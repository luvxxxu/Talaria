"""Talaria: iMessage for Hermes through a self-hosted Mac bridge.

The bridge (``talaria-bridge serve`` on the Mac signed in to Messages) exposes

    GET  /health                          -> {"ok", "cursor", "version"}
    GET  /events?after=<id>&timeout=<s>   -> {"events": [...], "cursor": N}   (long poll)
    POST /send {"text", "chat_guid" | "to"} -> {"ok": true}

and checks ``Authorization: Bearer <token>`` on every request. This adapter
long-polls ``/events``, hands each message to the gateway, and posts replies to
``/send``. Settings come from env (``TALARIA_*``) or ``gateway.platforms.talaria.extra``.
"""

from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import datetime as dt
import json
import logging
import os
import random
import re
import time
import uuid
from pathlib import Path
from typing import Any, Optional

import httpx

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.event import MessageEvent, MessageType

# Newer Hermes cores provide these; the fallbacks keep the plugin loadable on older ones.
try:
    from gateway.platforms._shared import get_scoped_secret as _get_secret
except ImportError:  # pragma: no cover - depends on the Hermes version
    def _get_secret(name: str, default: Any = None, **_kw: Any) -> Any:
        return os.environ.get(name, default)

try:
    from gateway.platforms._shared import send_error as _send_error
except ImportError:  # pragma: no cover
    def _send_error(message: Any, *, nothing_sent: bool = False) -> dict:
        return {"success": False, "error": str(message), **({"retryable": True} if nothing_sent else {})}

try:
    from gateway.platforms.helpers import MessageDeduplicator
except ImportError:  # pragma: no cover
    MessageDeduplicator = None

try:
    from gateway.platforms.helpers import hash_for_log as _hash_for_log
except ImportError:  # pragma: no cover
    def _hash_for_log(value: object) -> str:
        return "<redacted>"

try:
    from gateway.platforms.helpers import strip_markdown as _strip_markdown
except ImportError:  # pragma: no cover
    _strip_markdown = None

logger = logging.getLogger(__name__)

PLATFORM = "talaria"
ENV_URL = "TALARIA_BRIDGE_URL"
ENV_TOKEN = "TALARIA_BRIDGE_TOKEN"
ENV_ALLOWED = "TALARIA_ALLOWED_USERS"
ENV_ALLOW_ALL = "TALARIA_ALLOW_ALL_USERS"
ENV_HOME = "TALARIA_HOME_CHANNEL"
ENV_MAX_AGE = "TALARIA_MAX_AGE_SECONDS"

POLL_WAIT = 25  # seconds the bridge holds each long poll open
REQUEST_TIMEOUT = httpx.Timeout(10.0, read=POLL_WAIT + 15)
MAX_CHUNK = 4000  # characters per iMessage bubble before splitting
BACKOFF_START = 1.0
BACKOFF_MAX = 60.0
DEFAULT_MAX_AGE = 600.0
DIRECT_CHAT_SEPARATOR = ";-;"

PLATFORM_HINT = (
    "You are texting via iMessage. Replies arrive as plain text bubbles, so write like a person texting: "
    "short and conversational, answer first, no preamble or recap. Markdown does not render and is stripped, "
    "so skip headers, tables, code fences and backticks; for a few items use short lines rather than nested "
    "bullets. Put a command or code snippet on its own line as plain text so it can be copied. Write links as "
    "bare URLs. You cannot send files or images on this channel, and attachments the user sends are not "
    "forwarded to you yet: you only see their file names."
)


# ── helpers shared by the adapter and the out-of-process sender ─────────────


def normalize_handle(handle: str) -> str:
    """Same canonical form as the bridge: lowercase emails, bare E.164 phone numbers."""
    value = handle.strip().lower()
    for prefix in ("mailto:", "tel:"):
        if value.startswith(prefix):
            value = value[len(prefix):]
    if "@" in value:
        return value
    return re.sub(r"[^0-9+]", "", value)


