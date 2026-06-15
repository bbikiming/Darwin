import ForgeCore
import Foundation

/// `motion_4096.bin` 페이지 메타데이터 + v1 single-pose approximation 매핑.
///
/// ## ⚠️ 정확한 표현 (Codex audit P1-5, 2026-05-14)
///
/// 이 catalog 는 **공식 motion_4096.bin 메타데이터 + v1 single-pose approximation**
/// 이다. byte-identical raw page 재생이 아니라:
///
/// 1. **메타데이터** (slot, name, safety class) 는 공식 `motion_4096.bin` 의 page
///    header 와 `gui_motion.yaml` 의 안전 분류를 그대로 따른다.
/// 2. **자세는 single target pose approximation** — `v1TargetPoseID` 가 가리키는
///    `PoseLibrary` 의 검증된 단발 자세로 보내고, ConnectionStore.applyPoseSmoothly
///    의 안전 경로 (voltage / load / limit / split) 로 전이.
/// 3. **시간 곡선** (4-step bow 등) 은 현 v1 에서 재현 X. raw chain replay 는
///    v1.6 `motion_play` 기반 별도 경로로 예정.
///
/// **chain page (24/38/54) 의 사용자 표시 시간**: `durationMs` 는 v1 단발 전이 추정,
/// `rawChainDurationMs` 는 공식 chain 의 총 길이 (next_page 따라간 누계). UI 는
/// "공식 모션 재생" 으로 라벨링되는 경우 `rawChainDurationMs` 를, "단발 자세" 로
/// 라벨링되는 경우 `durationMs` 를 사용해야 한다.
public enum SafetyClass: String, Sendable, Codable, Equatable {
    case safe
    case caution
    case highRisk = "high_risk"

    public var koreanLabel: String {
        switch self {
        case .safe:     return "안전"
        case .caution:  return "주의"
        case .highRisk: return "위험"
        }
    }

    public var requiresConfirm: Bool { self == .highRisk }
}

/// 한 motion 페이지의 UI 메타데이터.
public struct MotionPageMetadata: Sendable, Equatable, Identifiable {
    /// `motion_4096.bin` 의 페이지 ID (1-based, 1..255).
    public let slot: UInt8
    /// 원본 페이지 이름 (RoboPlus 에서 그대로) — debug / tooltip 용.
    public let rawName: String
    /// 영문 UI 라벨.
    public let displayName: String
    /// 한국어 UI 라벨 (PRD §7.1).
    public let displayNameKo: String
    /// 안전 등급.
    public let safetyClass: SafetyClass
    /// **v1 single-pose 전이 시간** (ms) — `applyPoseSmoothly` 의 ramp 시간.
    /// chain page 의 공식 총 시간이 아님. 사용자에게 보여줄 때 "단발 자세" 표시 필요.
    public let durationMs: UInt32
    /// **Phase G5 (Codex audit P1-5)**: 공식 chain 의 총 지속 시간 (next_page 따라간 누계).
    /// nil 이면 single page (durationMs 와 동일). chain 인 경우 `motion_4096.bin` 의
    /// `decode_raw_page` 로 계산한 값.
    public let rawChainDurationMs: UInt32?
    /// 동기 mp3 파일명 (v2 활성). nil = 음원 없음.
    public let mp3Sync: String?
    /// 영향 받는 신체 부위.
    public let bodyRegions: [JointID.BodyPart]
    /// SF Symbol 아이콘 (UI).
    public let icon: String
    /// v1.0 에서 송출할 target pose. `PoseLibrary` 의 검증된 자세 ID.
    /// nil 이면 v1.0 비활성 (v1.5 에서 raw step 송출 필요).
    public let v1TargetPoseID: String?

    public var id: UInt8 { slot }

    /// **Phase G8 (Codex audit follow-up, 2026-05-15)**: chain page 여부.
    /// `motion_4096.bin` 의 next_page 가 있는 페이지 (24/38/54) 면 true.
    public var isChain: Bool { rawChainDurationMs != nil }

    /// 사용자에게 표시할 "공식 모션 길이" — chain 페이지면 chain 총합, 아니면 단발.
    /// **주의**: Mac v1 은 단발 자세 송출만 한다. 실제 progress ring 시간은 단발
    /// `durationMs` 를 그대로 써야 — Mac 이 8 초 ring 돌리는데 실 송출은 끝났다고
    /// 사용자가 혼동하지 않도록 (옵션 A). chain 표시는 caption / alert 보조 정보 용.
    public var effectiveDurationMs: UInt32 { rawChainDurationMs ?? durationMs }

