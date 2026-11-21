from dataclasses import dataclass
from typing import Any, Optional

from gateway.config import Platform, PlatformConfig
from gateway.platforms.event import MessageEvent, SessionSource


@dataclass
class SendResult:
    success: bool
    message_id: Optional[str] = None
    error: Optional[str] = None
    raw_response: Any = None
    retryable: bool = False


class BasePlatformAdapter:
    def __init__(self, config: PlatformConfig, platform: Platform):
        self.config = config
        self.platform = platform
        self._message_handler = None
        self._running = False
        self.fatal_error: Optional[tuple] = None
        self.lock_held = False

    def set_message_handler(self, handler) -> None:
        self._message_handler = handler

    async def handle_message(self, event: MessageEvent) -> None:
        if self._message_handler:
            await self._message_handler(event)

    def build_source(self, chat_id: str, chat_name: Optional[str] = None, chat_type: str = "dm",
                     user_id: Optional[str] = None, user_name: Optional[str] = None, **_kw: Any) -> SessionSource:
        return SessionSource(platform=self.platform, chat_id=str(chat_id), chat_name=chat_name,
                             chat_type=chat_type, user_id=user_id, user_name=user_name)

    def _mark_connected(self, *, listener_base: Optional[str] = None) -> None:
        self._running = True

    def _mark_disconnected(self) -> None:
        self._running = False

    def _set_fatal_error(self, code: str, message: str, *, retryable: bool) -> None:
        self.fatal_error = (code, message, retryable)

    def _acquire_platform_lock(self, scope: str, identity: str, resource_desc: str) -> bool:
        self.lock_held = True
        return True

    def _release_platform_lock(self) -> None:
        self.lock_held = False
