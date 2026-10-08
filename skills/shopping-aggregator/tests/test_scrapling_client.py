import types

from shopping_aggregator.config import RuntimeConfig
from shopping_aggregator.providers import get_provider
from shopping_aggregator.scrapling_client import ScraplingBrowserClient


class FakeSession:
    captured_kwargs = None

    def __init__(self, **kwargs):
        FakeSession.captured_kwargs = kwargs

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def fetch(self, url):
        return "<html>ok</html>"


def test_scrapling_client_does_not_require_real_chrome_by_default(
    monkeypatch, tmp_path
):
    fake_module = types.SimpleNamespace(StealthySession=FakeSession)
    monkeypatch.setattr(
        "shopping_aggregator.scrapling_client.importlib.import_module",
        lambda name: fake_module,
    )
    client = ScraplingBrowserClient(
        RuntimeConfig(config_dir=tmp_path, data_dir=tmp_path / "data")
    )

    client.fetch_text(get_provider("jd"), "相机", limit=1)

    assert FakeSession.captured_kwargs is not None
    assert FakeSession.captured_kwargs.get("real_chrome") is not True
