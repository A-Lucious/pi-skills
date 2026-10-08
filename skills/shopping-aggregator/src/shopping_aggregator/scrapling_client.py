from __future__ import annotations

import importlib
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, cast


class ScraplingUnavailableError(RuntimeError):
    pass


class ScraplingBrowserClient:
    def __init__(self, config: Any):
        self.config = config
        self.config.ensure_dirs()

    def fetch_text(
        self,
        provider: Any,
        query: str,
        limit: int,
        screenshot: bool = False,
        headed: bool = False,
    ) -> str:
        url = provider.search_url(query)
        page = self._fetch(provider, url, headed=headed)
        if screenshot:
            self._save_screenshot(provider.name, page)
        return self._page_text(page)

    def check_login(self, provider: Any) -> bool:
        page = self._fetch(provider, provider.search_url("test"), headed=False)
        return not provider.login_required(self._page_text(page))

    def open_login(
        self, provider: Any, headed: bool = True, wait_seconds: int = 90
    ) -> dict[str, Any]:
        page = self._fetch(
            provider, provider.login_url, headed=headed, network_idle=False
        )
        if headed:
            time.sleep(max(wait_seconds, 1))
        return {
            "site": provider.name,
            "profile": str(self.config.profile_path(provider.name)),
            "opened": True,
            "title": self._title(page),
        }

    def screenshot(
        self, provider: Any, query: str | None = None, headed: bool = False
    ) -> Path:
        url = provider.search_url(query or "test")
        page = self._fetch(provider, url, headed=headed)
        return self._save_screenshot(provider.name, page)

    def _fetch(
        self, provider: Any, url: str, headed: bool, network_idle: bool = True
    ) -> Any:
        try:
            fetchers = importlib.import_module("scrapling.fetchers")
            stealthy_session = fetchers.StealthySession
        except (ImportError, AttributeError) as exc:
            raise ScraplingUnavailableError(
                "Scrapling is not installed. Create or reuse a user-level venv, then run: "
                "python -m pip install -r requirements.txt && python -m playwright install chromium"
            ) from exc

        profile_path = self.config.profile_path(provider.name)
        profile_path.mkdir(parents=True, exist_ok=True)
        cookies = self._browser_cookies(provider)
        session_kwargs: dict[str, Any] = {
            "headless": not headed,
            "user_data_dir": str(profile_path),
            "network_idle": network_idle,
        }
        if os.environ.get("SHOPPING_AGGREGATOR_REAL_CHROME") == "1":
            session_kwargs["real_chrome"] = True
        if cookies:
            session_kwargs["cookies"] = cookies
        fetch_kwargs = self._fetch_kwargs(provider)
        with stealthy_session(**session_kwargs) as session:
            return session.fetch(url, **fetch_kwargs)

    def _fetch_kwargs(self, provider: Any) -> dict[str, Any]:
        if provider.name != "goofish":
            return {}
        return {"wait": 5000, "page_action": self._goofish_page_action}

    @staticmethod
    def _goofish_page_action(page: Any) -> None:
        page.wait_for_timeout(8000)
        try:
            page.mouse.wheel(0, 1600)
            page.wait_for_timeout(5000)
        except Exception:
            return

    def _browser_cookies(self, provider: Any) -> list[dict[str, str]]:
        domain = self._cookie_domain(provider.name)
        return [
            {"name": name, "value": value, "domain": domain, "path": "/"}
            for name, value in self.config.cookies(provider.name).items()
        ]

    @staticmethod
    def _cookie_domain(site: str) -> str:
        return {
            "goofish": ".goofish.com",
            "taobao": ".taobao.com",
            "jd": ".jd.com",
        }.get(site, f".{site}.com")

    def _save_screenshot(self, site: str, page: Any) -> Path:
        self.config.screenshot_dir.mkdir(parents=True, exist_ok=True)
        path = self.config.screenshot_dir / f"{site}-{int(time.time())}.png"
        if hasattr(page, "screenshot"):
            page.screenshot(path=str(path), full_page=True)
        elif hasattr(page, "page") and hasattr(page.page, "screenshot"):
            page.page.screenshot(path=str(path), full_page=True)
        else:
            path.write_text(self._page_text(page), encoding="utf-8")
        return path

    @staticmethod
    def _page_text(page: Any) -> str:
        if isinstance(page, str):
            return page
        for attribute in ("html", "text", "body"):
            if not hasattr(page, attribute):
                continue
            value = getattr(page, attribute)
            resolved = cast(Callable[[], object], value)() if callable(value) else value
            text = ScraplingBrowserClient._coerce_text(resolved)
            if text:
                return text
        return str(page)

    @staticmethod
    def _coerce_text(value: object) -> str:
        if isinstance(value, bytes):
            for encoding in ("utf-8", "gbk", "gb18030"):
                try:
                    return value.decode(encoding).strip()
                except UnicodeDecodeError:
                    continue
            return value.decode("utf-8", errors="ignore").strip()
        return str(value).strip()

    @staticmethod
    def _title(page: Any) -> str | None:
        if hasattr(page, "title"):
            value = page.title
            return str(
                cast(Callable[[], object], value)() if callable(value) else value
            )
        return None
