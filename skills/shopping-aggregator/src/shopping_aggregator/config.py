from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CONFIG_DIR = Path.home() / ".config" / "shopping-aggregator"
DEFAULT_DATA_DIR = Path.home() / ".local" / "share" / "shopping-aggregator"


def normalize_site(site: str) -> str:
    return site.strip().lower().replace("-", "_")


def cookie_env_name(site: str) -> str:
    return f"SHOPPING_AGGREGATOR_{normalize_site(site).upper()}_COOKIE"


def parse_cookie_header(cookie_header: str | None) -> dict[str, str]:
    cookies: dict[str, str] = {}
    if not cookie_header:
        return cookies
    for part in cookie_header.split(";"):
        if "=" not in part:
            continue
        name, value = part.split("=", 1)
        name = name.strip()
        if not name:
            continue
        cookies[name] = value.strip()
    return cookies


@dataclass(frozen=True)
class RuntimeConfig:
    config_dir: Path = DEFAULT_CONFIG_DIR
    data_dir: Path = DEFAULT_DATA_DIR

    @property
    def cookie_dir(self) -> Path:
        return self.config_dir / "cookies"

    @property
    def profile_dir(self) -> Path:
        return self.data_dir / "profiles"

    @property
    def screenshot_dir(self) -> Path:
        return self.data_dir / "screenshots"

    def cookie_file(self, site: str) -> Path:
        return self.cookie_dir / f"{normalize_site(site)}.txt"

    def profile_path(self, site: str) -> Path:
        return self.profile_dir / normalize_site(site)

    def cookie_header(self, site: str) -> str | None:
        env_value = os.environ.get(cookie_env_name(site))
        if env_value:
            return env_value.strip()
        cookie_path = self.cookie_file(site)
        if cookie_path.exists():
            text = cookie_path.read_text(encoding="utf-8").strip()
            return text or None
        return None

    def cookies(self, site: str) -> dict[str, str]:
        return parse_cookie_header(self.cookie_header(site))

    def ensure_dirs(self) -> None:
        for path in (self.cookie_dir, self.profile_dir, self.screenshot_dir):
            path.mkdir(parents=True, exist_ok=True)
