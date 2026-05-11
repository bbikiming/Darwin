//  SynthModel.swift — Sprint 11 ViewModel.
//
//  Synth Palette 의 상태 관리. 카탈로그 페이지 목록 + 합성 캔버스 + validator
//  결과 + 결과 페이지 경로를 보관.

import Foundation
import SwiftUI

/// 카탈로그 페이지 — Synth Palette UI 의 카드 모델.
public struct SynthCatalogEntry: Identifiable, Equatable {
    public let id: Int
    public let displayName: String
    public let rawName: String
    public let safetyClass: String  // "Safe" | "Caution" | "HighRisk"
    public let tags: [String]
    public let stepCount: Int

    public init(id: Int, displayName: String, rawName: String, safetyClass: String, tags: [String], stepCount: Int) {
        self.id = id
        self.displayName = displayName
        self.rawName = rawName
        self.safetyClass = safetyClass
        self.tags = tags
        self.stepCount = stepCount
    }
}

/// Synth 캔버스 항목 — 사용자가 드래그한 페이지.
public struct SynthCanvasItem: Identifiable, Equatable {
    public let id: UUID = UUID()
    public let entry: SynthCatalogEntry

    public init(entry: SynthCatalogEntry) {
        self.entry = entry
    }
}

/// 합성 연산자.
public enum SynthOperator: String, CaseIterable, Identifiable {
    case sequence
    case layer
    case morph
    case mutate
    case mirror
    case procedural

    public var id: String { rawValue }

    public var korean: String {
        switch self {
        case .sequence:   return "시퀀스 (순차 연결)"
        case .layer:      return "레이어 (부위별 합성)"
        case .morph:      return "모프 (두 페이지 보간)"
        case .mutate:     return "변형 (시간/속도/진폭)"
        case .mirror:     return "미러 (좌우 반전)"
        case .procedural: return "절차적 (anchor 사이 곡선)"
        }
    }
}

/// Validator 결과 — UI 표시용.
public struct SynthValidatorOutcome: Equatable {
    public enum Status: Equatable { case pass, warn, fail }
    public let stage: String   // "JointLimit" / "Velocity" / "SelfCollision" / "StaticStability"
    public let status: Status
    public let message: String

    public init(stage: String, status: Status, message: String) {
        self.stage = stage
        self.status = status
        self.message = message
    }
}

/// Synth Palette 상태 — ObservableObject.
@MainActor
public final class SynthModel: ObservableObject {
    @Published public var catalog: [SynthCatalogEntry] = []
    @Published public var canvas: [SynthCanvasItem] = []
    @Published public var selectedOperator: SynthOperator = .sequence
    @Published public var transitionMs: Double = 800
    @Published public var timeScale: Double = 1.0
    @Published public var resultJSON: String? = nil
    @Published public var resultPagePath: String? = nil
    @Published public var validatorResults: [SynthValidatorOutcome] = []
    @Published public var isLoading: Bool = false
    @Published public var lastError: String? = nil

    /// 데모용 fallback 카탈로그 — bridge 호출 실패 시 사용.
    public static let officialCatalogFallback: [SynthCatalogEntry] = [
        SynthCatalogEntry(id: 1,  displayName: "Stand Up",      rawName: "init",       safetyClass: "Safe",     tags: ["pose","anchor"], stepCount: 2),
        SynthCatalogEntry(id: 2,  displayName: "Yes",            rawName: "ok",         safetyClass: "Safe",     tags: ["gesture"], stepCount: 5),
        SynthCatalogEntry(id: 3,  displayName: "No",             rawName: "no",         safetyClass: "Safe",     tags: ["gesture"], stepCount: 5),
        SynthCatalogEntry(id: 4,  displayName: "Thank You",      rawName: "hi",         safetyClass: "Safe",     tags: ["gesture","greeting"], stepCount: 4),
        SynthCatalogEntry(id: 9,  displayName: "Walk Ready",     rawName: "walkready",  safetyClass: "Safe",     tags: ["pose","anchor","locomotion"], stepCount: 1),
        SynthCatalogEntry(id: 10, displayName: "Get Up (Front)", rawName: "f up",       safetyClass: "Caution",  tags: ["recovery","balance_critical"], stepCount: 5),
        SynthCatalogEntry(id: 11, displayName: "Get Up (Back)",  rawName: "b up",       safetyClass: "Caution",  tags: ["recovery","balance_critical"], stepCount: 6),
        SynthCatalogEntry(id: 12, displayName: "Right Kick",     rawName: "rk",         safetyClass: "HighRisk", tags: ["kick","balance_critical"], stepCount: 7),
        SynthCatalogEntry(id: 13, displayName: "Left Kick",      rawName: "lk",         safetyClass: "HighRisk", tags: ["kick","balance_critical"], stepCount: 7),
        SynthCatalogEntry(id: 15, displayName: "Sit Down",       rawName: "sit down",   safetyClass: "Safe",     tags: ["posture","idle"], stepCount: 1),
        SynthCatalogEntry(id: 17, displayName: "Hand Standing",  rawName: "mul1",       safetyClass: "HighRisk", tags: ["acrobatics","balance_critical"], stepCount: 7),
        SynthCatalogEntry(id: 23, displayName: "Yes Go!",        rawName: "d1",         safetyClass: "Safe",     tags: ["gesture"], stepCount: 4),
        SynthCatalogEntry(id: 24, displayName: "Wow!",            rawName: "d2",         safetyClass: "Safe",     tags: ["gesture"], stepCount: 5),
        SynthCatalogEntry(id: 27, displayName: "Oops",           rawName: "d3",         safetyClass: "Safe",     tags: ["gesture"], stepCount: 5),
        SynthCatalogEntry(id: 38, displayName: "Bye Bye",        rawName: "d2",         safetyClass: "Safe",     tags: ["gesture","greeting"], stepCount: 5),
        SynthCatalogEntry(id: 54, displayName: "Clap Please",    rawName: "int",        safetyClass: "Safe",     tags: ["gesture"], stepCount: 2),
    ]

    public init() {
        // 초기 fallback. 실 bridge 호출은 view onAppear 에서.
        catalog = Self.officialCatalogFallback
    }

    /// 페이지를 캔버스에 추가.
    public func addToCanvas(_ entry: SynthCatalogEntry) {
        canvas.append(SynthCanvasItem(entry: entry))
    }

    /// 캔버스 비우기.
    public func clearCanvas() {
        canvas.removeAll()
        resultJSON = nil
        resultPagePath = nil
        validatorResults.removeAll()
    }

    /// 색상 — safety class 기반.
    public static func color(for safety: String) -> Color {
        switch safety {
        case "Safe":      return .green
        case "Caution":   return .orange
        case "HighRisk":  return .red
        default:           return .gray
        }
    }
}
