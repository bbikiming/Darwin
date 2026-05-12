# harness/op1/

ROBOTIS DARWIN-OP 1세대 (CM-730 컨트롤러) 전용 하네스 자료.

## 구성

- (Phase 3) `BOM.md` — 부품 명세 (커넥터, 게이지, 길이, 단가, 구입처)
- [`leg-l-bus.yaml`](leg-l-bus.yaml) — 좌측 다리 Dynamixel 버스 WireViz 다이어그램 (Phase 1에서 작성됨)

## OP1 특화 사항

- 컨트롤러: CM-730 (STM32F103RE)
- USB: Mini-B (back panel)
- 오디오 잭 존재 (3.5 mm)
- HDMI 없음

상세는 [`docs/architecture/op1-vs-op2-matrix.md`](../../docs/architecture/op1-vs-op2-matrix.md).
