#!/usr/bin/env bash
# Ralph dashboard — append one stage event to <project>/.ralph/events.jsonl.
#
# The dashboard reads this file to show *facts* (which iteration is running, on
# which story, and how the last one ended) instead of guessing from commits and
# PRD state. Both drivers write here:
#   - the ralph-run skill, around each fresh-context subagent
#   - scripts/ralph.sh, around each headless iteration
#
# One JSON object per line, append-only. Each record carries both an ISO timestamp
# (human) and epoch seconds (machine) so readers never have to parse time zones.
#
# Usage:
#   ralph-event.sh --type TYPE [--iteration N] [--story US-001] [--status done|blocked|none]
#                  [--driver in-session|headless] [--max N] [--dir DIR] [--echo]
#
# Types: preflight | iteration_start | iteration_end | agent_start | agent_end
#        | complete | stopped
#
# Never fails the loop on a bad input: an unknown --type is reported and skipped
# (exit 0), because losing a dashboard event must not abort an iteration.

set -euo pipefail

DIR="$PWD"
TYPE=""
ITERATION="0"
STORY=""
STATUS=""
DRIVER=""
MAX=""
ECHO_EVENT=false

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dir) DIR="${2:-}"; shift 2 ;;
    --dir=*) DIR="${1#*=}"; shift ;;
    --type) TYPE="${2:-}"; shift 2 ;;
    --type=*) TYPE="${1#*=}"; shift ;;
    --iteration) ITERATION="${2:-}"; shift 2 ;;
    --iteration=*) ITERATION="${1#*=}"; shift ;;
    --story) STORY="${2:-}"; shift 2 ;;
    --story=*) STORY="${1#*=}"; shift ;;
    --status) STATUS="${2:-}"; shift 2 ;;
    --status=*) STATUS="${1#*=}"; shift ;;
    --driver) DRIVER="${2:-}"; shift 2 ;;
    --driver=*) DRIVER="${1#*=}"; shift ;;
    --max) MAX="${2:-}"; shift 2 ;;
    --max=*) MAX="${1#*=}"; shift ;;
    --echo) ECHO_EVENT=true; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

case "$TYPE" in
  preflight|iteration_start|iteration_end|agent_start|agent_end|complete|stopped) ;;
  "") die "--type is required (see --help)" ;;
  *) echo "Warning: unknown event type '$TYPE' — event skipped" >&2; exit 0 ;;
esac

[[ "$ITERATION" =~ ^[0-9]+$ ]] || die "--iteration must be a number, got '$ITERATION'"
if [[ -n "$MAX" && ! "$MAX" =~ ^[0-9]+$ ]]; then die "--max must be a number, got '$MAX'"; fi
case "${STATUS:-x}" in
  x|done|blocked|none|"") ;;
  *) echo "Warning: unexpected status '$STATUS' (expected done|blocked|none)" >&2 ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq on macOS)"

[[ "$DIR" = /* ]] || DIR="$PWD/$DIR"
[[ -d "$DIR" ]] || die "project directory not found: $DIR"

mkdir -p "$DIR/.ralph"
# Harness state stays out of commits, even if a story runs `git add -A`.
[[ -f "$DIR/.ralph/.gitignore" ]] || printf '*\n' > "$DIR/.ralph/.gitignore"

EVENT="$(jq -cn \
  --arg ts "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
  --argjson epoch "$(date +%s)" \
  --arg type "$TYPE" \
  --argjson iteration "$ITERATION" \
  --arg story "$STORY" \
  --arg status "$STATUS" \
  --arg driver "$DRIVER" \
  --arg max "$MAX" \
  '{ts: $ts, epoch: $epoch, type: $type, iteration: $iteration,
    story: (if $story == "" then null else $story end),
    status: (if $status == "" then null else $status end),
    driver: (if $driver == "" then null else $driver end),
    max: (if $max == "" then null else ($max | tonumber) end)}')" \
  || die "could not build the event record"

printf '%s\n' "$EVENT" >> "$DIR/.ralph/events.jsonl"

if [[ "$ECHO_EVENT" == true ]]; then printf '%s\n' "$EVENT"; fi
