//! gilrs 어댑터 — XInput/장치 폴링 → [`InputFrame`] (feature `device`).
//!
//! 안전 로직 **비관여**: gilrs 이벤트를 InputFrame 으로 옮기고, B(East) rising 을 즉시
//! 표시(`estop_edge`)만 한다 — 실제 정지 발화·게이트 전이는 호출자([`crate::Pilot`] +
//! 송신 계층)가 한다(INV-2). evdev(온보드)와 달리 Ally 는 gilrs/XInput 이라 **축 부호·트리거
//! 라우팅(버튼-아날로그 vs Z축)이 기기 편차**가 있다 — 아래 부호 상수와 트리거 경로는
//! **하드웨어 게이트에서 axis-dump 로 확정**한다(roadmap 04 §2 W1 리스크).

use crate::frame::{self, InputFrame};
use gilrs::{Axis, Button, Event, EventType, Gilrs};

// gilrs→frame 부호 정렬(기본 가정 — axis-dump 확인 대상). frame 규약 = evdev raw 와 동일
// (스틱 아래=+ly, 우=+lx; RY 아래=+ry) 이어야 g01 의 동결 SIGN_* 가 1:1 로 맞는다. gilrs 는
// 보통 스틱 위=+ 이므로 Y 축을 반전한다. X 는 우=+ 동일 가정 — 실기에서 반대면 여기만 바꾼다.
const LX_SIGN: f64 = 1.0;
const LY_SIGN: f64 = -1.0;
const RX_SIGN: f64 = 1.0;
const RY_SIGN: f64 = -1.0;

/// 한 번 pump 의 결과 — 최신 프레임 + 이번에 잡힌 연결/단절/E-STOP edge.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PumpResult {
    pub frame: InputFrame,
    /// B(East) rising — 호출자가 **즉시** E-STOP 신호를 발화(스로틀 금지, INV-1).
    pub estop_edge: bool,
    pub connected: bool,
    pub disconnected: bool,
}

/// gilrs 장치 폴링 소스 — 단일 패드 가정(첫 연결 패드). 내부에 누적 프레임을 유지한다.
pub struct GamepadSource {
    gilrs: Gilrs,
    frame: InputFrame,
}

impl GamepadSource {
    /// gilrs 초기화. 실패(플랫폼 미지원 등) 시 에러(박싱 — `gilrs::Error` 가 큼).
    pub fn new() -> Result<Self, Box<gilrs::Error>> {
        Ok(GamepadSource {
            gilrs: Gilrs::new().map_err(Box::new)?,
            frame: InputFrame::default(),
        })
    }

    /// 대기 중인 gilrs 이벤트를 모두 드레인해 누적 프레임을 갱신하고 결과를 반환한다.
    /// **입력 레이트(≈250Hz)로 호출** — B rising 즉시성(INV-1)을 위해 TX 20Hz 와 분리.
    pub fn pump(&mut self, now_ms: i64) -> PumpResult {
        let mut estop_edge = false;
        let mut connected = false;
        let mut disconnected = false;
        while let Some(Event { event, .. }) = self.gilrs.next_event() {
            match event {
                EventType::ButtonPressed(b, _) => {
                    if matches!(b, Button::East) {
                        estop_edge = true; // B — 즉시 발화 대상
                    }
                    self.set_button(b, true);
                }
                EventType::ButtonReleased(b, _) => self.set_button(b, false),
                EventType::ButtonChanged(b, v, _) => match b {
                    // 트리거가 버튼-아날로그로 오는 기기.
                    Button::LeftTrigger2 => self.frame.lt = frame::clamp_trigger(v as f64),
                    Button::RightTrigger2 => self.frame.rt = frame::clamp_trigger(v as f64),
                    _ => {}
                },
                EventType::AxisChanged(ax, v, _) => self.set_axis(ax, v as f64),
                EventType::Connected => connected = true,
                EventType::Disconnected => disconnected = true,
                _ => {}
            }
        }
        self.frame.ts_ms = now_ms;
        PumpResult {
            frame: self.frame,
            estop_edge,
            connected,
            disconnected,
        }
    }

    fn set_button(&mut self, b: Button, down: bool) {
        match b {
            Button::South => self.frame.btn_a = down,
            Button::East => self.frame.btn_b = down,
            Button::West => self.frame.btn_x = down,
            Button::North => self.frame.btn_y = down,
            Button::LeftTrigger => self.frame.btn_lb = down,
            Button::RightTrigger => self.frame.btn_rb = down,
            _ => {}
        }
    }

    fn set_axis(&mut self, ax: Axis, v: f64) {
        match ax {
            Axis::LeftStickX => self.frame.lx = frame::clamp_stick(LX_SIGN * v),
            Axis::LeftStickY => self.frame.ly = frame::clamp_stick(LY_SIGN * v),
            Axis::RightStickX => self.frame.rx = frame::clamp_stick(RX_SIGN * v),
            Axis::RightStickY => self.frame.ry = frame::clamp_stick(RY_SIGN * v),
            // 트리거가 Z축으로 오는 기기(버튼-아날로그 경로의 대안). `clamp_trigger` 는 음수를
            // 0 으로 묶어 rest=−1 기기에서 **오발만 막는다**(안전). 단 그 기기는 0..0.5 입력이
            // 전부 데드(하위 절반 손실)이므로, axis-dump 로 [−1,1] 범위 확인되면 `(v+1)/2` 재맵이
            // 필요하다 — 정확 보정은 하드웨어 게이트 항목.
            Axis::LeftZ => self.frame.lt = frame::clamp_trigger(v),
            Axis::RightZ => self.frame.rt = frame::clamp_trigger(v),
            _ => {}
        }
    }
}
