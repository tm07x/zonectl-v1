#!/usr/bin/env python3
"""zone_extract — fetch a URL, extract main content, write Markdown + JSON.

Contract (stdout, single JSON line):
  success -> {"capture_path","json_path","title","word_count"}
  failure -> {"error": "..."} and exit code 1
"""
import argparse, json, re, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse
import urllib.request

from lxml import html as lxml_html
from readability import Document
from markdownify import markdownify as md_to_markdown

MAX_BYTES = 10 * 1024 * 1024
ALLOWED_CONTENT_TYPES = {"text/html", "application/xhtml+xml", "text/plain"}
_META_CHARSET_RE = re.compile(
    rb"""charset\s*=\s*["']?\s*([A-Za-z0-9._-]+)""", re.IGNORECASE)


class _FetchedHTML(str):
    """String subclass carrying the post-redirect final URL."""

    def __new__(cls, text: str, final_url: str):
        obj = super().__new__(cls, text)
        obj.final_url = final_url
        return obj


def _validate_url(url: str) -> None:
    try:
        parsed = urlparse(url)
    except ValueError:
        raise ValueError("Invalid HTTP or HTTPS URL") from None
    if parsed.scheme not in ("http", "https"):
        raise ValueError("Only HTTP and HTTPS URLs are supported")
    if not parsed.hostname:
        raise ValueError("URL must include a host")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("URLs with credentials are not supported")


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            _validate_url(newurl)
            if (urlparse(req.full_url).scheme == "https"
                    and urlparse(newurl).scheme == "http"):
                raise ValueError("HTTPS to HTTP redirect is not allowed")
        except ValueError:
            fp.close()
            raise
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _validate_content_type(headers) -> None:
    if headers is None:
        return
    raw = headers.get("Content-Type")
    if not raw:
        return
    media_type = raw.split(";", 1)[0].strip().lower()
    if media_type and media_type not in ALLOWED_CONTENT_TYPES:
        raise ValueError(f"Unsupported content type: {media_type}")


def _detect_charset(body: bytes, headers) -> str:
    if body.startswith(b"\xef\xbb\xbf"):
        return "utf-8-sig"
    if body.startswith((b"\xff\xfe", b"\xfe\xff")):
        return "utf-16"
    if headers is not None:
        get_charset = getattr(headers, "get_content_charset", None)
        charset = get_charset() if callable(get_charset) else None
        if charset:
            return charset
    match = _META_CHARSET_RE.search(body[:1024])
    if match:
        return match.group(1).decode("ascii", errors="ignore")
    return "utf-8"


def _decode_body(body: bytes, headers) -> str:
    charset = _detect_charset(body, headers)
    try:
        return body.decode(charset, errors="replace")
    except LookupError:
        return body.decode("utf-8", errors="replace")


def fetch(url: str, timeout: int = 20) -> str:
    _validate_url(url)
    req = urllib.request.Request(
        url, headers={"User-Agent": "ZoneCapture/0.2 (+macOS)"})
    opener = urllib.request.build_opener(_SafeRedirectHandler())
    with opener.open(req, timeout=timeout) as r:
        headers = getattr(r, "headers", None)
        _validate_content_type(headers)
        body = r.read(MAX_BYTES + 1)
        if len(body) > MAX_BYTES:
            raise ValueError(f"Response exceeds maximum size of {MAX_BYTES} bytes")
        geturl = getattr(r, "geturl", None)
        final_url = geturl() if callable(geturl) else url
        return _FetchedHTML(_decode_body(body, headers), final_url=final_url or url)


def _resolve_relative_links(body_html: str, base_url: str) -> str:
    if not body_html or not base_url:
        return body_html
    try:
        fragment = lxml_html.fromstring(body_html)
    except Exception:
        return body_html
    for el in fragment.xpath(".//*[@href]"):
        href = (el.get("href") or "").strip()
        if not href or href.startswith("#"):
            continue
        resolved = urljoin(base_url, href)
        scheme = urlparse(resolved).scheme.lower()
        if scheme in ("http", "https", "mailto"):
            el.set("href", resolved)
        else:
            del el.attrib["href"]
    return lxml_html.tostring(fragment, encoding="unicode")


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s or "").strip().lower()
    return re.sub(r"[\s-]+", "-", s)[:60] or "page"


def extract(url: str, out_dir: str, timeout: int = 20) -> dict:
    html = fetch(url, timeout=timeout)
    final_url = getattr(html, "final_url", url) or url
    doc = Document(html, url=final_url)
    title = doc.short_title() or doc.title() or url
    body_html = _resolve_relative_links(doc.summary(html_partial=True), final_url)
    markdown = md_to_markdown(body_html, heading_style="ATX").strip()
    word_count = len(markdown.split())
    if word_count == 0:
        raise ValueError("No readable content extracted from page")
    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    host = urlparse(final_url).netloc or urlparse(url).netloc
    base = f"{now[:10]}-{slugify(title)}-{uuid.uuid4().hex[:6]}"
    md_path = Path(out_dir) / f"{base}.md"
    json_path = Path(out_dir) / f"{base}.json"
    frontmatter_lines = [
        "---",
        f"title: {json.dumps(title)}",
        f"url: {json.dumps(url)}",
    ]
    if final_url != url:
        frontmatter_lines.append(f"final_url: {json.dumps(final_url)}")
    frontmatter_lines.extend([
        f"site: {json.dumps(host)}",
        f"captured_at: {now}",
        f"word_count: {word_count}",
        "---",
        "",
        "",
    ])
    frontmatter = "\n".join(frontmatter_lines)
    sidecar = {
        "title": title, "url": url, "site": host,
        "captured_at": now, "word_count": word_count, "markdown": markdown,
    }
    if final_url != url:
        sidecar["final_url"] = final_url
    md_path.write_text(frontmatter + markdown + "\n", encoding="utf-8")
    json_path.write_text(json.dumps(sidecar, ensure_ascii=False, indent=2), encoding="utf-8")
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
        result = extract(args.url, args.out, timeout=args.timeout)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
