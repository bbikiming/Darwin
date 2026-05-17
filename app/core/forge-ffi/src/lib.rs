//! `forge-ffi` — C-ABI bindings for forge-core.
//!
//! Swift는 이 모듈이 만든 `libforge_core.a` + `forge_core.h`를 임포트.
//! 모든 export 함수는 `extern "C"` + `#[no_mangle]` + `catch_unwind`.
//!
//! 규약:
//! - 문자열 인자: NUL-terminated `*const c_char` (UTF-8).
//! - 문자열 반환: 우리가 alloc한 `*mut c_char` — 호출자가 `fc_string_free`로 해제.
//! - 에러: i32 반환. 0=OK, 음수=에러 (자세한 매핑은 `fc_error_*` 상수).
//! - 핸들: opaque `*mut FcXxx` 포인터. close 함수로 해제.

#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::time::Duration;

use forge_core::control::JointController;
use forge_core::controller::{cm::BoardSnapshot, CmController};
use forge_core::dynamixel::Bus;
use forge_core::joint::{JointId, JointState};
use forge_core::motion::{parse_mtn, write_mtn, CancelHandle, Motion};
use forge_core::serial::{LoopbackBus, PosixSerial, TcpBus};
use forge_core::strategy::{StrategyInput, StrategyState};
use forge_core::vision::{detect_blob, BlobResult, Frame, HsvRange, Pixel};
use forge_core::walk::{WalkCommand, WalkEngine};

// ============================================================================
// 에러 코드
// ============================================================================

/// 성공.
pub const FC_OK: c_int = 0;
/// 일반 에러.
pub const FC_ERR_GENERIC: c_int = -1;
/// 파라미터가 잘못됨.
pub const FC_ERR_INVALID: c_int = -2;
/// 직렬 포트 I/O 에러.
pub const FC_ERR_IO: c_int = -3;
/// 응답 timeout.
pub const FC_ERR_TIMEOUT: c_int = -4;
/// 코덱 에러.
pub const FC_ERR_CODEC: c_int = -5;
/// 디바이스 응답 없음.
pub const FC_ERR_DEVICE_NOT_FOUND: c_int = -6;
/// panic 보호 — Rust 코드가 panic.
pub const FC_ERR_PANIC: c_int = -99;

// ============================================================================
// 문자열 유틸
// ============================================================================

/// Rust → C 문자열 변환. nullptr은 빈 문자열 반환.
fn rust_to_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .map(|c| c.into_raw())
        .unwrap_or(ptr::null_mut())
}

/// `fc_*` 함수가 반환한 문자열 해제.
#[no_mangle]
pub unsafe extern "C" fn fc_string_free(s: *mut c_char) {
    if !s.is_null() {
        let _ = CString::from_raw(s);
    }
}

unsafe fn cstr_to_str<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        return None;
    }
    CStr::from_ptr(s).to_str().ok()
}

fn err_code(e: &forge_core::Error) -> c_int {
    use forge_core::Error::*;
    match e {
        Io(_) => FC_ERR_IO,
        Codec(_) => FC_ERR_CODEC,
        Timeout(_) => FC_ERR_TIMEOUT,
        DeviceNotFound(_) => FC_ERR_DEVICE_NOT_FOUND,
        Other(_) => FC_ERR_GENERIC,
    }
}

fn safe_call<F: FnOnce() -> c_int>(f: F) -> c_int {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(code) => code,
        Err(_) => FC_ERR_PANIC,
    }
}

// ============================================================================
// Version / 메타
// ============================================================================

/// forge-core 버전 (Cargo.toml). 호출자가 fc_string_free.
#[no_mangle]
pub extern "C" fn fc_version() -> *mut c_char {
    rust_to_c_string(env!("CARGO_PKG_VERSION").to_string())
}

// ============================================================================
// 직렬 포트 열거
// ============================================================================

/// 사용 가능한 USB 직렬 포트 경로를 줄바꿈 구분 문자열로 반환. (호출자가 free)
///
/// 실패 시 nullptr 반환 (out_err에 에러코드 set).
#[no_mangle]
pub unsafe extern "C" fn fc_serial_list_ports(out_err: *mut c_int) -> *mut c_char {
    let result: Result<String, c_int> = catch_unwind(|| match PosixSerial::list_ports() {
        Ok(v) => Ok(v.join("\n")),
        Err(e) => Err(err_code(&e)),
    })
    .unwrap_or(Err(FC_ERR_PANIC));
    match result {
        Ok(s) => {
            if !out_err.is_null() {
                *out_err = FC_OK;
            }
            rust_to_c_string(s)
        }
        Err(code) => {
            if !out_err.is_null() {
                *out_err = code;
            }
            ptr::null_mut()
        }
    }
}

