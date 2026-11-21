"""Shared test setup: the gateway stubs on sys.path and a fake bridge."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Optional

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "stubs"))
sys.path.insert(0, str(HERE.parent))

import httpx  # noqa: E402

TOKEN = "t" * 43
URL = "http://bridge.test:8790"
ME = "+821012345678"
CHAT = f"any;-;{ME}"


def event(rowid: int, text: str = "hi", *, sender: str = ME, chat_guid: Optional[str] = CHAT,
          age: float = 0, is_group: bool = False, attachments: Optional[list] = None) -> dict[str, Any]:
    return {
        "rowid": rowid, "guid": f"GUID-{rowid}", "sender": sender, "text": text,
        "chat_guid": chat_guid, "chat_identifier": sender, "is_group": is_group,
        "timestamp": time.time() - age, "service": "iMessage", "attachments": attachments or [],
    }


class FakeBridge:
    """Answers like talaria-bridge: /health, /events (short long-poll), /send."""

    def __init__(self, cursor: int = 0):
        self.cursor = cursor
        self.pending: list[dict] = []
        self.sent: list[dict] = []
        self.event_requests: list[dict] = []
        self.auth_headers: list[Optional[str]] = []
        self.health_status = 200
        self.send_status = 200
        self.fail_events = 0  # number of /events calls that raise ConnectError
        self.connect_error = False
        self.typing_mode = "off"  # what /health reports; "missing" = a bridge older than /typing
        self.typing_requests: list[dict] = []

    def push(self, *events: dict) -> None:
        self.pending.extend(events)
        self.cursor = max([self.cursor, *(e["rowid"] for e in events)])

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    async def handle(self, request: httpx.Request) -> httpx.Response:
        self.auth_headers.append(request.headers.get("authorization"))
        if self.connect_error:
            raise httpx.ConnectError("connection refused", request=request)
        if request.headers.get("authorization") != f"Bearer {TOKEN}":
            return httpx.Response(401, json={"error": "unauthorized", "reason": "token does not match TALARIA_TOKEN"})
        path = request.url.path
        if path == "/health":
            health = {"ok": True, "cursor": self.cursor, "version": "test"}
            if self.typing_mode != "missing":
                health["typing"] = self.typing_mode
            return httpx.Response(self.health_status, json=health)
        if path == "/typing":
            if self.typing_mode == "missing":
                return httpx.Response(404, json={"error": "not found"})
            self.typing_requests.append(json.loads(request.content))
            return httpx.Response(200, json={"ok": True, "enabled": self.typing_mode != "off"})
        if path == "/events":
            self.event_requests.append(dict(request.url.params))
            if self.fail_events:
                self.fail_events -= 1
                raise httpx.ConnectError("bridge down", request=request)
            after = int(request.url.params.get("after", self.cursor))
            ready = [e for e in self.pending if e["rowid"] > after]
            if not ready:
                await asyncio.sleep(0.02)
                # Like the real hub: events and cursor are read together, so the
                # cursor never moves past an event this response leaves out.
                ready = [e for e in self.pending if e["rowid"] > after]
            return httpx.Response(200, json={"events": ready, "cursor": self.cursor})
        if path == "/send":
            body = json.loads(request.content)
            if self.send_status != 200:
                return httpx.Response(self.send_status, json={"error": "recipient is not in TALARIA_ALLOWED_HANDLES"})
            self.sent.append(body)
            return httpx.Response(200, json={"ok": True})
        return httpx.Response(404, json={"error": "not found"})


async def wait_for(predicate, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.01)


def bridge_env() -> dict[str, str]:
    return {"TALARIA_BRIDGE_URL": URL, "TALARIA_BRIDGE_TOKEN": TOKEN}


__all__ = ["CHAT", "ME", "TOKEN", "URL", "FakeBridge", "bridge_env", "event", "wait_for", "os"]
