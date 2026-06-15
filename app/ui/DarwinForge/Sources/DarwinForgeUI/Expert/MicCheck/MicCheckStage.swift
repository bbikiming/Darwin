import Foundation

/// 다윈 마이크 체크 실험의 5단계.
///
/// 순서: 장치 탐색 → 녹음 → 맥 전송 → 분석·재생 → 이해(전사).
public enum MicCheckStage: String, CaseIterable, Identifiable {
    case probe
    case record
    case transfer
    case analyze
    case transcribe

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .probe:      return "1. 장치 탐색"
        case .record:     return "2. 로봇 마이크 녹음"
        case .transfer:   return "3. 맥으로 전송"
        case .analyze:    return "4. 분석 · 재생"
        case .transcribe: return "5. 이해 (음성→텍스트)"
        }
    }

    public var subtitle: String {
        switch self {
        case .probe:      return "로봇에 캡처 가능한 마이크가 있는지 확인"
        case .record:     return "arecord 로 사용자 음성 캡처"
        case .transfer:   return "녹음 바이트가 실제로 맥에 도달하는지 검증"
        case .analyze:    return "파형/레벨로 소리가 잡혔는지 확인 + 재생"
        case .transcribe: return "맥이 음성을 텍스트로 이해할 수 있는지"
        }
    }

    public var iconName: String {
        switch self {
        case .probe:      return "magnifyingglass"
        case .record:     return "mic.fill"
        case .transfer:   return "arrow.down.circle.fill"
        case .analyze:    return "waveform"
        case .transcribe: return "text.bubble.fill"
        }
    }
}

/// 한 단계의 진행/결과 상태.
public enum StageStatus: String, Equatable {
    case pending     // 아직 실행 안 됨
    case running     // 실행 중
    case passed      // 성공
    case warning     // 실행됐으나 주의 (예: 신호 거의 없음)
    case failed      // 실패
    case skipped     // 앞 단계 실패로 건너뜀
}

/// 한 단계의 불변 결과 레코드.
///
/// 상태 변경은 항상 새 인스턴스로(불변성) — `MicCheckStore` 가 배열 요소를 교체한다.
public struct StageOutcome: Equatable, Identifiable {
    public let stage: MicCheckStage
    public let status: StageStatus
    /// 사용자용 한 줄 결과.
    public let summary: String
    /// 접을 수 있는 원시 진단(명령/출력/에러).
    public let detail: String

    public var id: String { stage.rawValue }

    public init(stage: MicCheckStage, status: StageStatus,
                summary: String = "", detail: String = "") {
        self.stage = stage
        self.status = status
        self.summary = summary
        self.detail = detail
    }

    /// 초기 pending 상태.
    public static func pending(_ stage: MicCheckStage) -> StageOutcome {
        StageOutcome(stage: stage, status: .pending, summary: "대기 중")
    }
}
