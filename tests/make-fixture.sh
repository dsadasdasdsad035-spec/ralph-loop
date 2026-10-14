#!/usr/bin/env bash
# Build a fixture project for the Ralph dashboard in one of three states:
#   running   — iteration 3 in flight, 2/4 stories done, dirty working tree
#   complete  — all 4 stories done
#   blocked   — US-003 failed twice, loop stopped
# All timestamps are relative to now so recent/relative-time logic is exercised.
set -euo pipefail

STATE="${1:-running}"
FIX_ROOT="${RALPH_TEST_DIR:-${TMPDIR:-/tmp}/ralph-plugin-tests}"
ROOT="${2:-$FIX_ROOT/proj-$STATE}"
NOW=$(date +%s)

iso()  { date -r "$1" +"%Y-%m-%dT%H:%M:%S%z"; }
human(){ date -r "$1" +"%Y-%m-%d %H:%M"; }
ago()  { echo $((NOW - $1)); }

rm -rf "$ROOT"
mkdir -p "$ROOT/.ralph" "$ROOT/src" "$ROOT/archive/2026-10-08-old-feature"
cd "$ROOT"

git init -q -b main
git config user.email "dev@example.com"
git config user.name "Dev"
printf '*\n' > .ralph/.gitignore
printf 'node_modules/\n.ralph/\n' > .gitignore

cat > package.json <<'EOF'
{ "name": "myapp", "scripts": { "typecheck": "tsc --noEmit", "test": "node --test" } }
EOF
cat > src/tasks.ts <<'EOF'
export type Priority = 'high' | 'medium' | 'low';
export interface Task { id: string; title: string; priority: Priority }
EOF
GIT_AUTHOR_DATE="$(iso $((NOW - 7200)))" GIT_COMMITTER_DATE="$(iso $((NOW - 7200)))" \
  git add -A && GIT_AUTHOR_DATE="$(iso $((NOW - 7200)))" GIT_COMMITTER_DATE="$(iso $((NOW - 7200)))" git commit -qm "chore: initial scaffold"

case "$STATE" in
  running|blocked) P1=true; P2=true; P3=false; P4=false ;;
  complete)        P1=true; P2=true; P3=true;  P4=true  ;;
  *) echo "unknown state: $STATE" >&2; exit 1 ;;
esac

jq -n --argjson p1 "$P1" --argjson p2 "$P2" --argjson p3 "$P3" --argjson p4 "$P4" '
{
  project: "MyApp",
  branchName: "ralph/task-priority",
  description: "Task Priority System - Add priority levels to tasks",
  userStories: [
    { id: "US-001", title: "Add priority field to database",
      description: "As a developer, I need to store task priority so it persists across sessions.",
      acceptanceCriteria: ["Add priority column to tasks table: high|medium|low (default medium)",
                           "Generate and run migration successfully", "Typecheck passes"],
      priority: 1, passes: $p1, notes: "" },
    { id: "US-002", title: "Display priority indicator on task cards",
      description: "As a user, I want to see task priority at a glance.",
      acceptanceCriteria: ["Each task card shows a colored priority badge (red=high, yellow=medium, gray=low)",
                           "Priority visible without hovering or clicking", "Typecheck passes",
                           "Verify in browser using browser skill"],
      priority: 2, passes: $p2, notes: "" },
    { id: "US-003", title: "Add priority selector to task edit",
      description: "As a user, I want to change a task'"'"'s priority when editing it.",
      acceptanceCriteria: ["Priority dropdown in task edit modal", "Shows current priority as selected",
                           "Saves immediately on selection change", "Typecheck passes",
                           "Verify in browser using browser skill"],
      priority: 3, passes: $p3, notes: "" },
    { id: "US-004", title: "Filter tasks by priority",
      description: "As a user, I want to filter the task list to see only high-priority items.",
      acceptanceCriteria: ["Filter dropdown with options: All | High | Medium | Low",
                           "Filter persists in URL params", "Empty state message when no tasks match filter",
                           "Typecheck passes", "Verify in browser using browser skill"],
      priority: 4, passes: $p4, notes: "" }
  ]
}' > prd.json

