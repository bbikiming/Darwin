//! ROBOTIS motion_4096.bin → MotionPage Rust source 추출기.
//!
//! 사용: `cargo run -p forge-core --example decode_motion -- <page_id>`
//!
//! 출력: `pub(crate) fn page_<id>_<name>() -> MotionPage { ... }` 형식의
//! Rust source. test_fixtures.rs 에 직접 붙여넣을 수 있다.
//!
//! # 바이너리 레이아웃 (`Framework/src/motion/Action.cpp` 기준)
//!
//! 한 페이지 = 512 byte, 8-byte aligned. 컴파일된 ROBOTIS Action.cpp 의 PAGE 구조체:
//!
//! ```c
//! typedef struct {  // 64 byte
//!     uchar pause_time;
//!     uchar play_time;
//!     ushort position[31];
//! } STEP;
//! typedef struct {  // 512 byte
//!     uchar name[14];
//!     uchar reserved1;
//!     uchar repeat;
//!     uchar schedule;       // = speed_rate / accel
//!     uchar reserved2[3];
//!     uchar next;
//!     uchar exit;
//!     uchar reserved3[4];
//!     uchar checksum;
//!     uchar slope[31];      // = compliance
//!     uchar play_param;     // (unused in OP2 — accel via separate field)
//!     STEP step[7];
//! } PAGE;
//! ```
//!
//! 실제 OP2 의 motion_4096.bin 은 위 구조에서 `slope[]` 와 `step[]` 위치만 보존한
//! 변형이다. 본 디코더는 page 1 init 와 page 9 walkready fixture 의 byte-exact
//! 매칭으로 offset 을 역추적해 결정.

use std::env;
use std::fs;
use std::process;

const PAGE_BYTES: usize = 512;
const NUM_SLOTS: usize = 31;
const STEP_BYTES: usize = 64; // 31×2 positions + 1 pause + 1 play

/// 한 페이지에서 step 까지 추출. page 1 init / page 9 walkready / page 12 right kick
/// fixture 와 byte-exact 매칭으로 offset 역추적.
///
/// 레이아웃 (512 byte / page):
/// - 0..14   : name (ASCII, 0-padded)
/// - 14      : reserved
/// - 15      : repeat
/// - 16      : schedule (flag)
/// - 17      : next_page
/// - 18      : exit_page
/// - 19..22  : reserved
/// - 22      : speed (보통 32)
/// - 23      : reserved
/// - 24      : accel (보통 32)
/// - 25..31  : reserved / padding
/// - 31      : checksum
/// - 32..63  : compliance[31] + 1 byte padding (slope per joint, 0x55 default)
/// - 64..511 : step[7] each 64 byte (positions[31] u16 LE + pause_time u8 + play_time u8)
fn decode_page(raw: &[u8], page_id: u8) -> Option<DecodedPage> {
    if raw.len() != PAGE_BYTES {
        return None;
    }
    let name = extract_name(&raw[0..14]);
    let repeat = raw[15];
    let next_page = raw[17];
    let exit_page = raw[18];
    let step_num = raw[20] as usize;
    let speed = raw[22];
    let accel = raw[24];
    let mut compliance = [0u8; NUM_SLOTS];
    compliance.copy_from_slice(&raw[32..32 + NUM_SLOTS]);

    let mut steps = Vec::new();
    for s in 0..step_num.min(7) {
        let off = 64 + s * STEP_BYTES;
        if off + STEP_BYTES > PAGE_BYTES {
            break;
        }
        let step_bytes = &raw[off..off + STEP_BYTES];
        let mut positions = [0u16; NUM_SLOTS];
        for i in 0..NUM_SLOTS {
            let lo = step_bytes[i * 2] as u16;
            let hi = step_bytes[i * 2 + 1] as u16;
            positions[i] = lo | (hi << 8);
        }
        let pause_time = step_bytes[NUM_SLOTS * 2];
        let play_time = step_bytes[NUM_SLOTS * 2 + 1];
        steps.push(DecodedStep {
            positions,
            pause_time,
            play_time,
        });
    }
    Some(DecodedPage {
        id: page_id,
        name,
        compliance,
        next_page,
        exit_page,
        repeat,
        speed,
        accel,
        steps,
    })
}

fn extract_name(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).to_string()
}

