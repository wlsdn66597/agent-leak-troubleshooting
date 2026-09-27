# [Bug] Deadlock - 멀티스레드 락 순환 대기로 프로세스 무응답 (PID 유지, 로그 정지)

**Labels**: `bug` `concurrency` · **Environment**: WSL2 Ubuntu 22.04 (x86_64), `agent-leak-app` x86 · **Date**: 2026-09-27

## 1. Description (현상 설명)
- **현상**: `agent-leak-app` 실행 약 9초 뒤부터 로그 출력이 완전히 멈춘다.
  - 프로세스는 종료되지 않고 PID가 그대로 유지되며, CPU·메모리 사용량도 변하지 않는 **무응답 상태**가 계속된다.
  - 스스로 복구되지 않아 약 3분 뒤 수동으로 종료했다.
- **발생 조건**: `MULTI_THREAD_ENABLE=true`, `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=50`
  - 메모리·CPU는 안정값으로 고정했다.
  - 앱도 시작할 때 `[ THREAD ] Concurrency: True [ WARNING ]`, `>>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.`로 경고한다.
- **발생 시각**: 2026-09-27 13:24:01 시작 → 13:24:10,365 마지막 로그 → 13:27:06 수동 종료 (작업 프로세스 PID 17956)
- **재현 경로**:
  ```bash
  bash scripts/monitor.sh 2                                                                          # 터미널 1
  MULTI_THREAD_ENABLE=true MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 bash scripts/run_app.sh deadlock-before  # 터미널 2
  ps -ef | grep [a]gent-leak-app && bash scripts/diagnose_hang.sh 10                                 # 터미널 3 (정지 후)
  ```
  재현율 100%다. 사전 테스트를 포함한 반복 실행에서 매번 같은 지점(`WAITING ... BLOCKED`)에서 멈췄다.

## 2. Evidence & Logs (증거 자료)
**① PID 존재**: 프로세스가 살아 있다 (`ps -ef`, 13:26:05)
```text
jinu  17953  17950  0 13:24 pts/1  00:00:00 script -qfec /home/jinu/agent-leak/agent-leak-app  /dev/null
jinu  17955  17953  0 13:24 pts/4  00:00:00 /home/jinu/agent-leak/agent-leak-app      ← PyInstaller 부트로더
jinu  17956  17955  0 13:24 pts/4  00:00:00 /home/jinu/agent-leak/agent-leak-app      ← 실제 작업 프로세스
```

**② 스레드별 CPU/MEM 정체** (`ps -L` T0 13:26:05 → T1 13:26:15, `top -H`)
```text
    PID     LWP STAT %CPU   RSS WCHAN                    TIME COMMAND
  17956   17956 SNl+  0.0 17792 futex_wait_queue     00:00:00 agent-leak-app
  17956   18082 SNl+  0.0 17792 futex_wait_queue     00:00:00 agent-leak-app
  17956   18083 SNl+  0.0 17792 futex_wait_queue     00:00:00 agent-leak-app
cpu_ticks=6 rss=17792KB   (T0)  →  cpu_ticks=6 rss=17792KB   (T1, 10초 후)

Threads:   3 total,   0 running,   3 sleeping,   0 stopped,   0 zombie
%Cpu(s):  0.0 us,  0.0 sy,  0.0 ni,100.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st

PID:17956  관찰 10s 동안 CPU tick 변화:0  RSS 변화:0KB  마지막 로그 이후:126s
VERDICT: HANG - PID 는 살아있으나 CPU 사용·로그 기록이 모두 정지 → 스레드가 락 대기(Sleep) 중인 Deadlock 의심
```