git checkout -qb ralph/task-priority

commit_at() { local e="$1" m="$2"; GIT_AUTHOR_DATE="$(iso $e)" GIT_COMMITTER_DATE="$(iso $e)" git commit -qm "$m"; }

cat > src/db.ts <<'EOF'
export const MIGRATIONS = ["ALTER TABLE tasks ADD COLUMN priority TEXT DEFAULT 'medium'"];
EOF
git add -A; commit_at $((NOW - 5100)) "feat: US-001 - Add priority field to database"

cat > src/taskCard.ts <<'EOF'
export function priorityBadge(p: 'high'|'medium'|'low') {
  return { high: 'red', medium: 'yellow', low: 'gray' }[p];
}
EOF
git add -A; commit_at $((NOW - 4200)) "feat: US-002 - Display priority indicator on task cards"

if [[ "$STATE" == "complete" ]]; then
  cat > src/prioritySelect.ts <<'EOF'
export const PRIORITIES = ['high', 'medium', 'low'] as const;
EOF
  git add -A; commit_at $((NOW - 2400)) "feat: US-003 - Add priority selector to task edit"
  cat > src/filter.ts <<'EOF'
export function filterByPriority<T extends { priority: string }>(tasks: T[], p: string) {
  return p === 'all' ? tasks : tasks.filter(t => t.priority === p);
}
EOF
  git add -A; commit_at $((NOW - 900)) "feat: US-004 - Filter tasks by priority"
fi

{
  echo "# Ralph Progress Log"
  echo "Started: $(human $((NOW - 5400)))"
  echo "---"
  echo
  echo "## Codebase Patterns"
  echo "- Use \`IF NOT EXISTS\` for migrations — the dev DB is not always rebuilt"
  echo "- Task cards live in src/taskCard.ts; keep the badge mapping there only"
  echo "---"
  echo
  echo "## [$(human $((NOW - 5000)))] - US-001"
  echo "- Added priority column to tasks table with a migration"
  echo "- Files changed: src/db.ts, migrations/003_priority.sql"
  echo "- **Learnings for future iterations:**"
  echo "  - Migrations run automatically on \`npm run dev\`; no manual step"
  echo "  - This codebase uses raw SQL strings, not an ORM — don't introduce one"
  echo "---"
  echo
  echo "## [$(human $((NOW - 4100)))] - US-002"
  echo "- Priority badge rendered on every task card"
  echo "- Files changed: src/taskCard.ts, src/styles.css"
  echo "- **Learnings for future iterations:**"
  echo "  - CSS uses plain kebab-case classes, no Tailwind"
  echo "  - Verified in browser: badge shows red/yellow/gray correctly"
  echo "---"
} > progress.txt

if [[ "$STATE" == "complete" ]]; then
{
  echo
  echo "## [$(human $((NOW - 2300)))] - US-003"
  echo "- Priority dropdown added to the task edit modal, saves on change"
  echo "- Files changed: src/prioritySelect.ts, src/taskEdit.tsx"
  echo "- **Learnings for future iterations:**"
  echo "  - The edit modal re-renders after save; no manual refresh needed"
  echo "---"
  echo
  echo "## [$(human $((NOW - 800)))] - US-004"
  echo "- Filter dropdown with URL-param persistence and an empty state"
  echo "- Files changed: src/filter.ts, src/taskList.tsx"
  echo "- **Learnings for future iterations:**"
  echo "  - URL params are parsed in one place (src/urlState.ts) — extend it, don't add a second parser"
  echo "---"
} >> progress.txt
elif [[ "$STATE" == "blocked" ]]; then
{
  echo
  echo "## [$(human $((NOW - 2900)))] - US-003"
  echo "- Attempted the priority dropdown in the edit modal; could not make it save"
  echo "- Files changed: src/taskEdit.tsx (uncommitted, reverted)"
  echo "- **Learnings for future iterations:**"
  echo "  - The modal's save handler is fire-and-forget; needs an explicit await"
  echo "- BLOCKER: edit modal state resets before the save promise resolves — needs a decision on"
  echo "  whether to await in the handler or move state up to the parent"
  echo "---"
  echo
  echo "## [$(human $((NOW - 2500)))] - US-003"
  echo "- Second attempt: same modal state reset problem, no commit made"
  echo "- **Learnings for future iterations:**"
  echo "  - Do not retry this story without changing the modal's state ownership"
  echo "- BLOCKED: story left at passes: false for the human to split or answer"
  echo "---"
} >> progress.txt
fi

