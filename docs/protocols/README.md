# docs/protocols/

Dynamixel 1.0/2.0, CM-730/740 통신 명세. `app/core` Rust 코덱이 구현하는 사양.

## 문서

- [`dynamixel-1.0.md`](dynamixel-1.0.md) — Protocol 1.0 (MX-28T, CM-730/740, FSR가 사용)
- (Phase 2) `dynamixel-2.0.md` — Protocol 2.0 (XM-430, OP3 — 참고용)
- (Phase 2) `cm-730-740.md` — 컨트롤러 보드 차이, 직렬 핀맵, 부트로더, 펌웨어 업로드 절차

## 출처 우선순위

1. ROBOTIS e-Manual `https://emanual.robotis.com/docs/en/dxl/protocol1/`
2. `Framework/include/CM730.h`, `MX28.h` (vendor/reference/upstream-headers/)
3. ROBOTIS-OP-Series-Data PDF (vendor/reference/)
4. 학술 논문 / 커뮤니티 문서 (research/)
