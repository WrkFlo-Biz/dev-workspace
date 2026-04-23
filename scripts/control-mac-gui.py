#!/usr/bin/env python3
"""
control-mac-gui.py — VM-side helper for driving the Mac's Hammerspoon bridge.

Examples:
  scripts/control-mac-gui.py apps
  scripts/control-mac-gui.py focused
  scripts/control-mac-gui.py open "Terminal"
  scripts/control-mac-gui.py open-url "https://example.com"
  scripts/control-mac-gui.py type "hello world"
  scripts/control-mac-gui.py keystroke "cmd+shift+4"
  scripts/control-mac-gui.py click-menu "Safari" "File" "New Window"
  scripts/control-mac-gui.py osascript 'tell application "Terminal" to activate'
  scripts/control-mac-gui.py screenshot --out /tmp/mac-screen.png
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request


DEFAULT_BASE_URL = os.environ.get("MAC_GUI_URL", "http://100.78.207.22:9223").rstrip("/")


def post_json(path: str, body: dict) -> dict:
    req = urllib.request.Request(
        f"{DEFAULT_BASE_URL}/{path.lstrip('/')}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode() if exc.fp else ""
        raise SystemExit(f"HTTP {exc.code}: {payload or exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"request failed: {exc.reason}") from exc


def read_script(script_arg: str | None) -> str:
    if script_arg and script_arg != "-":
        return script_arg
    if not sys.stdin.isatty():
        return sys.stdin.read()
    raise SystemExit("missing AppleScript source")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Drive the Mac GUI bridge from the VM")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("apps")
    sub.add_parser("focused")

    sp = sub.add_parser("open")
    sp.add_argument("app")

    sp = sub.add_parser("open-url")
    sp.add_argument("url")

    sp = sub.add_parser("type")
    sp.add_argument("text")

    sp = sub.add_parser("keystroke")
    sp.add_argument("keys")

    sp = sub.add_parser("spotlight")
    sp.add_argument("query")
    sp.add_argument("--no-submit", action="store_true")

    sp = sub.add_parser("click-menu")
    sp.add_argument("app")
    sp.add_argument("path", nargs="+", help='Menu path segments, e.g. "File" "New Window"')

    sp = sub.add_parser("osascript")
    sp.add_argument("script", nargs="?", help='AppleScript source, or "-" to read stdin')

    sp = sub.add_parser("screenshot")
    sp.add_argument("--out", help="Write PNG bytes to this path")

    return p


def main() -> int:
    args = build_parser().parse_args()

    endpoint = args.cmd.replace("-", "_")
    body: dict = {}

    if args.cmd == "open":
        body = {"app": args.app}
    elif args.cmd == "open-url":
        body = {"url": args.url}
    elif args.cmd == "type":
        body = {"text": args.text}
    elif args.cmd == "keystroke":
        body = {"keys": args.keys}
    elif args.cmd == "spotlight":
        body = {"query": args.query, "submit": not args.no_submit}
    elif args.cmd == "click-menu":
        body = {"app": args.app, "path": args.path}
    elif args.cmd == "osascript":
        body = {"script": read_script(args.script)}

    result = post_json(endpoint, body)

    if args.cmd == "screenshot" and args.out and result.get("png_base64"):
        png = base64.b64decode(result["png_base64"])
        with open(args.out, "wb") as fh:
            fh.write(png)
        result = {k: v for k, v in result.items() if k != "png_base64"}
        result["out"] = args.out

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