def _setting(extra: Optional[dict], key: str, env: str, default: Any = "") -> Any:
    """Env first (profile-scoped), then ``config.extra``, then ``default``."""
    value = _get_secret(env, "")
    if value not in (None, ""):
        return value
    value = (extra or {}).get(key)
    return default if value in (None, "") else value


def _float_setting(extra: Optional[dict], key: str, env: str, default: float) -> float:
    try:
        return float(_setting(extra, key, env, default))
    except (TypeError, ValueError):
        return default


def _bridge_settings(config: Any) -> tuple[str, str]:
    extra = getattr(config, "extra", None) or {}
    url = str(_setting(extra, "bridge_url", ENV_URL)).strip().rstrip("/")
    token = str(_setting(extra, "bridge_token", ENV_TOKEN)).strip()
    return url, token


def _client(url: str, token: str, transport: Optional[httpx.AsyncBaseTransport] = None) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=url,
        headers={"Authorization": f"Bearer {token}"},
        timeout=REQUEST_TIMEOUT,
        transport=transport,
    )


def _plain_text(content: str) -> str:
    """iMessage shows Markdown literally, so drop the markers but keep the layout."""
    if _strip_markdown is None:
        return content.strip()
    try:
        return _strip_markdown(content, keep_link_targets=True).strip()
    except TypeError:  # older helper without keep_link_targets
        return _strip_markdown(content).strip()


def _chunks(text: str, limit: int = MAX_CHUNK) -> list[str]:
    """One bubble when it fits; otherwise split on paragraphs, then hard-split long ones."""
    if len(text) <= limit:
        return [text]
    chunks: list[str] = []
    current = ""
    for paragraph in re.split(r"\n\s*\n", text):
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        candidate = f"{current}\n\n{paragraph}" if current else paragraph
        if len(candidate) <= limit:
            current = candidate
            continue
        if current:
            chunks.append(current)
        while len(paragraph) > limit:
            cut = paragraph.rfind(" ", 0, limit)
            cut = cut if cut > limit // 2 else limit
            chunks.append(paragraph[:cut].rstrip())
            paragraph = paragraph[cut:].lstrip()
        current = paragraph
    if current:
        chunks.append(current)
    return chunks


def _error_detail(response: httpx.Response) -> str:
    try:
        body = response.json()
        detail = body.get("reason") or body.get("error")
        if detail:
            return str(detail)
    except (ValueError, AttributeError):
        pass
    return response.text[:200] or response.reason_phrase


async def _post_send(client: httpx.AsyncClient, chat_id: str, text: str) -> SendResult:
    """POST one bubble to the bridge. ``chat_id`` is a 1:1 chat GUID or a handle."""
    body: dict[str, Any] = {"text": text}
    if DIRECT_CHAT_SEPARATOR in chat_id:
        body["chat_guid"] = chat_id
    else:
        body["to"] = chat_id
    try:
        response = await client.post("/send", json=body)
    except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
        # The request never reached the bridge, so nothing was sent: safe to retry.
        return SendResult(success=False, error=f"bridge unreachable: {exc}", retryable=True)
    except httpx.HTTPError as exc:
        # The bridge may already have handed the text to Messages; don't risk a duplicate.
        return SendResult(success=False, error=f"bridge request failed: {exc}")
    if response.status_code == 200:
        return SendResult(success=True, message_id=uuid.uuid4().hex)
    return SendResult(success=False, error=f"bridge returned {response.status_code}: {_error_detail(response)}")


class _BridgeAuthError(Exception):
    pass


async def _get_json(client: httpx.AsyncClient, path: str, **params: Any) -> dict:
    response = await client.get(path, params=params or None)
    if response.status_code == 401:
        raise _BridgeAuthError(_error_detail(response))
    response.raise_for_status()
    return response.json()


def _state_path() -> Path:
    try:
        from hermes_constants import get_hermes_home
        home = Path(get_hermes_home())
    except Exception:
        home = Path.home() / ".hermes"
    return home / "talaria" / "state.json"


# ── adapter ──────────────────────────────────────────────────────────────────


