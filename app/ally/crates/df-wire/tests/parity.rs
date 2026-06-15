//! Python(df_udp.py — 실기 검증 원본) ↔ Rust(df-wire) 골든 벡터 패리티.
//!
//! 픽스처는 `scripts/gen-golden-vectors.py` 가 Python 원본을 실행해 생성한다.
//! 여기서 실패하면 포팅이 계약에서 드리프트한 것이다 — 픽스처를 고치지 말고
//! Rust 구현을 고쳐라 (원본이 바뀐 경우에만 재생성).

use df_wire::{
    battery_from_dv, build_line, cmd_datagram, estop_datagram, handshake_line, parse_ack,
    parse_tel2, GaitConfig, MotionCommand,
};

fn unhex(s: &str) -> Vec<u8> {
    assert!(s.len().is_multiple_of(2), "odd hex length: {s:?}");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex"))
        .collect()
}

fn cases(raw: &str) -> impl Iterator<Item = &str> {
    raw.lines().filter(|l| !l.is_empty() && !l.starts_with('#'))
}

#[test]
fn handshake_parity() {
    for line in cases(include_str!("fixtures/handshake.txt")) {
        let cols: Vec<&str> = line.split('|').collect();
        let [token, estop, cmd, hex] = cols[..] else {
            panic!("bad fixture line: {line}")
        };
        let expected = unhex(hex);
        let got = handshake_line(token, estop.parse().unwrap(), cmd.parse().unwrap());
        assert_eq!(got.into_bytes(), expected, "handshake({token})");
    }
}

#[test]
fn cmd_datagram_parity() {
    for fixture in cases(include_str!("fixtures/cmd_datagram.txt")) {
        // line 컬럼이 마지막 — 명령 라인 자체에 공백이 들어간다.
        let cols: Vec<&str> = fixture.splitn(4, '|').collect();
        let [token, seq, hex, line] = cols[..] else {
            panic!("bad fixture line: {fixture}")
        };
        let expected = unhex(hex);
        let got = cmd_datagram(token, seq.parse().unwrap(), line);
        assert_eq!(got, expected, "cmd_datagram(seq={seq})");
    }
}

#[test]
fn estop_datagram_parity() {
    for line in cases(include_str!("fixtures/estop_datagram.txt")) {
        let cols: Vec<&str> = line.split('|').collect();
        let [token, ts, hex] = cols[..] else {
            panic!("bad fixture line: {line}")
        };
        let expected = unhex(hex);
        assert_eq!(
            estop_datagram(token, ts.parse().unwrap()),
            expected,
            "estop(ts={ts})"
        );
    }
}

#[test]
fn ack_parity() {
    for line in cases(include_str!("fixtures/ack.txt")) {
        let cols: Vec<&str> = line.splitn(2, '|').collect();
        let [hex, expected] = cols[..] else {
            panic!("bad fixture line: {line}")
        };
        let got = match parse_ack(&unhex(hex)) {
            None => "none".to_string(),
            Some((seq, t_rx)) => format!("{seq} {t_rx}"),
        };
        assert_eq!(got, expected, "ack({hex})");
    }
}

#[test]
fn tel2_parity() {
    for line in cases(include_str!("fixtures/tel2.txt")) {
        let cols: Vec<&str> = line.splitn(2, '|').collect();
        let [hex, expected] = cols[..] else {
            panic!("bad fixture line: {line}")
        };
        let got = match parse_tel2(&unhex(hex)) {
            None => "none".to_string(),
            Some(tel) => tel.canonical(),
        };
        assert_eq!(got, expected, "tel2({hex})");
    }
}

#[test]
fn battery_parity() {
    for line in cases(include_str!("fixtures/battery.txt")) {
        let cols: Vec<&str> = line.split('|').collect();
        let [dv, v_expected, pct_expected] = cols[..] else {
            panic!("bad fixture line: {line}")
        };
        let (volt, pct) = battery_from_dv(dv.parse().unwrap());
        let v_got = volt.map_or("-".to_string(), |v| format!("{v:.6}"));
        let pct_got = pct.map_or("-".to_string(), |p| p.to_string());
        assert_eq!(v_got, v_expected, "battery v(dv={dv})");
        assert_eq!(pct_got, pct_expected, "battery pct(dv={dv})");
    }
}

#[test]
fn build_line_parity() {
    for fixture in cases(include_str!("fixtures/build_line.txt")) {
        let cols: Vec<&str> = fixture.splitn(16, '|').collect();
        let [cmd_id, period, foot, hip, min_period, max_period, min_foot, stride_ref, turn_ref, enabled, stride, side, turn, pan, tilt, expected] =
            cols[..]
        else {
            panic!("bad fixture line: {fixture}")
        };
        let cfg = GaitConfig {
            period_ms: period.parse().unwrap(),
            foot_mm: foot.parse().unwrap(),
            hip_deg: hip.parse().unwrap(),
            min_period_ms: min_period.parse().unwrap(),
            max_period_ms: max_period.parse().unwrap(),
            min_foot_mm: min_foot.parse().unwrap(),
            stride_ref_mm: stride_ref.parse().unwrap(),
            turn_ref_deg: turn_ref.parse().unwrap(),
        };
        let cmd = MotionCommand {
            enabled: enabled == "1",
            stride_mm: stride.parse().unwrap(),
            side_mm: side.parse().unwrap(),
            turn_deg: turn.parse().unwrap(),
            head_pan_deg: pan.parse().unwrap(),
            head_tilt_deg: tilt.parse().unwrap(),
        };
        assert_eq!(
            build_line(cmd_id, &cfg, &cmd),
            expected,
            "build_line({cmd_id})"
        );
    }
}
