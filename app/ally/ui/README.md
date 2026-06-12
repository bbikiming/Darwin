# ui/ — 웹 프론트 자리 (W2 구현)

WebView2 에 올라가는 콕핏 UI. **표시 전용** — 이동 명령 생성·E-STOP 경로에
관여하지 않는다 (PRD §7 INV-2). Rust 코어가 Tauri 이벤트로 밀어주는 상태
스냅샷(30Hz)+스틱 오버레이(60Hz)를 그리고, 사용자 조작은 Tauri 커맨드로
보낸다(터치 E-STOP 은 보조 경로).

## Switch 웹 콕핏 자산 이관 계획 (원본: tools/switch-pilot/web/)

| 원본 | 이관 방식 |
|---|---|
| `styles.css` 토큰(:root) | 색 팔레트 직계승, 간격·타이포는 1080p 토큰으로 재정의 (docs/02_UIUX_DESIGN.md §T·§C) |
| `robot3d.js` (Three.js GLB 뷰어) | 구조 재사용 — 관절각은 Rust ally-pose 가 푸시 (W3) |
| `app.js` 상태 폴링 | 폴링 → Tauri 이벤트 구독으로 교체 |
| `index.html` 레이아웃 | 콕핏 HUD 와이어프레임(02_UIUX_DESIGN.md §H)으로 재설계 |
| 카메라 `<img>` MJPEG | 동일 — `http://robot:8080/?action=stream` 직결 |

프레임워크 없음(vanilla JS) — Switch 콕핏 컨벤션 유지. Three.js 만 벤더링.
