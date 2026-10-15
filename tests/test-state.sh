#!/usr/bin/env bash
# ralph-state.sh — extractor regression.
#
# Covers the three healthy fixture states plus every degraded input the dashboard
# must survive: missing PRD, invalid PRD, not a git repo, empty repo (no commits),
# malformed events file, missing progress.txt. In all of them the extractor must
# still emit one valid JSON document and report what is missing instead of guessing.
#
# Usage: bash tests/test-state.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
STATE="$PLUGIN_ROOT/scripts/ralph-state.sh"
FIX="${RALPH_TEST_DIR:-${TMPDIR:-/tmp}/ralph-plugin-tests}"
D="$FIX/degraded"

pass=0; fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  (实际: $2 / 期望: $3)"; fail=$((fail+1)); fi; }
run() { bash "$STATE" --dir "$1" --compact 2>/dev/null; }

for s in running complete blocked multirun; do bash "$TESTS_DIR/make-fixture.sh" "$s" >/dev/null; done

echo "===== 正常状态 ====="
chk "running：阶段=实现中（节点 5）" "$(run "$FIX/proj-running" | jq -r '"\(.loop.stage)/\(.loop.stage_node)"')" "implement/5"
chk "running：来源=events（不是推断）" "$(run "$FIX/proj-running" | jq -r '.loop.source')" "events"
chk "running：正在处理 US-003" "$(run "$FIX/proj-running" | jq -r '.loop.story')" "US-003"
chk "running：脏工作区可见" "$(run "$FIX/proj-running" | jq -r '.project.dirty')" "true"
chk "running：已完成故事挂着提交与文件明细" "$(run "$FIX/proj-running" | jq -r '[.prd.stories[]|select(.commit!=null and (.commit.files|length)>0)]|length')" "2"
chk "running：归档运行可读" "$(run "$FIX/proj-running" | jq -r '.archive[0] | "\(.branch)/\(.done)/\(.total)"')" "ralph/user-auth/3/4"

chk "complete：阶段=全部完成（节点 11）" "$(run "$FIX/proj-complete" | jq -r '"\(.loop.stage)/\(.loop.stage_node)"')" "done/11"
chk "complete：4/4 且无待办" "$(run "$FIX/proj-complete" | jq -r '"\(.prd.counts.done)/\(.prd.counts.total)/\(.prd.counts.remaining)"')" "4/4/0"
chk "complete：迭代时间线 4 轮" "$(run "$FIX/proj-complete" | jq -r '.iterations|length')" "4"

chk "blocked：阶段=已卡住" "$(run "$FIX/proj-blocked" | jq -r '.loop.stage')" "blocked"
chk "blocked：两次尝试都在故事上" "$(run "$FIX/proj-blocked" | jq -r '.prd.stories[2].progress|length')" "2"

echo
echo "===== 多次运行（迭代号会重新从 1 开始）====="
# A real project runs the loop more than once. Iteration numbers are then NOT unique
# across the history, and a timeline keyed on the number alone silently overwrites
# the earlier run's iterations.
MR="$(run "$FIX/proj-multirun")"
chk "多次运行：迭代条目 = 事件里的 start 数（6 条，不是被覆盖后的 4）" \
  "$(printf '%s' "$MR" | jq -r '.iterations|length')" "6"
chk "多次运行：识别出 2 次运行" "$(printf '%s' "$MR" | jq -r '.loop.runs')" "2"
chk "多次运行：当前在第 2 次运行" "$(printf '%s' "$MR" | jq -r '.loop.run')" "2"
chk "多次运行：当前轮次按运行内计数（第 4 轮，不是历史最大 4）" \
  "$(printf '%s' "$MR" | jq -r '.loop.iteration')" "4"
chk "多次运行：max 取当前运行（100，不是首次运行的 10）" \
  "$(printf '%s' "$MR" | jq -r '.loop.max_iterations')" "100"
chk "多次运行：两次运行各有独立的第 1 轮" \
  "$(printf '%s' "$MR" | jq -r '[.iterations[]|select(.n==1)|.run]|sort|join(",")')" "1,2"
chk "多次运行：运行边界由迭代号回退识别（无 preflight 也能分）" \
  "$(printf '%s' "$MR" | jq -r '[.iterations[]|.run]|unique|length')" "2"
chk "多次运行：逐条时间正序（运行1 全部早于 运行2）" \
  "$(printf '%s' "$MR" | jq -r '([.iterations[]|select(.run==1)|.ended_epoch]|max) < ([.iterations[]|select(.run==2)|.started_epoch]|min)')" "true"
chk "多次运行：start/end 各自配对（每轮都有结束时间）" \
  "$(printf '%s' "$MR" | jq -r '[.iterations[]|select(.ended == null)]|length')" "1"

echo
echo "===== PRD 文档索引（tasks/）====="
DOCS_PROJ="$D/docsproj"
rm -rf "$DOCS_PROJ"; mkdir -p "$DOCS_PROJ/tasks"
cp "$FIX/proj-running/prd.json" "$DOCS_PROJ/prd.json"
cat > "$DOCS_PROJ/tasks/prd-task-priority.md" <<'MD'
# PRD: Task Priority System

### US-001: Add priority field to database

- [x] Add priority column
- [ ] Typecheck passes
MD
cat > "$DOCS_PROJ/tasks/prd-other.md" <<'MD'
# PRD: Unrelated Feature

### ZZ-009: Nothing shared

- [ ] Do the other thing
MD
printf '# Just notes\n\nNo stories.\n' > "$DOCS_PROJ/tasks/notes.md"
OUT="$(run "$DOCS_PROJ")"
chk "文档：列出 tasks/ 下的 md" "$(printf '%s' "$OUT" | jq -r '.docs.count')" "3"
chk "文档：识别出是当前 prd.json 来源的那篇" \
  "$(printf '%s' "$OUT" | jq -r '.docs.sources | length')" "1"
