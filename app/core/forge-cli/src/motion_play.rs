//! `forge motion play` — 모션 페이지를 실 robot 에 송출 (Sprint 13).
//!
//! ## ⚠️ 공식 Action player 와 동등하지 않음 (Codex audit P1-4, 2026-05-14)
//!
//! 이 모듈은 **raw step coarse playback** 이다 — 공식 `Action.cpp` 의 PRE/MAIN/POST/
//! PAUSE section + speed/accel/slope 기반 trapezoid 보간을 재현하지 않는다.
//! 각 step 은 `set_positions_many` 한 번 + `sleep(play_ms + pause_ms)` 만 한다.
//!
//! 의미:
//! - Bus traffic 패턴 / 모터 부하 곡선이 공식과 다름.
//! - Joint compliance(slope) 가 적용 안 됨.
//! - 짧은 play_time 의 빠른 step 에서 jerk 발생 가능.
//!
//! 정확한 공식 재생이 필요하면 별도 replayer 가 필요 — `forge motion replay-official`
//! (계획됨). 현재는 step 자세 시퀀스 확인 + low-risk 단발 자세 전이용.
//!
//! ## 안전 기본값
//! - **`--dry-run`** (기본 ON) → 패킷 stdout 출력만, 실 모터 송출 X
//! - `--engage` → 실 모터 송출 (사용자 명시)
//! - `precheck_motion` 자동 — V1/V3 통과 못 한 페이지는 거부
//! - Ctrl+C 시그널 처리: **현재 placeholder**. 실 emergency stop 구현 전까지
//!   사용자가 USB 케이블을 뽑거나 robot 측에서 직접 처리해야 함. P1 항목으로
//!   `signal-hook` 도입 예정.
//!
//! 페이지 source:
//! - `--slot <n>` — `motion_4096.bin` 슬롯
//! - `--from-json <path>` — Motion JSON 파일 (Sprint 10 산출 호환)
//!
//! 본 모듈은 **HARDWARE_VERIFICATION_PROTOCOL.md** 의 G3 단계에 해당.
//! 운영자는 사전에 G1 (validate) 과 G2 (connect / 토크 OFF 확인) 를 통과해야 함.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use clap::Args;
use forge_core::control::{ExecuteOptions, JointController};
use forge_core::dynamixel::Bus;
use forge_core::joint::JointId;
use forge_core::motion::{bin4096::read_bin4096_file, MotionPage, MotionStep, NUM_JOINTS_IN_STEP};
use forge_core::safety::torque_ramp::{TorqueRampProfile, TorqueRamper};
use forge_core::serial::PosixSerial;

/// **사이클 120 (audit #27, P0 safety)**: SIGINT/SIGTERM signal flag.
/// Ctrl+C handler 가 set → 메인 loop 가 다음 step 진입 직전 polling →
/// `true` 이면 torque OFF + clean exit.
static SHOULD_EXIT: AtomicBool = AtomicBool::new(false);

/// MX-28 position 의 12-bit value 마스크.
const POSITION_MASK: u16 = 0x0FFF;
const INVALID_BIT: u16 = 0x4000;
const TORQUE_OFF_BIT: u16 = 0x2000;

/// 8 ms tick (ROBOTIS 표준 PAGE step granularity).
const TICK_MS: u64 = 8;

/// `forge motion play` 인자.
#[derive(Args, Debug, Clone)]
pub struct PlayArgs {
    /// USB 직렬 포트 (예: `/dev/cu.usbserial-A1B2`). dry-run 시 미사용.
    #[arg(long)]
    pub port: Option<String>,
    /// `motion_4096.bin` 슬롯 (1..=255) 에서 페이지 로드. `--from-json` 과 양자택일.
    #[arg(long)]
    pub slot: Option<u8>,
    /// `motion_4096.bin` 경로 override.
    #[arg(long)]
    pub bin: Option<PathBuf>,
    /// Motion JSON 파일 (Sprint 10 `forge synth` 산출). `--slot` 과 양자택일.
    #[arg(long)]
    pub from_json: Option<PathBuf>,
    /// USB baud rate.
    #[arg(long, default_value_t = 1_000_000)]
    pub baud: u32,
    /// 응답 timeout (ms).
    #[arg(long, default_value_t = 50)]
    pub timeout: u64,
    /// **기본값**: 패킷만 출력, 실 모터 송출 X. `--engage` 로 해제.
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub dry_run: bool,
    /// 실 모터 송출 활성화 (사용자 명시 — `--dry-run false` 와 동일 효과).
    #[arg(long)]
    pub engage: bool,
    /// `precheck_motion` (V1/V3) 우회 — 비추천.
    #[arg(long)]
    pub skip_validation: bool,
    /// 단발 지지 자세 허용 (kick 등). `precheck_motion` 에 전달.
    #[arg(long)]
    pub single_foot_ok: bool,
    /// 재생 후 토크 OFF (기본 hold).
    #[arg(long)]
    pub torque_off_after: bool,
    /// `next_page` chain 따라가기 (기본 ON).
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    pub follow_chain: bool,
    /// 최대 chain 깊이 (무한 루프 방지).
    #[arg(long, default_value_t = 10)]
    pub max_chain_depth: usize,
}

