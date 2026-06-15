//! 상태 매핑 — Ally `darwin-fpv` 런타임 `Snapshot` → 스위치 콕핏 `/api/state` 스키마.
//!
//! 스위치 `web/app.js` 가 읽는 필드를 **그대로** 내보내 프런트를 무수정 재사용한다(계약).
//! app.js 가 소비하는 키: command{stride_mm,side_mm,turn_deg,head_*}·controller{left/right_x/y}·
//! mode·connected·ssh_connected·updated_at_ms·moving·armed·estopped·deadman·target·local_ip·
//! uptime_sec·input_status·watchdog_label·switch_battery·battery_v/pct·robot_fallen/walking·
//! link_latency_ms·packet_loss_pct·imu{source,gyro_*,accel_*}·camera·logs.

use serde_json::{json, Value};

use crate::app_state::{epoch_ms, AppState};

/// 스위치 콕핏이 폴링하는 `/api/state` 응답을 만든다.
pub fn build_state(app: &AppState) -> Value {
    let connected_rt = app.is_connected();
    let snap = app
        .shared
        .snap
        .read()
        .map(|g| g.clone())
        .unwrap_or_else(|_| darwin_fpv::Snapshot::disconnected());
    let sticks = app.shared.sticks.read().map(|g| *g).unwrap_or([0.0; 6]);
    let updated_at = app
        .shared
        .updated_at_epoch_ms
        .load(std::sync::atomic::Ordering::Relaxed);
    let host = app.host.lock().ok().and_then(|g| g.clone());
    let local_ip = app.local_ip.lock().ok().and_then(|g| g.clone());
    let connect_epoch = app.connect_epoch_ms.lock().ok().and_then(|g| *g);
    let logs: Vec<String> = app
        .logs
        .lock()
        .map(|g| g.iter().cloned().collect())
        .unwrap_or_default();

    let now = epoch_ms();
    let eff_hz = snap.conn.eff_hz;
    // 링크 살아있음 = 런타임 활성 + ACK 흐름(eff_hz≥1). UDP 도달 신호.
    let link_up = connected_rt && eff_hz >= 1.0;

    // 명령 5축 — 보행 3축(stride/side/turn) + 머리 pan/tilt(RS 헤드 레이트 적분).
    let command = json!({
        "stride_mm": snap.cmd.x,
        "side_mm": snap.cmd.y,
        "turn_deg": snap.cmd.a,
        "head_pan_deg": snap.cmd.head_pan,
        "head_tilt_deg": snap.cmd.head_tilt,
    });
    let moving = snap.cmd.x.abs() > 0.2 || snap.cmd.y.abs() > 0.2 || snap.cmd.a.abs() > 0.2;

    let controller = json!({
        "left_x": sticks[0], "left_y": sticks[1],
        "right_x": sticks[2], "right_y": sticks[3],
    });

    // 텔레메트리 파생.
    let (battery_v, battery_pct, robot_fallen, robot_walking, imu) = match &snap.tel {
        Some(t) => (
            json!(t.voltage_v),
            json!(t.battery_pct),
            json!(t.fallen),
            json!(t.walking),
            json!({
                "source": "robot",
                "gyro_x": t.gyro[0], "gyro_y": t.gyro[1], "gyro_z": t.gyro[2],
                "accel_x": t.accel[0], "accel_y": t.accel[1], "accel_z": t.accel[2],
            }),
        ),
        None => (
            Value::Null,
            Value::Null,
            json!(0),
            json!(false),
            json!({ "source": "none" }),
        ),
    };

    // 패킷 손실 = 기대 20Hz 대비 eff_hz 결손(링크 살아있을 때만).
    let packet_loss = if link_up {
        json!(((20.0 - eff_hz) / 20.0 * 100.0).clamp(0.0, 100.0))
    } else {
        Value::Null
    };

    let uptime_sec = connect_epoch.map_or(0, |e| ((now - e) / 1000).max(0));
    let input_status = if snap.pad.connected {
        "게임패드 연결"
    } else {
        "입력장치 없음"
    };
    let target = host
        .as_ref()
        .map_or_else(|| "-".to_string(), |h| format!("robotis@{h}"));

    // 런타임이 없으면 updated_at 을 과거로 둬 콕핏이 stale(연결 끊김)로 정직 표시.
    let updated_at_ms = if connected_rt {
        updated_at
    } else {
        now - 60_000
    };

    // ROG Ally 호스트 배터리(Windows GetSystemPowerStatus) — 콕핏 핸드헬드 배터리 칩.
    let switch_battery = match crate::platform::host_battery() {
        Some((pct, charging)) => json!({ "percent": pct, "charging": charging }),
        None => Value::Null,
    };
    // WiFi 신호(dBm) — 백그라운드 캐시(없으면 null → 콕핏 "--").
    let signal_dbm = app.wifi_dbm.lock().ok().and_then(|g| *g);
    // 카메라 경로 — Ally 는 직결(SSH 터널 불요). host 알면 port_open.
    let camera_runtime = if host.is_some() {
        json!({ "local_port_open": true, "status": "port_open", "port": 8080 })
    } else {
        json!({ "status": "disabled" })
    };
    // 활성 전송 경로 — UDP 패스트레인 vs SSH 파일 폴백(FPV 신뢰도 핵심 신호). 미연결=none.
    let transport = if link_up {
        snap.conn.transport.as_str()
    } else {
        "none"
    };
    // 워치독 라벨 — 안전/링크 상태 파생.
    let watchdog_label = if snap.safety.estop_latched {
        "정지"
    } else if snap.safety.recovering {
        "복구 중"
    } else if link_up {
        "정상"
    } else if connected_rt {
        "감시 중"
    } else {
        "—"
    };

    json!({
        "mode": "robot_udp",
        "connected": link_up,
        "ssh_connected": false,
        "updated_at_ms": updated_at_ms,
        "moving": moving,
        "armed": snap.safety.armed,
        "estopped": snap.safety.estop_latched,
        // Ally 는 데드맨 게이트 없음(F10 LB 데드맨 해제) — 항상 "잡음" 으로 둬 'ZL 잡기' 미표시.
        "deadman": true,
        "target": target,
        "local_ip": local_ip.unwrap_or_else(|| "-".to_string()),
        "uptime_sec": uptime_sec,
        "input_status": input_status,
        "watchdog_label": watchdog_label,
        "transport": transport,
        "command": command,
        "controller": controller,
        "switch_battery": switch_battery,
        "battery_v": battery_v,
        "battery_pct": battery_pct,
        "robot_fallen": robot_fallen,
        "robot_walking": robot_walking,
        "link_latency_ms": snap.conn.rtt_ms,
        "packet_loss_pct": packet_loss,
        "signal_dbm": signal_dbm,
        "wifi_dbm": signal_dbm,
        "imu": imu,
        "camera": camera_config(host.as_deref()),
        "camera_runtime": camera_runtime,
        "logs": logs,
    })
}

