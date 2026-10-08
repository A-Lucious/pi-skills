from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass(frozen=True)
class ProductResult:
    site: str
    title: str
    url: str
    price: str | None = None
    shop: str | None = None
    location: str | None = None
    image: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        return {
            key: value for key, value in data.items() if value not in (None, {}, [])
        }


@dataclass(frozen=True)
class ProviderSearchResult:
    site: str
    query: str
    items: list[ProductResult]
    login_required: bool = False
    message: str | None = None

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "site": self.site,
            "query": self.query,
            "login_required": self.login_required,
            "items": [item.to_dict() for item in self.items],
        }
        if self.message:
            data["message"] = self.message
        return data
