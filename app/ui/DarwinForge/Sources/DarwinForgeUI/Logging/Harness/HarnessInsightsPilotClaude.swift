import Foundation

// MARK: - Pilot / Setup / Claude / Joint / Remote / System error insight rules
//
// HarnessInsights 도메인별 분리 (cycle 227).
// 원본 HarnessInsights.swift 에서 pilot / setup / claude / joint / remote 관련 룰 추출.

extension HarnessInsights {

    // MARK: - Pilot adapter (cycle 215)

    /// 음성 인식 오류가 세션 내에서 3회 이상이면 HW/설정 문제 의심.
    static func pilotVoiceErrorInsight(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let voiceErrors = events.filter { $0.k.rawValue == TelemetryKind.pilotVoiceError.rawValue }
        guard voiceErrors.count >= 3 else { return [] }
        return [Insight(
            id: "pilot.voice_error_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "pilot.voice_error_chain",
            severity: .warn, kind: .pilot,
            title: "음성 인식 오류 \(voiceErrors.count) 회",
            evidence: "세션 중 \(voiceErrors.count) 회 voice_error 발생. 마이크 권한/HW 확인 필요.",
            recommendation: "시스템 환경 설정 > 개인정보 > 마이크 권한 확인. 외부 마이크 연결 상태 점검.",
            eventRefs: Array(voiceErrors.prefix(5).map(\.i)),
            confidence: 0.75
        )]
    }

    /// 키워드 인식률 (match/miss ratio) 가 30% 미만이면 환경 소음 의심.
    static func pilotVoiceMissRatioInsight(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let keywords = events.filter { $0.k.rawValue == TelemetryKind.pilotVoiceKeyword.rawValue }
        guard keywords.count >= 10 else { return [] }
        let matched = keywords.filter {
            ($0.d.raw["matched"])?.value as? Bool == true
        }.count
        let ratio = Double(matched) / Double(keywords.count)
        guard ratio < 0.3 else { return [] }
        return [Insight(
            id: "pilot.voice_low_match#\(a.summary.firstEventAt ?? "")",
            ruleID: "pilot.voice_low_match_rate",
            severity: .notice, kind: .pilot,
            title: "음성 키워드 매칭률 \(percent(ratio)) — 환경 소음 의심",
            evidence: "\(keywords.count) 건 인식 중 \(matched) 건만 매칭. 비율 \(percent(ratio)).",
            recommendation: "주변 소음 줄이거나 마이크 가까이 발화. 키워드 목록 확인 (걸어/멈춰/비상).",
            eventRefs: [],
            confidence: 0.65
        )]
    }

    // MARK: - Connection wizard (cycle 218)

    /// setup.conn_oneclick_all_failed 가 3회 이상이면 사용자가 연결에 어려움을 겪는 것.
    static func setupConnRepeatedFailure(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let failures = events.filter { $0.k.rawValue == TelemetryKind.setupConnOneClickAllFailed.rawValue }
        guard failures.count >= 3 else { return [] }
        return [Insight(
            id: "setup.conn_repeated_failure#\(a.summary.firstEventAt ?? "")",
            ruleID: "setup.conn_repeated_failure",
            severity: .warn, kind: .connection,
            title: "OneClick 전체 실패 \(failures.count)회 — 연결 환경 문제 의심",
            evidence: "세션 중 setup.conn_oneclick_all_failed 가 \(failures.count) 회 발생. 모든 후보 unreachable.",
            recommendation: "USB 케이블 / 포트 확인. 네트워크 endpoint 면 socat / IP / 방화벽 점검. 수동 경로 시도 권장.",
            eventRefs: failures.prefix(5).map(\.i),
            confidence: 0.8
        )]
    }

    /// setup.conn_wizard_started 가 5회 이상이면 연결 불안정으로 마법사를 반복 진입.
    static func setupConnWizardFrequency(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let starts = events.filter { $0.k.rawValue == TelemetryKind.setupConnWizardStarted.rawValue }
        guard starts.count >= 5 else { return [] }
        return [Insight(
            id: "setup.conn_wizard_frequency#\(a.summary.firstEventAt ?? "")",
            ruleID: "setup.conn_wizard_frequency",
            severity: .notice, kind: .connection,
            title: "연결 마법사 \(starts.count)회 진입 — 연결 불안정 의심",
            evidence: "세션 중 setup.conn_wizard_started 가 \(starts.count) 회. 연결이 끊어져 반복 재시도 가능성.",
            recommendation: "연결 환경 안정화 후 사용 권장. USB 또는 네트워크 경로 고정 설정 검토.",
            eventRefs: starts.prefix(5).map(\.i),
            confidence: 0.6
        )]
    }

