from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote_plus

from .models import ProductResult

LOGIN_MARKERS = (
    "请登录",
    "登录后继续",
    "passport.jd.com",
    "欢迎登录",
    "京东-欢迎登录",
    "扫码登录",
    "安全验证",
    "验证身份",
)

TAG_RE = re.compile(r"<[^>]+>")
JSON_OBJECT_RE = re.compile(r"\{[^{}]*(?:title|itemTitle|raw_title|name)[^{}]*\}", re.I)
JD_REACT_CARD_RE = re.compile(
    r'data-sku="(?P<sku>\d+)"(?P<body>.*?)(?=data-sku="\d+"|</body>|$)', re.S
)
TAOBAO_TITLE_RE = re.compile(
    r'<div class="[^"]*title--[^"]*" title="(?P<title>[^"]+)"',
    re.S,
)
GOOFISH_CARD_RE = re.compile(
    r'<a class="[^"]*feeds-item-wrap[^"]*" href="(?P<url>[^"]+)"(?P<body>.*?)(?=<a class="[^"]*feeds-item-wrap|</body>|$)',
    re.S,
)


def clean_text(value: str | None) -> str:
    if not value:
        return ""
    text = html.unescape(TAG_RE.sub("", value))
    return re.sub(r"\s+", " ", text).strip()


def normalize_url(value: str | None, default_scheme: str = "https:") -> str:
    if not value:
        return ""
    value = html.unescape(value).strip()
    if value.startswith("//"):
        return f"{default_scheme}{value}"
    if value.startswith(("http://", "https://")):
        return value
    if value.startswith("/"):
        return f"https://www.jd.com{value}"
    return value


def first_text(mapping: dict[str, Any], keys: tuple[str, ...]) -> str:
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, (str, int, float)):
            text = clean_text(str(value))
            if text:
                return text
    return ""


def first_regex(pattern: str, text: str) -> str:
    match = re.search(pattern, text, re.S)
    if not match:
        return ""
    return clean_text(match.group(1))


