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
#   tasks/*.md            PRD documents: index metadata always, full text on request
#
# Read-only: it never writes inside the project. The local server, the snapshot
# export and the in-session fragment all render what this prints, so the page
# cannot disagree with the artifacts.
#
# Usage:
#   ralph-state.sh [--dir DIR] [--prd FILE] [--progress FILE] [--events FILE]
#                  [--archive DIR] [--docs-dir DIR] [--docs-content N] [--compact]
#
# PRD documents are indexed by metadata only (a real project's tasks/ can hold
# hundreds of KB); --docs-content N additionally embeds up to N bytes per document
# so a snapshot or an in-session fragment can render them offline.
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
DOCS_DIR=""
DOCS_CONTENT=0
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
    --docs-dir) DOCS_DIR="${2:-}"; shift 2 ;;
    --docs-dir=*) DOCS_DIR="${1#*=}"; shift ;;
    --docs-content) DOCS_CONTENT="${2:-0}"; shift 2 ;;
    --docs-content=*) DOCS_CONTENT="${1#*=}"; shift ;;
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
DOCS_DIR="${DOCS_DIR:-$PROJECT_DIR/tasks}"
[[ "$DOCS_CONTENT" =~ ^[0-9]+$ ]] || die "--docs-content needs a byte count, got '$DOCS_CONTENT'"

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

# --- PRD documents (tasks/) ---------------------------------------------------
# Indexed by metadata only: a real tasks/ directory can hold several hundred KB, and
# this document is re-read on every dashboard poll. --docs-content N embeds the text
# (capped) for the snapshot/fragment paths, which cannot fetch on demand later.

# Story titles from prd.json: the stable link between the JSON and its source docs.
# (ids collide across documents; a merged prd.json even re-prefixes them.)
PRD_TITLES_JSON='[]'
if [[ "$PRD_USABLE" == true ]]; then
  PRD_TITLES_JSON="$(jq -c '[.userStories[] | (.title // "")]' "$PRD_FILE" 2>/dev/null || echo '[]')"
  PRD_TITLES_JSON="$(json_or "$PRD_TITLES_JSON" '[]')"
fi

DOCS_JSON='[]'
if [[ -d "$DOCS_DIR" ]]; then
  DOCS_JSON="$(
    for f in "$DOCS_DIR"/*.md "$DOCS_DIR"/*.markdown; do
      [[ -f "$f" ]] || continue
      name="$(basename "$f")"
      bytes="$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)"
      mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
      mti="$(date -r "$mt" +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || echo "")"
      # Story headings (### US-001: … / ### PWT-003: …). The id prefix is NOT a reliable
      # source marker — several documents in one tasks/ dir reuse "US-NNN" numbering —
      # so the title (which prd.json copies verbatim) is what identifies a source doc.
      ids="$(grep -oE '^#{2,4}[[:space:]]+[A-Za-z]+-[A-Za-z0-9_-]+' "$f" 2>/dev/null \
             | sed -E 's/^#+[[:space:]]+//' | sort -u || true)"
      titles="$(grep -oE '^#{2,4}[[:space:]]+[A-Za-z]+-[A-Za-z0-9_-]+:[[:space:]]*.*$' "$f" 2>/dev/null \
                | sed -E 's/^#+[[:space:]]+[A-Za-z]+-[A-Za-z0-9_-]+:[[:space:]]*//' | sed -E 's/[[:space:]]+$//' || true)"
      boxes="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' "$f" 2>/dev/null || true)"
      checked="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$f" 2>/dev/null || true)"
      h1="$(grep -m1 -E '^#[[:space:]]+' "$f" 2>/dev/null | sed -E 's/^#[[:space:]]+//' || true)"
      prd_heads="$(grep -cE '^#[[:space:]]+PRD' "$f" 2>/dev/null || true)"
      # Only read the body when the caller asked for content AND this file fits the cap.
      # (bash 3.2 with `set -u` rejects expanding an empty array, so the two cases are
      # built as separate program strings instead of a conditional element list.)
      if [[ "$DOCS_CONTENT" -gt 0 ]] && [[ "$bytes" -le "$DOCS_CONTENT" ]]; then
        jq -cn --arg file "$name" --argjson bytes "${bytes:-0}" --argjson mt "${mt:-0}" \
          --arg mti "$mti" --arg h1 "$h1" \
          --argjson ids "$(printf '%s' "$ids" | jq -Rsc 'split("\n")|map(select(length>0))')" \
          --argjson boxes "${boxes:-0}" --argjson checked "${checked:-0}" \
          --argjson prd_heads "${prd_heads:-0}" --argjson prd_titles "$PRD_TITLES_JSON" \
          --argjson titles "$(printf '%s' "$titles" | jq -Rsc 'split("\n")|map(select(length>0))')" \
          --rawfile body "$f" '
          { file: $file, path: ("tasks/" + $file), bytes: $bytes,
            mtime: $mt, mtime_iso: (if $mti == "" then null else $mti end),
            title: (if $h1 == "" then ($file | sub("\\.(md|markdown)$"; "")) else $h1 end),
            story_ids: $ids, stories: ($ids | length),
            is_prd: (($ids | length) > 0 or $prd_heads > 0),
            checkboxes: { total: $boxes, checked: $checked, open: ($boxes - $checked) },
            matches_prd_json: ([ $titles[] | select(. as $t | $prd_titles | index($t)) ] | length),
            content: $body }'
      else
        jq -cn --arg file "$name" --argjson bytes "${bytes:-0}" --argjson mt "${mt:-0}" \
          --arg mti "$mti" --arg h1 "$h1" \
          --argjson ids "$(printf '%s' "$ids" | jq -Rsc 'split("\n")|map(select(length>0))')" \
          --argjson boxes "${boxes:-0}" --argjson checked "${checked:-0}" \
          --argjson prd_heads "${prd_heads:-0}" --argjson prd_titles "$PRD_TITLES_JSON" \
          --argjson titles "$(printf '%s' "$titles" | jq -Rsc 'split("\n")|map(select(length>0))')" '
          { file: $file, path: ("tasks/" + $file), bytes: $bytes,
            mtime: $mt, mtime_iso: (if $mti == "" then null else $mti end),
            title: (if $h1 == "" then ($file | sub("\\.(md|markdown)$"; "")) else $h1 end),
            story_ids: $ids, stories: ($ids | length),
            is_prd: (($ids | length) > 0 or $prd_heads > 0),
            checkboxes: { total: $boxes, checked: $checked, open: ($boxes - $checked) },
            matches_prd_json: ([ $titles[] | select(. as $t | $prd_titles | index($t)) ] | length) }'
      fi
    done | jq -sc 'sort_by(.mtime) | reverse' 2>/dev/null || true
  )"
