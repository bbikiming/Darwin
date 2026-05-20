import Foundation

// MARK: - SessionMarkdownReport (v1.13.0)
//
// SessionAnalysis → Markdown 텍스트.  Claude / 동료에게 "이 세션 무슨 일이 있었나" 줄 때
// 사용. PII 는 이미 redact 된 상태로 디스크에 저장되어 있어 그대로 출력 안전.

public enum SessionMarkdownReport {

    /// 세션 meta + 분석 결과 → markdown 텍스트.
    public static func render(meta: TelemetrySessionMeta,
                                analysis: SessionAnalysis,
                                maxEnvelopes: Int = 10) -> String {
        var out: [String] = []

        out.append("# DarwinForge Harness Session — \(meta.id.prefix(8))")
        out.append("")
        out.append("- **App**: \(meta.appVersion) (build \(meta.appBuild))")
        out.append("- **Device / OS**: \(meta.device) · \(meta.os)")
        out.append("- **시작**: \(humanIso(meta.started))")
        if let ended = meta.ended {
            out.append("- **종료**: \(humanIso(ended))")
        } else {
            out.append("- **종료**: (비정상 종료 또는 진행 중)")
        }
        if let d = analysis.summary.durationLabel() {
            out.append("- **기간**: \(d)")
        }
        out.append("- **이벤트 수**: \(analysis.summary.totalEvents)")
        if analysis.dropped > 0 {
            out.append("- **Dropped**: \(analysis.dropped) (버퍼 초과)")
        }
        if meta.pinned {
            out.append("- **Pinned**: yes")
        }
        out.append("")

        out.append("## 요약")
        out.append("")
        out.append(summaryTable(analysis.summary))
        out.append("")

        if !analysis.summary.namespaceCounts.isEmpty {
            out.append("### 이벤트 분포 (Namespace)")
            out.append("")
            out.append("| Namespace | Count |")
            out.append("|-----------|------:|")
            for ns in analysis.summary.namespaceCounts.prefix(15) {
                out.append("| `\(ns.namespace)` | \(ns.count) |")
            }
            out.append("")
        }

        if let rtt = analysis.summary.rttMs {
            out.append("### RTT (ms)")
            out.append("")
            out.append("| count | mean | min | max | p95 |")
            out.append("|------:|-----:|----:|----:|----:|")
            out.append("| \(rtt.count) | \(fmt(rtt.mean)) | \(fmt(rtt.min)) | \(fmt(rtt.max)) | \(fmt(rtt.p95)) |")
            out.append("")
        }
        if let b = analysis.summary.batteryV {
            out.append("### 배터리 전압 (V)")
            out.append("")
            out.append("| count | mean | min | max | p95 |")
            out.append("|------:|-----:|----:|----:|----:|")
            out.append("| \(b.count) | \(fmt(b.mean)) | \(fmt(b.min)) | \(fmt(b.max)) | \(fmt(b.p95)) |")
            out.append("")
        }
        if let ratio = analysis.summary.imuStaleRatio, ratio > 0 {
            out.append("### IMU stale ratio")
            out.append("")
            out.append("Heartbeat sample 중 `imu_stale=true` 비율: **\(percent(ratio))**.")
            out.append("")
        }

        if !analysis.errors.isEmpty {
            out.append("## 에러 / 경고 envelopes (\(analysis.errors.count)건, 최대 \(maxEnvelopes)건 표시)")
            out.append("")
            for env in analysis.errors.prefix(maxEnvelopes) {
                out.append(renderEnvelope(env))
                out.append("")
            }
        }

        if !analysis.bookmarks.isEmpty {
            out.append("## 사용자 북마크")
            out.append("")
            for b in analysis.bookmarks {
                let len = (b.d.raw["len"]?.value as? Int) ?? 0
                let hash = (b.d.raw["hash"]?.value as? String) ?? ""
                out.append("- `#\(b.i)` \(humanIso(b.tw)) — note hash `\(hash)` (len \(len))")
            }
            out.append("")
        }

        out.append("---")
        out.append("_생성: DarwinForge Harness v1.13.0._")
        return out.joined(separator: "\n")
    }

