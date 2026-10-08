from shopping_aggregator.config import RuntimeConfig
from shopping_aggregator.providers import get_provider
from shopping_aggregator.scrapling_client import ScraplingBrowserClient


class BodyOnlyPage:
    text = ""
    body = "<!DOCTYPE html><title>京东-欢迎登录</title>".encode()


def test_page_text_falls_back_to_decoded_body_when_text_is_empty(tmp_path):
    client = ScraplingBrowserClient(
        RuntimeConfig(config_dir=tmp_path, data_dir=tmp_path / "data")
    )
    assert "欢迎登录" in client._page_text(BodyOnlyPage())


def test_jd_login_page_body_is_login_required():
    provider = get_provider("jd")
    assert (
        provider.login_required("<!DOCTYPE html><title>京东-欢迎登录</title>") is True
    )