    public init(slot: UInt8, rawName: String, displayName: String, displayNameKo: String,
                safetyClass: SafetyClass, durationMs: UInt32, rawChainDurationMs: UInt32? = nil,
                mp3Sync: String?, bodyRegions: [JointID.BodyPart], icon: String,
                v1TargetPoseID: String?) {
        self.slot = slot
        self.rawName = rawName
        self.displayName = displayName
        self.displayNameKo = displayNameKo
        self.safetyClass = safetyClass
        self.durationMs = durationMs
        self.rawChainDurationMs = rawChainDurationMs
        self.mp3Sync = mp3Sync
        self.bodyRegions = bodyRegions
        self.icon = icon
        self.v1TargetPoseID = v1TargetPoseID
    }
}

public enum MotionCatalog {
    /// Action Bar 메인 7 페이지 (v1.0 활성 — PRD §7.1).
    public static let actionBarMainSlots: [UInt8] = [1, 4, 15, 12, 13, 9, 23]

    /// "+ 더 보기" 9 페이지 (v1.5 활성 — PRD §7.2).
    public static let actionBarMoreSlots: [UInt8] = [2, 3, 10, 11, 16, 24, 27, 38, 54]

    /// 전체 16 페이지 — sidecar TOML 의 hardcode 미러.
    public static let all: [MotionPageMetadata] = [
        // — Action Bar 메인 7 —
        .init(slot: 1, rawName: "init",
              displayName: "Stand Up", displayNameKo: "기본 자세",
              safetyClass: .safe, durationMs: 2000,
              mp3Sync: "Stand up.mp3",
              bodyRegions: [.rightArm, .leftArm, .rightLeg, .leftLeg, .head],
              icon: "figure.stand",
              v1TargetPoseID: "idle"),
        .init(slot: 4, rawName: "hi",
              displayName: "Thank You", displayNameKo: "감사 인사",
              safetyClass: .safe, durationMs: 3600,
              mp3Sync: "Thank you.mp3",
              bodyRegions: [.head, .rightArm, .leftArm],
              icon: "hand.raised.fill",
              v1TargetPoseID: "bow_60"),
        .init(slot: 15, rawName: "sit down",
              displayName: "Sit Down", displayNameKo: "앉기",
              safetyClass: .safe, durationMs: 1000,
              mp3Sync: "Sit down.mp3",
              bodyRegions: [.rightLeg, .leftLeg],
              icon: "figure.seated.side",
              v1TargetPoseID: "sit_chair"),
        .init(slot: 12, rawName: "rk",
              displayName: "Right Kick", displayNameKo: "오른발 차기",
              safetyClass: .highRisk, durationMs: 1700,
              mp3Sync: "Right kick.mp3",
              bodyRegions: [.rightLeg],
              icon: "figure.kickboxing",
              v1TargetPoseID: "kick_forward_right"),
        .init(slot: 13, rawName: "lk",
              displayName: "Left Kick", displayNameKo: "왼발 차기",
              safetyClass: .highRisk, durationMs: 1700,
              rawChainDurationMs: nil, // single page (next_page=0)
              mp3Sync: "Left kick.mp3",
              bodyRegions: [.leftLeg],
              icon: "figure.kickboxing",
              // Phase G5 (Codex audit P1-5, 2026-05-14) — mirror pose 추가됨.
              // 이전엔 nil 이라 메인 7 슬롯 중 Right Kick / Left Kick UX 비대칭.
              v1TargetPoseID: "kick_forward_left"),
        .init(slot: 9, rawName: "walkready",
              displayName: "Walk Ready", displayNameKo: "보행 자세",
              safetyClass: .safe, durationMs: 1000,
              mp3Sync: nil,
              bodyRegions: [.rightArm, .leftArm, .rightLeg, .leftLeg],
              icon: "figure.walk.motion",
              v1TargetPoseID: "walk_ready"),
        .init(slot: 23, rawName: "d1",
              displayName: "Yes Go", displayNameKo: "출발!",
              safetyClass: .safe, durationMs: 3000,
              mp3Sync: "Yes go.mp3",
              bodyRegions: [.rightArm, .leftArm, .head],
              icon: "hand.point.right.fill",
              v1TargetPoseID: "hands_up"),

        // — + 더 보기 9 페이지 (v1.5) —
        // v1.5: 안전한 head/arm 단발 자세만 활성. get-up 류 (10/11) 는 chain 이 필요해서
        // 단일 pose 로 열면 fall risk → nil 유지 (v1.6 motion_play 추출 후 활성).
        // Codex 2차 권고 (2026-05-13): 단발 자세는 끄덕임/가로젓기로 인지되기
        // 어려움. (단발) 마커 명시 + duration 도 단발 기준으로 낮춤 (원본 chain
        // 2600ms 는 사용자에게 잘못된 기대 — progress ring 시간 + 토스트 timing
        // 둘 다 영향). chain 기반 모션은 v1.6 motion_play 추출 후.
        .init(slot: 2, rawName: "ok",
              displayName: "Yes (single-step)", displayNameKo: "고개 숙이기 (단발)",
              safetyClass: .safe, durationMs: 800,
              mp3Sync: "Yes.mp3", bodyRegions: [.head],
              icon: "arrow.down.circle",
              v1TargetPoseID: "nod_target"),
        .init(slot: 3, rawName: "no",
              displayName: "No (single-step)", displayNameKo: "고개 돌리기 (단발)",
              safetyClass: .safe, durationMs: 800,
              mp3Sync: "No.mp3", bodyRegions: [.head],
              icon: "arrow.right.circle",
              v1TargetPoseID: "shake_target"),
        // 사이클 143 (IMPLEMENTATION audit #7): [placeholder] 명시 — 현재 합성은 walkReady hold.
        .init(slot: 10, rawName: "f up",
              displayName: "[placeholder] Get Up Front", displayNameKo: "[placeholder] 앞 일어서기",
              safetyClass: .caution, durationMs: 3200,
              mp3Sync: nil,
              bodyRegions: [.rightArm, .leftArm, .rightLeg, .leftLeg],
              icon: "figure.stand",
              v1TargetPoseID: nil),     // v1.6 — multi-step chain 필요 (낙상 자세 → 무릎 → 직립)
        // 사이클 143 (IMPLEMENTATION audit #7): [placeholder] 명시.
        .init(slot: 11, rawName: "b up",
              displayName: "[placeholder] Get Up Back", displayNameKo: "[placeholder] 뒤 일어서기",
              safetyClass: .caution, durationMs: 4200,
              mp3Sync: nil,
              bodyRegions: [.rightArm, .leftArm, .rightLeg, .leftLeg],
              icon: "figure.stand",
              v1TargetPoseID: nil),     // v1.6 — 동일
        .init(slot: 16, rawName: "stand up",
              displayName: "Stand Up Exact", displayNameKo: "일어서기",
              safetyClass: .safe, durationMs: 1000, mp3Sync: nil,
              bodyRegions: [.rightLeg, .leftLeg], icon: "arrow.up",
              v1TargetPoseID: "idle"),
        // chain page (next=25) — 공식 chain duration 8192ms vs v1 single-pose 3600ms.
        .init(slot: 24, rawName: "d2",
              displayName: "Wow", displayNameKo: "감탄",
              safetyClass: .safe, durationMs: 3600,
              rawChainDurationMs: 8192,    // Codex audit P1-5: 24 → 25 chain 총 8192ms
              mp3Sync: "Wow.mp3",
              bodyRegions: [.rightArm, .leftArm, .head], icon: "sparkles",
              v1TargetPoseID: "surprise"),
        .init(slot: 27, rawName: "d3",
              displayName: "Oops", displayNameKo: "실수",
              safetyClass: .safe, durationMs: 3200, rawChainDurationMs: nil, mp3Sync: nil,
              bodyRegions: [.head, .rightArm], icon: "face.dashed",
              v1TargetPoseID: "shy"),
        // Phase G5 (Codex audit P1-5): 공식 bin 의 page 38 name 은 "d2" (정량 검증).
        // 이전엔 "d2 bye" 였는데 라벨 가공 — 공식 raw name 그대로 보존.
        .init(slot: 38, rawName: "d2",
              displayName: "Bye Bye", displayNameKo: "손 흔들기",
              safetyClass: .safe, durationMs: 3600,
              rawChainDurationMs: 7696,    // Codex audit P1-5: 38 → 39 chain 7696ms
              mp3Sync: nil,
              bodyRegions: [.rightArm], icon: "hand.wave.fill",
              v1TargetPoseID: "wave_right"),
        .init(slot: 54, rawName: "int",
              displayName: "Clap Please", displayNameKo: "박수 요청",
              safetyClass: .safe, durationMs: 2000,
              rawChainDurationMs: 8296,    // Codex audit P1-5: 54 → 55 → 56 → 58 chain 8296ms
              mp3Sync: nil,
              bodyRegions: [.rightArm, .leftArm], icon: "hands.sparkles",
              v1TargetPoseID: "clap_ready"),
    ]

    /// 슬롯 ID 로 메타데이터 조회.
    public static func find(slot: UInt8) -> MotionPageMetadata? {
        all.first(where: { $0.slot == slot })
    }

    /// Action Bar 메인에 그릴 7 페이지 (순서 보존).
    public static var actionBarMain: [MotionPageMetadata] {
        actionBarMainSlots.compactMap { find(slot: $0) }
    }

    /// "+ 더 보기" 9 페이지 (순서 보존).
    public static var actionBarMore: [MotionPageMetadata] {
        actionBarMoreSlots.compactMap { find(slot: $0) }
    }

    /// v1.0 에서 실제 모터 송출 가능한 슬롯인지 — `v1TargetPoseID` 가 있어야 함.
    public static func isV1Sendable(slot: UInt8) -> Bool {
        find(slot: slot)?.v1TargetPoseID != nil
    }
}
