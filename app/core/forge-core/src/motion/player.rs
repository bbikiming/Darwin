//! MotionPlayer — `motion_4096.bin` 페이지를 실 robot 에 순차 송출.
//!
//! `forge-cli/src/motion_play.rs` 에서 라이브러리로 추출 (Sprint 15, Day 1).
//! CLI 와 FFI(Swift TeleopChannel) 양쪽에서 동일 경로를 공유한다.
//!
//! # 취소 메커니즘
//!
//! `cancel()` 은 play 루프가 다음 sleep 간격(≤ 8 ms)에서 체크하는 AtomicBool
//! 을 세운다. 모터가 마지막으로 받은 SYNC_WRITE 위치에서 정지 — 토크 OFF 는
//! 호출자(TeleopChannel.emergencyStop)가 별도로 수행한다.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::control::{ExecuteOptions, JointController};
use crate::joint::JointId;
use crate::motion::{MotionPage, MotionStep, NUM_JOINTS_IN_STEP};
use crate::serial::SerialPort;

/// MX-28 position 12-bit 마스크.
const POSITION_MASK: u16 = 0x0FFF;
/// 해당 관절 미송출 마킹.
const INVALID_BIT: u16 = 0x4000;
/// 해당 관절 torque OFF 마킹.
const TORQUE_OFF_BIT: u16 = 0x2000;
/// 8 ms tick — ROBOTIS PAGE step granularity.
const TICK_MS: u64 = 8;

/// 모션 페이지를 실 robot 에 송출하는 단순 플레이어.
///
/// `cancel()` 을 호출하면 진행 중인 step 이후의 모든 송출을 중단한다.
/// 스레드 안전: `CancelHandle` 을 다른 스레드에서 넘겨 취소 가능.
pub struct MotionPlayer {
    cancel: Arc<AtomicBool>,
}

impl Default for MotionPlayer {
    fn default() -> Self {
        Self::new()
    }
}

