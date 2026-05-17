//! `forge synth ...` — Motion Synthesis CLI.
//!
//! Sprint 10 (S10-1 ~ S10-3). PRD-001 §6.3 명세 그대로.
//!
//! 모든 합성 결과는 `forge_core::motion::Motion` JSON 으로 export. `--out` 미지정
//! 시 stdout. `commit` 은 ROBOTIS `motion_4096.bin` 의 빈 슬롯에 페이지를 기록
//! (자동 백업 옵션 기본 on).

use std::path::PathBuf;

use clap::Subcommand;
use forge_core::motion::{Motion, MotionPage};
use forge_core::synth::library::PageLibrary;
use forge_core::synth::metadata::{BodyRegion, PageMetadata};
use forge_core::synth::ops::layer::{LayerInputs, LayerParams};
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

/// 기본 `motion_4096.bin` 경로 — workspace 내 research 디렉토리.
///
/// CARGO_MANIFEST_DIR = `app/core/forge-cli` → workspace root 까지 3 단계.
/// `FORGE_MOTION_BIN` env 또는 `--bin <path>` 옵션으로 override.
const DEFAULT_BIN_RELATIVE: &str =
    "../../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin";

#[derive(Subcommand, Debug)]
pub enum SynthCmd {
    /// 모션 라이브러리 조회 / 메타데이터.
    Library {
        /// 서브액션 — `list`, `tag`, `metadata`.
        #[command(subcommand)]
        action: LibraryAction,
    },

