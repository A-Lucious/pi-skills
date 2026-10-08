from shopping_aggregator.config import RuntimeConfig, parse_cookie_header


def test_parse_cookie_header_trims_and_skips_invalid_entries():
    assert parse_cookie_header(" a=1; bad; b = two ; empty= ") == {
        "a": "1",
        "b": "two",
        "empty": "",
    }


def test_runtime_config_prefers_environment_cookie(monkeypatch, tmp_path):
    monkeypatch.setenv("SHOPPING_AGGREGATOR_GOOFISH_COOKIE", "env_cookie=1")
    cookie_dir = tmp_path / "cookies"
    cookie_dir.mkdir()
    (cookie_dir / "goofish.txt").write_text("file_cookie=1", encoding="utf-8")
    config = RuntimeConfig(config_dir=tmp_path, data_dir=tmp_path / "data")
    assert config.cookie_header("goofish") == "env_cookie=1"


def test_runtime_config_reads_cookie_file_when_env_missing(monkeypatch, tmp_path):
    monkeypatch.delenv("SHOPPING_AGGREGATOR_JD_COOKIE", raising=False)
    cookie_dir = tmp_path / "cookies"
    cookie_dir.mkdir()
    (cookie_dir / "jd.txt").write_text(" jd_cookie=1\n", encoding="utf-8")
    config = RuntimeConfig(config_dir=tmp_path, data_dir=tmp_path / "data")
    assert config.cookie_header("jd") == "jd_cookie=1"
