# OP Pilot iOS UX Upgrade Build 5

작성일: 2026-05-25  
대상: `app/mobile/DarwinForgeMobile`  
빌드: `0.1.0 (5)`

## 적용한 UX 방법론

1. Apple Human Interface Guidelines
   - iOS 네이티브 기본 패턴을 유지하기 위해 `Form`, `NavigationStack`, `TabView`, system color, SF Symbols 중심으로 정리했다.
   - 연결 화면은 온보딩 원칙에 맞춰 한 번에 모든 설정을 요구하지 않고 `Mac 앱 준비 → 같은 Wi-Fi → 6자리 코드 → 상태 확인` 순서로 쪼갰다.
   - 상태 대시보드는 차트/데이터 시각화 원칙에 맞춰 색상만으로 상태를 전달하지 않고 숫자, 라벨, 막대, 선 그래프를 함께 제공한다.
   - 참고: [Apple HIG](https://developer.apple.com/design/human-interface-guidelines), [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding), [Charting data](https://developer.apple.com/design/human-interface-guidelines/charting-data), [Color](https://developer.apple.com/design/human-interface-guidelines/color)

2. Nielsen Norman Group 10 Usability Heuristics
   - Visibility of system status: Mac, 로봇, 잠금, 지연, 전압, 온도를 즉시 보이게 했다.
   - Match between system and real world: `ARM`, `ACK`, `watchdog`, `프리폼`, `Mock` 같은 용어를 `잠금 해제`, `응답`, `안전 감시`, `자유 조종`, `연습`으로 바꿨다.
   - Recognition rather than recall: 연결 절차를 단계 행으로 노출해 사용자가 기억하지 않고 따라갈 수 있게 했다.
   - Error prevention: 조작 화면이 아닌 연결/테스트/기록에서 긴급 정지 버튼을 제거해 실수 탭 가능성을 줄였다.
   - 참고: [NN/g 10 Usability Heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/)

## 구현 결과

### 연결

- 긴급 정지 버튼 제거.
- 현재 상태 섹션 추가: Mac 앱, 로봇, 연결 대상.
- 사용 방식 문구 변경: `연습`, `실제 연결`.
- 순차 가이드 추가: Mac 앱 준비, 같은 Wi-Fi, 6자리 코드, 상태 대시보드 확인.
- 자동 찾기/공유 텍스트/IP 직접 입력은 유지하되, 사용자가 언제 무엇을 써야 하는지 footer copy로 설명.

### 테스트

- 긴급 정지 버튼 제거.
- 테스트 단계 문구를 현장 행동 중심으로 정리.
- `E-stop`, `watchdog stop`, `background stop`을 쉬운 한국어로 변경.

### 기록

- 긴급 정지 버튼 제거.
- 제목을 `실행 기록`으로 변경.
- 빈 상태 화면 추가.
- 로그 행에 카테고리와 수준 라벨을 추가해 스캔성을 높임.

### 동작/조종기

- `ARM` 중심 문구를 `잠금 해제`로 변경.
- 조종기 탭 이름을 `조종기 (연습)`으로 변경.
- 실 로봇에서 비활성인 자유 조종/머리 방향 조절을 더 명확히 표시.

### 상태 대시보드

- `AppState.telemetryHistory` 추가: 최근 48개 텔레메트리 프레임 보존.
- 상태 탭에 `RobotDashboardView` 추가.
- 표시 항목:
  - Mac 연결 상태
  - 로봇 연결 상태
  - 잠금 상태
  - 다음 조치 안내
  - 배터리, 응답 지연, 모터 온도, 최근 응답 막대
  - 응답 지연/배터리 선 그래프

## 검증 결과

- 불필요한 긴급 정지 버튼 제거 확인:
  - `ConnectScreen`, `TestScreen`, `LogsScreen`에는 `EmergencyStopButton` 없음.
  - 조작이 필요한 `PilotScreen`, `RemotePilotScreen`에는 유지.
- 패키지 테스트:
  - `swift test`
  - 결과: 31개 테스트 통과.
- iOS 시뮬레이터 빌드:
  - `xcodebuild -project Xcode/DarwinForgeMobile.xcodeproj -scheme OPPilot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build`
  - 결과: 성공.
- 시뮬레이터 실행:
  - `xcrun simctl install "iPhone 17" ".../OP Pilot.app"`
  - `xcrun simctl launch "iPhone 17" com.yuseok.oppilot`
  - 결과: 앱 실행 성공, 첫 화면 렌더링 확인.
- Release 아카이브:
  - `xcodebuild -project Xcode/DarwinForgeMobile.xcodeproj -scheme OPPilot -configuration Release -destination 'generic/platform=iOS' -archivePath Xcode/.build/OPPilot-0.1.0-5.xcarchive archive -allowProvisioningUpdates`
  - 결과: `ARCHIVE SUCCEEDED`.
  - 산출물: `app/mobile/DarwinForgeMobile/Xcode/.build/OPPilot-0.1.0-5.xcarchive`

## 실제 로봇 검증에서 남은 조건

- 이번 작업은 앱 구현, 시뮬레이터 실행, 아카이브까지 완료했다.
- 실제 로봇 end-to-end 검증은 Mac Darwin Forge 앱의 Mobile Pilot Relay, 같은 Wi-Fi, 실제 로봇 전원/네트워크, 물리 긴급 정지 버튼 접근성이 준비된 상태에서 별도로 수행해야 한다.
- 카메라 QR 스캔은 아직 구현되어 있지 않으며, 화면 문구도 이 사실을 명시한다. 현재는 Mac 앱이 제공하는 연결 텍스트 붙여넣기와 IP 직접 입력을 지원한다.
