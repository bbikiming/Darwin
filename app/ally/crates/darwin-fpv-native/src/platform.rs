//! 플랫폼 — ROG Ally(Windows) 호스트 정보(배터리·WiFi). 콕핏의 `switch_battery`·`signal_dbm`
//! 필드를 채운다. 비-Windows(개발 호스트)는 None(콕핏이 graceful 하게 "--" 표시).

/// 호스트 배터리(퍼센트, 충전 중 여부) — Windows `GetSystemPowerStatus`(kernel32).
/// 무배터리/미상/실패는 None. 빠른 syscall 이라 요청마다 호출해도 무해.
#[cfg(windows)]
pub fn host_battery() -> Option<(u8, bool)> {
    #[repr(C)]
    struct SystemPowerStatus {
        ac_line_status: u8,
        battery_flag: u8,
        battery_life_percent: u8,
        system_status_flag: u8,
        battery_life_time: u32,
        battery_full_life_time: u32,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetSystemPowerStatus(status: *mut SystemPowerStatus) -> i32;
    }
    // SAFETY: POD 구조체 1개를 0 초기화해 넘기고 반환값(0=실패)만 신뢰한다.
    unsafe {
        let mut s: SystemPowerStatus = std::mem::zeroed();
        if GetSystemPowerStatus(&mut s) == 0 {
            return None;
        }
        let _ = (
            s.battery_flag,
            s.system_status_flag,
            s.battery_life_time,
            s.battery_full_life_time,
        );
        // ac_line_status: 1 = AC(충전), 0 = 배터리. battery_life_percent: 255 = 미상.
        let charging = s.ac_line_status == 1;
        if s.battery_life_percent <= 100 {
            Some((s.battery_life_percent, charging))
        } else {
            None
        }
    }
}

#[cfg(not(windows))]
pub fn host_battery() -> Option<(u8, bool)> {
    None
}

/// WiFi 신호(dBm) — Windows `netsh wlan show interfaces` 의 Signal% 를 dBm 로 근사(표준
/// `dBm ≈ %/2 − 100`). 느린 외부 호출이라 호출부가 백그라운드로 ~5s 캐시한다. 실패 None.
/// 로케일 무관 파싱: `: <숫자>%` 형태 줄에서 숫자만 추출(영문 "Signal"·한글 "신호" 공통).
#[cfg(windows)]
pub fn wifi_dbm() -> Option<i32> {
    let out = std::process::Command::new("netsh")
        .args(["wlan", "show", "interfaces"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        let l = line.trim();
        // P3-1: "Signal"(영문)·"신호"(한글) 라인만 파싱 — SSID/프로필명에 든 "...50%" 같은
        // 숫자+% 가 Signal 줄보다 먼저 와도 오판하지 않게.
        if !(l.to_ascii_lowercase().contains("signal") || l.contains("신호")) {
            continue;
        }
        if let (Some(pct_end), Some(colon)) = (l.find('%'), l.rfind(':')) {
            if colon < pct_end {
                let digits: String = l[colon + 1..pct_end]
                    .chars()
                    .filter(char::is_ascii_digit)
                    .collect();
                if let Ok(pct) = digits.parse::<i32>() {
                    if (0..=100).contains(&pct) {
                        return Some(pct / 2 - 100);
                    }
                }
            }
        }
    }
    None
}

#[cfg(not(windows))]
pub fn wifi_dbm() -> Option<i32> {
    None
}
