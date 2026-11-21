import json
import os
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from unittest import mock

from support import CHAT, ME, TOKEN, URL, FakeBridge, bridge_env, event, wait_for

from gateway.config import PlatformConfig
from talaria import adapter as talaria
from talaria.adapter import TalariaAdapter


class AdapterTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state_file = Path(self.tmp.name) / "talaria" / "state.json"
        self.patches = [
            mock.patch.dict(os.environ, bridge_env()),
            mock.patch.object(talaria, "_state_path", lambda: self.state_file),
            mock.patch.object(talaria, "BACKOFF_START", 0.01),
        ]
        for patch in self.patches:
            patch.start()
        self.bridge = FakeBridge(cursor=10)
        self.received = []
        self.adapter = self.make_adapter()

    async def asyncTearDown(self):
        await self.adapter.disconnect()
        for patch in reversed(self.patches):
            patch.stop()
        TalariaAdapter.transport = None
        self.tmp.cleanup()

    def make_adapter(self, extra=None):
        TalariaAdapter.transport = self.bridge.transport
        adapter = TalariaAdapter(PlatformConfig(extra=extra or {}))

        async def handler(evt):
            self.received.append(evt)

        adapter.set_message_handler(handler)
        return adapter


class InboundTests(AdapterTestCase):
    async def test_delivers_messages_from_the_bridge(self):
        self.assertTrue(await self.adapter.connect())
        self.bridge.push(event(11, "안녕 Hermes"))
        await wait_for(lambda: self.received)

        evt = self.received[0]
        self.assertEqual(evt.text, "안녕 Hermes")
        self.assertEqual(evt.message_id, "GUID-11")
        self.assertEqual(evt.source.chat_id, CHAT)
        self.assertEqual(evt.source.chat_type, "dm")
        self.assertEqual(evt.source.user_id, ME)
        self.assertEqual(self.bridge.auth_headers[0], f"Bearer {TOKEN}")
        await wait_for(lambda: self.state_file.exists())
        self.assertEqual(json.loads(self.state_file.read_text()), {"bridge_url": URL, "cursor": 11})

    async def test_starts_after_the_current_cursor(self):
        self.bridge.push(event(9, "old"))
        await self.adapter.connect()
        await wait_for(lambda: len(self.bridge.event_requests) >= 2)
        self.assertEqual(self.bridge.event_requests[0]["after"], "10")
        self.assertEqual(self.received, [])

    async def test_resumes_from_the_saved_cursor(self):
        self.state_file.parent.mkdir(parents=True)
        self.state_file.write_text(json.dumps({"bridge_url": URL, "cursor": 8}))
        self.bridge.push(event(9, "sent while Hermes restarted"))
        await self.adapter.connect()
        await wait_for(lambda: self.received)
        self.assertEqual(self.bridge.event_requests[0]["after"], "8")
        self.assertEqual(self.received[0].text, "sent while Hermes restarted")

    async def test_ignores_a_saved_cursor_for_another_bridge_or_ahead_of_it(self):
        self.state_file.parent.mkdir(parents=True)
        for state in ({"bridge_url": "http://other:8790", "cursor": 3}, {"bridge_url": URL, "cursor": 99}):
            self.state_file.write_text(json.dumps(state))
            self.bridge.event_requests.clear()
            adapter = self.make_adapter()
            await adapter.connect()
            await wait_for(lambda: self.bridge.event_requests)
            self.assertEqual(self.bridge.event_requests[0]["after"], "10", state)
            await adapter.disconnect()

    async def test_drops_duplicates_stale_and_group_messages(self):
        await self.adapter.connect()
        self.bridge.push(
            event(11, "first"),
            event(12, "too old", age=3600),
            event(13, "group", is_group=True, chat_guid="any;+;chat1"),
            event(14, "last"),
        )
        await wait_for(lambda: len(self.received) >= 2)
        await self.adapter._dispatch(event(11, "first"))  # redelivered
        self.assertEqual([e.text for e in self.received], ["first", "last"])

    async def test_mentions_attachments_it_cannot_forward(self):
        await self.adapter.connect()
        self.bridge.push(event(11, "", attachments=[{"path": "/Users/x/a.jpg", "mime_type": "image/jpeg", "name": "a.jpg"}]))
        await wait_for(lambda: self.received)
        self.assertIn("a.jpg", self.received[0].text)
        self.assertIn("cannot forward", self.received[0].text)

    async def test_keeps_polling_after_the_bridge_goes_away(self):
        self.bridge.fail_events = 3
        await self.adapter.connect()
        self.bridge.push(event(11, "after recovery"))
        await wait_for(lambda: self.received)
        self.assertEqual(self.received[0].text, "after recovery")

    async def test_follows_the_bridge_when_its_cursor_goes_backwards(self):
        await self.adapter.connect()
        await wait_for(lambda: self.bridge.event_requests)
        self.bridge.cursor = 2  # chat.db was recreated on the Mac
        self.bridge.pending = []
        await wait_for(lambda: self.adapter._cursor == 2)
        self.bridge.push(event(3, "new history"))
        await wait_for(lambda: self.received)
        self.assertEqual(self.received[0].text, "new history")