    /// **Sequence** — 페이지 시퀀스 연결. `forge synth sequence 1 9 16`.
    Sequence {
        /// 연결할 페이지 ID 목록 (1..=255).
        ids: Vec<u8>,
        /// 페이지 사이 bridge step 시간 (ms, 0 = bridge 생략).
        #[arg(long, default_value_t = DEFAULT_TRANSITION_MS)]
        transition_ms: u16,
        /// 결과의 시작 페이지 ID (`base_id`).
        #[arg(long, default_value_t = 100)]
        base_id: u8,
        /// 결과 페이지 이름.
        #[arg(long)]
        name: Option<String>,
        /// `motion_4096.bin` 경로 override.
        #[arg(long)]
        bin: Option<PathBuf>,
        /// 결과 JSON 출력 경로. None 이면 stdout.
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// **Layer** — 부위별 동시 합성. `forge synth layer --upper 4 --lower 9 --head 2`.
    Layer {
        /// 상체용 페이지 ID (관절 1..=6).
        #[arg(long)]
        upper: u8,
        /// 하체용 페이지 ID (관절 7..=18).
        #[arg(long)]
        lower: u8,
        /// 머리용 페이지 ID (관절 19..=20).
        #[arg(long)]
        head: Option<u8>,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
        /// 결과 JSON 출력 경로.
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// **Morph** — 두 페이지 사이 가중 평균. `forge synth morph 1 16 --ratio 0.5`.
    Morph {
        /// 페이지 A ID.
        a: u8,
        /// 페이지 B ID.
        b: u8,
        /// 보간 비율 (0=A, 1=B). `--progressive` 이면 무시.
        #[arg(long, default_value_t = 0.5)]
        ratio: f32,
        /// step 별로 t=i/(n-1) 의 smoothstep 적용.
        #[arg(long)]
        progressive: bool,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
        /// 결과 JSON 출력 경로.
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// **Mutate** — 단일 페이지 변형. 여러 mutation 동시 적용 가능.
    Mutate {
        /// 입력 페이지 ID.
        id: u8,
        /// 모든 step 의 play_time × factor.
        #[arg(long)]
        time_scale: Option<f32>,
        /// PAGEHEADER.speed × factor.
        #[arg(long)]
        speed_scale: Option<f32>,
        /// PAGEHEADER.repeat 새 값.
        #[arg(long)]
        repeat: Option<u8>,
        /// 모든 관절(1..=20)의 진폭을 중심점 기준 × factor.
        #[arg(long)]
        amplitude: Option<f32>,
        /// 특정 관절 (1..=20) 에 raw delta. 여러 번 가능 — `5=100 11=-50`.
        #[arg(long)]
        joint_offset: Vec<String>,
        /// 결과 페이지 ID.
        #[arg(long, default_value_t = 100)]
        new_id: u8,
        /// 결과 페이지 이름.
        #[arg(long)]
        name: Option<String>,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
        /// 결과 JSON 출력 경로.
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// **Mirror** — 좌우 반전. `forge synth mirror 12` → `lk_mirror`.
    Mirror {
        /// 입력 페이지 ID.
        id: u8,
        /// 결과 페이지 ID.
        #[arg(long, default_value_t = 100)]
        new_id: u8,
        /// 결과 페이지 이름.
        #[arg(long)]
        name: Option<String>,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
        /// 결과 JSON 출력 경로.
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// **Procedural** — anchor 사이 step 을 수학 함수로 생성.
    Procedural {
        /// 시작 anchor 페이지 ID.
        #[arg(long)]
        anchor_start: u8,
        /// 끝 anchor 페이지 ID.
        #[arg(long)]
        anchor_end: u8,
        /// 곡선 종류: `linear` | `ease` | `sine` | `bezier`.
        #[arg(long, default_value = "linear")]
        curve: String,
        /// 사인 곡선의 omega (사이클 수).
        #[arg(long, default_value_t = 1.0)]
        sine_omega: f32,
        /// 사인 곡선의 위상.
        #[arg(long, default_value_t = 0.0)]
        sine_phase: f32,
        /// 생성할 step 수 (1..=7).
        #[arg(long, default_value_t = 5)]
        num_steps: u8,
        /// 각 step play_time (raw, ms = ×8).
        #[arg(long, default_value_t = 16)]
        play_time: u8,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
        /// 결과 JSON 출력 경로.
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// **Validate** — page JSON 에 4-stage validator 실행.
    Validate {
        /// 검증할 page JSON 경로 (`Motion` 컨테이너 또는 단일 page).
        page: PathBuf,
        /// 단일발 지지 허용 (V4).
        #[arg(long)]
        single_foot_ok: bool,
    },

    /// **Commit** — page JSON 을 `motion_4096.bin` 슬롯에 기록 + 자동 백업.
    Commit {
        /// 입력 page JSON.
        page: PathBuf,
        /// 대상 슬롯 (1..=255). 빈 슬롯이어야 함 (기존 페이지 덮어쓰지 않음).
        #[arg(long)]
        slot: u8,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
        /// 백업 생략.
        #[arg(long)]
        no_backup: bool,
        /// 기존 페이지가 있어도 강제로 덮어쓰기.
        #[arg(long)]
        force: bool,
    },

    /// **Simulate** — page 의 timeline 을 텍스트로 미리보기.
    ///
    /// GIF/3D 렌더는 Sprint 11 (SwiftUI) 또는 Sprint 12 (claude integration)
    /// 시점에 추가. v1 은 ASCII timeline + validator 결과.
    Simulate {
        /// 시뮬레이션할 page JSON.
        page: PathBuf,
        /// 출력 형식 — `ascii` (기본) | `summary`.
        #[arg(long, default_value = "ascii")]
        format: String,
    },
}

#[derive(Subcommand, Debug)]
pub enum LibraryAction {
    /// 라이브러리에 있는 페이지 목록 출력.
    List {
        /// 태그로 필터 (예: `kick`, `gesture`).
        #[arg(long)]
        tag: Option<String>,
        /// 특정 ID 만 출력.
        #[arg(long)]
        id: Option<u16>,
        /// 안전 분류 필터: `safe` | `caution` | `highrisk`.
        #[arg(long)]
        safety: Option<String>,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
    },
    /// 페이지의 메타데이터 출력.
    Metadata {
        /// 페이지 ID.
        id: u16,
        /// `motion_4096.bin` 경로.
        #[arg(long)]
        bin: Option<PathBuf>,
    },
}

pub fn handle(cmd: SynthCmd) -> anyhow::Result<()> {
    match cmd {
        SynthCmd::Library { action } => handle_library(action),
        SynthCmd::Sequence {
            ids,
            transition_ms,
            base_id,
            name,
            bin,
            out,
        } => handle_sequence(
            &ids,
            transition_ms,
            base_id,
            name,
            bin.as_deref(),
            out.as_deref(),
        ),
        SynthCmd::Layer {
            upper,
            lower,
            head,
            bin,
            out,
        } => handle_layer(upper, lower, head, bin.as_deref(), out.as_deref()),
        SynthCmd::Morph {
            a,
            b,
            ratio,
            progressive,
            bin,
            out,
        } => handle_morph(a, b, ratio, progressive, bin.as_deref(), out.as_deref()),
        SynthCmd::Mutate {
            id,
            time_scale,
            speed_scale,
            repeat,
            amplitude,
            joint_offset,
            new_id,
            name,
            bin,
            out,
        } => handle_mutate(
            id,
            time_scale,
            speed_scale,
            repeat,
            amplitude,
            &joint_offset,
            new_id,
            name,
            bin.as_deref(),
            out.as_deref(),
        ),
        SynthCmd::Mirror {
            id,
            new_id,
            name,
            bin,
            out,
        } => handle_mirror(id, new_id, name, bin.as_deref(), out.as_deref()),
        SynthCmd::Procedural {
            anchor_start,
            anchor_end,
            curve,
            sine_omega,
            sine_phase,
            num_steps,
            play_time,
            bin,
            out,
        } => handle_procedural(
            anchor_start,
            anchor_end,
            &curve,
            sine_omega,
            sine_phase,
            num_steps,
            play_time,
            bin.as_deref(),
            out.as_deref(),
        ),
        SynthCmd::Validate {
            page,
            single_foot_ok,
        } => handle_validate(&page, single_foot_ok),
        SynthCmd::Commit {
            page,
            slot,
            bin,
            no_backup,
            force,
        } => handle_commit(&page, slot, bin.as_deref(), no_backup, force),
        SynthCmd::Simulate { page, format } => handle_simulate(&page, &format),
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn resolve_bin_path(bin: Option<&std::path::Path>) -> anyhow::Result<PathBuf> {
    if let Some(p) = bin {
        return Ok(p.to_path_buf());
    }
    if let Ok(env_path) = std::env::var("FORGE_MOTION_BIN") {
        return Ok(PathBuf::from(env_path));
    }
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push(DEFAULT_BIN_RELATIVE);
    Ok(p)
}

fn load_library(bin: Option<&std::path::Path>) -> anyhow::Result<PageLibrary> {
    let path = resolve_bin_path(bin)?;
    if !path.exists() {
        anyhow::bail!(
            "motion_4096.bin not found at {} — pass --bin <path> or set FORGE_MOTION_BIN",
            path.display()
        );
    }
    PageLibrary::from_official_bin(&path)
        .map_err(|e| anyhow::anyhow!("failed to load library from {}: {}", path.display(), e))
}

fn fetch_page(lib: &PageLibrary, id: u8) -> anyhow::Result<MotionPage> {
    lib.get(id as u16)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("page {id} not in OFFICIAL_CATALOG"))
}

fn write_motion_pages(pages: Vec<MotionPage>, out: Option<&std::path::Path>) -> anyhow::Result<()> {
    let motion = Motion {
        version: 1,
        robot_generation: "op2".to_string(),
        pages,
    };
    let json = motion
        .to_json_pretty()
        .map_err(|e| anyhow::anyhow!("serialize: {}", e))?;
    match out {
        Some(p) => {
            if let Some(parent) = p.parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent).ok();
                }
            }
            std::fs::write(p, json)?;
            eprintln!("✓ wrote {}", p.display());
        }
        None => println!("{}", json),
    }
    Ok(())
}

fn read_motion_pages(path: &std::path::Path) -> anyhow::Result<Vec<MotionPage>> {
    let s = std::fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("read {}: {}", path.display(), e))?;
    let motion: Motion =
        Motion::from_json(&s).map_err(|e| anyhow::anyhow!("parse motion JSON: {}", e))?;
    if motion.pages.is_empty() {
        anyhow::bail!("page JSON has no pages");
    }
    Ok(motion.pages)
}

fn parse_joint_offsets(specs: &[String]) -> anyhow::Result<Vec<Mutation>> {
    let mut out = Vec::new();
    for spec in specs {
        let (lhs, rhs) = spec
            .split_once('=')
            .ok_or_else(|| anyhow::anyhow!("--joint-offset '{}' must be ID=delta", spec))?;
        let joint_id: u8 = lhs
            .trim()
            .parse()
            .map_err(|e| anyhow::anyhow!("joint id '{}': {}", lhs, e))?;
        let delta: i16 = rhs
            .trim()
            .parse()
            .map_err(|e| anyhow::anyhow!("delta '{}': {}", rhs, e))?;
        out.push(Mutation::JointOffset { joint_id, delta });
    }
    Ok(out)
}

fn parse_curve(curve: &str, omega: f32, phase: f32) -> anyhow::Result<Curve> {
    match curve.to_lowercase().as_str() {
        "linear" => Ok(Curve::Linear),
        "ease" | "easeinout" | "smoothstep" => Ok(Curve::EaseInOut),
        "sine" | "sin" => Ok(Curve::Sine { omega, phase }),
        "bezier" => Ok(Curve::Bezier {
            p1: (0.25, 0.1),
            p2: (0.75, 0.9),
        }),
        other => anyhow::bail!("unknown curve '{}' (linear|ease|sine|bezier)", other),
    }
}

fn parse_safety(s: &str) -> anyhow::Result<forge_core::motion::SafetyClass> {
    use forge_core::motion::SafetyClass;
    match s.to_lowercase().as_str() {
        "safe" => Ok(SafetyClass::Safe),
        "caution" => Ok(SafetyClass::Caution),
        "highrisk" | "high_risk" | "high-risk" => Ok(SafetyClass::HighRisk),
        other => anyhow::bail!("unknown safety '{}' (safe|caution|highrisk)", other),
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handle_library(action: LibraryAction) -> anyhow::Result<()> {
    match action {
        LibraryAction::List {
            tag,
            id,
            safety,
            bin,
        } => {
            let lib = load_library(bin.as_deref())?;
            let mut ids: Vec<u16> = if let Some(t) = &tag {
                lib.by_tag(&forge_core::synth::metadata::Tag(t.clone()))
            } else if let Some(s) = &safety {
                lib.by_safety(parse_safety(s)?)
            } else {
                lib.ids()
            };
            if let Some(only) = id {
                ids.retain(|x| *x == only);
            }
            println!(
                "{:>4} {:>12} {:>8} {:>7}  {:<20}  {:<20}",
                "ID", "raw_name", "steps", "safety", "display_name", "tags"
            );
            println!("{:-<80}", "");
            for id in ids {
                let page = lib.get(id).expect("listed id");
                let meta = lib.metadata(id);
                let display = meta
                    .and_then(|m| m.display_name.clone())
                    .unwrap_or_default();
                let tags: String = meta
                    .map(|m| {
                        m.tags
                            .iter()
                            .map(|t| t.0.clone())
                            .collect::<Vec<_>>()
                            .join(",")
                    })
                    .unwrap_or_default();
                println!(
                    "{:>4} {:>12} {:>8} {:>7?}  {:<20}  {:<20}",
                    id,
                    page.name,
                    page.steps.len(),
                    page.safety_class,
                    display,
                    tags
                );
            }
            Ok(())
        }
        LibraryAction::Metadata { id, bin } => {
            let lib = load_library(bin.as_deref())?;
            let page = lib
                .get(id)
                .ok_or_else(|| anyhow::anyhow!("page {id} not in catalog"))?;
            let meta = lib.metadata(id).cloned().unwrap_or_default();
            println!("# Page {id}");
            println!("raw_name        = \"{}\"", page.name);
            println!("steps           = {}", page.steps.len());
            println!("speed / accel   = {} / {}", page.speed, page.accel);
            println!("next / exit     = {} / {}", page.next_page, page.exit_page);
            println!("safety_class    = {:?}", page.safety_class);
            if let Some(dn) = &meta.display_name {
                println!("display_name    = \"{}\"", dn);
            }
            println!(
                "tags            = [{}]",
                meta.tags
                    .iter()
                    .map(|t| format!("\"{}\"", t.0))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            println!(
                "body_regions    = {:?}",
                meta.body_regions
                    .iter()
                    .map(region_name)
                    .collect::<Vec<_>>()
            );
            if let Some(d) = meta.duration_ms {
                println!("duration_ms     = {d}");
            }
            if let Some(mp) = meta.mirror_pair {
                println!("mirror_pair     = {mp}");
            }
            println!("single_foot_ok  = {}", meta.single_foot_ok);
            Ok(())
        }
    }
}

fn region_name(r: &BodyRegion) -> &'static str {
    match r {
        BodyRegion::UpperBody => "upper",
        BodyRegion::LowerBody => "lower",
        BodyRegion::Head => "head",
    }
}

fn handle_sequence(
    ids: &[u8],
    transition_ms: u16,
    base_id: u8,
    name: Option<String>,
    bin: Option<&std::path::Path>,
    out: Option<&std::path::Path>,
) -> anyhow::Result<()> {
    if ids.is_empty() {
        anyhow::bail!("sequence: at least 1 page id required");
    }
    let lib = load_library(bin)?;
    let pages: Vec<MotionPage> = ids
        .iter()
        .map(|id| fetch_page(&lib, *id))
        .collect::<anyhow::Result<Vec<_>>>()?;
    let refs: Vec<&MotionPage> = pages.iter().collect();
    let op = Sequence;
    let params = SequenceParams {
        transition_ms,
        base_id,
        new_name: name,
    };
    let result = op
        .synthesize(&refs, &params)
        .map_err(|e| anyhow::anyhow!("sequence: {}", e))?;
    eprintln!(
        "✓ sequence: {} input(s) → {} page(s) (chain {}→...→{})",
        ids.len(),
        result.len(),
        result.first().map(|p| p.id).unwrap_or(0),
        result.last().map(|p| p.id).unwrap_or(0),
    );
    write_motion_pages(result, out)
}

fn handle_layer(
    upper: u8,
    lower: u8,
    head: Option<u8>,
    bin: Option<&std::path::Path>,
    out: Option<&std::path::Path>,
) -> anyhow::Result<()> {
    let lib = load_library(bin)?;
    let upper_page = fetch_page(&lib, upper)?;
    let lower_page = fetch_page(&lib, lower)?;
    let head_page = head.map(|h| fetch_page(&lib, h)).transpose()?;
    let refs_storage = (upper_page, lower_page, head_page);
    let inputs = LayerInputs {
        upper: Some(&refs_storage.0),
        lower: Some(&refs_storage.1),
        head: refs_storage.2.as_ref(),
    };
    let result = forge_core::synth::ops::layer::layer_pages(&inputs, &LayerParams::default())
        .map_err(|e| anyhow::anyhow!("layer: {}", e))?;
    eprintln!("✓ layer: 1 page ({} step)", result.steps.len());
    write_motion_pages(vec![result], out)
}

fn handle_morph(
    a: u8,
    b: u8,
    ratio: f32,
    progressive: bool,
    bin: Option<&std::path::Path>,
    out: Option<&std::path::Path>,
) -> anyhow::Result<()> {
    let lib = load_library(bin)?;
    let pa = fetch_page(&lib, a)?;
    let pb = fetch_page(&lib, b)?;
    let op = Morph;
    let params = MorphParams {
        ratio: if progressive {
            MorphRatio::Progressive
        } else {
            MorphRatio::Constant(ratio)
        },
    };
    let result = op
        .synthesize(&[&pa, &pb], &params)
        .map_err(|e| anyhow::anyhow!("morph: {}", e))?;
    eprintln!("✓ morph: ratio={ratio} progressive={progressive}");
    write_motion_pages(result, out)
}

#[allow(clippy::too_many_arguments)]
fn handle_mutate(
    id: u8,
    time_scale: Option<f32>,
    speed_scale: Option<f32>,
    repeat: Option<u8>,
    amplitude: Option<f32>,
    joint_offset: &[String],
    new_id: u8,
    name: Option<String>,
    bin: Option<&std::path::Path>,
    out: Option<&std::path::Path>,
) -> anyhow::Result<()> {
    let lib = load_library(bin)?;
    let page = fetch_page(&lib, id)?;
    let mut mutations: Vec<Mutation> = Vec::new();
    if let Some(k) = time_scale {
        mutations.push(Mutation::TimeScale { factor: k });
    }
    if let Some(k) = speed_scale {
        mutations.push(Mutation::SpeedScale { factor: k });
    }
    if let Some(r) = repeat {
        mutations.push(Mutation::Repeat { value: r });
    }
    if let Some(k) = amplitude {
        mutations.push(Mutation::AmplitudeScale {
            joint_ids: (1u8..=20).collect(),
            factor: k,
        });
    }
    mutations.extend(parse_joint_offsets(joint_offset)?);
    if mutations.is_empty() {
        anyhow::bail!("mutate: at least one mutation required (--time-scale / --speed-scale / --repeat / --amplitude / --joint-offset)");
    }
    let op = Mutate;
    let params = MutateParams {
        mutations,
        new_id: Some(new_id),
        new_name: name,
    };
    let result = op
        .synthesize(&[&page], &params)
        .map_err(|e| anyhow::anyhow!("mutate: {}", e))?;
    eprintln!("✓ mutate: page {id} → page {new_id}");
    write_motion_pages(result, out)
}

fn handle_mirror(
    id: u8,
    new_id: u8,
    name: Option<String>,
    bin: Option<&std::path::Path>,
    out: Option<&std::path::Path>,
) -> anyhow::Result<()> {
    let lib = load_library(bin)?;
    let page = fetch_page(&lib, id)?;
    let op = Mirror;
    let params = MirrorParams {
        new_id: Some(new_id),
        new_name: name,
    };
    let result = op
        .synthesize(&[&page], &params)
        .map_err(|e| anyhow::anyhow!("mirror: {}", e))?;
    eprintln!("✓ mirror: page {id} → page {new_id}");
    write_motion_pages(result, out)
}

#[allow(clippy::too_many_arguments)]
fn handle_procedural(
    anchor_start: u8,
    anchor_end: u8,
    curve: &str,
    sine_omega: f32,
    sine_phase: f32,
    num_steps: u8,
    play_time: u8,
    bin: Option<&std::path::Path>,
    out: Option<&std::path::Path>,
) -> anyhow::Result<()> {
    let lib = load_library(bin)?;
    let a = fetch_page(&lib, anchor_start)?;
    let b = fetch_page(&lib, anchor_end)?;
    let curve = parse_curve(curve, sine_omega, sine_phase)?;
    let op = Procedural;
    let params = ProceduralParams {
        curve,
        num_steps,
        play_time,
    };
    let result = op
        .synthesize(&[&a, &b], &params)
        .map_err(|e| anyhow::anyhow!("procedural: {}", e))?;
    eprintln!("✓ procedural: {num_steps} step(s) between {anchor_start} and {anchor_end}");
    write_motion_pages(result, out)
}

fn handle_validate(page_path: &std::path::Path, single_foot_ok: bool) -> anyhow::Result<()> {
    let pages = read_motion_pages(page_path)?;
    let mut overall_ok = true;
    for page in &pages {
        println!("# Page {} '{}'", page.id, page.name);
        let v1 = JointLimitValidator;
        let v2 = VelocityValidator;
        let v3 = SelfCollisionValidator;
        let meta = PageMetadata {
            single_foot_ok,
            ..Default::default()
        };
        let v4 = StaticStabilityValidator::with_metadata(meta);
        let reports = [
            v1.validate(page)
                .map_err(|e| anyhow::anyhow!("v1: {}", e))?,
            v2.validate(page)
                .map_err(|e| anyhow::anyhow!("v2: {}", e))?,
            v3.validate(page)
                .map_err(|e| anyhow::anyhow!("v3: {}", e))?,
            v4.validate(page)
                .map_err(|e| anyhow::anyhow!("v4: {}", e))?,
        ];
        for r in &reports {
            let stage = format!("{:?}", r.stage());
            match r {
                ValidatorReport::Pass(_) => println!("  ✓ {stage:<16} PASS"),
                ValidatorReport::Warn(_, m) => println!("  ! {stage:<16} WARN  {m}"),
                ValidatorReport::Fail(_, m) => {
                    println!("  ✗ {stage:<16} FAIL  {m}");
                    overall_ok = false;
                }
            }
        }
    }
    if !overall_ok {
        anyhow::bail!("validation failed — commit blocked");
    }
    eprintln!("✓ all pages pass 4-stage validation");
    Ok(())
}

fn handle_commit(
    page_path: &std::path::Path,
    slot: u8,
    bin: Option<&std::path::Path>,
    no_backup: bool,
    force: bool,
) -> anyhow::Result<()> {
    if slot == 0 {
        anyhow::bail!("slot 0 is reserved (empty)");
    }
    let pages = read_motion_pages(page_path)?;
    if pages.len() != 1 {
        anyhow::bail!(
            "commit accepts exactly 1 page; got {} — split chain into separate commits",
            pages.len()
        );
    }
    let bin_path = resolve_bin_path(bin)?;
    if !bin_path.exists() {
        anyhow::bail!("{} does not exist", bin_path.display());
    }

    // 백업 (자동, --no-backup 으로 비활성)
    if !no_backup {
        let ts = current_iso8601_for_filename();
        let backup_path = bin_path.with_extension(format!("bin.{ts}"));
        std::fs::copy(&bin_path, &backup_path)
            .map_err(|e| anyhow::anyhow!("backup {}: {}", backup_path.display(), e))?;
        eprintln!("✓ backup → {}", backup_path.display());
    }

    // 슬롯 점유 확인
    let raws = forge_core::motion::read_bin4096_file(&bin_path)
        .map_err(|e| anyhow::anyhow!("read bin: {}", e))?;
    let existing = raws.iter().find(|r| r.index == slot);
    if let Some(r) = existing {
        if !r.is_empty() && !force {
            anyhow::bail!(
                "slot {slot} occupied by '{}' — pass --force to overwrite",
                r.name
            );
        }
    }

    // 페이지를 raw byte 로 직렬화 (PAGEHEADER 64 + STEP × 7 = 512)
    let bytes = encode_page_to_raw(&pages[0], slot)?;

    // 전체 파일을 메모리에 읽고 슬롯 부분만 교체 후 다시 write.
    let mut data = std::fs::read(&bin_path)?;
    let offset = (slot as usize) * 512;
    if offset + 512 > data.len() {
        anyhow::bail!("bin file size {} too small for slot {slot}", data.len());
    }
    data[offset..offset + 512].copy_from_slice(&bytes);
    std::fs::write(&bin_path, data)?;
    eprintln!(
        "✓ wrote page '{}' to slot {} of {}",
        pages[0].name,
        slot,
        bin_path.display()
    );

    // Manifest sidecar 생성
    let manifest =
        Manifest::new(slot as u16, pages[0].name.clone(), "commit").with_input(&pages[0]);
    let manifest_path = bin_path.with_extension(format!("slot{slot}.manifest.json"));
    let json = manifest
        .to_json_pretty()
        .map_err(|e| anyhow::anyhow!("manifest: {}", e))?;
    std::fs::write(&manifest_path, json)?;
    eprintln!("✓ manifest → {}", manifest_path.display());
    eprintln!("  engine_version = {}", ENGINE_VERSION);

    Ok(())
}

fn current_iso8601_for_filename() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}

/// `MotionPage` → 512-byte `motion_4096.bin` 슬롯 페이로드.
///
/// PAGEHEADER offsets — `DARwIn-OP_ROBOTIS_v1.6.0/Framework/include/Action.h:41-59`
/// 와 `forge_core::synth::library::decode_raw_page` 가 사용하는 정식 offset.
///   name=0..13, reserved1=14, repeat=15, schedule=16, reserved2[3]=17..19,
///   stepnum=20, reserved3=21, speed=22, reserved4=23, accel=24, next=25, exit=26,
///   reserved5[4]=27..30, checksum=31, slope[31]=32..62, reserved6=63.
///
/// **Phase G1 (2026-05-14)**: 이전 버전은 stepnum=19/speed=21/accel=23/next=24/
/// exit=25/slope=28 로 1~4 byte 시프트돼 있었음 — `forge synth commit` 으로 쓰면
/// ROBOTIS Action player 가 stepnum/speed/accel/slope 를 잘못 읽어서 실제로
/// motion 이 깨질 수 있는 P0 버그였다. Codex audit 2026-05-14 에서 발견.
///
/// **Phase G8 (2026-05-15)**: schedule(offset 16) = `TIME_BASE_SCHEDULE` (0x0A) 추가
/// + 최종 checksum 계산 추가. 이전엔 둘 다 누락 → ROBOTIS `Action::LoadPage`
///   (Action.cpp:239-253) 의 `VerifyChecksum` 이 false → `ResetPage` 가 페이지를 0
///   으로 wipe → 사용자가 commit 한 모션이 실 로봇에서 빈 페이지로 사라지는 P0
///   데이터 손실 버그.
fn encode_page_to_raw(page: &MotionPage, slot: u8) -> anyhow::Result<[u8; 512]> {
    use forge_core::synth::library::{
        set_action_checksum, HEADER_OFFSET_ACCEL, HEADER_OFFSET_EXIT, HEADER_OFFSET_NEXT,
        HEADER_OFFSET_REPEAT, HEADER_OFFSET_SCHEDULE, HEADER_OFFSET_SLOPE, HEADER_OFFSET_SPEED,
        HEADER_OFFSET_STEPNUM, HEADER_SIZE, STEP_SIZE, TIME_BASE_SCHEDULE,
    };

    let mut buf = [0u8; 512];

    // name[0..13]
    let name_bytes = page.name.as_bytes();
    let n = name_bytes.len().min(14);
    buf[..n].copy_from_slice(&name_bytes[..n]);

    buf[HEADER_OFFSET_REPEAT] = page.repeat;
    // Phase G8 — 공식 motion_4096.bin 의 모든 페이지가 TIME_BASE.
    buf[HEADER_OFFSET_SCHEDULE] = TIME_BASE_SCHEDULE;
    buf[HEADER_OFFSET_STEPNUM] = page.steps.len() as u8;
    buf[HEADER_OFFSET_SPEED] = page.speed;
    buf[HEADER_OFFSET_ACCEL] = page.accel;
    buf[HEADER_OFFSET_NEXT] = page.next_page;
    buf[HEADER_OFFSET_EXIT] = page.exit_page;
    // slope[31] = 32..62 (31 byte). compliance 배열이 31 길이라 그대로 매핑.
    for (i, &c) in page.compliance.iter().enumerate().take(31) {
        buf[HEADER_OFFSET_SLOPE + i] = c;
    }
    // slot id is preserved by file offset (no byte in header for it).
    let _ = slot;

    // Steps: 64 byte each, max 7. position[31] at offset 0..61, pause=62, time=63.
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

    // Phase G8 — 모든 필드 set 한 후 마지막 단계로 checksum 계산. 누락 시 ROBOTIS
    // demo 가 페이지를 ResetPage 로 wipe → 사용자 작업 손실.
    set_action_checksum(&mut buf);
    Ok(buf)
}

fn handle_simulate(page_path: &std::path::Path, format: &str) -> anyhow::Result<()> {
    let pages = read_motion_pages(page_path)?;
    match format.to_lowercase().as_str() {
        "ascii" => simulate_ascii(&pages),
        "summary" => simulate_summary(&pages),
        other => anyhow::bail!("unknown format '{}' (ascii|summary)", other),
    }
}

fn simulate_ascii(pages: &[MotionPage]) -> anyhow::Result<()> {
    for page in pages {
        println!(
            "═══ Page {} '{}' ({} step, speed={}, accel={}) ═══",
            page.id,
            page.name,
            page.steps.len(),
            page.speed,
            page.accel
        );
        let mut elapsed_ms: u32 = 0;
        for (i, step) in page.steps.iter().enumerate() {
            let play_ms = step.play_ms() as u32;
            let pause_ms = step.pause_ms() as u32;
            elapsed_ms += play_ms + pause_ms;
            println!("  step {i}: t+{elapsed_ms:>5}ms  play={play_ms:>4}ms  pause={pause_ms:>4}ms");
            // **Phase G8 (Codex audit follow-up, 2026-05-15)**: ROBOTIS 공식 joint ID
            // 와 1:1 인덱싱 (slot 0 reserved). 이전 [0/12/14/19] 는 P0-2 와 같은
            // off-by-one — 사용자가 "R_KNEE" 라벨로 본 값이 실제로는 R_HIP_PITCH 였음.
            //   R_SHOULDER_PITCH = 1, R_HIP_PITCH = 11, R_KNEE = 13,
            //   R_ANKLE_PITCH = 15, HEAD_TILT = 20.
            let r_shoulder = step.positions[1] & 0x0FFF;
            let r_hip_pitch = step.positions[11] & 0x0FFF;
            let r_knee = step.positions[13] & 0x0FFF;
            let r_ankle = step.positions[15] & 0x0FFF;
            let head_tilt = step.positions[20] & 0x0FFF;
            println!(
                "          R_SH={r_shoulder:>4} R_HIP={r_hip_pitch:>4} R_KNEE={r_knee:>4} R_ANK={r_ankle:>4} HEAD={head_tilt:>4}"
            );
        }
        if page.next_page > 0 {
            println!("  → chains to page {}", page.next_page);
        }
    }
    Ok(())
}

fn simulate_summary(pages: &[MotionPage]) -> anyhow::Result<()> {
    let total_steps: usize = pages.iter().map(|p| p.steps.len()).sum();
    let total_ms: u32 = pages
        .iter()
        .flat_map(|p| p.steps.iter())
        .map(|s| s.play_ms() as u32 + s.pause_ms() as u32)
        .sum();
    println!(
        "pages={}  total_steps={}  total_ms={}  ({:.2}s)",
        pages.len(),
        total_steps,
        total_ms,
        total_ms as f32 / 1000.0
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_joint_offsets_basic() {
        let specs = vec!["5=100".to_string(), "11=-50".to_string()];
        let parsed = parse_joint_offsets(&specs).unwrap();
        assert_eq!(parsed.len(), 2);
        match &parsed[0] {
            Mutation::JointOffset { joint_id, delta } => {
                assert_eq!(*joint_id, 5);
                assert_eq!(*delta, 100);
            }
            _ => panic!("expected JointOffset"),
        }
    }

    #[test]
    fn parse_joint_offsets_bad_format_errors() {
        let specs = vec!["just_id".to_string()];
        assert!(parse_joint_offsets(&specs).is_err());
        let specs = vec!["5=abc".to_string()];
        assert!(parse_joint_offsets(&specs).is_err());
    }

    #[test]
    fn parse_curve_resolves_named_variants() {
        assert!(matches!(
            parse_curve("linear", 1.0, 0.0).unwrap(),
            Curve::Linear
        ));
        assert!(matches!(
            parse_curve("ease", 1.0, 0.0).unwrap(),
            Curve::EaseInOut
        ));
        assert!(matches!(
            parse_curve("sine", 2.0, 0.5).unwrap(),
            Curve::Sine {
                omega: 2.0,
                phase: 0.5
            }
        ));
        assert!(matches!(
            parse_curve("bezier", 1.0, 0.0).unwrap(),
            Curve::Bezier { .. }
        ));
        assert!(parse_curve("unknown", 1.0, 0.0).is_err());
    }

    #[test]
    fn parse_safety_resolves_variants() {
        use forge_core::motion::SafetyClass;
        assert_eq!(parse_safety("safe").unwrap(), SafetyClass::Safe);
        assert_eq!(parse_safety("CAUTION").unwrap(), SafetyClass::Caution);
        assert_eq!(parse_safety("highrisk").unwrap(), SafetyClass::HighRisk);
        assert_eq!(parse_safety("high-risk").unwrap(), SafetyClass::HighRisk);
        assert!(parse_safety("dangerous").is_err());
    }

    #[test]
    fn resolve_bin_path_uses_env_var_when_no_arg() {
        std::env::set_var("FORGE_MOTION_BIN", "/tmp/test_motion.bin");
        let p = resolve_bin_path(None).unwrap();
        assert_eq!(p, PathBuf::from("/tmp/test_motion.bin"));
        std::env::remove_var("FORGE_MOTION_BIN");
    }

    /// **Phase G1 (Codex audit 2026-05-14 P0-1)**: PAGEHEADER offset 검증.
    ///
    /// `Action.h:41-59` 의 공식 offset 으로 encode 했는지 byte 단위 확인 + decode
    /// round-trip. 이전 회귀 (stepnum=19, speed=21 …)가 다시 들어오면 즉시 fail.
    #[test]
    fn encode_page_uses_official_action_h_offsets() {
        let lib_path = {
            let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            p.push(DEFAULT_BIN_RELATIVE);
            p
        };
        if !lib_path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&lib_path).unwrap();
        let page = lib.get(1).expect("page 1");
        let raw = encode_page_to_raw(page, 1).unwrap();
        assert_eq!(raw.len(), 512);
        // 이름 4 byte ("init") 보존
        assert_eq!(&raw[..4], b"init");
        // Action.h:48-54 offsets (공식). 이전 1~4 byte 시프트되어 있던 P0 버그 회귀 방지.
        assert_eq!(raw[15], page.repeat, "repeat byte must be at offset 15");
        assert_eq!(
            raw[20],
            page.steps.len() as u8,
            "stepnum at offset 20 (was 19 — pre-G1 bug)"
        );
        assert_eq!(
            raw[22], page.speed,
            "speed at offset 22 (was 21 — pre-G1 bug)"
        );
        assert_eq!(
            raw[24], page.accel,
            "accel at offset 24 (was 23 — pre-G1 bug)"
        );
        assert_eq!(
            raw[25], page.next_page,
            "next at offset 25 (was 24 — pre-G1 bug)"
        );
        assert_eq!(
            raw[26], page.exit_page,
            "exit at offset 26 (was 25 — pre-G1 bug)"
        );
        // slope[31] = 32..62. compliance[0] 이 byte 32 에 들어가야 함.
        assert_eq!(
            raw[32], page.compliance[0],
            "slope[0] at offset 32 (was 28 — pre-G1 bug)"
        );
        if page.compliance.len() > 1 {
            assert_eq!(raw[33], page.compliance[1], "slope[1] at offset 33");
        }
    }

    /// 공식 raw page 를 그대로 encode 한 후 다시 decode 해서 헤더 필드가 모두
    /// 보존되는지 검증 (lossless round-trip).
    #[test]
    fn encode_then_decode_preserves_header_fields() {
        use forge_core::motion::bin4096::RawPage;
        use forge_core::motion::SafetyClass;
        use forge_core::synth::library::decode_raw_page;

        let lib_path = {
            let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            p.push(DEFAULT_BIN_RELATIVE);
            p
        };
        if !lib_path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&lib_path).unwrap();
        // chain page 24 (d2, next=25) 로 round-trip — next_page 검증 위해.
        let page = lib.get(24).expect("page 24");
        let raw_bytes = encode_page_to_raw(page, 24).unwrap();
        let round = RawPage {
            index: 24,
            name: page.name.clone(),
            raw: raw_bytes.to_vec(),
        };
        let decoded = decode_raw_page(&round, SafetyClass::Safe).expect("decode");
        assert_eq!(decoded.repeat, page.repeat);
        assert_eq!(decoded.speed, page.speed);
        assert_eq!(decoded.accel, page.accel);
        assert_eq!(decoded.next_page, page.next_page, "next_page round-trip");
        assert_eq!(decoded.exit_page, page.exit_page);
        assert_eq!(decoded.steps.len(), page.steps.len());
        // 첫 step 의 첫 관절 position round-trip.
        if !page.steps.is_empty() {
            assert_eq!(decoded.steps[0].positions[1], page.steps[0].positions[1]);
            assert_eq!(decoded.steps[0].play_time, page.steps[0].play_time);
        }
    }

    /// **Phase G8 (Codex audit follow-up, 2026-05-15)**: encoded buffer 가
    /// ROBOTIS `Action::VerifyChecksum` (Action.cpp:30-44) 의 byte-sum==0xff 조건을
    /// 만족 + schedule = TIME_BASE_SCHEDULE (0x0A). 누락 시 ROBOTIS demo 가 페이지를
    /// reset 으로 wipe 하는 P0 회귀 방지.
    #[test]
    fn encode_page_passes_robotis_verify_checksum_and_time_base_schedule() {
        use forge_core::synth::library::{
            verify_action_checksum, HEADER_OFFSET_SCHEDULE, TIME_BASE_SCHEDULE,
        };

        let lib_path = {
            let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            p.push(DEFAULT_BIN_RELATIVE);
            p
        };
        if !lib_path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&lib_path).unwrap();
        let page = lib.get(1).expect("page 1");
        let raw = encode_page_to_raw(page, 1).unwrap();
        assert_eq!(
            raw[HEADER_OFFSET_SCHEDULE], TIME_BASE_SCHEDULE,
            "schedule byte must be TIME_BASE (0x0A) — ROBOTIS 공식 motion 의 schedule"
        );
        assert!(
            verify_action_checksum(&raw),
            "encoded buffer must pass ROBOTIS VerifyChecksum — 누락 시 LoadPage 가 ResetPage 호출 (Action.cpp:249)"
        );
    }
}