@dataclass(frozen=True)
class ShoppingProvider:
    name: str
    display_name: str
    search_url_template: str
    login_url: str
    card_patterns: tuple[re.Pattern[str], ...]
    login_markers: tuple[str, ...] = LOGIN_MARKERS

    def search_url(self, query: str, page: int = 1) -> str:
        return self.search_url_template.format(query=quote_plus(query), page=page)

    def login_required(self, text: str) -> bool:
        if "site-nav-status-login" in text or "userid=" in text:
            return False
        return any(marker in text for marker in self.login_markers)

    def extract(self, text: str, limit: int = 20) -> list[ProductResult]:
        modern_items = self._extract_modern_cards(text)
        if len(modern_items) >= limit:
            return dedupe(modern_items)[:limit]
        items = (
            modern_items + self._extract_cards(text) + self._extract_json_objects(text)
        )
        return dedupe(items)[:limit]

    def _extract_cards(self, text: str) -> list[ProductResult]:
        results: list[ProductResult] = []
        for pattern in self.card_patterns:
            for match in pattern.finditer(text):
                data = match.groupdict()
                title = clean_text(data.get("title") or data.get("title_alt"))
                url = normalize_url(data.get("url"))
                if not title or not url:
                    continue
                results.append(
                    ProductResult(
                        site=self.name,
                        title=title,
                        url=url,
                        price=clean_text(data.get("price")) or None,
                        shop=clean_text(data.get("shop")) or None,
                    )
                )
        return results

    def _extract_modern_cards(self, text: str) -> list[ProductResult]:
        if self.name == "jd":
            return self._extract_jd_react_cards(text)
        if self.name == "taobao":
            return self._extract_taobao_2025_cards(text)
        if self.name == "goofish":
            return self._extract_goofish_feeds_cards(text)
        return []

    def _extract_jd_react_cards(self, text: str) -> list[ProductResult]:
        results: list[ProductResult] = []
        for match in JD_REACT_CARD_RE.finditer(text):
            sku = match.group("sku")
            body = match.group("body")
            title = first_regex(
                r'<span title="([^"]+)" class="[^"]*_newStyle_[^"]*"', body
            )
            if not title:
                title = first_regex(
                    r'<div class="[^"]*_wrapper_o085i_[^"]*" title="([^"]+)"', body
                )
            if not title:
                continue
            price = self._extract_jd_price(body)
            shop = first_regex(
                r'<span class="[^"]*_limit_zclqt_[^"]*"[^>]*>(.*?)</span>', body
            )
            image = normalize_url(first_regex(r'<img[^>]+src="([^"]+)"', body)) or None
            results.append(
                ProductResult(
                    site=self.name,
                    title=title,
                    url=f"https://item.jd.com/{sku}.html",
                    price=price or None,
                    shop=shop or None,
                    image=image,
                    raw={"sku": sku},
                )
            )
        return results

    @staticmethod
    def _extract_jd_price(body: str) -> str:
        marker = re.search(r'<span class="[^"]*_price_[^"]*"', body)
        if not marker:
            return ""
        price_area = body[marker.start() : marker.start() + 800]
        price_area = price_area.split("_subsidy_", 1)[0]
        price_area = price_area.split("_limit_zclqt_", 1)[0]
        text = clean_text(price_area).replace("¥", "")
        match = re.search(r"\d+(?:\.\d+)?", text)
        return match.group(0) if match else ""

    def _extract_goofish_feeds_cards(self, text: str) -> list[ProductResult]:
        results: list[ProductResult] = []
        for match in GOOFISH_CARD_RE.finditer(text):
            body = match.group("body")
            title = first_regex(
                r'<div class="[^"]*row1-wrap-title[^"]*" title="([^"]+)"', body
            )
            if not title:
                continue
            price_int = first_regex(
                r'<span class="[^"]*number--[^"]*"[^>]*>(.*?)</span>', body
            )
            price_decimal = first_regex(
                r'<span class="[^"]*decimal--[^"]*"[^>]*>(.*?)</span>', body
            )
            location = first_regex(
                r'<div class="[^"]*seller-text-wrap[^"]*" title="([^"]+)"', body
            )
            image = (
                normalize_url(
                    first_regex(
                        r'<img class="[^"]*feeds-image[^"]*" src="([^"]+)"', body
                    )
                )
                or None
            )
            results.append(
                ProductResult(
                    site=self.name,
                    title=title,
                    url=normalize_url(match.group("url")),
                    price=f"{price_int}{price_decimal}" if price_int else None,
                    location=location or None,
                    image=image,
                )
            )
        return results

    def _extract_taobao_2025_cards(self, text: str) -> list[ProductResult]:
        results: list[ProductResult] = []
        for index, match in enumerate(TAOBAO_TITLE_RE.finditer(text), start=1):
            title = clean_text(match.group("title"))
            body = text[match.end() : match.end() + 5000]
            if not title or len(title) < 4:
                continue
            price_int = first_regex(
                r'<div class="[^"]*priceInt--[^"]*"[^>]*>(.*?)</div>', body
            )
            price_float = first_regex(
                r'<div class="[^"]*priceFloat--[^"]*"[^>]*>(.*?)</div>', body
            )
            price = f"{price_int}{price_float}" if price_int else ""
            locations = re.findall(
                r'<div class="[^"]*procity--[^"]*"[^>]*><span>(.*?)</span></div>',
                body,
                re.S,
            )
            location = " ".join(
                clean_text(part) for part in locations if clean_text(part)
            )
            shop = first_regex(
                r'<[^>]+class="[^"]*shopName--[^"]*"[^>]*>(.*?)</[^>]+>', body
            )
            results.append(
                ProductResult(
                    site=self.name,
                    title=title,
                    url=f"https://s.taobao.com/search?q={quote_plus(title)}#result-{index}",
                    price=price or None,
                    shop=shop or None,
                    location=location or None,
                )
            )
        return results

    def _extract_json_objects(self, text: str) -> list[ProductResult]:
        results: list[ProductResult] = []
        for match in JSON_OBJECT_RE.finditer(text):
            try:
                data = json.loads(match.group(0))
            except json.JSONDecodeError:
                continue
            title = first_text(
                data, ("title", "itemTitle", "raw_title", "name", "shortTitle")
            )
            url = normalize_url(
                first_text(data, ("itemUrl", "url", "auctionURL", "detail_url", "link"))
            )
            if not title:
                continue
            results.append(
                ProductResult(
                    site=self.name,
                    title=title,
                    url=url or self.search_url(title),
                    price=first_text(
                        data, ("price", "reservePrice", "salePrice", "view_price")
                    )
                    or None,
                    shop=first_text(data, ("nick", "shop", "shopName", "seller"))
                    or None,
                    location=first_text(data, ("location", "itemLocation", "procity"))
                    or None,
                    image=normalize_url(first_text(data, ("picUrl", "image", "img")))
                    or None,
                    raw={
                        key: data[key]
                        for key in sorted(data)
                        if key in {"id", "itemId", "nid"}
                    },
                )
            )
        return results


