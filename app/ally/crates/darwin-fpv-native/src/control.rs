//! 제어 — 로봇 연결(백그라운드) + 콕핏 액션 → 안전 게이트 사상.
//!
//! 연결은 `shell.rs::connect` 의 walklab-active 게이트를 미러한다(Tauri 제거). SSH 핸드셰이크가
//! ~2s 걸려 액션 fetch 타임아웃(1200ms)을 넘으므로 **백그라운드 스레드**에서 수행하고, 콕핏은
//! `/api/state` 폴링으로 연결 변화를 본다(스위치 에이전트 자동연결 등가).

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use ally_input::{now_ms, ButtonEdges};
use ally_link::ssh::SshClient;
use ally_link::udp::local_ip_toward;
use darwin_fpv::{ConnPath, Endpoint, EstopCause, Runtime, RuntimeConfig};

use crate::app_state::{epoch_ms, AppState, NativeSink};

/// robotis RSA identity(홈 기준) — STEP2 프로비저닝 키(shell.rs IDENTITY_REL 과 동일).
fn identity_path() -> Option<String> {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?;
    let mut p = std::path::PathBuf::from(home);
    p.push(".ssh/id_rsa_darwin");
    Some(p.to_string_lossy().into_owned())
}

/// 비차단 연결 — 이미 진행 중이면 무시. 결과는 로그 + `/api/state` 로 노출.
pub fn connect_async(app: Arc<AppState>) {
    if app.connecting.swap(true, Ordering::SeqCst) {
        return; // 이미 연결 시도 중.
    }
    app.push_log("연결 시도");
    std::thread::spawn(move || {
        match do_connect(&app) {
            Ok(host) => app.push_log(&format!("연결됨 · {host}")),
            Err(e) => app.push_log(&format!("연결 실패 · {e}")),
        }
        app.connecting.store(false, Ordering::SeqCst);
    });
}

/// walklab 게이트 → Runtime 기동 → 핸들 적재(기존 런타임 교체). shell.rs::connect 미러.
fn do_connect(app: &AppState) -> Result<String, String> {
    let prefer = app.prefer.lock().map(|g| g.clone()).unwrap_or_default();
    let (host, path) = if prefer == "wired" {
        (ally_link::WIRED_HOST, ConnPath::Wired)
    } else {
        (ally_link::WIRELESS_HOST, ConnPath::Wireless)
    };
    let identity = identity_path();

    // walklab-active 선검사(없으면 핸드셰이크 미채택 → 무증상 SSH 폴백·eff_hz 0).
    let ssh = SshClient::new(host, identity.clone());
    let progress = ssh
        .run("cat /tmp/df-pilot-progress 2>/dev/null || true")
        .map_err(|e| format!("SSH 연결 실패({host}): {e}"))?
        .trim()
        .to_string();
    if progress != "walklab-active" {
        return Err(format!("walklab 미가동(progress='{progress}')"));
    }

    // 재연결 자폭 방지(P1-2): 기존 런타임을 **새 핸드셰이크 전에** 종료한다. Runtime::start 가
    // 고정 CHANNEL_PATH 에 새 토큰을 쓰는데, 옛 런타임 shutdown 의 retract_handshake 가 같은
    // 경로를 rm 하므로 — start 후에 옛 것을 닫으면 새 채널을 지워 새 UDP 세션이 자멸한다.
    let old = app.rt.lock().ok().and_then(|mut g| g.take());
    if let Some(old) = old {
        old.shutdown();
    }
    if let Ok(mut g) = app.estop.lock() {
        *g = None;
    }
    if let Ok(mut g) = app.inject.lock() {
        *g = None;
    }

    let cfg = RuntimeConfig {
        endpoint: Endpoint::Robot {
            host: host.to_string(),
            identity,
            path,
        },
        tick: Duration::from_millis(50),
        recv_timeout: Duration::from_millis(3),
    };
    let sink = Arc::new(NativeSink::new(app.shared.clone()));
    let rt = Runtime::start(cfg, sink).map_err(|e| format!("런타임 기동 실패: {e}"))?;

    // 새 핸들 적재.
    if let Ok(mut g) = app.estop.lock() {
        *g = Some(rt.estop_handle());
    }
    if let Ok(mut g) = app.inject.lock() {
        *g = Some(rt.edge_injector());
    }
    if let Ok(mut g) = app.host.lock() {
        *g = Some(host.to_string());
    }
    if let Ok(mut g) = app.local_ip.lock() {
        *g = local_ip_toward(host).ok().map(|ip| ip.to_string());
    }
    if let Ok(mut g) = app.connect_epoch_ms.lock() {
        *g = Some(epoch_ms());
    }
    if let Ok(mut g) = app.rt.lock() {
        *g = Some(rt);
    }
    Ok(host.to_string())
}

