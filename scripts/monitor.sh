#!/usr/bin/env bash
# agent-leak-app 관제 스크립트 (CPU / 메모리 / 스레드 / 로그 정체 추적)
# 사용법: scripts/monitor.sh [수집주기(초), 기본 5]
# 출력:   화면 + logs/monitor_YYYYmmdd_HHMMSS.log
set -u
export LC_ALL=C
source "$(dirname "$0")/lib.sh"

INTERVAL="${1:-5}"
HANG_SEC=$(( INTERVAL * 6 ))   # 로그가 이 시간 이상 멈춰 있고 CPU≈0 이면 HANG 의심
OUT="$RESULT_DIR/monitor_$(date +%Y%m%d_%H%M%S).log"
echo "[monitor] target=$PROC_NAME interval=${INTERVAL}s out=$OUT"

prev_pid=""
while true; do
  pid=$(find_pid)
  if [ -z "$pid" ]; then
    if [ -n "$prev_pid" ]; then
      echo "[$(date '+%F %T')] PROCESS:$PROC_NAME EXITED (PID:$prev_pid)" | tee -a "$OUT"
    else
      echo "[$(date '+%F %T')] PROCESS:$PROC_NAME NOT_RUNNING" | tee -a "$OUT"
    fi
    prev_pid=""
    sleep "$INTERVAL"
    continue
  fi
  prev_pid=$pid

  # top 을 2회 샘플링: 1회차는 누적값이라 버리고, 2회차(INTERVAL 동안의 실제 사용률)를 사용.
  # 헤더의 %Cpu(s) idle 값으로 시스템 전체 CPU 도 함께 기록해 "특정 프로세스" 문제인지 구분한다.
  read -r cpu sys_cpu < <(top -b -n 2 -d "$INTERVAL" -p "$pid" | awk -v p="$pid" '
      /^%Cpu/ && match($0, /[0-9.]+ *id/) { idle = substr($0, RSTART, RLENGTH) + 0 }
      $1 == p { cpu = $9 }
      END { printf "%s %.1f\n", (cpu == "" ? "0.0" : cpu), 100 - idle }')

  # RSS = 실제 물리 메모리 점유량(KB)
  read -r rss_kb mem thr stat < <(ps -o rss=,%mem=,nlwp=,stat= -p "$pid") || continue
  rss_mb=$(( rss_kb / 1024 ))
  limit=$(proc_env "$pid" MEMORY_LIMIT)
  cpu_max=$(proc_env "$pid" CPU_MAX_OCCUPY)
  idle=$(log_idle "$pid")
  [ -d "/proc/$pid" ] || continue   # 샘플링 도중 종료된 경우 불완전한 줄은 버린다 (다음 루프에서 EXITED 기록)
  disk=$(df -h / | awk 'NR == 2 { print $4 }')

  status=OK
  if [ -n "$limit" ] && [ "$rss_mb" -ge $(( limit * 8 / 10 )) ]; then status=MEM_WARN; fi
  if [ -n "$cpu_max" ] && awk -v c="$cpu" -v m="$cpu_max" 'BEGIN { exit !(c >= m * 0.8) }'; then status=CPU_WARN; fi
  if [ "$idle" -ge "$HANG_SEC" ] && awk -v c="$cpu" 'BEGIN { exit !(c < 1) }'; then status=HANG_SUSPECT; fi

  echo "[$(date '+%F %T')] PID:$pid PROCESS:$PROC_NAME CPU:${cpu}% SYS_CPU:${sys_cpu}%" \
       "MEM:${mem}% RSS:${rss_mb}MB/LIMIT:${limit:-?}MB THREADS:$thr STAT:$stat" \
       "LOG_IDLE:${idle}s DISK:$disk STATUS:$status" | tee -a "$OUT"
done
