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


@pytest.mark.parametrize("existing_parent", [False, True])
def test_db_prints_missing_override_path_without_creating_database(tmp_path, existing_parent):
    db = tmp_path / "data" / "zonecapture.db"
    if existing_parent:
        db.parent.mkdir()

    result = _run(["db"], str(db))

    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{db}\n"
    assert result.stderr == ""
    assert not db.exists()
    assert db.parent.exists() == existing_parent


@pytest.mark.parametrize("existing_parent", [False, True])
def test_db_discovers_fresh_home_path_without_creating_database(tmp_path, existing_parent):
    db = tmp_path / "Library" / "Application Support" / "ZoneCapture" / "zonecapture.db"
    if existing_parent:
        db.parent.mkdir(parents=True)
    env = os.environ.copy()
    env.pop("ZONE_CAPTURE_DB", None)
    env["HOME"] = str(tmp_path)

    result = subprocess.run(
        [sys.executable, ZONECTL, "db"], capture_output=True, text=True, env=env)

    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{db}\n"
    assert result.stderr == ""
    assert not db.exists()
    assert db.parent.exists() == existing_parent


@pytest.mark.parametrize("args", [["list"], ["search", "query"], ["export"], ["open", "1"]])
def test_read_commands_report_missing_database_without_creating_it(tmp_path, args):
    db = tmp_path / "zonecapture.db"

    result = _run(args, str(db))

    assert result.returncode == 1
    assert result.stdout == ""
    assert f"database not found at {db}" in result.stderr
    assert not db.exists()


def test_db_respects_zone_capture_root_when_db_unset(tmp_path):
    env = os.environ.copy()
    env.pop("ZONE_CAPTURE_DB", None)
    env["ZONE_CAPTURE_ROOT"] = str(tmp_path)

    result = subprocess.run(
        [sys.executable, ZONECTL, "db"], capture_output=True, text=True, env=env)

    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{tmp_path / 'zonecapture.db'}\n"


def test_open_refuses_note_without_url_or_capture_path():
    db = _make_db()
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO links (url, title, comment, source_app, kind, created_at) VALUES (?,?,?,?,?,?);",
        ("(no url — note from Terminal)", None, "remember this", "Terminal", "note", 1_700_000_002.0),
    )
    con.commit()
    con.close()

    env = os.environ.copy()
    env["ZONE_CAPTURE_DB"] = db
    env["ZONECTL_OPEN"] = "echo"
    result = subprocess.run(
        [sys.executable, ZONECTL, "open", "3"], capture_output=True, text=True, env=env)

    assert result.returncode != 0
    assert "note with no URL or file" in result.stderr


def test_open_handles_empty_zonectl_open_env_without_index_error():
    db = _make_db()
    env = os.environ.copy()
    env["ZONE_CAPTURE_DB"] = db
    env["ZONECTL_OPEN"] = ""
    env["PATH"] = ""  # ensures default 'open' isn't found, testing FileNotFoundError path cleanly
    result = subprocess.run(
        [sys.executable, ZONECTL, "open", "1"], capture_output=True, text=True, env=env)

    assert result.returncode != 0
    assert "IndexError" not in result.stderr
    assert "opener not found: open" in result.stderr


def test_search_escapes_like_wildcards_and_matches_topic():
    db = _make_db()
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO links (url, title, comment, source_app, kind, topic, created_at) VALUES (?,?,?,?,?,?,?);",
        ("https://metrics.example", "100% CPU", "check_load", "Safari", "url", "linux-kernels", 1_700_000_003.0),
    )
    con.commit()
    con.close()

    # Wildcard '%' must not match everything.
    pct = _run(["search", "%"], db)
    assert pct.returncode == 0
    assert "https://metrics.example" in pct.stdout
    assert "https://url.com" not in pct.stdout

    # Topic search works.
    topic = _run(["search", "linux-kernels"], db)
    assert topic.returncode == 0
    assert "https://metrics.example" in topic.stdout


def test_export_md_formats_notes_and_includes_capture_path():
    db = _make_db()
    con = sqlite3.connect(db)
    con.execute(
        "INSERT INTO links (url, title, comment, source_app, kind, topic, created_at) VALUES (?,?,?,?,?,?,?);",
        ("(no url — note from Terminal)", None, "kernel idea", "Terminal", "note", "systems", 1_700_000_004.0),
    )
    con.commit()
    con.close()

    result = _run(["export", "--format", "md"], db)
    assert result.returncode == 0, result.stderr
    assert "[(no url" not in result.stdout
    assert "- (no url — note from Terminal) `[systems]`" in result.stdout
    assert "/tmp/captures/page.md" in result.stdout
