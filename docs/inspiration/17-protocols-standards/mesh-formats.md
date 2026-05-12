# Mesh / Animation 포맷 — glTF / FBX / OBJ / STL / DAE

## 빠른 비교

| 포맷 | 출처 | 라이선스 | 우리에게 |
|------|------|----------|----------|
| **glTF 2.0** | Khronos Group | 무료 표준 | ★★ — 웹 / SceneKit / Vision Pro |
| **FBX** | Autodesk | 독점 (binary), 무료 SDK | ★ — Maya/MotionBuilder 호환 |
| **OBJ** | Wavefront | 공개 | ★ — 단순 메시 |
| **STL** | 3D Systems | 공개 | ★★ — DARwIn-OP URDF 메시 출처 |
| **COLLADA (DAE)** | Khronos | 공개 | ★ — 구식 |
| **USD** | Pixar | Apache 2.0 modified | ★★★ — 미래 표준 (별도 [`usd.md`](usd.md)) |
| **glb** | Khronos | 무료 | ★★ — glTF의 binary 변형 |

## DARwIn-OP 메시 출처

`HumaRobotics/darwin_description` (BSD-2):
- URDF가 STL 메시 참조 (각 link별)
- 약 20개 STL 파일 (link, motor housing, foot 등)

## DarwinForge SceneKit 임포트

SceneKit이 직접 지원:
- `.dae` (COLLADA) — 가장 잘 지원
- `.scn` (자체)
- `.obj` (limited)

STL → DAE 변환 필요. Blender CLI 또는 `stl2dae` 도구.

```sh
# 한 번만 실행
for f in app/ui/DarwinForge/Resources/darwin-meshes/*.stl; do
    blender --background --python scripts/stl_to_dae.py -- "$f"
done
```

또는 직접 GLTF로 변환:
```sh
# Blender CLI 한 번에 변환
blender --background --python scripts/convert_meshes.py
```

SceneKit은 GLTF를 직접 못 읽음 → DAE 또는 USDZ로.

## 우리 적용

★★ — SceneKit 통합 (Sprint 8+ 3D pose preview) 시 결정적. STL → DAE/USDZ
변환 스크립트 필요.

## 출처

- glTF 2.0: https://www.khronos.org/gltf/
- FBX SDK: https://aps.autodesk.com/developer/overview/fbx-sdk
- SceneKit 문서: https://developer.apple.com/documentation/scenekit
- HumaRobotics URDF: https://github.com/HumaRobotics/darwin_description
