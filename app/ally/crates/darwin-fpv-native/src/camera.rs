//! 카메라 프록시 — 로봇 8080 MJPEG 의 `?action=snapshot`(단일 JPEG)을 가져온다(raw TCP,
//! 외부 의존 0). 레이트리밋 + stale 캐시(스위치 cockpit.py 프록시 동작 모사). 콕핏이
//! same-origin `/api/camera-frame.jpg` 로 ~180ms 마다 폴링한다.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::app_state::{epoch_ms, AppState};

/// 로봇 읽기 최소 간격(ms) — 그 안엔 캐시 반환.
const RATE_MS: i64 = 200;
/// 로봇 도달 실패 시 마지막 프레임을 유지하는 한도(ms).
const STALE_MS: i64 = 3000;

/// 캐시·레이트리밋을 적용한 프레임 1장. 호스트 미연결/실패면 None(콕핏이 재시도 표시).
pub fn camera_frame(app: &AppState) -> Option<Vec<u8>> {
    let host = app.host.lock().ok().and_then(|g| g.clone())?;
    let now = epoch_ms();

    // 신선 캐시 반환(로봇 과독 방지).
    if let Ok(cache) = app.camera.lock() {
        if !cache.jpeg.is_empty() && now - cache.fetched_epoch_ms < RATE_MS {
            return Some(cache.jpeg.clone());
        }
    }

    match fetch_snapshot(&host) {
        Ok(jpeg) => {
            if let Ok(mut cache) = app.camera.lock() {
                cache.jpeg = jpeg.clone();
                cache.fetched_epoch_ms = now;
            }
            Some(jpeg)
        }
        Err(_) => {
            // stale 폴백 — 최근 프레임이 있으면 잠시 더 보여준다(검은 화면 깜빡임 회피).
            let cache = app.camera.lock().ok()?;
            if !cache.jpeg.is_empty() && now - cache.fetched_epoch_ms < STALE_MS {
                Some(cache.jpeg.clone())
            } else {
                None
            }
        }
    }
}

/// 로봇 `http://<host>:8080/?action=snapshot` → JPEG 바이트. HTTP/1.0 + close 로 단순화.
fn fetch_snapshot(host: &str) -> std::io::Result<Vec<u8>> {
    let addr = format!("{host}:8080")
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::AddrNotAvailable, "주소 해석 실패")
        })?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(800))?;
    stream.set_read_timeout(Some(Duration::from_millis(900)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    let req = format!(
        "GET /?action=snapshot HTTP/1.0\r\nHost: {host}\r\nUser-Agent: darwin-fpv-native\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(req.as_bytes())?;
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf)?;

    let pos = find(&buf, b"\r\n\r\n")
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "HTTP 헤더 끝 없음"))?;
    // 상태줄 200 확인.
    let status_line = String::from_utf8_lossy(&buf[..pos.min(80)]);
    let first = status_line.lines().next().unwrap_or("");
    if !first.contains(" 200") {
        return Err(std::io::Error::other(format!("카메라 응답: {first}")));
    }
    let body = buf[pos + 4..].to_vec();
    if body.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "빈 바디",
        ));
    }
    Ok(body)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}