// ============================================================================
// Bus 핸들 — open/close/ping/scan/board snapshot/joint ops
// ============================================================================

/// Bus 핸들. PosixSerial / LoopbackBus / TcpBus를 감쌈.
pub struct FcBus {
    backend: BusBackend,
    /// 진행 중인 motion play 취소 핸들. play 중이 아니면 None.
    motion_cancel: Option<CancelHandle>,
    /// play 가 진행 중이면 true.
    motion_playing: std::sync::atomic::AtomicBool,
}

#[allow(dead_code)] // Loopback은 in-process 테스트 후크용.
enum BusBackend {
    Posix(Bus<PosixSerial>),
    Loopback(Bus<LoopbackBus>),
    Tcp(Bus<TcpBus>),
}

/// 직렬 포트 open 후 Bus 생성. 실패 시 nullptr.
#[no_mangle]
pub unsafe extern "C" fn fc_bus_open(
    port_path: *const c_char,
    baud: u32,
    timeout_ms: u32,
    out_err: *mut c_int,
) -> *mut FcBus {
    let path = match cstr_to_str(port_path) {
        Some(s) => s,
        None => {
            if !out_err.is_null() {
                *out_err = FC_ERR_INVALID;
            }
            return ptr::null_mut();
        }
    };
    match catch_unwind(|| PosixSerial::open(path, baud)) {
        Ok(Ok(p)) => {
            let bus = Bus::new(p).with_timeout(Duration::from_millis(timeout_ms as u64));
            if !out_err.is_null() {
                *out_err = FC_OK;
            }
            Box::into_raw(Box::new(FcBus {
                backend: BusBackend::Posix(bus),
                motion_cancel: None,
                motion_playing: std::sync::atomic::AtomicBool::new(false),
            }))
        }
        Ok(Err(e)) => {
            if !out_err.is_null() {
                *out_err = err_code(&e);
            }
            ptr::null_mut()
        }
        Err(_) => {
            if !out_err.is_null() {
                *out_err = FC_ERR_PANIC;
            }
            ptr::null_mut()
        }
    }
}

/// 네트워크 endpoint(`host:port`) 로 TCP 연결 후 Bus 생성. 실패 시 nullptr.
/// `connect_timeout_ms` 는 연결 자체의 timeout, `io_timeout_ms`는 read/write 작업.
#[no_mangle]
pub unsafe extern "C" fn fc_bus_open_tcp(
    address: *const c_char,
    connect_timeout_ms: u32,
    io_timeout_ms: u32,
    out_err: *mut c_int,
) -> *mut FcBus {
    let addr = match cstr_to_str(address) {
        Some(s) => s,
        None => {
            if !out_err.is_null() {
                *out_err = FC_ERR_INVALID;
            }
            return ptr::null_mut();
        }
    };
    match catch_unwind(|| TcpBus::connect(addr, Duration::from_millis(connect_timeout_ms as u64))) {
        Ok(Ok(p)) => {
            let bus = Bus::new(p).with_timeout(Duration::from_millis(io_timeout_ms as u64));
            if !out_err.is_null() {
                *out_err = FC_OK;
            }
            Box::into_raw(Box::new(FcBus {
                backend: BusBackend::Tcp(bus),
                motion_cancel: None,
                motion_playing: std::sync::atomic::AtomicBool::new(false),
            }))
        }
        Ok(Err(e)) => {
            if !out_err.is_null() {
                *out_err = err_code(&e);
            }
            ptr::null_mut()
        }
        Err(_) => {
            if !out_err.is_null() {
                *out_err = FC_ERR_PANIC;
            }
            ptr::null_mut()
        }
    }
}

/// Bus 핸들 해제.
#[no_mangle]
pub unsafe extern "C" fn fc_bus_close(handle: *mut FcBus) {
    if !handle.is_null() {
        let _ = Box::from_raw(handle);
    }
}

fn bus_apply<R>(b: &mut FcBus, mut f: impl FnMut(&mut dyn BusOps) -> R) -> R {
    match &mut b.backend {
        BusBackend::Posix(bus) => f(bus),
        BusBackend::Loopback(bus) => f(bus),
        BusBackend::Tcp(bus) => f(bus),
    }
}

/// Bus를 trait 통해 다루도록 — codegen 절약용 어댑터.
#[allow(dead_code)] // read_id/write_id는 후속 FFI 함수가 추가될 때 사용.
trait BusOps {
    fn ping_id(&mut self, id: u8) -> Result<(), forge_core::Error>;
    fn read_id(&mut self, id: u8, addr: u8, len: u8) -> Result<Vec<u8>, forge_core::Error>;
    fn write_id(&mut self, id: u8, addr: u8, bytes: &[u8]) -> Result<(), forge_core::Error>;
    fn scan_range(&mut self, lo: u8, hi: u8) -> Vec<u8>;
}