/// 런타임 종료 + 핸들 정리(핸드셰이크 철회는 Runtime::shutdown).
pub fn disconnect(app: &AppState) {
    let old = app.rt.lock().ok().and_then(|mut g| g.take());
    if let Some(rt) = old {
        rt.shutdown();
    }
    if let Ok(mut g) = app.estop.lock() {
        *g = None;
    }
    if let Ok(mut g) = app.inject.lock() {
        *g = None;
    }
    app.push_log("연결 해제");
}

/// 콕핏 `/api/action` 동사 → 안전 게이트. 반환값 = **실제로 디스패치됐는가**(P2-2: 미연결
/// 무전송을 `{ok:true}` 거짓성공으로 보고하지 않게 — 콕핏이 false 면 "명령 전송 실패" 표시).
/// `reconnect` 는 호출부(server)가 connect_async 로 처리.
pub fn do_action(app: &AppState, action: &str) -> bool {
    match action {
        "arm" => {
            let ok = inject(
                app,
                ButtonEdges {
                    arm: true,
                    ..Default::default()
                },
            );
            app.push_log(if ok {
                "조종 시작(ARM)"
            } else {
                "ARM 무시(미연결)"
            });
            ok
        }
        "recover" => {
            let ok = inject(
                app,
                ButtonEdges {
                    recover: true,
                    ..Default::default()
                },
            );
            app.push_log(if ok {
                "복구"
            } else {
                "복구 무시(미연결)"
            });
            ok
        }
        // 정지·비상정지 모두 하드 E-STOP: 빠른 UDP 버스트(bus) + 게이트 래치(에지 주입).
        // Ally 게이트엔 소프트 disarm 에지가 없어 '정지'도 E-STOP 으로 수렴(재개는 '복구').
        "stop" | "estop" => {
            let mut dispatched = false;
            if let Ok(g) = app.estop.lock() {
                if let Some(bus) = g.as_ref() {
                    bus.fire(EstopCause::Touch, now_ms());
                    dispatched = true;
                }
            }
            let injected = inject(
                app,
                ButtonEdges {
                    estop: true,
                    ..Default::default()
                },
            );
            let ok = dispatched || injected;
            let label = if action == "stop" {
                "정지(E-STOP)"
            } else {
                "비상정지"
            };
            app.push_log(if ok {
                label
            } else {
                "E-STOP 무시(미연결 — 무전송)"
            });
            ok
        }
        "ping" => {
            app.push_log("점검(ping)");
            true
        }
        _ => false,
    }
}

/// 버튼 에지를 런타임 control-tx 게이트로 주입. 반환값 = **실제 전송 여부**(미연결=false).
fn inject(app: &AppState, e: ButtonEdges) -> bool {
    if let Ok(g) = app.inject.lock() {
        if let Some(tx) = g.as_ref() {
            return tx.send(e).is_ok();
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app_state::AppState;

    #[test]
    fn actions_report_false_when_disconnected() {
        // P2-2: 미연결(inject/bus None)이면 안전·이동 명령은 실제 무전송이므로 false 를
        // 반환해야 한다(콕핏이 "명령 전송 실패"로 정직 표시 — 거짓성공 금지).
        let app = AppState::new("wireless".into());
        assert!(!do_action(&app, "arm"));
        assert!(!do_action(&app, "estop"));
        assert!(!do_action(&app, "stop"));
        assert!(!do_action(&app, "recover"));
        // ping 은 진단 로그 전용 → 항상 성공.
        assert!(do_action(&app, "ping"));
        // 미지 동사 → false.
        assert!(!do_action(&app, "bogus"));
    }
}
