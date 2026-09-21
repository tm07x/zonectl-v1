import json
import os
import sqlite3
import subprocess
import sys
import tempfile

import pytest

ZONECTL = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "zonectl"))


def _run(args, db_path):
    env = os.environ.copy()
    env["ZONE_CAPTURE_DB"] = db_path
    result = subprocess.run(
        [sys.executable, ZONECTL] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    return result


def _make_db():
    tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
    con = sqlite3.connect(tmp.name)
    con.execute(
        """
        CREATE TABLE links (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            title TEXT,
            comment TEXT,
            source_app TEXT,
            kind TEXT NOT NULL DEFAULT 'url',
            capture_path TEXT,
            topic TEXT,
            created_at REAL NOT NULL
        );
        """
    )
    con.execute(
        "INSERT INTO links (url, title, source_app, kind, created_at) VALUES (?,?,?,?,?);",
        ("https://url.com", "URL Title", "Safari", "url", 1_700_000_000.0),
    )
    con.execute(
        "INSERT INTO links (url, title, source_app, kind, capture_path, created_at) VALUES (?,?,?,?,?,?);",
        (
            "https://page.com",
            "Page Title",
            "Safari",
            "capture",
            "/tmp/captures/page.md",
            1_700_000_001.0,
        ),
    )
    con.commit()
    con.close()
    return tmp.name


def test_list_shows_kind_and_capture_path():
    db = _make_db()
    result = _run(["list", "--limit", "10"], db)
    assert result.returncode == 0, result.stderr
    assert "url" in result.stdout
    assert "capture" in result.stdout
    assert "/tmp/captures/page.md" in result.stdout


def test_search_finds_by_title_and_shows_kind():
    db = _make_db()
    result = _run(["search", "Page Title"], db)
    assert result.returncode == 0, result.stderr
    assert "https://page.com" in result.stdout
    assert "capture" in result.stdout


def test_export_includes_capture_path():
    db = _make_db()
    result = _run(["export", "--format", "json"], db)
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert len(data) == 2
    capture = [r for r in data if r["kind"] == "capture"][0]
    assert capture["capture_path"] == "/tmp/captures/page.md"


def test_open_uses_capture_path_when_present(tmp_path):
    db = _make_db()
    target = tmp_path / "page.md"
    target.write_text("# captured\n", encoding="utf-8")

    con = sqlite3.connect(db)
    con.execute("UPDATE links SET capture_path = ? WHERE id = 2;", (str(target),))
    con.commit()
    con.close()

    env = os.environ.copy()
    env["ZONE_CAPTURE_DB"] = db
    env["ZONECTL_OPEN"] = "cat"
    result = subprocess.run(
        [sys.executable, ZONECTL, "open", "2"],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "# captured" in result.stdout


def test_open_falls_back_to_url_when_no_capture_path():
    db = _make_db()
    env = os.environ.copy()
    env["ZONE_CAPTURE_DB"] = db
    env["ZONECTL_OPEN"] = "echo"
    result = subprocess.run(
        [sys.executable, ZONECTL, "open", "1"],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "https://url.com" in result.stdout


def test_list_limit_zero_returns_no_rows():
    db = _make_db()
    result = _run(["list", "--limit", "0"], db)
    assert result.returncode == 0, result.stderr
    assert "https://url.com" not in result.stdout
    assert "https://page.com" not in result.stdout


def test_open_supports_opener_with_arguments():
    db = _make_db()
    env = os.environ.copy()
    env["ZONE_CAPTURE_DB"] = db
    env["ZONECTL_OPEN"] = "echo PREFIX"
    result = subprocess.run(
        [sys.executable, ZONECTL, "open", "1"],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith("PREFIX https://url.com")


def test_open_reports_opener_failure():
    db = _make_db()
    env = os.environ.copy()
    env["ZONE_CAPTURE_DB"] = db
    env["ZONECTL_OPEN"] = "false"
    result = subprocess.run(
        [sys.executable, ZONECTL, "open", "1"],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode != 0, "a failed opener must not exit 0"
    assert "error" in result.stderr.lower()
