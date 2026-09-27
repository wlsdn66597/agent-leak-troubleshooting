#!/usr/bin/env bash
# "살아있지만 멈춘" 상태(Hang / Deadlock) 진단
# 사용법: scripts/diagnose_hang.sh [관찰시간(초), 기본 10]
# 출력:   화면 + logs/diagnose_YYYYmmdd_HHMMSS.log
set -u
export LC_ALL=C
source "$(dirname "$0")/lib.sh"

WAIT="${1:-10}"
OUT="$RESULT_DIR/diagnose_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$OUT") 2>&1

section()   { printf '\n===== [%(%F %T)T] %s =====\n' -1 "$1"; }
cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }   # utime + stime (전체 스레드 합, 단위 tick)
threads()   { ps -L -o pid,lwp,stat,pcpu,rss,wchan:32,time,comm -p "$1"; }

section "1. 프로세스 생존 확인 (ps -ef)"
pid=$(find_pid)
if [ -z "$pid" ]; then
  echo "$PROC_NAME 프로세스가 없습니다 → Hang 이 아니라 종료(Crash)된 상태입니다. 실행 로그 마지막 부분을 확인하세요."
  exit 1
fi
ps -ef | grep -- "$PROC_NAME" | grep -v grep

section "2. T0 스냅샷 - 스레드별 상태 (ps -L)"
threads "$pid"
t0=$(cpu_ticks "$pid"); r0=$(ps -o rss= -p "$pid")
echo "cpu_ticks=$t0 rss=${r0// /}KB"
echo "... ${WAIT}초 동안 변화를 관찰합니다 ..."
sleep "$WAIT"
[ -d "/proc/$pid" ] || { echo "관찰 중 프로세스가 종료되었습니다 → Hang 아님"; exit 1; }

section "3. T1 스냅샷 - 스레드별 상태 (ps -L / top -H)"
threads "$pid"
top -H -b -n 1 -p "$pid" | sed -n '1,5p;7,$p'
t1=$(cpu_ticks "$pid"); r1=$(ps -o rss= -p "$pid")
echo "cpu_ticks=$t1 rss=${r1// /}KB"

log=$(latest_log "$pid")
section "4. 실행 로그 마지막 기록 (${log:-로그 파일 없음})"
if [ -n "$log" ]; then
  echo "파일 최종 수정: $(date -d @"$(stat -c %Y "$log")" '+%F %T')"
  tail -n 15 "$log"
  echo "--- 락/대기 관련 로그 (최근 20줄) ---"
  grep -nEi 'wait|block|acquir|lock|deadlock' "$log" | tail -n 20
fi

section "5. 판정"
idle=$(log_idle "$pid")
d_cpu=$(( t1 - t0 )); d_rss=$(( r1 - r0 ))
echo "PID:$pid  관찰 ${WAIT}s 동안 CPU tick 변화:$d_cpu  RSS 변화:${d_rss}KB  마지막 로그 이후:${idle}s"
if [ "$d_cpu" -eq 0 ] && [ "$idle" -ge "$WAIT" ]; then
  echo "VERDICT: HANG - PID 는 살아있으나 CPU 사용·로그 기록이 모두 정지 → 스레드가 락 대기(Sleep) 중인 Deadlock 의심"
  echo "         (위 ps -L 의 STAT=S, WCHAN=futex_* 는 스레드가 락(futex)을 기다리며 잠들어 있다는 뜻)"
elif [ "$idle" -ge "$WAIT" ]; then
  echo "VERDICT: BUSY-HANG - 로그는 멈췄지만 CPU 는 소비 중 → 무한 루프/라이브락 의심"
else
  echo "VERDICT: RUNNING - 로그가 계속 기록되고 있어 정상 진행 중"
fi
