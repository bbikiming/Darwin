# 보행 품질 업그레이드 — ROBOTIS Onboard 검증 런북 (Approach 1)

> 2026-05-31. 목표: 조종 시 보행을 **공식 볼-트래킹 데모 수준**(뒤뚱거림 없이 지면과
> 평행 유지)으로 끌어올린다. 근본 원인과 방법론은 멀티-에이전트 분석으로 확정됨.

## 0. 한 줄 결론 (왜 이 방법인가)

뒤뚱거림은 **튜닝·기구학 문제가 아니라 제어 아키텍처(전송 지연) 문제**다. Mac이 희소
키프레임을 지연 있는 TCP 버스(RTT 16~100ms)로 보내며 루프 밖에서 균형을 보정 →
보행 주파수(1.67Hz)에서 위상지연 90~250° → 비례 피드백이 에너지를 **주입**해 ~1.0Hz,
23° p2p roll 리미트 사이클. 데모는 **로봇 안에서 공식 `Walking.cpp`를 8ms(125Hz)
하드 실시간 + 루프 내 자이로 댐퍼 + 1틱 1 SyncWrite**로 돌려 매끄럽다.

→ **해법: 로봇이 공식 Walking 엔진을 직접 돌리게 하고, Mac은 X/Y/A만 보내는 얇은
원격이 된다 (`.robotisOnboard`).** 이러면 위상지연·희소샘플·관절 시차가 구조적으로 소멸.

## 1. 준비 상태 (이 런북 작성 시점에 코드로 완료된 것)

- ✅ 로봇측 브로커리지 `firmware-patches/walklab-brokerage/WalkLabBrokerage.{cpp,h}` 존재 —
  `/tmp/df-walklab-cmd` 5Hz 폴링 → `Walking::GetInstance()->X/Y/A_MOVE_AMPLITUDE` 적용 + Start/Stop.
- ✅ **빌드 자동화 통합 완료** (`RobotSetupCommand.swift`):
  - `demoInjectBlock`에 **walklab 분기 추가** — SOCCER와 동일 준비(모션 enable / walk-ready
    page 9 / 자이로 캘리브레이션) 후 `WalkLabBrokerage().Run()`으로 공식 gait 인계.
  - `demoBuildPatched`가 브로커리지 소스 배치 + `#include` 주입 + Makefile `OBJECTS` 등록
    (GNU Make 암묵 규칙이 컴파일). **하나의 `demo-pilot` 바이너리가 soccer + walklab 모두 지원.**
- ✅ v1 데몬으로도 공식 `BALANCE_ENABLE=true` 기본값이 살아 **자이로 밸런스 ON** (데모 품질 핵심).
- ⏳ 기본 엔진은 아직 `.macSparseKeyframe` 유지 (검증 전 조종 불능 방지). 검증 후 전환.

## 2. 전제 조건 (검증 시작 전)

- [ ] 로봇 전원 정상 (배터리 11V+, 보드 부팅 완료) — 직전 브라운아웃 이슈 해결 확인
- [ ] 로봇 네트워크 연결 + **SSH 접속 가능** (`ssh darwin@<robot-ip>`)
- [ ] 로봇이 **바닥에 서 있는 상태**(스탠드 아님) — 실제 보행 검증이므로
- [ ] 안전 공간 확보 + 비상정지 즉시 가능

## 3. 배포 (Mac → 로봇)

```bash
# 3-1. 브로커리지 소스를 로봇으로 복사 (빌드 자동화가 여기서 가져감)
scp -r firmware-patches/walklab-brokerage/ darwin@<robot-ip>:~/walklab-brokerage/
```

그다음 **Mac DarwinForge 앱에서**: WalkLab → 보행 엔진 picker → **ROBOTIS onboard** 선택 →
**ROBOTIS 측 빌드/시작** 트리거. 내부적으로 `demoBuildPatched`가 실행되어:
1. demo 소스 위치 탐색 (`~/Framework/Linux/project/demo` 등)
2. 브로커리지 `.cpp/.h` 배치 + `main.cpp`에 walklab 분기 주입 + `#include` + `OBJECTS` 등록
3. `make` → `demo-pilot` 생성 (원본 `main.cpp`/`Makefile` 복구)

> 수동 빌드가 필요하면 `firmware-patches/walklab-brokerage/INTEGRATION.md` 참조.
> (단, 자동화 경로가 정식. 수동 `patch -pN`은 경로 깊이 때문에 헷갈리니 자동화 우선.)