impl<P: forge_core::serial::SerialPort> BusOps for Bus<P> {
    fn ping_id(&mut self, id: u8) -> Result<(), forge_core::Error> {
        self.ping(id).map(|_| ())
    }
    fn read_id(&mut self, id: u8, addr: u8, len: u8) -> Result<Vec<u8>, forge_core::Error> {
        self.read(id, addr, len)
    }
    fn write_id(&mut self, id: u8, addr: u8, bytes: &[u8]) -> Result<(), forge_core::Error> {
        self.write(id, addr, bytes)
    }
    fn scan_range(&mut self, lo: u8, hi: u8) -> Vec<u8> {
        self.scan(lo..=hi)
    }
}

/// 한 ID에 PING. OK/에러코드.
#[no_mangle]
pub unsafe extern "C" fn fc_bus_ping(handle: *mut FcBus, id: u8) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        let bus = &mut *handle;
        match bus_apply(bus, |b| b.ping_id(id)) {
            Ok(()) => FC_OK,
            Err(e) => err_code(&e),
        }
    })
}

/// 범위 lo..=hi 스캔. 응답한 ID를 줄바꿈 구분 문자열로 반환 (호출자가 free).
#[no_mangle]
pub unsafe extern "C" fn fc_bus_scan(
    handle: *mut FcBus,
    lo: u8,
    hi: u8,
    out_err: *mut c_int,
) -> *mut c_char {
    if handle.is_null() {
        if !out_err.is_null() {
            *out_err = FC_ERR_INVALID;
        }
        return ptr::null_mut();
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let bus = &mut *handle;
        bus_apply(bus, |b| b.scan_range(lo, hi))
    }));
    match result {
        Ok(found) => {
            if !out_err.is_null() {
                *out_err = FC_OK;
            }
            let s = found
                .iter()
                .map(u8::to_string)
                .collect::<Vec<_>>()
                .join("\n");
            rust_to_c_string(s)
        }
        Err(_) => {
            if !out_err.is_null() {
                *out_err = FC_ERR_PANIC;
            }
            ptr::null_mut()
        }
    }
}

// ============================================================================
// CM 보드 상태
// ============================================================================

/// CM-730/740 보드 스냅샷 (FFI struct).
#[repr(C)]
pub struct FfiBoardSnapshot {
    /// 모델 번호 (730 또는 740 추정).
    pub model_number: u16,
    /// 펌웨어 version.
    pub version: u8,
    /// 배터리 raw (0.1 V 단위).
    pub voltage_raw: u8,
    /// 버튼 비트.
    pub button: u8,
}

impl From<BoardSnapshot> for FfiBoardSnapshot {
    fn from(s: BoardSnapshot) -> Self {
        Self {
            model_number: s.model_number,
            version: s.version,
            voltage_raw: s.voltage_raw,
            button: s.button,
        }
    }
}

/// CM 보드 스냅샷 read.
#[no_mangle]
pub unsafe extern "C" fn fc_bus_board_snapshot(
    handle: *mut FcBus,
    out: *mut FfiBoardSnapshot,
) -> c_int {
    if handle.is_null() || out.is_null() {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        let bus = &mut *handle;
        fn run<P: forge_core::serial::SerialPort>(
            b: &mut Bus<P>,
            out: *mut FfiBoardSnapshot,
        ) -> c_int {
            let mut cm = CmController::new(b);
            match cm.snapshot() {
                Ok(s) => {
                    unsafe {
                        *out = s.into();
                    }
                    FC_OK
                }
                Err(e) => err_code(&e),
            }
        }
        match &mut bus.backend {
            BusBackend::Posix(b) => run(b, out),
            BusBackend::Loopback(b) => run(b, out),
            BusBackend::Tcp(b) => run(b, out),
        }
    })
}

/// CM Dynamixel 전원 게이트.
#[no_mangle]
pub unsafe extern "C" fn fc_bus_set_dxl_power(handle: *mut FcBus, on: c_int) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        let bus = &mut *handle;
        fn run<P: forge_core::serial::SerialPort>(b: &mut Bus<P>, on: bool) -> c_int {
            let mut cm = CmController::new(b);
            cm.set_dxl_power(on)
                .map(|_| FC_OK)
                .unwrap_or_else(|e| err_code(&e))
        }
        let on_b = on != 0;
        match &mut bus.backend {
            BusBackend::Posix(b) => run(b, on_b),
            BusBackend::Loopback(b) => run(b, on_b),
            BusBackend::Tcp(b) => run(b, on_b),
        }
    })
}

// ============================================================================
// Joint 제어
// ============================================================================