# --- harness state ----------------------------------------------------------
printf '%s\n' "ralph/task-priority" > .ralph/last-branch
: > .ralph/iteration-3-prompt.md

# events carry both an ISO ts (human) and epoch seconds (machine)
ev() { # type iteration story status seconds_ago
  local e=$((NOW - $5))
  jq -cn --arg t "$(iso $e)" --argjson ep "$e" --arg type "$1" --argjson it "$2" \
         --arg s "$3" --arg st "$4" \
    '{ts:$t, epoch:$ep, type:$type, iteration:$it,
      story:(if $s=="-" then null else $s end),
      status:(if $st=="-" then null else $st end),
      max:10, driver:"in-session"}'
}

{
  ev preflight        0 -     -        5400
  ev iteration_start  1 US-001 -        5300
  ev iteration_end    1 US-001 done     4200
  ev iteration_start  2 US-002 -        4100
  ev iteration_end    2 US-002 done     1800
  case "$STATE" in
    complete)
      ev iteration_start 3 US-003 -      1700
      ev iteration_end   3 US-003 done    800
      ev iteration_start 4 US-004 -      700
      ev iteration_end   4 US-004 done    240
      ev complete        4 -      done    235 ;;
    blocked)
      ev iteration_start 3 US-003 -      1700
      ev iteration_end   3 US-003 blocked 900
      ev iteration_start 4 US-003 -      800
      ev iteration_end   4 US-003 blocked 300
      ev stopped         4 US-003 blocked 295 ;;
    *)
      ev iteration_start 3 US-003 -      120 ;;
  esac
} | jq -c . > .ralph/events.jsonl

# --- an archived previous run ------------------------------------------------
printf '%s\n' "ralph/user-auth" > archive/2026-10-08-old-feature/branch.txt
jq -n '{ project:"MyApp", branchName:"ralph/user-auth", description:"User Authentication - login and session basics",
  userStories:[
   {id:"US-001",title:"Add users table + migration",description:"",acceptanceCriteria:["Typecheck passes"],priority:1,passes:true,notes:""},
   {id:"US-002",title:"Session cookie on login",description:"",acceptanceCriteria:["Typecheck passes"],priority:2,passes:true,notes:""},
   {id:"US-003",title:"Logout endpoint",description:"",acceptanceCriteria:["Typecheck passes"],priority:3,passes:true,notes:""},
   {id:"US-004",title:"Rate limit login attempts",description:"",acceptanceCriteria:["Typecheck passes"],priority:4,passes:false,notes:"left out of scope"}]}' \
  > archive/2026-10-08-old-feature/prd.json
cat > archive/2026-10-08-old-feature/progress.txt <<'EOF'
# Ralph Progress Log
Started: Fri Oct 10 09:00:00 CST 2026
---

## [2026-10-08 09:20] - US-001
- users table + migration
---

## [2026-10-08 10:02] - US-002
- session cookie set on login
---

## [2026-10-08 10:40] - US-003
- logout endpoint clears the cookie
---
EOF

git add -A
GIT_AUTHOR_DATE="$(iso $((NOW - 60)))" GIT_COMMITTER_DATE="$(iso $((NOW - 60)))" \
  git commit -qm "chore: ralph artifacts"

# uncommitted work so the "dirty tree" signal has something to show
if [[ "$STATE" == "running" ]]; then
  cat > src/prioritySelect.wip.ts <<'EOF'
// in progress: priority dropdown wiring
export const DRAFT = true;
EOF
fi

echo "fixture ready: $ROOT (state=$STATE)"
