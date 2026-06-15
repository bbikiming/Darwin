import Foundation

// MARK: - WalkLab + Pose insight rules
//
// HarnessInsights 도메인별 분리 (cycle 227).
// 원본 HarnessInsights.swift 에서 walklab / pose 관련 룰 추출.

extension HarnessInsights {

    // MARK: - WalkLab

    static func walkLabRules(_ a: SessionAnalysis,
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
        // 같은 세션의 두 번째/세 번째 e-stop 을 silently 누락했다. 모든 매칭 쌍을 발화하되,
        // 같은 start 가 여러 stop 의 prior 가 되는 케이스는 dedup.
        let starts = events.filter { $0.k.rawValue == "walklab.start" }
        let estops = events.filter { $0.k.rawValue == "walklab.emergency_stop" }
        if !starts.isEmpty, !estops.isEmpty {
            var firedPairs: Set<String> = []     // "startSeq-stopSeq" dedup
            for stop in estops {
                guard let stopT = SessionAnalyzer.parseIso(stop.tw) else { continue }
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

    static func poseRules(_ a: SessionAnalysis,
                          _ events: [TelemetryEvent]) -> [Insight] {
        var out: [Insight] = []
        for (i, ev) in events.enumerated() {
            guard ev.k.rawValue == "pose.apply_failed",
                  (ev.d.raw["reason"]?.value as? String) == "writeFailed" else { continue }
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

    // MARK: - WalkLab extended (cycle 225)

    /// 보행 진단 CSV 익스포트 실패 — diagnostics_export(success=false) ≥1.
    static func walklabDiagnosticsExportFailure(
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
    static func walklabBalanceRiskyPattern(
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
    static func walklabCalibrationIncomplete(
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

    /// 보행 데이터 대량 삭제 — data_session_deleted ≥3.
    static func walklabDataDeletionFrequent(
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
}