fi
DOCS_JSON="$(json_or "$DOCS_JSON" '[]')"

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
  | ( ([ $ev[] | (.max? // empty) ] | last) // null ) as $cap_fallback
  | ( ( $ev | map(.driver? // empty) | last ) // "unknown" ) as $driver
  # Iteration numbers restart at 1 on every run, so they are NOT unique across the
  # history of a project. Tag each event with its run first (a preflight opens one;
  # with the in-session driver there is no preflight, so a number that fails to
  # advance marks the boundary), then pair start/end within a run.
  | ( reduce $ev[] as $e ( {run: 0, last_n: null, tag: []};
        ( $e.iteration // 0 ) as $n
        | if $e.type == "preflight" then
            .run += 1 | .last_n = null
          elif $e.type == "iteration_start" then
            ( if .run == 0 then .run = 1
              elif (.last_n != null and $n <= .last_n) then .run += 1
              else . end )
            | .last_n = $n
          else . end
        | .tag += [ ($e + {run: .run}) ]
      ) ) as $tagged
  | ( reduce ( $tagged.tag[] | select(.run > 0) ) as $e ( [];
        if $e.type == "iteration_start" then
          . + [ { run: $e.run, n: ($e.iteration // 0), story: ($e.story // null),
                  started: ($e.ts // null), started_epoch: ($e.epoch // null),
                  ended: null, ended_epoch: null, status: null } ]
        elif $e.type == "iteration_end" then
          ( $e.run ) as $er
          | ( $e.iteration // 0 ) as $en
          | [ .[] | if (.run == $er and .n == $en and .ended == null)
                  then . + { story: (.story // ($e.story // null)),
                             ended: ($e.ts // null), ended_epoch: ($e.epoch // null),
                             status: ($e.status // null) }
                  else . end ]
        else . end
      ) ) as $iterations
  | ( $iterations | last ) as $last_iter
  | ( $iterations | map(.run) | unique | length ) as $run_count
  # "第 N 轮" means N within the run the loop is on now, not a max across history.
  | ( $last_iter.n // 0 ) as $cur_iter
  | ( $last_iter.run // 0 ) as $cur_run
  # The iteration cap belongs to the run it was passed to — every run can use a
  # different --max-iterations, so a global "last max" would contradict the count.
  | ( ([ $tagged.tag[] | select(.run == $cur_run) | (.max? // empty) ] | last) // $cap_fallback ) as $iter_cap
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
        iteration: $cur_iter, run: $cur_run, runs: $run_count,
        total_iterations: ($iterations | length),
        max_iterations: $iter_cap,
        stage: $stage, stage_node: $stage_node, stage_label: $stage_label,
        story: $active_id, last_event: $last, last_event_age_sec: $last_age,
        source: ( if ($ev | length) > 0 then "events" else "inferred" end )
      },
      iterations: $iterations,
      recent_commits: ($commits | .[0:8]),
      archive: $archive,
      docs: {
        dir: $docs_dir,
        count: ($docs | length),
        # Which documents prd.json was generated from. A single-PRD project has one;
        # a merged prd.json has several, so this stays a list rather than one "current".
        # Matching is on story titles, because ids are reused across documents.
        sources: ( [ $docs[] | select(.is_prd) | select(.matches_prd_json > 0) ]
                   | sort_by(-.matches_prd_json)
                   | map({ path: .path, file: .file, title: .title,
                           stories: .stories, matched: .matches_prd_json }) ),
        items: $docs
      },
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
  --argjson docs "$DOCS_JSON" \
  --arg docs_dir "$DOCS_DIR" \
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