class ConnectTests(AdapterTestCase):
    async def test_rejected_token_is_fatal(self):
        with mock.patch.dict(os.environ, {"TALARIA_BRIDGE_TOKEN": "wrong"}):
            adapter = self.make_adapter()
        self.assertFalse(await adapter.connect())
        self.assertEqual(adapter.fatal_error[0], "unauthorized")
        self.assertFalse(adapter.fatal_error[2])
        self.assertFalse(adapter.lock_held)

    async def test_unreachable_bridge_is_retryable(self):
        self.bridge.connect_error = True
        self.assertFalse(await self.adapter.connect())
        self.assertEqual(self.adapter.fatal_error[0], "connect_failed")
        self.assertTrue(self.adapter.fatal_error[2])

    async def test_missing_settings(self):
        with mock.patch.dict(os.environ, {"TALARIA_BRIDGE_URL": "", "TALARIA_BRIDGE_TOKEN": ""}):
            adapter = self.make_adapter()
        self.assertFalse(await adapter.connect())
        self.assertEqual(adapter.fatal_error[0], "config_missing")

    async def test_settings_from_yaml_extra(self):
        with mock.patch.dict(os.environ, {"TALARIA_BRIDGE_URL": "", "TALARIA_BRIDGE_TOKEN": ""}):
            adapter = self.make_adapter({"bridge_url": URL + "/", "bridge_token": TOKEN, "max_age_seconds": "30"})
        self.assertEqual((adapter.bridge_url, adapter.max_age), (URL, 30.0))
        self.assertTrue(await adapter.connect())
        await adapter.disconnect()

    async def test_disconnect_stops_polling(self):
        await self.adapter.connect()
        await self.adapter.disconnect()
        self.assertIsNone(self.adapter._poll_task)
        self.assertFalse(self.adapter.lock_held)
        count = len(self.bridge.event_requests)
        await wait_for(lambda: True)
        self.assertEqual(len(self.bridge.event_requests), count)


