#!/usr/bin/env bash
# Ralph dashboard — read-only state extractor.
#
# Reads what the loop already leaves on disk and prints ONE JSON object:
#   prd.json              story list, priorities, passes, acceptance criteria, branch
#   progress.txt          per-iteration entries + the "Codebase Patterns" section
#   git log               the commit per story (`feat: US-XXX - …`) incl. per-file numstat
#   git status            dirty working tree (a story is mid-implementation)
#   .ralph/events.jsonl   precise stage events written by the loop drivers
#   archive/*/            completed previous runs
#
# Read-only: it never writes inside the project. The local server, the snapshot
# export and the in-session fragment all render what this prints, so the page
# cannot disagree with the artifacts.
#
# Usage:
#   ralph-state.sh [--dir DIR] [--prd FILE] [--progress FILE] [--events FILE]
#                  [--archive DIR] [--compact]
#
# Exit status is 0 whenever a JSON document was produced — degraded states
# (no PRD, invalid PRD, not a git repo, no events yet) are reported inside the
# JSON in `errors` and `loop.source`, never by exit code.
#
# Bash 3.2 compatible on purpose (macOS ships 3.2): no arrays, no mapfile.

set -euo pipefail

PROJECT_DIR="$PWD"
PRD_FILE=""
PROGRESS_FILE=""
EVENTS_FILE=""
ARCHIVE_DIR=""
PRETTY=true

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --dir=*) PROJECT_DIR="${1#*=}"; shift ;;
    --prd) PRD_FILE="${2:-}"; shift 2 ;;
    --prd=*) PRD_FILE="${1#*=}"; shift ;;
    --progress) PROGRESS_FILE="${2:-}"; shift 2 ;;
    --progress=*) PROGRESS_FILE="${1#*=}"; shift ;;
    --events) EVENTS_FILE="${2:-}"; shift 2 ;;
    --events=*) EVENTS_FILE="${1#*=}"; shift ;;
    --archive) ARCHIVE_DIR="${2:-}"; shift 2 ;;
    --archive=*) ARCHIVE_DIR="${1#*=}"; shift ;;
    --compact) PRETTY=false; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$PROJECT_DIR" = /* ]] || PROJECT_DIR="$PWD/$PROJECT_DIR"
[[ -d "$PROJECT_DIR" ]] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

PRD_FILE="${PRD_FILE:-$PROJECT_DIR/prd.json}"
PROGRESS_FILE="${PROGRESS_FILE:-$PROJECT_DIR/progress.txt}"
EVENTS_FILE="${EVENTS_FILE:-$PROJECT_DIR/.ralph/events.jsonl}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$PROJECT_DIR/archive}"

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq on macOS)"

NOW="$(date +%s)"
GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ERRORS=""