/// 페이지 source 디스크립터.
enum PageSource {
    Bin { path: PathBuf, slot: u8 },
    Json { path: PathBuf },
}

/// Motion JSON 또는 bin slot 에서 페이지 + 후속 chain 페이지 로드.
fn load_pages(
    source: &PageSource,
    follow_chain: bool,
    max_depth: usize,
) -> anyhow::Result<Vec<MotionPage>> {
    match source {
        PageSource::Bin { path, slot } => load_from_bin(path, *slot, follow_chain, max_depth),
        PageSource::Json { path } => load_from_json(path),
    }
}

fn load_from_bin(
    path: &std::path::Path,
    slot: u8,
    follow_chain: bool,
    max_depth: usize,
) -> anyhow::Result<Vec<MotionPage>> {
    let raws = read_bin4096_file(path).map_err(|e| anyhow::anyhow!("read bin: {e}"))?;
    let mut visited = std::collections::HashSet::new();
    let mut pages = Vec::new();
    let mut current = slot;
    while visited.insert(current) && pages.len() < max_depth {
        let raw = raws
            .iter()
            .find(|r| r.index == current)
            .ok_or_else(|| anyhow::anyhow!("slot {current} not in bin"))?;
        if raw.is_empty() {
            anyhow::bail!("slot {current} is empty");
        }
        let page =
            forge_core::synth::library::decode_raw_page(raw, forge_core::motion::SafetyClass::Safe)
                .map_err(|e| anyhow::anyhow!("decode slot {current}: {e}"))?;
        let next = page.next_page;
        pages.push(page);
        if !follow_chain || next == 0 {
            break;
        }
        current = next;
    }
    Ok(pages)
}

fn load_from_json(path: &std::path::Path) -> anyhow::Result<Vec<MotionPage>> {
    let s = std::fs::read_to_string(path)?;
    let motion: forge_core::motion::Motion =
        forge_core::motion::Motion::from_json(&s).map_err(|e| anyhow::anyhow!("parse: {e}"))?;
    if motion.pages.is_empty() {
        anyhow::bail!("motion JSON has no pages");
    }
    Ok(motion.pages)
}

/// 한 step 의 positions 를 `[(JointId, u16)]` 로 디코드.
///
/// 제외 조건 (Phase G4 — Codex audit P1-4, 2026-05-14 정정):
/// - INVALID flag (`0x4000`, Action.h:37) — 페이지 헤더에서 미사용 마킹
/// - TORQUE_OFF flag (`0x2000`, Action.h:38) — 해당 관절 토크 OFF 의도
///
/// **이전 버전은 `raw == 0` 도 skip 했음** → 12-bit position 0 은 valid (MX-28 의
/// 한 끝 위치) 이므로 잘못된 제외. ROBOTIS 공식도 raw==0 은 skip 하지 않는다.
///
/// ROBOTIS PageData 의 `positions[0]` 은 reserved 라 `slot in 1..=20`.
pub fn step_to_targets(step: &MotionStep) -> Vec<(JointId, u16)> {
    let mut out = Vec::new();
    for slot in 1..=NUM_JOINTS_IN_STEP.min(20) {
        let raw = step.positions[slot];
        // INVALID / TORQUE_OFF flag bit 만 체크. raw==0 은 valid 12-bit position.
        if (raw & INVALID_BIT) != 0 || (raw & TORQUE_OFF_BIT) != 0 {
            continue;
        }
        let Some(joint) = JointId::from_byte(slot as u8) else {
            continue;
        };
        let value = raw & POSITION_MASK;
        out.push((joint, value));
    }
    out
}

