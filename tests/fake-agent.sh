#!/usr/bin/env bash
# Fake iteration agent for testing the headless ralph.sh path.
# Mirrors what a real iteration does: implement -> commit -> flip passes:true ->
# append progress (the last two stay uncommitted, exactly like the real loop).
# Does nothing when the env says so, which is how the "blocked" path is tested.
set -euo pipefail
cd "$(pwd)"   # ralph.sh runs this inside the project dir

if [[ "${FAKE_AGENT_NOOP:-}" == "1" ]]; then
  echo "no-op iteration"
  sleep "${FAKE_AGENT_SLEEP:-0}"
  exit 0
fi

id="$(jq -r '[.userStories[]|select(.passes==false)]|sort_by(.priority)|.[0].id // empty' prd.json)"
[[ -n "$id" ]] || { echo "no story left"; exit 0; }

# pretend to work, so the dashboard can be observed mid-iteration
sleep "${FAKE_AGENT_SLEEP:-0}"

mkdir -p src
echo "implementation of $id" > "src/${id}.txt"
git add -A
git commit -qm "feat: $id - fake implementation"

jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true' prd.json > prd.json.tmp && mv prd.json.tmp prd.json
{
  echo "## [$(date +"%Y-%m-%d %H:%M")] - $id"
  echo "- fake iteration implemented $id"
  echo "- **Learnings for future iterations:**"
  echo "  - the fake agent always succeeds"
  echo "---"
} >> progress.txt

echo "RALPH_ITERATION: $id done"
