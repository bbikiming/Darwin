# 온보드 자동 일어나기(auto-getup) 수정·검증 — 2026-06-02

> **결론**: SSH 온보드(Wi-Fi) 모드에서 **넘어졌을 때 자동으로 일어나지 않던 문제 해결**.
> 원인은 로봇에 **v1.13 auto-getup 펌웨어 미배포**. 배포·재빌드·재시작 후 **앞/뒤 양방향
> 자동 기립을 라이브로 확인**(텔레메트리 + 육안).

---

## 1. 증상
SSH 온보드(Wi-Fi) 조종 중 로봇이 넘어져도 자동으로 일어나지 않음.

## 2. 원인 (하네스 로그로 진단)
Mac 하네스에 반복 기록된 이벤트:
```
recovery.getup_gate_blocked  gate="no_bus"  dxl_power=false  voltage=-1  cradle=true  fall_direction=forward
```
- Mac 측 자동복구는 **bus(LAN 5530 직결)** 가 있어야 동작하도록 게이팅됨. 온보드 모드엔
  bus가 없어(`no_bus`) 매번 차단 — **이는 의도된 설계**(온보드 모드는 "로봇 자율").
- 온보드 모드의 자동복구는 **로봇 펌웨어**가 담당해야 함. 그런데 로봇 SSH 점검 결과:
  - 구동 중 `demo` 바이너리 = **2026-06-01 빌드(v1.12)**, `CheckAndRecoverFall` **0개**.
  - 즉 **v1.13 auto-getup 패치가 로봇에 미배포** 상태였음. (Mac 레포엔 v1.13 존재)

## 3. 수정 (적용 내역)
1. v1.13 `WalkLabBrokerage.{cpp,h}` + `install-onboard.sh` 를 로봇
   `/robotis/Linux/project/demo/` 에 SSH 전송.
2. 로봇에서 `bash install-onboard.sh` 재빌드 (robotis 권한, 실행 중 demo 무영향).
   → 새 `demo` 바이너리 **2026-06-02 20:44, 188001 bytes, CheckAndRecoverFall 포함**.
3. demo 재시작 (`sudo -n killall demo` → `sudo -n …/demo`, NOPASSWD).
   로그: `[df] entering WalkLab onboard brokerage`. 현 PID 18148.
   ※ 재시작 시 모터 토크 순간 해제 → **로봇 받친 상태에서 수행**(안전 확인 후).

### v1.13 auto-getup 동작
`MotionStatus::FALLEN` 이 **6 poll(~600ms)** 연속 낙상 시 → Walking::Stop → getup page 재생:
- 앞으로 엎어짐 → **page 10**
- 뒤로 넘어짐 → **page 11**

## 4. 검증 (라이브, 텔레메트리 `fallen` 필드 감시)
앞/뒤 각각 완전히 눕히고 손 떼고 관찰:

| 방향 | 텔레메트리 증거 | 육안 |
|---|---|---|
| 뒤로 | `fallen=-1` **~4초 지속**(20:56:34) → `fallen=0`(20:56:38). getup page 11 모션 시간(~4s)과 일치 | 자동 기립 ✅ |
| 앞으로 | `fallen=1` 지속 후 `0` 복귀 | 자동 기립 ✅ |

> 대조: 살짝 기울이면 `fallen` 이 0↔1로 **~1초 깜빡**만 하고 getup 미발동(0.6s 디바운스
> 미충족). **완전 낙상 + 손 떼고 유지**해야 발동. 사용자 육안 확인: **"앞 뒤 둘 다 명확하게 잘 일어났어".**

## 5. 운영 메모 (중요)
- 온보드(Wi-Fi) 모드에선 Mac 하네스에 `recovery.getup_gate_blocked gate="no_bus"` 가 **계속
  찍히는 게 정상**입니다 — Mac 측 복구는 비활성이 맞고, **로봇 펌웨어가 자체적으로** 일어섭니다.
  이 로그를 보고 "복구 실패"로 오해하지 말 것.
- LAN(5530) 모드에선 Mac 측 자동복구(`AutoFallRecovery`)가 bus로 동작 — 두 모드가 상호보완.
- 펌웨어 원복: `/robotis/Linux/project/demo/` 에서
  `cp main.cpp.df-orig main.cpp && cp Makefile.df-orig Makefile && make`.

## 6. 최종 상태
- 로봇: demo PID 18148, v1.13(2026-06-02 20:44) 구동, walklab 온보드 모드, fallen=0(정상 기립).
- Mac 앱: DarwinForge 1.24.0 (build 566), SSH 온보드(Wi-Fi 192.168.0.33) 연결.