    // MARK: - Pilot safety / action bar (cycle 225)

    /// ARM 하지 않고 모션 시도 반복 — safety_gate_blocked ≥5.
    static func pilotSafetyGateBlockedFrequent(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let blocked = events.filter { $0.k.rawValue == TelemetryKind.pilotSafetyGateBlocked.rawValue }
        let count = blocked.count
        guard count >= 5 else { return [] }
        return [Insight(
            id: "pilot.safety_gate_blocked_frequent#\(a.summary.firstEventAt ?? "")",
            ruleID: "pilot.safety_gate_blocked_frequent",
            severity: .notice, kind: .pilot,
            title: "안전 게이트 차단 \(count)회 — ARM 필요",
            evidence: "세션 중 pilot.safety_gate_blocked \(count)회. ARM 하지 않고 모션 시도 반복.",
            recommendation: "Drag-to-ARM 조작 숙지 필요. ARM 상태에서만 모션 송출 가능.",
            eventRefs: Array(blocked.prefix(5).map(\.i)),
            confidence: 0.7
        )]
    }

    /// HighRisk 확인 대화상자 취소 반복 — action_bar_risk_cancelled ≥3.
    static func pilotActionBarRiskCancelFrequent(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let cancelled = events.filter { $0.k.rawValue == TelemetryKind.pilotActionBarRiskCancelled.rawValue }
        let count = cancelled.count
        guard count >= 3 else { return [] }
        return [Insight(
            id: "pilot.action_bar_risk_cancel_frequent#\(a.summary.firstEventAt ?? "")",
            ruleID: "pilot.action_bar_risk_cancel_frequent",
            severity: .notice, kind: .pilot,
            title: "위험 모션 취소 반복 \(count)회",
            evidence: "HighRisk 확인 대화상자에서 \(count)회 취소. 의도치 않은 위험 모션 접근 패턴.",
            recommendation: "Action Bar 슬롯 배치 재검토. 위험 모션을 자주 취소하면 슬롯에서 제거 권장.",
            eventRefs: Array(cancelled.prefix(5).map(\.i)),
            confidence: 0.65
        )]
    }

    // MARK: - Claude intent (cycle 225)

    /// Claude 도구 dispatch 에러 반복 — intent_error ≥3.
    static func claudeIntentErrorPattern(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let errors = events.filter { $0.k.rawValue == TelemetryKind.claudeIntentError.rawValue }
        let count = errors.count
        guard count >= 3 else { return [] }
        return [Insight(
            id: "claude.intent_error_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "claude.intent_error_pattern",
            severity: .warn, kind: .claude,
            title: "Claude 도구 dispatch 에러 \(count)회",
            evidence: "세션 중 claude.intent_error \(count)회. AI 도구 실행 실패 반복.",
            recommendation: "연결 상태 확인. Claude 응답 내 tool 이름 / 인자 오류 가능성. 대화 초기화 시도.",
            eventRefs: Array(errors.prefix(5).map(\.i)),
            confidence: 0.75
        )]
    }

    // MARK: - Pilot demo mode (cycle 225)

    /// 데모 모드 전환 실패 반복 — demo_mode_result(success=false) ≥2.
    static func pilotDemoModeFailure(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let failures = events.filter {
            $0.k.rawValue == TelemetryKind.pilotDemoModeResult.rawValue
                && ($0.d.raw["success"]?.value as? Bool) == false
        }
        let count = failures.count
        guard count >= 2 else { return [] }
        return [Insight(
            id: "pilot.demo_mode_failure#\(a.summary.firstEventAt ?? "")",
            ruleID: "pilot.demo_mode_failure",
            severity: .warn, kind: .pilot,
            title: "데모 모드 전환 실패 \(count)회",
            evidence: "pilot.demo_mode_result(success=false) \(count)회. 모드 전환 중 에러 반복.",
            recommendation: "로봇 연결 상태 확인. ball-follow 전환 시 카메라 / HSV 설정 점검.",
            eventRefs: Array(failures.prefix(5).map(\.i)),
            confidence: 0.75
        )]
    }

