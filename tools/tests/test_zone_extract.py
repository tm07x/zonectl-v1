from pathlib import Path
import importlib.util, json
import io
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

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


class _FakeResponse(io.BytesIO):
    def __init__(self, body):
        super().__init__(body)
        self.read_sizes = []

    def read(self, n=-1):
        self.read_sizes.append(n)
        return super().read(n)


def _stub_response(monkeypatch, response):
    open_response = Mock(return_value=response)
    monkeypatch.setattr(ze.urllib.request, "urlopen", open_response)
    monkeypatch.setattr(
        ze.urllib.request, "build_opener",
        lambda *handlers: SimpleNamespace(open=open_response))
    return open_response


@pytest.mark.parametrize("size", [1023, 1024])
def test_fetch_accepts_responses_through_limit_and_closes_them(monkeypatch, size):
    monkeypatch.setattr(ze, "MAX_BYTES", 1024)
    body = b"x" * (size - 2) + "\u00e9".encode("utf-8")
    response = _FakeResponse(body)
    _stub_response(monkeypatch, response)

    assert ze.fetch("https://example.com/page") == body.decode("utf-8")
    assert response.read_sizes == [1025]
    assert response.closed


@pytest.mark.parametrize("size", [1025, 5000])
def test_fetch_rejects_oversized_responses(monkeypatch, size):
    monkeypatch.setattr(ze, "MAX_BYTES", 1024)
    response = _FakeResponse(b"x" * size)
    _stub_response(monkeypatch, response)

    with pytest.raises(ValueError, match="1024 bytes"):
        ze.fetch("https://example.com/big")
    assert response.read_sizes == [1025]
    assert response.closed


def test_fetch_closes_response_on_read_failure(monkeypatch):
    class BrokenResponse(_FakeResponse):
        def read(self, n=-1):
            raise OSError("read failed")

    response = BrokenResponse(b"")
    _stub_response(monkeypatch, response)

    with pytest.raises(OSError, match="read failed"):
        ze.fetch("https://example.com/page")
    assert response.closed


def test_extract_passes_timeout_to_fetch(tmp_path, monkeypatch):
    fetch = Mock(return_value=_fixture_html())
    monkeypatch.setattr(ze, "fetch", fetch)

    ze.extract("https://example.com/page", str(tmp_path), timeout=7)

    fetch.assert_called_once_with("https://example.com/page", timeout=7)


@pytest.mark.parametrize("options, timeout", [([], 20), (["--timeout", "7"], 7)])
def test_cli_timeout_reaches_http_open(tmp_path, monkeypatch, capsys, options, timeout):
    response = _FakeResponse(_fixture_html().encode("utf-8"))
    open_response = _stub_response(monkeypatch, response)
    out_dir = tmp_path / "captures"
    monkeypatch.setattr(sys, "argv", [
        "zone_extract.py", "https://example.com/page", "--out", str(out_dir),
        *options])

    ze.main()

    open_response.assert_called_once()
    assert open_response.call_args.kwargs == {"timeout": timeout}
    assert open_response.call_args.args[0].full_url == "https://example.com/page"
    captured = capsys.readouterr()
    assert captured.err == ""
    result = json.loads(captured.out)
    assert Path(result["capture_path"]).is_file()
    assert Path(result["json_path"]).is_file()
    assert response.closed


def test_cli_reports_oversized_response_without_writing_capture(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(ze, "MAX_BYTES", 1024)
    response = _FakeResponse(b"x" * 1025)
    _stub_response(monkeypatch, response)
    out_dir = tmp_path / "captures"
    monkeypatch.setattr(sys, "argv", [
        "zone_extract.py", "https://example.com/big", "--out", str(out_dir)])

    with pytest.raises(SystemExit) as exc:
        ze.main()

    assert exc.value.code == 1
    captured = capsys.readouterr()
    assert captured.err == ""
    assert "1024 bytes" in json.loads(captured.out)["error"]
    assert list(out_dir.iterdir()) == []
    assert response.read_sizes == [1025]
    assert response.closed


@pytest.mark.parametrize("url, error", [
    ("file:///unsafe.html", "HTTP"),
    ("data:text/html,unsafe", "HTTP"),
    ("ftp://example.com/page", "HTTP"),
    ("javascript:alert(1)", "HTTP"),
    ("//example.com/page", "HTTP"),
    ("example.com/page", "HTTP"),
    ("https:///page", "host"),
    ("http://:80/page", "host"),
    ("https://?query=1", "host"),
    ("http://user:pass@example.com/page", "credentials"),
    ("https://user@example.com/page", "credentials"),
    ("https://:pass@example.com/page", "credentials"),
    ("https://@example.com/page", "credentials"),
])
def test_fetch_rejects_unsafe_urls_before_opening(monkeypatch, url, error):
    def unexpected_open(*args, **kwargs):
        pytest.fail("unsafe URL reached the transport")

    monkeypatch.setattr(ze.urllib.request, "urlopen", unexpected_open)
    monkeypatch.setattr(ze.urllib.request, "build_opener", unexpected_open)

    with pytest.raises(ValueError, match=error):
        ze.fetch(url)


@pytest.fixture
def local_page_server(monkeypatch):
    monkeypatch.setenv("no_proxy", "*")
    monkeypatch.setenv("NO_PROXY", "*")
    state = {"requests": [], "location": "/target"}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            state["requests"].append(self.path)
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", state["location"])
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = _fixture_html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}", state
        finally:
            server.shutdown()
            thread.join()


@pytest.mark.parametrize("target, error", [
    ("http://user:pass@{host}/target", "credentials"),
    ("http://user@{host}/target", "credentials"),
    ("http://@{host}/target", "credentials"),
    ("ftp://{host}/target", "HTTP"),
])
def test_fetch_rejects_unsafe_redirects_before_target_connection(
        monkeypatch, local_page_server, target, error):
    base_url, state = local_page_server
    state["location"] = target.format(host=base_url.removeprefix("http://"))
    create_connection = socket.create_connection
    attempts = []

    def connect_once(address, *args, **kwargs):
        attempts.append(address)
        assert len(attempts) == 1, "unsafe redirect attempted a target connection"
        assert address == ("127.0.0.1", int(base_url.rsplit(":", 1)[1]))
        return create_connection(address, *args, **kwargs)

    monkeypatch.setattr(socket, "create_connection", connect_once)

    with pytest.raises(ValueError, match=error):
        ze.fetch(f"{base_url}/redirect", timeout=2)
    assert len(attempts) == 1
    assert state["requests"] == ["/redirect"]


@pytest.mark.parametrize("relative", [False, True])
def test_fetch_follows_safe_redirects(local_page_server, relative):
    base_url, state = local_page_server
    state["location"] = "/target" if relative else f"{base_url}/target"

    assert ze.fetch(f"{base_url}/redirect", timeout=2) == _fixture_html()
    assert state["requests"] == ["/redirect", "/target"]