/// 한 관절의 실시간 상태 (FFI struct).
#[repr(C)]
pub struct FfiJointState {
    /// 관절 raw ID (1..6, 11..20).
    pub id: u8,
    /// 0/1.
    pub torque_enabled: u8,
    /// goal position (0..4095).
    pub goal_position: u16,
    /// 현재 position.
    pub present_position: u16,
    /// 현재 speed raw.
    pub present_speed: u16,
    /// 현재 load raw.
    pub present_load: u16,
    /// 전압 raw (0.1 V).
    pub present_voltage: u8,
    /// 온도 °C.
    pub present_temperature: u8,
}

impl From<JointState> for FfiJointState {
    fn from(s: JointState) -> Self {
        Self {
            id: s.id as u8,
            torque_enabled: s.torque_enabled as u8,
            goal_position: s.goal_position,
            present_position: s.present_position,
            present_speed: s.present_speed,
            present_load: s.present_load,
            present_voltage: s.present_voltage,
            present_temperature: s.present_temperature,
        }
    }
}

/// 한 관절 토크 enable/disable.
#[no_mangle]
pub unsafe extern "C" fn fc_joint_set_torque(
    handle: *mut FcBus,
    raw_id: u8,
    enable: c_int,
) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    let joint = match JointId::from_byte(raw_id) {
        Some(j) => j,
        None => return FC_ERR_INVALID,
    };
    safe_call(|| {
        let bus = &mut *handle;
        fn run<P: forge_core::serial::SerialPort>(
            b: &mut Bus<P>,
            joint: JointId,
            enable: bool,
        ) -> c_int {
            let mut jc = JointController::new(b);
            jc.set_torque(joint, enable)
                .map(|_| FC_OK)
                .unwrap_or_else(|e| err_code(&e))
        }
        let en = enable != 0;
        match &mut bus.backend {
            BusBackend::Posix(b) => run(b, joint, en),
            BusBackend::Loopback(b) => run(b, joint, en),
            BusBackend::Tcp(b) => run(b, joint, en),
        }
    })
}

/// 한 관절 goal position 설정. 안전 한계로 clamp.
#[no_mangle]
pub unsafe extern "C" fn fc_joint_set_position(
    handle: *mut FcBus,
    raw_id: u8,
    position: u16,
    out_clamped: *mut u16,
) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    let joint = match JointId::from_byte(raw_id) {
        Some(j) => j,
        None => return FC_ERR_INVALID,
    };
    safe_call(|| {
        let bus = &mut *handle;
        fn run<P: forge_core::serial::SerialPort>(
            b: &mut Bus<P>,
            joint: JointId,
            position: u16,
        ) -> Result<u16, forge_core::Error> {
            let mut jc = JointController::new(b);
            jc.set_position(joint, position)
        }
        let result: Result<u16, forge_core::Error> = match &mut bus.backend {
            BusBackend::Posix(b) => run(b, joint, position),
            BusBackend::Loopback(b) => run(b, joint, position),
            BusBackend::Tcp(b) => run(b, joint, position),
        };
        match result {
            Ok(c) => {
                if !out_clamped.is_null() {
                    *out_clamped = c;
                }
                FC_OK
            }
            Err(e) => err_code(&e),
        }
    })
}

/// 한 관절 moving_speed 설정 — Dynamixel MX-28T address 32-33 (2 byte).
/// speed: 0 = 무제한 (default), 1-1023 = 단계별 (0.114 rpm per unit).
/// 자세 변경 시 모터의 보간 속도 제한 → 부드러운 이동.
#[no_mangle]
pub unsafe extern "C" fn fc_joint_set_moving_speed(
    handle: *mut FcBus,
    raw_id: u8,
    speed: u16,
) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    let joint = match JointId::from_byte(raw_id) {
        Some(j) => j,
        None => return FC_ERR_INVALID,
    };
    safe_call(|| {
        let bus = &mut *handle;
        fn run<P: forge_core::serial::SerialPort>(
            b: &mut Bus<P>,
            joint: JointId,
            speed: u16,
        ) -> Result<(), forge_core::Error> {
            let low = (speed & 0xFF) as u8;
            let high = ((speed >> 8) & 0xFF) as u8;
            // MX-28T moving_speed register address = 32.
            b.write(joint as u8, 32, &[low, high])
        }
        let result: Result<(), forge_core::Error> = match &mut bus.backend {
            BusBackend::Posix(b) => run(b, joint, speed),
            BusBackend::Loopback(b) => run(b, joint, speed),
            BusBackend::Tcp(b) => run(b, joint, speed),
        };
        match result {
            Ok(()) => FC_OK,
            Err(e) => err_code(&e),
        }
    })
}

