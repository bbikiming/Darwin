//! DARwIn FPV 네이티브 콕핏 — 스위치 HTML 콕핏 + Ally Rust 코어 + Edge 렌더.
//!
//! 단일 .exe: 로컬 HTTP 서버(127.0.0.1:8765)가 임베드된 스위치 콕핏을 서빙하고, 로봇 연결은
//! darwin-fpv 런타임(ally-link 위 — Windows 검증) 으로 수립한다. 기동 시 자동 연결 후 Edge 를
//! `--app` 으로 띄운다(실제 브라우저 = Tauri WebView2 의 CSP 인젝션 문제 없음).
//!
//! 플래그: `--port N`(기본 8765) · `--wired`(유선 123.1, 기본 무선 0.33) ·
//!   (기본) 몰입형 전체화면(--app + --start-fullscreen, JS requestFullscreen 폴백, Alt+F4 탈출) ·
//!   `--windowed`(단순 창모드) · `--kiosk`(완전 락다운, InPrivate — 핸드헬드 조종엔 비권장) ·
//!   `--no-browser`(서버만).

mod app_state;
mod camera;
mod control;
mod platform;
mod server;
mod state_map;

use std::time::{Duration, Instant};

use app_state::AppState;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let port: u16 = flag_val(&args, "--port")
        .and_then(|s| s.parse().ok())
        .unwrap_or(8765);
    let prefer = if has_flag(&args, "--wired") {
        "wired"
    } else {
        "wireless"
    }
    .to_string();
    let no_browser = has_flag(&args, "--no-browser");
    // 3-상태 기동 모드. 기본은 몰입형 전체화면(--app + JS requestFullscreen) — 자세한 근거는
    // launch_browser/LaunchMode 주석 참조.
    let launch_mode = if has_flag(&args, "--kiosk") {
        LaunchMode::Kiosk // 완전 락다운(opt-in) — InPrivate 강제라 localStorage 비영속.
    } else if has_flag(&args, "--windowed") {
        LaunchMode::Windowed // 기존 단순 --app 창모드(opt-out)
    } else {
        LaunchMode::Fullscreen // 신규 기본: --app + --start-fullscreen(JS requestFullscreen 폴백). 상태 영속 + Alt+F4 탈출.
    };

    let app = AppState::new(prefer.clone());
    eprintln!("[fpv-native] DARwIn FPV 네이티브 콕핏 시작 — port={port} prefer={prefer}");

    // 방화벽 인바운드 UDP 허용(best-effort) — 로봇 TEL2(robot→Ally)는 cmd 와 다른 소스
    // 포트라 Windows stateful 매핑이 없어 기본 차단된다(→ 텔레메트리 빈 화면). 관리자면
    // 자동 적용, 아니면 무해 실패(영구 규칙은 ally-bootstrap.ps1 §2.5 가 관리자로 등록).
    try_firewall_allow();

    // 자동 연결(백그라운드) — 스위치 에이전트 자동연결 등가. 로봇 미가동이면 콕핏이 '연결
    // 대기' 표시, '재연결' 버튼으로 재시도.
    control::connect_async(app.clone());

    // WiFi 신호 백그라운드 갱신(~5s 캐시 — netsh 호출이 느려 핫패스 분리). 비-Windows None.
    {
        let app = app.clone();
        std::thread::spawn(move || loop {
            let dbm = platform::wifi_dbm();
            if let Ok(mut g) = app.wifi_dbm.lock() {
                *g = dbm;
            }
            std::thread::sleep(Duration::from_secs(5));
        });
    }

    // 서버가 뜨면 Edge 기동(별도 스레드 — serve 는 블로킹).
    if !no_browser {
        let url = format!("http://127.0.0.1:{port}/");
        std::thread::spawn(move || {
            if wait_port(port, 8000) {
                eprintln!("[fpv-native] 서버 준비됨 — 브라우저 기동: {url}");
                launch_browser(&url, launch_mode);
            } else {
                eprintln!("[fpv-native] 서버 대기 실패 — 브라우저로 {url} 를 직접 여세요");
            }
        });
    }

    if let Err(e) = server::serve(app, port) {
        eprintln!("[fpv-native] 서버 오류: {e}");
        std::process::exit(1);
    }
}

/// Edge 기동 모드. 기본 Fullscreen 은 --app + web/ JS requestFullscreen(상태 영속·Alt+F4 탈출),
/// Kiosk 만 진짜 락다운(InPrivate 강제 → localStorage 비영속, opt-in 전용).
#[derive(Clone, Copy)]
enum LaunchMode {
    Windowed,
    Fullscreen,
    Kiosk,
}

fn has_flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn flag_val<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