class TalariaAdapter(BasePlatformAdapter):
    """Long-polls the Talaria bridge and relays 1:1 iMessages to and from Hermes."""

    SUPPORTS_MESSAGE_EDITING = False
    MAX_MESSAGE_LENGTH = MAX_CHUNK
    splits_long_messages = True  # send() splits long replies itself

    # Tests swap in an httpx.MockTransport; None means real network.
    transport: Optional[httpx.AsyncBaseTransport] = None

    def __init__(self, config: PlatformConfig, **_kwargs: Any):
        super().__init__(config, Platform(PLATFORM))
        extra = getattr(config, "extra", None) or {}
        self.bridge_url, self.bridge_token = _bridge_settings(config)
        self.max_age = _float_setting(extra, "max_age_seconds", ENV_MAX_AGE, DEFAULT_MAX_AGE)
        self._http: Optional[httpx.AsyncClient] = None
        self._poll_task: Optional[asyncio.Task] = None
        self._polling = False
        self._cursor = 0
        self._seen = MessageDeduplicator(ttl_seconds=3600) if MessageDeduplicator else _SeenIDs()

    @property
    def name(self) -> str:
        return "iMessage (Talaria)"

    # lifecycle

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        if not self.bridge_url or not self.bridge_token:
            return self._fail("config_missing", f"{ENV_URL} and {ENV_TOKEN} must be set", retryable=False)
        if hasattr(self, "_acquire_platform_lock") and not self._acquire_platform_lock(
                PLATFORM, self.bridge_url, f"Talaria bridge {self.bridge_url}"):
            return False
        self._http = _client(self.bridge_url, self.bridge_token, self.transport)
        try:
            health = await _get_json(self._http, "/health")
        except _BridgeAuthError as exc:
            await self._close()
            return self._fail("unauthorized", f"the bridge rejected {ENV_TOKEN} ({exc})", retryable=False)
        except (httpx.HTTPError, ValueError) as exc:
            await self._close()
            logger.error("Talaria: cannot reach the bridge at %s: %s", self.bridge_url, exc)
            return self._fail("connect_failed", f"cannot reach the bridge at {self.bridge_url}: {exc}", retryable=True)

        bridge_cursor = int(health.get("cursor") or 0)
        stored = self._load_cursor()
        # Resume where we stopped so messages sent while Hermes restarted still arrive
        # (the bridge keeps recent ones), unless the bridge's history was reset.
        self._cursor = stored if stored is not None and stored <= bridge_cursor else bridge_cursor
        self._polling = True
        self._mark_connected()
        self._poll_task = asyncio.create_task(self._poll_loop(), name="talaria-poll")
        logger.info("Talaria: connected to bridge %s (version %s, cursor %d)",
                    self.bridge_url, health.get("version", "?"), self._cursor)
        return True

    async def disconnect(self) -> None:
        self._polling = False
        self._mark_disconnected()
        task, self._poll_task = self._poll_task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        await self._close()

    async def _close(self) -> None:
        if self._http is not None:
            with contextlib.suppress(Exception):
                await self._http.aclose()
            self._http = None
        if hasattr(self, "_release_platform_lock"):
            with contextlib.suppress(Exception):
                self._release_platform_lock()

    def _fail(self, code: str, message: str, *, retryable: bool) -> bool:
        if hasattr(self, "_set_fatal_error"):
            self._set_fatal_error(code, message, retryable=retryable)
        return False

    # inbound

    async def _poll_loop(self) -> None:
        delay = BACKOFF_START
        failing = False
        while self._polling and self._http is not None:
            try:
                data = await _get_json(self._http, "/events", after=self._cursor, timeout=POLL_WAIT)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # bridge down, Mac asleep, token changed, ...
                if not failing:
                    level = logging.ERROR if isinstance(exc, _BridgeAuthError) else logging.WARNING
                    logger.log(level, "Talaria: polling the bridge failed (%s); retrying with backoff",
                               exc if isinstance(exc, _BridgeAuthError) else type(exc).__name__)
                    failing = True
                await asyncio.sleep(delay + random.uniform(0, delay / 2))
                delay = min(delay * 2, BACKOFF_MAX)
                continue
            if failing:
                logger.info("Talaria: bridge reachable again")
                failing = False
            delay = BACKOFF_START

            for item in data.get("events") or []:
                try:
                    await self._dispatch(item)
                except asyncio.CancelledError:
                    raise
                except Exception:
                    logger.exception("Talaria: failed to handle an incoming message")

            cursor = data.get("cursor")
            if isinstance(cursor, int) and cursor != self._cursor:
                if cursor < self._cursor:
                    logger.warning("Talaria: bridge cursor went backwards (%d -> %d); following it",
                                   self._cursor, cursor)
                self._cursor = cursor
                self._save_cursor(cursor)

    async def _dispatch(self, item: dict) -> None:
        guid = str(item.get("guid") or item.get("rowid") or "")
        sender = str(item.get("sender") or "")
        if not guid or not sender or item.get("is_group"):
            return
        if self._seen.is_duplicate(guid):
            return
        timestamp = float(item.get("timestamp") or 0)
        if self.max_age > 0 and timestamp and time.time() - timestamp > self.max_age:
            logger.info("Talaria: skipping message %s, older than %.0fs", guid, self.max_age)
            return

        text = str(item.get("text") or "").strip()
        attachments = [a for a in item.get("attachments") or [] if isinstance(a, dict)]
        if attachments:
            names = ", ".join(str(a.get("name") or a.get("mime_type") or "file") for a in attachments)
            note = f"[The user attached {len(attachments)} file(s) that this channel cannot forward yet: {names}]"
            text = f"{text}\n\n{note}" if text else note
        if not text:
            return

        chat_id = str(item.get("chat_guid") or sender)
        source = self.build_source(
            chat_id=chat_id,
            chat_name=sender,
            chat_type="dm",
            user_id=normalize_handle(sender),
            user_name=sender,
        )
        event = MessageEvent(
            text=text,
            message_type=MessageType.TEXT,
            source=source,
            message_id=guid,
            raw_message=item,
            timestamp=dt.datetime.fromtimestamp(timestamp) if timestamp else dt.datetime.now(),
        )
        logger.debug("Talaria: message %s from %s (%d chars)", guid, sender, len(text))
        logger.info("Talaria: message %s from %s", guid, _hash_for_log(sender))
        await self.handle_message(event)

    def _load_cursor(self) -> Optional[int]:
        try:
            state = json.loads(_state_path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if state.get("bridge_url") != self.bridge_url:
            return None
        cursor = state.get("cursor")
        return cursor if isinstance(cursor, int) else None

    def _save_cursor(self, cursor: int) -> None:
        path = _state_path()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"bridge_url": self.bridge_url, "cursor": cursor}), encoding="utf-8")
            os.replace(tmp, path)
        except OSError as exc:
            logger.debug("Talaria: could not save cursor: %s", exc)

    # outbound

    def format_message(self, content: str) -> str:
        return _plain_text(content)

    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[dict[str, Any]] = None) -> SendResult:
        text = self.format_message(content)
        if not text:
            return SendResult(success=False, error="Talaria send requires text")
        if self._http is None:
            return SendResult(success=False, error="Not connected", retryable=True)
        result = SendResult(success=True)
        for chunk in _chunks(text):
            result = await _post_send(self._http, chat_id, chunk)
            if not result.success:
                logger.warning("Talaria: send to %s failed: %s", _hash_for_log(chat_id), result.error)
                return result
        return result

    async def send_typing(self, chat_id: str, metadata: Any = None) -> None:
        """Messages offers no public way to show a typing indicator."""

    async def get_chat_info(self, chat_id: str) -> dict[str, Any]:
        handle = chat_id.rsplit(DIRECT_CHAT_SEPARATOR, 1)[-1]
        return {"name": handle, "type": "dm", "chat_id": chat_id}