/// 한 관절 상태 read.
#[no_mangle]
pub unsafe extern "C" fn fc_joint_read_state(
    handle: *mut FcBus,
    raw_id: u8,
    out: *mut FfiJointState,
) -> c_int {
    if handle.is_null() || out.is_null() {
        return FC_ERR_INVALID;
    }
    let joint = match JointId::from_byte(raw_id) {
        Some(j) => j,
        None => return FC_ERR_INVALID,
    };
    safe_call(|| {
        let bus = &mut *handle;
        fn run<P: forge_core::serial::SerialPort>(
            b: &mut Bus<P>,
            joint: JointId,
        ) -> Result<JointState, forge_core::Error> {
            let mut jc = JointController::new(b);
            jc.read_state(joint)
        }
        let result = match &mut bus.backend {
            BusBackend::Posix(b) => run(b, joint),
            BusBackend::Loopback(b) => run(b, joint),
            BusBackend::Tcp(b) => run(b, joint),
        };
        match result {
            Ok(s) => {
                *out = s.into();
                FC_OK
            }
            Err(e) => err_code(&e),
        }
    })
}

/// 모든 관절 토크 OFF (소프트 e-stop).
#[no_mangle]
pub unsafe extern "C" fn fc_emergency_stop(handle: *mut FcBus) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        let bus = &mut *handle;
        fn run<P: forge_core::serial::SerialPort>(b: &mut Bus<P>) -> c_int {
            let mut jc = JointController::new(b);
            jc.emergency_stop()
                .map(|_| FC_OK)
                .unwrap_or_else(|e| err_code(&e))
        }
        match &mut bus.backend {
            BusBackend::Posix(b) => run(b),
            BusBackend::Loopback(b) => run(b),
            BusBackend::Tcp(b) => run(b),
        }
    })
}

// ============================================================================
// Motion import/export
// ============================================================================

/// `.mtn` 텍스트 → JSON 문자열. 호출자가 fc_string_free.
#[no_mangle]
pub unsafe extern "C" fn fc_motion_mtn_to_json(
    mtn_text: *const c_char,
    generation: *const c_char,
    out_err: *mut c_int,
) -> *mut c_char {
    let text = match cstr_to_str(mtn_text) {
        Some(s) => s,
        None => {
            if !out_err.is_null() {
                *out_err = FC_ERR_INVALID;
            }
            return ptr::null_mut();
        }
    };
    let gen = cstr_to_str(generation).unwrap_or("op2").to_string();
    match catch_unwind(|| {
        parse_mtn(text).map(|mut m| {
            m.robot_generation = gen;
            m
        })
    }) {
        Ok(Ok(motion)) => match motion.to_json_pretty() {
            Ok(j) => {
                if !out_err.is_null() {
                    *out_err = FC_OK;
                }
                rust_to_c_string(j)
            }
            Err(_) => {
                if !out_err.is_null() {
                    *out_err = FC_ERR_GENERIC;
                }
                ptr::null_mut()
            }
        },
        _ => {
            if !out_err.is_null() {
                *out_err = FC_ERR_CODEC;
            }
            ptr::null_mut()
        }
    }
}

/// JSON → `.mtn` 텍스트. 호출자가 fc_string_free.
#[no_mangle]
pub unsafe extern "C" fn fc_motion_json_to_mtn(
    json_text: *const c_char,
    out_err: *mut c_int,
) -> *mut c_char {
    let text = match cstr_to_str(json_text) {
        Some(s) => s,
        None => {
            if !out_err.is_null() {
                *out_err = FC_ERR_INVALID;
            }
            return ptr::null_mut();
        }
    };
    match catch_unwind(|| Motion::from_json(text)) {
        Ok(Ok(m)) => {
            if !out_err.is_null() {
                *out_err = FC_OK;
            }
            rust_to_c_string(write_mtn(&m))
        }
        _ => {
            if !out_err.is_null() {
                *out_err = FC_ERR_CODEC;
            }
            ptr::null_mut()
        }
    }
}

// ============================================================================
// Walk simulation (no real motor commands)
// ============================================================================

/// 워크 시뮬레이션 결과 한 시점.
#[repr(C)]
pub struct FfiFootTargets {
    /// elapsed_ms.
    pub elapsed_ms: f64,
    /// 0=Phase0, 1=Phase1, 2=Phase2, 3=Phase3.
    pub phase: u8,
    /// left x/y/z + right x/y/z.
    pub feet: [f64; 6],
}

/// 새 walk 엔진 핸들.
pub struct FcWalk {
    engine: WalkEngine,
}

/// 워크 엔진 생성.
#[no_mangle]
pub extern "C" fn fc_walk_new() -> *mut FcWalk {
    Box::into_raw(Box::new(FcWalk {
        engine: WalkEngine::new(),
    }))
}

