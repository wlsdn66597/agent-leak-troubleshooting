#!/usr/bin/env bash
# monitor.sh / diagnose_hang.sh 공통 함수 (source 전용)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT_DIR/agent.env" ] && source "$ROOT_DIR/agent.env"
PROC_NAME="${PROC_NAME:-agent-leak-app}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-${AGENT_HOME:-$HOME/agent-leak}/logs}"
RESULT_DIR="$ROOT_DIR/logs"
mkdir -p "$RESULT_DIR"

# 대상 PID. PyInstaller 바이너리는 부트로더(부모)+실제 작업(자식) 2개가 뜨므로 가장 최근(-n) 것을 쓴다.
find_pid() {
  pgrep -n -x "$PROC_NAME" 2>/dev/null || pgrep -n -f "$PROC_NAME" 2>/dev/null
}

# 대상 프로세스에 "실제로 적용된" 환경변수 값 (/proc/PID/environ)
proc_env() {  # $1=pid $2=변수명
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -n 1
}

# 앱 로그 디렉터리(AGENT_LOG_DIR)와 run_app.sh 콘솔 로그 중 가장 최근에 수정된 파일
latest_log() {  # $1=pid
  local dir f t max=0 newest=""
  dir=$(proc_env "$1" AGENT_LOG_DIR)
  dir="${dir:-${AGENT_LOG_DIR:-}}"
  local cands=("$RESULT_DIR"/console_*.log)
  [ -n "$dir" ] && cands+=("$dir"/*)
  for f in "${cands[@]}"; do
    [ -f "$f" ] || continue
    t=$(stat -c %Y "$f")
    [ "$t" -gt "$max" ] && { max=$t; newest=$f; }
  done
  echo "$newest"
}

# 마지막 로그 기록 이후 경과 시간(초). 로그 파일이 없으면 -1
log_idle() {  # $1=pid
  local f
  f=$(latest_log "$1")
  if [ -n "$f" ]; then echo $(( $(date +%s) - $(stat -c %Y "$f") )); else echo -1; fi
}
