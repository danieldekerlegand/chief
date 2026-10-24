#!/usr/bin/env python3
from __future__ import annotations
import argparse
import subprocess
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4173)
    parser.add_argument("--no-collect", action="store_true")
    args = parser.parse_args()
    if not args.no_collect:
        subprocess.run(["python3", str(Path(__file__).with_name("collect.py"))], check=True)
    public = ROOT / "apps" / "portfolio" / "public"
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw): super().__init__(*a, directory=str(public), **kw)
    print(f"Chief Portfolio: http://127.0.0.1:{args.port}")
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()

if __name__ == "__main__": main()
