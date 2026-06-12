# docs/design/ — 업그레이드 기획 문서 인덱스

> 2026-06-11 기준. 각 Wave 가 머지될 때 이 표의 상태를 갱신한다.
> **구현 착수는 [implementation-prompts.md](implementation-prompts.md)** — 세션별 복붙
> 프롬프트 12종(P1~P12, 의존 순서 정렬·체크박스 추적).
> 모든 문서는 "다른 세션이 추가 탐색 없이 착수 가능"을 기준으로 작성됨 — 착수 전 해당
> 문서의 착수 가이드 절(§)부터 읽을 것.

## 1. 문서 목록과 구현 현황

| 문서 | 영역 | 설계 커밋 | 구현 현황 |
|---|---|---|---|
| [cockpit-latency-hardening.md](cockpit-latency-hardening.md) | Mac 전송·입력·시리얼 (확정 이슈 35건) | cf132bd | **W0 ✅**(66039c6·8139247) · **W2 ✅**(e0bb2cf·da495d6·7808fdb·c62d3af·a61afbc·9dff323) · W3 부분(J1 fe8d748, J9 0153464) · **J4·J13 ✅**(bus D0) · §6 Tracer 7지점 mark 모델 ✅ · **W1 코드 ✅**(OnboardCommandChannel+PersistentSSHChannel+UDP E-STOP+SendPolicy, P3) · LatencyBudgetRegressionTests ✅ · 실기 벤치 ⬜ |
| [controller-mapping-uiux.md](controller-mapping-uiux.md) | 컨트롤러 매핑 GUI/프로파일 | 2026-06-10 | **P1~P3+드라이버 실소비 ✅**(3c5f97c·f3352c1·f088628·1f52279·cde16de) · 잔여 L4(드라이버 일원화)는 레이턴시 문서 관할 |
| [3d-viewport-enhancement.md](3d-viewport-enhancement.md) | 5개 화면 3D 뷰포트 (모델링·조명·환경·오버레이) | b46a226 | **W0 ✅**(b941f54) · **W1 ✅**(2a58777+2abd6d4) · +라이브 튜닝 패널(9a32f8d, 계획 외) · **W2 ✅**(화면별 프리셋 5종+셰이더 AA 그리드+소품·콕핏 그리드 58→1노드, 3399 테스트) · **W3 ✅**(RigSkeleton 선행+오버레이 7종: CoM·지지다각형·관절축·한계각·FSR·수평선·EE궤적·한계경고, 0-alloc 풀·자체 타이머 0 — 브랜치 `claude/p11-3d-overlays` 머지됨) · **W4 ✅**(MeshRig 머리 디테일·ViewCube ease 전환+`shortestAngleDelta`·턴테이블·DOF 토글·Cockpit 체이스 follower) · **W5 ✅**(성능 가드 §7 실측·`renderImage` 회귀 가드·스냅샷 5종 기준선, +20 테스트) — **3D 트랙 전 웨이브 완료** |
| [walklab-onboard-teleop-upgrade.md](walklab-onboard-teleop-upgrade.md) | 로봇 측 코드·알고리즘 + 명령/텔레메트리 계약 | 2507be6 | **O0 코드 ✅**(TEL ≥11+last_cmd_id/loop_ms·RobotClockSync·tracer ackReceived, P3) · **O1 코드 ✅**(WalkLabTransport 순수 로직+호스트 테스트 63 checks·브로커리지 UDP 리스너 17372/17374·supervisor 20ms·워치독 티어 600/2500ms 스트림 소스 전용·RefreshHandshake·파일 폴백 보존, P3) · **O2 코드 ✅**(거버너·슬루·게이트 스케줄·twist v2·밸런스 결선, 호스트 154 checks) · **O4 코드 ✅**(TEL2 30Hz UDP/파일 TEL v1 5Hz·FSR/CoP·phase·래치·seq_applied·active_source·J6 적응형 폴러·콕핏 명령vs래치 HUD·walkAnimator 위상동기·3D FSR 오버레이, P9 `daa2550`·`998297a`) · 실기 배포(demoBuildPatched)·벤치(≥20Hz·E-STOP p95·30Hz 수신율) ⬜ · O3(FSR/IMU 밸런스 피드백) ⬜ |
| [bus-direct-teleop-upgrade.md](bus-direct-teleop-upgrade.md) | 직결(bus) 조종 — 50Hz 연속 스트리밍 | b54daff | **D0 ✅**(J4·J13·계측) · **D1 ✅ 5ff5873**(시간 기반 50Hz 공유 샘플러+래치, 양 송출 루프) · **D2 ✅ e940e63**(IMU 50Hz·자이로 LPF·FSR 오버레이; FSR 유선 5Hz·낙상 윈도 IMU레이트 독립은 보고됨) · D3 ⬜ — 실기(드리프트·온도·진동·20ms 추종) 사용자 보고 대기 |
| [handheld-direct-pilot-upgrade.md](handheld-direct-pilot-upgrade.md) | RG G01 **2.4G 동글** 직결(USB HID, 유선은 폴백) + Switch 무선 최적화 | f157c06 (동글 기본 개정 2026-06-11) | **H0 ✅ 실측 완료**(2026-06-12, [보고서](../reports/2026-06-12-rgg01-usb-probe.md) — Track A 확정, graceful 단절=release 합성+노드 소멸(거리이탈 미측정), 유선 폴백 불발) · H3 코드 ✅(P10) · H1·H2 ⬜ |