/// 워크 엔진 해제.
#[no_mangle]
pub unsafe extern "C" fn fc_walk_free(h: *mut FcWalk) {
    if !h.is_null() {
        let _ = Box::from_raw(h);
    }
}

/// 명령 설정.
#[no_mangle]
pub unsafe extern "C" fn fc_walk_set_command(
    h: *mut FcWalk,
    x: f64,
    y: f64,
    a: f64,
    enable: c_int,
) -> c_int {
    if h.is_null() {
        return FC_ERR_INVALID;
    }
    (*h).engine.command = WalkCommand {
        x_amplitude: x,
        y_amplitude: y,
        a_amplitude: a,
        enabled: enable != 0,
    };
    FC_OK
}

/// 보행 주기 (ms) 갱신. 200..=1500 범위로 clamp.
#[no_mangle]
pub unsafe extern "C" fn fc_walk_set_period_ms(h: *mut FcWalk, period_ms: f64) -> c_int {
    if h.is_null() {
        return FC_ERR_INVALID;
    }
    (*h).engine.set_period_ms(period_ms);
    FC_OK
}

/// dt_ms 만큼 진행 후 발 궤적 sample.
#[no_mangle]
pub unsafe extern "C" fn fc_walk_tick(
    h: *mut FcWalk,
    dt_ms: u32,
    out: *mut FfiFootTargets,
) -> c_int {
    if h.is_null() || out.is_null() {
        return FC_ERR_INVALID;
    }
    let e = &mut (*h).engine;
    e.tick(Duration::from_millis(dt_ms as u64));
    let f = e.foot_targets();
    let phase = match e.phase() {
        forge_core::walk::WalkPhase::Phase0 => 0,
        forge_core::walk::WalkPhase::Phase1 => 1,
        forge_core::walk::WalkPhase::Phase2 => 2,
        forge_core::walk::WalkPhase::Phase3 => 3,
    };
    *out = FfiFootTargets {
        elapsed_ms: e.elapsed_ms,
        phase,
        feet: [
            f.left[0], f.left[1], f.left[2], f.right[0], f.right[1], f.right[2],
        ],
    };
    FC_OK
}

// ============================================================================
// Strategy FSM
// ============================================================================

/// strategy FSM 한 step. state는 0..4 (Idle/LookingForBall/Approaching/Kicking/Cooldown).
/// 입력: ball_pixel_count, since_kick_ms, abort.
/// 반환: 다음 state.
#[no_mangle]
pub extern "C" fn fc_strategy_step(
    state: u8,
    ball_pixel_count: u32,
    since_kick_ms: u32,
    abort: c_int,
) -> u8 {
    let s = match state {
        0 => StrategyState::Idle,
        1 => StrategyState::LookingForBall,
        2 => StrategyState::ApproachingBall,
        3 => StrategyState::Kicking,
        4 => StrategyState::Cooldown,
        _ => StrategyState::Idle,
    };
    let input = StrategyInput {
        ball: BlobResult {
            pixel_count: ball_pixel_count,
            centroid_x: 0.0,
            centroid_y: 0.0,
        },
        since_kick_ms,
        abort: abort != 0,
    };
    let next = s.next(input);
    match next {
        StrategyState::Idle => 0,
        StrategyState::LookingForBall => 1,
        StrategyState::ApproachingBall => 2,
        StrategyState::Kicking => 3,
        StrategyState::Cooldown => 4,
    }
}

// ============================================================================
// Vision — RGBA 버퍼에서 공 검출
// ============================================================================

/// FFI blob 결과.
#[repr(C)]
pub struct FfiBlobResult {
    /// 매칭 픽셀 수.
    pub pixel_count: u32,
    /// centroid x.
    pub centroid_x: f32,
    /// centroid y.
    pub centroid_y: f32,
}

/// RGBA 버퍼에서 ROBOCUP_BALL HSV 범위로 blob 검출.
///
/// `pixels`는 `width * height * 4` 바이트. 모자라면 FC_ERR_INVALID.
#[no_mangle]
pub unsafe extern "C" fn fc_vision_detect_ball(
    pixels: *const u8,
    pixel_count: u32,
    width: u32,
    height: u32,
    out: *mut FfiBlobResult,
) -> c_int {
    if pixels.is_null() || out.is_null() {
        return FC_ERR_INVALID;
    }
    if (width * height * 4) > pixel_count {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        let slice = std::slice::from_raw_parts(pixels, pixel_count as usize);
        let mut frame = Frame::solid(width, height, Pixel::default());
        for y in 0..height {
            for x in 0..width {
                let i = ((y * width + x) * 4) as usize;
                frame.set_pixel(
                    x,
                    y,
                    Pixel {
                        r: slice[i],
                        g: slice[i + 1],
                        b: slice[i + 2],
                        a: slice[i + 3],
                    },
                );
            }
        }
        let blob = detect_blob(&frame, HsvRange::ROBOCUP_BALL);
        *out = FfiBlobResult {
            pixel_count: blob.pixel_count,
            centroid_x: blob.centroid_x,
            centroid_y: blob.centroid_y,
        };
        FC_OK
    })
}

