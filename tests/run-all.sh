#!/usr/bin/env bash
# Run every Ralph dashboard test suite and summarise.
#
# Usage: bash tests/run-all.sh
# Env:   RALPH_TEST_DIR   where fixtures/artifacts go (default: ${TMPDIR}/ralph-plugin-tests)
#        RALPH_TEST_PORT  first port for the UI suite (default 7911)
#
# Exit status: 0 all suites passed, 1 any failure, 2 only skipped.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RALPH_TEST_DIR="${RALPH_TEST_DIR:-${TMPDIR:-/tmp}/ralph-plugin-tests}"
export RALPH_TEST_PORT="${RALPH_TEST_PORT:-7911}"

mkdir -p "$RALPH_TEST_DIR"
echo "测试目录: $RALPH_TEST_DIR"
echo

declare -a NAMES STATUS
run_suite() { # $1 = label, rest = command
  local label="$1"; shift
  echo "================================================================"
  echo "  $label"
  echo "================================================================"
  if "$@"; then
    NAMES+=("$label"); STATUS+=("PASS")
  else
    local code=$?
    NAMES+=("$label")
    [[ $code -eq 2 ]] && STATUS+=("SKIP") || STATUS+=("FAIL")
  fi
  echo
}

run_suite "状态提取器（正常 + 降级输入）" bash "$TESTS_DIR/test-state.sh"
run_suite "无头循环集成（事件流 / --dashboard / 完成与卡住）" bash "$TESTS_DIR/test-headless.sh"
run_suite "看板 UI（四状态 / 实时刷新 / 快照 / 会话内片段）" python3 "$TESTS_DIR/test-ui.py"

echo "================================================================"
echo "  汇总"
echo "================================================================"
fails=0
for i in "${!NAMES[@]}"; do
  printf '%-10s %s\n' "${STATUS[$i]}" "${NAMES[$i]}"
  [[ "${STATUS[$i]}" == "FAIL" ]] && fails=$((fails + 1))
done
echo
if [[ $fails -gt 0 ]]; then
  echo "结果: FAIL（$fails 个套件失败）"
  exit 1
fi
if printf '%s\n' "${STATUS[@]}" | grep -q SKIP; then
  echo "结果: PASS（有套件被跳过）"
  exit 0
fi
echo "结果: PASS"
