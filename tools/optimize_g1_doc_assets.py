#!/usr/bin/env python3
"""Shrink mirrored G1 doc image assets with macOS sips."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


IMAGE_EXTS = {".png", ".jpg", ".jpeg"}


def default_docs_dir() -> Path:
    return Path(__file__).resolve().parents[1] / "g1-docs"


def run_sips(src: Path, dst: Path, max_edge: int, quality: int) -> None:
    subprocess.run(
        [
            "sips",
            "-s",
            "format",
            "jpeg",
            "-s",
            "formatOptions",
            str(quality),
            "-Z",
            str(max_edge),
            str(src),
            "--out",
            str(dst),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def replace_references(pages_dir: Path, old_name: str, new_name: str) -> int:
    count = 0
    for path in pages_dir.glob("*.md"):
        text = path.read_text(encoding="utf-8")
        updated = text.replace(f"../assets/{old_name}", f"../assets/{new_name}")
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            count += 1
    return count


def optimize(args: argparse.Namespace) -> int:
    sips = shutil.which("sips")
    if not sips:
        print("sips not found; this optimizer is intended for macOS", file=sys.stderr)
        return 2

    assets_dir = args.docs_dir / "assets"
    pages_dir = args.docs_dir / "pages"
    if not assets_dir.is_dir() or not pages_dir.is_dir():
        print(f"expected assets/ and pages/ under {args.docs_dir}", file=sys.stderr)
        return 2

    changed = 0
    saved = 0
    skipped = 0
    candidates = sorted(p for p in assets_dir.iterdir() if p.suffix.lower() in IMAGE_EXTS)

    with tempfile.TemporaryDirectory(prefix="g1-doc-assets-") as tmp:
        tmp_dir = Path(tmp)
        for src in candidates:
            original_size = src.stat().st_size
            if original_size < args.min_bytes:
                skipped += 1
                continue

            dst_name = re.sub(r"\.(png|jpe?g)$", ".jpg", src.name, flags=re.I)
            tmp_dst = tmp_dir / dst_name
            try:
                run_sips(src, tmp_dst, args.max_edge, args.quality)
            except subprocess.CalledProcessError:
                skipped += 1
                continue

            new_size = tmp_dst.stat().st_size
            if new_size >= original_size * args.keep_ratio:
                skipped += 1
                continue

            final_dst = assets_dir / dst_name
            if final_dst != src and final_dst.exists():
                skipped += 1
                continue

            os.replace(tmp_dst, final_dst)
            if final_dst != src:
                replace_references(pages_dir, src.name, dst_name)
                src.unlink()

            changed += 1
            saved += original_size - new_size
            print(f"{src.name} -> {dst_name}: {original_size // 1024}K -> {new_size // 1024}K")

    print(f"optimized {changed}, skipped {skipped}, saved {saved // 1024}K")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docs-dir", type=Path, default=default_docs_dir())
    parser.add_argument("--max-edge", type=int, default=2560)
    parser.add_argument("--quality", type=int, default=84)
    parser.add_argument("--min-bytes", type=int, default=256 * 1024)
    parser.add_argument("--keep-ratio", type=float, default=0.92, help="keep only if new file is below this fraction of old size")
    args = parser.parse_args(argv)
    args.docs_dir = args.docs_dir.resolve()
    return args


def main(argv: list[str]) -> int:
    return optimize(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
