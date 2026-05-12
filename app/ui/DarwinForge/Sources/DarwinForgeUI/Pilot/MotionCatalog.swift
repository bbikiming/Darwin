import ForgeCore
import Foundation

/// `motion_4096.bin` 페이지 → UI 메타데이터 매핑.
///
/// Sprint 15 Remote Pilot v1.0 — Action Bar 의 7 메인 페이지 + 9 추가 페이지(v1.5).
/// 모션 데이터 자체는 `docs/motion-format/page-metadata-motion4096.toml` 의 sidecar 와
/// `motion_4096.bin` 의 byte-identical 페이지. 본 catalog 는 UI 매핑만 담당.
///
/// **현재(v1.0) 구현 메모**: forge-core 의 motion_4096.bin 페이지 step 디코더 +
/// SYNC_WRITE goal_position 송출 경로가 아직 없다 (별도 PR — Sprint 15 Day 1-2).
/// 따라서 v1.0 에서는 각 motion slot 을 **canonical target pose** (PoseLibrary 의
/// 검증된 자세) 로 매핑하고, ConnectionStore.applyPoseSmoothly(_:) 의 검증된
/// 안전 경로 (voltage / load / limit / split) 로 송출한다. 모션의 시간 곡선
/// (4-step bow 등)이 아닌 **최종 자세 도달** 만 보장. v1.5 에서 raw step 송출 가능.
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
    /// 예상 지속 시간 (ms).
    public let durationMs: UInt32
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
              mp3Sync: "Left kick.mp3",
              bodyRegions: [.leftLeg],
              icon: "figure.kickboxing",
              v1TargetPoseID: nil), // PoseLibrary 에 mirror 자세 없음 — v1.5 에서 raw step
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
        .init(slot: 2, rawName: "ok",
              displayName: "Yes", displayNameKo: "끄덕임",
              safetyClass: .safe, durationMs: 2600,
              mp3Sync: "Yes.mp3", bodyRegions: [.head],
              icon: "checkmark.circle",
              v1TargetPoseID: nil),
        .init(slot: 3, rawName: "no",
              displayName: "No", displayNameKo: "가로젓기",
              safetyClass: .safe, durationMs: 2600,
              mp3Sync: "No.mp3", bodyRegions: [.head],
              icon: "xmark.circle",
              v1TargetPoseID: nil),
        .init(slot: 10, rawName: "f up",
              displayName: "Get Up Front", displayNameKo: "앞 일어서기",
              safetyClass: .caution, durationMs: 3200,
              mp3Sync: nil,
              bodyRegions: [.rightArm, .leftArm, .rightLeg, .leftLeg],
              icon: "figure.stand",
              v1TargetPoseID: nil),
        .init(slot: 11, rawName: "b up",
              displayName: "Get Up Back", displayNameKo: "뒤 일어서기",
              safetyClass: .caution, durationMs: 4200,
              mp3Sync: nil,
              bodyRegions: [.rightArm, .leftArm, .rightLeg, .leftLeg],
              icon: "figure.stand",
              v1TargetPoseID: nil),
        .init(slot: 16, rawName: "stand up",
              displayName: "Stand Up Exact", displayNameKo: "일어서기",
              safetyClass: .safe, durationMs: 1000, mp3Sync: nil,
              bodyRegions: [.rightLeg, .leftLeg], icon: "arrow.up",
              v1TargetPoseID: "idle"),
        .init(slot: 24, rawName: "d2",
              displayName: "Wow", displayNameKo: "감탄",
              safetyClass: .safe, durationMs: 3600, mp3Sync: "Wow.mp3",
              bodyRegions: [.rightArm, .leftArm, .head], icon: "sparkles",
              v1TargetPoseID: nil),
        .init(slot: 27, rawName: "d3",
              displayName: "Oops", displayNameKo: "실수",
              safetyClass: .safe, durationMs: 3200, mp3Sync: nil,
              bodyRegions: [.head, .rightArm], icon: "face.dashed",
              v1TargetPoseID: nil),
        .init(slot: 38, rawName: "d2 bye",
              displayName: "Bye Bye", displayNameKo: "손 흔들기",
              safetyClass: .safe, durationMs: 3600, mp3Sync: nil,
              bodyRegions: [.rightArm], icon: "hand.wave.fill",
              v1TargetPoseID: "wave_right"),
        .init(slot: 54, rawName: "int",
              displayName: "Clap Please", displayNameKo: "박수 요청",
              safetyClass: .safe, durationMs: 2000, mp3Sync: nil,
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
