#!/usr/bin/env bash
# Ralph dashboard — entry point.
#
#   ralph-dashboard.sh [--dir DIR] [--port 7878] [--open]
#       Start the local, read-only viewer (127.0.0.1) and print its URL.
#
#   ralph-dashboard.sh --snapshot FILE [--dir DIR]
#       Write a self-contained HTML snapshot (state embedded) — no server, no
#       Python. Open the file directly; it does not auto-update.
#
#   ralph-dashboard.sh --inline-fragment FILE [--dir DIR]
#       Write a Gen UI fragment (for rendering the board inside a ZCode session).
#
#   ralph-dashboard.sh --once [--dir DIR]
#       Print the state JSON the page renders, then exit. Handy for scripting.
#
#   ralph-dashboard.sh --stop
#       Stop a viewer started earlier from this project (kills the recorded PID).
#
# Read-only: nothing here writes inside the project except .ralph/dashboard.pid
# (harness state, self-ignored) when a server is started.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_DIR="$PWD"
PORT=7878
OPEN=false
MODE="serve"
OUT_FILE=""
MOD=""

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --dir=*) PROJECT_DIR="${1#*=}"; shift ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --open) OPEN=true; shift ;;
    --snapshot) MODE="snapshot"; OUT_FILE="${2:-}"; shift 2 ;;
    --snapshot=*) MODE="snapshot"; OUT_FILE="${1#*=}"; shift ;;
    --inline-fragment) MODE="fragment"; OUT_FILE="${2:-}"; shift 2 ;;
    --inline-fragment=*) MODE="fragment"; OUT_FILE="${1#*=}"; shift ;;
    --once) MODE="once"; shift ;;
    --stop) MODE="stop"; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$PROJECT_DIR" = /* ]] || PROJECT_DIR="$PWD/$PROJECT_DIR"
[[ -d "$PROJECT_DIR" ]] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

STATE_SCRIPT="$PLUGIN_ROOT/scripts/ralph-state.sh"
[[ -f "$STATE_SCRIPT" ]] || die "state extractor missing: $STATE_SCRIPT"

# --- stop --------------------------------------------------------------------

if [[ "$MODE" == "stop" ]]; then
  PID_FILE="$PROJECT_DIR/.ralph/dashboard.pid"
  [[ -f "$PID_FILE" ]] || die "no dashboard PID recorded at $PID_FILE"
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" && echo "已停止看板服务 (pid $PID)"
  else
    echo "记录里的进程已不在运行 (pid ${PID:-?})"
  fi
  rm -f "$PID_FILE"
  exit 0
fi

state_json() { bash "$STATE_SCRIPT" --dir "$PROJECT_DIR" --compact; }

# A standalone snapshot has no server to fetch documents from later, so the PRD texts
# are embedded (capped) while the live service keeps them out of the polled payload.
DOCS_EMBED_MAX=200000
state_json_with_docs() {
  bash "$STATE_SCRIPT" --dir "$PROJECT_DIR" --compact --docs-content "$DOCS_EMBED_MAX"
}

# --- once --------------------------------------------------------------------

if [[ "$MODE" == "once" ]]; then
  bash "$STATE_SCRIPT" --dir "$PROJECT_DIR"
  exit 0
fi

# --- snapshot / fragment -----------------------------------------------------
# The template has the state placeholder alone on its own line, so splicing by line
# number is exact: no regex escaping of JSON can go wrong, and the tags around the
# placeholder survive.

render_template() { # $1 = template file, $2 = destination
  local template="$1" dest="$2" state line_no dir_part base_part tmp
  [[ -f "$template" ]] || die "template missing: $template"
  state="$(state_json_with_docs)" || die "could not read project state"
  # `<` can only appear inside JSON strings, so escaping it globally is safe and
  # guarantees the payload cannot close the embedding <script> tag.
  state="$(printf '%s' "$state" | sed 's/</\\u003c/g')"
  line_no="$(grep -n -m1 '__RALPH_STATE__' "$template" | cut -d: -f1)"
  [[ -n "$line_no" ]] || die "template has no state placeholder: $template"
  # Guard the whole design: the placeholder must sit alone on its line, otherwise
  # replacing that line would delete surrounding markup.
  [[ "$(sed -n "${line_no}p" "$template" | tr -d '[:space:]')" == "__RALPH_STATE__" ]] \
    || die "placeholder in $template must be alone on its own line (line $line_no has other content)"
  dir_part="$(cd "$(dirname "$dest")" && pwd)"
  base_part="$(basename "$dest")"
  dest="$dir_part/$base_part"
  tmp="$(mktemp "$dir_part/.ralph-dashboard.XXXXXX")"
  {
    head -n "$((line_no - 1))" "$template"
    printf '%s\n' "$state"
    tail -n "+$((line_no + 1))" "$template"
  } > "$tmp"
  mv "$tmp" "$dest"
  echo "$dest"
}

if [[ "$MODE" == "snapshot" ]]; then
  [[ -n "$OUT_FILE" ]] || die "--snapshot needs a destination file (e.g. --snapshot ralph-dashboard.html)"
  OUT="$(render_template "$PLUGIN_ROOT/dashboard/index.html" "$OUT_FILE")"
  echo "快照已写入: $OUT"
  echo "用浏览器直接打开即可（静态快照，不会自动更新；要看实时进度请不加 --snapshot 起服务）"
  exit 0
fi

if [[ "$MODE" == "fragment" ]]; then
  [[ -n "$OUT_FILE" ]] || die "--inline-fragment needs a destination file"
  OUT="$(render_template "$PLUGIN_ROOT/dashboard/inline.html" "$OUT_FILE")"
  echo "$OUT"
  exit 0
fi

# --- serve -------------------------------------------------------------------

PYTHON="$(command -v python3 || command -v python || true)"
if [[ -z "$PYTHON" ]]; then
  FALLBACK="$PROJECT_DIR/ralph-dashboard.html"
  echo "没有找到 python3 —— 无法启动本地服务，改为生成静态快照。" >&2
  OUT="$(render_template "$PLUGIN_ROOT/dashboard/index.html" "$FALLBACK")"
  echo "快照已写入: $OUT（打开即可；需要实时刷新请安装 Python 3 后重跑）"
  exit 0
fi

mkdir -p "$PROJECT_DIR/.ralph"
[[ -f "$PROJECT_DIR/.ralph/.gitignore" ]] || printf '*\n' > "$PROJECT_DIR/.ralph/.gitignore"

# Record the PID so `--stop` (and the user) can find the server later.
"$PYTHON" "$PLUGIN_ROOT/dashboard/serve.py" --dir "$PROJECT_DIR" --port "$PORT" $( $OPEN && echo --open ) &
SERVER_PID=$!
echo "$SERVER_PID" > "$PROJECT_DIR/.ralph/dashboard.pid"
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -f "$PROJECT_DIR/.ralph/dashboard.pid"' EXIT INT TERM
wait "$SERVER_PID"