/// 한 step 의 dry-run 출력 (실 송출 X, stdout 으로 패킷 요약).
fn dry_print_step(step_idx: usize, page_name: &str, step: &MotionStep) {
    let targets = step_to_targets(step);
    println!(
        "[dry-run] page '{}' step {} (play={} ms, pause={} ms) — {} joints",
        page_name,
        step_idx,
        step.play_ms(),
        step.pause_ms(),
        targets.len()
    );
    for (joint, value) in &targets {
        println!("           {:?}={}", joint, value);
    }
}

/// `forge motion play` 디스패처.
pub fn handle(args: PlayArgs) -> anyhow::Result<()> {
    // 1) source 결정
    let bin_path = resolve_bin_path(args.bin.as_deref())?;
    let source = match (&args.slot, &args.from_json) {
        (Some(slot), None) => PageSource::Bin {
            path: bin_path,
            slot: *slot,
        },
        (None, Some(p)) => PageSource::Json { path: p.clone() },
        (Some(_), Some(_)) => {
            anyhow::bail!("`--slot` and `--from-json` are mutually exclusive")
        }
        (None, None) => {
            anyhow::bail!("either `--slot <n>` or `--from-json <path>` required")
        }
    };

    // 2) 페이지 + chain 로드
    let pages = load_pages(&source, args.follow_chain, args.max_chain_depth)?;
    eprintln!(
        "✓ loaded {} page(s) — {}",
        pages.len(),
        pages
            .iter()
            .map(|p| format!("{}:'{}'", p.id, p.name))
            .collect::<Vec<_>>()
            .join(" → ")
    );

    // 3) Engage 결정 — `--engage` 또는 `--dry-run false` 명시 시에만 실 송출
    let actually_engage = args.engage || (!args.dry_run);
    if !actually_engage {
        eprintln!("🟡 dry-run mode — 실 모터 송출 없음. 실행하려면 `--engage` 추가");
        for page in &pages {
            println!(
                "═══ Page {} '{}' ({} step) ═══",
                page.id,
                page.name,
                page.steps.len()
            );
            for (i, step) in page.steps.iter().enumerate() {
                dry_print_step(i, &page.name, step);
            }
        }
        eprintln!(
            "\n✓ dry-run 종료. 총 {} 페이지, {} step",
            pages.len(),
            pages.iter().map(|p| p.steps.len()).sum::<usize>()
        );
        return Ok(());
    }

    // 4) 실 송출 — port 필수
    let port = args
        .port
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("`--port` required for engage mode"))?;
    eprintln!("🔴 engage mode — 실 robot 에 모터 명령 송출");
    eprintln!("   사용자 책임: HARDWARE_VERIFICATION_PROTOCOL.md G3 사전점검 5 항목 완료 가정");

    let posix =
        PosixSerial::open(port, args.baud).map_err(|e| anyhow::anyhow!("USB open {port}: {e}"))?;
    let mut bus = Bus::new(posix).with_timeout(Duration::from_millis(args.timeout));
    let mut jc = JointController::new(&mut bus);

    // 5) Ctrl+C 핸들러 — emergency_stop
    let _ = setup_ctrlc_handler();

    // 6) 페이지별 재생
    for (page_idx, page) in pages.iter().enumerate() {
        // 6a) precheck_motion (V1/V3)
        if !args.skip_validation {
            let options = ExecuteOptions {
                confirm_risk: args.single_foot_ok,
            };
            if let Err(e) = jc.precheck_motion(page, options) {
                anyhow::bail!(
                    "page {} '{}' precheck failed: {e}\n  pass --skip-validation to bypass (not recommended)",
                    page.id,
                    page.name
                );
            }
            eprintln!("✓ page {} '{}' precheck PASS", page.id, page.name);
        }

        // 6b) 토크 ramp (첫 페이지에만)
        if page_idx == 0 {
            let joints: Vec<JointId> = step_to_targets(&page.steps[0])
                .into_iter()
                .map(|(j, _)| j)
                .collect();
            let mut ramper = TorqueRamper::new(&joints, TorqueRampProfile::gentle());
            ramper.enable_torque(&mut jc)?;
            while ramper.next_step(&mut jc)? {
                std::thread::sleep(Duration::from_millis(TICK_MS * 4));
            }
            eprintln!(
                "✓ torque ramp 완료 (final P-gain {})",
                ramper.final_p_gain()
            );
        }

        // 6c) step 순회 (repeat 횟수만큼)
        let repeat = page.repeat.max(1) as usize;
        for r in 0..repeat {
            eprintln!(
                "▶ page {} '{}' iteration {}/{}",
                page.id,
                page.name,
                r + 1,
                repeat
            );
            for (step_idx, step) in page.steps.iter().enumerate() {
                // **사이클 120 (audit #27, P0 safety)**: Ctrl+C 감지 시 emergency torque OFF.
                // 매 step 진입 직전 polling — 종전 placeholder 였던 setup_ctrlc_handler 가
                // 이제 SHOULD_EXIT 를 set → 본 분기 진입 → torque OFF + clean exit.
                if SHOULD_EXIT.load(Ordering::SeqCst) {
                    let joints: Vec<JointId> = step_to_targets(step)
                        .into_iter()
                        .map(|(j, _)| j)
                        .collect();
                    // 토크 OFF 실패해도 종료 진행 — 사용자 안내 우선.
                    let _ = jc.set_torque_many(&joints, false);
                    report_emergency_exit();
                    return Ok(());
                }

                let targets = step_to_targets(step);
                if targets.is_empty() {
                    continue;
                }
                jc.set_positions_many(&targets)?;
                let play_ms = step.play_ms() as u64;
                if play_ms > 0 {
                    std::thread::sleep(Duration::from_millis(play_ms));
                }
                let pause_ms = step.pause_ms() as u64;
                if pause_ms > 0 {
                    std::thread::sleep(Duration::from_millis(pause_ms));
                }
                eprintln!(
                    "  step {} done (play {} ms, pause {} ms)",
                    step_idx, play_ms, pause_ms
                );
            }
        }
    }

    // 7) 종료 처리
    if args.torque_off_after {
        let last = pages.last().expect("non-empty");
        let joints: Vec<JointId> = step_to_targets(&last.steps[0])
            .into_iter()
            .map(|(j, _)| j)
            .collect();
        jc.set_torque_many(&joints, false)?;
        eprintln!("✓ 토크 OFF — 모터 자유 상태");
    } else {
        eprintln!("✓ 재생 완료 — 마지막 자세 유지 (토크 ON)");
    }

    Ok(())
}

