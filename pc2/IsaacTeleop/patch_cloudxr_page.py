#!/usr/bin/env python3
"""Add a headset-friendly client link to the pinned CloudXR certificate page."""

import ast
from importlib.metadata import distribution


ORIGINAL = '<p>You can close this tab and return to the web client.</p>'
LEGACY_REPLACEMENT = (
    "<p><a href='https://nvidia.github.io/IsaacTeleop/client' "
    "style='display:inline-block;padding:20px 32px;margin:16px;"
    "background:#176b27;color:white;border-radius:12px;font-size:24px;"
    "text-decoration:none'>Open NVIDIA Isaac Teleop Client</a></p>"
    "<p>Continue to the client, enter this PC2 address, and connect.</p>"
)
REPLACEMENT = (
    LEGACY_REPLACEMENT.replace("<a href=", "<a id='teleop-client' href=").replace(
        "Continue to the client, enter this PC2 address, and connect.",
        "Continue to the client with this PC2 address pre-filled, then connect.",
    )
    + "<script>const link=document.getElementById('teleop-client');"
    "const url=new URL(link.href);"
    "url.searchParams.set('serverIP',window.location.hostname);"
    "url.searchParams.set('port',window.location.port||'48322');"
    "link.href=url.toString();</script>"
)


def patch_source(source: str) -> str:
    if source.count(REPLACEMENT) == 1 and ORIGINAL not in source and LEGACY_REPLACEMENT not in source:
        return source
    matches = [template for template in (ORIGINAL, LEGACY_REPLACEMENT) if template in source]
    if len(matches) != 1 or source.count(matches[0]) != 1 or REPLACEMENT in source:
        raise RuntimeError("Unexpected CloudXR certificate page. Refusing to patch an unknown template.")
    patched = source.replace(matches[0], REPLACEMENT)
    ast.parse(patched)
    return patched


def main() -> None:
    package = distribution("isaacteleop")
    if package.version != "1.4.145":
        raise RuntimeError(f"This patch requires isaacteleop 1.4.145, found {package.version}")
    path = package.locate_file("isaacteleop/cloudxr/wss.py")
    source = path.read_text()
    patched = patch_source(source)
    if patched != source:
        path.write_text(patched)
    print("CloudXR certificate page: NVIDIA client link installed (restart the verifier to use it).")


if __name__ == "__main__":
    main()