    // MARK: - Claude errors (cycle 226)

    /// Claude API 에러 반복 — claude.error ≥3.
    static func claudeErrorPattern(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let errors = events.filter { $0.k.rawValue == TelemetryKind.claudeError.rawValue }
        let count = errors.count
        guard count >= 3 else { return [] }
        return [Insight(
            id: "claude.error_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "claude.error_pattern",
            severity: .warn, kind: .claude,
            title: "Claude API 에러 \(count)회",
            evidence: "세션 중 claude.error \(count)회. LLM 응답 실패 반복.",
            recommendation: "네트워크 연결 확인. API 키 유효성 점검. 대화 초기화 후 재시도.",
            eventRefs: Array(errors.prefix(5).map(\.i)),
            confidence: 0.8
        )]
    }

    /// Claude plan execution 실패 반복 — plan_execution_failed ≥2.
    static func claudePlanExecFailPattern(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let failures = events.filter { $0.k.rawValue == TelemetryKind.claudePlanExecutionFailed.rawValue }
        let count = failures.count
        guard count >= 2 else { return [] }
        return [Insight(
            id: "claude.plan_exec_fail_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "claude.plan_exec_fail_pattern",
            severity: .warn, kind: .claude,
            title: "Claude plan 실행 실패 \(count)회",
            evidence: "세션 중 claude.plan_execution_failed \(count)회. 도구 dispatch 실패 반복.",
            recommendation: "로봇 연결 상태 확인. plan 에 사용된 도구가 현재 상태에서 실행 가능한지 점검.",
            eventRefs: Array(failures.prefix(5).map(\.i)),
            confidence: 0.75
        )]
    }

    // MARK: - Joint / Remote / System errors (cycle 226)

    /// Joint action 실패 반복 — joint.action_failed ≥3.
    static func jointActionFailedPattern(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let failures = events.filter { $0.k.rawValue == TelemetryKind.jointActionFailed.rawValue }
        let count = failures.count
        guard count >= 3 else { return [] }
        return [Insight(
            id: "joint.action_failed_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "joint.action_failed_pattern",
            severity: .warn, kind: .motion,
            title: "관절 제어 에러 \(count)회",
            evidence: "세션 중 joint.action_failed \(count)회. 특정 motor 통신 또는 torque 오류 반복.",
            recommendation: "해당 motor ID 의 power / 케이블 / Dynamixel firmware 상태 확인.",
            eventRefs: Array(failures.prefix(5).map(\.i)),
            confidence: 0.8
        )]
    }

    /// Remote command 에러 반복 — remote.command_error ≥3.
    static func remoteCommandErrorPattern(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let errors = events.filter { $0.k.rawValue == TelemetryKind.remoteCommandError.rawValue }
        let count = errors.count
        guard count >= 3 else { return [] }
        return [Insight(
            id: "remote.command_error_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "remote.command_error_pattern",
            severity: .warn, kind: .remote,
            title: "원격 명령 에러 \(count)회",
            evidence: "세션 중 remote.command_error \(count)회. SSH/SMB 명령 실행 반복 실패.",
            recommendation: "SSH 연결 상태 / 호스트 접근성 확인. 타임아웃 설정 조정 필요할 수 있음.",
            eventRefs: Array(errors.prefix(5).map(\.i)),
            confidence: 0.75
        )]
    }

    /// 예외 발생 — error.exception ≥1 (즉시 진단 필요).
    static func errorExceptionPattern(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let exceptions = events.filter { $0.k.rawValue == TelemetryKind.errorException.rawValue }
        let count = exceptions.count
        guard count >= 1 else { return [] }
        return [Insight(
            id: "error.exception_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "error.exception_pattern",
            severity: count >= 3 ? .critical : .warn, kind: .harness,
            title: "예외 \(count)건 발생",
            evidence: "세션 중 error.exception \(count)건. 예상치 못한 오류 — 스택 확인 필요.",
            recommendation: "Inspector 에서 해당 이벤트의 error_hash / source 확인. 반복 시 앱 재시작 권장.",
            eventRefs: Array(exceptions.prefix(5).map(\.i)),
            confidence: 0.95
        )]
    }
}
