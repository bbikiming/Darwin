//! ally-cli — 헤드리스 수용시험 (W1 구현 예정).
//!
//! W1 시나리오 (docs/04_ACCEPTANCE_ROADMAP.md §2 W1 게이트):
//! 핸드셰이크 → 20Hz 영명령 스트림(eff_hz ≥19 확인) → E-STOP 버스트 → 메트릭
//! 덤프(RTT·effective_hz·TEL2 수신율). switch-pilot `native_acceptance.py` 의
//! Rust 판으로, 이후 회귀 검증 도구로 영구 보존한다.

fn main() {
    println!(
        "ally-cli W0 골격 — 수용시험 시나리오는 W1에서 구현됩니다.\n\
         (df-wire {}-token 빌더·TEL2 파서는 골든 벡터 패리티 테스트로 검증됨: \
         cargo test -p df-wire)",
        14
    );
}
