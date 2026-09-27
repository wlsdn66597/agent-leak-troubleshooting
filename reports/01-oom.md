# [Bug] OOM - 메모리 누수로 MEMORY_LIMIT 도달 시 MemoryGuard 에 의해 33초 만에 강제 종료

**Labels**: `bug` `memory-leak` · **Environment**: WSL2 Ubuntu 22.04 (x86_64, RAM 3.7GiB), `agent-leak-app` x86 · **Date**: 2026-09-27

## 1. Description (현상 설명)
- **현상**: `agent-leak-app`을 실행하면 약 33초 뒤 아무 오류 응답 없이 프로세스가 사라지고, 터미널에 `>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<`가 출력된다.
- **발생 조건**: `MEMORY_LIMIT=256`, `CPU_MAX_OCCUPY=50`, `MULTI_THREAD_ENABLE=false`
  - 다른 장애 요인을 배제하려고 CPU·스레드는 안정값으로 고정했다.
  - 앱도 시작할 때 `[ MEMORY ] Limit: 256MB [ WARNING: Recommend Over 256MB ]`로 경고한다.
- **발생 시각**: 2026-09-27 13:09:14 시작 → 13:09:47 종료 (PID 6768)
- **재현 경로**:
  ```bash
  bash scripts/monitor.sh 2                                                                       # 터미널 1
  MEMORY_LIMIT=256 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false bash scripts/run_app.sh oom-before   # 터미널 2
  ```
  재현율 100%다. 사전 테스트를 포함한 반복 실행에서 매번 32~52초 사이에 같은 방식으로 종료됐다.

## 2. Evidence & Logs (증거 자료)
**① monitor.sh 관제 로그**: RSS가 선형 증가하고, CPU는 안정적이다.
```text
[2026-09-27 13:09:18] PID:6768 PROCESS:agent-leak-app CPU:2.0% SYS_CPU:0.2% MEM:1.1% RSS:42MB/LIMIT:256MB  THREADS:1 STAT:SN+ STATUS:OK
[2026-09-27 13:09:23] PID:6768 PROCESS:agent-leak-app CPU:1.5% SYS_CPU:0.2% MEM:2.4% RSS:92MB/LIMIT:256MB  THREADS:1 STAT:SN+ STATUS:OK
[2026-09-27 13:09:29] PID:6768 PROCESS:agent-leak-app CPU:1.5% SYS_CPU:0.2% MEM:3.7% RSS:142MB/LIMIT:256MB THREADS:1 STAT:SN+ STATUS:OK
[2026-09-27 13:09:36] PID:6768 PROCESS:agent-leak-app CPU:1.5% SYS_CPU:0.1% MEM:5.0% RSS:192MB/LIMIT:256MB THREADS:1 STAT:SN+ STATUS:OK
[2026-09-27 13:09:38] PID:6768 PROCESS:agent-leak-app CPU:1.5% SYS_CPU:0.4% MEM:5.7% RSS:217MB/LIMIT:256MB THREADS:1 STAT:SN+ STATUS:MEM_WARN
[2026-09-27 13:09:45] PID:6768 PROCESS:agent-leak-app CPU:1.5% SYS_CPU:0.4% MEM:7.0% RSS:267MB/LIMIT:256MB THREADS:1 STAT:SN+ STATUS:MEM_WARN
[2026-09-27 13:09:47] PROCESS:agent-leak-app EXITED (PID:6768)
```

| 시각 | 13:09:18 | 13:09:23 | 13:09:29 | 13:09:36 | 13:09:38 | 13:09:45 | 13:09:47 |
|---|---|---|---|---|---|---|---|
| RSS (MB) | 42 | 92 | 142 | 192 | 217 | 267 | 종료 |
| CPU (%) | 2.0 | 1.5 | 1.5 | 1.5 | 1.5 | 1.5 | — |

- 약 27초 동안 RSS가 42 → 267MB로 증가했다(**약 8.3MB/초, 일정한 기울기**). 반면 CPU는 0~2%로 변화가 없다.
- 전체 캡처: [관제 로그 캡처](../docs/evidence/01a-oom-monitor.webp)

**② 프로그램 실행 로그**: 종료 직전과 직후 구간 (`logs/console_oom-before_20260927_130914.log`)
```text
2026-09-27 13:09:16,864 [INFO] [MemoryWorker] Current Heap: 25MB
2026-09-27 13:09:19,902 [INFO] [MemoryWorker] Current Heap: 50MB
...  (약 3.04초마다 +25MB)
2026-09-27 13:09:44,239 [INFO] [MemoryWorker] Current Heap: 250MB
2026-09-27 13:09:47,281 [INFO] [MemoryWorker] Current Heap: 275MB
2026-09-27 13:09:47,281 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-09-27 13:09:47,281 [CRITICAL] [MemoryGuard] Self-terminating process 6768 to prevent system instability.
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
```
- 전체 캡처: [실행 로그 캡처](../docs/evidence/01b-oom-app-log.webp)