chk "文档：来源文档路径正确" \
  "$(printf '%s' "$OUT" | jq -r '.docs.sources[0].path')" "tasks/prd-task-priority.md"
chk "文档：标题命中数（用标题而非 id 判定来源）" \
  "$(printf '%s' "$OUT" | jq -r '.docs.sources[0].matched')" "1"
chk "文档：非来源的 PRD 不计入 sources" \
  "$(printf '%s' "$OUT" | jq -r '[.docs.sources[]|select(.file=="prd-other.md")]|length')" "0"
chk "文档：统计复选框进度" \
  "$(printf '%s' "$OUT" | jq -r '.docs.items[]|select(.file=="prd-task-priority.md")|"\(.checkboxes.checked)/\(.checkboxes.total)"')" "1/2"
chk "文档：非 PRD 文档被标出" \
  "$(printf '%s' "$OUT" | jq -r '.docs.items[]|select(.file=="notes.md")|.is_prd')" "false"
chk "文档：标题取自一级标题" \
  "$(printf '%s' "$OUT" | jq -r '.docs.items[]|select(.file=="notes.md")|.title')" "Just notes"
chk "文档：默认不内嵌正文（轮询负载保持轻量）" \
  "$(printf '%s' "$OUT" | jq -r '[.docs.items[]|select(has("content"))]|length')" "0"
OUT2="$(bash "$STATE" --dir "$DOCS_PROJ" --compact --docs-content 100000)"
chk "文档：--docs-content 时内嵌正文" \
  "$(printf '%s' "$OUT2" | jq -r '[.docs.items[]|select(has("content"))]|length')" "3"
chk "文档：内嵌正文内容正确" \
  "$(printf '%s' "$OUT2" | jq -r '.docs.items[]|select(.file=="notes.md")|.content|test("No stories")')" "true"
chk "文档：超过 --docs-content 上限的不内嵌" \
  "$(bash "$STATE" --dir "$DOCS_PROJ" --compact --docs-content 10 | jq -r '[.docs.items[]|select(has("content"))]|length')" "0"

echo
echo "===== 降级输入 ====="
rm -rf "$D"; mkdir -p "$D/noprj" "$D/badprd" "$D/plain" "$D/emptyrepo" "$D/badevents/.ralph" "$D/noprogress"
printf 'not json {{{ \n' > "$D/badprd/prd.json"
for d in plain emptyrepo badevents noprogress; do cp "$FIX/proj-running/prd.json" "$D/$d/prd.json"; done
printf 'garbage line\n' > "$D/badevents/.ralph/events.jsonl"
( cd "$D/emptyrepo" && git init -q -b main )
( cd "$D/noprogress" && git init -q -b main && git config user.email d@e.com && git config user.name D && git add -A && git commit -qm "chore: init" )

OUT="$(run "$D/noprj")"
chk "无 prd.json：仍是合法 JSON" "$(printf '%s' "$OUT" | jq -r 'type' 2>/dev/null)" "object"
chk "无 prd.json：阶段=no-prd（节点 1）" "$(printf '%s' "$OUT" | jq -r '"\(.loop.stage)/\(.loop.stage_node)"')" "no-prd/1"
chk "无 prd.json：prd 为 null" "$(printf '%s' "$OUT" | jq -r '.prd')" "null"
chk "无 prd.json：说明缺失原因" "$(printf '%s' "$OUT" | jq -r '[.errors[]|select(contains("prd.json not found"))]|length')" "1"
chk "无 prd.json：非 git 也如实说明" "$(printf '%s' "$OUT" | jq -r '[.errors[]|select(contains("not a git repository"))]|length')" "1"

OUT="$(run "$D/badprd")"
chk "PRD 损坏：报 JSON 非法" "$(printf '%s' "$OUT" | jq -r '[.errors[]|select(contains("not valid JSON"))]|length')" "1"
chk "PRD 损坏：不猜测故事" "$(printf '%s' "$OUT" | jq -r '.prd')" "null"

OUT="$(run "$D/plain")"
chk "非 git：is_git_repo=false" "$(printf '%s' "$OUT" | jq -r '.project.is_git_repo')" "false"
chk "非 git：仍读到 4 个故事" "$(printf '%s' "$OUT" | jq -r '.prd.counts.total')" "4"
chk "非 git：没有提交可挂" "$(printf '%s' "$OUT" | jq -r '[.prd.stories[]|select(.commit!=null)]|length')" "0"

OUT="$(run "$D/emptyrepo")"
chk "空仓库：head 为 null 而非空串" "$(printf '%s' "$OUT" | jq -r '.project.head')" "null"
chk "空仓库：分支名仍可读" "$(printf '%s' "$OUT" | jq -r '.project.branch')" "main"
chk "空仓库：无错误" "$(printf '%s' "$OUT" | jq -r '.errors|length')" "0"

OUT="$(run "$D/badevents")"
chk "事件损坏：回退为推断" "$(printf '%s' "$OUT" | jq -r '.loop.source')" "inferred"
chk "事件损坏：说明文件有问题" "$(printf '%s' "$OUT" | jq -r '[.errors[]|select(contains("malformed"))]|length')" "1"

OUT="$(run "$D/noprogress")"
chk "缺 progress.txt：不报错、无进度记录" "$(printf '%s' "$OUT" | jq -r '"\(.progress_entries|length)/\(.errors|length)"')" "0/0"

echo
echo "断言: $pass 通过, $fail 失败"
[[ $fail -eq 0 ]] && echo "结果: PASS" || echo "结果: FAIL"
exit $(( fail > 0 ))
