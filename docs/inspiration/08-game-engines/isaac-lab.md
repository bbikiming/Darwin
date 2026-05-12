# NVIDIA Isaac Lab + Omniverse — RL 학습 1순위

→ 시뮬레이터 측면은 [`../01-simulation/isaac-sim.md`](../01-simulation/isaac-sim.md) 참조.

## 게임 엔진 측면

Isaac Sim은 NVIDIA Omniverse 위에 만들어진다. Omniverse는 Pixar USD 기반
3D collaborative editing platform. 여러 사용자가 하나의 씬을 동시 편집.

### USD (Universal Scene Description)

Pixar에서 시작, 현재 산업 표준. 여러 DCC 도구 (Maya / Houdini / Blender) 가
같은 USD 파일을 읽고 쓸 수 있음.

DarwinForge 매핑:
- DARwIn-OP URDF → USD 변환 → Isaac Sim에서 즉시 시뮬
- `urdf2usd` 도구 (NVIDIA 제공)

### Isaac Sim Composer / Action Graph

Unreal Blueprint 유사한 비주얼 스크립팅. 로봇 동작 시퀀스를 노드로 구성.

## RL 워크플로우

```
URDF (BSD-2)
  ↓ urdf2usd
darwin-op.usd
  ↓ Isaac Lab env (Python gym)
DarwinOpVelocityEnv
  ↓ PPO / SAC training
policy.pt
  ↓ ONNX export
policy.onnx
  ↓ tract Rust 추론
forge-core::walk::RLPolicy.forward(obs)
```

장점: 4096 환경 병렬 → 1시간 학습으로 강건한 walk 정책.
단점: Linux + RTX 머신 필요. macOS DarwinForge는 추론만.

## 우리 차용 우선순위

★★★ — RL 실험 1순위. 다만 학습은 별도 머신.

## 출처

- Isaac Lab: https://isaac-sim.github.io/IsaacLab/
- Omniverse: https://www.nvidia.com/en-us/omniverse/
- USD (Pixar): https://openusd.org/
- urdf2usd: https://docs.omniverse.nvidia.com/extensions/latest/ext_isaacsim/ext_omni_isaac_urdf.html
- tract: https://github.com/sonos/tract
