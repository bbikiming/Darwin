//! 측정 보고 헬퍼 — 분위수·합격 판정(순수, 테스트 가능).
//!
//! 합격선(04 §2 W1): eff_hz ≥ 19 · E-STOP 내부 ≤ 150ms · (정지 계약 ≤320ms 는
//! 물리 거동 입회라 헤드리스 자동 판정 대상 아님 — §4.2). 여기 임계는 회귀 가드용
//! 이고, 최종 게이트 판정은 ACK 가 아니라 물리 거동이다(F9 교훈).

/// eff_hz 합격선 — 20Hz 송신에서 ACK 도달율(§2 W1).
pub const EFF_HZ_PASS: f64 = 19.0;
/// E-STOP 내부 지연 상한(ms) — 입력 이벤트 → 소켓 write(회귀 가드, 실측 기대 ~수 ms).
pub const ESTOP_INTERNAL_MAX_MS: f64 = 150.0;

/// 정렬된 표본의 p 분위(0..100) — nearest-rank. 빈 표본은 None.
pub fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (p / 100.0 * sorted.len() as f64).ceil() as usize;
    let idx = rank.saturating_sub(1).min(sorted.len() - 1);
    Some(sorted[idx])
}

/// 미정렬 표본을 복사·정렬해 p 분위 반환.
pub fn percentile_of(samples: &[f64], p: f64) -> Option<f64> {
    let mut v = samples.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    percentile(&v, p)
}

/// PASS/FAIL 라벨 — `ok` 가 true 면 PASS.
pub fn verdict(ok: bool) -> &'static str {
    if ok {
        "PASS"
    } else {
        "FAIL"
    }
}

/// eff_hz 합격 판정(≥ 19).
pub fn eff_hz_pass(eff_hz: f64) -> bool {
    eff_hz >= EFF_HZ_PASS
}

/// E-STOP 내부 지연 합격 판정(≤ 150ms).
pub fn estop_internal_pass(latency_ms: f64) -> bool {
    latency_ms <= ESTOP_INTERNAL_MAX_MS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentile_nearest_rank() {
        let s = [10.0, 20.0, 30.0, 40.0, 50.0];
        assert_eq!(percentile(&s, 50.0), Some(30.0));
        assert_eq!(percentile(&s, 95.0), Some(50.0));
        assert_eq!(percentile(&s, 0.0), Some(10.0));
        assert_eq!(percentile(&s, 100.0), Some(50.0));
        assert_eq!(percentile(&[], 50.0), None);
        assert_eq!(percentile(&[7.0], 95.0), Some(7.0));
    }

    #[test]
    fn percentile_of_sorts_first() {
        let unsorted = [50.0, 10.0, 40.0, 20.0, 30.0];
        assert_eq!(percentile_of(&unsorted, 50.0), Some(30.0));
    }

    #[test]
    fn verdicts() {
        assert!(eff_hz_pass(19.0));
        assert!(eff_hz_pass(20.0));
        assert!(!eff_hz_pass(18.9));
        assert!(estop_internal_pass(0.5));
        assert!(estop_internal_pass(150.0));
        assert!(!estop_internal_pass(150.1));
        assert_eq!(verdict(true), "PASS");
        assert_eq!(verdict(false), "FAIL");
    }
}
