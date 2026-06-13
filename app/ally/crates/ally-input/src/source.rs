//! gilrs 입력 소스 — 250Hz 폴링 스레드 + 무손실 B E-STOP 채널.
//!
//! 03 §2 입력 스레드: gilrs 이벤트를 펌프해 **B(East) rising 을 무손실 estop
//! 채널로 즉시** 보내고(매핑·게이트 비경유 — INV-1), A/Y rising 은 게이트 edge
//! 채널로, 연속 축 상태는 최신승 `InputFrame` 으로 발행한다. 패드 단절(gilrs
//! Disconnected)은 frame.connected=false 로 표출돼 TX 루프가 zero+disarm 한다.
//!
//! `Gilrs` 는 플랫폼 핸들을 들고 Send 가 아닐 수 있어 **스레드 내부에서 생성**한다
//! (소유권이 스레드 경계를 넘지 않음). 초기화 성공/실패만 동기 채널로 회신한다.

use std::sync::mpsc::{Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use gilrs::{Axis, Button, EventType, Gilrs};

use crate::adapter::GilrsAxes;
use crate::gate::ButtonEdges;
use crate::{now_ms, POLL_PERIOD};

/// E-STOP 발원 — W1 은 패드 B 만. (W2: 터치·수퍼바이저·절전 합류.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstopReason {
    PadButtonB,
}

/// E-STOP 신호 — 발원 + 입력 스레드가 이벤트를 본 monotonic ms.
/// `t_ms`(공유 [`now_ms`])로 "입력 이벤트 → 소켓 write 내부 지연"을 측정한다(04 §2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EstopSignal {
    pub reason: EstopReason,
    pub t_ms: i64,
}

/// 한 폴 시점의 입력 — gilrs 방향 raw 축 + 연결 상태 + monotonic 수신 ms.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InputFrame {
    pub axes: GilrsAxes,
    pub connected: bool,
    pub t_ms: i64,
}

impl InputFrame {
    fn disconnected(t_ms: i64) -> Self {
        InputFrame {
            axes: GilrsAxes::default(),
            connected: false,
            t_ms,
        }
    }

    /// 이 프레임이 `now_ms` 기준 stale 인지(신선도 임계 ms 초과).
    pub fn is_stale(&self, now_ms: i64, threshold_ms: i64) -> bool {
        now_ms - self.t_ms > threshold_ms
    }
}

