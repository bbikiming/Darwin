//! §C v1 14-token 명령 라인 빌더 — `ssh_control_client.py::_build_line/_gait_params`
//! 의 1:1 포팅.
//!
//! 토큰 순서는 WalkLabBrokerage.cpp::ParseAndApply 에 고정:
//!   {cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip}
//!   {bgain} {benable} {blevel} {headPan} {headTilt} {ballTrack}
//! bgain/benable/blevel 은 Python 원본과 동일하게 "1.0 0 2" 고정, ballTrack 은
//! W0 범위에서 0 고정(볼트랙 토글은 ally-input W1).

/// 한 틱의 조종 의도 — Python `mapping.MotionCommand` 등가(speed_scale 은
/// 라인 직렬화에 쓰이지 않아 제외).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MotionCommand {
    pub enabled: bool,
    pub stride_mm: f64,
    pub side_mm: f64,
    pub turn_deg: f64,
    pub head_pan_deg: f64,
    pub head_tilt_deg: f64,
}

impl MotionCommand {
    /// 정지 명령 (enabled=0 + 전축 0) — failsafe 의 zero 주입에 쓴다.
    pub fn zero() -> Self {
        MotionCommand {
            enabled: false,
            stride_mm: 0.0,
            side_mm: 0.0,
            turn_deg: 0.0,
            head_pan_deg: 0.0,
            head_tilt_deg: 0.0,
        }
    }
}

/// 게이트 보간 설정 — Python `SshControlClient` 의 gait 필드 등가.
/// 기본값은 Python DEFAULT_* (Switch 검증값). Ally 콕핏(W1)은 G01 온보드
/// 스케줄과 같은 체감을 위해 `ally-input::g01` 의 700→560ms/18→40mm 를 주입한다.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GaitConfig {
    pub period_ms: f64,
    pub foot_mm: f64,
    pub hip_deg: f64,
    pub min_period_ms: f64,
    pub max_period_ms: f64,
    pub min_foot_mm: f64,
    pub stride_ref_mm: f64,
    pub turn_ref_deg: f64,
}

impl Default for GaitConfig {
    fn default() -> Self {
        // ssh_control_client.py DEFAULT_PERIOD_MS 등과 1:1.
        GaitConfig {
            period_ms: 600.0,
            foot_mm: 40.0,
            hip_deg: 13.0,
            min_period_ms: 520.0,
            max_period_ms: 780.0,
            min_foot_mm: 18.0,
            stride_ref_mm: 25.0,
            turn_ref_deg: 12.0,
        }
    }
}

/// 입력 강도에 따라 period/foot 를 보간 — `_gait_params` 등가.
///
/// WalkLab 의 체감 속도는 stride 만으로 정해지지 않는다: 케이던스(period)와
/// 발 들기(foot)를 intensity^0.7 곡선으로 함께 보간해 저강도 입력이 실제로
/// 느려지게 한다(풀스틱은 설정 최대 게이트 유지).
pub fn gait_params(cfg: &GaitConfig, cmd: &MotionCommand) -> (f64, f64) {
    if !cmd.enabled {
        return (cfg.period_ms, cfg.foot_mm);
    }
    let stride_i = cmd.stride_mm.abs() / cfg.stride_ref_mm.abs().max(1.0);
    let side_i = cmd.side_mm.abs() / cfg.stride_ref_mm.abs().max(1.0);
    let turn_i = cmd.turn_deg.abs() / cfg.turn_ref_deg.abs().max(1.0);
    let intensity = stride_i.max(side_i).max(turn_i).clamp(0.0, 1.0);
    let shaped = intensity.powf(0.7);
    let min_period = cfg.min_period_ms.min(cfg.max_period_ms);
    let max_period = cfg.min_period_ms.max(cfg.max_period_ms);
    let period = max_period - (max_period - min_period) * shaped;
    let min_foot = cfg.min_foot_mm.min(cfg.foot_mm);
    let max_foot = cfg.min_foot_mm.max(cfg.foot_mm);
    let foot = min_foot + (max_foot - min_foot) * shaped;
    (period, foot)
}

/// 14-token 명령 라인 직렬화 — `_build_line` 등가 (cmd_id 는 호출자 주입:
/// Python 은 uuid4 를 내부 생성하지만 그러면 골든 벡터가 불가능하다).
pub fn build_line(cmd_id: &str, cfg: &GaitConfig, cmd: &MotionCommand) -> String {
    let enabled = u8::from(cmd.enabled);
    let (period_ms, foot_mm) = gait_params(cfg, cmd);
    format!(
        "{} {} {:.2} {:.2} {:.2} {:.0} {:.0} {:.0} 1.0 0 2 {:.2} {:.2} 0",
        cmd_id,
        enabled,
        cmd.stride_mm,
        cmd.side_mm,
        cmd.turn_deg,
        period_ms,
        foot_mm,
        cfg.hip_deg,
        cmd.head_pan_deg,
        cmd.head_tilt_deg,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_command_keeps_default_gait() {
        let cfg = GaitConfig::default();
        let (period, foot) = gait_params(&cfg, &MotionCommand::zero());
        assert_eq!((period, foot), (cfg.period_ms, cfg.foot_mm));
    }

    #[test]
    fn full_stick_reaches_max_gait() {
        let cfg = GaitConfig::default();
        let cmd = MotionCommand {
            enabled: true,
            stride_mm: 25.0,
            side_mm: 0.0,
            turn_deg: 0.0,
            head_pan_deg: 0.0,
            head_tilt_deg: 0.0,
        };
        let (period, foot) = gait_params(&cfg, &cmd);
        assert!((period - 520.0).abs() < 1e-9);
        assert!((foot - 40.0).abs() < 1e-9);
    }

    #[test]
    fn zero_line_layout() {
        let line = build_line("id0", &GaitConfig::default(), &MotionCommand::zero());
        assert_eq!(line, "id0 0 0.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0");
    }
}
