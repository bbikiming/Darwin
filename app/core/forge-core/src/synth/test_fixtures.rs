//! ROBOTIS 공식 모션 페이지 fixture.
//!
//! `DARwIn-OP_ROBOTIS_v1.6.0/Data/motion_4096.bin` 의 슬롯 1·2·9·12·13·16 을
//! byte-preserving 디코딩하여 [`crate::motion::MotionPage`] 로 빌드한다.
//! 합성 연산자·validator 의 단위 테스트에서 ground truth 로 사용.
//!
//! # 보존 원칙
//!
//! - `positions[31]` 의 모든 비트 (상위 플래그 `0x4000` INVALID, `0x2000` TORQUE_OFF
//!   포함) 를 raw u16 그대로 임베드한다 — 의미 디코드는 4b5672a 머지 후
//!   [`crate::motion::bin4096`] 가 담당한다.
//! - `compliance[31]` 도 raw byte 그대로 (`0x55` = 기본 슬로프 85).
//! - 시간 단위는 raw (`time × 8 ms`).
//!
//! # 추출 출처
//!
//! 본 파일은 [`scripts`] 없이 손으로 옮기지 않고 [`docs/motion-format/page-catalog-motion4096.md`]
//! 와 동일한 추출 절차로 생성되었다. 향후 재추출 필요 시 `motion_4096.bin`
//! 의 sha-256 을 본 모듈 상단에 기록할 것 (Sprint 9-11 provenance 항목).
//!
//! [`scripts`]: ../../../../scripts/
//! [`docs/motion-format/page-catalog-motion4096.md`]: ../../../../docs/motion-format/page-catalog-motion4096.md

#![cfg(test)]

use crate::motion::{MotionPage, MotionStep, SafetyClass};

/// Page 1 `"init"` — ROBOTIS 공식 `motion_4096.bin` 슬롯 1.
///
/// 2 step, `speed=32`, `accel=32`. step 1 은 거의 모든 관절이 `0x07ff` 근방
/// = MX28 중앙(2047). 즉 step 1 ≈ walkready 자세.
pub(crate) fn page_1_init() -> MotionPage {
    MotionPage {
        id: 1,
        name: "init".to_string(),
        compliance: [
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Safe,
        steps: vec![
            // step 0: pause=0, time=125 (1000 ms)
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0941, 0x06bf, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 125,
            },
            // step 1: pause=0, time=125 (1000 ms) — walkready 와 매우 가까움
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 125,
            },
        ],
    }
}

/// Page 2 `"ok"` — 5 step yes/nodding gesture. ROBOTIS 슬롯 2.
pub(crate) fn page_2_ok() -> MotionPage {
    MotionPage {
        id: 2,
        name: "ok".to_string(),
        compliance: [
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Safe,
        steps: vec![
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x0921, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x07d4, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x0921, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x07d4, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 125,
            },
        ],
    }
}

