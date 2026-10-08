from shopping_aggregator.config import RuntimeConfig
from shopping_aggregator.providers import get_provider
from shopping_aggregator.scrapling_client import ScraplingBrowserClient


def test_browser_cookies_are_playwright_cookie_list(tmp_path):
    cookie_dir = tmp_path / "cookies"
    cookie_dir.mkdir()
    (cookie_dir / "jd.txt").write_text("a=1; b=two", encoding="utf-8")
    client = ScraplingBrowserClient(
        RuntimeConfig(config_dir=tmp_path, data_dir=tmp_path / "data")
    )

    cookies = client._browser_cookies(get_provider("jd"))

    assert cookies == [
        {"name": "a", "value": "1", "domain": ".jd.com", "path": "/"},
        {"name": "b", "value": "two", "domain": ".jd.com", "path": "/"},
    ]