class _SeenIDs:
    """Fallback for cores without MessageDeduplicator: remembers recent ids."""

    def __init__(self, limit: int = 2000):
        self._ids: dict[str, None] = {}
        self._limit = limit

    def is_duplicate(self, msg_id: str) -> bool:
        if msg_id in self._ids:
            return True
        self._ids[msg_id] = None
        if len(self._ids) > self._limit:
            self._ids.pop(next(iter(self._ids)))
        return False


# ── plugin registration ──────────────────────────────────────────────────────


def check_requirements() -> bool:
    """Only httpx is needed, and Hermes already depends on it."""
    return True


def validate_config(config: Any) -> bool:
    url, token = _bridge_settings(config)
    return bool(url and token)


def is_connected(config: Any) -> bool:
    return validate_config(config)


def _env_enablement() -> Optional[dict]:
    """Seed ``PlatformConfig.extra`` from env so env-only setups show up in ``hermes gateway status``."""
    url = str(_get_secret(ENV_URL, "") or "").strip().rstrip("/")
    token = str(_get_secret(ENV_TOKEN, "") or "").strip()
    if not (url and token):
        return None
    seed: dict[str, Any] = {"bridge_url": url, "bridge_token": token}
    home = str(_get_secret(ENV_HOME, "") or "").strip()
    if home:
        seed["home_channel"] = {"chat_id": home, "name": str(_get_secret(f"{ENV_HOME}_NAME", "") or "Home")}
    return seed


