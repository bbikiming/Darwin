//! §A.2-TEL2 텔레메트리 파싱 — `df_udp.parse_tel2`/`battery_from_dv` 의 1:1 포팅.
//!
//! 가변 토큰 수: FSR 그룹은 8셀 또는 단일 "-", CoP 그룹은 2셀 또는 단일 "-".
//! 커서가 라인을 걷고, 형태가 어긋난 입력은 None(샘플 폐기 — 루프에 예외를
//! 던지지도, 쓰레기를 먹이지도 않는다).

use crate::wire::ascii_lossy_str;

/// 3S LiPo 전압 창 — 배터리 퍼센트 추정용 (Python 원본과 동일).
pub const BATTERY_MIN_V: f64 = 10.5;
pub const BATTERY_MAX_V: f64 = 12.6;

// 고정 선두 14토큰: TEL2 ts seq phase x y a period gx gy gz ax ay az.
const TEL2_FIXED: usize = 14;

/// 파싱된 TEL2 한 샘플. 필드 의미는 ssh-parity-contract §A.2-TEL2.
#[derive(Debug, Clone, PartialEq)]
pub struct Tel2 {
    pub ts_ms: i64,
    pub seq_applied: i64,
    /// 보행 위상 (음수 = 보행 중 아님) — 3D 합성 포즈의 입력.
    pub phase: i64,
    /// 셰이핑(거버너·슬루) 적용된 래치값 — HUD 래치 인디케이터의 "적용값".
    pub latch_x: f64,
    pub latch_y: f64,
    pub latch_a: f64,
    pub latch_period: f64,
    pub gyro: [i64; 3],
    pub accel: [i64; 3],
    pub fsr: Option<[i64; 8]>,
    pub cop: Option<[i64; 2]>,
    /// CoP 존재 = 접지 신호 (§A.2-TEL2).
    pub ground: bool,
    pub left_contact: bool,
    pub right_contact: bool,
    pub fallen: i64,
    pub risk: Option<f64>,
    pub voltage_v: Option<f64>,
    pub battery_pct: Option<i64>,
    pub active_source: String,
    pub loop_ms: i64,
    /// TEL2 에는 walking01 이 없다 — 위상(>=0)으로 유도 (Python 원본 동일).
    pub walking: bool,
}

/// TEL2 데이터그램 파싱. 형태 불일치·숫자 오류는 모두 None.
pub fn parse_tel2(data: &[u8]) -> Option<Tel2> {
    let text = ascii_lossy_str(data);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    let t: Vec<&str> = trimmed.split_whitespace().collect();
    if t.len() < TEL2_FIXED || t[0] != "TEL2" {
        return None;
    }
    let ts_ms = t[1].parse::<i64>().ok()?;
    let seq_applied = t[2].parse::<i64>().ok()?;
    let phase = t[3].parse::<i64>().ok()?;
    let latch_x = t[4].parse::<f64>().ok()?;
    let latch_y = t[5].parse::<f64>().ok()?;
    let latch_a = t[6].parse::<f64>().ok()?;
    let latch_period = t[7].parse::<f64>().ok()?;
    let gyro = parse_i64_triplet(&t, 8)?;
    let accel = parse_i64_triplet(&t, 11)?;

    let mut cur = TEL2_FIXED;
    let fsr = if *t.get(cur)? == "-" {
        cur += 1;
        None
    } else {
        let mut cells = [0i64; 8];
        for (i, cell) in cells.iter_mut().enumerate() {
            *cell = t.get(cur + i)?.parse::<i64>().ok()?;
        }
        cur += 8;
        Some(cells)
    };
    let cop = if *t.get(cur)? == "-" {
        cur += 1;
        None
    } else {
        let x = t.get(cur)?.parse::<i64>().ok()?;
        let y = t.get(cur + 1)?.parse::<i64>().ok()?;
        cur += 2;
        Some([x, y])
    };
    let fallen = t.get(cur)?.parse::<i64>().ok()?;
    cur += 1;
    let risk_token = *t.get(cur)?;
    let risk = if risk_token == "-" {
        None
    } else {
        Some(risk_token.parse::<f64>().ok()?)
    };
    cur += 1;
    let voltage_dv = t.get(cur)?.parse::<i64>().ok()?;
    cur += 1;
    let active_source = (*t.get(cur)?).to_string();
    cur += 1;
    let loop_ms = t.get(cur)?.parse::<i64>().ok()?;

    let (voltage_v, battery_pct) = battery_from_dv(voltage_dv);
    // FSR 그룹에서 발별 접지 유도 — CoP 그룹은 로봇의 전신 접지 신호 (§A.2-TEL2).
    let left_contact = fsr.is_some_and(|c| c[0..4].iter().any(|&v| v > 0));
    let right_contact = fsr.is_some_and(|c| c[4..8].iter().any(|&v| v > 0));

    Some(Tel2 {
        ts_ms,
        seq_applied,
        phase,
        latch_x,
        latch_y,
        latch_a,
        latch_period,
        gyro,
        accel,
        fsr,
        cop,
        ground: cop.is_some(),
        left_contact,
        right_contact,
        fallen,
        risk,
        voltage_v,
        battery_pct,
        active_source,
        loop_ms,
        walking: phase >= 0,
    })
}

