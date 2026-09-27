# [Bug] CPU Spike - CPU 부하가 50%를 넘자 Watchdog 보호 조치(SIGTERM)로 30초 만에 프로세스 종료

**Labels**: `bug` `performance` · **Environment**: WSL2 Ubuntu 22.04 (x86_64, 8 vCPU), `agent-leak-app` x86 · **Date**: 2026-09-27

## 1. Description (현상 설명)
- **현상**: `agent-leak-app` 실행 후 CPU 부하가 계속 오르다가, 약 30초 뒤 `>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<`를 출력하며 종료된다.
- **발생 조건**: `CPU_MAX_OCCUPY=100`, `MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false`
  - 메모리·스레드는 안정값으로 고정했다.
  - 앱도 시작할 때 `[ CPU ] Limit: 100% [ WARNING: Recommend Under 50% ]`로 경고한다.
- **발생 시각**: 2026-09-27 13:17:22 시작 → 13:17:52 종료 (PID 12401)
- **재현 경로**:
  ```bash
  bash scripts/monitor.sh 2                                                                          # 터미널 1
  CPU_MAX_OCCUPY=100 MEMORY_LIMIT=512 MULTI_THREAD_ENABLE=false bash scripts/run_app.sh cpu-before     # 터미널 2
  top -b -n 1 -p "$(pgrep -n -x agent-leak-app)" | head -n 8                                         # 터미널 3 (실행 중)
  ```
  재현율 100%다. 사전 테스트를 포함한 반복 실행에서 매번 24~30초에 같은 방식으로 종료됐다.

## 2. Evidence & Logs (증거 자료)
**① 프로그램 실행 로그**: 부하 상승과 Watchdog 종료 (`logs/console_cpu-before_20260927_131722.log`)
```text
 [ CPU    ] Limit: 100%  		[ WARNING: Recommend Under 50% ]
2026-09-27 13:17:24,593 [INFO] [CpuWorker] Started. Maximum CPU Limit: 100%
2026-09-27 13:17:24,594 [INFO] [CpuWorker] Current Load: 5.00%
2026-09-27 13:17:30,827 [INFO] [CpuWorker] Current Load: 13.61%
2026-09-27 13:17:37,060 [INFO] [CpuWorker] Current Load: 23.29%
2026-09-27 13:17:43,294 [INFO] [CpuWorker] Current Load: 31.40%
2026-09-27 13:17:49,528 [INFO] [CpuWorker] Current Load: 40.68%
2026-09-27 13:17:52,645 [INFO] [CpuWorker] Current Load: 50.44%
2026-09-27 13:17:52,746 [CRITICAL] [CpuWorker] CPU Threshold Violated! (50.44%).
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
```

| 시각 | 13:17:24 | :30 | :37 | :43 | :49 | :52 | :52.746 |
|---|---|---|---|---|---|---|---|
| 앱 보고 Load (%) | 5.00 | 13.61 | 23.29 | 31.40 | 40.68 | **50.44** | Violated → SIGTERM |

**② top 스냅샷** (13:17:38, 실행 중): 대상 PID와 시스템 전체
```text
top - 13:17:38 up 1:38,  1 user,  load average: 0.01, 0.03, 0.00
Tasks:   1 total,   0 running,   1 sleeping,   0 stopped,   0 zombie
%Cpu(s):  0.8 us,  4.1 sy,  0.0 ni, 95.1 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
  12401 jinu      30  10   24184  17792   9600 S   0.0   0.5   0:00.13 agent-leak-app
```

**③ monitor.sh 관제 로그**: 같은 구간
```text
[2026-09-27 13:17:25] PID:12401 PROCESS:agent-leak-app CPU:0.0% SYS_CPU:0.2% RSS:17MB/LIMIT:512MB STAT:SN+ STATUS:OK
[2026-09-27 13:17:40] PID:12401 PROCESS:agent-leak-app CPU:2.0% SYS_CPU:0.3% RSS:17MB/LIMIT:512MB STAT:SN+ STATUS:OK
[2026-09-27 13:17:49] PID:12401 PROCESS:agent-leak-app CPU:2.0% SYS_CPU:0.4% RSS:17MB/LIMIT:512MB STAT:SN+ STATUS:OK
[2026-09-27 13:17:54] PROCESS:agent-leak-app EXITED (PID:12401)
```

**④ 종료 코드** (`logs/runs.csv`)
```text
tag         survival_sec  exit_code     result  last_keyword  CPU_MAX_OCCUPY  pid
cpu-before  30            143(SIGTERM)  EXITED  WATCHDOG      100             12401
```
- 전체 캡처: [CPU 종료 패턴 캡처](../docs/evidence/03-cpu-watchdog.png)

