//! 합성 결과의 provenance manifest.
//!
//! 결과 페이지마다 sidecar `.provenance.json` 으로 저장되어 재현 / 감사 추적을
//! 보장한다. PRD §7.4 참조.
//!
//! # 의존성 정책
//!
//! 본 모듈은 `forge-core` 의 기존 workspace 의존성 (`serde`, `serde_json`) 만
//! 사용한다. 진짜 SHA-256 (`sha2` crate) 은 4b5672a 머지 + Sprint 10 시점에
//! 추가될 예정. 그 전까지는 std `DefaultHasher` (SipHash 1-3) 로 produce 한
//! 64-bit digest 를 hex prefix `siphash13:` 로 표기해 진짜 sha256 과
//! 시각적으로 구분한다 (PRD §17 충돌 회피 약속).

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::motion::MotionPage;
use crate::synth::validator::ValidatorReport;

/// 본 엔진의 의미 버전. 합성 알고리즘 변경 시 minor 이상 증가.
pub const ENGINE_VERSION: &str = "0.1.0-skeleton";

/// 입력 페이지의 식별 digest.
///
/// 머지 전 placeholder: `siphash13:` prefix + 16 hex chars (u64).
/// 머지 후 `sha256:` prefix + 64 hex chars 로 업그레이드 예정.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputDigest {
    /// 입력 페이지 ID (reference library 기준).
    pub page_id: u16,
    /// 페이지 이름 (사람이 읽기 위함).
    pub page_name: String,
    /// 컨텐츠 digest. 형식: `{algo}:{hex}`.
    pub digest: String,
}

impl InputDigest {
    /// 페이지로부터 digest 생성. 머지 전 SipHash 1-3 사용.
    pub fn from_page(page: &MotionPage) -> Self {
        Self {
            page_id: page.id as u16,
            page_name: page.name.clone(),
            digest: format!("siphash13:{:016x}", siphash13_of_page(page)),
        }
    }
}

/// Validator 단계별 결과 요약. 인간 / 기계가 모두 읽기 좋게 string 보존.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidatorReportEntry {
    /// 단계 이름 (e.g. `"JointLimit"`).
    pub stage: String,
    /// 결과 코드 (`"PASS"` | `"WARN"` | `"FAIL"`).
    pub outcome: String,
    /// 사람이 읽는 메시지 (WARN / FAIL 인 경우). PASS 면 빈 문자열.
    pub message: String,
}

impl From<ValidatorReport> for ValidatorReportEntry {
    fn from(r: ValidatorReport) -> Self {
        let stage = format!("{:?}", r.stage());
        match r {
            ValidatorReport::Pass(_) => Self {
                stage,
                outcome: "PASS".to_string(),
                message: String::new(),
            },
            ValidatorReport::Warn(_, msg) => Self {
                stage,
                outcome: "WARN".to_string(),
                message: msg,
            },
            ValidatorReport::Fail(_, msg) => Self {
                stage,
                outcome: "FAIL".to_string(),
                message: msg,
            },
        }
    }
}

/// 합성 결과 추적용 manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    /// 출력 페이지 ID (`motion_4096.bin` slot 1..=255).
    pub page_id: u16,
    /// 출력 페이지 이름.
    pub page_name: String,
    /// 생성 시각 (UNIX epoch ms). 사람이 읽으려면 [`Manifest::created_iso8601`].
    pub created_epoch_ms: u64,
    /// 엔진 버전 (semver).
    pub engine_version: String,
    /// 사용한 합성 연산자 (e.g. `"sequence"`, `"mirror"`).
    pub operator: String,
    /// 입력 reference 페이지 digest 목록.
    pub inputs: Vec<InputDigest>,
    /// 합성 recipe (TOML 원문). 사용자가 declarative 로 제공한 경우.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recipe_toml: Option<String>,
    /// 4단계 validator 결과.
    pub validator_results: Vec<ValidatorReportEntry>,
    /// Claude 세션 ID (있다면). `/synth` 슬래시로 호출된 경우.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claude_session: Option<String>,
}

