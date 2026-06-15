//! HTTP 서버 — `tiny_http`(동기·경량) 4-워커. 정적(임베드 스위치 web/)·`/api/*` 라우팅.
//!
//! 폴링 REST(WebSocket 불요): 콕핏이 `/api/state` 를 ~8Hz, `/api/camera-frame.jpg` 를 ~5Hz
//! 폴링한다. 카메라 프록시가 ~1s 막혀도 다른 워커가 state 를 계속 처리한다(워커 4개).

use std::sync::Arc;

use include_dir::{include_dir, Dir};
use serde_json::{json, Value};
use tiny_http::{Header, Method, Request, Response, Server};

use crate::app_state::AppState;
use crate::{camera, control, state_map};

/// 스위치 콕핏 프런트 전체를 바이너리에 임베드(단일 .exe 자족).
static WEB: Dir = include_dir!("$CARGO_MANIFEST_DIR/web");

/// 127.0.0.1:port 바인드 + 4-워커 요청 루프(블로킹).
pub fn serve(app: Arc<AppState>, port: u16) -> std::io::Result<()> {
    let server =
        Server::http(("127.0.0.1", port)).map_err(|e| std::io::Error::other(e.to_string()))?;
    let server = Arc::new(server);
    eprintln!("[fpv-native] HTTP 서버 listening 127.0.0.1:{port}");

    let mut handles = Vec::new();
    for _ in 0..4 {
        let server = server.clone();
        let app = app.clone();
        handles.push(std::thread::spawn(move || {
            while let Ok(req) = server.recv() {
                handle(&app, req);
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    Ok(())
}

fn handle(app: &Arc<AppState>, mut req: Request) {
    let method = req.method().clone();
    let url = req.url().to_string();
    let path = url.split('?').next().unwrap_or(&url).to_string();

    match (&method, path.as_str()) {
        (Method::Get, "/api/state") => json_ok(req, &state_map::build_state(app)),
        (Method::Get, "/api/camera-frame.jpg") => serve_camera(app, req),
        (Method::Get, "/api/config") => json_ok(req, &json!({ "config": {}, "provisioned": true })),
        (Method::Get, "/api/provisioning") => json_ok(req, &json!({ "provisioned": true })),
        (Method::Get, "/api/health") => json_ok(req, &json!({ "checks": [] })),
        (Method::Get, "/api/robot-command") => json_ok(req, &json!({ "ok": false })),

        (Method::Post, "/api/action") => {
            let body = read_body(&mut req);
            let action = body
                .get("action")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let ok = if action == "reconnect" {
                control::connect_async(Arc::clone(app));
                true
            } else {
                control::do_action(app, &action)
            };
            json_ok(req, &json!({ "ok": ok, "action": action }));
        }
        (Method::Post, "/api/system") => {
            let body = read_body(&mut req);
            if body.get("action").and_then(Value::as_str) == Some("exit_app") {
                json_ok(req, &json!({ "ok": true }));
                // 응답 후 종료를 별도 스레드에서(P2-4): disconnect 가 SSH 합류로 막혀도 워커는
                // 즉시 풀리고, 핸드셰이크 철회 뒤 프로세스를 종료한다.
                let app = Arc::clone(app);
                std::thread::spawn(move || {
                    control::disconnect(&app);
                    std::process::exit(0);
                });
                return;
            }
            json_ok(req, &json!({ "ok": false }));
        }
        (Method::Post, "/api/service") => {
            let _ = read_body(&mut req);
            // Ally 카메라는 직결(터널 불요) — 콕핏이 에러 안 내게 ok.
            json_ok(req, &json!({ "ok": true }));
        }
        (Method::Post, "/api/config") => {
            let _ = read_body(&mut req);
            json_ok(req, &json!({ "ok": true }));
        }
        (Method::Post, "/api/preflight") => {
            let _ = read_body(&mut req);
            json_ok(req, &json!({ "ok": true, "level": "good", "checks": [] }));
        }
        (Method::Post, "/api/robot-ready") => {
            let _ = read_body(&mut req);
            json_ok(req, &json!({ "ok": true }));
        }

        (Method::Get, _) => serve_static(req, &path),
        _ => json_ok(req, &json!({ "ok": false })),
    }
}

fn serve_camera(app: &AppState, req: Request) {
    match camera::camera_frame(app) {
        Some(jpeg) => {
            let resp = Response::from_data(jpeg)
                .with_header(hdr("Content-Type", "image/jpeg"))
                .with_header(hdr("Cache-Control", "no-store"));
            let _ = req.respond(resp);
        }
        None => {
            let _ = req.respond(Response::from_string("no camera").with_status_code(503));
        }
    }
}

fn serve_static(req: Request, path: &str) {
    let rel = if path == "/" || path.is_empty() {
        "index.html"
    } else {
        path.trim_start_matches('/')
    };
    match WEB.get_file(rel) {
        Some(file) => {
            // no-store: 바이너리(임베드 web/) 갱신 후 Edge/브라우저가 옛 콕핏을 캐시하지 않게.
            let resp = Response::from_data(file.contents().to_vec())
                .with_header(hdr("Content-Type", content_type(rel)))
                .with_header(hdr("Cache-Control", "no-store"));
            let _ = req.respond(resp);
        }
        None => {
            let _ = req.respond(Response::from_string("404 Not Found").with_status_code(404));
        }
    }
}

fn read_body(req: &mut Request) -> Value {
    let mut s = String::new();
    if req.as_reader().read_to_string(&mut s).is_ok() {
        serde_json::from_str(&s).unwrap_or(Value::Null)
    } else {
        Value::Null
    }
}

fn json_ok(req: Request, v: &Value) {
    let body = serde_json::to_vec(v).unwrap_or_default();
    let resp = Response::from_data(body)
        .with_header(hdr("Content-Type", "application/json; charset=utf-8"))
        .with_header(hdr("Cache-Control", "no-store"));
    let _ = req.respond(resp);
}

fn hdr(key: &str, value: &str) -> Header {
    Header::from_bytes(key.as_bytes(), value.as_bytes()).expect("valid header")
}

fn content_type(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "webmanifest" => "application/manifest+json; charset=utf-8",
        "glb" => "model/gltf-binary",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "jpg" | "jpeg" => "image/jpeg",
        _ => "application/octet-stream",
    }
}