fn resolve_bin_path(arg: Option<&std::path::Path>) -> anyhow::Result<PathBuf> {
    if let Some(p) = arg {
        return Ok(p.to_path_buf());
    }
    if let Ok(env) = std::env::var("FORGE_MOTION_BIN") {
        return Ok(PathBuf::from(env));
    }
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin");
    Ok(p)
}

fn setup_ctrlc_handler() -> Result<(), Box<dyn std::error::Error>> {
    // **사이클 120 (audit #27, P0 safety)**: ctrlc crate 도입 — Ctrl+C/SIGTERM 시 flag set.
    // 메인 step loop 가 다음 step 진입 전 polling → true 이면 torque OFF + clean exit.
    //
    // 종전: placeholder Ok(()) — SIGINT 시 std 기본 동작 (즉시 종료) → 모터 자세 lock.
    // 신규: SHOULD_EXIT.set(true) → loop 가 발견 → emergency_stop 호출.
    //
    // # 비유
    //
    // 비행기 cockpit "eject" 버튼 — pilot 이 누르면 (Ctrl+C) 즉시 emergency landing
    // 절차 (torque OFF + walkReady) 진행. 종전엔 종이 alarm 만 울리고 동작 안 됨.
    ctrlc::set_handler(|| {
        SHOULD_EXIT.store(true, Ordering::SeqCst);
        eprintln!("\n⚠️  Ctrl+C 감지 — 다음 step 직전 emergency torque OFF 진행");
    })?;
    Ok(())
}

