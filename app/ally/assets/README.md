# assets/ — 앱 자산 자리

| 자산 | 출처 | 시점 |
|---|---|---|
| `darwin.glb` | `tools/switch-pilot/web/assets/darwin.glb` (733KB, ~30k tri, glTF 2.0) — 빌드 시 복사, 직접 수정 금지 | W3 |
| `fonts/` | 한글 포함 산세리프 + readout 모노스페이스 (라이선스 확인 후 번들) | W2 |
| `sounds/` | UI 틱·ARM 램프업·E-STOP 클락슨 등 (docs/02_UIUX_DESIGN.md §A) | W4 |
| `boxart/` | Armoury Crate 박스아트 (PKG-01) | W4 |

GLB 가 단일 메시면 W3 에서 Mac 의 STL/URDF 세트로 링크별 분리 재추출
(tools/switch-pilot 의 GLB 가공 스크립트 재사용).
