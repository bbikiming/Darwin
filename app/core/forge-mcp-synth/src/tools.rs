//! MCP tools — 11개 함수 + JSON Schema 정의.
//!
//! PRD §9.2 명세 그대로. 각 tool 은 `Engine` 을 통해 `forge_core::synth` 를
//! 호출하고 결과를 사람이 읽는 텍스트로 반환.

use serde_json::{json, Value};
use thiserror::Error;

use forge_core::motion::{Motion, MotionPage, SafetyClass};
use forge_core::synth::library::PageLibrary;
use forge_core::synth::metadata::{PageMetadata, Tag};
use forge_core::synth::ops::layer::{layer_pages, LayerInputs, LayerParams};
use forge_core::synth::ops::mirror::{Mirror, MirrorParams};
use forge_core::synth::ops::morph::{Morph, MorphParams, MorphRatio};
use forge_core::synth::ops::mutate::{Mutate, MutateParams, Mutation};
use forge_core::synth::ops::procedural::{Curve, Procedural, ProceduralParams};
use forge_core::synth::ops::sequence::{Sequence, SequenceParams, DEFAULT_TRANSITION_MS};
use forge_core::synth::ops::SynthOp;
use forge_core::synth::provenance::{Manifest, ENGINE_VERSION};
use forge_core::synth::validator::{
    joint_limit::JointLimitValidator, self_collision::SelfCollisionValidator,
    static_stability::StaticStabilityValidator, velocity::VelocityValidator, Validator,
    ValidatorReport,
};

use crate::engine::{backup_path, Engine, EngineError};

/// Tool 호출 에러.
#[derive(Debug, Error)]
pub enum ToolError {
    /// 알 수 없는 tool 이름.
    #[error("unknown tool: {0}")]
    UnknownTool(String),
    /// 잘못된 / 누락된 argument.
    #[error("invalid argument: {0}")]
    BadArg(String),
    /// 페이지를 찾을 수 없음.
    #[error("page {0} not found in library")]
    PageNotFound(u16),
    /// 합성 op 실패.
    #[error("synth: {0}")]
    Synth(String),
    /// Validator 가 FAIL 을 반환.
    #[error("validation failed: {0}")]
    ValidationFailed(String),
    /// 엔진 에러.
    #[error(transparent)]
    Engine(#[from] EngineError),
    /// 파일 시스템 에러.
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    /// JSON 직렬화 에러.
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
}

/// MCP `tools/list` 응답용 — 11 tools 의 schema 정의.
pub fn tool_definitions() -> Vec<Value> {
    vec![
        tool_def(
            "library_search",
            "공식 카탈로그(OFFICIAL_CATALOG 16개) 페이지 검색. tag/safety 필터 지원.",
            json!({
                "type": "object",
                "properties": {
                    "tag": { "type": "string", "description": "필터할 태그 (예: 'kick', 'gesture')" },
                    "safety": { "type": "string", "enum": ["safe", "caution", "highrisk"] }
                }
            }),
        ),
        tool_def(
            "library_get",
            "특정 페이지 ID 의 MotionPage + 메타데이터 조회.",
            json!({
                "type": "object",
                "required": ["page_id"],
                "properties": {
                    "page_id": { "type": "integer", "minimum": 1, "maximum": 255 }
                }
            }),
        ),
        tool_def(
            "synth_sequence",
            "여러 페이지를 시간순으로 연결. 7 step 초과 시 next_page chain 으로 자동 분할.",
            json!({
                "type": "object",
                "required": ["page_ids"],
                "properties": {
                    "page_ids": { "type": "array", "items": { "type": "integer" } },
                    "transition_ms": { "type": "integer", "default": 800, "minimum": 0 },
                    "base_id": { "type": "integer", "default": 100 },
                    "name": { "type": "string" }
                }
            }),
        ),
        tool_def(
            "synth_layer",
            "상체/하체/머리 부위를 서로 다른 페이지에서 가져와 병합.",
            json!({
                "type": "object",
                "required": ["upper", "lower"],
                "properties": {
                    "upper": { "type": "integer" },
                    "lower": { "type": "integer" },
                    "head": { "type": "integer" }
                }
            }),
        ),
        tool_def(
            "synth_morph",
            "두 페이지 A·B 의 step 별 관절 가중합.",
            json!({
                "type": "object",
                "required": ["a", "b"],
                "properties": {
                    "a": { "type": "integer" },
                    "b": { "type": "integer" },
                    "ratio": { "type": "number", "minimum": 0.0, "maximum": 1.0, "default": 0.5 },
                    "progressive": { "type": "boolean", "default": false }
                }
            }),
        ),
        tool_def(
            "synth_mutate",
            "단일 페이지 변형. time_scale / speed_scale / amplitude / repeat / joint_offset 조합.",
            json!({
                "type": "object",
                "required": ["page_id"],
                "properties": {
                    "page_id": { "type": "integer" },
                    "time_scale": { "type": "number" },
                    "speed_scale": { "type": "number" },
                    "amplitude": { "type": "number" },
                    "repeat": { "type": "integer", "minimum": 1, "maximum": 255 },
                    "joint_offsets": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["joint_id", "delta"],
                            "properties": {
                                "joint_id": { "type": "integer", "minimum": 1, "maximum": 20 },
                                "delta": { "type": "integer" }
                            }
                        }
                    },
                    "new_id": { "type": "integer", "default": 100 },
                    "new_name": { "type": "string" }
                }
            }),
        ),
        tool_def(
            "synth_mirror",
            "좌·우 반전. page 12 (Right Kick) ↔ page 13 (Left Kick) ground truth.",
            json!({
                "type": "object",
                "required": ["page_id"],
                "properties": {
                    "page_id": { "type": "integer" },
                    "new_id": { "type": "integer", "default": 100 },
                    "new_name": { "type": "string" }
                }
            }),
        ),
        tool_def(
            "synth_procedural",
            "시작/끝 anchor + 궤적 함수 (linear/ease/sine/bezier) 로 step 생성.",
            json!({
                "type": "object",
                "required": ["anchor_start", "anchor_end"],
                "properties": {
                    "anchor_start": { "type": "integer" },
                    "anchor_end": { "type": "integer" },
                    "curve": { "type": "string", "enum": ["linear", "ease", "sine", "bezier"], "default": "linear" },
                    "sine_omega": { "type": "number", "default": 1.0 },
                    "sine_phase": { "type": "number", "default": 0.0 },
                    "num_steps": { "type": "integer", "minimum": 1, "maximum": 7, "default": 5 },
                    "play_time": { "type": "integer", "minimum": 1, "maximum": 255, "default": 16 }
                }
            }),
        ),
        tool_def(
            "validate",
            "Motion JSON 에 4-stage validator 실행 (JointLimit / Velocity / SelfCollision / StaticStability).",
            json!({
                "type": "object",
                "required": ["motion_json"],
                "properties": {
                    "motion_json": { "type": "string", "description": "Motion JSON 문자열 (Motion 컨테이너)" },
                    "single_foot_ok": { "type": "boolean", "default": false }
                }
            }),
        ),
        tool_def(
            "commit",
            "Motion JSON 의 첫 페이지를 motion_4096.bin 의 슬롯에 기록 + 자동 백업. validator FAIL 이면 거부.",
            json!({
                "type": "object",
                "required": ["motion_json", "slot"],
                "properties": {
                    "motion_json": { "type": "string" },
                    "slot": { "type": "integer", "minimum": 1, "maximum": 255 },
                    "no_backup": { "type": "boolean", "default": false },
                    "force": { "type": "boolean", "default": false },
                    "single_foot_ok": { "type": "boolean", "default": false }
                }
            }),
        ),
        tool_def(
            "preview",
            "Motion JSON 의 timeline ASCII 미리보기 + summary.",
            json!({
                "type": "object",
                "required": ["motion_json"],
                "properties": {
                    "motion_json": { "type": "string" },
                    "format": { "type": "string", "enum": ["ascii", "summary"], "default": "ascii" }
                }
            }),
        ),
    ]
}

