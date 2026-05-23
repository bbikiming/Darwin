import Foundation

// MARK: - HarnessInsights (v1.14.0, 2026-05-20)
//
// 룰 기반 패턴 검출. `SessionAnalysis` 를 입력으로 받아 [Insight] 반환. Pure 함수 —
// XCTest 에서 fixture 로 단위 검증.
//
// 자세한 설계: docs/harness/log-utilization-system.md

public struct Insight: Sendable, Equatable, Identifiable {
    public let id: String
    public let ruleID: String
    public let severity: Severity
    public let kind: Kind
    public let title: String
    public let evidence: String
    public let recommendation: String
    /// 관련 이벤트 seq 번호 — Inspector 가 점프할 때 사용.
    public let eventRefs: [UInt64]
    /// 0..1 — 1 = 결정적 (산술 임계), 0.5 = 휴리스틱.
    public let confidence: Double

    public enum Severity: String, Codable, Sendable {
        case info, notice, warn, critical
    }
    public enum Kind: String, Codable, Sendable {
        case connection, imu, bus, walklab, pose, harness, idle, motion, pilot
        case setup, remote, claude
    }
}

public enum HarnessInsights {
    /// `SessionAnalysis` 한 개로부터 단일 세션 인사이트.
    /// `events` 를 별도로 받는 이유: timeline 내부 카운트만으론 추적 불가능한 케이스 (chain 연쇄 등) 가 있어 raw 이벤트가 필요.
    public static func compute(analysis: SessionAnalysis,
                                events: [TelemetryEvent]) -> [Insight] {
        var out: [Insight] = []
        out.append(contentsOf: connectionRules(analysis, events))
        out.append(contentsOf: reconnectRule(analysis, events))      // v1.14.2
        out.append(contentsOf: rttRules(analysis))
        out.append(contentsOf: imuRules(analysis))
        out.append(contentsOf: imuFlappingRule(analysis, events))    // v1.14.2
        out.append(contentsOf: busRules(analysis, events))
        out.append(contentsOf: busFlappingRule(analysis, events))    // v1.14.2
        out.append(contentsOf: walkLabRules(analysis, events))
        out.append(contentsOf: poseRules(analysis, events))
        out.append(contentsOf: harnessRules(analysis))
        out.append(contentsOf: idleRules(analysis, events))
        out.append(contentsOf: pilotVoiceErrorInsight(analysis, events))    // v1.20.8 cycle 215
        out.append(contentsOf: pilotVoiceMissRatioInsight(analysis, events))
        out.append(contentsOf: setupConnRepeatedFailure(analysis, events))  // cycle 218
        out.append(contentsOf: setupConnWizardFrequency(analysis, events))  // cycle 218
        out.append(contentsOf: pilotSafetyGateBlockedFrequent(analysis, events))   // cycle 225
        out.append(contentsOf: pilotActionBarRiskCancelFrequent(analysis, events)) // cycle 225
        out.append(contentsOf: claudeIntentErrorPattern(analysis, events))         // cycle 225
        out.append(contentsOf: walklabDiagnosticsExportFailure(analysis, events))  // cycle 225
        out.append(contentsOf: walklabBalanceRiskyPattern(analysis, events))       // cycle 225
        out.append(contentsOf: walklabCalibrationIncomplete(analysis, events))     // cycle 225
        out.append(contentsOf: pilotDemoModeFailure(analysis, events))             // cycle 225
        out.append(contentsOf: walklabDataDeletionFrequent(analysis, events))      // cycle 225
        out.append(contentsOf: claudeErrorPattern(analysis, events))               // cycle 226
        out.append(contentsOf: claudePlanExecFailPattern(analysis, events))        // cycle 226
        out.append(contentsOf: jointActionFailedPattern(analysis, events))         // cycle 226
        out.append(contentsOf: remoteCommandErrorPattern(analysis, events))        // cycle 226
        out.append(contentsOf: errorExceptionPattern(analysis, events))            // cycle 226
        out.append(contentsOf: busWriteFailStorm(analysis, events))                // cycle 226
        return out
    }

    // MARK: - Connection

