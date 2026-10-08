from shopping_aggregator.cli import main


def test_save_cookie_stdin_writes_user_only_file(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr("sys.stdin.read", lambda: " a=1; b=2 \n")

    exit_code = main(
        ["save-cookie", "jd", "--stdin"],
        config_dir=tmp_path,
        data_dir=tmp_path / "data",
    )

    cookie_file = tmp_path / "cookies" / "jd.txt"
    assert exit_code == 0
    assert cookie_file.read_text(encoding="utf-8") == "a=1; b=2"
    assert oct(cookie_file.stat().st_mode & 0o777) == "0o600"
    assert "cookie_saved" in capsys.readouterr().out
