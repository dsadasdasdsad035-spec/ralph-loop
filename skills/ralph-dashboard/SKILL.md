---
name: ralph-dashboard
description: "Open the read-only Ralph dashboard: a local board showing prd.json story status, the live loop flow, and the iteration timeline. Use when the user says 看板, 打开看板, 看 ralph 跑到哪了, 实时进度, 看 prd.json 任务情况, dashboard, show ralph progress, watch the loop. Read-only — it never touches the project beyond reading its artifacts."
---

# Ralph Dashboard

The dashboard is a read-only viewer over what the loop already leaves on disk:
`prd.json`, `progress.txt`, git history, `.ralph/events.jsonl`, and `archive/`.
It never writes project files and never invents progress — anything it cannot
read is reported as missing instead of guessed.

You do not re-implement any of this. The scripts do the work:

| Script | Role |
|---|---|
| `scripts/ralph-state.sh` | Aggregates the artifacts into one state JSON (read-only) |
| `scripts/ralph-dashboard.sh` | Entry point: serve / `--snapshot` / `--inline-fragment` / `--once` / `--stop` |
| `dashboard/serve.py` | Local read-only HTTP server, bound to 127.0.0.1, polls disk per request |
| `dashboard/index.html` | The full board page (task board + live flow + timeline + archive) |
| `dashboard/inline.html` | Fragment template for rendering the board inside a ZCode session |

## Step 0: Resolve paths

Resolve the plugin root the same way the `ralph-run` skill does (env var
`ZCODE_PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT`, else this skill's base directory minus
`/skills/ralph-dashboard`, else one search under
`~/.zcode/cli/plugins/cache`). Then confirm `scripts/ralph-dashboard.sh` exists.

`<PROJECT_DIR>` is the project root — the directory holding `.git` and, normally,
`prd.json`. If the user did not say which project, use the current workspace.

## Step 1: Look before you speak

```bash
bash "<plugin-root>/scripts/ralph-dashboard.sh" --once --dir "<PROJECT_DIR>"
```

This prints the exact state JSON the page renders. Read it and check:

- `errors` — anything listed there (no `prd.json`, invalid JSON, not a git repo)
  will also appear on the page as a warning banner. Say what is missing.
- `loop.stage` / `loop.stage_label` — the current phase. `loop.source` is
  `events` when the loop wrote stage events, `inferred` when the page had to
  reconstruct the phase from commits + PRD state. When it is `inferred` and the
  project is mid-loop, say so plainly instead of promising precision.
- `prd.counts` — done/total, and `prd.next`.

If `prd` is `null`, the loop has not been set up in this project yet: tell the
user to run `/prd` then `/ralph` first. Do not create a PRD for them.

## Step 2: Pick the view the user asked for

**A. Live board (default — "打开看板", "看实时进度", "watch the loop")**

```bash
bash "<plugin-root>/scripts/ralph-dashboard.sh" --dir "<PROJECT_DIR>" --port 7878
```

It prints `Ralph 看板: http://127.0.0.1:<port>/` and keeps running. Run it in the
background so it does not block the session, then tell the user the URL. The page
re-reads the artifacts every 2 seconds, so it stays live while an in-session or
headless loop runs. Stop it later with `--stop` (it records a PID under
`.ralph/dashboard.pid`) or by ending the process.

**B. In-session view (Desktop; "在会话里看", or when the user wants it inline)**

Write the fragment into the session visualization directory the host supplies
(the same directory the `visualize` skill uses):

```bash
bash "<plugin-root>/scripts/ralph-dashboard.sh" --inline-fragment "<session-viz-dir>/ralph-board.html" --dir "<PROJECT_DIR>"
```

Then follow the `visualize` skill for authoring/emit rules and reference that
file in the final response. The fragment is a point-in-time snapshot: it does not
poll. For a live view, use A. If the host supplied no visualization directory,
fall back to C and tell the user the file path.

**C. Snapshot file ("导出", "存成文件", or no Python available)**

```bash
bash "<plugin-root>/scripts/ralph-dashboard.sh" --snapshot /tmp/ralph-dashboard.html --dir "<PROJECT_DIR>"
```

Produces one self-contained HTML file (state embedded, no server, no network) for
the current moment. It does not auto-update — regenerate it to refresh.

## Step 3: Report

Say what the board is showing right now — done/total, the current story and
phase, and anything the artifacts could not tell you (blocked story, stale run,
missing events file). If the user is about to start or has just started a loop,
mention that the live board (A) updates on its own.

## Contract

- Read-only: the dashboard never edits `prd.json`, `progress.txt`, or any project
  file. The only thing it may write is `.ralph/dashboard.pid` (harness state,
  self-ignored) when a server is started.
- The server binds to `127.0.0.1` only and has no mutating routes.
- Never hand-edit or fabricate dashboard data in place of running the scripts —
  if the state looks wrong, the artifacts are wrong, and that is worth reporting.