fn parse_i64_triplet(t: &[&str], start: usize) -> Option<[i64; 3]> {
    Some([
        t.get(start)?.parse::<i64>().ok()?,
        t.get(start + 1)?.parse::<i64>().ok()?,
        t.get(start + 2)?.parse::<i64>().ok()?,
    ])
}

/// 데시볼트 → (볼트, 퍼센트). 0 이하 = 미상 (Python 원본 동일).
pub fn battery_from_dv(voltage_dv: i64) -> (Option<f64>, Option<i64>) {
    if voltage_dv <= 0 {
        return (None, None);
    }
    let voltage_v = voltage_dv as f64 / 10.0;
    let span = BATTERY_MAX_V - BATTERY_MIN_V;
    let pct = round_half_even((voltage_v - BATTERY_MIN_V) / span * 100.0);
    (Some(voltage_v), Some(pct.clamp(0, 100)))
}

// Python round() 는 banker's rounding(half-to-even) — f64::round()(half-away)와
// 다르므로 패리티를 위해 직접 구현한다.
fn round_half_even(x: f64) -> i64 {
    let floor = x.floor();
    let diff = x - floor;
    let f = floor as i64;
    // 정확히 .5 인 동률은 짝수 쪽으로 — 그 외엔 가까운 쪽으로.
    let round_up = diff > 0.5 || (diff >= 0.5 && f % 2 != 0);
    if round_up {
        f + 1
    } else {
        f
    }
}

impl Tel2 {
    /// 패리티 검증용 캐노니컬 직렬화 — `scripts/gen-golden-vectors.py::canon_tel2`
    /// 와 형식이 핀 고정으로 거울이다. 형식을 바꾸면 양쪽을 함께 바꿔라.
    pub fn canonical(&self) -> String {
        let fsr = match &self.fsr {
            Some(c) => c.iter().map(i64::to_string).collect::<Vec<_>>().join(","),
            None => "-".to_string(),
        };
        let cop = match &self.cop {
            Some(c) => format!("{},{}", c[0], c[1]),
            None => "-".to_string(),
        };
        let risk = match self.risk {
            Some(r) => format!("{r:.6}"),
            None => "-".to_string(),
        };
        let volt = match self.voltage_v {
            Some(v) => format!("{v:.6}"),
            None => "-".to_string(),
        };
        let pct = match self.battery_pct {
            Some(p) => p.to_string(),
            None => "-".to_string(),
        };
        format!(
            "ts={} seq={} phase={} x={:.6} y={:.6} a={:.6} period={:.6} \
             gx={} gy={} gz={} ax={} ay={} az={} \
             fsr={} cop={} ground={} lc={} rc={} \
             fallen={} risk={} v={} pct={} src={} loop={} walking={}",
            self.ts_ms,
            self.seq_applied,
            self.phase,
            self.latch_x,
            self.latch_y,
            self.latch_a,
            self.latch_period,
            self.gyro[0],
            self.gyro[1],
            self.gyro[2],
            self.accel[0],
            self.accel[1],
            self.accel[2],
            fsr,
            cop,
            u8::from(self.ground),
            u8::from(self.left_contact),
            u8::from(self.right_contact),
            self.fallen,
            risk,
            volt,
            pct,
            self.active_source,
            self.loop_ms,
            u8::from(self.walking),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_half_even_matches_python_round() {
        // (입력, python round() 결과)
        let cases = [
            (0.5, 0),
            (1.5, 2),
            (2.5, 2),
            (-0.5, 0),
            (-1.5, -2),
            (23.809523809523807, 24),
            (-4.3, -4),
            (100.0, 100),
        ];
        for (x, expected) in cases {
            assert_eq!(round_half_even(x), expected, "x={x}");
        }
    }

    #[test]
    fn battery_window() {
        assert_eq!(battery_from_dv(0), (None, None));
        assert_eq!(battery_from_dv(-5), (None, None));
        let (v, pct) = battery_from_dv(126);
        assert_eq!(v, Some(12.6));
        assert_eq!(pct, Some(100));
        let (_, pct) = battery_from_dv(104); // 창 아래 → 0 으로 클램프
        assert_eq!(pct, Some(0));
        let (_, pct) = battery_from_dv(131); // 창 위 → 100 으로 클램프
        assert_eq!(pct, Some(100));
    }

    #[test]
    fn malformed_inputs_are_dropped() {
        assert_eq!(parse_tel2(b""), None);
        assert_eq!(parse_tel2(b"TEL 1 2 3"), None);
        assert_eq!(parse_tel2(b"TEL2 1 2 3"), None); // 고정 14토큰 미달
    }
}
