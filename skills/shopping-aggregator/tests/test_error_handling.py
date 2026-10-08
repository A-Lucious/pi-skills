import json

from shopping_aggregator.cli import main


class FailingBrowserClient:
    def fetch_text(self, provider, query, limit, screenshot=False, headed=False):
        raise TimeoutError("navigation timed out")


def test_search_reports_provider_error_without_crashing(capsys, tmp_path):
    exit_code = main(
        ["search", "相机", "--sites", "taobao", "--limit", "1"],
        client=FailingBrowserClient(),
        config_dir=tmp_path,
        data_dir=tmp_path / "data",
    )
    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["results"] == []
    assert payload["statuses"] == [
        {"site": "taobao", "login_required": None, "error": "navigation timed out"}
    ]
