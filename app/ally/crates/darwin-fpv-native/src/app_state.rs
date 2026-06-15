//! 앱 상태 — 공유 스냅샷(NativeSink 가 기록) + 활성 런타임 핸들 + 액션 로그·카메라 캐시.
//!
//! INV-2 유지: 안전 런타임(darwin-fpv)은 이 모듈을 모른다. NativeSink 가 [`EventSink`] 를
//! 구현해 런타임 스냅샷을 공유 상태에 적재하고, HTTP `/api/state` 가 그걸 읽어 스위치
//! 콕핏 스키마로 사상한다(폴링 REST — Tauri 이벤트 대체).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use ally_input::ButtonEdges;
use darwin_fpv::{EstopBus, EventSink, Runtime, Snapshot};

/// 벽시계 epoch ms — `updated_at_ms`(브라우저 `Date.now()` 와 비교) 용. ally_input::now_ms
/// 는 monotonic 이라 여기 쓰면 안 된다(브라우저 시계와 도메인 불일치).
pub fn epoch_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// epoch ms → "HH:MM:SS" (UTC). 액션 로그 라벨용(표시 전용).
pub fn hms(epoch_ms: i64) -> String {
    let secs = (epoch_ms / 1000).rem_euclid(86_400);
    format!(
        "{:02}:{:02}:{:02}",
        secs / 3600,
        (secs % 3600) / 60,
        secs % 60
    )
}

/// NativeSink 가 적재하는 공유 표시 상태(단일 쓰기 = 런타임 RX/TX 스레드, 다중 읽기 = HTTP).
pub struct SharedState {
    pub snap: RwLock<Snapshot>,
    /// [lx, ly, rx, ry, lt, rt] — emit_stick 최신값(스틱 오버레이·자세 추정용).
    pub sticks: RwLock<[f64; 6]>,
    /// 마지막 emit_state 의 epoch ms. 런타임이 죽으면 멈춰서 stale 이 자연 노출된다.
    pub updated_at_epoch_ms: AtomicI64,
}

impl SharedState {
    pub fn new() -> Arc<Self> {
        Arc::new(SharedState {
            snap: RwLock::new(Snapshot::disconnected()),
            sticks: RwLock::new([0.0; 6]),
            updated_at_epoch_ms: AtomicI64::new(0),
        })
    }
}

/// darwin-fpv 런타임 → 공유 상태 어댑터(Tauri 이벤트 대신 메모리 적재). 짧고 비차단(INV-2).
pub struct NativeSink {
    shared: Arc<SharedState>,
}

impl NativeSink {
    pub fn new(shared: Arc<SharedState>) -> Self {
        NativeSink { shared }
    }
}

impl EventSink for NativeSink {
    fn emit_state(&self, snapshot: &Snapshot) {
        if let Ok(mut g) = self.shared.snap.write() {
            *g = snapshot.clone();
        }
        self.shared
            .updated_at_epoch_ms
            .store(epoch_ms(), Ordering::Relaxed);
    }

    fn emit_stick(&self, lx: f64, ly: f64, rx: f64, ry: f64, lt: f64, rt: f64) {
        if let Ok(mut g) = self.shared.sticks.write() {
            *g = [lx, ly, rx, ry, lt, rt];
        }
    }
}

/// 카메라 프레임 캐시(레이트리밋·stale 폴백).
#[derive(Default)]
pub struct CameraCache {
    pub jpeg: Vec<u8>,
    pub fetched_epoch_ms: i64,
}

/// 앱 전역 상태 — HTTP 워커 스레드들이 Arc 로 공유한다.
pub struct AppState {
    pub shared: Arc<SharedState>,
    /// 활성 런타임(연결 시 Some). 재연결/종료에서 교체·정지.
    pub rt: Mutex<Option<Runtime>>,
    /// E-STOP 버스(빠른 UDP 버스트 경로) — 터치 E-STOP 합류.
    pub estop: Mutex<Option<EstopBus>>,
    /// 버튼 에지 주입단(콕핏 터치 ARM/복구/E-STOP 게이트 래치).
    pub inject: Mutex<Option<Sender<ButtonEdges>>>,
    /// 연결된 로봇 host(카메라 프록시·target 표시).
    pub host: Mutex<Option<String>>,
    /// "wired" | "wireless".
    pub prefer: Mutex<String>,
    /// 로컬 egress IP(표시).
    pub local_ip: Mutex<Option<String>>,
    /// 연결 시각 epoch ms(uptime 산출).
    pub connect_epoch_ms: Mutex<Option<i64>>,
    /// 연결 진행 가드(중복 connect 방지).
    pub connecting: AtomicBool,
    /// 액션 로그 링(<=20).
    pub logs: Mutex<VecDeque<String>>,
    /// 카메라 프레임 캐시.
    pub camera: Mutex<CameraCache>,
    /// WiFi 신호(dBm) — 백그라운드 poller 가 ~5s 갱신(느린 netsh 호출 캐시). None=미상.
    pub wifi_dbm: Mutex<Option<i32>>,
}

impl AppState {
    pub fn new(prefer: String) -> Arc<Self> {
        Arc::new(AppState {
            shared: SharedState::new(),
            rt: Mutex::new(None),
            estop: Mutex::new(None),
            inject: Mutex::new(None),
            host: Mutex::new(None),
            prefer: Mutex::new(prefer),
            local_ip: Mutex::new(None),
            connect_epoch_ms: Mutex::new(None),
            connecting: AtomicBool::new(false),
            logs: Mutex::new(VecDeque::new()),
            camera: Mutex::new(CameraCache::default()),
            wifi_dbm: Mutex::new(None),
        })
    }

    /// 연결 여부(런타임 존재).
    pub fn is_connected(&self) -> bool {
        self.rt.lock().map(|g| g.is_some()).unwrap_or(false)
    }

    /// 액션/이벤트 로그 1줄 추가(시각 prefix, 링 20).
    pub fn push_log(&self, msg: &str) {
        if let Ok(mut logs) = self.logs.lock() {
            logs.push_back(format!("{} {}", hms(epoch_ms()), msg));
            while logs.len() > 20 {
                logs.pop_front();
            }
        }
    }
}
