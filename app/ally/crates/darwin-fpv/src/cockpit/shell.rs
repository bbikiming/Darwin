//! Tauri 셸 — `feature = "cockpit"`. EventSink 의 Tauri 구현 + §3 커맨드 + 런타임 배선.
//!
//! INV-2: **이 모듈만 tauri 를 안다.** 안전 런타임([`crate::runtime`])은 EventSink 트레이트
//! 너머로만 표시계층에 닿는다 — 여기서 그 트레이트를 Tauri 이벤트로 구현한다. 런타임은
//! connect 커맨드에서 기동되며(빌더보다 먼저 sink 를 받음), webview 는 명령·E-STOP 생성
//! 경로에 없다(물리 B·수퍼바이저가 주 경로, 터치 E-STOP 은 보조 발원으로 estop 버스 합류).

use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tauri::{AppHandle, Emitter, State};

use ally_input::now_ms;
use ally_link::ssh::SshClient;

use crate::cockpit::{state_payload, stick_payload};
use crate::estop::{EstopBus, EstopCause};
use crate::event::EventSink;
use crate::runtime::{Endpoint, Runtime, RuntimeConfig};
use crate::state::{ConnPath, Snapshot};

/// robotis RSA identity 상대 경로(홈 기준). STEP2 프로비저닝 키.
const IDENTITY_REL: &str = ".ssh/id_rsa_darwin";

/// Tauri 백엔드 EventSink — 런타임 스냅샷을 §3 이벤트로 webview 에 push(표시 전용).
struct TauriSink {
    app: AppHandle,
    emits: AtomicU64,
}

impl EventSink for TauriSink {
    fn emit_state(&self, snap: &Snapshot) {
        let n = self.emits.fetch_add(1, Ordering::Relaxed);
        if n == 0 || n.is_multiple_of(60) {
            eprintln!(
                "[cockpit] emit_state #{n} eff_hz={:.1} armed={} pad={} tel={}",
                snap.conn.eff_hz,
                snap.safety.armed,
                snap.pad.connected,
                snap.tel.is_some()
            );
        }
        let _ = self.app.emit("state", state_payload(snap, now_ms()));
    }
    fn emit_stick(&self, lx: f64, ly: f64, rx: f64, ry: f64, lt: f64, rt: f64) {
        let _ = self.app.emit("stick", stick_payload(lx, ly, rx, ry, lt, rt));
    }
}

/// 앱 상태 — 활성 런타임(연결 시 기동, 해제 시 종료)과 그 estop 버스 핸들.
#[derive(Default)]
struct AppState {
    rt: Mutex<Option<Runtime>>,
    estop: Mutex<Option<EstopBus>>,
}

fn identity_path() -> Option<String> {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?;
    let mut p = std::path::PathBuf::from(home);
    p.push(IDENTITY_REL);
    Some(p.to_string_lossy().into_owned())
}

/// §3 `connect` — §7 세션 시퀀스 개시(prefer = "wired"|"wireless"). 실로봇 경로:
/// 운영자가 `ally-cli connect` 로 단일세션·walklab 선검증한 상태여야 한다.
#[tauri::command]
fn connect(prefer: String, app: AppHandle, state: State<AppState>) -> Result<(), String> {
    let (host, path) = match prefer.as_str() {
        "wired" => (ally_link::WIRED_HOST, ConnPath::Wired),
        _ => (ally_link::WIRELESS_HOST, ConnPath::Wireless),
    };
    eprintln!(
        "[cockpit] ▶ connect(prefer={prefer}) host={host} identity={:?}",
        identity_path()
    );

    // walklab-active + incumbent 선검사 (ally-cli connect 와 동일 게이트). 런타임 Robot
    // 경로는 이 검사를 반복하지 않으므로 여기서 한다 — 없으면 walklab 미가동 시 핸드셰이크가
    // 채택 안 돼 무증상 SSH 폴백으로 강등('연결됨인데 eff_hz 0·무반응')된다.
    let ssh = SshClient::new(host, identity_path());
    let progress = ssh
        .run("cat /tmp/df-pilot-progress 2>/dev/null || true")
        .map_err(|e| format!("SSH 연결 실패({host}): {e}"))?
        .trim()
        .to_string();
    if progress != "walklab-active" {
        let msg =
            format!("walklab 미가동(df-pilot-progress='{progress}') — 로봇에서 walklab 기동 후 재시도");
        eprintln!("[cockpit] ✗ {msg}");
        return Err(msg);
    }
    let incumbent = ssh
        .run(&format!("cat {} 2>/dev/null || true", ally_link::ssh::CHANNEL_PATH))
        .unwrap_or_default()
        .trim()
        .to_string();
    if !incumbent.is_empty() {
        eprintln!("[cockpit] ⚠ 활성 세션 감지(채널 {incumbent}) — 덮어쓰면 그 세션이 끊깁니다");
    }
    eprintln!("[cockpit] ✓ walklab-active 확인 — 런타임 기동");

    let cfg = RuntimeConfig {
        endpoint: Endpoint::Robot {
            host: host.to_string(),
            identity: identity_path(),
            path,
        },
        tick: Duration::from_millis(50),
        recv_timeout: Duration::from_millis(3),
    };
    let sink = Arc::new(TauriSink {
        app,
        emits: AtomicU64::new(0),
    });
    let rt = Runtime::start(cfg, sink).map_err(|e| {
        eprintln!("[cockpit] ✗ 런타임 기동 실패: {e}");
        e.to_string()
    })?;
    eprintln!("[cockpit] ✓ 런타임 기동 OK (host={host}) — 핸드셰이크/20Hz 스트림 시작");
    *state.estop.lock().unwrap() = Some(rt.estop_handle());
    // 기존 런타임 교체(잠금 밖에서 종료 — 합류가 잠금을 들지 않게).
    let old = state.rt.lock().unwrap().replace(rt);
    if let Some(old) = old {
        old.shutdown();
    }
    Ok(())
}

/// §3 `disconnect` — §7-⑦ 정리 후 종료(핸드셰이크 철회).
#[tauri::command]
fn disconnect(state: State<AppState>) {
    let old = state.rt.lock().unwrap().take();
    if let Some(rt) = old {
        rt.shutdown();
    }
    *state.estop.lock().unwrap() = None;
}

/// §3 `touch_estop` — 보조 E-STOP. estop 버스에 합류(물리 B 가 주 경로). webview 가
/// 죽어도 물리 경로는 무손상 — 이건 추가 발원일 뿐(INV-2 예외 아님).
#[tauri::command]
fn touch_estop(state: State<AppState>) {
    if let Some(bus) = state.estop.lock().unwrap().as_ref() {
        bus.fire(EstopCause::Touch, now_ms());
    }
}

/// §3 `set_settings` — 비안전 설정만(HUD 토글 등). 매핑 수치는 D2 동결(설정 항목 아님).
#[tauri::command]
fn set_settings(_settings: serde_json::Value) {}

/// 콕핏 실행 — Tauri 이벤트 루프(표시 전용 메인 스레드). 런타임은 connect 에서 기동.
pub fn run() {
    eprintln!("[cockpit] Tauri 셸 기동 — withGlobalTauri, 커맨드: connect/disconnect/touch_estop/set_settings");
    tauri::Builder::default()
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            connect,
            disconnect,
            touch_estop,
            set_settings
        ])
        .run(tauri::generate_context!())
        .expect("DARwIn FPV Tauri 실행 실패");
}
