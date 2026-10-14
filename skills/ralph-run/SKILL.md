---
name: ralph-run
description: "Run the Ralph autonomous development loop inside the ZCode session: repeatedly spawn a fresh-context subagent that implements exactly one prd.json user story, runs the project's checks, commits, and appends learnings — until every story has passes: true. Use when the user says run ralph, start the loop, keep going until all stories pass, 跑 ralph, 开始循环, 自动实现这些故事, 继续实现到全部通过."
---

# Ralph Loop — in-session orchestrator

You are the loop driver, not an implementer. Your job is to spawn one **fresh-context subagent per
iteration**, let each one implement a single story, and stop when the PRD is complete or the loop is
genuinely stuck. Never implement stories yourself in this session: a fresh agent per story is the
whole point of Ralph — clean context stops one story's mess from polluting the next.

## Step 0: Locate the project and the loop script

**Resolve the plugin root first.** The loop script is `<plugin-root>/scripts/ralph.sh`. `${CLAUDE_PLUGIN_ROOT}`
is *not* expanded inside skill text — resolve the real path yourself, once, and reuse it below:

- If `ZCODE_PLUGIN_ROOT` or `CLAUDE_PLUGIN_ROOT` is set in the shell environment, use it.
- Otherwise derive it from this skill's own directory, reported in the skill header as
  `Base directory for this skill: …/plugins/ralph/skills/ralph-run` — the plugin root is that path
  minus `/skills/ralph-run`.
- If that path does not exist, search the plugin cache once:
  `find ~/.zcode/cli/plugins/cache -maxdepth 4 -type d -name ralph -path '*/ralph' | head`.

Then confirm the script is there (`ls -l <plugin-root>/scripts/ralph.sh`). If it is missing, tell the
user the plugin installation looks incomplete instead of improvising a replacement loop.

`ralph.sh` owns every piece of loop state, so you never hand-edit `progress.txt` or parse JSON yourself.

Two sibling scripts sit next to it, both optional and best-effort:

- `scripts/ralph-event.sh` — appends one stage event to `<PROJECT_DIR>/.ralph/events.jsonl`. The
  dashboard reads that file to show *which* iteration is running on *which* story instead of
  guessing from commits. Call it around every subagent (1b/1c) and when the loop ends (Step 2/3).
  If the helper is missing, skip it silently: an older install still runs, it just loses precision.
- `scripts/ralph-dashboard.sh` — the read-only board (`--dir`, `--port`, `--stop`, `--snapshot FILE`,
  `--inline-fragment FILE`, `--once`). Start it **only when the user asked** for the dashboard or a
  live view; with it running, the loop is observable while it works.

Run the preflight (replace `<PROJECT_DIR>` with the project root — the directory holding `.git`,
usually the current workspace; also pass `--max-iterations` if the user named a number):

```bash
bash "<plugin-root>/scripts/ralph.sh" --dir "<PROJECT_DIR>" --max-iterations 10 --prepare-only
```

It prints a JSON state object. `--prepare-only` also performs the setup an iteration needs:
archives the previous run when `branchName` changed, initialises `progress.txt`, and writes the
last-branch marker. It fails loudly if the directory is not a git repo, `jq` is missing, or the PRD
is absent.

| State | What to do |
|---|---|
| Command failed because `prd.json` is missing | Stop. Tell the user to create the PRD first (`prd` skill) then convert it (`ralph` skill). Do not invent a PRD. |
| `remaining` is `0` | Stop and report the work was already complete. |
| `next` is a story id | Start the loop (Step 1). |

## Step 1: Run iterations

Repeat, up to `max-iterations` times (default 10, or what the user asked for):

**1a. Render this iteration's prompt.** The template lives in the plugin, never inline it:

```bash
bash "<plugin-root>/scripts/ralph.sh" --dir "<PROJECT_DIR>" --render-prompt <N>
```