**③ 종료 코드** (`logs/runs.csv`)
```text
tag         survival_sec  exit_code     result  last_keyword     MEMORY_LIMIT  pid
oom-before  33            137(SIGKILL)  EXITED  SELF-TERMINATED  256           6768
```

## 3. Root Cause Analysis (원인 분석)
- **메모리 누수**
  - `MemoryWorker`가 약 3초마다 25MB를 할당하고, Heap이 줄어드는 구간이 한 번도 없다(25 → 275MB 단조 증가).
  - OS 관측값(RSS)도 같은 기울기로 증가한다.
  - 즉 할당한 객체를 계속 참조한 채 쌓아 두어, GC가 회수할 수 없는 **힙 메모리 누수**다.
  - CPU는 0~2%로 일정해서 연산 폭주가 아닌 **메모리 단독 문제**임을 확인했다.
- **종료 주체는 앱 내부 MemoryGuard**
  - Heap이 한도(275MB ≥ 256MB)를 넘은 13:09:47,281에 `MemoryGuard`가 초과를 감지했다.
  - 같은 밀리초에 자기 PID(6768)를 지목해 종료를 선언했다.
  - 종료 코드 **137 = 128 + 9(SIGKILL)** 로, 스스로 SIGKILL을 보내 즉시 종료했다.
  - 커널 OOM Killer가 아니라 **애플리케이션 보호 정책**에 의한 종료다. 시스템 메모리(3.7GiB) 중 사용량은 7%에 불과했다.
- **OS 동작 원리: 이 정책이 필요한 이유**
  - 누수를 방치하면 물리 메모리 고갈 → 스왑 thrashing으로 호스트 전체가 느려진다.
  - 결국 커널 OOM Killer가 `oom_score` 기준으로 희생자를 골라, 무관한 프로세스까지 죽일 수 있다.
  - MemoryGuard는 그 전에 정한 한도에서 누수 당사자만 끊어 피해 범위를 한 프로세스로 제한한다(fail-fast).
- **관측 참고**: `monitor.sh`의 첫 샘플(`PID:6760 RSS:2MB`)은 PyInstaller 부트로더(부모)이고, 실제 누수는 자식 프로세스 6768에서 발생했다.

## 4. Workaround & Verification (조치 및 검증)
**조치**: 환경변수 `MEMORY_LIMIT`을 256에서 512로 상향한다(최대 허용값).
```bash
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false RUN_TIMEOUT=300 bash scripts/run_app.sh oom-after
```

**검증 (Before & After)**

| 구분 | MEMORY_LIMIT | 생존 시간 | 종료 코드 | 결과 |
|---|---|---|---|---|
| Before | 256MB | **33초** | 137 (SIGKILL, MemoryGuard) | `EXITED` / `SELF-TERMINATED` |
| After | 512MB | **301초 이상** | 143 (SIGTERM, 5분 관찰 종료) | `SURVIVED` |

```text
 [ MEMORY ] Limit: 512MB 		[ OK ]
2026-09-27 13:12:17,680 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-09-27 13:12:17,702 [INFO] [System] Memory Cache Flushed. Process Stabilized.
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
2026-09-27 13:13:23,575 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
```
- **결과**: 생존 시간이 33초에서 5분 이상으로 **9배 이상** 늘었다.
- **After 동작**: 한도에 도달해도 종료 대신 캐시를 비우고 회복했다. 5분 동안 약 66초 주기로 **4회** 회복했다.
- **After의 143**: 앱이 죽은 것이 아니라 `RUN_TIMEOUT=300`에서 관찰을 끝낸 것이다.
- 캡처: [Before/After 캡처](../docs/evidence/02-oom-before-after.webp)

**한계와 근본 해결 제안**
- 이번 조치는 **임시 조치**다. After에서도 Heap이 25MB씩 계속 늘다가 한도에서 캐시를 비울 뿐, 누수 자체는 남아 있다.
- 근본적으로는 누적 자료구조에 상한을 둬야 한다(`collections.deque(maxlen=N)`, LRU 캐시).
- 처리가 끝난 데이터의 참조를 제거하고, `tracemalloc` 스냅샷 비교로 누적 지점을 찾아 수정한다.
- 운영 관점에서는 RSS **증가 기울기** 기반 경보를 두어 한도 도달 전에 탐지한다.