class OutboundTests(AdapterTestCase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        await self.adapter.connect()

    async def test_reply_to_chat_guid(self):
        result = await self.adapter.send(CHAT, "  hello  ")
        self.assertTrue(result.success)
        self.assertEqual(self.bridge.sent, [{"text": "hello", "chat_guid": CHAT}])

    async def test_send_to_handle(self):
        await self.adapter.send(ME, "hello")
        self.assertEqual(self.bridge.sent, [{"text": "hello", "to": ME}])

    async def test_long_replies_are_split(self):
        text = "\n\n".join(["a" * 3000, "b" * 3000, "c " * 3000])
        self.assertTrue((await self.adapter.send(CHAT, text)).success)
        self.assertGreater(len(self.bridge.sent), 2)
        self.assertTrue(all(len(body["text"]) <= talaria.MAX_CHUNK for body in self.bridge.sent))
        joined = "".join(body["text"] for body in self.bridge.sent)
        self.assertEqual(joined.replace(" ", "").replace("\n", ""), text.replace(" ", "").replace("\n", ""))

    async def test_bridge_refusal_is_reported(self):
        self.bridge.send_status = 403
        result = await self.adapter.send(CHAT, "hello")
        self.assertFalse(result.success)
        self.assertFalse(result.retryable)
        self.assertIn("ALLOWED_HANDLES", result.error)

    async def test_unreachable_bridge_is_retryable(self):
        self.bridge.connect_error = True
        result = await self.adapter.send(CHAT, "hello")
        self.assertFalse(result.success)
        self.assertTrue(result.retryable)

    async def test_empty_and_not_connected(self):
        self.assertFalse((await self.adapter.send(CHAT, "   ")).success)
        await self.adapter.disconnect()
        result = await self.adapter.send(CHAT, "hello")
        self.assertFalse(result.success)
        self.assertTrue(result.retryable)

    async def test_chat_info(self):
        self.assertEqual(await self.adapter.get_chat_info(CHAT), {"name": ME, "type": "dm", "chat_id": CHAT})


class StandaloneSendTests(AdapterTestCase):
    async def test_sends_without_a_running_adapter(self):
        result = await talaria._standalone_send(PlatformConfig(), CHAT, "cron says hi")
        self.assertTrue(result["success"])
        self.assertEqual(self.bridge.sent, [{"text": "cron says hi", "chat_guid": CHAT}])

    async def test_reports_missing_settings(self):
        with mock.patch.dict(os.environ, {"TALARIA_BRIDGE_URL": "", "TALARIA_BRIDGE_TOKEN": ""}):
            result = await talaria._standalone_send(PlatformConfig(), CHAT, "hi")
        self.assertFalse(result["success"])
        self.assertTrue(result.get("retryable"))

    async def test_reports_bridge_errors(self):
        self.bridge.send_status = 403
        result = await talaria._standalone_send(PlatformConfig(), CHAT, "hi")
        self.assertFalse(result["success"])


class HelperTests(unittest.TestCase):
    def test_normalize_handle(self):
        self.assertEqual(talaria.normalize_handle(" +82 10-1234-5678 "), ME)
        self.assertEqual(talaria.normalize_handle("Me@iCloud.com"), "me@icloud.com")
        self.assertEqual(talaria.normalize_handle("tel:+821012345678"), ME)

    def test_chunks(self):
        self.assertEqual(talaria._chunks("short"), ["short"])
        chunks = talaria._chunks("x" * 9000, limit=4000)
        self.assertEqual([len(c) for c in chunks], [4000, 4000, 1000])

    def test_env_enablement(self):
        with mock.patch.dict(os.environ, {**bridge_env(), "TALARIA_HOME_CHANNEL": CHAT}):
            seed = talaria._env_enablement()
        self.assertEqual(seed["bridge_url"], URL)
        self.assertEqual(seed["home_channel"], {"chat_id": CHAT, "name": "Home"})
        with mock.patch.dict(os.environ, {"TALARIA_BRIDGE_URL": "", "TALARIA_BRIDGE_TOKEN": ""}):
            self.assertIsNone(talaria._env_enablement())


class RegistrationTests(unittest.TestCase):
    def capture(self):
        captured = {}

        class Ctx:
            def register_platform(self, **kwargs):
                captured.update(kwargs)

        talaria.register(Ctx())
        return captured

    def test_registers_the_platform(self):
        kwargs = self.capture()
        self.assertEqual(kwargs["name"], "talaria")
        self.assertIs(kwargs["adapter_factory"], TalariaAdapter)
        self.assertEqual(kwargs["allowed_users_env"], "TALARIA_ALLOWED_USERS")
        self.assertEqual(kwargs["cron_deliver_env_var"], "TALARIA_HOME_CHANNEL")
        self.assertTrue(kwargs["allowlist_suppresses_pairing"])

    def test_drops_options_an_older_core_does_not_know(self):
        @dataclass
        class PlatformEntry:
            name: str = ""
            label: str = ""
            adapter_factory: object = None
            check_fn: object = None
            allowed_users_env: str = ""
            extra: dict = field(default_factory=dict)

        module = type(sys)("gateway.platform_registry")
        module.PlatformEntry = PlatformEntry
        with mock.patch.dict(sys.modules, {"gateway.platform_registry": module}):
            kwargs = self.capture()
        self.assertEqual(set(kwargs), {"name", "label", "adapter_factory", "check_fn", "allowed_users_env"})


if __name__ == "__main__":
    unittest.main()