**Record the iteration start** (best-effort — this is what lets a running dashboard say "第 N 轮正在
处理 US-00X" as a fact rather than a guess):

```bash
bash "<plugin-root>/scripts/ralph-event.sh" --dir "<PROJECT_DIR>" --type iteration_start \
  --iteration <N> --story <STORY_ID> --max <MAX> --driver in-session
```

**1b. Spawn exactly one fresh subagent** with that prompt as its task. Use the `Agent` tool with
`subagent_type: "general-purpose"`, a synchronous call, one agent at a time. Prepend a short
orientation header to the rendered prompt:

```
Working directory: <PROJECT_DIR> — treat it as the repository root; run all commands from there.
<rendered prompt>
```

Do not add your own commentary about what you think the story needs; you have not read the
codebase and the subagent will. Do not run the story's checks or commit for it.

**1c. Re-read the state** after the subagent returns, with the same `--prepare-only` command.

**The script's `remaining` count is the only source of truth — never the subagent's report or the
`<promise>COMPLETE</promise>` token.** Two observed reasons: a subagent whose context filled up may
return a *compaction summary* of its own transcript instead of its report, and that text can omit the
token even though the story landed correctly; conversely a subagent can claim success while
`prd.json` still says `passes: false`. Read the state, then decide:

| After an iteration | What to do |
|---|---|
| `remaining` is `0` | The loop is complete. Go to Step 2. |
| `remaining` decreased | Progress was made. Continue with the next iteration. |
| `remaining` unchanged | The story did not land. Check the subagent's report and `progress.txt`: if it describes a real blocker, stop the loop and surface it (Step 3). If not, allow **one** retry of the same story — a second consecutive no-progress iteration ends the loop. |
| The `next` story id changed but `remaining` did not | A different story got taken; almost always means the previous story was left `passes: false` deliberately. Treat as no progress. |

**Record the outcome** right after deciding, with the same helper — `done` when `remaining`
decreased, `blocked` when it did not:

```bash
bash "<plugin-root>/scripts/ralph-event.sh" --dir "<PROJECT_DIR>" --type iteration_end \
  --iteration <N> --story <STORY_ID> --status <done|blocked> --driver in-session
```

**1d. Between iterations** there is nothing to clean up: each iteration is a separate agent whose
context dies with it. Memory between iterations is exactly git history, `prd.json`, and
`progress.txt` — which is why the subagent is told to commit and to append learnings.

Stop early and honestly if the subagent burns its whole run without finishing: two sibling
iterations of the same story with no commit means the story is too big or the environment is broken.
Loops that keep retrying a stuck story burn the user's budget for nothing.

## Step 2: Report completion

First close the run in the event log:

```bash
bash "<plugin-root>/scripts/ralph-event.sh" --dir "<PROJECT_DIR>" --type complete \
  --iteration <N> --status done --driver in-session
```

Completion is decided by `remaining == 0`, and at that point you print the completion signal the
user's tooling expects, on its own line:

```
<promise>COMPLETE</promise>
```

You print it — the subagents do not need to have emitted it. A subagent that finished its story but
returned a context-compaction summary without the token is normal, not a failure, and is not a reason
to run another iteration. Do not run a further iteration just to "collect" the token: every extra
iteration can pick up a non-existent story and waste the user's budget.

Then summarise for the user: story count done, iterations used, the branch (`branchName`), and the
commits produced (`git log --oneline` on that branch). If any story was marked `passes: true` while
the subagent reported it could not verify something (no browser capability, skipped tests), say so
explicitly instead of repeating "all stories pass" as if it were fully verified.

If the user was watching the live board, the page already shows this state; mention that it is
current rather than repeating every number from it.

## Step 3: Report a blocked loop

If the loop ends without completing — max iterations reached, or a repeated no-progress story —
close the run in the event log the same way, with `blocked`:

```bash
bash "<plugin-root>/scripts/ralph-event.sh" --dir "<PROJECT_DIR>" --type stopped \
  --iteration <N> --story <STUCK_STORY_ID> --status blocked --driver in-session
```

Then report and stop:

- Which story is stuck (`next`), how many iterations it consumed, and what the iterations reported
- What `progress.txt` says the blocker is
- What the user must decide (split the story, fix the environment, or answer an open requirement)

Do not mark a stuck story `passes: true` yourself, and do not "fix" the PRD to make the loop look
green. A blocked story left at `passes: false` is the correct end state.

## Contract summary

- One story per iteration; one fresh subagent per iteration; never batch stories into one agent.
- This session never writes product code, never commits, and never edits `prd.json`.
- The subagent owns: the implementation, the project's checks, the commit, `passes: true`, and the
  `progress.txt` entry.
- The script owns: archiving, progress initialisation, prompt rendering, and state reporting.
- You own the event log: one `iteration_start` / `iteration_end` per iteration, then `complete` or
  `stopped`. It is best-effort; a failed write must never abort an iteration.
- Completion is `remaining == 0` read from the script — not the subagent's prose, not the token.
- `.ralph/` holds harness state and self-ignores via a generated `.gitignore`, so a story's
  `git add -A` cannot commit it. `prd.json` and `progress.txt` *are* meant to be committed — they
  are the loop's memory across iterations.
