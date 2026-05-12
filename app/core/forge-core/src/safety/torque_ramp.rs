//! 토크 enable 시 단계별 P_GAIN ramp.
//!
//! 모터를 즉시 최대 토크로 깨우면 "둠칫" 현상이 발생 — walkReady 같은 자세
//! 차이가 큰 명령에서 모터에 충격이 가해진다. 단계별 P_GAIN ramp로 부드럽게
//! 깨우고, 추가로 자세 보간(`walk::ini_pose::interpolate`)을 결합해 안전한
//! 활성화 흐름을 제공한다.
//!
//! # 흐름
//!
//! 1. P_GAIN = 0 (무토크) 으로 SYNC_WRITE.
//! 2. TORQUE_ENABLE = 1 (토크 enable이지만 P=0이라 실 토크는 0).
//! 3. P_GAIN을 profile.steps 만큼 8 → 16 → 32 단계적으로 SYNC_WRITE, 각 step
//!    사이 profile.step_period 만큼 sleep.
//! 4. 최종 P=32 (공식 op2_walking_module 기본값) 도달.
//!
//! 호출자가 sleep을 책임 (이 모듈은 sleep 함수 직접 호출 안 함 — 단위 테스트
//! 가능성을 위해).
//!
//! # Provenance — `[0, 8, 16, 32]` ramp 결정 근거 (2026-05-12 정리)
//!
//! 본 ramp 프로파일은 **ROBOTIS 원본에 직접 명시되지 않은 자체 설계** — 다음
//! 근거로 결정:
//!
//! - **최종 32** : `op2_walking_module/config/param.yaml` 의 `p_gain: 32` 공식
//!   기본값. ROBOTIS 가 워킹·모션 양쪽에서 사용하는 표준 P-gain.
//! - **시작 0**  : Dynamixel `P_GAIN=0` 은 효과적으로 모터 disable 과 동등 —
//!   TORQUE_ENABLE 명령 자체는 즉시 받지만 PID 계산 결과가 0 이라 실 토크 없음.
//!   토크-on 순간 갑작스러운 자세 보정 (motor 가 현재 위치 → goal position 으로
//!   강제 이동) 을 방지한다.
//! - **중간 8, 16** : 32 의 25% / 50% — 4 단계 ramp 가 1·2 단계보다 부드럽고
//!   8 단계 미세 ramp 보다 빠르다. 200 ms × 4 = **800 ms 총 ramp** 가 사용자가
//!   "기다림"으로 인지 가능한 임계 안.
//! - **2단계 quick (`[16, 32]`)** : 이미 자세가 walkReady 인근이라 충격 위험 낮은
//!   상황 (예: 모션 사이 연속 재생). 400 ms.
//!
//! 본 ramp 값은 실 모터 실측 검증이 아직 미완 (BLOCKER M3). 실측 후 조정 가능.
//! `safety::torque_ramp::tests` 의 회귀 테스트는 ramp **순서·총 step** 만 lock,
//! 구체값은 변경 가능하도록 의도적으로 느슨함.

use std::time::Duration;

use crate::control::JointController;
use crate::error::Result;
use crate::joint::JointId;
use crate::serial::SerialPort;

/// P_GAIN ramp profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TorqueRampProfile {
    /// 각 step에서 보낼 P_GAIN. 길이 N 이면 N step ramp.
    pub p_gain_steps: &'static [u8],
    /// 각 step 사이 대기 (호출자가 sleep).
    pub step_period: Duration,
}

impl Default for TorqueRampProfile {
    /// 권장 default — 4 단계 800 ms 총.
    fn default() -> Self {
        Self::gentle()
    }
}

impl TorqueRampProfile {
    /// 부드러운 4단계 — 800 ms 전체. walkReady 같은 큰 자세 변화에 권장.
    ///
    /// 첫 step P=0 = 무토크에서 TORQUE_ENABLE 켜기. 마지막 P=32 = 공식 default.
    pub fn gentle() -> Self {
        Self {
            p_gain_steps: &[0, 8, 16, 32],
            step_period: Duration::from_millis(200),
        }
    }

    /// 빠른 2단계 — 400 ms. 이미 자세가 안정적일 때.
    pub fn quick() -> Self {
        Self {
            p_gain_steps: &[16, 32],
            step_period: Duration::from_millis(200),
        }
    }

    /// 진단용 — 최저 토크 유지. 사용자가 손으로 자세 조정 가능.
    pub fn manual_hold() -> Self {
        Self {
            p_gain_steps: &[8],
            step_period: Duration::from_millis(0),
        }
    }
}

/// 토크 ramp 실행기 — `Iterator`로 step을 노출, 호출자가 sleep 사이 추가 작업
/// (자세 보간 등) 가능.
///
/// # 사용 패턴
///
/// ```ignore
/// let profile = TorqueRampProfile::gentle();
/// let mut ramper = TorqueRamper::new(&JointId::ALL, profile);
/// ramper.enable_torque(&mut jc)?;            // step 0: P=0 + torque on
/// for _ in 1..profile.p_gain_steps.len() {
///     std::thread::sleep(profile.step_period);
///     ramper.next_step(&mut jc)?;            // P=8, 16, 32 차례
/// }
/// ```
pub struct TorqueRamper {
    joints: Vec<JointId>,
    profile: TorqueRampProfile,
    cursor: usize,
}