## 3. Root Cause Analysis (원인 분석)
- **특정 프로세스의 부하 상승**
  - `CpuWorker`가 약 3초마다 부하를 올려, 28초 만에 5% → 50.44%에 도달했다.
  - 같은 시간 시스템 전체는 `95.1 id`(유휴 95%), `SYS_CPU` 1% 미만으로 한가했다.
  - 따라서 **시스템 전체 부하가 아니라 `agent-leak-app`(PID 12401) 한 프로세스의 문제**다.
  - 메모리는 17MB로 고정되어 메모리 요인도 배제된다.
- **종료는 오류가 아니라 Watchdog의 보호 조치**
  - 부하가 50%를 넘은 13:17:52,746에 `CPU Threshold Violated!`가 기록됐다.
  - 같은 초에 Watchdog가 긴급 중단을 선언했다.
  - 종료 코드 **143 = 128 + 15(SIGTERM)** 이다.
  - Traceback·Exception이 전혀 없어, 예외로 인한 크래시가 아니라 **과점유 방지 정책의 의도된 종료**다.
  - 임계치는 `CPU_MAX_OCCUPY` 값이 아니라 앱 내부 한계(50%)다. 그래서 `CPU_MAX_OCCUPY`를 50보다 크게 주면 부하가 그 한계를 넘도록 허용되어 종료된다.
- **OS 동작 원리: 단일 프로세스를 끊는 이유**
  - CPU는 스케줄러(CFS)가 실행 가능한 프로세스들에게 시간을 나눠 주는 공유 자원이다.
  - 한 프로세스가 계속 실행 상태로 코어를 점유하면 run queue가 길어진다. 그러면 다른 서비스, 헬스체크, SSH의 응답 지연으로 번진다.
  - 원인이 특정된 프로세스만 SIGTERM으로 정리하는 편이 전체 재부팅보다 훨씬 작은 비용으로 나머지를 지킨다.
  - 참고로 앱은 시작할 때 `SafetyGuard`로 스스로 우선순위를 낮춘다(`NI 10`, `STAT SN+`의 N). 이것도 다른 프로세스에 CPU를 양보하려는 보호 장치다.
- **관측 한계 (명시)**
  - 앱이 보고한 `Current Load`(23~50%)와 OS 실측(top %CPU 0.0, monitor 0~2%)이 일치하지 않는다.
  - `Current Load`는 앱이 과점유 상황을 모사해 **내부적으로 계산한 값**으로 판단된다.
  - 따라서 종료 판정의 근거는 앱 로그의 Load와 Watchdog 로그이고, top·monitor는 "해당 PID 대 시스템 전체" 범위를 좁히는 보조 증거로 사용했다.

## 4. Workaround & Verification (조치 및 검증)
**조치**: 환경변수 `CPU_MAX_OCCUPY`를 100에서 50으로 낮춘다(앱 권장값 `Recommend Under 50%`).
```bash
CPU_MAX_OCCUPY=50 MEMORY_LIMIT=512 MULTI_THREAD_ENABLE=false RUN_TIMEOUT=300 bash scripts/run_app.sh cpu-after
```

**검증 (Before & After)**

| 구분 | CPU_MAX_OCCUPY | 생존 시간 | 종료 코드 | 결과 |
|---|---|---|---|---|
| Before | 100% | **30초** | 143 (SIGTERM, Watchdog) | `EXITED` / `WATCHDOG` |
| After | 50% | **301초 이상** | 143 (SIGTERM, 5분 관찰 종료) | `SURVIVED` |

```text
 [ CPU    ] Limit: 50%  		[ OK ]
2026-09-27 13:18:47,519 [INFO] [CpuWorker] Peak reached (50.00%). Starting cooldown...
2026-09-27 13:19:24,919 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-09-27 13:20:05,473 [INFO] [CpuWorker] Peak reached (50.00%). Starting cooldown...
2026-09-27 13:20:36,639 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-09-27 13:21:20,302 [INFO] [CpuWorker] Peak reached (50.00%). Starting cooldown...
```
- **결과**: 5분 동안 `Peak reached → Cooldown`을 **4회** 반복했다. `Threshold Violated`는 0회로, 종료 없이 생존했다.
- **종료 코드 해석**: 두 실행 모두 종료 코드는 143이지만 의미가 다르다.
  - Before: Watchdog에 의한 종료(`last_keyword=WATCHDOG`)
  - After: 관찰 종료(`SURVIVED`)
  - `result`와 `last_keyword`로 구분한다.
- 캡처: [Before/After 캡처](../docs/evidence/04-cpu-before-after.webp)

**근본 해결 제안**
- 상한을 낮추는 것은 **임시 조치**다.
- 코드에서는 busy-wait 루프를 `Event.wait()`나 `sleep` + 지수 백오프로 바꾸고, 무거운 연산은 작업 단위로 쪼개 중간에 양보하게 한다.
- 인프라에서는 cgroup CPU quota(`CPUQuota=`)로 프로세스별 상한을 OS 수준에서 강제한다.