def dedupe(items: list[ProductResult]) -> list[ProductResult]:
    seen: set[tuple[str, str, str]] = set()
    unique: list[ProductResult] = []
    for item in items:
        key = (item.site, item.url, item.title)
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
    return unique


PROVIDERS: dict[str, ShoppingProvider] = {
    "jd": ShoppingProvider(
        name="jd",
        display_name="京东",
        search_url_template="https://search.jd.com/Search?keyword={query}&enc=utf-8&page={page}",
        login_url="https://passport.jd.com/new/login.aspx",
        card_patterns=(
            re.compile(
                r'<div[^>]+class="[^"]*gl-i-wrap[^"]*"[^>]*>.*?'
                r'<a[^>]+href="(?P<url>[^"]+)"[^>]*>.*?'
                r"<em[^>]*>(?P<title>.*?)</em>.*?"
                r"<strong[^>]*>.*?<i[^>]*>(?P<price>.*?)</i>.*?</strong>"
                r'(?:.*?<span[^>]+class="[^"]*curr-shop[^"]*"[^>]*>(?P<shop>.*?)</span>)?',
                re.S,
            ),
        ),
    ),
    "goofish": ShoppingProvider(
        name="goofish",
        display_name="闲鱼",
        search_url_template="https://www.goofish.com/search?q={query}&page={page}",
        login_url="https://www.goofish.com/",
        card_patterns=(
            re.compile(
                r'<a[^>]+href="(?P<url>[^"]*goofish[^"]*)"[^>]*>.*?'
                r"(?:<[^>]+>)*(?P<title>[^<]{2,80})(?:</[^>]+>).*?"
                r"(?:¥|￥)\s*(?P<price>[\d.]+)",
                re.S,
            ),
        ),
    ),
    "taobao": ShoppingProvider(
        name="taobao",
        display_name="淘宝",
        search_url_template="https://s.taobao.com/search?page={page}&q={query}&tab=all",
        login_url="https://login.taobao.com/",
        card_patterns=(
            re.compile(
                r'<a[^>]+href="(?P<url>[^"]*(?:item\.taobao|detail\.tmall)[^"]*)"[^>]*>.*?'
                r'(?:title="(?P<title>[^"]+)"|<[^>]+class="[^"]*title[^"]*"[^>]*>(?P<title_alt>.*?)</[^>]+>).*?'
                r"(?:¥|￥)\s*(?P<price>[\d.]+)",
                re.S,
            ),
        ),
    ),
}


def get_provider(site: str) -> ShoppingProvider:
    key = site.strip().lower()
    if key not in PROVIDERS:
        supported = ", ".join(sorted(PROVIDERS))
        raise ValueError(f"Unsupported site '{site}'. Supported sites: {supported}")
    return PROVIDERS[key]


def supported_sites() -> list[str]:
    return sorted(PROVIDERS)
