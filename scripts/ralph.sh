#!/usr/bin/env bash
# Ralph — long-running autonomous agent loop.
#
# Usage:
#   ralph.sh [options] [max_iterations]
#
# Options:
#   --dir DIR            Project directory holding prd.json / progress.txt (default: $PWD)
#   --tool TOOL          amp | claude | custom (default: claude)
#   --cmd CMD            Shell command for --tool custom; receives the prompt on stdin
#   --prompt FILE        Iteration prompt template (default: <plugin>/templates/iteration-prompt.md)
#   --prd FILE           PRD path (default: <dir>/prd.json)
#   --progress FILE      Progress log path (default: <dir>/progress.txt)
#   --max-iterations N   Maximum iterations (default: 10)
#   --prepare-only       Do the preflight/archive/progress setup, print state as JSON, exit
#   --render-prompt N    Print the iteration prompt for iteration N, exit (no agent is spawned)
#
# ZCode users normally do not run this script: the in-session `ralph-run` skill drives the
# same loop with a fresh-context subagent per iteration. This script is the headless path
# for people who already have a coding CLI (amp / claude) or their own agent command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_DIR="$PWD"
TOOL="claude"
AGENT_CMD=""
PROMPT_TEMPLATE="$PLUGIN_ROOT/templates/iteration-prompt.md"
PRD_FILE=""
PROGRESS_FILE=""
MAX_ITERATIONS=10
PREPARE_ONLY=false
RENDER_PROMPT=""

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --dir=*) PROJECT_DIR="${1#*=}"; shift ;;
    --tool) TOOL="${2:-}"; shift 2 ;;
    --tool=*) TOOL="${1#*=}"; shift ;;
    --cmd) AGENT_CMD="${2:-}"; shift 2 ;;
    --cmd=*) AGENT_CMD="${1#*=}"; shift ;;
    --prompt) PROMPT_TEMPLATE="${2:-}"; shift 2 ;;
    --prompt=*) PROMPT_TEMPLATE="${1#*=}"; shift ;;
    --prd) PRD_FILE="${2:-}"; shift 2 ;;
    --prd=*) PRD_FILE="${1#*=}"; shift ;;
    --progress) PROGRESS_FILE="${2:-}"; shift 2 ;;
    --progress=*) PROGRESS_FILE="${1#*=}"; shift ;;
    --max-iterations) MAX_ITERATIONS="${2:-}"; shift 2 ;;
    --max-iterations=*) MAX_ITERATIONS="${1#*=}"; shift ;;
    --prepare-only) PREPARE_ONLY=true; shift ;;
    --render-prompt) RENDER_PROMPT="${2:-}"; shift 2 ;;
    --render-prompt=*) RENDER_PROMPT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Warning: ignoring unknown argument '$1'" >&2
      fi
      shift
      ;;
  esac
done