impl TorqueRamper {
    /// 새 ramp. 대상 관절 + profile.
    pub fn new(joints: &[JointId], profile: TorqueRampProfile) -> Self {
        Self {
            joints: joints.to_vec(),
            profile,
            cursor: 0,
        }
    }

    /// 시작 — 첫 P_GAIN 적용 + TORQUE_ENABLE.
    pub fn enable_torque<P: SerialPort>(&mut self, jc: &mut JointController<'_, P>) -> Result<()> {
        // step 0의 P_GAIN.
        let p0 = self.profile.p_gain_steps[0];
        jc.set_p_gain_many(&self.joints, p0)?;
        // 그 후 TORQUE_ENABLE = 1. P=0이라 실 토크 발생 안 함.
        jc.set_torque_many(&self.joints, true)?;
        self.cursor = 1;
        Ok(())
    }

    /// 다음 step P_GAIN 발사. 더 이상 step 없으면 no-op.
    pub fn next_step<P: SerialPort>(&mut self, jc: &mut JointController<'_, P>) -> Result<bool> {
        if self.cursor >= self.profile.p_gain_steps.len() {
            return Ok(false);
        }
        let p = self.profile.p_gain_steps[self.cursor];
        jc.set_p_gain_many(&self.joints, p)?;
        self.cursor += 1;
        Ok(true)
    }

    /// 남은 step 수.
    pub fn remaining(&self) -> usize {
        self.profile.p_gain_steps.len().saturating_sub(self.cursor)
    }

    /// 마지막 P_GAIN.
    pub fn final_p_gain(&self) -> u8 {
        *self.profile.p_gain_steps.last().unwrap_or(&32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dynamixel::Bus;
    use crate::serial::LoopbackBus;

    #[test]
    fn gentle_profile_has_four_steps_ending_at_32() {
        let p = TorqueRampProfile::gentle();
        assert_eq!(p.p_gain_steps, &[0, 8, 16, 32]);
        assert_eq!(p.step_period, Duration::from_millis(200));
    }

    #[test]
    fn enable_torque_writes_p_gain_then_torque() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = JointController::new(&mut bus);
        let mut ramper = TorqueRamper::new(
            &[JointId::HeadPan, JointId::HeadTilt],
            TorqueRampProfile::gentle(),
        );
        ramper.enable_torque(&mut jc).unwrap();
        let written = bus.port_mut().written.clone();
        // 첫 SYNC_WRITE = P_GAIN(28) 두 관절 P=0.
        assert_eq!(written[5], crate::controller::mx28_register::P_GAIN);
        // 두 번째 SYNC_WRITE = TORQUE_ENABLE(24) 두 관절 = 1.
        // 첫 패킷 길이는 FF FF FE LEN 0x83 ADDR LENGTH (ID DATA)+ checksum
        // 두 관절 × (1 ID + 1 데이터) = 4 바이트 + 4 헤더 = 8 = LEN byte.
        // 두 번째 패킷의 시작 offset = 위 길이 + 4 (FF FF FE LEN).
        // 안전하게 두 번째 SYNC_WRITE 헤더만 검색.
        let second_start = written
            .iter()
            .enumerate()
            .skip(7)
            .find(|(_, &b)| b == 0xFF)
            .map(|(i, _)| i)
            .unwrap();
        assert_eq!(
            written[second_start + 5],
            crate::controller::mx28_register::TORQUE_ENABLE
        );
    }

    #[test]
    fn next_step_advances_through_profile() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = JointController::new(&mut bus);
        let mut ramper = TorqueRamper::new(&[JointId::HeadPan], TorqueRampProfile::gentle());
        ramper.enable_torque(&mut jc).unwrap();
        assert_eq!(ramper.remaining(), 3);
        assert!(ramper.next_step(&mut jc).unwrap());
        assert!(ramper.next_step(&mut jc).unwrap());
        assert!(ramper.next_step(&mut jc).unwrap());
        // 4 step 다 끝.
        assert!(!ramper.next_step(&mut jc).unwrap());
        assert_eq!(ramper.remaining(), 0);
    }

    #[test]
    fn final_p_gain_matches_official_op2_walking_default() {
        // op2_walking_module/config/param.yaml:20 p_gain: 32.
        let ramper = TorqueRamper::new(&[JointId::HeadPan], TorqueRampProfile::gentle());
        assert_eq!(ramper.final_p_gain(), 32);
    }

    #[test]
    fn manual_hold_profile_keeps_low_p_gain_for_human_posing() {
        // 사용자가 손으로 자세 변경 가능한 hold 상태.
        let p = TorqueRampProfile::manual_hold();
        assert_eq!(p.p_gain_steps, &[8]);
    }
}