append_error() { ERRORS="${ERRORS}$1
"; }

# Anything handed to jq as --argjson must be valid JSON. A producer that emits
# nothing (empty repo, git failure) or garbage would otherwise abort the whole
# aggregation, so every value goes through this guard.
json_or() { # $1 = candidate value, $2 = fallback JSON
  if [[ -n "$1" ]] && printf '%s' "$1" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$1"
  else
    printf '%s' "$2"
  fi
}

# --- PRD ---------------------------------------------------------------------

PRD_USABLE=false
if [[ ! -f "$PRD_FILE" ]]; then
  append_error "prd.json not found at $PRD_FILE — generate the PRD (/prd) and convert it (/ralph) first"
elif ! jq -e . "$PRD_FILE" >/dev/null 2>&1; then
  append_error "prd.json is not valid JSON — fix it, then reload"
elif ! jq -e '.userStories | type == "array"' "$PRD_FILE" >/dev/null 2>&1; then
  append_error "prd.json has no userStories array — convert the PRD with the ralph skill"
else
  PRD_USABLE=true
fi
PRD_SRC="$PRD_FILE"; [[ "$PRD_USABLE" == true ]] || PRD_SRC="/dev/null"

# --- events ------------------------------------------------------------------

EVENTS_SRC="/dev/null"
if [[ -f "$EVENTS_FILE" ]]; then
  if jq -e -c . "$EVENTS_FILE" >/dev/null 2>&1; then
    EVENTS_SRC="$EVENTS_FILE"
  else
    append_error ".ralph/events.jsonl has a malformed line — stage detection falls back to inference"
  fi
fi

# --- progress ----------------------------------------------------------------

PROGRESS_SRC="$PROGRESS_FILE"; [[ -f "$PROGRESS_FILE" ]] || PROGRESS_SRC="/dev/null"

# --- git ---------------------------------------------------------------------

IS_REPO=false
GIT_BRANCH=""
HEAD_JSON='null'
DIRTY_JSON='[]'
COMMITS_JSON='[]'
DIRTY_N=0

if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  IS_REPO=true
  # symbolic-ref works on an unborn branch (fresh repo, no commits) where
  # rev-parse --abbrev-ref prints the useless literal "HEAD".
  GIT_BRANCH="$(git -C "$PROJECT_DIR" symbolic-ref --short -q HEAD 2>/dev/null \
    || git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  HEAD_JSON="$(git -C "$PROJECT_DIR" log -1 --pretty=format:'%H%x1f%h%x1f%s%x1f%cI' 2>/dev/null \
    | jq -Rn '([inputs | split("\u001f")] | .[0]) as $h
              | if $h == null then null else {hash: $h[0], short: $h[1], subject: $h[2], ts: $h[3]} end' 2>/dev/null || true)"
  DIRTY_JSON="$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null \
    | jq -Rn '[inputs | select(length > 3) | {status: .[0:2], path: .[3:]}]' 2>/dev/null || true)"
  DIRTY_JSON="$(json_or "$DIRTY_JSON" '[]')"
  DIRTY_N="$(printf '%s' "$DIRTY_JSON" | jq 'length' 2>/dev/null || echo 0)"
  # Commits with per-file numstat, newest first. \x02 starts each commit block;
  # the first line of a block is hash/short/subject/date, the rest are numstat rows.
  COMMITS_JSON="$(git -C "$PROJECT_DIR" log -n 60 --no-renames --numstat \
      --pretty=format:$'\x02%H\x1f%h\x1f%s\x1f%cI' 2>/dev/null \
    | jq -Rn '([inputs] | join("\n") | split("\u0002") | .[1:]
              | map( split("\n") as $l
                     | ($l[0] | split("\u001f")) as $h
                     | select(($h | length) >= 4)
                     | { hash: $h[0], short: $h[1], subject: $h[2], ts: $h[3],
                         files: [ $l[1:][] | select(length > 0) | split("\t")
                                  | { add: (.[0] | tonumber?), del: (.[1] | tonumber?), path: .[2] } ] }))' 2>/dev/null || true)"
  COMMITS_JSON="$(json_or "$COMMITS_JSON" '[]')"
  HEAD_JSON="$(json_or "$HEAD_JSON" null)"
else
  append_error "$PROJECT_DIR is not a git repository — commits and dirty-tree signals are unavailable"
fi

# --- archive -----------------------------------------------------------------

ARCHIVE_JSON='[]'
if [[ -d "$ARCHIVE_DIR" ]]; then
  ARCHIVE_JSON="$(
    for d in "$ARCHIVE_DIR"/*/; do
      [[ -d "$d" ]] || continue
      name="$(basename "$d")"
      branch="$(head -1 "$d/branch.txt" 2>/dev/null || true)"
      hp=false; [[ -f "$d/progress.txt" ]] && hp=true
      if [[ -f "$d/prd.json" ]] && jq -e '.userStories | type == "array"' "$d/prd.json" >/dev/null 2>&1; then
        jq -c --arg dir "$name" --arg branch "$branch" --argjson hp "$hp" '{
          dir: $dir,
          branch: (if $branch != "" then $branch else (.branchName // null) end),
          description: (.description // .project // null),
          total: (.userStories | length),
          done: ([.userStories[] | select(.passes == true)] | length),
          has_prd: true, has_progress: $hp,
          stories: [.userStories[] | {id, title, priority, passes: (.passes == true)}]
        }' "$d/prd.json"
      else
        jq -cn --arg dir "$name" --arg branch "$branch" --argjson hp "$hp" '{
          dir: $dir,
          branch: (if $branch != "" then $branch else null end),
          description: null, total: 0, done: 0,
          has_prd: false, has_progress: $hp, stories: []
        }'
      fi
    done | jq -sc 'sort_by(.dir) | reverse' 2>/dev/null || true
  )"
fi
ARCHIVE_JSON="$(json_or "$ARCHIVE_JSON" '[]')"

ERRORS_JSON="$(printf '%s' "$ERRORS" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || true)"
ERRORS_JSON="$(json_or "$ERRORS_JSON" '[]')"

# --- aggregate ---------------------------------------------------------------
# One jq pass so the output is a single consistent snapshot of disk state.

JQ_PROGRAM='
  ( $prd[0] // null ) as $p
  | ( $p.userStories // [] ) as $raw
  | ( [ $progress | splits("\n## ") ] | .[1:]
      | map( (split("\n")) as $l | {heading: $l[0], body: ($l[1:] | join("\n"))} )
    ) as $secs
  | ( [ $secs[]
        | ( .heading | try capture("^\\[(?<ts>[^\\]]+)\\]\\s*-\\s*(?<sid>[A-Za-z0-9_.\\-]+)\\s*$") catch null ) as $m
        | select($m != null)
        | { ts: $m.ts, story: $m.sid,
            body: (.body | sub("(?m)\\n-{3,}[ \\t]*\\s*$"; "") | sub("\\s+$"; "")) } ]
    ) as $pentries
  | ( $secs | map(select(.heading | test("^Codebase[ _]Patterns")))
      | (.[0].body // "") | sub("(?m)\\n-{3,}[ \\t]*\\s*$"; "") ) as $patterns
  | ( $raw | map(
        . as $s
        | ( ( $commits | map(select(.subject | test("(^|[^A-Za-z0-9_])" + $s.id + "([^A-Za-z0-9_]|$)"))) | .[0] ) // null ) as $c
        | { id: $s.id, title: $s.title, description: ($s.description // ""),
            priority: ($s.priority // 999), passes: ($s.passes == true), notes: ($s.notes // ""),
            acceptanceCriteria: ($s.acceptanceCriteria // []),
            commit: $c,
            # every attempt this story has a progress entry for, oldest first —
            # a story that was retried twice must show both attempts
            progress: [ $pentries[] | select(.story == $s.id) ] } ) ) as $stories
  | ( $stories | map(select(.passes)) ) as $done_stories
  | ( $stories | map(select(.passes | not)) | sort_by(.priority) ) as $todo
  | ( $todo[0] // null ) as $next_story
  | ( $events ) as $ev
  | ( $ev | last ) as $last
  | ( $last != null and (($last.type // "") | IN("iteration_start", "agent_start")) ) as $running
  | ( if $last != null and ($last.epoch // null) != null then ($now - $last.epoch) else null end ) as $last_age
  | ( [ $ev[] | (.iteration // 0) ] | max // 0 ) as $iter_max
  | ( ([ $ev[] | (.max? // empty) ] | last) // null ) as $iter_cap
  | ( ( $ev | map(.driver? // empty) | last ) // "unknown" ) as $driver
  | ( reduce $ev[] as $e ( {order: [], m: {}};
        ( $e.iteration // 0 ) as $n
        | ( $n | tostring ) as $k
        | if $n < 1 then .
          elif $e.type == "iteration_start" then
            .m[$k] = ((.m[$k] // {n: $n})
              + { story: ($e.story // null), started: ($e.ts // null), started_epoch: ($e.epoch // null) })
            | if (.order | index($n)) == null then .order = (.order + [$n]) else . end
          elif $e.type == "iteration_end" then
            .m[$k] = ((.m[$k] // {n: $n})
              + { story: ((.m[$k].story) // ($e.story // null)),
                  ended: ($e.ts // null), ended_epoch: ($e.epoch // null), status: ($e.status // null) })
            | if (.order | index($n)) == null then .order = (.order + [$n]) else . end
          else . end
      ) ) as $acc
  | ( [ $acc.order[] | $acc.m[(. | tostring)] ] ) as $iterations
  | ( if $p == null then "no-prd"
      elif ($todo | length) == 0 then "done"
      elif $running then
        # An iteration is in flight. Once the story it is working on is committed
        # or already flipped to passes:true, what remains is the wrap-up
        # (prd.json / progress.txt), not the implementation.
        ( if ( ( $stories | map(select(.id == ($last.story // "")))
                   | .[0] | if . == null then null else ((.passes == true) or (.commit != null)) end ) // false )
          then "update-prd" else "implement" end )
      elif $last != null and $last.type == "stopped" then
        # A recorded stop is a fact, not an inference: the loop is not running any more.
        ( if $last.status == "blocked" then "blocked" else "idle" end )
      elif $last != null and $last.type == "iteration_end" and $last.status == "blocked" then "blocked"
      elif $last_age == null or $last_age > 600 then "idle"
      else "between" end ) as $stage
  | ( if $running or $stage == "blocked" then ($last.story // null) else ($next_story.id // null) end ) as $active_id
  | ( { "no-prd": 1, implement: 5, "update-prd": 8, blocked: 10, between: 4, idle: 4, done: 11 }[$stage] ) as $stage_node
  | ( { "no-prd": "等待 PRD", implement: "实现中", "update-prd": "收尾（更新 prd.json / progress.txt）",
        blocked: "已卡住", between: "轮次间隙", idle: "循环未运行", done: "全部完成" }[$stage] ) as $stage_label
  | {
      schema: 1,
      generated_at: $generated_at,
      now_epoch: $now,
      project: {
        dir: $dir, is_git_repo: $is_repo, branch: $branch, head: $head,
        dirty: (($dirty | length) > 0), dirty_files: $dirty
      },
      prd: ( if $p == null then null else {
        path: $prd_path,
        project: ($p.project // null),
        branchName: ($p.branchName // null),
        description: ($p.description // null),
        counts: { total: ($stories | length), done: ($done_stories | length), remaining: ($todo | length) },
        next: ($next_story.id // null),
        stories: $stories
      } end ),
      patterns_md: $patterns,
      progress_entries: $pentries,
      loop: {
        driver: $driver, running: $running,
        stale: ($running and $last_age != null and $last_age > 1800),
        iteration: $iter_max, max_iterations: $iter_cap,
        stage: $stage, stage_node: $stage_node, stage_label: $stage_label,
        story: $active_id, last_event: $last, last_event_age_sec: $last_age,
        source: ( if ($ev | length) > 0 then "events" else "inferred" end )
      },
      iterations: $iterations,
      recent_commits: ($commits | .[0:8]),
      archive: $archive,
      errors: $errors
    }
'

set +e
OUTPUT="$(jq -n \
  --argjson now "$NOW" \
  --arg generated_at "$GENERATED_AT" \
  --arg dir "$PROJECT_DIR" \
  --arg prd_path "$PRD_FILE" \
  --arg branch "$GIT_BRANCH" \
  --argjson is_repo "$IS_REPO" \
  --argjson head "$HEAD_JSON" \
  --argjson dirty "$DIRTY_JSON" \
  --argjson commits "$COMMITS_JSON" \
  --argjson archive "$ARCHIVE_JSON" \
  --argjson errors "$ERRORS_JSON" \
  --slurpfile prd "$PRD_SRC" \
  --slurpfile events "$EVENTS_SRC" \
  --rawfile progress "$PROGRESS_SRC" \
  "$JQ_PROGRAM")"
STATUS=$?
set -e

if [[ $STATUS -ne 0 || -z "$OUTPUT" ]]; then
  die "state aggregation failed (jq exit $STATUS) — check prd.json and .ralph/events.jsonl"
fi

if [[ "$PRETTY" == true ]]; then printf '%s\n' "$OUTPUT" | jq .; else printf '%s\n' "$OUTPUT"; fi