    private static func connectionRules(_ a: SessionAnalysis,
                                          _ events: [TelemetryEvent]) -> [Insight] {
        var out: [Insight] = []
        let attempts = a.summary.connectAttempts
        let failures = a.summary.connectFailures
        if attempts >= 3, Double(failures) / Double(attempts) >= 0.4 {
            out.append(Insight(
                id: "connection.high_failure_rate#\(a.summary.firstEventAt ?? "")",
                ruleID: "connection.high_failure_rate",
                severity: .warn, kind: .connection,
                title: "연결 실패율이 높습니다 (\(failures)/\(attempts))",
                evidence: "총 \(attempts) 시도 중 \(failures) 실패 — \(percent(Double(failures)/Double(attempts)))",
                recommendation: "USB 케이블 / 드라이버 / 전원 어댑터 점검. 네트워크 endpoint 면 socat / IP 확인.",
                eventRefs: events.filter { $0.k.rawValue == "connection.failure" }.map(\.i),
                confidence: 0.95
            ))
        }

        // Flapping — 60초 윈도우 내 disconnect ↔ success ≥ 3 cycle.
        let cycles = countFlappingCycles(events: events, windowSeconds: 60)
        if cycles >= 3 {
            out.append(Insight(
                id: "connection.flapping#\(a.summary.firstEventAt ?? "")",
                ruleID: "connection.flapping",
                severity: .warn, kind: .connection,
                title: "연결이 자주 끊어졌다 다시 붙습니다 (\(cycles) cycles / 60s)",
                evidence: "60초 윈도우 안에서 connect ↔ disconnect \(cycles) 회 반복.",
                recommendation: "USB 접촉 불량 / 전원 노이즈 / socat 프로세스 재시작 / 네트워크 안정성 확인.",
                eventRefs: events.filter {
                    let k = $0.k.rawValue
                    return k == "connection.disconnect" || k == "connection.success"
                }.map(\.i),
                confidence: 0.8
            ))
        }
        return out
    }

    /// 60s 슬라이딩 윈도우 안 (connect 성공 → disconnect / failure) 쌍 카운트.
    private static func countFlappingCycles(events: [TelemetryEvent], windowSeconds: Double) -> Int {
        let endKinds: Set<String> = ["connection.disconnect", "connection.failure"]
        let startKind = "connection.success"
        var cycles = 0
        for i in 0..<events.count {
            guard events[i].k.rawValue == startKind else { continue }
            guard let t0 = SessionAnalyzer.parseIso(events[i].tw) else { continue }
            // 윈도우 안에서 disconnect / failure 가 있나?
            for j in (i+1)..<events.count {
                guard let tj = SessionAnalyzer.parseIso(events[j].tw) else { continue }
                if tj.timeIntervalSince(t0) > windowSeconds { break }
                if endKinds.contains(events[j].k.rawValue) {
                    cycles += 1
                    break
                }
            }
        }
        return cycles
    }

    // MARK: - RTT

    private static func rttRules(_ a: SessionAnalysis) -> [Insight] {
        guard let s = a.summary.rttMs else { return [] }
        var out: [Insight] = []
        if s.p95 > 100 {
            out.append(Insight(
                id: "rtt.severe#\(a.summary.firstEventAt ?? "")",
                ruleID: "rtt.severe",
                severity: .warn, kind: .connection,
                title: "RTT p95 \(fmt(s.p95))ms — 매우 느림",
                evidence: "샘플 \(s.count) 회 · mean \(fmt(s.mean))ms · p95 \(fmt(s.p95))ms · max \(fmt(s.max))ms",
                recommendation: "즉시 disconnect 권장. 네트워크 endpoint 면 socat / Wi-Fi 진단. USB 면 hub / 전원.",
                eventRefs: [],
                confidence: 0.95
            ))
        } else if s.p95 > 50 {
            out.append(Insight(
                id: "rtt.regression#\(a.summary.firstEventAt ?? "")",
                ruleID: "rtt.regression",
                severity: .notice, kind: .connection,
                title: "RTT p95 \(fmt(s.p95))ms — 평소보다 느림",
                evidence: "샘플 \(s.count) 회 · mean \(fmt(s.mean))ms · p95 \(fmt(s.p95))ms",
                recommendation: "bus polling cadence / endpoint 변경 / 케이블 점검 검토.",
                eventRefs: [],
                confidence: 0.7
            ))
        }
        return out
    }

