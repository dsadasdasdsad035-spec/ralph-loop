#!/usr/bin/env bash
# Headless loop integration — drives the real scripts/ralph.sh with a fake agent.
#
# Proves the parts that only exist at runtime: stage events written around each
# iteration, the dashboard reporting a live loop (running/implement/current story),
# clean server shutdown with the loop, blocked-run detection, and completion.
#
# Usage: bash tests/test-headless.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FIX="${RALPH_TEST_DIR:-${TMPDIR:-/tmp}/ralph-plugin-tests}"
RALPH="$PLUGIN_ROOT/scripts/ralph.sh"
PORT="${RALPH_TEST_PORT:-7944}"

pass=0; fail=0
chk() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  (实际: $(printf '%s' "$2" | head -c 120) / 期望: $(printf '%s' "$3" | head -c 120))"; fail=$((fail+1)); fi; }
st() { bash "$PLUGIN_ROOT/scripts/ralph-state.sh" --dir "$1" --compact; }

make_proj() { # $1 = dir name
  rm -rf "$FIX/$1"; mkdir -p "$FIX/$1/src"
  (cd "$FIX/$1" && git init -q -b main && git config user.email d@e.com && git config user.name D \
    && echo x > src/app.txt && git add -A && git commit -qm "chore: init" \
    && git checkout -qb ralph/loop-test \
    && jq -n '{project:"LoopTest", branchName:"ralph/loop-test", description:"headless loop test",
               userStories:[range(1;4)|{id:("US-00"+(tostring)),title:("story "+(tostring)),
               description:"",acceptanceCriteria:["Typecheck passes"],priority:.,passes:false,notes:""}]}' > prd.json)
}

echo "===== 场景 1：进度推进的循环（2 轮 × 5 秒，看板开启）====="
make_proj proj-loop
cd "$FIX/proj-loop"
FAKE_AGENT_SLEEP=5 bash "$RALPH" --dir . --tool custom \
  --cmd "bash $TESTS_DIR/fake-agent.sh" --max-iterations 2 --dashboard --port "$PORT" > "$FIX/loop-run.log" 2>&1 &
LOOP_PID=$!
sleep 3
MID="$(curl -s "http://127.0.0.1:$PORT/api/state")"
chk "循环进行中：看板可访问" "$([[ -n "$MID" ]] && echo yes || echo no)" "yes"
chk "循环进行中：running" "$(echo "$MID" | jq -r '.loop.running')" "true"
chk "循环进行中：阶段=实现中" "$(echo "$MID" | jq -r '.loop.stage')" "implement"
chk "循环进行中：驱动=headless" "$(echo "$MID" | jq -r '.loop.driver')" "headless"
chk "循环进行中：当前故事" "$(echo "$MID" | jq -r '.loop.story')" "US-001"
chk "循环进行中：轮次" "$(echo "$MID" | jq -r '"\(.loop.iteration)/\(.loop.max_iterations)"')" "1/2"

wait $LOOP_PID; LOOP_EXIT=$?
sleep 0.6
chk "未跑完退出码 1" "$LOOP_EXIT" "1"
chk "看板 URL 已打印" "$(grep -c "Ralph 看板: http://127.0.0.1:$PORT/" "$FIX/loop-run.log")" "1"
chk "退出后无残留服务进程" "$(pgrep -f "serve.py --dir $FIX/proj-loop" | wc -l | tr -d ' ')" "0"
chk "退出后 pid 文件已清理" "$([[ -f "$FIX/proj-loop/.ralph/dashboard.pid" ]] && echo left || echo gone)" "gone"

EV="$FIX/proj-loop/.ralph/events.jsonl"
chk "事件：preflight 一条" "$(jq -r 'select(.type=="preflight")|.type' "$EV" | wc -l | tr -d ' ')" "1"
chk "事件：两轮 end 都是 done" "$(jq -r 'select(.type=="iteration_end")|"\(.iteration):\(.status)"' "$EV" | tr '\n' ' ')" "1:done 2:done "
chk "事件：stopped 不冒充完成" "$(jq -r 'select(.type=="stopped")|"\(.status)/\(.story)"' "$EV")" "none/US-003"

FINAL="$(st "$FIX/proj-loop")"
chk "结束后：阶段=idle（有记录的停止）" "$(echo "$FINAL" | jq -r '.loop.stage')" "idle"
chk "结束后：完成度 2/3" "$(echo "$FINAL" | jq -r '"\(.prd.counts.done)/\(.prd.counts.total)"')" "2/3"
chk "结束后：prd/progress 未提交（工作区脏）" "$(echo "$FINAL" | jq -r '.project.dirty')" "true"
chk "结束后：两轮的进度记录都在故事上" "$(echo "$FINAL" | jq -r '[.prd.stories[]|select((.progress|length)>0)]|length')" "2"

echo
echo "===== 场景 2：卡住的循环（no-op 代理 × 2 轮）====="
make_proj proj-stuck
cd "$FIX/proj-stuck"
FAKE_AGENT_NOOP=1 bash "$RALPH" --dir . --tool custom \
  --cmd "bash $TESTS_DIR/fake-agent.sh" --max-iterations 2 > "$FIX/loop-stuck.log" 2>&1
chk "卡住循环退出码 1" "$?" "1"
SEV="$FIX/proj-stuck/.ralph/events.jsonl"
chk "事件：两轮都是 blocked" "$(jq -r 'select(.type=="iteration_end")|.status' "$SEV" | tr '\n' ' ')" "blocked blocked "
chk "事件：stopped=blocked" "$(jq -r 'select(.type=="stopped")|.status' "$SEV")" "blocked"
chk "卡住后：页面阶段=已卡住" "$(st "$FIX/proj-stuck" | jq -r '.loop.stage')" "blocked"

echo
echo "===== 场景 3：全部完成即停 ====="
make_proj proj-done
cd "$FIX/proj-done"
bash "$RALPH" --dir . --tool custom --cmd "bash $TESTS_DIR/fake-agent.sh" --max-iterations 6 > "$FIX/loop-done.log" 2>&1
chk "跑完退出码 0" "$?" "0"
chk "事件：complete=done" "$(jq -r 'select(.type=="complete")|.status' "$FIX/proj-done/.ralph/events.jsonl")" "done"
DONE="$(st "$FIX/proj-done")"
chk "完成后：阶段=done" "$(echo "$DONE" | jq -r '.loop.stage')" "done"
chk "完成后：3/3" "$(echo "$DONE" | jq -r '"\(.prd.counts.done)/\(.prd.counts.total)"')" "3/3"
chk "完成后：三个故事都挂上提交" "$(echo "$DONE" | jq -r '[.prd.stories[]|select(.commit!=null)]|length')" "3"

echo
echo "断言: $pass 通过, $fail 失败"
[[ $fail -eq 0 ]] && echo "结果: PASS" || echo "结果: FAIL"
exit $(( fail > 0 ))