[[ "$PROJECT_DIR" = /* ]] || PROJECT_DIR="$PWD/$PROJECT_DIR"
[[ -d "$PROJECT_DIR" ]] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

PRD_FILE="${PRD_FILE:-$PROJECT_DIR/prd.json}"
PROGRESS_FILE="${PROGRESS_FILE:-$PROJECT_DIR/progress.txt}"
ARCHIVE_DIR="$PROJECT_DIR/archive"
STATE_DIR="$PROJECT_DIR/.ralph"
LAST_BRANCH_FILE="$STATE_DIR/last-branch"

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq on macOS)"
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJECT_DIR is not a git repository"
[[ -f "$PRD_FILE" ]] || die "PRD not found: $PRD_FILE — generate it first (prd skill), then convert it (ralph skill)"
# An iteration edits this file with jq. If one ever leaves it malformed, fail with a readable
# message instead of a bare jq parse error three functions down.
jq -e '.userStories | type == "array"' "$PRD_FILE" >/dev/null 2>&1 \
  || die "$PRD_FILE is not valid PRD JSON (needs a userStories array) — fix it, then rerun"

# Harness state (rendered prompts, last-branch marker) is not project content. Self-ignore the
# directory so a story's `git add -A` cannot sweep it into a commit.
mkdir -p "$STATE_DIR"
[[ -f "$STATE_DIR/.gitignore" ]] || printf '*\n' > "$STATE_DIR/.gitignore"

# --- state helpers -----------------------------------------------------------------

init_progress() {
  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } > "$PROGRESS_FILE"
}

prd_branch() { jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo ""; }
prd_remaining() { jq '[.userStories[] | select(.passes == false)] | length' "$PRD_FILE"; }
prd_next() { jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority) | .[0].id // "none"' "$PRD_FILE"; }

# Safety net only: the ralph skill archives properly *before* overwriting a PRD. If prd.json
# was swapped by hand, the previous PRD is already gone — archive what survives and record
# the branch so the run history is still traceable.
archive_previous_run() {
  local last_branch="$1"
  local folder_name archive_folder
  folder_name="$(echo "$last_branch" | sed 's|^ralph/||')"
  archive_folder="$ARCHIVE_DIR/$(date +%Y-%m-%d)-$folder_name"
  mkdir -p "$archive_folder"
  [[ -f "$PROGRESS_FILE" ]] && cp "$PROGRESS_FILE" "$archive_folder/"
  printf '%s\n' "$last_branch" > "$archive_folder/branch.txt"
  if [[ -f "$PRD_FILE" ]] && [[ "$(prd_branch)" == "$last_branch" ]]; then
    cp "$PRD_FILE" "$archive_folder/"
  else
    echo "Note: previous prd.json was already replaced by the current feature; only progress.txt is archived." >&2
  fi
  echo "Archived previous run ($last_branch) to: $archive_folder"
}

# --- preflight ---------------------------------------------------------------------

CURRENT_BRANCH="$(prd_branch)"
[[ -n "$CURRENT_BRANCH" ]] || die "prd.json has no branchName; convert the PRD with the ralph skill first"

if [[ -f "$LAST_BRANCH_FILE" ]]; then
  LAST_BRANCH="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")"
  if [[ -n "$LAST_BRANCH" && "$CURRENT_BRANCH" != "$LAST_BRANCH" ]]; then
    archive_previous_run "$LAST_BRANCH"
    init_progress
  fi
fi
printf '%s\n' "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
[[ -f "$PROGRESS_FILE" ]] || init_progress

REMAINING="$(prd_remaining)"
NEXT_STORY="$(prd_next)"

[[ -f "$PROMPT_TEMPLATE" ]] || die "iteration prompt template not found: $PROMPT_TEMPLATE"

render_prompt() {
  local iteration="$1" content
  content="$(cat "$PROMPT_TEMPLATE")"
  content="${content//\{\{PROJECT_DIR\}\}/$PROJECT_DIR}"
  content="${content//\{\{PRD_PATH\}\}/$PRD_FILE}"
  content="${content//\{\{PROGRESS_PATH\}\}/$PROGRESS_FILE}"
  content="${content//\{\{ITERATION\}\}/$iteration}"
  content="${content//\{\{MAX_ITERATIONS\}\}/$MAX_ITERATIONS}"
  printf '%s\n' "$content"
}

if [[ -n "$RENDER_PROMPT" ]]; then
  [[ "$RENDER_PROMPT" =~ ^[0-9]+$ ]] || die "--render-prompt needs an iteration number"
  render_prompt "$RENDER_PROMPT"
  exit 0
fi

if [[ "$PREPARE_ONLY" == true ]]; then
  jq -n \
    --arg project "$PROJECT_DIR" \
    --arg prd "$PRD_FILE" \
    --arg progress "$PROGRESS_FILE" \
    --arg branch "$CURRENT_BRANCH" \
    --arg next "$NEXT_STORY" \
    --argjson remaining "$REMAINING" \
    --arg completed "$(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE")" \
    '{project: $project, prd: $prd, progress: $progress, branch: $branch,
      remaining: $remaining, completed: ($completed | tonumber), next: $next}'
  exit 0
fi

# --- agent command -----------------------------------------------------------------

if [[ "$TOOL" == "custom" ]]; then
  AGENT_CMD="${AGENT_CMD:-${RALPH_AGENT_CMD:-}}"
  [[ -n "$AGENT_CMD" ]] || die "--tool custom needs --cmd \"...\" or RALPH_AGENT_CMD (the prompt arrives on stdin)"
  TOOL_LABEL="$AGENT_CMD"
elif [[ "$TOOL" == "amp" || "$TOOL" == "claude" ]]; then
  command -v "$TOOL" >/dev/null 2>&1 || die "'$TOOL' is not on PATH. Use --tool custom with your own agent command, or run the in-session ralph-run skill instead."
  TOOL_LABEL="$TOOL"
else
  die "invalid tool '$TOOL' (expected amp, claude or custom)"
fi

[[ -f "$PROMPT_TEMPLATE" ]] || die "iteration prompt template not found: $PROMPT_TEMPLATE"

run_agent() {
  local prompt_file="$1"
  # The agent must run *inside* the project; output is echoed for the operator and captured
  # for the completion check. A failed agent run must not abort the loop.
  case "$TOOL" in
    amp)    (cd "$PROJECT_DIR" && amp --dangerously-allow-all < "$prompt_file" 2>&1 | tee /dev/stderr) || true ;;
    claude) (cd "$PROJECT_DIR" && claude --dangerously-skip-permissions --print < "$prompt_file" 2>&1 | tee /dev/stderr) || true ;;
    custom) (cd "$PROJECT_DIR" && sh -c "$AGENT_CMD" < "$prompt_file" 2>&1 | tee /dev/stderr) || true ;;
  esac
}

# --- loop --------------------------------------------------------------------------

echo "Starting Ralph — tool: $TOOL_LABEL — project: $PROJECT_DIR"
echo "Branch: $CURRENT_BRANCH — stories remaining: $REMAINING/$((REMAINING + $(jq '[.userStories[] | select(.passes == true)] | length' "$PRD_FILE"))) — max iterations: $MAX_ITERATIONS"

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL_LABEL)"
  echo "==============================================================="

  PROMPT_FILE="$STATE_DIR/iteration-$i-prompt.md"
  render_prompt "$i" > "$PROMPT_FILE"

  OUTPUT="$(run_agent "$PROMPT_FILE")"

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  REMAINING="$(prd_remaining)"
  echo "Iteration $i complete. Stories remaining: $REMAINING"
  if [[ "$REMAINING" -eq 0 ]]; then
    echo "Ralph completed all tasks (all stories have passes: true)."
    exit 0
  fi

  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
