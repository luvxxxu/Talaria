from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional


class MessageType(Enum):
    TEXT = "text"
    PHOTO = "photo"
    DOCUMENT = "document"


@dataclass
class SessionSource:
    platform: Any
    chat_id: str
    chat_name: Optional[str] = None
    chat_type: str = "dm"
    user_id: Optional[str] = None
    user_name: Optional[str] = None


@dataclass
class MessageEvent:
    text: str
    message_type: MessageType = MessageType.TEXT
    source: Optional[SessionSource] = None
    raw_message: Any = None
    message_id: Optional[str] = None
    media_urls: list = field(default_factory=list)
    timestamp: datetime = field(default_factory=datetime.now)
