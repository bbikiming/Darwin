//! ROBOTIS motion_4096.bin → velocity calibration 통계 산출.
//!
//! 사용: `cargo run -p forge-core --example calibrate_velocity`
//!
//! 출력: `tests/fixtures/velocity_calibration.json` — 각 catalog 페이지 의 step
//! 간 |Δposition| / play_ms 통계 (per joint + per page + overall p50/p90/p95/p99/max).
//!
//! `synth::validator::velocity::{WARN_RAW_PER_MS, MAX_RAW_PER_MS}` 임계의
//! provenance 데이터.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use forge_core::motion::bin4096::parse_bin4096;

const PAGE_BYTES: usize = 512;
const NUM_SLOTS: usize = 31;
const STEP_BYTES: usize = 64;
const POSITION_MASK: u16 = 0x0FFF;
const FLAG_INVALID: u16 = 0x4000;
const FLAG_TORQUE_OFF: u16 = 0x2000;
const SKIP_MARKER: u16 = 32767;

/// OFFICIAL_CATALOG ids (gui_motion.yaml).
const CATALOG_IDS: &[u8] = &[
    1, 2, 3, 4, 9, 10, 11, 12, 13, 15, 17, 23, 24, 27, 38, 54,
];

#[derive(Debug, Default, Clone)]
struct PageVelocityStats {
    page_id: u8,
    name: String,
    step_num: u8,
    /// 각 (step transition, joint) 별 |Δ| / play_ms.
    samples: Vec<f64>,
    per_joint_max: BTreeMap<u8, f64>,
    transition_max: f64,
}

fn decode_step_positions(step_bytes: &[u8]) -> [u16; NUM_SLOTS] {
    let mut p = [0u16; NUM_SLOTS];
    for i in 0..NUM_SLOTS {
        let lo = step_bytes[i * 2] as u16;
        let hi = step_bytes[i * 2 + 1] as u16;
        p[i] = lo | (hi << 8);
    }
    p
}

fn analyze_page(raw_page: &[u8], id: u8) -> PageVelocityStats {
    let name_end = raw_page[..14].iter().position(|b| *b == 0).unwrap_or(14);
    let name = String::from_utf8_lossy(&raw_page[..name_end]).to_string();
    let step_num = raw_page[20];
    let mut stats = PageVelocityStats {
        page_id: id,
        name: name.clone(),
        step_num,
        ..Default::default()
    };
    if step_num < 2 {
        return stats;
    }

    let mut steps: Vec<([u16; NUM_SLOTS], u8)> = Vec::new();
    for s in 0..step_num as usize {
        let off = 64 + s * STEP_BYTES;
        if off + STEP_BYTES > PAGE_BYTES {
            break;
        }
        let pos = decode_step_positions(&raw_page[off..off + STEP_BYTES]);
        let play_time = raw_page[off + NUM_SLOTS * 2 + 1];
        steps.push((pos, play_time));
    }
    // play_time 단위: raw × 8 ms.
    for w in steps.windows(2) {
        let (pa, _ta) = &w[0];
        let (pb, tb) = &w[1];
        let play_ms = (*tb as f64) * 8.0;
        if play_ms <= 0.0 {
            continue;
        }
        for joint_id in 1..=20u8 {
            let i = joint_id as usize;
            let av = pa[i];
            let bv = pb[i];
            // SKIP / INVALID / TORQUE_OFF 제외 (validator 와 동일 규약)
            if av == SKIP_MARKER
                || bv == SKIP_MARKER
                || (av & FLAG_INVALID) != 0
                || (bv & FLAG_INVALID) != 0
                || (av & FLAG_TORQUE_OFF) != 0
                || (bv & FLAG_TORQUE_OFF) != 0
            {
                continue;
            }
            let av = (av & POSITION_MASK) as i32;
            let bv = (bv & POSITION_MASK) as i32;
            let delta = (bv - av).unsigned_abs() as f64;
            let rate = delta / play_ms;
            stats.samples.push(rate);
            let entry = stats.per_joint_max.entry(joint_id).or_insert(0.0);
            if rate > *entry {
                *entry = rate;
            }
            if rate > stats.transition_max {
                stats.transition_max = rate;
            }
        }
    }
    stats
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() as f64) * p).floor() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

