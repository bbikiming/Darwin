//! 헤드 레이트 적분 — `MapGamepad` 머리부(F10)의 Rust 등가.
//!
//! 우스틱 = **레이트 제어**: 곡선 성형된 입력을 °/s 로 적분하고 입력 0 이면 직전 각을
//! 유지(hold). dt 는 호출자가 공급하고 상한([`g01::HEAD_INTEGRATE_DT_MAX_MS`])으로 이벤트
//! 공백 시 점프를 막는다. dt ≤ 0(획득 직후/리셋)이면 적분을 생략한다.

use crate::g01;
use crate::shape::shape_head_axis;

/// 적분된 머리 각 hold 상태 (pan/tilt, deg).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct HeadHold {
    pub pan: f64,
    pub tilt: f64,
}

impl HeadHold {
    /// 한 틱 적분 — `rx`/`ry`(우스틱 [-1,1]) × 레이트 × dt, ±클램프. `dt_ms ≤ 0` → 무동작.
    pub fn integrate(&mut self, rx: f64, ry: f64, dt_ms: f64) {
        if dt_ms <= 0.0 {
            return;
        }
        let dt_s = dt_ms.min(g01::HEAD_INTEGRATE_DT_MAX_MS as f64) / 1000.0;
        let pan_rate = g01::SIGN_PAN * shape_head_axis(rx);
        let tilt_rate = g01::SIGN_TILT * shape_head_axis(ry);
        self.pan = (self.pan + pan_rate * g01::HEAD_PAN_RATE_DPS * dt_s)
            .clamp(-g01::HEAD_PAN_CLAMP_DEG, g01::HEAD_PAN_CLAMP_DEG);
        self.tilt = (self.tilt + tilt_rate * g01::HEAD_TILT_RATE_DPS * dt_s)
            .clamp(-g01::HEAD_TILT_CLAMP_DEG, g01::HEAD_TILT_CLAMP_DEG);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_or_negative_dt_is_noop() {
        let mut h = HeadHold {
            pan: 5.0,
            tilt: -3.0,
        };
        h.integrate(1.0, 1.0, 0.0);
        h.integrate(1.0, 1.0, -50.0);
        assert_eq!(
            h,
            HeadHold {
                pan: 5.0,
                tilt: -3.0
            }
        );
    }

    #[test]
    fn neutral_stick_holds_angle() {
        let mut h = HeadHold {
            pan: 12.0,
            tilt: 7.0,
        };
        h.integrate(0.0, 0.0, 100.0);
        assert_eq!(
            h,
            HeadHold {
                pan: 12.0,
                tilt: 7.0
            }
        );
    }

    #[test]
    fn integrates_toward_clamp_and_saturates() {
        let mut h = HeadHold::default();
        // 풀 우스틱(rx=+1) → SIGN_PAN(−1)·rate 150°/s. 100ms → −15° 방향.
        h.integrate(1.0, 0.0, 100.0);
        assert!(h.pan < 0.0);
        // 장시간 적분 → ±클램프 포화.
        for _ in 0..200 {
            h.integrate(1.0, 0.0, 200.0);
        }
        assert!((h.pan + g01::HEAD_PAN_CLAMP_DEG).abs() < 1e-9);
    }

    #[test]
    fn dt_is_capped_to_max() {
        // dt 5000ms 가 그대로 적분되면 한 틱에 수백도 — 상한 200ms 로 제한되는지.
        let mut capped = HeadHold::default();
        capped.integrate(1.0, 0.0, 5000.0);
        let mut at_max = HeadHold::default();
        at_max.integrate(1.0, 0.0, g01::HEAD_INTEGRATE_DT_MAX_MS as f64);
        assert!((capped.pan - at_max.pan).abs() < 1e-9);
    }

    #[test]
    fn tilt_up_is_positive_sign() {
        // ry=−1(스틱 위, raw 아래=+ 부호 반전 후) → SIGN_TILT(−1)·shape(−1)=+ → tilt 상승.
        let mut h = HeadHold::default();
        h.integrate(0.0, -1.0, 100.0);
        assert!(h.tilt > 0.0);
    }
}