/// gilrs 폴링 서비스 — 스레드를 소유하고 채널·최신 프레임을 노출한다.
pub struct InputService {
    frame: Arc<Mutex<InputFrame>>,
    running: Arc<std::sync::atomic::AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl InputService {
    /// 폴링 스레드 기동. 반환: (서비스, estop 수신, edge 수신).
    /// gilrs 초기화 실패 시 Err(메시지) — 패드 미연결은 실패가 아니다(연결 대기).
    pub fn spawn() -> Result<(Self, Receiver<EstopSignal>, Receiver<ButtonEdges>), String> {
        let (estop_tx, estop_rx) = std::sync::mpsc::channel::<EstopSignal>();
        let (edge_tx, edge_rx) = std::sync::mpsc::channel::<ButtonEdges>();
        let (init_tx, init_rx) = std::sync::mpsc::sync_channel::<Result<(), String>>(1);

        let frame = Arc::new(Mutex::new(InputFrame::disconnected(now_ms())));
        let running = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let frame_thread = Arc::clone(&frame);
        let running_thread = Arc::clone(&running);

        let handle = std::thread::Builder::new()
            .name("ally-input-poll".into())
            .spawn(move || {
                reader_loop(frame_thread, running_thread, estop_tx, edge_tx, init_tx);
            })
            .map_err(|e| format!("입력 스레드 생성 실패: {e}"))?;

        match init_rx.recv() {
            Ok(Ok(())) => Ok((
                InputService {
                    frame,
                    running,
                    handle: Some(handle),
                },
                estop_rx,
                edge_rx,
            )),
            Ok(Err(e)) => Err(e),
            Err(_) => Err("입력 스레드 초기화 응답 없음".into()),
        }
    }

    /// 최신 입력 프레임(최신승 스냅샷).
    pub fn latest(&self) -> InputFrame {
        *self.frame.lock().expect("input frame mutex poisoned")
    }

    /// 스레드 정지 + 합류.
    pub fn stop(mut self) {
        self.running
            .store(false, std::sync::atomic::Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for InputService {
    fn drop(&mut self) {
        self.running
            .store(false, std::sync::atomic::Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

fn reader_loop(
    frame: Arc<Mutex<InputFrame>>,
    running: Arc<std::sync::atomic::AtomicBool>,
    estop_tx: Sender<EstopSignal>,
    edge_tx: Sender<ButtonEdges>,
    init_tx: SyncSender<Result<(), String>>,
) {
    let mut gilrs = match Gilrs::new() {
        Ok(g) => {
            let _ = init_tx.send(Ok(()));
            g
        }
        Err(e) => {
            let _ = init_tx.send(Err(format!("gilrs 초기화 실패: {e}")));
            return;
        }
    };

    // 이미 연결된 첫 패드를 채택(Ally 내장 패드는 기동 시 이미 존재).
    let mut active: Option<gilrs::GamepadId> = gilrs.gamepads().map(|(id, _)| id).next();

    while running.load(std::sync::atomic::Ordering::Relaxed) {
        // 1) 이벤트 펌프 — 버튼 edge 는 무손실(폴 사이 눌림+뗌도 포착).
        while let Some(ev) = gilrs.next_event() {
            match ev.event {
                EventType::Connected => {
                    if active.is_none() {
                        active = Some(ev.id);
                    }
                }
                EventType::Disconnected => {
                    if active == Some(ev.id) {
                        active = None;
                    }
                }
                EventType::ButtonPressed(btn, _) => {
                    // 활성 패드만 — 다른 패드의 입력은 무시(콕핏 단일 조종자).
                    if active.is_none() {
                        active = Some(ev.id);
                    }
                    if active != Some(ev.id) {
                        continue;
                    }
                    match btn {
                        // B(East) — E-STOP 즉시 무손실 발화(INV-1: 스로틀·디바운스 금지).
                        Button::East => {
                            let _ = estop_tx.send(EstopSignal {
                                reason: EstopReason::PadButtonB,
                                t_ms: now_ms(),
                            });
                            let _ = edge_tx.send(ButtonEdges {
                                estop: true,
                                ..Default::default()
                            });
                        }
                        Button::South => {
                            let _ = edge_tx.send(ButtonEdges {
                                arm: true,
                                ..Default::default()
                            });
                        }
                        Button::North => {
                            let _ = edge_tx.send(ButtonEdges {
                                recover: true,
                                ..Default::default()
                            });
                        }
                        _ => {} // West(볼트랙)·범퍼 등 — W1 미배선
                    }
                }
                _ => {}
            }
        }

        // 2) 연속 상태 → 최신승 프레임. 단절 시 중립(zero) 발행.
        let now = now_ms();
        let next = match active.filter(|id| gilrs.gamepad(*id).is_connected()) {
            Some(id) => {
                let gp = gilrs.gamepad(id);
                InputFrame {
                    axes: read_axes(&gp),
                    connected: true,
                    t_ms: now,
                }
            }
            None => InputFrame::disconnected(now),
        };
        *frame.lock().expect("input frame mutex poisoned") = next;

        std::thread::sleep(POLL_PERIOD);
    }
}

/// gilrs 패드 → 정규화 축(gilrs 방향: 스틱 위=+·오른쪽=+, 트리거 [0,1]).
fn read_axes(gp: &gilrs::Gamepad) -> GilrsAxes {
    GilrsAxes {
        left_x: gp.value(Axis::LeftStickX) as f64,
        left_y: gp.value(Axis::LeftStickY) as f64,
        right_x: gp.value(Axis::RightStickX) as f64,
        right_y: gp.value(Axis::RightStickY) as f64,
        lt: trigger_value(gp, Axis::LeftZ, Button::LeftTrigger2),
        rt: trigger_value(gp, Axis::RightZ, Button::RightTrigger2),
        btn_a: gp.is_pressed(Button::South),
        btn_b: gp.is_pressed(Button::East),
        btn_x: gp.is_pressed(Button::West),
        btn_y: gp.is_pressed(Button::North),
        btn_lb: gp.is_pressed(Button::LeftTrigger),
        btn_rb: gp.is_pressed(Button::RightTrigger),
    }
}

/// 트리거 정규화 [0,1] — 축(LeftZ/RightZ)과 버튼 아날로그 중 큰 값을 취해
/// 기기별 노출 방식(축 vs 버튼, 0..1 vs −1..1) 편차를 흡수한다. 정확한 분포는
/// 축 덤프 모드로 현장 확인(04 §2 리스크).
fn trigger_value(gp: &gilrs::Gamepad, axis: Axis, btn: Button) -> f64 {
    let from_axis = gp.value(axis) as f64;
    let from_btn = gp.button_data(btn).map(|d| d.value() as f64).unwrap_or(0.0);
    from_axis.max(from_btn).clamp(0.0, 1.0)
}

/// 축 덤프 모드 — gilrs 이벤트와 파생 정규화값을 `duration` 동안 stdout 으로 출력.
/// XInput 트리거가 축/버튼 어느 쪽으로 오는지 게이트 현장에서 즉시 확인하는 도구.
pub fn dump_events(duration: Duration) -> Result<(), String> {
    let mut gilrs = Gilrs::new().map_err(|e| format!("gilrs 초기화 실패: {e}"))?;
    println!(
        "=== 축 덤프 ({}s) — 스틱/트리거/버튼을 움직여 매핑 확인 ===",
        duration.as_secs()
    );
    for (id, gp) in gilrs.gamepads() {
        println!(
            "  패드: id={id:?} name={:?} connected={}",
            gp.name(),
            gp.is_connected()
        );
    }
    let start = std::time::Instant::now();
    let mut last_print = now_ms();
    while start.elapsed() < duration {
        while let Some(ev) = gilrs.next_event() {
            println!("  event id={:?} {:?}", ev.id, ev.event);
        }
        // 250ms 마다 활성 패드의 정규화 스냅샷도 함께 출력.
        let now = now_ms();
        if now - last_print >= 250 {
            last_print = now;
            if let Some((id, gp)) = gilrs.gamepads().next() {
                let a = read_axes(&gp);
                println!(
                    "  state id={id:?} LS=({:+.2},{:+.2}) RS=({:+.2},{:+.2}) LT={:.2} RT={:.2} \
                     A={} B={} X={} Y={} LB={} RB={}",
                    a.left_x,
                    a.left_y,
                    a.right_x,
                    a.right_y,
                    a.lt,
                    a.rt,
                    a.btn_a as u8,
                    a.btn_b as u8,
                    a.btn_x as u8,
                    a.btn_y as u8,
                    a.btn_lb as u8,
                    a.btn_rb as u8,
                );
            }
        }
        std::thread::sleep(POLL_PERIOD);
    }
    Ok(())
}
