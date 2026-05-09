#!/usr/bin/env python3
"""Mirror Unitree G1 markdown docs into a local, agent-friendly tree."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import mimetypes
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path


USER_AGENT = "unitree-g1-doc-mirror/1.0"
TEXT_EXTS = {".md", ".txt", ".json", ".yaml", ".yml", ".csv", ".xml", ".html", ".htm"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp"}
PDF_EXTS = {".pdf"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}
AUDIO_EXTS = {".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac"}
ARCHIVE_EXTS = {".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz", ".7z", ".rar"}
ASSET_ATTR_RE = re.compile(r"""(?P<prefix>\b(?:src|href)=["'])(?P<url>[^"']+)(?P<suffix>["'])""", re.I)
MD_LINK_RE = re.compile(r"""(?P<bang>!?)\[(?P<label>[^\]]*)\]\((?P<url>[^)\s]+)(?P<title>\s+["'][^)]*["'])?\)""")


@dataclass
class Doc:
    name: str
    path: str
    url: str
    index_path: str
    local_path: str
    parents: list[str]
    parent_paths: list[str]
    children: list["Doc"] = field(default_factory=list)
    status: str = "pending"
    sha256: str | None = None
    bytes: int = 0
    error: str | None = None


def default_paths() -> tuple[Path, Path]:
    repo_root = Path(__file__).resolve().parents[1]
    return repo_root / "g1-doc-index.json", repo_root / "g1-docs"


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", value).strip("._-")
    return slug or "doc"


def frontmatter_value(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def frontmatter_field(name: str, values: list[str]) -> list[str]:
    if not values:
        return [f"{name}: []"]
    return [f"{name}:"] + [f"  - {frontmatter_value(v)}" for v in values]


def load_docs(index_path: Path) -> list[Doc]:
    data = json.loads(index_path.read_text(encoding="utf-8"))
    root_nodes = data.get("directory", data.get("data", {}).get("directory", []))

    def walk(nodes: list[dict], prefix: tuple[int, ...], parents: list[str], parent_paths: list[str]) -> list[Doc]:
        docs: list[Doc] = []
        for i, node in enumerate(nodes):
            index = prefix + (i,)
            index_path = "_".join(f"{part:02d}" for part in index)
            slug = safe_slug(str(node.get("path") or node.get("name") or index_path))
            doc = Doc(
                name=str(node.get("name", "")),
                path=str(node.get("path", "")),
                url=str(node.get("url", "")),
                index_path=index_path,
                local_path=f"pages/{index_path}_{slug}.md",
                parents=parents[:],
                parent_paths=parent_paths[:],
            )
            doc.children = walk(
                node.get("children") or [],
                index,
                parents + [doc.name],
                parent_paths + [doc.path],
            )
            docs.append(doc)
        return docs

    return walk(root_nodes, (), [], [])


def iter_docs(docs: list[Doc]):
    for doc in docs:
        yield doc
        yield from iter_docs(doc.children)


def request_url(url: str, timeout: int, retries: int) -> tuple[bytes, dict[str, str]]:
    last_error: Exception | None = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                headers = {k.lower(): v for k, v in resp.headers.items()}
                return resp.read(), headers
        except (urllib.error.URLError, TimeoutError) as exc:
            last_error = exc
            if attempt < retries:
                time.sleep(0.5 * (attempt + 1))
    raise RuntimeError(str(last_error))


def url_ext(url: str, content_type: str = "") -> str:
    parsed = urllib.parse.urlparse(url)
    ext = Path(parsed.path).suffix.lower()
    if ext:
        return ext
    guessed = mimetypes.guess_extension(content_type.split(";", 1)[0].strip())
    return guessed or ""


def is_video(url: str, content_type: str = "") -> bool:
    return url_ext(url, content_type) in VIDEO_EXTS or content_type.lower().startswith("video/")


def should_download_asset(url: str, asset_mode: str) -> bool:
    if asset_mode == "none" or url.startswith(("data:", "mailto:", "tel:", "#")):
        return False
    if asset_mode == "all":
        return True
    ext = url_ext(url)
    if asset_mode == "images":
        return ext in IMAGE_EXTS
    if asset_mode == "docs":
        return ext in IMAGE_EXTS | PDF_EXTS | TEXT_EXTS
    return False


def asset_name(url: str, content_type: str = "") -> str:
    parsed = urllib.parse.urlparse(url)
    base = safe_slug(Path(parsed.path).name or "asset")
    stem = Path(base).stem or "asset"
    ext = Path(base).suffix or url_ext(url, content_type)
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:12]
    return f"{stem}_{digest}{ext}"


def rewrite_url(
    url: str,
    base_url: str,
    doc_url_to_local: dict[str, str],
    assets: dict[str, str],
    out_dir: Path,
    timeout: int,
    retries: int,
    asset_mode: str,
    max_asset_bytes: int,
    failures: list[dict],
) -> str:
    absolute = urllib.parse.urljoin(base_url, html.unescape(url))
    normalized = absolute.split("#", 1)[0].rstrip("/")
    fragment = "#" + absolute.split("#", 1)[1] if "#" in absolute else ""

    if normalized in doc_url_to_local:
        return doc_url_to_local[normalized] + fragment
    if not should_download_asset(absolute, asset_mode):
        return url
    if absolute in assets:
        return assets[absolute]

    try:
        data, headers = request_url(absolute, timeout, retries)
        content_type = headers.get("content-type", "")
        if asset_mode != "all" and is_video(absolute, content_type):
            return url
        if len(data) > max_asset_bytes:
            failures.append({"url": absolute, "error": f"asset exceeds {max_asset_bytes} bytes"})
            return url
        local = "assets/" + asset_name(absolute, content_type)
        target = out_dir / local
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        assets[absolute] = "../" + local
        return assets[absolute]
    except Exception as exc:  # keep the doc useful even if one image fails
        failures.append({"url": absolute, "error": str(exc)})
        return url


def rewrite_markdown(
    text: str,
    base_url: str,
    doc_url_to_local: dict[str, str],
    out_dir: Path,
    assets: dict[str, str],
    args: argparse.Namespace,
    failures: list[dict],
) -> str:
    def repl_md(match: re.Match) -> str:
        new_url = rewrite_url(
            match.group("url"),
            base_url,
            doc_url_to_local,
            assets,
            out_dir,
            args.timeout,
            args.retries,
            args.asset_mode,
            args.max_asset_mb * 1024 * 1024,
            failures,
        )
        title = match.group("title") or ""
        return f'{match.group("bang")}[{match.group("label")}]({new_url}{title})'

    def repl_attr(match: re.Match) -> str:
        new_url = rewrite_url(
            match.group("url"),
            base_url,
            doc_url_to_local,
            assets,
            out_dir,
            args.timeout,
            args.retries,
            args.asset_mode,
            args.max_asset_mb * 1024 * 1024,
            failures,
        )
        return match.group("prefix") + new_url + match.group("suffix")

    text = MD_LINK_RE.sub(repl_md, text)
    return ASSET_ATTR_RE.sub(repl_attr, text)


def doc_frontmatter(doc: Doc) -> str:
    lines = [
        "---",
        f"name: {frontmatter_value(doc.name)}",
        f"path: {frontmatter_value(doc.path)}",
        f"url: {frontmatter_value(doc.url)}",
        f"index_path: {frontmatter_value(doc.index_path)}",
        *frontmatter_field("parents", doc.parents),
        *frontmatter_field("parent_paths", doc.parent_paths),
        "---",
        "",
    ]
    return "\n".join(lines)


def write_indexes(docs: list[Doc], out_dir: Path, generated_at: str, asset_count: int) -> None:
    def to_dict(doc: Doc) -> dict:
        node = {
            "name": doc.name,
            "path": doc.path,
            "url": doc.url,
            "index_path": doc.index_path,
            "local_path": doc.local_path,
            "status": doc.status,
            "bytes": doc.bytes,
            "sha256": doc.sha256,
        }
        if doc.error:
            node["error"] = doc.error
        if doc.children:
            node["children"] = [to_dict(child) for child in doc.children]
        return node

    index = {
        "generated_at": generated_at,
        "doc_count": sum(1 for _ in iter_docs(docs)),
        "asset_count": asset_count,
        "directory": [to_dict(doc) for doc in docs],
    }
    (out_dir / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lines = ["# Unitree G1 Docs", "", f"Generated: {generated_at}", ""]

    def append_md(nodes: list[Doc], depth: int) -> None:
        for doc in nodes:
            indent = "  " * depth
            status = "" if doc.status == "ok" else f" ({doc.status})"
            lines.append(f"{indent}- [{doc.name}](./{doc.local_path}) `{doc.index_path}` `{doc.path}`{status}")
            append_md(doc.children, depth + 1)

    append_md(docs, 0)
    (out_dir / "index.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def mirror(args: argparse.Namespace) -> int:
    docs = load_docs(args.index)
    flat = list(iter_docs(docs))
    doc_url_to_local = {doc.url.rstrip("/"): Path(doc.local_path).name for doc in flat if doc.url}
    assets: dict[str, str] = {}
    failures: list[dict] = []
    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

    (args.out / "pages").mkdir(parents=True, exist_ok=True)
    (args.out / "raw").mkdir(parents=True, exist_ok=True)
    if args.asset_mode != "none":
        (args.out / "assets").mkdir(parents=True, exist_ok=True)

    for n, doc in enumerate(flat, 1):
        print(f"[{n:02d}/{len(flat):02d}] {doc.index_path} {doc.path}", flush=True)
        try:
            data, _headers = request_url(doc.url, args.timeout, args.retries)
            doc.bytes = len(data)
            doc.sha256 = hashlib.sha256(data).hexdigest()
            raw_name = Path(doc.local_path).name
            (args.out / "raw" / raw_name).write_bytes(data)
            text = data.decode("utf-8-sig")
            text = rewrite_markdown(text, doc.url, doc_url_to_local, args.out, assets, args, failures)
            (args.out / doc.local_path).write_text(doc_frontmatter(doc) + text.rstrip() + "\n", encoding="utf-8")
            doc.status = "ok"
        except Exception as exc:
            doc.status = "error"
            doc.error = str(exc)
            failures.append({"url": doc.url, "path": doc.path, "error": str(exc)})
            (args.out / doc.local_path).write_text(doc_frontmatter(doc) + f"# {doc.name}\n\nDownload failed: {exc}\n", encoding="utf-8")

    write_indexes(docs, args.out, generated_at, len(assets))
    (args.out / "failures.json").write_text(json.dumps(failures, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    ok = sum(1 for doc in flat if doc.status == "ok")
    print(f"docs: {ok}/{len(flat)} ok, assets: {len(assets)}, failures: {len(failures)}")
    return 0 if ok == len(flat) else 1


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_index, default_out = default_paths()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, default=default_index, help=f"doc index JSON, default: {default_index}")
    parser.add_argument("--out", type=Path, default=default_out, help=f"mirror output directory, default: {default_out}")
    parser.add_argument(
        "--asset-mode",
        choices=["none", "images", "docs", "all"],
        default="docs",
        help="asset policy: docs mirrors images/PDF/text and skips videos, audio, archives",
    )
    parser.add_argument("--max-asset-mb", type=int, default=80, help="skip individual assets larger than this")
    parser.add_argument("--timeout", type=int, default=30, help="per-request timeout seconds")
    parser.add_argument("--retries", type=int, default=2, help="request retries after the first attempt")
    args = parser.parse_args(argv)
    args.index = args.index.resolve()
    args.out = args.out.resolve()
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if not args.index.exists():
        print(f"index not found: {args.index}", file=sys.stderr)
        return 2
    return mirror(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