fn main() {
    let bin_path =
        "research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin";
    let bytes = fs::read(bin_path).expect("read motion_4096.bin");
    let pages = parse_bin4096(&bytes).expect("parse");

    let mut page_stats: Vec<PageVelocityStats> = Vec::new();
    let mut all_samples: Vec<f64> = Vec::new();
    let mut overall_per_joint_max: BTreeMap<u8, f64> = BTreeMap::new();

    for id in CATALOG_IDS {
        let p = &pages[*id as usize];
        let s = analyze_page(&p.raw, *id);
        for sample in &s.samples {
            all_samples.push(*sample);
        }
        for (j, max) in &s.per_joint_max {
            let e = overall_per_joint_max.entry(*j).or_insert(0.0);
            if max > e {
                *e = *max;
            }
        }
        page_stats.push(s);
    }

    all_samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p50 = percentile(&all_samples, 0.50);
    let p90 = percentile(&all_samples, 0.90);
    let p95 = percentile(&all_samples, 0.95);
    let p99 = percentile(&all_samples, 0.99);
    let max = all_samples.last().copied().unwrap_or(0.0);
    let n = all_samples.len();

    // 권장 WARN / FAIL: p99 × 1.1 / max × 1.1.
    let recommended_warn = p99 * 1.1;
    let recommended_fail = max * 1.1;

    // JSON 직접 직렬화 (serde_json deps 가 dev-dep 인 경우 회피).
    let mut out = String::new();
    out.push_str("{\n");
    // 2026-05-17 clippy unnecessary_to_string fix — &str literal 이미 &str.
    out.push_str("  \"source\": \"research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin\",\n");
    out.push_str(&format!("  \"catalog_pages\": {},\n", CATALOG_IDS.len()));
    out.push_str(&format!("  \"total_samples\": {},\n", n));
    out.push_str("  \"unit\": \"raw_delta_per_ms\",\n");
    out.push_str("  \"overall\": {\n");
    out.push_str(&format!("    \"p50\": {:.4},\n", p50));
    out.push_str(&format!("    \"p90\": {:.4},\n", p90));
    out.push_str(&format!("    \"p95\": {:.4},\n", p95));
    out.push_str(&format!("    \"p99\": {:.4},\n", p99));
    out.push_str(&format!("    \"max\": {:.4}\n", max));
    out.push_str("  },\n");
    out.push_str("  \"recommended_thresholds\": {\n");
    out.push_str(&format!(
        "    \"warn_raw_per_ms\": {:.2},   /* p99 × 1.1 */\n",
        recommended_warn
    ));
    out.push_str(&format!(
        "    \"max_raw_per_ms\": {:.2}    /* max × 1.1 */\n",
        recommended_fail
    ));
    out.push_str("  },\n");

    out.push_str("  \"per_joint_max_raw_per_ms\": {\n");
    let joint_entries: Vec<String> = overall_per_joint_max
        .iter()
        .map(|(j, m)| format!("    \"{j}\": {:.4}", m))
        .collect();
    out.push_str(&joint_entries.join(",\n"));
    out.push_str("\n  },\n");

    out.push_str("  \"per_page\": [\n");
    let page_entries: Vec<String> = page_stats
        .iter()
        .filter(|s| !s.samples.is_empty())
        .map(|s| {
            let mut joint_max: Vec<String> = s
                .per_joint_max
                .iter()
                .map(|(j, m)| format!("\"{j}\": {:.4}", m))
                .collect();
            joint_max.sort();
            format!(
                "    {{\"id\": {}, \"name\": \"{}\", \"steps\": {}, \"max_raw_per_ms\": {:.4}, \"per_joint\": {{{}}}}}",
                s.page_id,
                s.name,
                s.step_num,
                s.transition_max,
                joint_max.join(", ")
            )
        })
        .collect();
    out.push_str(&page_entries.join(",\n"));
    out.push_str("\n  ]\n");
    out.push_str("}\n");

    let fixtures_dir = PathBuf::from("app/core/forge-core/tests/fixtures");
    fs::create_dir_all(&fixtures_dir).expect("mkdir");
    let path = fixtures_dir.join("velocity_calibration.json");
    fs::write(&path, &out).expect("write");

    eprintln!("Wrote {}", path.display());
    eprintln!("Overall: p50={:.2} p90={:.2} p95={:.2} p99={:.2} max={:.2} raw/ms",
        p50, p90, p95, p99, max);
    eprintln!("Recommend WARN={:.2}, MAX={:.2}", recommended_warn, recommended_fail);
}