struct DecodedStep {
    positions: [u16; NUM_SLOTS],
    pause_time: u8,
    play_time: u8,
}

struct DecodedPage {
    id: u8,
    name: String,
    compliance: [u8; NUM_SLOTS],
    next_page: u8,
    exit_page: u8,
    repeat: u8,
    speed: u8,
    accel: u8,
    steps: Vec<DecodedStep>,
}

fn rust_array_u8(label: &str, arr: &[u8]) -> String {
    let chunks: Vec<String> = arr
        .chunks(11)
        .map(|c| {
            c.iter()
                .map(|b| format!("{}", b))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .collect();
    format!("{label}: [\n    {},\n],", chunks.join(",\n    "))
}

fn rust_array_u16(arr: &[u16]) -> String {
    let chunks: Vec<String> = arr
        .chunks(10)
        .map(|c| {
            c.iter()
                .map(|p| format!("0x{:04x}", p))
                .collect::<Vec<_>>()
                .join(", ")
        })
        .collect();
    format!("[\n            {},\n        ]", chunks.join(",\n            "))
}

fn emit_rust(p: &DecodedPage, safety: &str) -> String {
    let name_safe: String = p.name.chars().filter(|c| c.is_alphanumeric() || *c == '_').collect();
    let name_lower = name_safe.to_lowercase();
    let mut out = String::new();
    out.push_str(&format!(
        "/// Page {} `\"{}\"` — ROBOTIS 슬롯 {} (auto-extracted).\n",
        p.id, p.name, p.id
    ));
    out.push_str(&format!(
        "pub(crate) fn page_{}_{}() -> MotionPage {{\n",
        p.id, name_lower
    ));
    out.push_str("    MotionPage {\n");
    out.push_str(&format!("        id: {},\n", p.id));
    out.push_str(&format!("        name: \"{}\".to_string(),\n", p.name));
    out.push_str(&format!("        {}\n", indent(&rust_array_u8("compliance", &p.compliance), "        ")));
    out.push_str(&format!("        next_page: {},\n", p.next_page));
    out.push_str(&format!("        exit_page: {},\n", p.exit_page));
    out.push_str(&format!("        repeat: {},\n", p.repeat));
    out.push_str(&format!("        speed: {},\n", p.speed));
    out.push_str(&format!("        accel: {},\n", p.accel));
    out.push_str(&format!("        safety_class: SafetyClass::{},\n", safety));
    out.push_str("        steps: vec![\n");
    for s in &p.steps {
        out.push_str("            MotionStep {\n");
        out.push_str(&format!(
            "                positions: {},\n",
            rust_array_u16(&s.positions)
        ));
        out.push_str(&format!("                pause_time: {},\n", s.pause_time));
        out.push_str(&format!("                play_time: {},\n", s.play_time));
        out.push_str("            },\n");
    }
    out.push_str("        ],\n");
    out.push_str("    }\n");
    out.push_str("}\n");
    out
}

fn indent(s: &str, prefix: &str) -> String {
    s.lines()
        .enumerate()
        .map(|(i, l)| if i == 0 { l.to_string() } else { format!("{}{}", prefix, l) })
        .collect::<Vec<_>>()
        .join("\n")
}

fn main() {
    let bin_path = "research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin";
    let raw = match fs::read(bin_path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("failed to read {bin_path}: {e}");
            process::exit(1);
        }
    };
    if raw.len() != 256 * PAGE_BYTES {
        eprintln!("unexpected file size: {} bytes", raw.len());
        process::exit(1);
    }
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: cargo run -p forge-core --example decode_motion -- <page_id> [<page_id> ...]");
        process::exit(2);
    }
    for arg in args {
        let id: u8 = arg.parse().expect("page_id 1..=255");
        let off = id as usize * PAGE_BYTES;
        let page = decode_page(&raw[off..off + PAGE_BYTES], id).expect("decode");
        // safety 추정 — gui_motion.yaml 매핑에 따라 분류.
        let safety = match id {
            1 | 2 | 3 | 4 | 9 | 15 | 23 | 24 | 27 | 38 | 54 => "Safe",
            10 | 11 => "Caution",
            12 | 13 | 17 => "HighRisk",
            _ => "Safe",
        };
        println!("// === page {} ===", id);
        println!("{}", emit_rust(&page, safety));
    }
}
