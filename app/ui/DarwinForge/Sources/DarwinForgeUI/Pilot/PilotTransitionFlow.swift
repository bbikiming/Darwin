import Foundation

/// Pilot 모드 전환 단계 한 개 — 사용자 화면에 체크리스트로 표시.
///
/// 두 시나리오:
///   - **patched demo 설치 됨**: 모든 단계 자동.
///   - **원본 demo (패치 미설치)**: "로봇 후면 MODE 버튼", "로봇 후면 START 버튼" 두 단계가
///     `kind = .waitingForUser` — 사용자가 직접 로봇을 만져야 함.
///
/// 단계 ID 는 안정 — 테스트 / 다국어 / 분석에 활용.
public struct PilotTransitionStep: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public var kind: Kind
    /// 예상 소요 시간 — automatic 일 때 progress UI 가 fake progress 채우기 용.
    public let estimatedSeconds: Double

    public enum Kind: Sendable, Equatable {
        /// 자동 진행 — 스피너 표시.
        case automatic
        /// 사용자가 로봇 후면 버튼 등 직접 액션 필요 — 강조 + 펄스.
        case waitingForUser
        /// 완료 — 체크 마크.
        case completed
        /// 실패 — X 마크 + 사유.
        case failed(String)
    }

    public init(id: String, title: String, detail: String,
                kind: Kind, estimatedSeconds: Double = 1.0) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.estimatedSeconds = estimatedSeconds
    }
}

/// 시나리오별 단계 시퀀스 — RemotePilotView 가 모드 전환 시 선택.
public enum PilotTransitionFlow {
    /// **시나리오 1**: 사용자가 "공 자동 추적" 클릭 + patched demo 설치돼 있음.
    /// 모든 단계 자동 — 사용자 액션 없음.
    public static func ballFollowPatched() -> [PilotTransitionStep] {
        [
            .init(id: "stop-bridge",
                  title: "forge-bridge 종료",
                  detail: "USB bus 해제 — ROBOTIS demo 가 점유 가능하도록",
                  kind: .automatic, estimatedSeconds: 0.5),
            .init(id: "start-demo-patched",
                  title: "패치 demo 시작",
                  detail: "`demo-pilot` binary 실행 + `/tmp/df-pilot-mode=soccer` 쓰기",
                  kind: .automatic, estimatedSeconds: 1.5),
            .init(id: "auto-soccer-mode",
                  title: "자동 SOCCER 모드 진입",
                  detail: "StatusCheck::m_cur_mode = SOCCER + mp3 안내",
                  kind: .automatic, estimatedSeconds: 1.0),
            .init(id: "gyro-calibration",
                  title: "센서 calibration",
                  detail: "Gyro 보정 — 로봇이 흔들리지 않도록 정비 스탠드 유지",
                  kind: .automatic, estimatedSeconds: 3.0),
            .init(id: "walk-ready",
                  title: "walk_ready 자세",
                  detail: "Action page 9 + Head / Walking 모듈 enable",
                  kind: .automatic, estimatedSeconds: 1.0),
            .init(id: "tracking-active",
                  title: "공 추적 활성",
                  detail: "Camera HUD 의 공 위치 표시 + head pan/tilt 동작 확인",
                  kind: .automatic, estimatedSeconds: 0.5),
        ]
    }

    /// **시나리오 2**: 원본 demo (패치 미설치). 후면 버튼 단계 포함.
    public static func ballFollowOriginal() -> [PilotTransitionStep] {
        [
            .init(id: "stop-bridge",
                  title: "forge-bridge 종료",
                  detail: "USB bus 해제 — ROBOTIS demo 가 점유 가능하도록",
                  kind: .automatic, estimatedSeconds: 0.5),
            .init(id: "start-demo-original",
                  title: "원본 demo 시작",
                  detail: "`demo` binary 실행 — READY 모드로 시작",
                  kind: .automatic, estimatedSeconds: 1.5),
            .init(id: "press-mode-button",
                  title: "로봇 후면 MODE 버튼 1회",
                  detail: "후면 패널의 MODE 버튼을 짧게 누르세요 — head LED 가 빨강으로 + “Autonomous soccer mode” 음성",
                  kind: .waitingForUser),
            .init(id: "press-start-button",
                  title: "로봇 후면 START 버튼 1회",
                  detail: "후면 패널의 START 버튼을 짧게 누르세요 — “Start soccer demonstration” 음성 + gyro 보정 시작",
                  kind: .waitingForUser),
            .init(id: "tracking-active",
                  title: "공 추적 활성",
                  detail: "Camera HUD 의 공 위치 표시 + head pan/tilt 동작 확인",
                  kind: .automatic, estimatedSeconds: 0.5),
        ]
    }

    /// **시나리오 3**: "수동" 으로 돌아갈 때 — demo 종료 + bridge 복구.
    public static func manualRecovery() -> [PilotTransitionStep] {
        [
            .init(id: "stop-demo",
                  title: "ROBOTIS demo 종료",
                  detail: "demo / demo-pilot / walk_demo 모두 종료",
                  kind: .automatic, estimatedSeconds: 1.0),
            .init(id: "start-bridge",
                  title: "forge-bridge 복구",
                  detail: "5530 socat 재시작 — Mac 모터 송출 가능",
                  kind: .automatic, estimatedSeconds: 1.0),
            .init(id: "manual-ready",
                  title: "수동 모드 준비",
                  detail: "Action Bar / ARM 슬라이더 사용 가능",
                  kind: .automatic, estimatedSeconds: 0.5),
        ]
    }
}
