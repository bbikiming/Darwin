//! V4 — 정적 안정성 검증.
//!
//! 본구현 (S9-10 V4). PRD §5.3 V4, §8.5.
//!
//! ## 단순화된 휴리스틱 (v1)
//!
//! 본격적인 CoM 계산은 robot URDF + 링크 질량 + IK 가 필요해 비용이 큼. v1 은
//! 다음의 **proxy** 를 사용:
//!
//! 1. **양발 지지 (`single_foot_ok = false`)** — 양 다리 hip_pitch 의 raw 차이가
//!    임계 이내인지 확인. 차이가 크면 한 발이 들려 있는 상태로 판단.
//! 2. **단일 발 지지 허용 (`single_foot_ok = true`)** — 검사 skip (모든 step 통과).
//!
//! 임계값은 walkReady (l_hip_pitch=+65°, r_hip_pitch=-65°) 의 절대값 차이 130° 를
//! 기준으로 약간 보수적으로 설정 (raw 1500).
//!
//! 단순화된 v1 의 한계는 PRD §13 Open Questions 에 명시되며, 본격 CoM 검사는
//! 후속 Sprint 에서 보강.

use super::{Validator, ValidatorReport, ValidatorStage};
use crate::joint::JointId;
use crate::motion::MotionPage;
use crate::synth::error::SynthError;
use crate::synth::metadata::PageMetadata;
use crate::synth::Result;

const SKIP_MARKER: u16 = 32767;
const POSITION_MASK: u16 = 0x0FFF;

/// 양발 지지 자세에서 좌·우 hip_pitch 의 최대 raw 차이.
///
/// walkReady 의 r=-65°/l=+65° 차이가 130° ≈ raw 1480 → 약간 여유 1700.
pub const MAX_HIP_PITCH_DIFF_RAW: u16 = 1700;

/// V4 — Static stability validator (단순화 v1).
#[derive(Debug, Default)]
pub struct StaticStabilityValidator {
    /// 호출자가 제공하는 메타데이터. `None` 이면 default(양발 지지 가정).
    pub metadata: Option<PageMetadata>,
}

impl Validator for StaticStabilityValidator {
    fn stage(&self) -> ValidatorStage {
        ValidatorStage::StaticStability
    }

    fn validate(&self, page: &MotionPage) -> Result<ValidatorReport> {
        let single_foot_ok = self
            .metadata
            .as_ref()
            .map(|m| m.single_foot_ok)
            .unwrap_or(false);

        if single_foot_ok {
            // 한 발 지지 허용 — proxy 검사 skip
            return Ok(ValidatorReport::Pass(self.stage()));
        }

        let mut violations: Vec<String> = Vec::new();
        for (i, step) in page.steps.iter().enumerate() {
            let r = step.positions[JointId::RHipPitch as usize];
            let l = step.positions[JointId::LHipPitch as usize];
            if r == SKIP_MARKER || l == SKIP_MARKER {
                continue;
            }
            let r_val = (r & POSITION_MASK) as i32;
            let l_val = (l & POSITION_MASK) as i32;
            let diff = (r_val - l_val).unsigned_abs() as u16;
            if diff > MAX_HIP_PITCH_DIFF_RAW {
                violations.push(format!(
                    "step {}: hip_pitch L/R diff {} > {} raw — likely single-foot",
                    i, diff, MAX_HIP_PITCH_DIFF_RAW
                ));
            }
        }

        if violations.is_empty() {
            Ok(ValidatorReport::Pass(self.stage()))
        } else {
            Ok(ValidatorReport::Fail(self.stage(), violations.join("; ")))
        }
    }
}

impl StaticStabilityValidator {
    /// 메타데이터를 명시하는 생성자.
    pub fn with_metadata(metadata: PageMetadata) -> Self {
        Self {
            metadata: Some(metadata),
        }
    }

    /// `PageLibrary::metadata` 에서 가져와 검증.
    pub fn validate_with_metadata(
        page: &MotionPage,
        metadata: &PageMetadata,
    ) -> Result<ValidatorReport> {
        Self::with_metadata(metadata.clone()).validate(page)
    }
}

// 사용 사이트가 Result 를 다시 wrap 하지 않도록.
#[allow(dead_code)]
fn _unused() -> Result<()> {
    Err(SynthError::Other("placeholder".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::motion::page::NUM_JOINTS_IN_STEP;
    use crate::motion::{MotionPage, MotionStep, SafetyClass};

    fn page_with_hip_pitch(r_raw: u16, l_raw: u16) -> MotionPage {
        let mut p = MotionPage::default();
        p.safety_class = SafetyClass::Safe;
        let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
        positions[JointId::RHipPitch as usize] = r_raw;
        positions[JointId::LHipPitch as usize] = l_raw;
        p.steps = vec![MotionStep {
            positions,
            pause_time: 0,
            play_time: 16,
        }];
        p
    }

    #[test]
    fn stage_is_static_stability() {
        assert_eq!(
            StaticStabilityValidator::default().stage(),
            ValidatorStage::StaticStability
        );
    }

    #[test]
    fn symmetric_two_foot_passes() {
        // r=2000, l=2100 → diff 100 << threshold
        let v = StaticStabilityValidator::default();
        let p = page_with_hip_pitch(2000, 2100);
        assert!(matches!(
            v.validate(&p).unwrap(),
            ValidatorReport::Pass(_)
        ));
    }

    #[test]
    fn large_asymmetric_fails_two_foot_assumption() {
        // r=200, l=3900 → diff 3700 > 1700 threshold
        let v = StaticStabilityValidator::default();
        let p = page_with_hip_pitch(200, 3900);
        let report = v.validate(&p).unwrap();
        assert!(report.is_fail(), "expected Fail, got {:?}", report);
    }

    #[test]
    fn single_foot_ok_metadata_skips_check() {
        let meta = PageMetadata {
            single_foot_ok: true,
            ..Default::default()
        };
        let v = StaticStabilityValidator::with_metadata(meta);
        // 매우 비대칭이지만 single_foot_ok=true 이라 통과
        let p = page_with_hip_pitch(200, 3900);
        assert!(matches!(
            v.validate(&p).unwrap(),
            ValidatorReport::Pass(_)
        ));
    }

    #[test]
    fn skip_marker_is_ignored() {
        let v = StaticStabilityValidator::default();
        let p = page_with_hip_pitch(SKIP_MARKER, 3900);
        assert!(matches!(
            v.validate(&p).unwrap(),
            ValidatorReport::Pass(_)
        ));
    }
}