fn tool_def(name: &str, description: &str, input_schema: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": input_schema
    })
}

/// MCP `tools/call` 디스패처.
pub fn call_tool(name: &str, args: &Value, engine: &Engine) -> Result<String, ToolError> {
    match name {
        "library_search" => tool_library_search(args, engine),
        "library_get" => tool_library_get(args, engine),
        "synth_sequence" => tool_synth_sequence(args, engine),
        "synth_layer" => tool_synth_layer(args, engine),
        "synth_morph" => tool_synth_morph(args, engine),
        "synth_mutate" => tool_synth_mutate(args, engine),
        "synth_mirror" => tool_synth_mirror(args, engine),
        "synth_procedural" => tool_synth_procedural(args, engine),
        "validate" => tool_validate(args, engine),
        "commit" => tool_commit(args, engine),
        "preview" => tool_preview(args),
        other => Err(ToolError::UnknownTool(other.to_string())),
    }
}

// ---------------------------------------------------------------------------
// arg parsing helpers
// ---------------------------------------------------------------------------

fn get_u16(args: &Value, key: &str) -> Result<u16, ToolError> {
    args.get(key)
        .and_then(|v| v.as_u64())
        .map(|v| v as u16)
        .ok_or_else(|| ToolError::BadArg(format!("missing '{key}' (integer)")))
}

fn get_u8(args: &Value, key: &str) -> Result<u8, ToolError> {
    args.get(key)
        .and_then(|v| v.as_u64())
        .map(|v| v as u8)
        .ok_or_else(|| ToolError::BadArg(format!("missing '{key}' (integer)")))
}

fn get_opt_u8(args: &Value, key: &str) -> Option<u8> {
    args.get(key).and_then(|v| v.as_u64()).map(|v| v as u8)
}

fn get_opt_u16(args: &Value, key: &str) -> Option<u16> {
    args.get(key).and_then(|v| v.as_u64()).map(|v| v as u16)
}

fn get_opt_f32(args: &Value, key: &str) -> Option<f32> {
    args.get(key).and_then(|v| v.as_f64()).map(|v| v as f32)
}

