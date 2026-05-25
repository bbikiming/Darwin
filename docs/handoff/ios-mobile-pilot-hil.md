# iOS Mobile Pilot — HIL (Hardware-in-the-Loop) 핸드오프

작성일: 2026-05-25 (truth-gap fix 반영, build 5)
상태: Pre-HIL — 자동 테스트 통과 (iOS 31 / Mac MobileRelay 42), 실 robot 검증은 아래 절차 대기
관련 문서:
- [docs/prd/ios-robot-control-mvp.md §12.10](../prd/ios-robot-control-mvp.md)
- [docs/handoff/ios-mobile-pilot-first-build.md](ios-mobile-pilot-first-build.md)
- [docs/release/ios-mobile-pilot-testflight.md](../release/ios-mobile-pilot-testflight.md)

## 1. 사전 조건

- Mac DarwinForge 가 OP1/OP2 와 USB serial 또는 SSH 로 정상 연결되는 상태.
- TestFlight 에 build 5 (또는 그 이후) 가 업로드되어 iPhone 에 설치돼 있음.
- 로봇은 cradle 또는 tether 상태.
- 하드웨어 E-stop 토글이 손 닿는 곳.
- 관찰자 1명 권장.
- ARM 3-toggle 모두 사용자가 직접 ON 가능한 상황 (cradle / 물리 E-stop 확인 / 시야 확보).
- Mac DarwinForge → Mobile Pilot Relay 패널 ON, 6자리 pairing code 화면에 표시.

### 1.1 자동 검증 통과 가정 (build 5)

| 항목 | 결과 |
|---|---|
| iOS unit tests | 31 / 31 |
| Mac MobileRelay tests | 42 / 42 (walk integration 5개 포함) |
| iOS Simulator build | success |
| Mac DarwinForgeUI build | success |

위가 보장되지 않은 build 는 HIL 진입 금지.

## 2. HIL Gate 매트릭스

| Gate | 시나리오 | 통과 기준 | 결과 (date / tester) |
|---|---|---|---|
| HIL-0 | robot 미연결 (Mac relay 만 ON) | iPhone status rail `Mac ✓ / Robot 미연결 / 잠김`, action 버튼은 sim/disabled | — |
| HIL-1 | robot 연결 (Mac USB direct 또는 SSH) | `Robot ✓` 5초 이내 표시, telemetry 1Hz 갱신 | — |
| HIL-2 | ARM checklist + slider | `ARM` 상태, walkReady 완료, dxlPower ON, latency < 100ms | — |
| HIL-3 | Safe action 1개 (보행 자세 / 인사 / 앉기) | progress + ACK, 로봇이 실제 자세 도달, 실패 사유 없음 | — |
| HIL-4 | Walk deadman (slowForward 2초 → release) | press 중 robot 보행, release 후 < 300ms 안에 stop | — |
| HIL-5 | active walk 중 E-stop | < 300ms 안에 robot 정지, EStop banner 표시, 하드웨어 E-stop 동시 검증 | — |
| HIL-6 | active walk 중 iPhone 앱 강제 종료 | < 500ms 안에 Mac watchdog 가 stop 발동, robot 잔존 운동 없음 | — |
| HIL-7 | 10분 반복 조작 (slowForward / turn / safe action) | stale command 0건, ACK miss 5% 이하, 그동안 E-stop/하드웨어 토글 정상 | — |

## 3. 실행 순서 (권장)

1. **사전 점검**
   - Mac DarwinForge 실행 → Mobile Pilot Relay 토글 ON
   - QR/pairing code 화면 표시 확인
   - iPhone 과 Mac 동일 Wi-Fi
   - 하드웨어 E-stop 토글 확인 (ON → OFF → ON)
2. **Pairing (HIL-0)**
   - iPhone Connect 화면에서 자동 발견 또는 manual host 입력
   - pairing code 입력 → `session.welcome` 확인
3. **Robot 연결 (HIL-1)**
   - Mac 쪽 ConnectionStore 가 robot 와 연결
   - iPhone status rail `Robot ✓` 표시 확인
4. **ARM (HIL-2)**
   - cradle checkbox 확인
   - ARM slider drag+hold
   - Mac UI 의 `TeleopChannel.armed=true` 와 동기 확인
5. **Safe action (HIL-3)**
   - 보행 자세 → ACK 확인
   - 인사 또는 앉기 1회 더
6. **Walk deadman (HIL-4)**
   - 보행 segment 진입
   - slowForward 영역 2초 press → release
   - turnLeft / turnRight 각 1초 press → release
   - 매번 release 직후 robot stop 확인
7. **Safety (HIL-5, 6)**
   - active walk 중 E-stop 발동
   - ARM 다시 → active walk 중 앱 강제 종료
   - 매 케이스 robot 잔존 운동 0
8. **반복 (HIL-7)**
   - 10분 동안 walking + safe action 교대 조작
   - command id 와 ACK latency 가 Logs 에 누락 없이 표시되는지 확인

## 4. 실패 시 기록 양식

```text
HIL Gate:
Date / tester:
iPhone build (CFBundleVersion):
Mac relay version:
Robot endpoint:
시나리오:
기대:
실제:
command id:
ACK latency:
Mac Harness log link:
iPhone Logs screenshot:
하드웨어 E-stop 사용 여부:
결정 (Pass / Conditional / Fail):
```

## 5. 차단 조건 (No-Go)

다음 중 하나라도 발생하면 그 build 는 TestFlight 후보 자격 박탈 → `docs/release/ios-mobile-pilot-testflight.md` §11 절차로 회수.

- HIL-5 또는 HIL-6 에서 robot 가 release/disconnect 이후에도 움직임
- ARM 없이 motion/walk 가 robot 에 전달
- ARM 체크리스트 3개 중 하나라도 체크 안 됐는데 ARM 통과 (real relay 모드)
- 두 번째 iPhone 이 동시에 명령 가능 (single authority 위반)
- E-stop tap 후 300ms 이내 stop 미발동
- ACK 없이 iPhone UI 가 성공 표시 (E-stop 의 optimistic UI 제외)
- 보행 중 latency > 150ms 가 5초 이상 유지되는데 walk command 계속 전달
- `freeform` preset 이 real relay 에서 reject 되지 않음 (truth-gap P0-2 회귀)
- `bow` 또는 slot 41 이 motion 으로 활성됨 (truth-gap P0-4 회귀)
- Pairing tap 시 `000000` 자동 코드로 연결되는 경로 발견 (truth-gap P1-1 회귀)

## 6. Mock vs HIL 차이 정리

| 영역 | Mock (Review) | HIL (real robot) |
|---|---|---|
| transport | MockRelayClient (in-process) | WebSocket over LAN |
| robot ACK | 즉시 fake ack | WalkLab onboard brokering 의 cmd_id 기반 ack |
| 안전 gate | port 의 in-memory armed flag | `TeleopChannel.allowMotion` + dxlPower 게이트 |
| E-stop | armed=false, robot=estopped 표시만 | `ConnectionStore.emergencyStop()` → torque OFF + bus stop |
| watchdog | scripted client 가 모의 | 실 NWConnection close + 500ms 타이머 |
| sim 라벨 | "Mock Relay (Review)" | 표시되지 않음 |

## 7. 결과 누적

각 HIL 사이클 종료 후 다음을 기록한다.

- 통과 Gate
- 실패 Gate (재시도 결정 포함)
- 발견된 issue (P0~P3)
- 다음 build 의 build number
- Mac relay 호환 버전

이 markdown 파일을 in-place 로 업데이트한다 (git history 가 audit trail).
