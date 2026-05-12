import Foundation

/// motion_4096.bin 페이지 안전 분류 — Rust SafetyClass 와 1:1.
public enum MotionSafetyClass: String, Codable, Sendable {
    case safe = "Safe"
    case caution = "Caution"
    case highRisk = "HighRisk"
}

/// 한 모션 페이지의 sidecar 메타데이터.
/// 출처: docs/motion-format/page-metadata-motion4096.toml
public struct MotionPageMetadata: Identifiable, Sendable {
    public let id: UInt8           // motion_4096.bin 슬롯 번호
    public let rawName: String     // PAGEHEADER name[14]
    public let displayName: String // 영문 표시명
    public let displayNameKo: String
    public let safetyClass: MotionSafetyClass
    public let durationMs: UInt32
    public let mp3Sync: String?
    public let bodyRegions: [String]
    public let singleFootOk: Bool
}

/// v1.0 Action Bar 슬롯 순서 (7개).
public let actionBarMain: [UInt8] = [1, 4, 15, 12, 13, 9, 23]

/// v1.5 추가 슬롯 (+ 더 보기, 9개).
public let actionBarMore: [UInt8] = [2, 3, 10, 11, 16, 24, 27, 38, 54]

/// motion_4096.bin 공식 카탈로그 — 16 페이지 sidecar hardcode.
/// 출처: docs/motion-format/page-metadata-motion4096.toml + gui_motion.yaml
public enum MotionCatalog {
    public static let all: [MotionPageMetadata] = [
        MotionPageMetadata(
            id: 1, rawName: "init",
            displayName: "Stand Up", displayNameKo: "기본 자세",
            safetyClass: .safe, durationMs: 2000, mp3Sync: nil,
            bodyRegions: ["UpperBody", "LowerBody", "Head"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 2, rawName: "ok",
            displayName: "Yes", displayNameKo: "끄덕임",
            safetyClass: .safe, durationMs: 2600, mp3Sync: "Yes.mp3",
            bodyRegions: ["Head"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 3, rawName: "no",
            displayName: "No", displayNameKo: "가로젓기",
            safetyClass: .safe, durationMs: 2600, mp3Sync: "No.mp3",
            bodyRegions: ["Head"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 4, rawName: "hi",
            displayName: "Thank You", displayNameKo: "감사 인사",
            safetyClass: .safe, durationMs: 3600, mp3Sync: "Thank you.mp3",
            bodyRegions: ["UpperBody", "Head"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 9, rawName: "walkready",
            displayName: "Walk Ready", displayNameKo: "보행 자세",
            safetyClass: .safe, durationMs: 1000, mp3Sync: nil,
            bodyRegions: ["LowerBody", "Head"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 10, rawName: "f up",
            displayName: "Get Up (Front)", displayNameKo: "앞 일어서기",
            safetyClass: .caution, durationMs: 3200, mp3Sync: nil,
            bodyRegions: ["UpperBody", "LowerBody"], singleFootOk: false
        ),
        MotionPageMetadata(
            id: 11, rawName: "b up",
            displayName: "Get Up (Back)", displayNameKo: "뒤 일어서기",
            safetyClass: .caution, durationMs: 4200, mp3Sync: nil,
            bodyRegions: ["UpperBody", "LowerBody"], singleFootOk: false
        ),
        MotionPageMetadata(
            id: 12, rawName: "rk",
            displayName: "Right Kick", displayNameKo: "오른발 차기",
            safetyClass: .highRisk, durationMs: 1664, mp3Sync: nil,
            bodyRegions: ["LowerBody"], singleFootOk: false
        ),
        MotionPageMetadata(
            id: 13, rawName: "lk",
            displayName: "Left Kick", displayNameKo: "왼발 차기",
            safetyClass: .highRisk, durationMs: 1664, mp3Sync: nil,
            bodyRegions: ["LowerBody"], singleFootOk: false
        ),
        MotionPageMetadata(
            id: 15, rawName: "sit down",
            displayName: "Sit Down", displayNameKo: "앉기",
            safetyClass: .safe, durationMs: 1000, mp3Sync: "Sit down.mp3",
            bodyRegions: ["UpperBody", "LowerBody"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 16, rawName: "standup",
            displayName: "Stand Up (Alt)", displayNameKo: "일어서기",
            safetyClass: .safe, durationMs: 2000, mp3Sync: nil,
            bodyRegions: ["UpperBody", "LowerBody"], singleFootOk: false
        ),
        MotionPageMetadata(
            id: 23, rawName: "d1",
            displayName: "Yes Go!", displayNameKo: "출발!",
            safetyClass: .safe, durationMs: 3000, mp3Sync: "Yes go.mp3",
            bodyRegions: ["UpperBody"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 24, rawName: "d2",
            displayName: "Wow!", displayNameKo: "감탄",
            safetyClass: .safe, durationMs: 3600, mp3Sync: nil,
            bodyRegions: ["UpperBody", "Head"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 27, rawName: "d3",
            displayName: "Oops", displayNameKo: "실수",
            safetyClass: .safe, durationMs: 3200, mp3Sync: nil,
            bodyRegions: ["UpperBody", "Head"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 38, rawName: "d2",
            displayName: "Bye Bye", displayNameKo: "손 흔들기",
            safetyClass: .safe, durationMs: 3600, mp3Sync: nil,
            bodyRegions: ["UpperBody"], singleFootOk: true
        ),
        MotionPageMetadata(
            id: 54, rawName: "int",
            displayName: "Clap Please", displayNameKo: "박수 요청",
            safetyClass: .safe, durationMs: 2000, mp3Sync: nil,
            bodyRegions: ["UpperBody"], singleFootOk: true
        ),
    ]

    public static func find(slot: UInt8) -> MotionPageMetadata? {
        all.first { $0.id == slot }
    }
}
