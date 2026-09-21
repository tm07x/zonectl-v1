#!/usr/bin/env python3
"""zone_extract — fetch a URL, extract main content, write Markdown + JSON.

Contract (stdout, single JSON line):
  success -> {"capture_path","json_path","title","word_count"}
  failure -> {"error": "..."} and exit code 1
"""
import argparse, json, re, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
import urllib.request

from readability import Document
from markdownify import markdownify as md_to_markdown

# Responses larger than this are truncated rather than buffered whole: an
# unbounded read() lets one huge page balloon memory and produce a giant
# capture file.
MAX_BYTES = 10 * 1024 * 1024


def fetch(url: str, timeout: int = 20) -> str:
    req = urllib.request.Request(
        url, headers={"User-Agent": "ZoneCapture/0.1 (+macOS)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(MAX_BYTES + 1)[:MAX_BYTES].decode("utf-8", errors="replace")


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s or "").strip().lower()
    return re.sub(r"[\s-]+", "-", s)[:60] or "page"


def extract(url: str, out_dir: str) -> dict:
    html = fetch(url)
    doc = Document(html)
    title = doc.short_title() or doc.title() or url
    body_html = doc.summary(html_partial=True)
    markdown = md_to_markdown(body_html, heading_style="ATX").strip()
    word_count = len(markdown.split())
    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    host = urlparse(url).netloc
    base = f"{now[:10]}-{slugify(title)}-{uuid.uuid4().hex[:6]}"
    md_path = Path(out_dir) / f"{base}.md"
    json_path = Path(out_dir) / f"{base}.json"
    frontmatter = (
        "---\n"
        f"title: {json.dumps(title)}\n"
        f"url: {json.dumps(url)}\n"
        f"site: {json.dumps(host)}\n"
        f"captured_at: {now}\n"
        f"word_count: {word_count}\n"
        "---\n\n"
    )
    md_path.write_text(frontmatter + markdown + "\n", encoding="utf-8")
    json_path.write_text(json.dumps({
        "title": title, "url": url, "site": host,
        "captured_at": now, "word_count": word_count, "markdown": markdown,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"capture_path": str(md_path), "json_path": str(json_path),
            "title": title, "word_count": word_count}


def main() -> None:
    ap = argparse.ArgumentParser(description="Extract a page to Markdown.")
    ap.add_argument("url")
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=20)
    args = ap.parse_args()
    Path(args.out).mkdir(parents=True, exist_ok=True)
    try:
        result = extract(args.url, args.out)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
