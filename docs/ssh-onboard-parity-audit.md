# DarwinForge — 연결·조작 흐름 & SSH↔LAN 동등성 감사

> 2026-06-01 · 6차원 병렬 에이전트 감사 (connection-lifecycle, onboard-control-completeness,
> ssh-lan-parity-telemetry, safety-failure, cockpit-ux-feedback, visualization-model)

## 판정 (사용자 3대 질문)

| 질문 | 판정 | 한 줄 |
|---|---|---|
| ① 실행 앱이 최신 버전(아이콘·3D 모델) 맞나 | ✅ YES | 정식 빌드로 아이콘·메시 복원. 모델은 SafeResourceBundle(4경로 탐색 + 폴백)로 안전 |
| ② 연결 후 조작이 명확·원활한가 | ⚠️ PARTIAL | 걷기는 안정적이나, UI가 "어느 경로/엔진이 활성인지"·"텔레메트리 정지"를 안 알림 |
| ③ SSH가 LAN급 조작인가 | ❌ NOT YET | 동등이 아니라 **트레이드**. 온보드는 걷기 안정 ↔ Mac은 텔레메트리·헤드·하드웨어 e-stop 상실 |

## 핵심 진실: 두 경로는 상호 배타적 트레이드

- **LAN(5530 브리지)**: 전체 텔레메트리(IMU/관절/배터리) + 헤드/e-stop/일어나기/Mac 안전게이트 작동. 단 **걷기 뒤뚱**(open-loop).
- **SSH 온보드**: 공식 Walking 엔진 = **걷기 안정**(closed-loop 8ms). 단 demo가 `/dev/ttyUSB0` 점유 → `killall socat`(RobotSetupCommand.swift:315)로 **5530 죽음** → Mac은 **눈 가린 상태**(텔레메트리 0, 헤드 불가, 하드웨어 e-stop 불가, 안전게이트 무력).

## CRITICAL (안전)

- **C1. 온보드 모드에서 콕핏 E-STOP이 로봇에 안 닿음.** `ConnectionStore.emergencyStop()`(1370-1407)는 `bus.emergencyStop()`만 호출 → bus(5530)가 죽은 상태. SSH e-stop 경로 없음 → **로봇은 5초 stale 타임아웃까지 토크 켠 채 계속 걸음.** ← 실로봇 테스트 전 최우선 수정.
- **C2. 텔레메트리 끊기면 Mac 안전게이트가 조용히 무력화.** L0 전압/L3 50° 기울기/L4 과열 게이트가 stale·nil 읽고 발화 안 함. 정작 로봇이 무선으로 걸을 때 보호 없음.
- **C3. 재부팅 시 walklab 모드 조용히 이탈.** `/tmp/df-pilot-mode`는 tmpfs → 재부팅 후 demo가 SOCCER(공 추적)로. Mac은 여전히 onboard로 명령 전송 → **로봇이 공 쫓는데 사용자는 걷는 줄 앎.**

## HIGH

- **H1.** 정지된 텔레메트리를 "신선(녹색)"으로 표시 → 거짓 신뢰. staleness 게이팅 필요.
- **H2.** 온보드에서 **헤드 제어 불가** (serializedLine 10필드에 헤드 없음, WalkingEngine.swift:130-137). 한 감사 항목이 "헤드 멀티플렉싱됨"이라 했으나 **거짓**.
- **H3.** 일어나기/자동복구 온보드 불가인데 UI는 토글 제공.
- **H4.** 주 UI에 경로/엔진 모호 — `activeEndpoint`만 표시, 엔진 표시는 사이드패널에 묻힘, "CONNECTED"가 bus 존재로 판정.
- **H5.** `motorGate`가 온보드 깨진 상태에서도 "dispatch 활성 ✓" 표시.

## SSH = LAN 동등성 작업목록 (순서대로)

1. **SSH e-stop** — `/tmp/df-walklab-cmd`에 `enabled=0` + `killall -9 demo-pilot`, 로봇측 SIGTERM 핸들러로 Walking::Stop()+토크 off. *(C1 — 안전 바닥, 최우선)*
2. **로봇→Mac 텔레메트리 업링크** — demo-pilot이 IMU+관절/전압/온도를 `/tmp/df-walklab-telemetry`에 ~5Hz write, Mac이 SSH로 폴링 → HUD·낙상예측·L0/L3/L4 게이트 복구. *(C2·H1·H3 해제)*
3. **경로/엔진/staleness 명시 표면화** — `TelemetryMode` enum + 영구 경로·엔진 배지 + stale desaturation + "SAFETY GATES OFFLINE" 배너. *(C2·H1·H4)*
4. **온보드 헤드 제어** — serializedLine + 로봇 sscanf에 헤드 pan/tilt 필드 추가. *(H2)*
5. **모드 영속 + 연결시 검증** — walklab 모드 재부팅 유지, SSH 연결시 데몬 모드 확인·자동복구. *(C3)*
6. **데몬 감시** — systemd Restart=always + heartbeat, Mac 자동폴백 onboardLastAckAt stale>2s. 
7. **게이트·폴백 정리** — onboard-aware motorGate, 폴백 히스테리시스, 정지 확인, 엔진전환 배너, LAN↔SSH 전환 통합테스트. *(H5·M2·M3)*

## 정직한 결론

LAN과 SSH는 **반비례, 동등 아님**. 동등(파리티)을 원하면 위 1-4가 필수. 그전까지 온보드는 "걷기 안정·안전/관측 저하"로 취급하고 **UI가 그걸 명시**해야 함(녹색 LAN 데이터 위장 금지).

핵심 파일: WalkingEngine.swift(serializedLine 10필드), WalkLabOnboardBridge.swift(send/ACK/폴백), RobotSetupCommand.swift(start가 socat kill:315; SSH e-stop 없음), ConnectionStore.swift(emergencyStop:1370-1407), PilotCockpitView.swift·CockpitWalkLogicPanel.swift(onboard-aware 게이팅/표시 없음).