    // MARK: - IMU

    private static func imuRules(_ a: SessionAnalysis) -> [Insight] {
        // **v1.14.2 (2026-05-21)** — `events` 안의 imu.unavailable / imu.recovered 패턴도
        // 함께 보려고 별도 메서드로 raw 이벤트 필요. 본 함수는 stale ratio 만 기본.
        guard let ratio = a.summary.imuStaleRatio, ratio >= 0.25 else { return [] }
        return [Insight(
            id: "imu.stale_persistent#\(a.summary.firstEventAt ?? "")",
            ruleID: "imu.stale_persistent",
            severity: ratio >= 0.5 ? .warn : .notice,
            kind: .imu,
            title: "IMU stale 비율 \(percent(ratio))",
            evidence: "heartbeat sample 중 imu_stale=true 가 \(percent(ratio)). 정상 < 5%.",
            recommendation: "IMU register 응답 확인. 펌웨어 variant / sensor 배선 / I2C 충돌 가능성.",
            eventRefs: [],
            confidence: 0.85
        )]
    }

    /// **v1.14.2 (2026-05-21)** — imu.unavailable ↔ imu.recovered 사이클 N회면
    /// "IMU 불안정" 진단. recovered 만 카운트 (페어로 발생).
    private static func imuFlappingRule(_ a: SessionAnalysis,
                                          _ events: [TelemetryEvent]) -> [Insight] {
        let recoveries = events.filter { $0.k.rawValue == "imu.recovered" }
        guard recoveries.count >= 3 else { return [] }
        return [Insight(
            id: "imu.flapping#\(a.summary.firstEventAt ?? "")",
            ruleID: "imu.flapping",
            severity: .warn, kind: .imu,
            title: "IMU 불안정 — 회복 \(recoveries.count)회",
            evidence: "한 세션에서 imu.recovered 가 \(recoveries.count) 회 발생. IMU 가 반복적으로 끊겼다 회복.",
            recommendation: "IMU 케이블 / 커넥터 / I2C 풀업 저항 / power 강하 점검. 펌웨어 retry 로직 확인.",
            eventRefs: recoveries.prefix(5).map(\.i),
            confidence: 0.9
        )]
    }

    /// **v1.14.2 (2026-05-21)** — reconnect 시도가 자주면 네트워크 / USB 환경 불량 진단.
    private static func reconnectRule(_ a: SessionAnalysis,
                                        _ events: [TelemetryEvent]) -> [Insight] {
        let attempts = events.filter { $0.k.rawValue == "connection.reconnect_attempt" }
        guard attempts.count >= 5 else { return [] }
        return [Insight(
            id: "connection.reconnect_frequent#\(a.summary.firstEventAt ?? "")",
            ruleID: "connection.reconnect_frequent",
            severity: .warn, kind: .connection,
            title: "자동 재연결 시도 \(attempts.count)회 — 환경 불안정",
            evidence: "한 세션 안에서 reconnect_attempt 가 \(attempts.count) 회. 정상은 0회 또는 단발.",
            recommendation: "네트워크 endpoint 면 socat 안정성 / Wi-Fi RSSI / 호스트명 → 고정 IP. USB 면 케이블 교체 / 다른 포트.",
            eventRefs: attempts.prefix(5).map(\.i),
            confidence: 0.85
        )]
    }

    /// **v1.14.2 (2026-05-21)** — bus.recovered 가 자주 발생 = 일시적 단선 패턴.
    private static func busFlappingRule(_ a: SessionAnalysis,
                                          _ events: [TelemetryEvent]) -> [Insight] {
        let recoveries = events.filter { $0.k.rawValue == "bus.recovered" }
        guard recoveries.count >= 5 else { return [] }
        return [Insight(
            id: "bus.flapping#\(a.summary.firstEventAt ?? "")",
            ruleID: "bus.flapping",
            severity: .warn, kind: .bus,
            title: "Bus 일시 단선 \(recoveries.count)회 — 진동 / 접촉 불량 의심",
            evidence: "bus.recovered 가 \(recoveries.count) 회. read 실패 후 다음 read 성공 패턴 반복.",
            recommendation: "DXL 커넥터 / TTL 케이블 흔들기 테스트. 진동 환경이면 케이블 고정. 모터 ID 단선 가능성.",
            eventRefs: recoveries.prefix(5).map(\.i),
            confidence: 0.85
        )]
    }