async def _standalone_send(pconfig: Any, chat_id: str, message: str, *, thread_id: Optional[str] = None,
                           media_files: Optional[list] = None, force_document: bool = False,
                           **_kw: Any) -> dict[str, Any]:
    """Out-of-process delivery (cron jobs running without the gateway). Text only."""
    url, token = _bridge_settings(pconfig)
    if not (url and token):
        return _send_error(f"Talaria: {ENV_URL} and {ENV_TOKEN} are not set", nothing_sent=True)
    text = _plain_text(message)
    if not text:
        return _send_error("Talaria: nothing to send", nothing_sent=True)
    async with _client(url, token, TalariaAdapter.transport) as client:
        for index, chunk in enumerate(_chunks(text)):
            result = await _post_send(client, chat_id, chunk)
            if not result.success:
                return _send_error(f"Talaria send failed: {result.error}",
                                   nothing_sent=index == 0 and result.retryable)
    return {"success": True, "platform": PLATFORM, "chat_id": chat_id, "message_id": result.message_id}


def _supported_kwargs(kwargs: dict[str, Any]) -> dict[str, Any]:
    """Drop registration options this Hermes core doesn't know (older cores reject unknown kwargs)."""
    try:
        from gateway.platform_registry import PlatformEntry
        known = {f.name for f in dataclasses.fields(PlatformEntry)}
    except Exception:
        return kwargs
    unknown = sorted(set(kwargs) - known)
    if unknown:
        logger.debug("Talaria: this Hermes version ignores %s", ", ".join(unknown))
    return {key: value for key, value in kwargs.items() if key in known}


def register(ctx: Any) -> None:
    """Plugin entry point, called by the Hermes plugin system."""
    ctx.register_platform(**_supported_kwargs(dict(
        name=PLATFORM,
        label="iMessage (Talaria)",
        adapter_factory=TalariaAdapter,
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=[ENV_URL, ENV_TOKEN],
        install_hint="No extra packages needed (uses httpx from Hermes).",
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var=ENV_HOME,
        standalone_sender_fn=_standalone_send,
        allowed_users_env=ENV_ALLOWED,
        allow_all_env=ENV_ALLOW_ALL,
        # Unknown senders are dropped silently instead of being sent a pairing code.
        allowlist_suppresses_pairing=True,
        # send() splits long replies itself.
        max_message_length=0,
        pii_safe=True,
        emoji="💬",
        platform_hint=PLATFORM_HINT,
        dashboard_description="Use Hermes through iMessage via your own Talaria bridge on a Mac.",
        dashboard_env_vars=(ENV_URL, ENV_TOKEN, ENV_ALLOWED),
    )))
