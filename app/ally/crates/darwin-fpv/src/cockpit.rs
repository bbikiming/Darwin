//! 콕핏 — 런타임(안전 코어) ↔ Tauri 표시계층 브리지 (§3 Rust⇄UI 계약).
//!
//! **tauri-free 부분**(이 모듈 본문): Snapshot → §3 이벤트 페이로드 직렬화와 UI 커맨드
//! 모델. serde_json 만 쓰므로 기본 빌드에서 단위검증된다. **실제 Tauri 배선**(AppHandle·
//! `#[tauri::command]`·이벤트 emit·capabilities)은 `feature = "cockpit"` 의 [`shell`]
//! 모듈에 격리한다 — INV-2: 안전 런타임은 여전히 tauri 를 모르고, 셸만 EventSink 를
//! 구현해 이 직렬화로 webview 에 push 한다.

use serde_json::{json, Value};

use crate::state::Snapshot;

/// §3 `state` 이벤트 페이로드 — Snapshot → JSON(HUD 상태 스냅샷 전체).
///
/// `tel.*` 는 마지막 TEL2 원본에서 §3 필드로 사상한다(없으면 null). `tel.age_ms` 는
/// `now_ms − 수신시각`(>1500ms 면 UI 채도 저하 = stale 정직). 관절각은 TEL2 에 없으므로
/// 여기 없다(§5 합성 포즈는 별도 `pose` 이벤트 — Phase 3+/ally-pose).
pub fn state_payload(s: &Snapshot, now_ms: i64) -> Value {
    let tel = match &s.tel {
        None => Value::Null,
        Some(t) => json!({
            "x_lat": t.latch_x,
            "y_lat": t.latch_y,
            "a_lat": t.latch_a,
            "period_lat": t.latch_period,
            "phase": t.phase,
            "seq_applied": t.seq_applied,
            "imu": [t.gyro[0], t.gyro[1], t.gyro[2], t.accel[0], t.accel[1], t.accel[2]],
            "fsr": t.fsr.map(|c| Value::from(c.to_vec())).unwrap_or(Value::Null),
            "cop": t.cop.map(|c| Value::from(c.to_vec())).unwrap_or(Value::Null),
            "fallen": t.fallen,
            "voltage_v": t.voltage_v,
            "active_source": t.active_source,
            "walking": t.walking,
            "age_ms": s.tel_age_ms(now_ms),
        }),
    };
    json!({
        "conn": {
            "path": s.conn.path.as_str(),
            "transport": s.conn.transport.as_str(),
            "rtt_ms": s.conn.rtt_ms,
            "eff_hz": s.conn.eff_hz,
        },
        "safety": {
            "armed": s.safety.armed,
            "estop_latched": s.safety.estop_latched,
            "recovering": s.safety.recovering,
        },
        "cmd": { "x": s.cmd.x, "y": s.cmd.y, "a": s.cmd.a },
        "pad": { "connected": s.pad.connected, "turbo": s.pad.turbo },
        "cam": { "healthy": s.cam_healthy },
        "tel": tel,
    })
}

/// §3 `stick` 이벤트 페이로드 — 스틱/트리거 readout 오버레이(경량·고빈도).
pub fn stick_payload(lx: f64, ly: f64, rx: f64, ry: f64, lt: f64, rt: f64) -> Value {
    json!({ "lx": lx, "ly": ly, "rx": rx, "ry": ry, "lt": lt, "rt": rt })
}

/// UI→Rust 커맨드(§3 invoke) 모델 — 셸이 Tauri 커맨드를 이걸로 환원해 런타임에 지시한다.
/// `touch_estop` 은 **보조 경로**(물리 B 가 주) — 무손실 estop 채널에 합류한다.
#[derive(Debug, Clone, PartialEq)]
pub enum CockpitCommand {
    /// §7 세션 시퀀스 개시(prefer = "wired"|"wireless").
    Connect { prefer: String },
    /// §7-⑦ 정리 후 종료.
    Disconnect,
    /// 보조 E-STOP — estop 채널 합류(webview 죽어도 물리 경로 무손상).
    TouchEstop,
    /// 비안전 설정만(HUD 토글 등). 매핑 수치는 D2 동결 — 설정 항목 아님.
    SetSettings(Value),
}

#[cfg(feature = "cockpit")]
pub mod shell;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{ConnPath, ConnTransport, Snapshot};

    #[test]
    fn state_payload_reflects_safety_and_conn() {
        let mut s = Snapshot::disconnected();
        s.conn.path = ConnPath::Wireless;
        s.conn.transport = ConnTransport::SshFile;
        s.conn.eff_hz = 19.5;
        s.conn.rtt_ms = Some(12.0);
        s.safety.armed = true;
        s.safety.estop_latched = true;
        s.cmd.x = 38.0;
        let v = state_payload(&s, 1000);
        assert_eq!(v["conn"]["path"], "wireless");
        assert_eq!(v["conn"]["transport"], "ssh_file");
        assert_eq!(v["conn"]["eff_hz"], 19.5);
        assert_eq!(v["conn"]["rtt_ms"], 12.0);
        assert_eq!(v["safety"]["armed"], true);
        assert_eq!(v["safety"]["estop_latched"], true);
        assert_eq!(v["cmd"]["x"], 38.0);
    }

    #[test]
    fn tel_is_null_until_received_then_honest_age() {
        let mut s = Snapshot::disconnected();
        // 미수신 → null + rtt null.
        let v = state_payload(&s, 1000);
        assert_eq!(v["tel"], Value::Null);
        assert_eq!(v["conn"]["rtt_ms"], Value::Null);

        // 수신 후 age 가 정직하게 흐른다(>1500 이면 UI 가 stale 강등).
        let mut tel = sample_tel();
        tel.latch_x = 7.5;
        s.apply_tel2(tel, 1000);
        let v = state_payload(&s, 2600); // 1600ms 경과 → stale 영역
        assert_eq!(v["tel"]["x_lat"], 7.5);
        assert_eq!(v["tel"]["age_ms"], 1600);
        assert_eq!(v["tel"]["imu"].as_array().unwrap().len(), 6);
    }

    #[test]
    fn fsr_cop_null_groups() {
        let mut s = Snapshot::disconnected();
        let mut tel = sample_tel();
        tel.fsr = None;
        tel.cop = None;
        s.apply_tel2(tel, 0);
        let v = state_payload(&s, 0);
        assert_eq!(v["tel"]["fsr"], Value::Null);
        assert_eq!(v["tel"]["cop"], Value::Null);
    }

    fn sample_tel() -> df_wire::Tel2 {
        df_wire::Tel2 {
            ts_ms: 0,
            seq_applied: 5,
            phase: 2,
            latch_x: 0.0,
            latch_y: 0.0,
            latch_a: 0.0,
            latch_period: 600.0,
            gyro: [1, 2, 3],
            accel: [4, 5, 6],
            fsr: Some([10, 20, 30, 40, 50, 60, 70, 80]),
            cop: Some([100, 200]),
            ground: true,
            left_contact: true,
            right_contact: false,
            fallen: 0,
            risk: None,
            voltage_v: Some(11.8),
            battery_pct: Some(62),
            active_source: "udp".into(),
            loop_ms: 8,
            walking: true,
        }
    }
}