/// 카메라 설정 — 연결 시 로봇 8080 MJPEG. snapshot_url 존재 → 콕핏이 /api/camera-frame.jpg
/// 프록시 사용(레이트리밋·same-origin). 미연결이면 비활성.
fn camera_config(host: Option<&str>) -> Value {
    match host {
        Some(h) => json!({
            "enabled": true,
            "stream_url": format!("http://{h}:8080/?action=stream"),
            "snapshot_url": format!("http://{h}:8080/?action=snapshot"),
            "label": "DARwIn Head Camera",
            "route": "직결",
        }),
        None => json!({ "enabled": false }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app_state::AppState;
    use darwin_fpv::ConnPath;

    #[test]
    fn maps_core_fields_for_switch_cockpit() {
        let app = AppState::new("wireless".into());
        {
            let mut s = app.shared.snap.write().unwrap();
            s.cmd.x = 38.0;
            s.cmd.y = -10.0;
            s.cmd.a = 5.0;
            s.cmd.head_pan = 12.0;
            s.cmd.head_tilt = -7.0;
            s.safety.armed = true;
            s.pad.connected = true;
            s.conn.path = ConnPath::Wireless;
        }
        *app.shared.sticks.write().unwrap() = [0.5, -0.3, 0.1, 0.2, 0.0, 0.0];

        let v = build_state(&app);
        // app.js 계약 필드 — 28개 top-level + 5축 command 전부 공급.
        assert_eq!(v["mode"], "robot_udp");
        assert_eq!(v["connected"], false, "rt None → 미연결");
        assert_eq!(v["armed"], true);
        assert_eq!(v["estopped"], false);
        assert_eq!(v["deadman"], true, "Ally 데드맨 없음 → 항상 true");
        assert_eq!(v["command"]["stride_mm"], 38.0);
        assert_eq!(v["command"]["side_mm"], -10.0);
        assert_eq!(v["command"]["turn_deg"], 5.0);
        assert_eq!(v["command"]["head_pan_deg"], 12.0, "머리 pan 노출");
        assert_eq!(v["command"]["head_tilt_deg"], -7.0, "머리 tilt 노출");
        assert_eq!(v["moving"], true);
        assert_eq!(v["controller"]["left_x"], 0.5);
        assert_eq!(v["controller"]["right_y"], 0.2);
        assert_eq!(v["input_status"], "게임패드 연결");
        assert_eq!(v["imu"]["source"], "none", "TEL2 미수신 → none");
        assert_eq!(v["battery_v"], Value::Null);
        assert_eq!(v["robot_walking"], false);
        assert!(v["logs"].is_array());
        // 갭 보강 필드 — 키 존재(값은 플랫폼/연결에 따라).
        assert!(v.get("switch_battery").is_some(), "switch_battery 키 존재");
        assert!(v.get("signal_dbm").is_some());
        assert!(v.get("wifi_dbm").is_some());
        assert_eq!(v["watchdog_label"], "—", "미연결 → —");
        assert_eq!(
            v["transport"], "none",
            "미연결 → 전송 none(좌측 레일 '전송' 타일)"
        );
        assert_eq!(
            v["camera_runtime"]["status"], "disabled",
            "host 없음 → disabled"
        );
    }

    #[test]
    fn camera_and_target_follow_host() {
        let app = AppState::new("wireless".into());
        *app.host.lock().unwrap() = Some("192.168.0.33".into());
        let v = build_state(&app);
        assert_eq!(v["camera"]["enabled"], true);
        assert_eq!(
            v["camera"]["snapshot_url"],
            "http://192.168.0.33:8080/?action=snapshot"
        );
        assert_eq!(v["target"], "robotis@192.168.0.33");
        assert_eq!(
            v["camera_runtime"]["status"], "port_open",
            "host 있으면 직결 port_open"
        );
    }

    #[test]
    fn disconnected_has_no_camera() {
        let app = AppState::new("wireless".into());
        let v = build_state(&app);
        assert_eq!(v["camera"]["enabled"], false);
        assert_eq!(v["target"], "-");
    }
}