## 2. 의존 그래프

```
                    ┌─ controller-mapping-uiux (완료) — 매핑 의미론의 원천
                    │
cockpit-latency-hardening (Mac 공통 전송·계측)
  W1(SSH/UDP 허브) ◀━ 한 묶음 ━▶ onboard O0·O1 (브로커리지 v2 — 이벤트 구동)
                                    │
        onboard O2(거버너·twist) ───┼── 전 클라이언트의 최종 안전판
          │  상수 공유               │     (콕핏·Switch·G01·모바일)
          ▼                         ▼
  bus D1(50Hz 스트리밍)·D2     handheld H1(GamepadPilot)·H3(Switch UDP화)
          │                         │
        onboard O3(FSR/IMU 피드백)·O4(TEL2 30Hz)
          │
          ▼
  3d-viewport W3(CoM/FSR/IMU 오버레이가 실데이터 소비)   ※ W2·W4·W5 는 독립
```

## 3. 전 문서 공유 불변식 (요약)

- **E-STOP 경로에 스로틀·배칭·추가 홉 금지** — 변경은 홉 제거 또는 병행 채널 추가 방향만.
- **파일 기반 명령/E-STOP/텔레메트리 경로는 영구 폴백** — UDP/stdin 은 가산 채널.
- **로봇 측 거버너(O2-3)가 최종 클램프 소유** — 클라이언트 클램프는 UX 레이어.
  (현재 Switch 가 stride 50mm 를 무거버너로 통과시킴 — O2-3 이 핸드헬드 계열 전제.)
- **래칭·슬루·게이트 스케줄·밸런스 LPF 상수는 단일 정의 공유** — 모드 간 조종감 패리티.
- 3D: 30fps·`isFullyIdle`·0-alloc 풀·`wantsHDR=false` 계약 유지, 헤드리스 스냅샷 회귀 금지.
- Swift 테스트 serial 실행(UserDefaults 공유), 실기는 크래들+다리 토크 해제+배터리 차단.

## 4. 권장 착수 순서 (2026-06-11 시점)

1. ~~**H0 — RG G01 2.4G 동글 호환성 프로브**~~ ✅ 2026-06-12 실측 완료 — Track A 확정,
   H1 코드 테이블·failsafe 거동 확보 ([보고서](../reports/2026-06-12-rgg01-usb-probe.md)).
2. **3D W2 — 화면별 환경 프리셋+셰이더 그리드** (독립, UI 전용): W1 완료로 즉시 가능.
3. **레이턴시 W1 + 온보드 O0·O1** (한 묶음, 최대 체감): 명령 4–8Hz→20-30Hz,
   E-STOP 로봇 측 100ms→~5ms.
4. **온보드 O2 — 거버너·의미론 v2**: 핸드헬드(H1·H3)와 bus(D1) 착수의 안전 전제.
5. 이후 병렬: bus D1·D2(D0 ✅) / handheld H1·H2 / 3D W3(O4 TEL2 이후 실데이터) / O3(실기 비중 최대).