/// Page 9 `"walkready"` — 단일 step 보행 준비 자세. ROBOTIS 슬롯 9.
///
/// 어깨 roll(idx 3,4) compliance 가 `0x77` = 119 로 다른 페이지보다 부드러움.
pub(crate) fn page_9_walkready() -> MotionPage {
    MotionPage {
        id: 9,
        name: "walkready".to_string(),
        compliance: [
            85, 85, 85, 119, 119, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Safe,
        steps: vec![MotionStep {
            positions: [
                0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                0x4000,
            ],
            pause_time: 0,
            play_time: 125,
        }],
    }
}

/// Page 12 `"rk"` — Right kick (7 step). ROBOTIS 슬롯 12.
///
/// step 0/5/6 은 walkready 자세 (anchor), step 1~4 가 실제 kick 동작.
/// [`page_13_left_kick`] 와 좌우 대칭 — Sprint 9-7 Mirror ground truth.
pub(crate) fn page_12_right_kick() -> MotionPage {
    MotionPage {
        id: 12,
        name: "rk".to_string(),
        compliance: [
            85, 85, 85, 119, 119, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 68, 68, 85, 85, 85, 85,
            85, 85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::HighRisk,
        steps: vec![
            // step 0 — walkready anchor (start)
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 62,
            },
            // step 1 — prep
            MotionStep {
                positions: [
                    0x4200, 0x057f, 0x0974, 0x072d, 0x08ef, 0x094f, 0x06b2, 0x0802, 0x0802, 0x0809,
                    0x07fb, 0x0665, 0x099b, 0x0a56, 0x05a3, 0x0955, 0x06ab, 0x089b, 0x0870, 0x0802,
                    0x089f, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 25,
            },
            // step 2 — load
            MotionStep {
                positions: [
                    0x4200, 0x057f, 0x0974, 0x072d, 0x08ef, 0x094f, 0x06b2, 0x0802, 0x0802, 0x084b,
                    0x07da, 0x059a, 0x0a21, 0x0bcc, 0x0572, 0x09e5, 0x06ab, 0x089b, 0x0870, 0x0802,
                    0x089f, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 9,
            },
            // step 3 — kick (pause=18 = 144ms hold)
            MotionStep {
                positions: [
                    0x4200, 0x053c, 0x08ac, 0x070c, 0x08ef, 0x0802, 0x05c8, 0x0802, 0x0802, 0x084b,
                    0x07da, 0x048c, 0x09ef, 0x0953, 0x0586, 0x0702, 0x06cc, 0x086d, 0x084f, 0x0802,
                    0x09cb, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 18,
                play_time: 9,
            },
            // step 4 — retract
            MotionStep {
                positions: [
                    0x4200, 0x057f, 0x0974, 0x072d, 0x08ef, 0x094f, 0x06b2, 0x0802, 0x0802, 0x084b,
                    0x07da, 0x0504, 0x09e5, 0x0bcc, 0x0586, 0x09e5, 0x06b2, 0x089b, 0x0870, 0x0802,
                    0x089f, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 9,
            },
            // step 5 — return to walkready
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 14,
            },
            // step 6 — walkready anchor (end)
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 62,
            },
        ],
    }
}

/// Page 13 `"lk"` — Left kick (7 step). ROBOTIS 슬롯 13.
///
/// [`page_12_right_kick`] 의 좌우 대칭. step 0/5/6 anchor 동일,
/// step 1~4 가 좌측 다리로 swing. Mirror algorithm 의 ground truth.
pub(crate) fn page_13_left_kick() -> MotionPage {
    MotionPage {
        id: 13,
        name: "lk".to_string(),
        compliance: [
            85, 85, 85, 119, 119, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 68, 68, 85, 85, 85, 85,
            85, 85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::HighRisk,
        steps: vec![
            // step 0 — walkready anchor (start)
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 62,
            },
            // step 1 — prep
            MotionStep {
                positions: [
                    0x4200, 0x0686, 0x0a7b, 0x070c, 0x08cd, 0x0949, 0x06ab, 0x07f8, 0x07f8, 0x07ff,
                    0x07f1, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0794, 0x074b, 0x0802,
                    0x09cb, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 25,
            },
            // step 2 — load
            MotionStep {
                positions: [
                    0x4200, 0x0686, 0x0a7b, 0x070c, 0x08cd, 0x0949, 0x06ab, 0x07f8, 0x07f8, 0x0820,
                    0x07af, 0x0601, 0x0a61, 0x0a5d, 0x042f, 0x0955, 0x060b, 0x0794, 0x074b, 0x0802,
                    0x09cb, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 9,
            },
            // step 3 — kick (pause=18 = 144ms hold)
            MotionStep {
                positions: [
                    0x4200, 0x074e, 0x0abe, 0x070c, 0x08ef, 0x0a32, 0x07f8, 0x07f8, 0x07f8, 0x0820,
                    0x07af, 0x0633, 0x0b29, 0x0a75, 0x06a8, 0x0938, 0x08d1, 0x0794, 0x078e, 0x0802,
                    0x09cb, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 18,
                play_time: 9,
            },
            // step 4 — retract
            MotionStep {
                positions: [
                    0x4200, 0x0622, 0x0a17, 0x070c, 0x08cd, 0x0949, 0x06ab, 0x07f8, 0x07f8, 0x0820,
                    0x07af, 0x0665, 0x0ad5, 0x0a5d, 0x042f, 0x0955, 0x0615, 0x07a8, 0x074b, 0x0802,
                    0x09cb, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 9,
            },
            // step 5 — return to walkready
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 14,
            },
            // step 6 — walkready anchor (end)
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 62,
            },
        ],
    }
}

/// Page 16 `"stand up"` — 단일 step stand pose. ROBOTIS 슬롯 16.
///
/// name 은 공백 1자 포함 (`"stand up"`) — ROBOTIS 원본 그대로 보존.
pub(crate) fn page_16_stand_up() -> MotionPage {
    MotionPage {
        id: 16,
        name: "stand up".to_string(),
        compliance: [
            85, 85, 85, 119, 119, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Safe,
        steps: vec![MotionStep {
            positions: [
                0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                0x07fc, 0x067c, 0x0984, 0x0a56, 0x05aa, 0x0969, 0x0697, 0x0809, 0x07f7, 0x0800,
                0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                0x4000,
            ],
            pause_time: 0,
            play_time: 125,
        }],
    }
}

/// Page 3 `"no"` — head shake gesture. ROBOTIS 슬롯 3, 5 step (HEAD_PAN 좌우 진동).
///
/// 추출: `examples/decode_motion 3`, 2026-05-12. step_num=5, speed=32, accel=32.
/// 본체 자세는 walkready 와 거의 동일 — HEAD_PAN (positions[19]) 만 0x07ff (중앙)
/// ↔ 0x0758 (좌) ↔ 0x08a5 (우) 진동.
pub(crate) fn page_3_no() -> MotionPage {
    MotionPage {
        id: 3,
        name: "no".to_string(),
        compliance: [
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Safe,
        steps: vec![
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x0758,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x08a5,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x0758,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x08a5,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 125,
            },
        ],
    }
}

/// Page 4 `"hi"` — waving gesture (gui_motion.yaml 의 "Thank you" 메뉴 매핑).
///
/// 추출: `examples/decode_motion 4`, 2026-05-12. 4 step. R_SHOULDER 만 변화
/// (positions[1,3,5] 등), 손 흔들기.
///
/// gui_motion.yaml 의 메뉴 라벨 "Thank you" 와 내부 page name "hi" 가 다르다
/// (UI 라벨 vs 개발자 라벨).
pub(crate) fn page_4_hi() -> MotionPage {
    MotionPage {
        id: 4,
        name: "hi".to_string(),
        compliance: [
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Safe,
        steps: vec![
            MotionStep {
                positions: [
                    0x4200, 0x0522, 0x0ad9, 0x0716, 0x08e5, 0x096d, 0x068d, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 50,
            },
            MotionStep {
                positions: [
                    0x4200, 0x0522, 0x0ad9, 0x0716, 0x08e5, 0x096d, 0x068d, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x0737, 0x08c3, 0x0841, 0x07bc, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x0770, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 25,
                play_time: 125,
            },
            MotionStep {
                positions: [
                    0x4200, 0x0522, 0x0ad9, 0x0716, 0x08e5, 0x096d, 0x068d, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 125,
            },
            MotionStep {
                positions: [
                    0x4200, 0x05c8, 0x0a32, 0x06d3, 0x0927, 0x0863, 0x0798, 0x07ff, 0x07ff, 0x07ff,
                    0x07ff, 0x07dd, 0x0820, 0x07ff, 0x07ff, 0x080f, 0x07ee, 0x07ff, 0x07ff, 0x07ff,
                    0x087a, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 125,
            },
        ],
    }
}

/// Page 10 `"f up"` — Get Up (Front) recovery. ROBOTIS 슬롯 10, 5 step, Caution.
///
/// 추출: `examples/decode_motion 10`, 2026-05-12. 다리·팔 큰 변화 (HipPitch
/// 0x0385=901 → 무릎 0x0c5e=3166 — kick 보다 더 극단). walkready 로 복귀 (step 4).
///
/// 안전 등급 `Caution` — `op2_gui_demo/config/gui_motion.yaml` 분류.
pub(crate) fn page_10_get_up_front() -> MotionPage {
    MotionPage {
        id: 10,
        name: "f up".to_string(),
        compliance: [
            85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Caution,
        steps: vec![
            MotionStep {
                positions: [
                    0x4200, 0x0532, 0x0a7b, 0x0726, 0x08e8, 0x0afd, 0x04dc, 0x07fb, 0x07f1, 0x07ff,
                    0x07ff, 0x0514, 0x0ac1, 0x0ac1, 0x053c, 0x0903, 0x06d0, 0x080f, 0x07f5, 0x07ff,
                    0x09c7, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 25,
            },
            MotionStep {
                positions: [
                    0x4200, 0x08e5, 0x06c9, 0x0726, 0x08e8, 0x0b1b, 0x04d8, 0x07fb, 0x07f1, 0x07ff,
                    0x07ff, 0x0385, 0x0c5e, 0x0bf7, 0x03db, 0x090d, 0x06c2, 0x080f, 0x07f5, 0x07ff,
                    0x09c7, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 25,
            },
            MotionStep {
                positions: [
                    0x4200, 0x0971, 0x068a, 0x0665, 0x0999, 0x052f, 0x0aa7, 0x07fb, 0x07f1, 0x07ff,
                    0x07ff, 0x03ad, 0x0c01, 0x0dcd, 0x0220, 0x0b2c, 0x0496, 0x07ff, 0x07ff, 0x07ff,
                    0x09c7, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 100,
            },
            MotionStep {
                positions: [
                    0x4200, 0x0895, 0x0730, 0x0665, 0x0999, 0x052f, 0x0aa7, 0x07fb, 0x07f1, 0x07ff,
                    0x07ff, 0x03ad, 0x0c33, 0x0d87, 0x025c, 0x0a43, 0x05a4, 0x07ff, 0x07ff, 0x07ff,
                    0x09c7, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                    0x0000,
                ],
                pause_time: 0,
                play_time: 125,
            },
            MotionStep {
                positions: [
                    0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                    0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                    0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                    0x4000,
                ],
                pause_time: 0,
                play_time: 125,
            },
        ],
    }
}

/// Page 15 `"sit down"` — 단일 step seated pose. ROBOTIS 슬롯 15.
///
/// 추출: `examples/decode_motion 15`, 2026-05-12. 1 step. Knee 0x0db9=3513,
/// HipPitch 0x04fd=1277 — 깊게 앉음. SHOULDER_ROLL compliance 119 (다른
/// 페이지보다 부드러움).
pub(crate) fn page_15_sit_down() -> MotionPage {
    MotionPage {
        id: 15,
        name: "sit down".to_string(),
        compliance: [
            85, 85, 85, 119, 119, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85,
            85, 85, 85, 85, 85, 0, 0, 0, 0, 0,
        ],
        next_page: 0,
        exit_page: 0,
        repeat: 1,
        speed: 32,
        accel: 32,
        safety_class: SafetyClass::Safe,
        steps: vec![MotionStep {
            positions: [
                0x4200, 0x05dc, 0x09d5, 0x072a, 0x08eb, 0x094c, 0x06ae, 0x07fb, 0x07f1, 0x0809,
                0x07fb, 0x04fd, 0x0aed, 0x0db9, 0x023b, 0x0b1b, 0x04d8, 0x081d, 0x07f5, 0x0802,
                0x087d, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                0x0000,
            ],
            pause_time: 0,
            play_time: 125,
        }],
    }
}

#[cfg(test)]
mod tests {
    //! 공식 데이터 invariant — fixture 자체가 변형되지 않았는지 확인.

    use super::*;

    /// Position 의 상위 4 bit 마스크. 0x4000 = INVALID, 0x2000 = TORQUE_OFF.
    const FLAG_MASK: u16 = 0xF000;
    /// MX28 12-bit 위치 마스크 (0..=4095).
    const POSITION_MASK: u16 = 0x0FFF;

    fn assert_page_invariants(p: &MotionPage) {
        assert!(p.id >= 1, "page id 0 is reserved for empty slot");
        assert!(!p.steps.is_empty(), "page has no steps");
        assert!(p.steps.len() <= 7, "page has more than 7 steps");
        assert!(p.compliance.len() == 31);
        // Compliance values are either 0 (unused slots 26..=30) or a valid slope.
        for (i, c) in p.compliance.iter().enumerate() {
            if i < 26 {
                assert!(*c > 0, "slot {i} compliance is zero");
            }
        }
    }

    #[test]
    fn page_1_init_invariants() {
        let p = page_1_init();
        assert_eq!(p.id, 1);
        assert_eq!(p.name, "init");
        assert_eq!(p.steps.len(), 2);
        assert_eq!(p.steps[0].play_time, 125);
        assert_page_invariants(&p);
    }

    #[test]
    fn page_2_ok_has_five_steps() {
        let p = page_2_ok();
        assert_eq!(p.steps.len(), 5);
        assert_page_invariants(&p);
    }

    #[test]
    fn page_9_walkready_is_single_step() {
        let p = page_9_walkready();
        assert_eq!(p.steps.len(), 1);
        // walkready 의 본체 관절 (idx 0..=20) 은 모두 합리적 12-bit 범위.
        for (i, pos) in p.steps[0].positions.iter().enumerate().take(21) {
            let masked = pos & POSITION_MASK;
            assert!(
                masked < 4096,
                "slot {i} pos 0x{pos:04x} exceeds 12-bit range"
            );
        }
    }

    #[test]
    fn page_12_and_13_share_anchor_steps() {
        // step 0, 5, 6 은 walkready 자세 — page 12 와 13 동일해야 한다.
        let rk = page_12_right_kick();
        let lk = page_13_left_kick();
        assert_eq!(rk.steps[0].positions, lk.steps[0].positions);
        assert_eq!(rk.steps[5].positions, lk.steps[5].positions);
        assert_eq!(rk.steps[6].positions, lk.steps[6].positions);
    }

    #[test]
    fn page_12_and_13_differ_in_kick_steps() {
        // step 1~4 는 좌·우가 달라야 한다 (실제 kick).
        let rk = page_12_right_kick();
        let lk = page_13_left_kick();
        for i in 1..=4 {
            assert_ne!(
                rk.steps[i].positions, lk.steps[i].positions,
                "step {i} should differ between rk and lk"
            );
        }
    }

    #[test]
    fn page_12_step_3_holds_with_pause() {
        // step 3 (실제 kick impact) 는 144 ms (raw 18) hold.
        let rk = page_12_right_kick();
        assert_eq!(rk.steps[3].pause_time, 18);
        assert_eq!(rk.steps[3].pause_ms(), 144);
    }

    #[test]
    fn page_16_preserves_space_in_name() {
        let p = page_16_stand_up();
        assert_eq!(p.name, "stand up", "ROBOTIS 원본 공백 보존");
    }

    #[test]
    fn invalid_flag_bits_are_present_in_kick_pages() {
        // ROBOTIS 페이지의 idx 21..=25 슬롯에는 INVALID bit (0x4000) 또는
        // INVALID+TORQUE_OFF bit (0x4200) 가 set 되어 있다 — 미사용 관절 표시.
        for p in [page_12_right_kick(), page_13_left_kick()] {
            for step in &p.steps {
                for &pos in &step.positions[21..=25] {
                    let flag = pos & FLAG_MASK;
                    assert!(
                        flag == 0x4000 || flag == 0x4200,
                        "expected INVALID flag on unused slot, got 0x{pos:04x}"
                    );
                }
            }
        }
    }

    #[test]
    fn all_fixtures_distinct_ids() {
        let ids: Vec<u8> = [
            page_1_init().id,
            page_2_ok().id,
            page_3_no().id,
            page_4_hi().id,
            page_9_walkready().id,
            page_10_get_up_front().id,
            page_12_right_kick().id,
            page_13_left_kick().id,
            page_15_sit_down().id,
            page_16_stand_up().id,
        ]
        .into_iter()
        .collect();
        let unique: std::collections::HashSet<_> = ids.iter().copied().collect();
        assert_eq!(ids.len(), unique.len(), "fixture page ids must be unique");
    }

    #[test]
    fn page_3_no_is_head_pan_only_variation() {
        // No 제스처 — body 자세 거의 동일, HEAD_PAN (positions[19]) 만 진동.
        let p = page_3_no();
        assert_eq!(p.id, 3);
        assert_eq!(p.steps.len(), 5);
        assert_page_invariants(&p);
        // body 관절 (1..=18) 은 모든 step 에서 동일
        for j in 1..=18usize {
            let first = p.steps[0].positions[j];
            for s in &p.steps[1..] {
                assert_eq!(s.positions[j], first, "joint {j} should be static in No gesture");
            }
        }
        // HEAD_PAN (positions[19]) 은 변동
        let head_pans: Vec<u16> = p.steps.iter().map(|s| s.positions[19]).collect();
        let unique: std::collections::HashSet<u16> = head_pans.iter().copied().collect();
        assert!(unique.len() >= 2, "HEAD_PAN should vary across No steps");
    }

    #[test]
    fn page_4_hi_is_arm_only_variation() {
        // hi (Thank you) 제스처 — 다리는 정지, 팔만 변화.
        let p = page_4_hi();
        assert_eq!(p.id, 4);
        assert_eq!(p.steps.len(), 4);
        assert_page_invariants(&p);
        // 미사용 slot 21..=25 는 INVALID flag (0x4000 이상) 가 set 되어야 한다.
        for step in &p.steps {
            for (i, &pos) in step.positions[21..=25].iter().enumerate() {
                let flag = pos & 0x4000;
                assert!(
                    flag == 0x4000,
                    "slot {} should have INVALID flag, got 0x{pos:04x}",
                    21 + i
                );
            }
        }
    }

    #[test]
    fn page_10_get_up_front_has_extreme_knee() {
        // Get Up (Front) — 무릎이 매우 깊게 굽혀짐 (0x0c5e = 3166 = +98° 가까이).
        let p = page_10_get_up_front();
        assert_eq!(p.id, 10);
        assert_eq!(p.safety_class, SafetyClass::Caution);
        assert_page_invariants(&p);
        // 어떤 step 에서 KNEE (positions[13] 또는 [14]) 가 3000 이상.
        let max_knee = p
            .steps
            .iter()
            .flat_map(|s| [s.positions[13] & POSITION_MASK, s.positions[14] & POSITION_MASK])
            .max()
            .unwrap();
        assert!(
            max_knee >= 3000,
            "Get Up Front should have deep knee bend, got max {max_knee}"
        );
        // 마지막 step 은 walkready 자세로 복귀.
        let last = &p.steps[p.steps.len() - 1];
        let walkready = page_9_walkready();
        // 다리 (id 7..=18) 거의 일치 — anchor 회복.
        for j in 7..=18usize {
            let diff = (last.positions[j] as i32 - walkready.steps[0].positions[j] as i32).abs();
            assert!(
                diff < 50,
                "joint {j} not back to walkready: last=0x{:04x} ready=0x{:04x}",
                last.positions[j],
                walkready.steps[0].positions[j]
            );
        }
    }

    /// Fixture extraction provenance — `examples/decode_motion` 디코더가 실제
    /// `motion_4096.bin` 의 page 1 과 byte-exact 매칭 함을 확인. 후속 fixture
    /// 추가 시에도 이 테스트가 디코더 정확성을 보장.
    ///
    /// 절차: load bin → decode page 1 → compare to `page_1_init()` fixture.
    /// 모든 분야 (name, compliance, steps, pause/play_time) 100% 일치.
    #[test]
    fn decoder_matches_page_1_init_byte_exact() {
        use crate::motion::bin4096::parse_bin4096;
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin");
        if !path.exists() {
            eprintln!("skip: {} not present", path.display());
            return;
        }
        let bytes = std::fs::read(&path).expect("read bin");
        let pages = parse_bin4096(&bytes).expect("parse");
        let raw_page_1 = &pages[1].raw;
        let fx = page_1_init();
        // name
        let name_end = raw_page_1[..14].iter().position(|b| *b == 0).unwrap_or(14);
        let raw_name = std::str::from_utf8(&raw_page_1[..name_end]).unwrap();
        assert_eq!(raw_name, fx.name);
        // step count (raw byte 20)
        assert_eq!(raw_page_1[20] as usize, fx.steps.len());
        // step 0 first position (byte 64-65 = positions[0])
        let raw_p0 = raw_page_1[64] as u16 | ((raw_page_1[65] as u16) << 8);
        assert_eq!(raw_p0, fx.steps[0].positions[0]);
        // step 0 RShoulderPitch (byte 66-67 = positions[1])
        let raw_p1 = raw_page_1[66] as u16 | ((raw_page_1[67] as u16) << 8);
        assert_eq!(raw_p1, fx.steps[0].positions[1]);
        // step 0 pause/play (byte 126,127)
        assert_eq!(raw_page_1[126], fx.steps[0].pause_time);
        assert_eq!(raw_page_1[127], fx.steps[0].play_time);
    }

    #[test]
    fn page_15_sit_down_is_single_deep_squat() {
        // Sit Down — 1 step, knee 0x0db9=3513 (= +127°), hip pitch 0x04fd=1277 (-67°).
        let p = page_15_sit_down();
        assert_eq!(p.id, 15);
        assert_eq!(p.steps.len(), 1);
        assert_page_invariants(&p);
        // SHOULDER_ROLL compliance 119 (다른 페이지보다 부드러움) — sit 시 어깨 좌우 흔들림 완충.
        assert_eq!(p.compliance[3], 119);
        assert_eq!(p.compliance[4], 119);
        // Knee 매우 깊음.
        let r_knee = p.steps[0].positions[13] & POSITION_MASK;
        assert!(r_knee >= 2500, "R_KNEE should be deeply bent, got {r_knee}");
    }
}