**③ monitor.sh 관제 로그**: 정지 이후 약 3분 동안 변화 없음
```text
[2026-09-27 13:24:10] PID:17956 PROCESS:agent-leak-app CPU:0.0% RSS:17MB/LIMIT:512MB THREADS:3 STAT:SNl+ LOG_IDLE:0s   STATUS:OK
[2026-09-27 13:24:23] PID:17956 PROCESS:agent-leak-app CPU:0.0% RSS:17MB/LIMIT:512MB THREADS:3 STAT:SNl+ LOG_IDLE:13s  STATUS:HANG_SUSPECT
[2026-09-27 13:26:50] PID:17956 PROCESS:agent-leak-app CPU:0.0% RSS:17MB/LIMIT:512MB THREADS:3 STAT:SNl+ LOG_IDLE:160s STATUS:HANG_SUSPECT
[2026-09-27 13:27:05] PID:17956 PROCESS:agent-leak-app CPU:0.0% RSS:17MB/LIMIT:512MB THREADS:3 STAT:SNl+ LOG_IDLE:175s STATUS:HANG_SUSPECT
```
- 13:24:23부터 13:27:05까지 `HANG_SUSPECT`가 **74회 연속** 기록됐다(CPU 0.0%, RSS 17MB 고정, `LOG_IDLE` 13 → 175초).

**④ 마지막 로그 기록**: `logs/console_deadlock-before_20260927_132401.log` (파일 최종 수정 13:24:10)
```text
2026-09-27 13:24:08,351 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-09-27 13:24:08,351 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
2026-09-27 13:24:08,351 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
2026-09-27 13:24:08,352 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-09-27 13:24:08,352 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-09-27 13:24:10,364 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-09-27 13:24:10,364 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-09-27 13:24:10,365 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
2026-09-27 13:24:10,365 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
                                                  (이후 수동 종료 시까지 176초간 추가 기록 없음)
```
- 캡처: [PID·스레드 정체 캡처](../docs/evidence/05a-deadlock-diagnose.webp), [마지막 로그·판정·관제 캡처](../docs/evidence/05b-deadlock-last-log.webp)

## 3. Root Cause Analysis (원인 분석)
**증거가 좁혀 가는 범위**

| 관측 | 배제되는 가설 |
|---|---|
| PID 3개 생존 (①) | 크래시·강제 종료 |
| CPU tick 변화 0, 모든 스레드 %CPU 0.0 (②③) | 무한 루프·라이브락 (그랬다면 CPU가 소비됨) |
| STAT `S`(interruptible sleep), `D` 아님 (②) | 디스크·I/O 대기 |
| RSS 17,792KB 고정 (②③) | 메모리 누수·할당 진행 |
| WCHAN `futex_wait_queue` (②) | → **락(futex)을 얻기 위해 잠들어 기다리는 중** |

**로그로 재구성한 스레드와 락의 관계** (④)

| 스레드 | 보유 중인 락 (13:24:08,352) | 기다리는 락 (13:24:10,365) |
|---|---|---|
| Worker-Thread-1 | `Shared_Memory_A` | `Socket_Pool_B` |
| Worker-Thread-2 | `Socket_Pool_B` | `Shared_Memory_A` |

```text
Worker-Thread-1 ──(보유)──▶ Shared_Memory_A ◀──(대기)── Worker-Thread-2
       │                                                    │
     (대기)                                               (보유)
       ▼                                                    ▼
  Socket_Pool_B ◀───────────────────────────────────────────┘
```
- 각 스레드가 기다리는 락을 **상대방이 쥐고 있고**, 대기 관계가 1 → 2 → 1로 원을 이룬다.
- 두 `WAITING ... BLOCKED`가 같은 밀리초(13:24:10,365)에 기록된 뒤, 어느 스레드에서도 `released`나 다음 단계 로그가 나오지 않았다. 따라서 둘 다 영원히 대기 중이다.
- 메인(`AgentWorker`)은 `Waiting for worker threads to complete transactions...` 이후 두 워커의 종료를 기다리며 함께 멈췄다. 그래서 프로세스 전체가 무응답이 됐다.

