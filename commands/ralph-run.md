---
description: Run the Ralph loop — one fresh-context subagent per user story until all pass
argument-hint: "[max iterations, e.g. 10]"
---

Load the `ralph-run` skill and drive the Ralph loop to completion in this session: $ARGUMENTS

If a number was given, use it as `--max-iterations`; otherwise default to 10. Do not implement any
story yourself — spawn one fresh subagent per iteration, re-read state after each one, and stop when
all stories pass or a story is genuinely blocked.