impl Manifest {
    /// 새 manifest 빌더 시작. 필수 필드만 채우고 나머지는 default.
    pub fn new(page_id: u16, page_name: impl Into<String>, operator: impl Into<String>) -> Self {
        Self {
            page_id,
            page_name: page_name.into(),
            created_epoch_ms: current_epoch_ms(),
            engine_version: ENGINE_VERSION.to_string(),
            operator: operator.into(),
            inputs: Vec::new(),
            recipe_toml: None,
            validator_results: Vec::new(),
            claude_session: None,
        }
    }

    /// 입력 페이지를 manifest 에 추가. digest 자동 계산.
    pub fn with_input(mut self, page: &MotionPage) -> Self {
        self.inputs.push(InputDigest::from_page(page));
        self
    }

    /// 여러 입력 페이지 일괄 추가.
    pub fn with_inputs<'a, I: IntoIterator<Item = &'a MotionPage>>(mut self, pages: I) -> Self {
        for p in pages {
            self.inputs.push(InputDigest::from_page(p));
        }
        self
    }

    /// Recipe TOML 첨부.
    pub fn with_recipe(mut self, toml: impl Into<String>) -> Self {
        self.recipe_toml = Some(toml.into());
        self
    }

    /// Validator 결과 추가.
    pub fn with_validator_result(mut self, report: ValidatorReport) -> Self {
        self.validator_results.push(report.into());
        self
    }

    /// 여러 validator 결과 일괄 추가.
    pub fn with_validator_results<I: IntoIterator<Item = ValidatorReport>>(
        mut self,
        reports: I,
    ) -> Self {
        for r in reports {
            self.validator_results.push(r.into());
        }
        self
    }

    /// Claude 세션 ID 첨부.
    pub fn with_claude_session(mut self, session: impl Into<String>) -> Self {
        self.claude_session = Some(session.into());
        self
    }

    /// 생성 시각을 ISO-8601 UTC string 으로 변환.
    pub fn created_iso8601(&self) -> String {
        epoch_ms_to_iso8601(self.created_epoch_ms)
    }

    /// 어떤 validator 라도 FAIL 인지 여부.
    pub fn has_validator_failure(&self) -> bool {
        self.validator_results.iter().any(|e| e.outcome == "FAIL")
    }

    /// 모든 validator 가 PASS 인지 여부.
    pub fn all_validators_passed(&self) -> bool {
        !self.validator_results.is_empty()
            && self.validator_results.iter().all(|e| e.outcome == "PASS")
    }

