import Foundation

/// 로봇의 두 가지 상호배타 운용 모드 (+ 미연결).
///
/// # 비유
///
/// 한 대의 자동차를 "운전(스스로 달림)" 모드와 "정비(리프트에 올려 바퀴를 직접 돌림)"
/// 모드로 나눠 쓰는 것과 같다. 두 모드는 같은 엔진/바퀴(= CM730 시리얼 `/dev/ttyUSB0`)
/// 를 공유하므로 동시에 쓸 수 없다 — 한쪽을 켜면 반대쪽은 꺼진다.
///
/// # 모드
///
/// - `walk` (보행 / SSH 온보드): 로봇이 `walklab` 데모로 자율 보행. Mac 은 걷기/멈춤
///   명령과 상태(IMU·전압)만 주고받는다. `bus == nil`, `telemetryMode ∈ {.onboard, .onboardStale}`.
///   WalkLab·파일럿이 사용.
/// - `jointEdit` (관절편집 / LAN 버스): forge-bridge(TCP 5530)가 시리얼을 점유, Mac 이
///   `bus` 로 모터를 직접 제어. `bus != nil`, `telemetryMode == .lan`. 스튜디오·티칭이 사용.
/// - `offline`: 라이브 연결 없음.
///
/// 순수 값 타입 — UI import 없이(아이콘은 SF Symbol 문자열) 단위 테스트 가능.
public enum ConnectionMode: String, Equatable, Sendable, CaseIterable {
    case walk
    case jointEdit
    case offline

    /// 파생 규칙 — `ConnectionStore.currentMode` 가 이 헬퍼로 위임해 store 구성 없이
    /// 단위 테스트 가능하게 한다.
    ///
    /// 우선순위:
    ///   1. `busActive` (LAN 버스 존재) → `.jointEdit` — Mac 직접 제어가 최우선 진실.
    ///   2. `telemetryMode` 가 온보드 라이브/지연 → `.walk`.
    ///   3. 그 외 → `.offline`.
    public static func derive(busActive: Bool, telemetryMode: TelemetryMode) -> ConnectionMode {
        if busActive { return .jointEdit }
        switch telemetryMode {
        case .onboard, .onboardStale: return .walk
        case .lan, .offline:          return .offline
        }
    }

    /// 짧은 한국어 라벨 — 세그먼트/배지.
    public var label: String {
        switch self {
        case .walk:      return "보행"
        case .jointEdit: return "관절편집"
        case .offline:   return "오프라인"
        }
    }

    /// SF Symbol 아이콘.
    public var iconSystemName: String {
        switch self {
        case .walk:      return "figure.walk"
        case .jointEdit: return "slider.horizontal.3"
        case .offline:   return "wifi.slash"
        }
    }

    /// 이 모드가 무엇을 하는지 사용자에게 설명하는 한 줄 안내.
    public var guidance: String {
        switch self {
        case .walk:
            return "로봇이 자율 보행 — Mac은 걷기/멈춤 명령과 상태(IMU·전압)만. WalkLab·파일럿 사용."
        case .jointEdit:
            return "Mac이 관절을 직접 제어 — 스튜디오·티칭 사용. (보행은 멈춥니다.)"
        case .offline:
            return "라이브 연결 없음 — 먼저 로봇에 연결하세요."
        }
    }

    /// 두 모드가 같은 모터 버스를 공유한다는 공통 전환 주의 문구.
    public static let switchNote =
        "두 모드는 같은 모터 버스를 공유해 동시 사용 불가 — 전환하면 반대 모드는 종료됩니다(약 10초)."
}
