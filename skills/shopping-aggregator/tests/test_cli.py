import json

from shopping_aggregator.cli import main


class FakeBrowserClient:
    def fetch_text(self, provider, query, limit, screenshot=False, headed=False):
        return '<div class="gl-i-wrap"><a href="//item.jd.com/123.html"><em>相机</em></a><strong><i>1999</i></strong></div>'

    def check_login(self, provider):
        return True


def test_search_outputs_normalized_json(capsys, tmp_path):
    exit_code = main(
        ["search", "相机", "--sites", "jd", "--limit", "1"],
        client=FakeBrowserClient(),
        config_dir=tmp_path,
        data_dir=tmp_path / "data",
    )
    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["query"] == "相机"
    assert payload["results"][0]["site"] == "jd"
    assert payload["results"][0]["title"] == "相机"


def test_check_login_outputs_status_json(capsys, tmp_path):
    exit_code = main(
        ["check-login", "jd"],
        client=FakeBrowserClient(),
        config_dir=tmp_path,
        data_dir=tmp_path / "data",
    )
    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload == {"site": "jd", "logged_in": True}