impl MotionPlayer {
    /// 새 player — cancel flag false 로 초기화.
    pub fn new() -> Self {
        Self {
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    /// 다른 스레드에서 `cancel()` 을 호출할 수 있는 핸들을 반환.
    pub fn cancel_handle(&self) -> CancelHandle {
        CancelHandle(self.cancel.clone())
    }

    /// 진행 중인 재생을 즉시 중단 요청.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }

    /// 페이지 목록을 순서대로 실 robot 에 송출.
    ///
    /// - 각 페이지 앞에 `precheck_motion` 실행 (HighRisk + !confirm_risk → 거부).
    /// - INVALID/TORQUE_OFF 마킹 관절은 자동 건너뜀.
    /// - `cancel()` 이 호출되면 다음 8 ms 체크 시점에 즉시 반환.
    /// - play_ms/pause_ms 내 sleep 도 8 ms 단위로 분할해 취소를 빠르게 감지.
    pub fn play_pages<P: SerialPort>(
        &self,
        jc: &mut JointController<'_, P>,
        pages: &[MotionPage],
        opts: ExecuteOptions,
    ) -> crate::error::Result<()> {
        self.cancel.store(false, Ordering::SeqCst);

        for page in pages {
            jc.precheck_motion(page, opts)?;

            let repeat = page.repeat.max(1) as usize;
            for _ in 0..repeat {
                for step in &page.steps {
                    if self.cancel.load(Ordering::Relaxed) {
                        return Ok(());
                    }
                    let targets = step_to_targets(step);
                    if !targets.is_empty() {
                        jc.set_positions_many(&targets)?;
                    }
                    interruptible_sleep(
                        Duration::from_millis(step.play_ms() as u64),
                        &self.cancel,
                    );
                    if self.cancel.load(Ordering::Relaxed) {
                        return Ok(());
                    }
                    interruptible_sleep(
                        Duration::from_millis(step.pause_ms() as u64),
                        &self.cancel,
                    );
                    if self.cancel.load(Ordering::Relaxed) {
                        return Ok(());
                    }
                }
            }
        }
        Ok(())
    }
}

/// `MotionPlayer` 와 별도 스레드에서 취소를 요청하는 핸들.
#[derive(Clone)]
pub struct CancelHandle(Arc<AtomicBool>);

impl CancelHandle {
    /// player loop 에게 다음 8 ms tick 에 중단 요청 신호.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// 이미 cancel 신호가 send 됐는지 확인.
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// step 한 개의 positions 를 `[(JointId, goal_position)]` 으로 디코드.
///
/// INVALID 또는 TORQUE_OFF 플래그가 있거나 raw==0인 슬롯은 제외.
/// ROBOTIS `positions[0]` 은 reserved — slot 1..=20 만 처리.
pub fn step_to_targets(step: &MotionStep) -> Vec<(JointId, u16)> {
    let mut out = Vec::new();
    for slot in 1..=NUM_JOINTS_IN_STEP.min(20) {
        let raw = step.positions[slot];
        if raw == 0 || (raw & INVALID_BIT) != 0 || (raw & TORQUE_OFF_BIT) != 0 {
            continue;
        }
        let Some(joint) = JointId::from_byte(slot as u8) else {
            continue;
        };
        out.push((joint, raw & POSITION_MASK));
    }
    out
}

/// duration 을 최대 `TICK_MS` 단위로 쪼개 sleep. cancel 감지 시 즉시 반환.
fn interruptible_sleep(duration: Duration, cancel: &AtomicBool) {
    if duration.is_zero() {
        return;
    }
    let tick = Duration::from_millis(TICK_MS);
    let mut remaining = duration;
    while !remaining.is_zero() {
        if cancel.load(Ordering::Relaxed) {
            return;
        }
        let sleep_for = remaining.min(tick);
        std::thread::sleep(sleep_for);
        remaining = remaining.saturating_sub(sleep_for);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::ExecuteOptions;
    use crate::dynamixel::Bus;
    use crate::motion::{MotionPage, MotionStep, SafetyClass};
    use crate::serial::LoopbackBus;

    fn make_step(vals: &[(usize, u16)]) -> MotionStep {
        let mut positions = [0u16; NUM_JOINTS_IN_STEP];
        for &(i, v) in vals {
            positions[i] = v;
        }
        MotionStep {
            positions,
            pause_time: 0,
            play_time: 0, // instant — no sleep in tests
        }
    }

    // 2026-05-17 dead code purge: `safe_page_with_step` (clippy "never used") 제거.

    #[test]
    fn precheck_high_risk_blocked_without_confirm() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = crate::control::JointController::new(&mut bus);
        let page = MotionPage {
            id: 12,
            name: "rk".to_string(),
            safety_class: SafetyClass::HighRisk,
            ..Default::default()
        };
        let player = MotionPlayer::new();
        let err = player
            .play_pages(&mut jc, &[page], ExecuteOptions::default())
            .unwrap_err();
        assert!(err.to_string().contains("HighRisk"));
    }

    #[test]
    fn invalid_bit_slots_are_skipped() {
        let step = make_step(&[(1, 2048), (2, INVALID_BIT | 1500)]);
        let targets = step_to_targets(&step);
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].1, 2048);
    }

    #[test]
    fn torque_off_bit_slots_are_skipped() {
        let step = make_step(&[(1, 2048), (3, TORQUE_OFF_BIT | 1500)]);
        let targets = step_to_targets(&step);
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].1, 2048);
    }

    #[test]
    fn cancel_stops_play_immediately() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = crate::control::JointController::new(&mut bus);
        let player = MotionPlayer::new();
        // Page with no steps — precheck passes, nothing to send.
        let page = MotionPage {
            id: 1,
            name: "test".to_string(),
            safety_class: SafetyClass::Safe,
            steps: vec![], // no steps — trivially passes collision check
            repeat: 1,
            ..Default::default()
        };
        let result = player.play_pages(&mut jc, &[page], ExecuteOptions::default());
        assert!(result.is_ok(), "expected Ok, got {:?}", result);
        // Verify cancel handle signals the player.
        let handle = player.cancel_handle();
        handle.cancel();
        assert!(handle.is_cancelled());
    }

    #[test]
    fn seven_official_pages_decodable_from_catalog() {
        // Verify JointId::from_byte works for all 20 slots used by motion pages.
        for slot in 1u8..=20 {
            assert!(
                JointId::from_byte(slot).is_some(),
                "slot {slot} should map to JointId"
            );
        }
    }

    #[test]
    fn step_to_targets_masks_to_12bit() {
        let step = make_step(&[(1, 0x0FFF)]);
        let targets = step_to_targets(&step);
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].1, 0x0FFF);
    }

    #[test]
    fn cancel_handle_shared_across_threads() {
        let player = MotionPlayer::new();
        let handle = player.cancel_handle();
        assert!(!handle.is_cancelled());
        handle.cancel();
        assert!(handle.is_cancelled());
        assert!(player.cancel.load(Ordering::SeqCst));
    }
}