/// 127.0.0.1:port 가 받을 때까지 폴링(브라우저 기동 전 서버 준비 확인).
fn wait_port(port: u16, timeout_ms: u64) -> bool {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    while Instant::now() < deadline {
        if std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// Edge(`msedge.exe --app=URL`)로 콕핏을 띄운다 — 네이티브 Windows 브라우저, CSP 인젝션 무관.
/// 비-Windows(개발 호스트)에선 기본 열기 명령으로 폴백(GUI 운용은 Ally 전용).
#[cfg(windows)]
fn launch_browser(url: &str, mode: LaunchMode) {
    use std::process::Command;
    // **전용 Edge 프로필 (2026-06-16)** — 사용자의 기존 Edge 인스턴스와 ProcessSingleton 잠금이
    // 충돌해 콕핏 창이 안 뜨던 문제 수정(실기: "Lock file can not be created! Error code: 32" →
    // Edge abort). 별도 user-data-dir 로 격리하면 독립 인스턴스로 떠 충돌하지 않는다. 절대 제거 금지.
    let profile = std::env::var("LOCALAPPDATA")
        .map(|p| format!(r"{p}\DarwinFpv\edge-profile"))
        .unwrap_or_else(|_| {
            std::env::temp_dir()
                .join("darwin-fpv-edge")
                .to_string_lossy()
                .into_owned()
        });
    let candidates = [
        "msedge",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    ];
    for exe in candidates {
        let mut cmd = Command::new(exe);
        match mode {
            // Kiosk 만 진짜 락다운(InPrivate 강제 → localStorage 비영속, opt-in 전용).
            LaunchMode::Kiosk => {
                cmd.arg("--kiosk")
                    .arg(url)
                    .arg("--edge-kiosk-type=fullscreen");
            }
            // Fullscreen(기본): --app + --start-fullscreen. **--start-fullscreen 이 1차 풀스크린**
            // — 제스처 불요라 기동 즉시 전체화면이 된다. 게임패드 단독 조종(스틱/버튼 폴링)은 DOM
            // 제스처·user-activation 을 안 만들어 web/ JS requestFullscreen 이 안 걸리므로(검토 지적),
            // OS 레벨 --start-fullscreen 으로 띄운다. JS requestFullscreen 은 Edge 가 이 플래그를
            // 무시한 경우의 폴백(첫 터치/키 1회). --app 이라 상태 영속·Alt+F4 탈출 보존.
            LaunchMode::Fullscreen => {
                cmd.arg(format!("--app={url}")).arg("--start-fullscreen");
            }
            // Windowed(opt-out): 단순 --app 창모드(풀스크린 없음).
            LaunchMode::Windowed => {
                cmd.arg(format!("--app={url}"));
            }
        }
        // native-feel 플래그 — 모든 Edge 후보에 공통 적용(주소창/탭/뒤로가기 스와이프/크래시 버블
        // 제거 + 백그라운드 스로틀 해제로 텔레메트리 끊김 방지). 전용 프로필·폴백 체인은 보존.
        cmd.arg(format!("--user-data-dir={profile}"))
            .arg("--no-first-run")
            .arg("--no-default-browser-check")
            .arg("--disable-features=Translate,msEdgeSplitScreen")
            .arg("--overscroll-history-navigation=0")
            .arg("--hide-crash-restore-bubble")
            .arg("--disable-session-crashed-bubble")
            .arg("--noerrdialogs")
            .arg("--disable-background-timer-throttling")
            .arg("--disable-backgrounding-occluded-windows")
            .arg("--disable-renderer-backgrounding");
        if cmd.spawn().is_ok() {
            return;
        }
    }
    // 폴백: 기본 브라우저(전체화면/native 플래그 미적용 — 비상 경로).
    let _ = Command::new("cmd").args(["/C", "start", "", url]).spawn();
}

#[cfg(not(windows))]
fn launch_browser(url: &str, _mode: LaunchMode) {
    use std::process::Command;
    let _ = Command::new("open")
        .arg(url)
        .spawn()
        .or_else(|_| Command::new("xdg-open").arg(url).spawn());
}

/// 인바운드 UDP 허용 규칙을 현재 exe 기준으로 best-effort 등록(멱등: delete→add). 관리자
/// 권한이면 적용되고, 아니면 netsh 가 무해하게 실패한다(stdout/stderr 무시). 영구·확실한
/// 등록은 ally-bootstrap.ps1(관리자) 가 담당하고, 이건 그게 안 돈 경우의 보조 경로다.
#[cfg(windows)]
fn try_firewall_allow() {
    use std::process::{Command, Stdio};
    let exe = match std::env::current_exe() {
        Ok(p) => p.to_string_lossy().into_owned(),
        Err(_) => return,
    };
    let name = "name=DARwIn-FPV-In-UDP-self";
    let _ = Command::new("netsh")
        .args(["advfirewall", "firewall", "delete", "rule", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("netsh")
        .args([
            "advfirewall",
            "firewall",
            "add",
            "rule",
            name,
            "dir=in",
            "action=allow",
            &format!("program={exe}"),
            "protocol=udp",
            // **2026-06-16 수정** — public 포함. 로봇 직결 어댑터(LocalNetwork)는 Windows 가
            // 보통 Public 으로 분류한다(실기: 이더넷 2 = Public). private,domain 만이면 로봇→Ally
            // TEL2 UDP 가 차단돼 connected:false·IMU 무데이터·HUD 공백이 된다.
            "profile=private,domain,public",
            "enable=yes",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

#[cfg(not(windows))]
fn try_firewall_allow() {}