## 4. 검증 체크리스트 (순서대로, 각 단계 통과 전 다음 금지)

### V1 — 빌드/분기 진입
- [ ] `demo-pilot` 생성됨 (`ls -la ~/Framework/Linux/project/demo/demo-pilot`)
- [ ] `echo walklab > /tmp/df-pilot-mode` 후 `sudo ./demo-pilot &` → stderr에
      `[main]/[df-pilot] entering WalkLabBrokerage` 로그 확인 (SOCCER로 안 빠지는지)
- [ ] `[WalkLabBrokerage] start polling /tmp/df-walklab-cmd` 로그 확인

### V2 — 명령 반영 (정지 상태, 발 들지 말 것)
- [ ] `echo "1 0 0 0 600 40 13" > /tmp/df-walklab-cmd` → 제자리 보행 시작
- [ ] `/tmp/df-walklab-ack`에 `OK ...` 기록 (데몬 처리 확인)
- [ ] Mac UI에서 "ROBOTIS onboard" + ACK 수신 표시

### V3 — 보행 품질 (핵심, 데모 = 답지)
- [ ] **제자리 걸음**: 몸통이 **지면과 평행 유지**, roll 진동 작음 (≠ 23° 뒤뚱)
- [ ] **방향 전환**(a≠0): 매끄럽게 회전, 넘어지지 않음
- [ ] **앞으로 걷기**(x=20~28mm): 데모처럼 자연스럽게 전진
- [ ] Mac HUD의 IMU roll/pitch가 **작은 진동**으로 안정 (이전 ~1.0Hz/23° 사라짐)
- [ ] 영상으로 데모와 나란히 비교 → 동등 수준 확인

### V4 — 안전 (필수, 통과 못하면 기본 전환 금지)
- [ ] **비상정지** → 로봇이 **5초 STALE 전에** 정지하는지 (현재 `walkLabRobotisStop`이
      `enabled=0` 송출 + `killall demo-pilot` 경로 — e-stop에서 실제 호출되는지 로그 확인)
- [ ] 명령 끊김(SSH 중단) → 5초 후 자동 stop 동작
- [ ] 정지 후 토크 상태 정상, 재시작 가능

### V5 — 안정성 (TODO 항목 실측)
- [ ] 주행 중 X/Y/A 실시간 변경 안정 (불안정하면 phase=0에서만 적용하도록 데몬 수정 필요)
- [ ] 주행 중 PERIOD_TIME 변경 안정성 (`WalkLabBrokerage.cpp` 내 TODO)

## 5. 검증 통과 후

- [ ] 기본 보행 엔진을 `.robotisOnboard`로 전환 (`WalkLabSession.swift:1934`
      `walkingEngine = .macSparseKeyframe` → `.robotisOnboard`), Mac 키프레임은 SSH 불가/sim fallback로 강등
- [ ] (선택) 데몬 v2: balance 필드(8~10) 파싱해 `Walking::BALANCE_*` 튜닝 노출
- [ ] (선택, Approach 2) 5Hz 파일 폴링 → TCP 소켓 푸시로 stick-to-step 지연 추가 절감
- [ ] (별개) 정적 -17° 전방 기울기 = IMU 영점(-10.85° 캡처값) + 힙피치 13° 조합.
      온보드 전환 후엔 로봇이 균형을 잡으므로 영향 적음 — 필요 시 IMU 영점 보정 적용 검토.

## 6. 미해결 질문 (검증 시 확인)

1. 운용 버스가 TCP(net:192.168.123.x:5530, RTT 16~100ms) 확정 — Mac 보행이 데모 품질
   불가한 근거. (USB 직결이면 Mac도 덜 나쁘나, 답지는 여전히 온보드.)
2. 실로봇 펌웨어가 v1.6.0 빌드 경로와 일치하는가 (MX28_1024 주석 → 4096 모드 → balance 게인 x4).
3. `Data/config.ini` 유무 — 없으면 브로커리지가 생성자 기본값(600ms, 13° hip, balance on) 사용.
4. 비상정지 온보드 경로가 5초 STALE 전 확실히 정지하는가 — 필요 시 명시 Stop()/torque-off 추가.

---

**요약**: 코드 측 준비는 완료(빌드 자동화 통합 + 브로커리지 + 분기). 남은 건 **로봇 연결 후
이 런북의 V1~V5 검증**이며, 통과 시 기본 엔진을 전환하면 조종 보행이 데모 수준이 된다.