// ============================================================================
// Motion play (Sprint 15)
// ============================================================================

/// `motion_4096.bin` 의 `slot` 페이지를 실 robot 에 동기 송출.
///
/// - `bin_path` == NULL 이면 환경변수 `FORGE_MOTION_BIN` 또는 소스 기본 경로 사용.
/// - `dry_run` != 0 이면 stdout 로그만 (실 송출 없음).
/// - `confirm_risk` != 0 이면 HighRisk 모션 실행 허용.
/// - `follow_chain` != 0 이면 `next_page` chain 을 따라감 (v1.0: OFF 권장).
/// - `max_chain_depth` 0 이면 내부 기본값(10) 적용.
/// - 반환: 0=OK, 음수=에러.
///
/// **주의**: 이 함수는 블로킹. Swift 는 Task/DispatchQueue 에서 호출해야 함.
/// 취소는 `fc_motion_play_cancel` 로.
#[no_mangle]
pub unsafe extern "C" fn fc_motion_play_slot(
    handle: *mut FcBus,
    slot: u8,
    bin_path: *const c_char,
    dry_run: c_int,
    confirm_risk: c_int,
    single_foot_ok: c_int,
    follow_chain: c_int,
    max_chain_depth: usize,
) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        use forge_core::control::ExecuteOptions;
        use forge_core::motion::bin4096::read_bin4096_file;
        use forge_core::motion::player::MotionPlayer;
        use forge_core::motion::SafetyClass;
        use forge_core::synth::library::decode_raw_page;
        use std::path::PathBuf;
        use std::sync::atomic::Ordering;

        let bin = if bin_path.is_null() {
            // env 또는 기본 경로
            if let Ok(env) = std::env::var("FORGE_MOTION_BIN") {
                PathBuf::from(env)
            } else {
                let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
                p.push(
                    "../../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin",
                );
                p
            }
        } else {
            match cstr_to_str(bin_path) {
                Some(s) => PathBuf::from(s),
                None => return FC_ERR_INVALID,
            }
        };

        let raws = match read_bin4096_file(&bin) {
            Ok(r) => r,
            Err(_) => return FC_ERR_IO,
        };

        // 카탈로그에서 해당 슬롯의 safety_class 를 조회.
        let catalog_safety = forge_core::motion::OFFICIAL_CATALOG
            .iter()
            .find(|e| e.id == slot as u16)
            .map(|e| e.safety)
            .unwrap_or(SafetyClass::Safe);

        // chain 로드
        let depth = if max_chain_depth == 0 {
            10
        } else {
            max_chain_depth
        };
        let do_chain = follow_chain != 0;
        let mut pages = Vec::new();
        let mut visited = std::collections::HashSet::new();
        let mut current = slot;
        loop {
            if !visited.insert(current) || pages.len() >= depth {
                break;
            }
            let raw = match raws.iter().find(|r| r.index == current) {
                Some(r) => r,
                None => return FC_ERR_INVALID,
            };
            if raw.is_empty() {
                return FC_ERR_INVALID;
            }
            let page_safety = if current == slot {
                catalog_safety
            } else {
                SafetyClass::Safe
            };
            let page = match decode_raw_page(raw, page_safety) {
                Ok(p) => p,
                Err(_) => return FC_ERR_GENERIC,
            };
            let next = page.next_page;
            pages.push(page);
            if !do_chain || next == 0 {
                break;
            }
            current = next;
        }

        if dry_run != 0 {
            for p in &pages {
                println!(
                    "[dry-run] page {} '{}' {} step(s)",
                    p.id,
                    p.name,
                    p.steps.len()
                );
            }
            return FC_OK;
        }

        let opts = ExecuteOptions {
            confirm_risk: confirm_risk != 0 || single_foot_ok != 0,
        };

        let bus = &mut *handle;
        bus.motion_playing.store(true, Ordering::SeqCst);

        let player = MotionPlayer::new();
        bus.motion_cancel = Some(player.cancel_handle());

        let result = match &mut bus.backend {
            BusBackend::Posix(b) => {
                let mut jc = forge_core::control::JointController::new(b);
                player.play_pages(&mut jc, &pages, opts)
            }
            BusBackend::Tcp(b) => {
                let mut jc = forge_core::control::JointController::new(b);
                player.play_pages(&mut jc, &pages, opts)
            }
            BusBackend::Loopback(b) => {
                let mut jc = forge_core::control::JointController::new(b);
                player.play_pages(&mut jc, &pages, opts)
            }
        };

        bus.motion_playing.store(false, Ordering::SeqCst);
        bus.motion_cancel = None;

        match result {
            Ok(()) => FC_OK,
            Err(e) => err_code(&e),
        }
    })
}

