---
description: Open the read-only Ralph dashboard — prd.json story status, live loop flow, iteration timeline
argument-hint: "[optional: --once | --snapshot FILE | --port N | 会话内]"
---

Load the `ralph-dashboard` skill and open the dashboard for this project. $ARGUMENTS

Defaults: start the live local board (127.0.0.1) and report its URL; use `--once` when the user
only wants the current status in text. Pass `--snapshot FILE` for a self-contained file instead of
a server, or write the in-session fragment when the user wants it rendered inside the conversation.

Never edit `prd.json`, `progress.txt`, or any project file while doing this — the dashboard is
strictly read-only, and anything it cannot read is reported as missing rather than guessed.
