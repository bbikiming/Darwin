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

    // MARK: - WalkLab

    private static func walkLabRules(_ a: SessionAnalysis,
                                       _ events: [TelemetryEvent]) -> [Insight] {
        var out: [Insight] = []
        // 같은 reason 으로 차단 3+.
        let blocked = events.filter { $0.k.rawValue == "walklab.start_blocked" }
        var reasonCount: [String: Int] = [:]
        for ev in blocked {
            if let r = ev.d.raw["reason"]?.value as? String {
                reasonCount[r, default: 0] += 1
            }
        }
        for (reason, count) in reasonCount where count >= 3 {
            out.append(Insight(
                id: "walklab.start_blocked_repeat:\(reason)#\(a.summary.firstEventAt ?? "")",
                ruleID: "walklab.start_blocked_repeat",
                severity: .warn, kind: .walklab,
                title: "보행 시작 차단 반복 — \(reason) (\(count)회)",
                evidence: "같은 사유로 \(count) 번 차단됨. 사용자가 재시도해도 같은 곳에서 막힘.",
                recommendation: "사유에 맞는 사전 조건 확인: cradle / IMU / SSH / brokering / balance corrector.",
                eventRefs: blocked.filter { ($0.d.raw["reason"]?.value as? String) == reason }.map(\.i),
                confidence: 0.9
            ))
        }
        // walkLab.start 후 1분 안 e-stop — 모든 매칭 쌍 발화.
        //
        // **v1.14.1 (Critic P1-3 fix, 2026-05-21)** — 종전 `break` 가 첫 e-stop 만 보고
        // 같은 세션의 두 번째/세 번째 e-stop 을 silently 누락했다 ("walk → e-stop → 재연결
        // → walk → e-stop" 같은 반복 안전 사고 패턴). 모든 매칭 쌍을 발화하되, 같은
        // start 가 여러 stop 의 prior 가 되는 케이스는 dedup.
        let starts = events.filter { $0.k.rawValue == "walklab.start" }
        let estops = events.filter { $0.k.rawValue == "walklab.emergency_stop" }
        if !starts.isEmpty, !estops.isEmpty {
            var firedPairs: Set<String> = []     // "startSeq-stopSeq" dedup
            for stop in estops {
                guard let stopT = SessionAnalyzer.parseIso(stop.tw) else { continue }
                // 가장 가까운 prior start 찾기.
                let priorStarts = starts.filter {
                    guard let t = SessionAnalyzer.parseIso($0.tw) else { return false }
                    return t < stopT
                }
                guard let lastStart = priorStarts.last,
                      let startT = SessionAnalyzer.parseIso(lastStart.tw) else { continue }
                let delta = stopT.timeIntervalSince(startT)
                guard delta <= 60 else { continue }
                let pairKey = "\(lastStart.i)-\(stop.i)"
                guard !firedPairs.contains(pairKey) else { continue }
                firedPairs.insert(pairKey)
                out.append(Insight(
                    id: "walklab.emergency_pattern:\(stop.i)#\(a.summary.firstEventAt ?? "")",
                    ruleID: "walklab.emergency_pattern",
                    severity: .critical, kind: .walklab,
                    title: "보행 시작 후 \(Int(delta))초 내 비상 정지",
                    evidence: "walkLab.start (seq #\(lastStart.i)) → walkLab.emergency_stop (seq #\(stop.i)).",
                    recommendation: "tilt 임계 / fall predictor / IMU 부호 / balance corrector gain 검토. 반복되면 systemic 이슈.",
                    eventRefs: [lastStart.i, stop.i],
                    confidence: 0.85
                ))
            }
            // 2회 이상 반복이면 종합 critical insight 추가.
            if firedPairs.count >= 2 {
                let stopSeqs = estops.map(\.i)
                out.append(Insight(
                    id: "walklab.emergency_pattern_repeat#\(a.summary.firstEventAt ?? "")",
                    ruleID: "walklab.emergency_pattern_repeat",
                    severity: .critical, kind: .walklab,
                    title: "보행 시작 후 비상 정지 반복 — \(firedPairs.count) 회",
                    evidence: "같은 세션에서 1분 내 start→e-stop 패턴 \(firedPairs.count) 회 반복. systemic 이슈 강력 시사.",
                    recommendation: "IMU 부호 / tilt 임계 / cradle 위치 / 모터 power 모두 재점검. 동영상 비교 권장.",
                    eventRefs: stopSeqs,
                    confidence: 0.95
                ))
            }
        }
        return out
    }

    // MARK: - Pose

    private static func poseRules(_ a: SessionAnalysis,
                                    _ events: [TelemetryEvent]) -> [Insight] {
        var out: [Insight] = []
        // pose.apply_failed → bus.read_fail / bus.write_fail 연쇄.
        for (i, ev) in events.enumerated() {
            guard ev.k.rawValue == "pose.apply_failed",
                  (ev.d.raw["reason"]?.value as? String) == "writeFailed" else { continue }
            // 직후 30초 내 bus.read_fail 또는 bus.write_fail 있나?
            guard let evT = SessionAnalyzer.parseIso(ev.tw) else { continue }
            let nextWindow = events.dropFirst(i + 1).prefix { next in
                guard let nt = SessionAnalyzer.parseIso(next.tw) else { return false }
                return nt.timeIntervalSince(evT) <= 30
            }
            let busChain = nextWindow.filter {
                $0.k.rawValue == "bus.read_fail" || $0.k.rawValue == "bus.write_fail"
            }
            if busChain.count >= 2 {
                out.append(Insight(
                    id: "pose.write_failed_chain:\(ev.i)#\(a.summary.firstEventAt ?? "")",
                    ruleID: "pose.write_failed_chain",
                    severity: .warn, kind: .pose,
                    title: "Pose write 실패 후 bus 에러 연쇄",
                    evidence: "pose.apply_failed (writeFailed, seq #\(ev.i)) 직후 30초 내 bus 에러 \(busChain.count) 회.",
                    recommendation: "Bus / motor power 회복 시퀀스 — torque OFF → 잠시 대기 → power 재인가 후 재시도.",
                    eventRefs: [ev.i] + busChain.map(\.i),
                    confidence: 0.8
                ))
                break
            }
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

    // MARK: - Pilot adapter (cycle 215)

    /// 음성 인식 오류가 세션 내에서 3회 이상이면 HW/설정 문제 의심.
    private static func pilotVoiceErrorInsight(
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
    private static func pilotVoiceMissRatioInsight(
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
    private static func setupConnRepeatedFailure(
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
    private static func setupConnWizardFrequency(
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
    private static func pilotSafetyGateBlockedFrequent(
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
    private static func pilotActionBarRiskCancelFrequent(
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
    private static func claudeIntentErrorPattern(
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

    // MARK: - WalkLab extended (cycle 225)

    /// 보행 진단 CSV 익스포트 실패 — diagnostics_export(success=false) ≥1.
    private static func walklabDiagnosticsExportFailure(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let failures = events.filter {
            $0.k.rawValue == TelemetryKind.walklabDiagnosticsExport.rawValue
                && ($0.d.raw["success"]?.value as? Bool) == false
        }
        let count = failures.count
        guard count >= 1 else { return [] }
        return [Insight(
            id: "walklab.diagnostics_export_failure#\(a.summary.firstEventAt ?? "")",
            ruleID: "walklab.diagnostics_export_failure",
            severity: .warn, kind: .walklab,
            title: "보행 진단 CSV 익스포트 실패",
            evidence: "\(count)건 익스포트 실패. 파일 권한 또는 디스크 공간 문제.",
            recommendation: "익스포트 대상 경로 쓰기 권한 확인. 디스크 여유 공간 점검.",
            eventRefs: Array(failures.prefix(5).map(\.i)),
            confidence: 0.8
        )]
    }

    /// 위험 balance 설정 승인 반복 — balance_risky_confirmed ≥2.
    private static func walklabBalanceRiskyPattern(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let risky = events.filter { $0.k.rawValue == TelemetryKind.walklabBalanceRiskyConfirmed.rawValue }
        let count = risky.count
        guard count >= 2 else { return [] }
        return [Insight(
            id: "walklab.balance_risky_pattern#\(a.summary.firstEventAt ?? "")",
            ruleID: "walklab.balance_risky_pattern",
            severity: .warn, kind: .walklab,
            title: "위험 balance 설정 승인 \(count)회 — 주의",
            evidence: "세션 중 balance_risky_confirmed \(count)회. 안전 범위 밖 gain/sign 사용.",
            recommendation: "모든 위험 설정은 sim 에서 먼저 검증 권장. 낙상 대비 크레들 고정 확인.",
            eventRefs: Array(risky.prefix(5).map(\.i)),
            confidence: 0.7
        )]
    }

    /// 캘리브레이션 미완료 — capture_start 후 capture_done 없는 축.
    private static func walklabCalibrationIncomplete(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let starts = events.filter { $0.k.rawValue == TelemetryKind.walklabCalibrationCaptureStart.rawValue }
        let dones = events.filter { $0.k.rawValue == TelemetryKind.walklabCalibrationCaptureDone.rawValue }
        let doneAxes = Set(dones.compactMap { $0.d.raw["axis"]?.value as? String })
        let incomplete = starts.compactMap { $0.d.raw["axis"]?.value as? String }
            .filter { !doneAxes.contains($0) }
        let unique = Array(Set(incomplete))
        guard !unique.isEmpty else { return [] }
        let refs = starts.filter {
            guard let ax = $0.d.raw["axis"]?.value as? String else { return false }
            return unique.contains(ax)
        }
        return [Insight(
            id: "walklab.calibration_incomplete#\(a.summary.firstEventAt ?? "")",
            ruleID: "walklab.calibration_incomplete",
            severity: .notice, kind: .walklab,
            title: "캘리브레이션 미완료 — \(unique.joined(separator: ", "))",
            evidence: "calibration_capture_start 후 capture_done 없는 축: \(unique.joined(separator: ", ")). 캘리브레이션 중단됨.",
            recommendation: "캘리브레이션 미완료 축은 IMU 보정이 적용되지 않음. 해당 축 재캡처 필요.",
            eventRefs: Array(refs.prefix(5).map(\.i)),
            confidence: 0.75
        )]
    }

    // MARK: - Pilot demo mode (cycle 225)

    /// 데모 모드 전환 실패 반복 — demo_mode_result(success=false) ≥2.
    private static func pilotDemoModeFailure(
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

    // MARK: - WalkLab data deletion (cycle 225)

    /// 보행 데이터 대량 삭제 — data_session_deleted ≥3.
    private static func walklabDataDeletionFrequent(
        _ a: SessionAnalysis, _ events: [TelemetryEvent]
    ) -> [Insight] {
        let deleted = events.filter { $0.k.rawValue == TelemetryKind.walklabDataSessionDeleted.rawValue }
        let count = deleted.count
        guard count >= 3 else { return [] }
        return [Insight(
            id: "walklab.data_deletion_frequent#\(a.summary.firstEventAt ?? "")",
            ruleID: "walklab.data_deletion_frequent",
            severity: .info, kind: .walklab,
            title: "보행 데이터 세션 \(count)건 삭제",
            evidence: "세션 중 \(count)건 삭제. 대량 데이터 정리 또는 품질 불만 가능성.",
            recommendation: "자동 정리 정책 활용 검토. 삭제 사유 분석하여 trial 품질 개선.",
            eventRefs: Array(deleted.prefix(5).map(\.i)),
            confidence: 0.5
        )]
    }

    // MARK: - format helpers

    private static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
    private static func percent(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
}
