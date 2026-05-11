//! S9-12 — Synthesis 풀 파이프라인 통합 테스트.
//!
//! 입력 → 1개 이상의 합성 op → 4-stage validator → 통과 시 출력.
//! 본 모듈은 production runtime API 가 아닌 **테스트 + 데모 helper** 만 제공.

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use crate::motion::SafetyClass;
    use crate::synth::library::PageLibrary;
    use crate::synth::metadata::PageMetadata;
    use crate::synth::ops::mirror::{Mirror, MirrorParams};
    use crate::synth::ops::SynthOp;
    use crate::synth::validator::{
        joint_limit::JointLimitValidator, self_collision::SelfCollisionValidator,
        static_stability::StaticStabilityValidator, velocity::VelocityValidator, Validator,
        ValidatorReport,
    };

    fn official_bin_path() -> PathBuf {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin");
        p
    }

    /// 4 단계 validator 모두 page 에 적용. 첫 Fail 에서 중단.
    fn run_all_validators(
        page: &crate::motion::MotionPage,
        metadata: Option<&PageMetadata>,
    ) -> Vec<ValidatorReport> {
        let mut reports = Vec::new();

        let v1 = JointLimitValidator;
        let r1 = v1.validate(page).expect("V1");
        let r1_fail = r1.is_fail();
        reports.push(r1);
        if r1_fail {
            return reports;
        }

        let v2 = VelocityValidator;
        let r2 = v2.validate(page).expect("V2");
        let r2_fail = r2.is_fail();
        reports.push(r2);
        if r2_fail {
            return reports;
        }

        let v3 = SelfCollisionValidator;
        let r3 = v3.validate(page).expect("V3");
        let r3_fail = r3.is_fail();
        reports.push(r3);
        if r3_fail {
            return reports;
        }

        let v4 = match metadata {
            Some(m) => StaticStabilityValidator::with_metadata(m.clone()),
            None => StaticStabilityValidator::default(),
        };
        let r4 = v4.validate(page).expect("V4");
        reports.push(r4);

        reports
    }

    /// 풀 파이프라인 — Right Kick page 12 → Mirror → 4-stage validation.
    ///
    /// HighRisk 분류라 single_foot_ok=false → V4 가 fail 일 수 있음 (좌·우 hip_pitch
    /// 차이 큰 자세). 그러나 metadata 를 single_foot_ok=true 로 주면 V4 통과.
    #[test]
    fn pipeline_mirror_right_kick_with_single_foot_ok_passes_all() {
        let path = official_bin_path();
        if !path.exists() {
            eprintln!("skip: {} not present", path.display());
            return;
        }
        let lib = PageLibrary::from_official_bin(&path).expect("load");
        let right_kick = lib.get(12).expect("page 12");
        let metadata = lib.metadata(12).expect("page 12 meta").clone();

        // single_foot_ok 강제 (kick 은 한발 지지 자세)
        let mut single_foot_meta = metadata.clone();
        single_foot_meta.single_foot_ok = true;

        // 1. Mirror op
        let op = Mirror;
        let mirrored = op
            .synthesize(&[right_kick], &MirrorParams::default())
            .expect("mirror");
        assert_eq!(mirrored.len(), 1);
        let mirrored_page = &mirrored[0];

        // 2. 4-stage validation with single_foot_ok=true
        let reports = run_all_validators(mirrored_page, Some(&single_foot_meta));
        for r in &reports {
            assert!(
                !r.is_fail(),
                "validator stage {:?} failed: {:?}",
                r,
                r
            );
        }
        assert_eq!(reports.len(), 4, "expected all 4 validators to run");
    }

    /// 풀 파이프라인 — Stand Up page 1 (Safe, 양발 지지). 모든 validator 통과.
    #[test]
    fn pipeline_stand_up_passes_all_validators() {
        let path = official_bin_path();
        if !path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&path).expect("load");
        let stand_up = lib.get(1).expect("page 1");
        let metadata = lib.metadata(1).expect("page 1 meta");

        // mirror 안 함 — 원본 그대로 validation
        let reports = run_all_validators(stand_up, Some(metadata));
        for r in &reports {
            assert!(
                !r.is_fail(),
                "Stand Up should pass all stages, but {:?} failed",
                r
            );
        }
    }

    /// 풀 파이프라인 — 안전 분류별 페이지가 카탈로그 16개 모두 V1/V2/V3 통과.
    /// V4 는 HighRisk 페이지만 fail 가능 (양발 지지 가정 시 hip 비대칭이라).
    #[test]
    fn pipeline_v1_v2_v3_pass_all_catalog_pages() {
        let path = official_bin_path();
        if !path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&path).expect("load");

        for id in lib.ids() {
            let page = lib.get(id).expect("page");
            let v1 = JointLimitValidator;
            let v2 = VelocityValidator;
            let v3 = SelfCollisionValidator;
            assert!(
                !v1.validate(page).expect("v1").is_fail(),
                "page {} fails V1",
                id
            );
            assert!(
                !v2.validate(page).expect("v2").is_fail(),
                "page {} fails V2",
                id
            );
            assert!(
                !v3.validate(page).expect("v3").is_fail(),
                "page {} fails V3 ({:?})",
                id,
                v3.validate(page)
            );
        }
    }

    /// 풀 파이프라인 — HighRisk 분류 페이지는 default V4 (양발 가정) 에서 fail
    /// (단발 자세). single_foot_ok 메타 명시 시 V4 도 pass.
    #[test]
    fn pipeline_high_risk_pages_require_single_foot_metadata() {
        let path = official_bin_path();
        if !path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&path).expect("load");
        for id in lib.by_safety(SafetyClass::HighRisk) {
            let page = lib.get(id).expect("page");
            let mut meta = lib.metadata(id).expect("meta").clone();
            // single_foot_ok=true 라야 V4 통과
            meta.single_foot_ok = true;
            let v4 = StaticStabilityValidator::with_metadata(meta);
            assert!(
                !v4.validate(page).expect("v4").is_fail(),
                "HighRisk page {} should pass V4 when single_foot_ok=true",
                id
            );
        }
    }
}