    // MARK: - Bus

    private static func busRules(_ a: SessionAnalysis,
                                  _ events: [TelemetryEvent]) -> [Insight] {
        var out: [Insight] = []
        // 분당 read fail.
        let durationMin = (a.summary.durationSeconds ?? 0) / 60.0
        let perMin: Double = durationMin > 0 ? Double(a.summary.busReadFailures) / durationMin : 0
        if a.summary.busReadFailures >= 10, perMin >= 10 {
            out.append(Insight(
                id: "bus.read_storm#\(a.summary.firstEventAt ?? "")",
                ruleID: "bus.read_storm",
                severity: .warn, kind: .bus,
                title: "Bus read 실패 폭증 — 분당 \(fmt(perMin))회",
                evidence: "총 \(a.summary.busReadFailures) 회 / \(fmt(durationMin)) 분.",
                recommendation: "특정 motor ID 단선 / power 강하 / Dynamixel ping 패킷 충돌 의심.",
                eventRefs: events.filter { $0.k.rawValue == "bus.read_fail" }.prefix(20).map(\.i),
                confidence: 0.85
            ))
        }
        return out
    }

    // MARK: - Harness self

    private static func harnessRules(_ a: SessionAnalysis) -> [Insight] {
        guard a.dropped > 0 else { return [] }
        return [Insight(
            id: "harness.dropped_present#\(a.summary.firstEventAt ?? "")",
            ruleID: "harness.dropped_present",
            severity: .notice, kind: .harness,
            title: "텔레메트리 이벤트 \(a.dropped) 개 누락",
            evidence: "AsyncStream 버퍼(4096) 초과로 newest 보존 정책 작동. consumer 가 느릴 때 발생.",
            recommendation: "이벤트 율 줄이기 또는 Harness.streamBufferLimit 상향. consumer Task 부하 점검.",
            eventRefs: [],
            confidence: 1.0
        )]
    }

    // MARK: - Idle

    private static func idleRules(_ a: SessionAnalysis,
                                    _ events: [TelemetryEvent]) -> [Insight] {
        guard let dur = a.summary.durationSeconds, dur > 1800 else { return [] }
        // 30분 이상이면서 user actor 이벤트 < 10 → idle.
        let userEvents = events.filter { $0.a == .user }.count
        guard userEvents < 10 else { return [] }
        return [Insight(
            id: "idle_session#\(a.summary.firstEventAt ?? "")",
            ruleID: "idle_session",
            severity: .info, kind: .idle,
            title: "긴 idle 세션 — \(Int(dur/60))분",
            evidence: "총 \(Int(dur/60)) 분 중 사용자 액션 \(userEvents) 회. 대부분 heartbeat.",
            recommendation: "테스트 의도 명확하지 않다면 세션 닫고 새로 시작. 디스크 / 분석 노이즈 감소.",
            eventRefs: [],
            confidence: 0.6
        )]
    }

    /// Bus write 실패 폭증 — busWriteFail 분당 5회 이상.
    private static func busWriteFailStorm(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let writes = events.filter { $0.k.rawValue == TelemetryKind.busWriteFail.rawValue }
        let durationMin = (a.summary.durationSeconds ?? 0) / 60.0
        let perMin: Double = durationMin > 0 ? Double(writes.count) / durationMin : 0
        guard writes.count >= 5, perMin >= 5 else { return [] }
        return [Insight(
            id: "bus.write_storm#\(a.summary.firstEventAt ?? "")",
            ruleID: "bus.write_storm",
            severity: .critical, kind: .bus,
            title: "Bus write 실패 폭증 — 분당 \(fmt(perMin))회",
            evidence: "총 \(writes.count) 회 / \(fmt(durationMin)) 분. bus read storm 과 병행 시 bus 전체 장애.",
            recommendation: "즉시 연결 해제 후 power cycle. 특정 motor ID 단선 / Dynamixel bus 충돌 의심.",
            eventRefs: Array(writes.prefix(10).map(\.i)),
            confidence: 0.9
        )]
    }

    // MARK: - format helpers

    static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
    static func percent(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
}
