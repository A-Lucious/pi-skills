from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from .config import DEFAULT_CONFIG_DIR, DEFAULT_DATA_DIR, RuntimeConfig
from .providers import get_provider, supported_sites
from .scrapling_client import ScraplingBrowserClient, ScraplingUnavailableError


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Search shopping platforms with Scrapling-backed sessions."
    )
    parser.add_argument("--config-dir", type=Path, default=DEFAULT_CONFIG_DIR)
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    subparsers = parser.add_subparsers(dest="command", required=True)

    search = subparsers.add_parser("search", help="Search product listings.")
    search.add_argument("query")
    search.add_argument("--sites", default=",".join(supported_sites()))
    search.add_argument("--limit", type=int, default=10)
    search.add_argument("--screenshot", action="store_true")
    search.add_argument("--headed", action="store_true")

    check_login = subparsers.add_parser(
        "check-login", help="Check whether a site session appears logged in."
    )
    check_login.add_argument("site", choices=supported_sites())

    login = subparsers.add_parser(
        "login", help="Open headed login flow and persist browser profile."
    )
    login.add_argument("site", choices=supported_sites())
    login.add_argument("--wait-seconds", type=int, default=90)
    login.add_argument("--headless", action="store_true")

    screenshot = subparsers.add_parser(
        "screenshot", help="Capture a diagnostic screenshot."
    )
    screenshot.add_argument("site", choices=supported_sites())
    screenshot.add_argument("--query")
    screenshot.add_argument("--headed", action="store_true")

    save_cookie = subparsers.add_parser(
        "save-cookie", help="Save a site cookie header from stdin into the user config."
    )
    save_cookie.add_argument("site", choices=supported_sites())
    save_cookie.add_argument("--stdin", action="store_true", required=True)

    return parser


def main(
    argv: Sequence[str] | None = None,
    client: Any | None = None,
    config_dir: Path | None = None,
    data_dir: Path | None = None,
) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    config = RuntimeConfig(
        config_dir=config_dir or args.config_dir, data_dir=data_dir or args.data_dir
    )
    browser_client = client or ScraplingBrowserClient(config)

    try:
        if args.command == "search":
            payload = run_search(args, browser_client)
        elif args.command == "check-login":
            provider = get_provider(args.site)
            payload = {
                "site": provider.name,
                "logged_in": bool(browser_client.check_login(provider)),
            }
        elif args.command == "login":
            provider = get_provider(args.site)
            payload = browser_client.open_login(
                provider, headed=not args.headless, wait_seconds=args.wait_seconds
            )
        elif args.command == "screenshot":
            provider = get_provider(args.site)
            path = browser_client.screenshot(
                provider, query=args.query, headed=args.headed
            )
            payload = {"site": provider.name, "screenshot": str(path)}
        elif args.command == "save-cookie":
            provider = get_provider(args.site)
            payload = save_cookie_from_stdin(config, provider.name)
        else:
            parser.error(f"Unsupported command: {args.command}")
    except ScraplingUnavailableError as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def run_search(args: argparse.Namespace, browser_client: Any) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    statuses: list[dict[str, Any]] = []
    for site in parse_sites(args.sites):
        provider = get_provider(site)
        try:
            text = browser_client.fetch_text(
                provider,
                args.query,
                args.limit,
                screenshot=args.screenshot,
                headed=args.headed,
            )
        except Exception as exc:
            statuses.append(
                {"site": provider.name, "login_required": None, "error": str(exc)}
            )
            continue
        if provider.login_required(text):
            statuses.append(
                {
                    "site": provider.name,
                    "login_required": True,
                    "repair_command": f"python scripts/shop_search.py login {provider.name}",
                }
            )
            continue
        items = provider.extract(text, limit=args.limit)
        results.extend(item.to_dict() for item in items)
        statuses.append(
            {"site": provider.name, "login_required": False, "count": len(items)}
        )
    return {"query": args.query, "results": results, "statuses": statuses}


def parse_sites(value: str) -> list[str]:
    sites = [site.strip().lower() for site in value.split(",") if site.strip()]
    return sites or supported_sites()


def save_cookie_from_stdin(config: RuntimeConfig, site: str) -> dict[str, Any]:
    cookie_header = sys.stdin.read().strip()
    if not cookie_header:
        raise ValueError("No cookie header received on stdin")
    config.cookie_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(config.cookie_dir, 0o700)
    cookie_path = config.cookie_file(site)
    cookie_path.write_text(cookie_header, encoding="utf-8")
    os.chmod(cookie_path, 0o600)
    return {"site": site, "cookie_saved": True, "path": str(cookie_path)}


if __name__ == "__main__":
    raise SystemExit(main())
