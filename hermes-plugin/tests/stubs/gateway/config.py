from dataclasses import dataclass, field
from typing import Any, Optional


class Platform:
    def __init__(self, value: str):
        self.value = value

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Platform) and other.value == self.value

    def __hash__(self) -> int:
        return hash(self.value)


@dataclass
class PlatformConfig:
    enabled: bool = True
    token: Optional[str] = None
    api_key: Optional[str] = None
    extra: dict[str, Any] = field(default_factory=dict)
