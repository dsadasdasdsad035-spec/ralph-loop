---
description: Convert a PRD into prd.json user stories for the Ralph autonomous loop
argument-hint: "[path to PRD, e.g. tasks/prd-task-priority.md]"
---

Load the `ralph` skill and convert this PRD into `prd.json` in the project root: $ARGUMENTS

If no path was given, use the most recently modified file in `tasks/` and say which one you picked.
Archive any previous run before overwriting a `prd.json` from a different feature. Do not implement
anything — when `prd.json` is written and validates with `jq . prd.json`, tell the user to start the
loop with `/ralph-run`.