    // MARK: - 내부 helpers

    private static func summaryTable(_ s: SessionSummary) -> String {
        var rows: [(String, String)] = []
        rows.append(("연결 시도 / 성공 / 실패",
                     "\(s.connectAttempts) / \(s.connectSuccesses) / \(s.connectFailures)"))
        rows.append(("Disconnect", "\(s.disconnects)"))
        rows.append(("Bus read / write 실패",
                     "\(s.busReadFailures) / \(s.busWriteFailures)"))
        rows.append(("E-stop", "\(s.eStops)"))
        rows.append(("Error / Warn", "\(s.errorCount) / \(s.warnCount)"))
        rows.append(("WalkLab start / stop / e-stop",
                     "\(s.walkLabStarts) / \(s.walkLabStops) / \(s.walkLabEmergencyStops)"))
        rows.append(("WalkLab blocked", "\(s.walkLabStartBlocks)"))
        rows.append(("Motion play / complete",
                     "\(s.motionPlays) / \(s.motionCompletes)"))
        rows.append(("Pose apply", "\(s.poseApplies)"))
        rows.append(("Teach 스냅샷 / 라이브러리 저장",
                     "\(s.teachSnapshots) / \(s.poseLibrarySaves)"))

        var out: [String] = ["| 항목 | 값 |", "|------|----|"]
        for (k, v) in rows {
            out.append("| \(k) | \(v) |")
        }
        return out.joined(separator: "\n")
    }

    private static func renderEnvelope(_ env: ErrorEnvelope) -> String {
        var out: [String] = []
        out.append("### 🚨 `\(env.trigger.k.rawValue)` (\(env.trigger.lv.rawValue))")
        out.append("- 시각: `\(humanIso(env.trigger.tw))`  ·  seq `#\(env.trigger.i)`  ·  actor `\(env.trigger.a.rawValue)`")
        if let ctx = env.trigger.c {
            out.append("- Context: \(renderCtx(ctx))")
        }
        if !env.trigger.d.raw.isEmpty {
            out.append("- Payload:")
            out.append("  ```json")
            for line in prettyJson(env.trigger.d.raw).split(separator: "\n") {
                out.append("  \(line)")
            }
            out.append("  ```")
        }
        if !env.preceding.isEmpty {
            out.append("- 직전:")
            for ev in env.preceding {
                out.append("  - `\(briefIso(ev.tw))` `\(ev.k.rawValue)` (\(ev.lv.rawValue))")
            }
        }
        if !env.following.isEmpty {
            out.append("- 직후:")
            for ev in env.following {
                out.append("  - `\(briefIso(ev.tw))` `\(ev.k.rawValue)` (\(ev.lv.rawValue))")
            }
        }
        return out.joined(separator: "\n")
    }

    private static func renderCtx(_ c: TelemetryContext) -> String {
        var parts: [String] = []
        if let cn = c.cn { parts.append("conn=`\(cn.rawValue)`") }
        if let ep = c.ep { parts.append("endpoint=`\(ep)`") }
        if let sc = c.sc { parts.append("section=`\(sc)`") }
        if let bv = c.bv { parts.append("batt=`\(fmt(bv))V`") }
        if let rt = c.rt { parts.append("rtt=`\(fmt(rt))ms`") }
        if c.im == true { parts.append("**imu_stale**") }
        return parts.joined(separator: " · ")
    }

    private static func prettyJson(_ obj: [String: AnyCodable]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(obj), let s = String(data: d, encoding: .utf8) { return s }
        return "{}"
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }
    private static func percent(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }

    private static func humanIso(_ s: String) -> String {
        guard let d = SessionAnalyzer.parseIso(s) else { return s }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private static func briefIso(_ s: String) -> String {
        guard let d = SessionAnalyzer.parseIso(s) else { return s }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}