**교착상태 4대 조건의 성립**
1. **상호 배제 (Mutual Exclusion)**: `Shared_Memory_A`와 `Socket_Pool_B`는 한 번에 한 스레드만 보유한다. 앱도 `CAUTION: Strict resource locking is enabled.`로 이를 밝힌다.
2. **점유 대기 (Hold and Wait)**: 각 스레드가 첫 락을 쥔 채(`Holding...`) 두 번째 락을 요청한다.
3. **비선점 (No Preemption)**: 상대가 쥔 락을 빼앗을 수 없고, 해제될 때까지 기다리기만 한다.
4. **순환 대기 (Circular Wait)**: Thread-1 → Socket_Pool_B(Thread-2 보유) → Shared_Memory_A(Thread-1 보유)

네 조건이 동시에 성립하므로 외부 개입 없이는 절대 풀리지 않는다. 스레드들은 커널 futex에서 잠든 상태라 CPU를 쓰지 않고, 그래서 CPU·메모리·로그가 모두 멈춘 **"조용한 장애"**로 관측된다.

## 4. Workaround & Verification (조치 및 검증)
**조치**: 환경변수 `MULTI_THREAD_ENABLE`을 true에서 false로 바꿔, 두 워커가 동시에 락을 경쟁하는 경로 자체를 끈다.
```bash
MULTI_THREAD_ENABLE=false MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 RUN_TIMEOUT=300 bash scripts/run_app.sh deadlock-after
```

**검증 (Before & After)**

| 구분 | MULTI_THREAD_ENABLE | 경과 | 결과 | 마지막 상태 |
|---|---|---|---|---|
| Before | true | 9초 만에 정지, 185초 뒤 수동 종료 | `STOPPED_BY_USER` | `BLOCKED` (Deadlock 재현) |
| After | false | **301초 이상** 정상 동작 | `SURVIVED` | 로그 계속 기록 (Deadlock 회피) |

```text
 [ THREAD ] Concurrency: False 		[ OK ]
>>> [SYSTEM] ALL CONFIGURATIONS OPTIMAL. RUNNING STABILITY TEST... <<<
2026-09-27 13:27:19,783 [INFO] [Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
2026-09-27 13:27:20,856 [INFO] [Scheduler] All tasks completed.
...
2026-09-27 13:32:17,808 [INFO] [MemoryWorker] Current Heap: 300MB      ← 5분 뒤에도 로그 기록 중
```
- **After**: 작업이 모두 완료됐다(`All tasks completed`). 이후 5분 동안 로그가 끊기지 않고 282줄 기록됐다. `HANG_SUSPECT`는 0회였다.
- **Before의 `exit_code`가 `?`인 이유**: 이 실행 당시 `run_app.sh`에는 Ctrl+C로 중단하면 종료 코드를 기록하기 전에 출력 파이프라인이 끊기는 버그가 있었다. 이후 수정해 현재는 `143(SIGTERM)`이 기록된다. 판정 근거는 `STOPPED_BY_USER`(스스로 끝나지 못함)와 `last_keyword=BLOCKED`다.
- 캡처: [Before/After 캡처](../docs/evidence/06-deadlock-before-after.webp)

**근본 해결 제안**
- `MULTI_THREAD_ENABLE=false`는 동시성을 포기하는 **임시 조치**다. 코드에서는 순환 대기 조건을 깨야 한다.
  - **락 획득 순서 고정**: 모든 스레드가 `Shared_Memory_A → Socket_Pool_B` 같은 전역 순서로만 획득하게 하면, 순환 대기가 원천적으로 불가능하다.
  - **타임아웃**: `lock.acquire(timeout=5)`로 무한 대기를 없앤다. 실패하면 보유한 락을 해제하고 백오프 후 재시도한다. 점유 대기 조건을 깨는 방법이다.
  - **구조 개선**: 두 자원이 모두 필요한 구간은 락 하나로 합치거나, `queue.Queue` 기반 생산자-소비자 구조로 바꿔 공유 락 자체를 줄인다.
- 운영 측면에서는 PID 존재가 아니라 **마지막 처리 시각(heartbeat)**을 보는 liveness probe를 둔다. 이번처럼 "살아 있지만 멈춘" 프로세스를 자동으로 감지하고 재시작하기 위해서다.