/// 진행 중인 motion play 를 취소. 다음 8 ms 체크 시점에 중단.
/// 반환: 0=OK (취소 신호 전송), -2=핸들 invalid.
#[no_mangle]
pub unsafe extern "C" fn fc_motion_play_cancel(handle: *mut FcBus) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        let bus = &mut *handle;
        if let Some(ref h) = bus.motion_cancel {
            h.cancel();
        }
        FC_OK
    })
}

/// motion play 가 진행 중인지 확인. 1=재생 중, 0=정지, -2=핸들 invalid.
#[no_mangle]
pub unsafe extern "C" fn fc_motion_play_is_running(handle: *mut FcBus) -> c_int {
    if handle.is_null() {
        return FC_ERR_INVALID;
    }
    safe_call(|| {
        use std::sync::atomic::Ordering;
        let bus = &*handle;
        if bus.motion_playing.load(Ordering::SeqCst) {
            1
        } else {
            0
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_returns_non_empty() {
        unsafe {
            let v = fc_version();
            assert!(!v.is_null());
            let s = CStr::from_ptr(v).to_str().unwrap();
            assert!(!s.is_empty());
            fc_string_free(v);
        }
    }

    #[test]
    fn strategy_step_idle_to_looking() {
        let next = fc_strategy_step(0, 0, 0, 0);
        assert_eq!(next, 1); // LookingForBall
    }

    #[test]
    fn strategy_step_looking_to_approaching_when_ball() {
        let next = fc_strategy_step(1, 100, 0, 0);
        assert_eq!(next, 2);
    }

    #[test]
    fn strategy_abort_forces_idle() {
        let next = fc_strategy_step(2, 1500, 0, 1);
        assert_eq!(next, 0);
    }

    #[test]
    fn walk_tick_advances() {
        unsafe {
            let h = fc_walk_new();
            assert!(!h.is_null());
            assert_eq!(fc_walk_set_command(h, 0.04, 0.0, 0.0, 1), FC_OK);
            let mut t = std::mem::MaybeUninit::<FfiFootTargets>::uninit();
            assert_eq!(fc_walk_tick(h, 100, t.as_mut_ptr()), FC_OK);
            let t = t.assume_init();
            assert!(t.elapsed_ms > 99.0);
            fc_walk_free(h);
        }
    }

    // ---- motion play FFI tests ----

    #[test]
    fn motion_play_null_handle_returns_invalid() {
        unsafe {
            assert_eq!(
                fc_motion_play_slot(ptr::null_mut(), 1, ptr::null(), 1, 0, 0, 0, 0),
                FC_ERR_INVALID
            );
            assert_eq!(fc_motion_play_cancel(ptr::null_mut()), FC_ERR_INVALID);
            assert_eq!(fc_motion_play_is_running(ptr::null_mut()), FC_ERR_INVALID);
        }
    }

    #[test]
    fn motion_play_is_running_false_when_idle() {
        unsafe {
            // Construct a Loopback FcBus directly for testing.
            let mut h = Box::new(FcBus {
                backend: BusBackend::Loopback(Bus::new(LoopbackBus::default())),
                motion_cancel: None,
                motion_playing: std::sync::atomic::AtomicBool::new(false),
            });
            assert_eq!(fc_motion_play_is_running(h.as_mut() as *mut _), 0);
        }
    }

    #[test]
    fn motion_play_cancel_ok_when_no_play() {
        unsafe {
            let mut h = Box::new(FcBus {
                backend: BusBackend::Loopback(Bus::new(LoopbackBus::default())),
                motion_cancel: None,
                motion_playing: std::sync::atomic::AtomicBool::new(false),
            });
            // cancel with no active play — should still return OK.
            assert_eq!(fc_motion_play_cancel(h.as_mut() as *mut _), FC_OK);
        }
    }

    #[test]
    fn motion_play_dry_run_with_missing_bin_returns_error() {
        unsafe {
            let path = std::ffi::CString::new("/nonexistent/motion.bin").unwrap();
            let mut h = Box::new(FcBus {
                backend: BusBackend::Loopback(Bus::new(LoopbackBus::default())),
                motion_cancel: None,
                motion_playing: std::sync::atomic::AtomicBool::new(false),
            });
            let result = fc_motion_play_slot(
                h.as_mut() as *mut _,
                1,
                path.as_ptr(),
                1, // dry_run
                0,
                0,
                0,
                0,
            );
            assert!(result < 0, "expected error for missing bin, got {result}");
        }
    }
}
