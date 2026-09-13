from pathlib import Path
import importlib.util, json

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("zone_extract", HERE.parent / "zone_extract.py")
ze = importlib.util.module_from_spec(spec); spec.loader.exec_module(ze)

def _fixture_html():
    return (HERE / "fixtures" / "example.html").read_text(encoding="utf-8")

def test_extract_writes_md_and_json(tmp_path, monkeypatch):
    monkeypatch.setattr(ze, "fetch", lambda url, timeout=20: _fixture_html())
    result = ze.extract("https://example.com/page", str(tmp_path))
    md = Path(result["capture_path"]).read_text(encoding="utf-8")
    js = json.loads(Path(result["json_path"]).read_text(encoding="utf-8"))
    assert result["title"]
    assert "---\n" in md and "url:" in md
    assert "main content that matters" in md
    assert "Copyright Noise" not in md
    assert js["url"] == "https://example.com/page"
    assert js["markdown"] and "main content that matters" in js["markdown"]
    assert result["word_count"] > 0

def test_extract_error_is_raised(tmp_path, monkeypatch):
    def boom(url, timeout=20): raise RuntimeError("network down")
    monkeypatch.setattr(ze, "fetch", boom)
    try:
        ze.extract("https://x.io", str(tmp_path))
        assert False, "expected RuntimeError"
    except RuntimeError as e:
        assert "network down" in str(e)
