//! ally-pose — 합성 포즈 계산 (W3 구현 예정).
//!
//! TEL2 에는 관절각이 없다(무선 계약 상한) — Mac 앱과 동일하게 보행 위상
//! (phase)·래치 진폭으로 forge-core walk 게이트 모델 순기구학을 돌려 20관절
//! 각도를 합성하고, IMU roll/pitch 만 실측 보정한다. UI 는 이 포즈에
//! **"합성 포즈" 라벨을 불변 표기**한다 (제품 원칙 5 "정직한 표시").
//!
//! W3 범위 (docs/03_ARCHITECTURE.md §5):
//! - forge-core walk FK 직링크 (wasm 불필요 — Rust 가 계산해 30Hz 이벤트 푸시)
//! - Three.js 쪽은 darwin.glb 관절 트리에 각도 적용만