fn get_opt_str(args: &Value, key: &str) -> Option<String> {
    args.get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

fn get_opt_bool(args: &Value, key: &str) -> bool {
    args.get(key).and_then(|v| v.as_bool()).unwrap_or(false)
}

fn parse_safety(s: &str) -> Result<SafetyClass, ToolError> {
    match s.to_lowercase().as_str() {
        "safe" => Ok(SafetyClass::Safe),
        "caution" => Ok(SafetyClass::Caution),
        "highrisk" | "high_risk" | "high-risk" => Ok(SafetyClass::HighRisk),
        other => Err(ToolError::BadArg(format!("unknown safety '{other}'"))),
    }
}

fn parse_curve(args: &Value) -> Result<Curve, ToolError> {
    let name = args
        .get("curve")
        .and_then(|v| v.as_str())
        .unwrap_or("linear");
    let omega = get_opt_f32(args, "sine_omega").unwrap_or(1.0);
    let phase = get_opt_f32(args, "sine_phase").unwrap_or(0.0);
    match name.to_lowercase().as_str() {
        "linear" => Ok(Curve::Linear),
        "ease" | "easeinout" => Ok(Curve::EaseInOut),
        "sine" | "sin" => Ok(Curve::Sine { omega, phase }),
        "bezier" => Ok(Curve::Bezier {
            p1: (0.25, 0.1),
            p2: (0.75, 0.9),
        }),
        other => Err(ToolError::BadArg(format!(
            "unknown curve '{other}' (linear|ease|sine|bezier)"
        ))),
    }
}

fn fetch_page(lib: &PageLibrary, id: u16) -> Result<MotionPage, ToolError> {
    lib.get(id).cloned().ok_or(ToolError::PageNotFound(id))
}

fn motion_from_pages(pages: Vec<MotionPage>) -> Motion {
    Motion {
        version: 1,
        robot_generation: "op2".to_string(),
        pages,
    }
}

fn motion_to_json(motion: &Motion) -> Result<String, ToolError> {
    Ok(serde_json::to_string_pretty(motion)?)
}

// ---------------------------------------------------------------------------
// Tool 1: library_search
// ---------------------------------------------------------------------------

fn tool_library_search(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let tag = get_opt_str(args, "tag");
    let safety = get_opt_str(args, "safety");
    engine
        .with_library(|lib| {
            let mut ids = if let Some(t) = &tag {
                lib.by_tag(&Tag(t.clone()))
            } else if let Some(s) = &safety {
                match parse_safety(s) {
                    Ok(sc) => lib.by_safety(sc),
                    Err(_) => Vec::new(),
                }
            } else {
                lib.ids()
            };
            ids.sort_unstable();

            let mut output = String::new();
            output.push_str(&format!("# {} pages\n\n", ids.len()));
            for id in ids {
                let page = lib.get(id).expect("listed");
                let meta = lib.metadata(id);
                let display = meta
                    .and_then(|m| m.display_name.clone())
                    .unwrap_or_default();
                let tags: Vec<String> = meta
                    .map(|m| m.tags.iter().map(|t| t.0.clone()).collect())
                    .unwrap_or_default();
                output.push_str(&format!(
                    "- **{}**  `{}`  steps={}  safety={:?}  display=\"{}\"  tags=[{}]\n",
                    id,
                    page.name,
                    page.steps.len(),
                    page.safety_class,
                    display,
                    tags.join(", ")
                ));
            }
            output
        })
        .map_err(ToolError::from)
}

// ---------------------------------------------------------------------------
// Tool 2: library_get
// ---------------------------------------------------------------------------

fn tool_library_get(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let id = get_u16(args, "page_id")?;
    engine
        .with_library(|lib| -> Result<String, ToolError> {
            let page = fetch_page(lib, id)?;
            let meta = lib.metadata(id).cloned().unwrap_or_default();
            let motion = motion_from_pages(vec![page]);
            let mut out = motion_to_json(&motion)?;
            out.push_str("\n\n# Metadata\n");
            out.push_str(&serde_json::to_string_pretty(&meta)?);
            Ok(out)
        })
        .map_err(ToolError::from)?
}

// ---------------------------------------------------------------------------
// Tool 3: synth_sequence
// ---------------------------------------------------------------------------

fn tool_synth_sequence(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let ids: Vec<u8> = args
        .get("page_ids")
        .and_then(|v| v.as_array())
        .ok_or_else(|| ToolError::BadArg("missing 'page_ids' (array)".into()))?
        .iter()
        .map(|v| v.as_u64().unwrap_or(0) as u8)
        .collect();
    if ids.is_empty() {
        return Err(ToolError::BadArg("page_ids must not be empty".into()));
    }
    let transition_ms = get_opt_u16(args, "transition_ms").unwrap_or(DEFAULT_TRANSITION_MS);
    let base_id = get_opt_u8(args, "base_id").unwrap_or(100);
    let name = get_opt_str(args, "name");

    engine
        .with_library(|lib| -> Result<String, ToolError> {
            let pages: Vec<MotionPage> = ids
                .iter()
                .map(|&id| fetch_page(lib, id as u16))
                .collect::<Result<Vec<_>, _>>()?;
            let refs: Vec<&MotionPage> = pages.iter().collect();
            let op = Sequence;
            let params = SequenceParams {
                transition_ms,
                base_id,
                new_name: name,
            };
            let result = op
                .synthesize(&refs, &params)
                .map_err(|e| ToolError::Synth(e.to_string()))?;
            motion_to_json(&motion_from_pages(result))
        })
        .map_err(ToolError::from)?
}

// ---------------------------------------------------------------------------
// Tool 4: synth_layer
// ---------------------------------------------------------------------------

fn tool_synth_layer(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let upper_id = get_u16(args, "upper")?;
    let lower_id = get_u16(args, "lower")?;
    let head_id = get_opt_u16(args, "head");
    engine
        .with_library(|lib| -> Result<String, ToolError> {
            let upper = fetch_page(lib, upper_id)?;
            let lower = fetch_page(lib, lower_id)?;
            let head = head_id.map(|h| fetch_page(lib, h)).transpose()?;
            let inputs = LayerInputs {
                upper: Some(&upper),
                lower: Some(&lower),
                head: head.as_ref(),
            };
            let result = layer_pages(&inputs, &LayerParams::default())
                .map_err(|e| ToolError::Synth(e.to_string()))?;
            motion_to_json(&motion_from_pages(vec![result]))
        })
        .map_err(ToolError::from)?
}

// ---------------------------------------------------------------------------
// Tool 5: synth_morph
// ---------------------------------------------------------------------------

fn tool_synth_morph(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let a_id = get_u16(args, "a")?;
    let b_id = get_u16(args, "b")?;
    let ratio = get_opt_f32(args, "ratio").unwrap_or(0.5);
    let progressive = get_opt_bool(args, "progressive");
    engine
        .with_library(|lib| -> Result<String, ToolError> {
            let a = fetch_page(lib, a_id)?;
            let b = fetch_page(lib, b_id)?;
            let op = Morph;
            let params = MorphParams {
                ratio: if progressive {
                    MorphRatio::Progressive
                } else {
                    MorphRatio::Constant(ratio)
                },
            };
            let result = op
                .synthesize(&[&a, &b], &params)
                .map_err(|e| ToolError::Synth(e.to_string()))?;
            motion_to_json(&motion_from_pages(result))
        })
        .map_err(ToolError::from)?
}

// ---------------------------------------------------------------------------
// Tool 6: synth_mutate
// ---------------------------------------------------------------------------

fn tool_synth_mutate(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let id = get_u16(args, "page_id")?;
    let mut mutations: Vec<Mutation> = Vec::new();
    if let Some(k) = get_opt_f32(args, "time_scale") {
        mutations.push(Mutation::TimeScale { factor: k });
    }
    if let Some(k) = get_opt_f32(args, "speed_scale") {
        mutations.push(Mutation::SpeedScale { factor: k });
    }
    if let Some(k) = get_opt_f32(args, "amplitude") {
        mutations.push(Mutation::AmplitudeScale {
            joint_ids: (1u8..=20).collect(),
            factor: k,
        });
    }
    if let Some(r) = get_opt_u8(args, "repeat") {
        mutations.push(Mutation::Repeat { value: r });
    }
    if let Some(arr) = args.get("joint_offsets").and_then(|v| v.as_array()) {
        for entry in arr {
            let joint_id = entry
                .get("joint_id")
                .and_then(|v| v.as_u64())
                .ok_or_else(|| ToolError::BadArg("joint_offsets.joint_id".into()))?
                as u8;
            let delta = entry
                .get("delta")
                .and_then(|v| v.as_i64())
                .ok_or_else(|| ToolError::BadArg("joint_offsets.delta".into()))?
                as i16;
            mutations.push(Mutation::JointOffset { joint_id, delta });
        }
    }
    if mutations.is_empty() {
        return Err(ToolError::BadArg(
            "at least one of time_scale/speed_scale/amplitude/repeat/joint_offsets required".into(),
        ));
    }
    let new_id = get_opt_u8(args, "new_id").unwrap_or(100);
    let new_name = get_opt_str(args, "new_name");
    engine
        .with_library(|lib| -> Result<String, ToolError> {
            let page = fetch_page(lib, id)?;
            let op = Mutate;
            let params = MutateParams {
                mutations,
                new_id: Some(new_id),
                new_name,
            };
            let result = op
                .synthesize(&[&page], &params)
                .map_err(|e| ToolError::Synth(e.to_string()))?;
            motion_to_json(&motion_from_pages(result))
        })
        .map_err(ToolError::from)?
}

// ---------------------------------------------------------------------------
// Tool 7: synth_mirror
// ---------------------------------------------------------------------------

fn tool_synth_mirror(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let id = get_u16(args, "page_id")?;
    let new_id = get_opt_u8(args, "new_id").unwrap_or(100);
    let new_name = get_opt_str(args, "new_name");
    engine
        .with_library(|lib| -> Result<String, ToolError> {
            let page = fetch_page(lib, id)?;
            let op = Mirror;
            let params = MirrorParams {
                new_id: Some(new_id),
                new_name,
            };
            let result = op
                .synthesize(&[&page], &params)
                .map_err(|e| ToolError::Synth(e.to_string()))?;
            motion_to_json(&motion_from_pages(result))
        })
        .map_err(ToolError::from)?
}

// ---------------------------------------------------------------------------
// Tool 8: synth_procedural
// ---------------------------------------------------------------------------

fn tool_synth_procedural(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let start_id = get_u16(args, "anchor_start")?;
    let end_id = get_u16(args, "anchor_end")?;
    let num_steps = get_opt_u8(args, "num_steps").unwrap_or(5).clamp(1, 7);
    let play_time = get_opt_u8(args, "play_time").unwrap_or(16);
    let curve = parse_curve(args)?;
    engine
        .with_library(|lib| -> Result<String, ToolError> {
            let a = fetch_page(lib, start_id)?;
            let b = fetch_page(lib, end_id)?;
            let op = Procedural;
            let params = ProceduralParams {
                curve,
                num_steps,
                play_time,
            };
            let result = op
                .synthesize(&[&a, &b], &params)
                .map_err(|e| ToolError::Synth(e.to_string()))?;
            motion_to_json(&motion_from_pages(result))
        })
        .map_err(ToolError::from)?
}

// ---------------------------------------------------------------------------
// Tool 9: validate
// ---------------------------------------------------------------------------

fn validators_pipeline(page: &MotionPage, single_foot_ok: bool) -> [ValidatorReport; 4] {
    let v1 = JointLimitValidator;
    let v2 = VelocityValidator;
    let v3 = SelfCollisionValidator;
    let meta = PageMetadata {
        single_foot_ok,
        ..Default::default()
    };
    let v4 = StaticStabilityValidator::with_metadata(meta);
    [
        v1.validate(page).expect("v1 deterministic"),
        v2.validate(page).expect("v2 deterministic"),
        v3.validate(page).expect("v3 deterministic"),
        v4.validate(page).expect("v4 deterministic"),
    ]
}

fn format_validator_results(reports: &[ValidatorReport]) -> String {
    let mut s = String::new();
    for r in reports {
        let stage = format!("{:?}", r.stage());
        match r {
            ValidatorReport::Pass(_) => s.push_str(&format!("  ✓ {stage:<16} PASS\n")),
            ValidatorReport::Warn(_, m) => s.push_str(&format!("  ! {stage:<16} WARN  {m}\n")),
            ValidatorReport::Fail(_, m) => s.push_str(&format!("  ✗ {stage:<16} FAIL  {m}\n")),
        }
    }
    s
}

fn parse_motion_json(args: &Value) -> Result<Motion, ToolError> {
    let s = args
        .get("motion_json")
        .and_then(|v| v.as_str())
        .ok_or_else(|| ToolError::BadArg("missing 'motion_json' (string)".into()))?;
    Motion::from_json(s).map_err(|e| ToolError::BadArg(format!("invalid motion_json: {e}")))
}

fn tool_validate(args: &Value, _engine: &Engine) -> Result<String, ToolError> {
    let motion = parse_motion_json(args)?;
    let single_foot_ok = get_opt_bool(args, "single_foot_ok");
    let mut out = String::new();
    let mut any_fail = false;
    for page in &motion.pages {
        out.push_str(&format!("# Page {} '{}'\n", page.id, page.name));
        let reports = validators_pipeline(page, single_foot_ok);
        if reports.iter().any(|r| r.is_fail()) {
            any_fail = true;
        }
        out.push_str(&format_validator_results(&reports));
    }
    if any_fail {
        out.push_str("\n**Overall: FAIL** — commit blocked.\n");
    } else {
        out.push_str("\n**Overall: PASS** — all pages cleared 4-stage validation.\n");
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Tool 10: commit
// ---------------------------------------------------------------------------

fn tool_commit(args: &Value, engine: &Engine) -> Result<String, ToolError> {
    let motion = parse_motion_json(args)?;
    if motion.pages.len() != 1 {
        return Err(ToolError::BadArg(format!(
            "commit accepts exactly 1 page, got {}",
            motion.pages.len()
        )));
    }
    let slot = get_u8(args, "slot")?;
    if slot == 0 {
        return Err(ToolError::BadArg("slot 0 is reserved".into()));
    }
    let single_foot_ok = get_opt_bool(args, "single_foot_ok");
    let no_backup = get_opt_bool(args, "no_backup");
    let force = get_opt_bool(args, "force");

    let page = &motion.pages[0];

    // 1. validator 통과해야 commit.
    let reports = validators_pipeline(page, single_foot_ok);
    if reports.iter().any(|r| r.is_fail()) {
        let summary = format_validator_results(&reports);
        return Err(ToolError::ValidationFailed(format!(
            "page failed validation:\n{summary}\nPass `single_foot_ok=true` for HighRisk pages."
        )));
    }

    let bin_path = engine
        .bin_path
        .as_ref()
        .ok_or_else(|| ToolError::BadArg("commit requires bin path configured".into()))?
        .clone();
    if !bin_path.exists() {
        return Err(ToolError::BadArg(format!(
            "bin file not found: {}",
            bin_path.display()
        )));
    }

    // 2. 백업
    let mut report = String::new();
    if !no_backup {
        let backup = backup_path(&bin_path);
        std::fs::copy(&bin_path, &backup)?;
        report.push_str(&format!("✓ backup → {}\n", backup.display()));
    }

    // 3. 슬롯 점유 확인
    let raws = forge_core::motion::read_bin4096_file(&bin_path)
        .map_err(|e| ToolError::BadArg(format!("read bin: {e}")))?;
    let existing = raws.iter().find(|r| r.index == slot);
    if let Some(r) = existing {
        if !r.is_empty() && !force {
            return Err(ToolError::BadArg(format!(
                "slot {slot} occupied by '{}' — pass force=true to overwrite",
                r.name
            )));
        }
    }

    // 4. 페이지 byte 직렬화
    let bytes = encode_page_to_raw(page);
    let mut data = std::fs::read(&bin_path)?;
    let offset = (slot as usize) * 512;
    if offset + 512 > data.len() {
        return Err(ToolError::BadArg(format!(
            "bin size {} too small for slot {slot}",
            data.len()
        )));
    }
    data[offset..offset + 512].copy_from_slice(&bytes);
    std::fs::write(&bin_path, data)?;
    report.push_str(&format!(
        "✓ wrote page '{}' (id={}) to slot {} of {}\n",
        page.name,
        page.id,
        slot,
        bin_path.display()
    ));

    // 5. Manifest sidecar
    let manifest = Manifest::new(slot as u16, page.name.clone(), "mcp_commit").with_input(page);
    let manifest_path = bin_path.with_extension(format!("slot{slot}.manifest.json"));
    std::fs::write(&manifest_path, manifest.to_json_pretty()?)?;
    report.push_str(&format!("✓ manifest → {}\n", manifest_path.display()));
    report.push_str(&format!("  engine_version={ENGINE_VERSION}\n"));

    // 라이브러리 캐시 reload (다음 호출이 새 페이지를 보도록).
    engine.reload()?;
    Ok(report)
}

/// `MotionPage` → 512-byte raw page payload — ROBOTIS Action 호환.
///
/// **Phase G8 (Codex audit follow-up, 2026-05-15)**: 마지막 `set_action_checksum`
/// 호출 추가. 누락 시 `Action::LoadPage` (Action.cpp:239-253) 가 페이지를 reset 으로
/// wipe → MCP 로 commit 한 모션이 실 로봇에서 사라지는 P0 데이터 손실 버그.
fn encode_page_to_raw(page: &MotionPage) -> [u8; 512] {
    use forge_core::synth::library::{
        set_action_checksum, HEADER_OFFSET_ACCEL, HEADER_OFFSET_EXIT, HEADER_OFFSET_NEXT,
        HEADER_OFFSET_REPEAT, HEADER_OFFSET_SCHEDULE, HEADER_OFFSET_SLOPE, HEADER_OFFSET_SPEED,
        HEADER_OFFSET_STEPNUM, HEADER_SIZE, STEP_SIZE, TIME_BASE_SCHEDULE,
    };

    let mut buf = [0u8; 512];
    let name_bytes = page.name.as_bytes();
    let n = name_bytes.len().min(14);
    buf[..n].copy_from_slice(&name_bytes[..n]);

    // ROBOTIS Action.h PAGEHEADER (line 41-59) 오프셋 — synth/library 공통 const 사용.
    buf[HEADER_OFFSET_REPEAT] = page.repeat;
    buf[HEADER_OFFSET_SCHEDULE] = TIME_BASE_SCHEDULE;
    buf[HEADER_OFFSET_STEPNUM] = page.steps.len() as u8;
    buf[HEADER_OFFSET_SPEED] = page.speed;
    buf[HEADER_OFFSET_ACCEL] = page.accel;
    buf[HEADER_OFFSET_NEXT] = page.next_page;
    buf[HEADER_OFFSET_EXIT] = page.exit_page;
    for (i, &c) in page.compliance.iter().enumerate().take(31) {
        buf[HEADER_OFFSET_SLOPE + i] = c;
    }
    // Steps: 64 byte 각, 최대 7.
    for (s_idx, step) in page.steps.iter().take(7).enumerate() {
        let base = HEADER_SIZE + s_idx * STEP_SIZE;
        for (i, &pos) in step.positions.iter().enumerate().take(31) {
            let off = base + i * 2;
            buf[off] = (pos & 0xFF) as u8;
            buf[off + 1] = (pos >> 8) as u8;
        }
        buf[base + 62] = step.pause_time;
        buf[base + 63] = step.play_time;
    }

    // Phase G8 — 모든 필드 set 한 후 마지막 단계로 checksum 계산.
    set_action_checksum(&mut buf);
    buf
}

// ---------------------------------------------------------------------------
// Tool 11: preview
// ---------------------------------------------------------------------------

fn tool_preview(args: &Value) -> Result<String, ToolError> {
    let motion = parse_motion_json(args)?;
    let format = get_opt_str(args, "format").unwrap_or_else(|| "ascii".to_string());
    match format.to_lowercase().as_str() {
        "summary" => Ok(preview_summary(&motion)),
        // "ascii" (기본) 또는 기타 — ASCII timeline 으로 fall through.
        _ => Ok(preview_ascii(&motion)),
    }
}

fn preview_summary(motion: &Motion) -> String {
    let total_steps: usize = motion.pages.iter().map(|p| p.steps.len()).sum();
    let total_ms: u32 = motion
        .pages
        .iter()
        .flat_map(|p| p.steps.iter())
        .map(|s| s.play_ms() as u32 + s.pause_ms() as u32)
        .sum();
    format!(
        "pages={}  total_steps={}  total_ms={}  ({:.2}s)",
        motion.pages.len(),
        total_steps,
        total_ms,
        total_ms as f32 / 1000.0
    )
}

fn preview_ascii(motion: &Motion) -> String {
    let mut out = String::new();
    for page in &motion.pages {
        out.push_str(&format!(
            "═══ Page {} '{}' ({} step, speed={}, accel={}) ═══\n",
            page.id,
            page.name,
            page.steps.len(),
            page.speed,
            page.accel
        ));
        let mut elapsed: u32 = 0;
        for (i, step) in page.steps.iter().enumerate() {
            let play_ms = step.play_ms() as u32;
            let pause_ms = step.pause_ms() as u32;
            elapsed += play_ms + pause_ms;
            out.push_str(&format!(
                "  step {i}: t+{elapsed:>5}ms  play={play_ms:>4}ms  pause={pause_ms:>4}ms\n"
            ));
            // **Phase G8 (Codex audit follow-up, 2026-05-15)**: ROBOTIS 공식 joint ID
            // 1:1 (slot 0 reserved). 이전 [0/12/19] off-by-one fix.
            let r_shoulder = step.positions[1] & 0x0FFF;
            let r_hip_pitch = step.positions[11] & 0x0FFF;
            let r_knee = step.positions[13] & 0x0FFF;
            let head_tilt = step.positions[20] & 0x0FFF;
            out.push_str(&format!(
                "          R_SH={r_shoulder:>4} R_HIP={r_hip_pitch:>4} R_KNEE={r_knee:>4} HEAD={head_tilt:>4}\n"
            ));
        }
        if page.next_page > 0 {
            out.push_str(&format!("  → chain to page {}\n", page.next_page));
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Tests — pure logic, in-memory engine
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn engine_with_bin() -> Engine {
        Engine::new_default()
    }

    fn engine_in_memory() -> Engine {
        Engine::new_in_memory()
    }

    #[test]
    fn tool_definitions_has_required_keys() {
        let defs = tool_definitions();
        assert!(defs.len() >= 11);
        for tool in defs {
            assert!(tool["name"].is_string());
            assert!(tool["description"].is_string());
            assert!(tool["inputSchema"].is_object());
        }
    }

    #[test]
    fn unknown_tool_errors() {
        let e = engine_in_memory();
        let r = call_tool("does_not_exist", &json!({}), &e);
        assert!(matches!(r, Err(ToolError::UnknownTool(_))));
    }

    #[test]
    fn library_search_returns_pages_when_bin_present() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let out = call_tool("library_search", &json!({}), &e).unwrap();
        assert!(out.contains("Stand Up"));
        assert!(out.contains("Right Kick"));
    }

    #[test]
    fn library_search_by_safety_filter() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let out = call_tool("library_search", &json!({"safety": "highrisk"}), &e).unwrap();
        assert!(out.contains("Right Kick"));
        assert!(out.contains("Left Kick"));
        assert!(!out.contains("Stand Up"));
    }

    #[test]
    fn library_get_returns_motion_json_plus_metadata() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let out = call_tool("library_get", &json!({"page_id": 1}), &e).unwrap();
        assert!(out.contains("\"name\":"));
        assert!(out.contains("init"));
        assert!(out.contains("# Metadata"));
    }

    #[test]
    fn library_get_missing_page_errors() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let r = call_tool("library_get", &json!({"page_id": 200}), &e);
        assert!(matches!(r, Err(ToolError::PageNotFound(200))));
    }

    #[test]
    fn synth_mirror_returns_motion_json() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let out = call_tool(
            "synth_mirror",
            &json!({"page_id": 12, "new_id": 100, "new_name": "lk_synth"}),
            &e,
        )
        .unwrap();
        assert!(out.contains("\"name\":"));
        assert!(out.contains("lk_synth"));
        // 결과를 다시 parsing 가능해야 함
        let motion: Motion = Motion::from_json(&out).expect("parseable JSON");
        assert_eq!(motion.pages.len(), 1);
        assert_eq!(motion.pages[0].id, 100);
    }

    #[test]
    fn synth_sequence_produces_chain_when_overflow() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        // walkready(9, 1 step) + rk(12, 7 step) + walkready(9, 1 step) = 9 step
        // → 2 페이지 chain
        let out = call_tool(
            "synth_sequence",
            &json!({
                "page_ids": [9, 12, 9],
                "transition_ms": 0,
                "base_id": 200,
                "name": "test_routine"
            }),
            &e,
        )
        .unwrap();
        let motion: Motion = Motion::from_json(&out).unwrap();
        assert_eq!(motion.pages.len(), 2);
        assert_eq!(motion.pages[0].id, 200);
        assert_eq!(motion.pages[0].next_page, 201);
        assert_eq!(motion.pages[1].next_page, 0);
    }

    #[test]
    fn synth_mutate_time_scale_doubles_play_time() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let out = call_tool(
            "synth_mutate",
            &json!({"page_id": 1, "time_scale": 2.0, "new_id": 110}),
            &e,
        )
        .unwrap();
        let motion: Motion = Motion::from_json(&out).unwrap();
        assert_eq!(motion.pages[0].id, 110);
        // page 1 의 play_time = 125, 두 배 = 250
        assert_eq!(motion.pages[0].steps[0].play_time, 250);
    }

    #[test]
    fn synth_mutate_requires_at_least_one_mutation() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let r = call_tool("synth_mutate", &json!({"page_id": 1}), &e);
        assert!(matches!(r, Err(ToolError::BadArg(_))));
    }

    #[test]
    fn synth_morph_returns_motion_with_steps() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        // page 1 init (2 step) ↔ page 9 walkready (1 step)
        // morph 은 min(steps) = 1 step 결과.
        let out = call_tool("synth_morph", &json!({"a": 1, "b": 9, "ratio": 0.5}), &e).unwrap();
        let motion: Motion = Motion::from_json(&out).unwrap();
        assert_eq!(motion.pages.len(), 1);
        assert_eq!(motion.pages[0].steps.len(), 1);
    }

    #[test]
    fn synth_procedural_with_sine_curve_returns_steps() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let out = call_tool(
            "synth_procedural",
            &json!({
                "anchor_start": 9,
                "anchor_end": 1,
                "curve": "sine",
                "num_steps": 5
            }),
            &e,
        )
        .unwrap();
        let motion: Motion = Motion::from_json(&out).unwrap();
        assert_eq!(motion.pages[0].steps.len(), 5);
    }

    #[test]
    fn synth_layer_combines_three_regions() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        // upper=hi(4), lower=walkready(9), head=ok(2)
        let out = call_tool(
            "synth_layer",
            &json!({"upper": 4, "lower": 9, "head": 2}),
            &e,
        )
        .unwrap();
        let motion: Motion = Motion::from_json(&out).unwrap();
        assert_eq!(motion.pages.len(), 1);
    }

    #[test]
    fn validate_passes_for_stand_up() {
        let e = engine_with_bin();
        if !e.bin_exists() {
            return;
        }
        let lib_out = call_tool("library_get", &json!({"page_id": 1}), &e).unwrap();
        // library_get 의 출력에서 motion JSON 부분만 추출 (# Metadata 전).
        let json_part = lib_out.split("\n\n# Metadata").next().unwrap();
        let r = call_tool(
            "validate",
            &json!({"motion_json": json_part, "single_foot_ok": false}),
            &e,
        )
        .unwrap();
        assert!(r.contains("PASS"));
        assert!(r.contains("Overall: PASS"));
    }

    #[test]
    fn preview_summary_reports_total_seconds() {
        let e = engine_in_memory();
        let mut page = MotionPage::default();
        page.steps.clear();
        page.steps.push(forge_core::motion::MotionStep {
            positions: [2048; 31],
            pause_time: 0,
            play_time: 125,
        });
        let motion = motion_from_pages(vec![page]);
        let json = motion_to_json(&motion).unwrap();
        let r = call_tool(
            "preview",
            &json!({"motion_json": json, "format": "summary"}),
            &e,
        )
        .unwrap();
        // play_time 125 raw × 8 ms = 1000 ms
        assert!(r.contains("total_ms=1000"), "got: {r}");
        assert!(r.contains("(1.00s)"));
    }

    #[test]
    fn preview_ascii_includes_timeline() {
        let e = engine_in_memory();
        let mut page = MotionPage::default();
        page.steps.clear();
        page.steps.push(forge_core::motion::MotionStep {
            positions: [2048; 31],
            pause_time: 0,
            play_time: 16,
        });
        let json = motion_to_json(&motion_from_pages(vec![page])).unwrap();
        let r = call_tool("preview", &json!({"motion_json": json}), &e).unwrap();
        assert!(r.contains("step 0"));
        // Phase G8 (Codex audit follow-up, 2026-05-15) — 라벨이 R_SH/R_HIP/R_KNEE/HEAD 로 통일.
        assert!(r.contains("R_SH="));
    }

    #[test]
    fn validate_with_bad_motion_json_errors() {
        let e = engine_in_memory();
        let r = call_tool("validate", &json!({"motion_json": "not json"}), &e);
        assert!(matches!(r, Err(ToolError::BadArg(_))));
    }

    #[test]
    fn commit_without_bin_errors() {
        // In-memory engine 은 bin_path 가 None → commit 거부.
        let e = Engine::new_in_memory();
        // 2026-05-17 clippy field_reassign_with_default fix.
        let mut page = MotionPage {
            id: 100,
            name: "test".to_string(),
            ..Default::default()
        };
        page.steps[0].positions = [2048; 31];
        let json = motion_to_json(&motion_from_pages(vec![page])).unwrap();
        let r = call_tool(
            "commit",
            &json!({"motion_json": json, "slot": 100, "no_backup": true}),
            &e,
        );
        assert!(r.is_err());
    }

    #[test]
    fn encode_page_to_raw_size_512() {
        // 2026-05-17 clippy field_reassign_with_default fix.
        let page = MotionPage {
            name: "init".to_string(),
            ..Default::default()
        };
        let raw = encode_page_to_raw(&page);
        assert_eq!(raw.len(), 512);
        // ROBOTIS schedule offset 16 = 0x0A
        assert_eq!(raw[16], 0x0A);
        // stepnum offset 20 = page.steps.len()
        assert_eq!(raw[20], page.steps.len() as u8);
    }

    /// **Phase G8 (Codex audit follow-up, 2026-05-15)**: encoded buffer 가 ROBOTIS
    /// `VerifyChecksum` (Action.cpp:30-44) 의 byte-sum==0xff 조건 통과. 누락 시
    /// `LoadPage` 가 페이지를 reset 으로 wipe — P0 데이터 손실.
    #[test]
    fn encode_page_passes_robotis_verify_checksum() {
        use forge_core::synth::library::verify_action_checksum;
        // 2026-05-17 clippy field_reassign_with_default fix.
        let page = MotionPage {
            name: "init".to_string(),
            ..Default::default()
        };
        let mut buf = [0u8; 512];
        buf.copy_from_slice(&encode_page_to_raw(&page));
        assert!(
            verify_action_checksum(&buf),
            "encoded buffer must pass ROBOTIS VerifyChecksum"
        );
    }

    /// **Phase G8 (Codex audit follow-up, 2026-05-15)**: preview_ascii 가 ROBOTIS
    /// 공식 joint ID 와 1:1 인덱싱 사용 — 이전엔 [0/12/19] off-by-one 으로 사용자가
    /// "R_KNEE=X" 라벨로 본 값이 실제로는 R_HIP_PITCH 였음.
    ///
    /// 검증 방법: positions 의 각 ID 슬롯에 알려진 unique 값을 set 한 후,
    /// preview output 에 그 값이 올바른 라벨로 나타나는지 확인.
    #[test]
    fn preview_ascii_uses_official_joint_indexing() {
        use forge_core::motion::Motion;
        // 2026-05-17 clippy field_reassign_with_default fix.
        let mut page = MotionPage {
            id: 1,
            name: "test".to_string(),
            ..Default::default()
        };
        // 각 관절에 unique 식별 값 — output 에서 라벨 매칭 검증용. 12-bit 범위 (0..4095).
        page.steps[0].positions[1] = 1111; // R_SH_PITCH
        page.steps[0].positions[11] = 2222; // R_HIP_PITCH
        page.steps[0].positions[13] = 3333; // R_KNEE
        page.steps[0].positions[20] = 2700; // HEAD_TILT (12-bit max=4095)
        let motion = Motion {
            version: 1,
            robot_generation: "op2".to_string(),
            pages: vec![page],
        };
        let out = preview_ascii(&motion);

        // 라벨 + 값 짝이 정확히 표시돼야 함.
        assert!(
            out.contains("R_SH=1111"),
            "preview missing R_SH=1111: {out}"
        );
        assert!(
            out.contains("R_HIP=2222"),
            "preview missing R_HIP=2222: {out}"
        );
        assert!(
            out.contains("R_KNEE=3333"),
            "preview missing R_KNEE=3333: {out}"
        );
        assert!(
            out.contains("HEAD=2700"),
            "preview missing HEAD=2700: {out}"
        );
        // 회귀 가드 — 이전 off-by-one 인덱스가 다시 들어오면 fail.
        assert!(
            !out.contains("R_KNEE=2222"),
            "회귀: R_KNEE 가 positions[11] (R_HIP_PITCH 값) 을 표시 — off-by-one 부활"
        );
    }
}
