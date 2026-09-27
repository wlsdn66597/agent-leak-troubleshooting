#!/usr/bin/env bash
# agent-leak-app 실행 환경 준비 + 부트 조건 사전 검증
# 사용법: source scripts/setup_env.sh
#   - 이미 export 된 값은 유지하므로 `MEMORY_LIMIT=512 source scripts/setup_env.sh` 처럼 덮어쓸 수 있다.
#   - run_app.sh 가 내부에서 자동으로 source 한다.

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$_root/agent.env" ] && source "$_root/agent.env"
unset _root

export AGENT_HOME="${AGENT_HOME:-$HOME/agent-leak}"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="${AGENT_LOG_DIR:-$AGENT_HOME/logs}"
export MEMORY_LIMIT="${MEMORY_LIMIT:-256}"          # MB, 50~512
export CPU_MAX_OCCUPY="${CPU_MAX_OCCUPY:-50}"       # %, 10~100
export MULTI_THREAD_ENABLE="${MULTI_THREAD_ENABLE:-true}"
export PYTHONUNBUFFERED=1                            # 파이프로 받을 때 로그가 버퍼에 갇히지 않도록

mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
[ -f "$AGENT_KEY_PATH/secret.key" ] || printf 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"

_errs=0
_err() { echo "[setup][ERROR] $*" >&2; _errs=$((_errs + 1)); }

[ "$(id -u)" -ne 0 ] || _err "root 계정으로는 실행할 수 없습니다. 일반 사용자로 실행하세요."
{ [[ $MEMORY_LIMIT =~ ^[0-9]+$ ]] && (( MEMORY_LIMIT >= 50 && MEMORY_LIMIT <= 512 )); } \
  || _err "MEMORY_LIMIT 은 50~512 정수여야 합니다 (현재: $MEMORY_LIMIT)"
{ [[ $CPU_MAX_OCCUPY =~ ^[0-9]+$ ]] && (( CPU_MAX_OCCUPY >= 10 && CPU_MAX_OCCUPY <= 100 )); } \
  || _err "CPU_MAX_OCCUPY 는 10~100 정수여야 합니다 (현재: $CPU_MAX_OCCUPY)"
[[ ${MULTI_THREAD_ENABLE,,} =~ ^(true|false|1|0|yes|no)$ ]] \
  || _err "MULTI_THREAD_ENABLE 은 true/false/1/0/yes/no 중 하나여야 합니다 (현재: $MULTI_THREAD_ENABLE)"
[ "$(cat "$AGENT_KEY_PATH/secret.key")" = "agent_api_key_test" ] || _err "secret.key 내용이 agent_api_key_test 가 아닙니다"
[ -w "$AGENT_LOG_DIR" ] || _err "AGENT_LOG_DIR 에 쓰기 권한이 없습니다: $AGENT_LOG_DIR"
if ss -ltn 2>/dev/null | grep -q ":$AGENT_PORT "; then
  _err "포트 $AGENT_PORT 가 이미 사용 중입니다 (이전 프로세스 잔존 여부: ss -ltnp | grep $AGENT_PORT," \
       "이전 과제 서비스라면: sudo systemctl disable --now agent-app.service)"
fi

if [ "$_errs" -gt 0 ]; then
  unset _errs; unset -f _err
  return 1 2>/dev/null || exit 1
fi
unset _errs; unset -f _err

echo "[setup] OK AGENT_HOME=$AGENT_HOME PORT=$AGENT_PORT MEMORY_LIMIT=${MEMORY_LIMIT}MB" \
     "CPU_MAX_OCCUPY=${CPU_MAX_OCCUPY}% MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE"