    /// JSON 직렬화 (사람이 읽는 pretty 형식).
    pub fn to_json_pretty(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// JSON 역직렬화.
    pub fn from_json(s: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(s)
    }

    /// 파일에 manifest 를 기록. 부모 디렉토리는 사전 생성되어 있어야 한다.
    pub fn write_to_path(&self, path: &std::path::Path) -> std::io::Result<()> {
        let json = self
            .to_json_pretty()
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        std::fs::write(path, json)
    }

    /// 파일에서 manifest 로드.
    pub fn read_from_path(path: &std::path::Path) -> std::io::Result<Self> {
        let s = std::fs::read_to_string(path)?;
        Self::from_json(&s).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn current_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// epoch ms → ISO-8601 UTC string (e.g. `2026-05-12T00:00:00.000Z`).
///
/// 외부 crate 없이 std 만 사용한 단순 구현. Gregorian 정확.
fn epoch_ms_to_iso8601(ms: u64) -> String {
    let secs = (ms / 1000) as i64;
    let sub_ms = (ms % 1000) as u32;
    let (y, mo, d, h, mi, s) = epoch_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{sub_ms:03}Z")
}

/// UNIX epoch seconds → (year, month, day, hour, minute, second), UTC.
fn epoch_to_ymdhms(mut secs: i64) -> (i32, u32, u32, u32, u32, u32) {
    let day_sec = 86_400i64;
    let mut days = secs.div_euclid(day_sec);
    secs = secs.rem_euclid(day_sec);
    let h = (secs / 3600) as u32;
    let mi = ((secs % 3600) / 60) as u32;
    let s = (secs % 60) as u32;

    // 1970-01-01 = Thursday. Civil-from-days (Howard Hinnant 알고리즘).
    days += 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let doe = (days - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if mo <= 2 { y + 1 } else { y };
    (y as i32, mo, d, h, mi, s)
}

/// `MotionPage` 의 의미적 컨텐츠 hash (SipHash 1-3).
///
/// 머지 후 `sha2::Sha256` 으로 교체 예정. 현재 구현은 동일 페이지에 대해
/// 동일 hash 를 보장하지만 cryptographic strength 는 없다.
fn siphash13_of_page(p: &MotionPage) -> u64 {
    let mut h = DefaultHasher::new();
    p.id.hash(&mut h);
    p.name.hash(&mut h);
    p.compliance.hash(&mut h);
    p.next_page.hash(&mut h);
    p.exit_page.hash(&mut h);
    p.repeat.hash(&mut h);
    p.speed.hash(&mut h);
    p.accel.hash(&mut h);
    for step in &p.steps {
        for pos in &step.positions {
            pos.hash(&mut h);
        }
        step.pause_time.hash(&mut h);
        step.play_time.hash(&mut h);
    }
    h.finish()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::synth::test_fixtures::{
        page_12_right_kick, page_13_left_kick, page_1_init, page_9_walkready,
    };
    use crate::synth::validator::ValidatorStage;

    #[test]
    fn engine_version_is_set() {
        assert!(!ENGINE_VERSION.is_empty());
        assert!(ENGINE_VERSION.contains("0.1.0"));
    }

    #[test]
    fn digest_is_deterministic_for_same_page() {
        let p1 = page_1_init();
        let p2 = page_1_init();
        let d1 = InputDigest::from_page(&p1);
        let d2 = InputDigest::from_page(&p2);
        assert_eq!(d1, d2, "동일 페이지는 동일 digest 를 생산해야 한다");
    }

    #[test]
    fn digest_differs_for_different_pages() {
        let d1 = InputDigest::from_page(&page_1_init());
        let d9 = InputDigest::from_page(&page_9_walkready());
        let d12 = InputDigest::from_page(&page_12_right_kick());
        let d13 = InputDigest::from_page(&page_13_left_kick());
        assert_ne!(d1.digest, d9.digest);
        assert_ne!(d1.digest, d12.digest);
        assert_ne!(d12.digest, d13.digest, "rk 와 lk 는 다른 digest");
    }

    #[test]
    fn digest_format_is_siphash13_prefixed() {
        let d = InputDigest::from_page(&page_1_init());
        assert!(d.digest.starts_with("siphash13:"));
        // hex part = 16 chars (u64).
        assert_eq!(d.digest.len(), "siphash13:".len() + 16);
    }

    #[test]
    fn builder_assembles_full_manifest() {
        let m = Manifest::new(100, "wave_then_sit", "sequence")
            .with_input(&page_1_init())
            .with_input(&page_16_stand_up_inline())
            .with_recipe("op = \"sequence\"\ninputs = [1, 16]")
            .with_validator_result(ValidatorReport::Pass(ValidatorStage::JointLimit))
            .with_validator_result(ValidatorReport::Pass(ValidatorStage::Velocity))
            .with_validator_result(ValidatorReport::Pass(ValidatorStage::SelfCollision))
            .with_validator_result(ValidatorReport::Pass(ValidatorStage::StaticStability))
            .with_claude_session("ses-test-01");

        assert_eq!(m.page_id, 100);
        assert_eq!(m.page_name, "wave_then_sit");
        assert_eq!(m.operator, "sequence");
        assert_eq!(m.inputs.len(), 2);
        assert!(m.recipe_toml.is_some());
        assert_eq!(m.validator_results.len(), 4);
        assert_eq!(m.claude_session.as_deref(), Some("ses-test-01"));
        assert!(m.all_validators_passed());
        assert!(!m.has_validator_failure());
    }

    fn page_16_stand_up_inline() -> MotionPage {
        // 의도적으로 fixture 와 별도 — builder 가 일반 페이지를 받음을 검증.
        let mut p = page_9_walkready();
        p.id = 16;
        p.name = "stand_up_inline".to_string();
        p
    }

    #[test]
    fn warn_and_fail_results_are_carried() {
        let m = Manifest::new(101, "risky", "morph")
            .with_validator_result(ValidatorReport::Pass(ValidatorStage::JointLimit))
            .with_validator_result(ValidatorReport::Warn(
                ValidatorStage::Velocity,
                "knee 82% of max".to_string(),
            ))
            .with_validator_result(ValidatorReport::Fail(
                ValidatorStage::SelfCollision,
                "knee hyperextension".to_string(),
            ));

        assert!(m.has_validator_failure());
        assert!(!m.all_validators_passed());
        assert_eq!(m.validator_results[1].outcome, "WARN");
        assert_eq!(m.validator_results[2].outcome, "FAIL");
        assert!(m.validator_results[2].message.contains("hyperextension"));
    }

    #[test]
    fn json_round_trip() {
        let m = Manifest::new(102, "test_round_trip", "mirror")
            .with_inputs([&page_12_right_kick(), &page_13_left_kick()])
            .with_validator_result(ValidatorReport::Pass(ValidatorStage::JointLimit));
        let json = m.to_json_pretty().expect("serialize");
        let m2 = Manifest::from_json(&json).expect("deserialize");
        assert_eq!(m, m2);
    }

    #[test]
    fn json_omits_none_fields() {
        let m = Manifest::new(103, "minimal", "sequence");
        let json = m.to_json_pretty().expect("serialize");
        assert!(!json.contains("recipe_toml"));
        assert!(!json.contains("claude_session"));
    }

    #[test]
    fn file_round_trip() {
        let tmp = std::env::temp_dir().join(format!(
            "manifest_test_{}.json",
            std::process::id()
        ));
        let m = Manifest::new(104, "file_test", "layer").with_input(&page_1_init());
        m.write_to_path(&tmp).expect("write");
        let loaded = Manifest::read_from_path(&tmp).expect("read");
        assert_eq!(m, loaded);
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn iso8601_known_epoch_values() {
        // 1970-01-01T00:00:00.000Z
        assert_eq!(epoch_ms_to_iso8601(0), "1970-01-01T00:00:00.000Z");
        // 2026-05-12T00:00:00.000Z → epoch seconds = 1778544000
        let s = epoch_ms_to_iso8601(1_778_544_000_000);
        assert_eq!(s, "2026-05-12T00:00:00.000Z");
        // 2000-01-01T00:00:00.000Z → 946684800
        assert_eq!(
            epoch_ms_to_iso8601(946_684_800_000),
            "2000-01-01T00:00:00.000Z"
        );
        // Sub-second 보존
        let s = epoch_ms_to_iso8601(1_778_544_000_123);
        assert_eq!(s, "2026-05-12T00:00:00.123Z");
    }

    #[test]
    fn created_iso8601_format_is_valid() {
        let m = Manifest::new(105, "now", "sequence");
        let iso = m.created_iso8601();
        // 형식: YYYY-MM-DDTHH:MM:SS.sssZ → 24 chars
        assert_eq!(iso.len(), 24, "got {iso}");
        assert!(iso.ends_with('Z'));
        assert_eq!(&iso[4..5], "-");
        assert_eq!(&iso[7..8], "-");
        assert_eq!(&iso[10..11], "T");
    }
}
