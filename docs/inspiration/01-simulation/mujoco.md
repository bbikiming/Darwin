# MuJoCo — 미분가능 물리 시뮬레이션

## 한 줄 소개

원래 Roboti LLC의 상용 물리 엔진. 2021년 DeepMind 인수 후 무료화·오픈
소스화. 미분가능성과 빠른 contact 해석으로 RL 학습용 표준.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 개발사 | DeepMind (Google) |
| 라이선스 | **Apache 2.0** |
| 플랫폼 | Linux / macOS (Apple Silicon 네이티브 ★) / Windows |
| 언어 바인딩 | C, Python, MATLAB, Rust(unofficial) |
| 모델 포맷 | MJCF (자체 XML), URDF import 지원 |
| GPU | 옵션 (MuJoCo XLA / mjx) — Brax + JAX 백엔드 |
| Apple Silicon 가속 | ✅ ARM64 네이티브 |
| 최신 | MuJoCo 3.x (2024) — 확인 필요 |

## 왜 중요한가

- **Apple Silicon 네이티브** — Isaac Sim과 달리 macOS에서 즉시 동작.
  DarwinForge 사용자가 추가 머신 없이 sim 가능.
- **미분가능** — gradient를 통한 정책 최적화 (PILCO, MBRL).
- **Brax + MJX** — JAX로 GPU 가속 + 4096 환경 병렬 RL.
- **MuJoCo Menagerie** — 공식 로봇 모델 컬렉션 (Anymal, Spot, Talos 등).
  DARwIn-OP는 직접 없으므로 MJCF 변환 필요.

## DARwIn-OP 변환 흐름

```
HumaRobotics/darwin_description (URDF, BSD-2)
  ↓ urdf2mjcf 또는 수동 변환
darwin-op.xml (MJCF)
  ↓ MuJoCo Python load
sim ready
```

수동 변환 시 주의:
- URDF의 `joint type=continuous` → MJCF `<joint type="hinge">`
- mesh STL은 그대로 호환
- inertia 매트릭스 단위 일치 (URDF는 link-frame, MJCF도 link-frame)

## DarwinForge 적용 제안

### macOS에서 즉시 활용 가능 — 핵심 시나리오

```
┌─────────────────────────────────┐
│  DarwinForge.app  (macOS)        │
│                                  │
│  Walk Sim 탭                     │
│  ├── 현재: 단순 sin파            │
│  └── 신규: MuJoCo 백엔드 옵션    │
│       ↓ Python subprocess 또는   │
│       ↓ Rust mujoco-rs 바인딩    │
│  MuJoCo viewer 임베디드 또는     │
│  GLFW window 별도 창             │
└─────────────────────────────────┘
```

### Rust 바인딩 (선택지)

| crate | 상태 | 노트 |
|-------|------|------|
| `mujoco-rs` | unofficial | 기본 API 커버 |
| `dm_control` Python | 공식 | Python subprocess로 호출 |
| `mujoco_xla` (mjx) | 공식 | JAX 기반, GPU |

**권장 — Phase 1**: Python subprocess로 mujoco viewer를 띄우고, forge-core가
JSON-RPC로 모터 명령. 단순.

**권장 — Phase 2**: `mujoco-rs` 직접 임베디드 → 같은 프로세스 안에서 GUI에 렌더.

### URDF/MJCF 변환 스크립트

```sh
# scripts/sim/import-darwin-mjcf.sh
git clone --depth=1 https://github.com/HumaRobotics/darwin_description \
    /tmp/darwin_urdf
python3 scripts/sim/urdf_to_mjcf.py \
    --in /tmp/darwin_urdf/urdf/darwin.urdf \
    --out app/core/forge-sim-mujoco/models/darwin-op.xml
```

## Brax + MJX (RL 학습)

JAX 백엔드라서 GPU 1장으로 4096개 환경을 동시 시뮬. forge-core는 이걸 직접
호출하지 않고, **학습된 정책 가중치만 ONNX로 export → tract 추론**.

```
Linux + RTX (학습)              macOS DarwinForge (추론)
┌──────────────────┐            ┌──────────────────────┐
│ Brax + MJX       │  ONNX      │ forge-core::walk::    │
│ DARwIn-OP env    │ ─────────→ │  RLPolicy (tract)    │
│ PPO / SAC        │  (.onnx)   │  forward(obs)         │
└──────────────────┘            └──────────────────────┘
```

## 차용 우선순위

★★★ — Webots와 함께 1순위 시뮬. macOS 네이티브가 결정적.

## 출처

- MuJoCo: https://mujoco.org/
- GitHub: https://github.com/google-deepmind/mujoco
- Menagerie: https://github.com/google-deepmind/mujoco_menagerie
- Brax: https://github.com/google/brax
- mjx 가이드: https://mujoco.readthedocs.io/en/stable/mjx.html
- mujoco-rs: https://crates.io/crates/mujoco-rs
- urdf2mjcf 도구: https://github.com/balintbo/urdf2mjcf
