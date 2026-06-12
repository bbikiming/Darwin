# App Review Notes 템플릿

App Store Connect 제출 시 "App Review Information → Notes" 에 붙여넣을 내용.
DarwinForge 는 외부 하드웨어(ROBOTIS-OP2 robot) 의존 앱이므로, 심사관이 하드웨어
없이 검토 가능하도록 시뮬레이션 모드를 명시하는 것이 핵심.

---

## 영문 (App Review 제출용)

```
DarwinForge is a macOS app for controlling, authoring motion for, and
programming ROBOTIS DARwIn-OP / OP2 humanoid robots over USB serial.

=== Reviewing without hardware ===

The app does NOT require a physical robot to launch, navigate, or evaluate.
On first launch with no robot connected, the app runs in SIMULATION MODE:

- Walk Lab: full gait simulation with on-screen 3D robot model, IMU gauges,
  and fall-prevention monitoring dashboard — all driven by a software model,
  no hardware needed.
- Motion Studio: pose authoring and motion playback preview in the 3D viewport.
- All menus, settings, and UI are fully functional without a robot.

The USB entitlement (com.apple.security.device.usb) is used ONLY when a real
ROBOTIS-OP2 robot is connected via USB serial. Its absence does not block any
review path — the app gracefully shows "simulation mode" when no robot is present.

=== Permissions ===

- Microphone / Speech Recognition: optional voice commands ("walk", "stop",
  "emergency"). The app is fully usable without granting these.
- Local Network: pairs with the companion iOS app (OP Pilot) over Bonjour for
  remote control relay, and communicates with a Tello drone. Optional feature.

=== Demo video ===

A short screen recording demonstrating simulation mode (no hardware) is
attached / available at: [URL]

Thank you for reviewing. Please reach out via Resolution Center with any
questions about the hardware integration.
```

---

## 한국어 (내부 참고용)

```
DarwinForge 는 ROBOTIS DARwIn-OP / OP2 휴머노이드 로봇을 USB 시리얼로 제어/
모션 제작/프로그래밍하는 macOS 앱입니다.

=== 하드웨어 없이 심사하기 ===

실 로봇 없이도 앱 실행/탐색/평가 가능합니다. 로봇 미연결 상태에서 첫 실행 시
시뮬레이션 모드로 동작:
- Walk Lab: 3D 로봇 모델 + IMU 게이지 + fall-prevention 모니터링 대시보드,
  모두 소프트웨어 모델 구동 (하드웨어 불필요)
- Motion Studio: 3D 뷰포트에서 자세 제작 + 모션 재생 미리보기
- 모든 메뉴/설정/UI 가 로봇 없이 완전 동작

USB entitlement 은 실 ROBOTIS-OP2 가 USB 연결됐을 때만 사용. 부재 시 "시뮬레이션
모드" 표시 — 심사 경로 차단 없음.

=== 권한 ===
- 마이크 / 음성 인식: 선택적 음성 명령 ("걸어"/"정지"/"비상"). 미허용해도 사용 가능.
- 로컬 네트워크: iOS 컴패니언 앱 (OP Pilot) Bonjour 페어링 + Tello 드론 통신. 선택 기능.

=== 데모 영상 ===
시뮬레이션 모드 시연 화면 녹화: [URL]
```

---

## 데모 영상 가이드 (권장)

App Review 가 하드웨어 없이 기능을 이해하도록 30초~2분 영상:

1. 앱 실행 → "시뮬레이션 모드" 표시
2. Walk Lab 진입 → 3D 모델 보행 시뮬 + 모니터링 dashboard (⌘⇧M)
3. Motion Studio → 자세 제작 미리보기
4. (선택) 실 robot 연결 시 동작 — 별도 영상

업로드: App Store Connect 의 "App Review Information → Attachment" 또는
외부 URL (YouTube unlisted 등).
