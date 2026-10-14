#!/usr/bin/env python3
"""Ralph dashboard — local, read-only viewer for a Ralph loop.

Serves the dashboard page and a live state API. Every /api/state request runs
scripts/ralph-state.sh, which re-reads prd.json / progress.txt / git /
.ralph/events.jsonl from disk, so the page shows the loop's real artifacts and
nothing else. The server never writes inside the project and holds no state of
its own.

Binding is always 127.0.0.1 (loopback only) and there are no mutating routes —
this is an admin *view*, not an admin console.

    python3 serve.py --dir /path/to/project [--port 7878] [--open]

Stdlib only; no third-party packages, no build step.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLUGIN_ROOT = HERE.parent
INDEX = HERE / "index.html"
STATE_SCRIPT = PLUGIN_ROOT / "scripts" / "ralph-state.sh"
PLACEHOLDER = "__RALPH_STATE__"
STATE_TIMEOUT = 30.0
ALLOWED_HOSTS = {"localhost", "127.0.0.1", "[::1]", "::1"}


def compact_json(text: str) -> str:
    """Re-serialize so the embedded value is one line and cannot close its <script> tag."""
    data = json.loads(text)
    out = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return out.replace("<", "\\u003c")


def read_state(project_dir: str) -> tuple[str, str | None]:
    """Return (state_json, error). Never raises — a broken extractor becomes page state."""
    if not STATE_SCRIPT.exists():
        return "", f"state extractor not found: {STATE_SCRIPT}"
    try:
        proc = subprocess.run(
            ["bash", str(STATE_SCRIPT), "--dir", project_dir, "--compact"],
            capture_output=True, text=True, timeout=STATE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return "", f"state extractor timed out after {STATE_TIMEOUT:.0f}s"
    except OSError as exc:
        return "", f"could not run the state extractor: {exc}"

    stdout = proc.stdout.strip()
    if proc.returncode != 0 or not stdout:
        detail = (proc.stderr or "").strip().splitlines()
        return "", detail[-1] if detail else f"state extractor exited {proc.returncode}"
    try:
        return compact_json(stdout), None
    except json.JSONDecodeError as exc:
        return "", f"state extractor produced invalid JSON: {exc}"


def error_state(project_dir: str, message: str) -> str:
    return json.dumps({
        "schema": 1,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "now_epoch": int(time.time()),
        "project": {"dir": project_dir, "is_git_repo": False, "branch": "", "head": None,
                    "dirty": False, "dirty_files": []},
        "prd": None,
        "patterns_md": "",
        "progress_entries": [],
        "loop": {"driver": "unknown", "running": False, "stale": False, "iteration": 0,
                 "max_iterations": None, "stage": "no-prd", "stage_node": 1,
                 "stage_label": "状态读取失败", "story": None, "last_event": None,
                 "last_event_age_sec": None, "source": "inferred"},
        "iterations": [],
        "recent_commits": [],
        "archive": [],
        "errors": [message],
    }, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")


class Handler(BaseHTTPRequestHandler):
    server_version = "ralph-dashboard/1.0"
    project_dir = ""

    def log_message(self, fmt: str, *args) -> None:  # keep polling quiet
        pass

    def _host_ok(self) -> bool:
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip()
        return host in ALLOWED_HOSTS

    def _send(self, body: bytes, ctype: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802
        if not self._host_ok():
            self._send(b"forbidden: non-local Host header", "text/plain; charset=utf-8", 403)
            return

        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            state_json, err = read_state(self.project_dir)
            if err:
                state_json = error_state(self.project_dir, err)
            try:
                template = INDEX.read_text(encoding="utf-8")
            except OSError as exc:
                self._send(f"cannot read dashboard page: {exc}".encode(), "text/plain; charset=utf-8", 500)
                return
            page = template.replace(PLACEHOLDER, state_json, 1)
            self._send(page.encode("utf-8"), "text/html; charset=utf-8")
            return

        if path in ("/api/state", "/api/state.json"):
            state_json, err = read_state(self.project_dir)
            if err:
                state_json = error_state(self.project_dir, err)
            self._send(state_json.encode("utf-8"), "application/json; charset=utf-8")
            return

        if path == "/healthz":
            self._send(b'{"ok":true}', "application/json; charset=utf-8")
            return

        self._send("not found. routes: / , /api/state , /healthz".encode(), "text/plain; charset=utf-8", 404)


def pick_port(host: str, want: int, tries: int = 20) -> int:
    for candidate in range(want, want + tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind((host, candidate))
                return candidate
            except OSError:
                continue
    raise SystemExit(f"Error: no free port in {want}..{want + tries - 1}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Ralph dashboard — read-only local viewer")
    ap.add_argument("--dir", default=os.getcwd(), help="project directory holding prd.json (default: cwd)")
    ap.add_argument("--port", type=int, default=7878, help="preferred port (default 7878, auto-increments if busy)")
    ap.add_argument("--open", action="store_true", help="open the browser once the server is up")
    args = ap.parse_args()

    project_dir = str(Path(args.dir).expanduser().resolve())
    if not Path(project_dir).is_dir():
        print(f"Error: project directory not found: {project_dir}", file=sys.stderr)
        return 1
    if not INDEX.exists():
        print(f"Error: dashboard page not found: {INDEX}", file=sys.stderr)
        return 1

    # Fail before binding if the extractor cannot run at all — an empty board
    # is worse than a clear error.
    _, err = read_state(project_dir)
    if err:
        print(f"Warning: {err} — the page will show this instead of guessing.", file=sys.stderr)

    host = "127.0.0.1"
    port = pick_port(host, args.port)
    Handler.project_dir = project_dir

    httpd = ThreadingHTTPServer((host, port), Handler)
    url = f"http://{host}:{port}/"
    # flush=True matters: when this server is started by ralph.sh in the background,
    # stdout is a pipe (block-buffered) and the caller must see the URL immediately.
    print(f"Ralph 看板: {url}", flush=True)
    print(f"项目: {project_dir}", flush=True)
    print("数据: prd.json / progress.txt / git / .ralph/events.jsonl（每次刷新现读，只读不改项目）", flush=True)
    print("Ctrl-C 退出", flush=True)

    if args.open:
        threading.Thread(target=lambda: (time.sleep(0.4), webbrowser.open(url)), daemon=True).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