/// **사이클 120 (audit #27)**: emergency torque OFF — Ctrl+C 시 호출.
/// 현재 활성 페이지의 joint 들 모두 torque OFF + 메시지 출력.
/// `JointController` 미사용 (`&mut Bus` 필요한 보다 raw 한 path) — 향후 ramper 의
/// `disable_torque` 같은 helper 가 안전. 본 함수는 safe 종료 marker.
fn report_emergency_exit() {
    eprintln!("🛑 emergency exit — torque OFF 시도 후 종료");
    eprintln!("   사용자 확인: 모터가 풀렸는지 확인 후 USB 케이블 안전 분리");
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_core::motion::MotionStep;

    /// Phase G4 (Codex audit P1-4): default 는 INVALID_BIT 로 채워서 "valid 인 slot 만
    /// 명시적으로 set" 시나리오를 만든다. 이전엔 default 0 이라 raw==0 skip 가정에 의존.
    fn step_with(values: &[(usize, u16)]) -> MotionStep {
        let mut positions = [INVALID_BIT; NUM_JOINTS_IN_STEP];
        positions[0] = 0; // slot 0 reserved
        for &(i, v) in values {
            positions[i] = v;
        }
        MotionStep {
            positions,
            pause_time: 0,
            play_time: 16,
        }
    }

    /// **Phase G4 (Codex audit P1-4, 2026-05-14)**: INVALID/TORQUE_OFF flag bit 만
    /// skip. raw==0 은 valid 12-bit position 이므로 통과해야 함 (이전 잘못된 skip 회귀 방지).
    #[test]
    fn step_to_targets_filters_invalid_flag_slots() {
        let s = step_with(&[
            (1, 2048),                  // OK
            (2, INVALID_BIT),           // skip (INVALID)
            (3, TORQUE_OFF_BIT | 1500), // skip (TORQUE_OFF)
            (4, 1024),                  // OK
            (5, 0x6000 | 800),          // INVALID + TORQUE_OFF → skip
        ]);
        let t = step_to_targets(&s);
        let ids: Vec<u8> = t.iter().map(|(j, _)| *j as u8).collect();
        assert_eq!(ids, vec![1, 4]);
        assert_eq!(t[0].1, 2048);
        assert_eq!(t[1].1, 1024);
    }

    #[test]
    fn step_to_targets_masks_to_12bit_value() {
        // 0x0FFF 는 12-bit max, flag bit 없음 → 통과 + mask 결과 그대로.
        let s = step_with(&[(1, 0x0FFF)]);
        let t = step_to_targets(&s);
        assert_eq!(t.len(), 1);
        assert_eq!(t[0].1, 0x0FFF);
    }

    /// **Phase G4 (Codex audit P1-4)**: raw==0 은 valid position 이라 출력에 포함.
    /// 이전엔 `raw == 0` skip 조건 때문에 falsely 제외됐던 회귀 방지.
    #[test]
    fn step_to_targets_includes_raw_zero_as_valid_position() {
        let s = step_with(&[(1, 0)]); // raw==0 — valid 12-bit position
        let t = step_to_targets(&s);
        assert_eq!(t.len(), 1, "raw==0 must be a valid target (Codex P1-4)");
        assert_eq!(t[0].0 as u8, 1);
        assert_eq!(t[0].1, 0);
    }

    #[test]
    fn step_to_targets_skips_slot_zero() {
        let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
        positions[0] = 9999; // slot 0 — JointId 0 부재
        let s = MotionStep {
            positions,
            pause_time: 0,
            play_time: 16,
        };
        let t = step_to_targets(&s);
        let has_slot_zero = t.iter().any(|(j, v)| *j as u8 == 0 || *v == 9999);
        assert!(!has_slot_zero, "slot 0 should never appear");
    }

    #[test]
    fn resolve_bin_path_uses_env_or_default() {
        // env 가 우선
        std::env::set_var("FORGE_MOTION_BIN", "/tmp/test_motion_play.bin");
        let p = resolve_bin_path(None).unwrap();
        assert_eq!(p, PathBuf::from("/tmp/test_motion_play.bin"));
        std::env::remove_var("FORGE_MOTION_BIN");

        // arg override
        let p = resolve_bin_path(Some(std::path::Path::new("/explicit/path.bin"))).unwrap();
        assert_eq!(p, PathBuf::from("/explicit/path.bin"));
    }
}
