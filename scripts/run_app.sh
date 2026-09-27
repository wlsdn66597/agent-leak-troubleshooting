#!/usr/bin/env bash
# agent-leak-app 1회 실행 + 콘솔 로그 저장 + 생존 시간/종료 사유를 logs/runs.csv 에 기록
# 사용법: [MEMORY_LIMIT=..] [CPU_MAX_OCCUPY=..] [MULTI_THREAD_ENABLE=..] [RUN_TIMEOUT=초] scripts/run_app.sh <tag>
#   RUN_TIMEOUT: 지정 시간까지 살아있으면 SIGTERM 으로 끝내고 SURVIVED 로 기록 (0 = 무제한)
#   Ctrl+C: 앱에 SIGTERM 을 보내고 STOPPED_BY_USER 로 기록 (Deadlock 관찰 후 종료할 때 사용)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-run}"
source "$ROOT/scripts/setup_env.sh" || exit 1

APP_BIN="${APP_BIN:-$AGENT_HOME/agent-leak-app}"
RUN_TIMEOUT="${RUN_TIMEOUT:-0}"
RESULT_DIR="$ROOT/logs"
mkdir -p "$RESULT_DIR"
[ -f "$APP_BIN" ] || { echo "[run] 실행 파일을 찾을 수 없습니다: $APP_BIN (APP_BIN 으로 지정 가능)" >&2; exit 1; }
case "$APP_BIN" in
  *.py) APP_CMD=(python3 "$APP_BIN") ;;   # 스크립트 형태로 제공된 경우
  *)    APP_CMD=("$APP_BIN") ;;
esac

CONSOLE="$RESULT_DIR/console_${TAG}_$(date +%Y%m%d_%H%M%S).log"
CSV="$RESULT_DIR/runs.csv"
[ -f "$CSV" ] || echo "tag,start,end,survival_sec,exit_code,result,last_keyword,MEMORY_LIMIT,CPU_MAX_OCCUPY,MULTI_THREAD_ENABLE,pid,console_log" > "$CSV"

# 모든 출력 줄에 수신 시각을 붙인다 (앱 로그에 타임스탬프가 없는 줄도 증거로 쓰기 위함). pty 가 붙이는 CR 은 제거
stamp() { while IFS= read -r line; do printf '[%(%F %T)T] %s\n' -1 "${line%$'\r'}"; done; }

# 앱 트리: script → PyInstaller 부트로더 → 실제 작업 프로세스 (포트가 고정이라 동시에 1개만 실행된다)
stop_app() { pkill -TERM -x "${PROC_NAME:-agent-leak-app}" 2>/dev/null; }
RC_FILE=$(mktemp)

STOP_REASON=""
trap 'STOP_REASON=SURVIVED;        stop_app' USR1
trap 'STOP_REASON=STOPPED_BY_USER; stop_app' INT TERM

START=$(date +%s)
cd "$AGENT_HOME"
# 앱의 print() 출력은 파이프로 받으면 블록 버퍼에 갇혀, 강제 종료 직전의 배너
# (">>> [SYSTEM] SELF-TERMINATED ..." / ">>> [SYSTEM] WATCHDOG ... (SIGTERM)")가 유실된다.
# script 로 가상 터미널(pty)을 붙여 줄 단위로 출력되게 한다. (-e: 앱의 종료 코드를 그대로 반환)
# Ctrl+C 는 이 스크립트의 trap(stop_app → SIGTERM)만 처리하도록, 출력 파이프라인은 SIGINT 를 무시하고
# 앱은 setsid 로 별도 세션에서 실행한다. (그러지 않으면 SIGINT 에 파이프라인이 먼저 끊겨 종료 코드가 유실된다)
printf -v CMD '%q ' "${APP_CMD[@]}"
( trap '' INT
  { setsid -w script -qfec "$CMD" /dev/null < /dev/null; echo $? > "$RC_FILE"; } 2>&1 | stamp | tee -a "$CONSOLE"
) &
RUNNER=$!
sleep 1
APP_PID=$(pgrep -n -x "${PROC_NAME:-agent-leak-app}")   # 실제 작업 프로세스 PID (monitor.sh 와 동일)
echo "[run] tag=$TAG PID=${APP_PID:-?} MEMORY_LIMIT=$MEMORY_LIMIT CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY" \
     "MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE RUN_TIMEOUT=$RUN_TIMEOUT log=$CONSOLE" | stamp | tee -a "$CONSOLE"

WATCHER=""
if [ "$RUN_TIMEOUT" -gt 0 ]; then
  ( sleep "$RUN_TIMEOUT"; kill -USR1 $$ 2>/dev/null ) &
  WATCHER=$!
fi

# trap 으로 wait 가 중간에 깨어나도 앱이 실제로 끝날 때까지 기다려 진짜 종료 코드를 얻는다
while :; do
  wait "$RUNNER"
  kill -0 "$RUNNER" 2>/dev/null || break
done
END=$(date +%s)
[ -n "$WATCHER" ] && kill "$WATCHER" 2>/dev/null
CODE=$(cat "$RC_FILE" 2>/dev/null); CODE=${CODE:-?}
rm -f "$RC_FILE"

# 시작 배너의 "POTENTIAL DEADLOCK" 경고는 종료 사유가 아니므로 DEADLOCK 단어는 제외한다
KEYWORD=$(grep -oE 'SELF-TERMINATED|Memory limit exceeded|WATCHDOG|Threshold Violated|BLOCKED' "$CONSOLE" | tail -n 1)
RESULT="${STOP_REASON:-EXITED}"
case "$CODE" in
  137) SIG="(SIGKILL)" ;;
  143) SIG="(SIGTERM)" ;;
  *)   SIG="" ;;
esac

echo "$TAG,$(date -d @"$START" '+%F %T'),$(date -d @"$END" '+%F %T'),$((END - START)),$CODE$SIG,$RESULT,$KEYWORD,$MEMORY_LIMIT,$CPU_MAX_OCCUPY,$MULTI_THREAD_ENABLE,${APP_PID:-?},$CONSOLE" >> "$CSV"
echo "[run] 종료: tag=$TAG PID=${APP_PID:-?} 생존 $((END - START))s exit=$CODE$SIG result=$RESULT keyword=${KEYWORD:-없음} → $CSV"
