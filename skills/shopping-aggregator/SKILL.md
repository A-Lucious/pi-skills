---
name: shopping-aggregator
description: Use when searching products, comparing shopping listings, building product shortlists, checking logged-in shopping pages, or capturing diagnostics from Goofish/Xianyu, Taobao, and JD with Scrapling-backed browser sessions.
---

# Shopping Aggregator

## Overview

Search Goofish/Xianyu, Taobao, and JD through a local Python CLI that uses Scrapling browser sessions, user-level cookies, persistent profiles, and screenshots for login diagnostics.

Use this for personal shopping research and authenticated browsing assistance. Do not use it for bulk crawling, credential dumping, captcha solving beyond normal Scrapling behavior, or actions that violate site terms.

## One-Time Setup

Create or reuse a user-level virtual environment so future skills do not recreate dependencies:

```bash
python -m venv ~/.venvs/shopping-aggregator
~/.venvs/shopping-aggregator/bin/python -m pip install -r /home/lucious/tmp/shopping-aggregator-skill/requirements.txt
~/.venvs/shopping-aggregator/bin/python -m playwright install chromium
```

If an existing Scrapling environment is preferred, use its Python binary instead of `~/.venvs/shopping-aggregator/bin/python`.

## Cookie Storage

Never paste cookie values into prompts, code, command arguments, or skill files. Save each cookie header through stdin so it does not appear in shell history:

```bash
cd /home/lucious/tmp/shopping-aggregator-skill
read -rs GOOFISH_COOKIE && printf '%s' "$GOOFISH_COOKIE" | ~/.venvs/shopping-aggregator/bin/python scripts/shop_search.py save-cookie goofish --stdin
read -rs TAOBAO_COOKIE && printf '%s' "$TAOBAO_COOKIE" | ~/.venvs/shopping-aggregator/bin/python scripts/shop_search.py save-cookie taobao --stdin
read -rs JD_COOKIE && printf '%s' "$JD_COOKIE" | ~/.venvs/shopping-aggregator/bin/python scripts/shop_search.py save-cookie jd --stdin
```

The command writes `0600` files under `~/.config/shopping-aggregator/cookies/`.

Environment variables override files when set:

- `SHOPPING_AGGREGATOR_GOOFISH_COOKIE`
- `SHOPPING_AGGREGATOR_TAOBAO_COOKIE`
- `SHOPPING_AGGREGATOR_JD_COOKIE`

## Search Products

```bash
cd /home/lucious/tmp/shopping-aggregator-skill
~/.venvs/shopping-aggregator/bin/python scripts/shop_search.py search '机械键盘' --sites goofish,taobao,jd --limit 10
```

Useful options:

- `--sites goofish,jd` limits platforms.
- `--screenshot` captures diagnostic screenshots while fetching.
- `--headed` opens a visible browser for risk-control troubleshooting.

The command prints normalized JSON with `query`, `results`, and per-site `statuses`. If a platform needs login, the status includes a repair command.

## Login Checks and Repair

Check one site:

```bash
~/.venvs/shopping-aggregator/bin/python scripts/shop_search.py check-login jd
```

When login expires, try minimal manual repair:

```bash
~/.venvs/shopping-aggregator/bin/python scripts/shop_search.py login goofish --wait-seconds 120
```

This opens a headed browser, lets the user complete QR/password login, and keeps the browser profile under `~/.local/share/shopping-aggregator/profiles/<site>/` for future runs.

## Screenshots

Capture the current rendered search page:

```bash
~/.venvs/shopping-aggregator/bin/python scripts/shop_search.py screenshot taobao --query '相机' --headed
```

Screenshots are stored under `~/.local/share/shopping-aggregator/screenshots/`. Use screenshots when login state is unclear, a selector stops working, or the site shows risk-control pages.

## Provider Notes

| Site | URL strategy | Login behavior |
| --- | --- | --- |
| `goofish` | `https://www.goofish.com/search?q=...`; extracts embedded JSON first, then cards | Often requires valid Taobao-family cookies and may show virtual lists |
| `taobao` | `https://s.taobao.com/search?q=...`; browser-rendered extraction | Ajax signatures are fragile; prefer Scrapling rendered page |
| `jd` | `https://search.jd.com/Search?keyword=...`; HTML cards when available | Cookies/profile improve location, price, and account-specific visibility |

## Failure Handling

1. Re-run with `--screenshot` and inspect the status JSON.
2. If `login_required` appears, run `login <site>` with a headed browser.
3. If Scrapling is missing, run the setup commands again in the selected venv.
4. If a site changes markup, update `src/shopping_aggregator/providers.py` selector or JSON-key mappings and rerun tests.

## Local Development Checks

```bash
cd /home/lucious/tmp/shopping-aggregator-skill
PYTHONPATH=src python -m pytest -q
python -m compileall src scripts tests
```
