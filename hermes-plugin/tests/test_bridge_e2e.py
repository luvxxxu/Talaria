"""The plugin against a real talaria-bridge process and a fake chat.db.

    TALARIA_BRIDGE_BIN=../../bridge/.build/release/talaria-bridge python -m unittest test_bridge_e2e

Never makes the bridge call Messages: the only /send goes to a recipient the
bridge refuses (403) before any AppleScript runs. Skipped without TALARIA_BRIDGE_BIN.
"""

import asyncio
import contextlib
import os
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from support import CHAT, ME, TOKEN, wait_for

from gateway.config import PlatformConfig
from talaria import adapter as talaria
from talaria.adapter import TalariaAdapter

BIN = os.environ.get("TALARIA_BRIDGE_BIN")
APPLE_EPOCH = 978307200

SCHEMA = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, chat_identifier TEXT, style INTEGER);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT, attributedBody BLOB,
    handle_id INTEGER, is_from_me INTEGER DEFAULT 0, date INTEGER, service TEXT, item_type INTEGER DEFAULT 0,
    associated_message_type INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, mime_type TEXT, transfer_name TEXT);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
"""


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@unittest.skipUnless(BIN, "set TALARIA_BRIDGE_BIN to a built talaria-bridge")
class BridgeEndToEndTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.db_path = root / "chat.db"
        with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
            db.executescript(SCHEMA)
            db.execute("INSERT INTO handle (id, service) VALUES (?, 'iMessage')", (ME,))
            db.execute("INSERT INTO chat (guid, chat_identifier, style) VALUES (?, ?, 45)", (CHAT, ME))
        (root / "empty.env").write_text("")
        port = free_port()
        env = {**os.environ, "TALARIA_TOKEN": TOKEN, "TALARIA_ALLOWED_HANDLES": ME, "TALARIA_PORT": str(port),
               "TALARIA_DB_PATH": str(self.db_path), "TALARIA_STATE_PATH": str(root / "bridge-state.json")}
        self.bridge_log = open(root / "bridge.log", "wb")
        self.bridge = subprocess.Popen([BIN, "--env-file", str(root / "empty.env"), "serve"], env=env,
                                       stdout=self.bridge_log, stderr=subprocess.STDOUT)
        url = f"http://127.0.0.1:{port}"
        self.patches = [
            mock.patch.dict(os.environ, {"TALARIA_BRIDGE_URL": url, "TALARIA_BRIDGE_TOKEN": TOKEN}),
            mock.patch.object(talaria, "_state_path", lambda: root / "plugin-state.json"),
        ]
        for patch in self.patches:
            patch.start()
        for _ in range(100):  # wait for the listener
            with socket.socket() as sock:
                if sock.connect_ex(("127.0.0.1", port)) == 0:
                    break
            await asyncio.sleep(0.05)
        self.received = []
        self.adapter = TalariaAdapter(PlatformConfig())

        async def handler(evt):
            self.received.append(evt)

        self.adapter.set_message_handler(handler)

    async def asyncTearDown(self):
        await self.adapter.disconnect()
        for patch in reversed(self.patches):
            patch.stop()
        self.bridge.terminate()
        self.bridge.wait(timeout=10)
        self.bridge_log.close()
        self.tmp.cleanup()

    def insert_message(self, text: str, handle_id: int = 1, chat_id: int = 1) -> None:
        with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
            cur = db.execute(
                "INSERT INTO message (guid, text, handle_id, date, service) VALUES (?, ?, ?, ?, 'iMessage')",
                (f"E2E-{time.time_ns()}", text, handle_id, int((time.time() - APPLE_EPOCH) * 1e9)))
            db.execute("INSERT INTO chat_message_join VALUES (?, ?)", (chat_id, cur.lastrowid))

    async def test_message_flows_from_chat_db_to_hermes(self):
        self.assertTrue(await self.adapter.connect())
        self.insert_message("안녕, 실제 브리지")
        await wait_for(lambda: self.received, timeout=10)
        evt = self.received[0]
        self.assertEqual(evt.text, "안녕, 실제 브리지")
        self.assertEqual(evt.source.chat_id, CHAT)
        self.assertEqual(evt.source.user_id, ME)

    async def test_bridge_refuses_recipients_outside_its_allowlist(self):
        self.assertTrue(await self.adapter.connect())
        result = await self.adapter.send("any;-;+15550001111", "should never reach Messages")
        self.assertFalse(result.success)
        self.assertIn("403", result.error)

    async def test_wrong_token_is_rejected(self):
        with mock.patch.dict(os.environ, {"TALARIA_BRIDGE_TOKEN": "x" * 43}):
            adapter = TalariaAdapter(PlatformConfig())
        self.assertFalse(await adapter.connect())
        self.assertEqual(adapter.fatal_error[0], "unauthorized")
        self.assertIn("does not match", adapter.fatal_error[1])


if __name__ == "__main__":
    unittest.main()
