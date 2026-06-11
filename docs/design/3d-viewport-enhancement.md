# 3D 뷰포트 고도화 — 모델링·조명·환경·로봇공학 오버레이 설계 (3D Viewport Enhancement)

> 2026-06-11 · 코드베이스 전수 탐색(3D 구현 6파일 + 자산/스펙 조사) 기반 설계.
> 대상: Studio · Teach · WalkLab · Motion Studio · Pilot Cockpit 의 5개 3D 화면.
> 본 문서는 구현 세션이 **추가 탐색 없이 Wave 0 부터 착수 가능한 수준**의 자족적 설계를 목표로 한다.
> 각 Wave = 독립 커밋(또는 PR) 단위.

## 0. 결론 요약

현재 3D 뷰는 기능적으론 완성도가 높으나(공용 뷰포트 95% 재사용, idle 최적화, STL 메시 rig)
렌더링 품질과 공학 정보 밀도가 2010년대 초 수준이다. 지배 요인 4가지:

1. **머티리얼**: 전면 Blinn-Phong 단색 — `physicallyBased`/`lightingEnvironment` 사용처 0건.
   STL 이 face normal 그대로라 곡면이 각져 보임.
2. **조명**: 3점 directional/ambient 만 — IBL 부재로 흰 쉘·금속 부품의 형태감이 죽음.
3. **환경**: 5개 화면이 동일한 "어두운 바닥 + 실린더 그리드" — 화면 목적(편집/티칭/계측/무대/조종)별
   시각 컨텍스트 없음.
4. **공학 오버레이 부재**: CoM/지지다각형, 관절 한계, FSR 접지, IMU 수평선 등 로봇공학 핵심 정보가
   3D 공간에 표시되지 않음 — 텔레메트리(`FsrReading`, IMU roll/pitch, `ZMPMonitor.Verdict`,
   `JointID.degreeLimits`)는 이미 전부 존재하므로 시각화만 결선하면 된다.

권장 순서: **W0(분리 리팩토링) → W1(PBR+IBL, 품질의 80%) → W2(화면별 프리셋+셰이더 그리드)
→ W3(공학 오버레이, 핵심 차별화) → W4(디테일+카메라 연출) → W5(성능 검증)**.
W3 은 W0 만 의존하므로 W1/W2 와 병렬 가능.

## 1. 현재 상태 (확인된 코드 앵커)

기준 커밋: `fe8d748` 시점. 모든 경로는 `app/ui/DarwinForge/Sources/DarwinForgeUI/` 기준.

| 파일 | 줄수 | 책임 / 핵심 앵커 |
|---|---|---|
| `Visualization/RobotScene3D.swift` | 1,055 | NSViewRepresentable + `Coordinator`(90행~) + 3점 조명(116/130/140행: key 240 warm·fill 130 cool·ambient 200) + `SCNFloor` reflectivity 0(172행) + 실린더 그리드 `makeGrid()`(308행) + 원점 축 `makeAxes()`(332행) + IMU `tiltNode`(103·188행, v1.11.18.1 wrapper) + 발자취 200-sphere 풀 + 프리미티브 `DarwinOP2Rig`(413행~) + 헤드리스 `renderImage`/`writePNG`(364행~) |
| `Visualization/MeshRig.swift` | 303 | URDF 트리 + STL 로드(`linkColor` 291행 — 링크별 단색 회색), URDF→SceneKit 좌표 변환(root 에 120° axis-angle, 43행) |
| `Visualization/STLLoader.swift` | 162 | binary STL 파서. `parseBinarySTL(data:scale:diffuse:)`(54행)가 geometry + Blinn 머티리얼(140행)을 함께 생성. **face normal 을 vertex 3개에 복제** — smoothing 없음 |
| `Visualization/InteractiveSceneView.swift` | 551 | orbit/pan/zoom, FOV 28°, smoothing 0.32 / inertia 0.88, `isFullyIdle` tick skip(307·331행), frame-adaptive distance, ViewCube 프리셋은 `instant: true` 1프레임 점프(425·466행) |
| `Visualization/ViewCube3D.swift` | 440 | 카메라 프리셋 위젯(자체 조명 key 480/fill 220/ambient 320) |
| `Visualization/Robot3DViewport.swift` | 130 | Studio/Teach/Motion/WalkLab 표준 래퍼 |
| `Visualization/ViewportControls.swift` | 47 | 우상단 ViewCube + Home |
| `Pilot/Cockpit/CockpitChaseSceneView.swift` | 345 | Cockpit 전용 scene(체이스캠 = rigAnchor 자식 + LookAt constraint, 자체 그리드 58노드) |

**자산/데이터 (이미 존재 — 신규 에셋 불필요)**
- STL 21개: `Resources/Meshes/geo_op_*.stl` (Package.swift `.copy` 번들 완료).
  참조용 추가 STL 50+개: `vendor/robotis-op2-common/meshes/`.
- 관절 한계/회전축: `JointID.degreeLimits`/`rotationAxis` — `Sources/ForgeCore/Kinematics.swift:51`,
  관례 문서 `docs/architecture/joint-conventions.md`.
- FSR: `FsrReading` (4-cell + center_x/y, ID 111/112) — `Sources/ForgeCore/Bus.swift`.
  IMU: `WalkLabSession.imuRollDeg/imuPitchDeg` — `WalkLab/WalkLabSession.swift:224`.
- 안정성 판정: `ZMPMonitor` + `Verdict`(safe/borderline/unsafe) —
  `WalkLab/Safety/ZMPMonitor.swift:28·61` (support polygon 로직 기존재).
- 링크 질량: `vendor/robotis-op2-common/` URDF(xacro) inertial 값에서 추출 가능
  (body ≈0.975kg, thigh ≈0.119, shin ≈0.070, foot ≈0.206, head ≈0.158 — 구현 시 xacro 에서 확정).

**불변 성능 계약 (모든 Wave 가 준수)**
- `preferredFramesPerSecond = 30` (v1.14.8), `InteractiveSceneView.isFullyIdle` tick skip (v1.14.8.1).
- footTrace 200-sphere 0-alloc 풀 패턴 — 신규 오버레이도 동일 패턴 의무.
- `wantsHDR = false`, bloom 0, floor reflectivity 0 — 흰 로봇 burn-out 방지 이력(v1.14.8 조명 하향).
- 헤드리스 `SCNRenderer` 스냅샷(`renderImage`/`writePNG`) 항상 동작 — 회귀 금지.
- 신규 코드의 자체 타이머/per-frame 루프 추가 금지(명시 예외: W4 턴테이블, Cockpit 은 원래 연속 렌더).

**프레임워크 결정: SceneKit 유지.** RealityKit 마이그레이션 비권장 — 헤드리스 스냅샷 파이프라인,
커스텀 orbit 카메라, shader modifier 확장이 전부 재작성 대상이고 비-AR 뷰포트 제어가 더 제약적.

## 2. Wave 0 — 분리 리팩토링 (난이도 S · 행동변화 0)

목적: `RobotScene3D.swift`(1,055줄, 800줄 규칙 초과)를 분할해 이후 Wave 의 작업 면적 확보.
**렌더 결과가 픽셀 단위로 동일**해야 한다.

### (a) 변경/신규 파일

| 파일 | 내용 |
|---|---|
| `Visualization/RobotScene3D.swift` (잔존 ~120줄) | NSViewRepresentable + 헤드리스 렌더 extension 만 |
| 신규 `Visualization/Rigs/DarwinOP2Rig.swift` (~640줄) | 413행~ 의 프리미티브 rig + `UInt8.isOnRightHalf` extension 이동 |
| 신규 `Visualization/Scene/RobotSceneCoordinator.swift` (~250줄) | `Coordinator` 를 최상위 클래스로 승격. scene 그래프 소유, pose/trace/tilt 바인딩 |
| 신규 `Visualization/Scene/SceneStage.swift` (~180줄) | 조명 rig 구성 + 바닥 + `makeGrid()` + `makeAxes()` 이동. **조명/노출 수치는 전부 이 파일의 상수로 집결** (W1 튜닝 루프 대비) |

### (b) 호환성

- `Coordinator` 는 `public` 이고 `renderImage` 가 직접 생성하므로
  `public typealias Coordinator = RobotSceneCoordinator` 로 소스 호환 유지.
- import/접근제어 외 로직 수정 0.

### (d) 검증

```sh
# 리팩토링 전 기준 스냅샷 → 후 스냅샷 → diff
swift build --package-path app/ui/DarwinForge
# RobotScene3D.writePNG(pose: .walkReady, …) 를 호출하는 기존/임시 테스트로 PNG 2장 생성 후
# 픽셀 diff 0 (또는 MSE < 1e-6) 확인. swift test 전체 통과(serial — --parallel 금지).
```

### (e) 리스크: 낮음
유일한 함정은 public API 표면(`Coordinator` 직접 참조) — typealias 로 해소.

## 3. Wave 1 — PBR 머티리얼 + Normal Smoothing + IBL (난이도 L · 단일 커밋)

PBR 은 `lightingEnvironment` 없이는 금속이 검게 죽고 IBL 은 Blinn 에 영향이 없으므로
**1-A~1-D 는 반드시 한 커밋으로 동시 전환**한다. 시각 품질 개선의 80%가 이 Wave 에서 결정된다.

### 1-A. 절차적 IBL (에셋 0)

신규 `Visualization/Scene/ProceduralEnvironmentMap.swift` (~150줄)

- 책임: **128×64 equirectangular 그라디언트 CGImage 를 코드 생성** (HDR 에셋 번들 불필요.
  8bit RGBA 로 충분 — 헤드룸이 더 필요하면 Float16 raw buffer → CGImage).
- 기본(studio) 무드 구성:
  - 천정(θ=0): RGB (0.95, 0.97, 1.00) × 휘도 1.15
  - 수평선(θ=π/2): (0.52, 0.55, 0.60)
  - 바닥(θ=π): (0.16, 0.16, 0.18)
  - **소프트박스 가우시안 패치 2개** — key 방향(azimuth 좌상 45°, elevation 50°)에 휘도 2.5,
    σ≈12° 사각 패치 / fill 방향에 휘도 1.4 패치 1개.
    이 패치가 금속·clearcoat 하이라이트의 형태감을 만들며, 절차적 IBL 이 번들 HDR 대비
    밋밋해지는 약점을 상쇄한다.
- API: `static func make(spec: SceneEnvironmentSpec) -> CGImage` (W2 에서 preset 별 tint 소비).
- 적용: `scene.lightingEnvironment.contents = image`, `intensity = 1.0`(화면별 0.55–1.0 은 W2).
- `scene.background` 는 **clear 유지** — SwiftUI `LinearGradient(DFColor.scene3DTop/Bottom)` 배경
  패턴 보존. lightingEnvironment 와 background 는 독립이므로 충돌 없음.
- 생성물은 preset 별 1회 생성 후 static 캐시.

### 1-B. 조명 재설계 (PBR 광량 기준)

`SceneStage.swift` 상수 변경 — PBR 에서 Blinn 시절 강도는 의미가 달라지므로 재튜닝:

| 라이트 | 종전 (Blinn) | 신규 (PBR) | 비고 |
|---|---|---|---|
| Key directional | 240, warm (1.0, 0.98, 0.95) | **550**, 색 유지, castsShadow 유지 | IBL 이 base 를 깔아주므로 과도 금지 |
| Fill directional | 130, cool | **삭제** | IBL 소프트박스 패치가 대체. 노드 -1 |
| Ambient | 200 | **삭제** | PBR + ambient 병행은 워시아웃 원인. IBL 이 대체 |
| Rim directional | 없음 | **신규 180**, (0.85, 0.90, 1.0), 위치 (0, 2.0, 2.2) → look at (0, 0.3, 0), castsShadow=false | 흰 쉘 윤곽을 배경에서 분리 |

그림자: `shadowMode = .deferred` 유지, `shadowMapSize = CGSize(width: 1024, height: 1024)` 명시
고정, `shadowRadius 4 → 7`, `shadowSampleCount 12 → 8`(radius 증가분 상쇄),
`shadowColor = NSColor(white: 0, alpha: 0.5)`.

**burn-out 가드 (필수)**
- 흰 쉘 diffuse 0.82 초과 금지(1-C), `wantsHDR = false` 유지.
- 신규 테스트 `Tests/DarwinForgeUITests/SceneExposureTests.swift`:
  헤드리스 렌더(walkReady 정면) 후 **휘도 ≥ 250 픽셀 비율 < 1.5% assert** (LED emission 영역 감안).
  이 테스트가 이후 모든 조명 튜닝의 안전망이자 CI 상시 가드.

### 1-C. 부위별 PBR 머티리얼

신규 `Visualization/Rigs/RigMaterials.swift` (~160줄) — 부위 카테고리 → `SCNMaterial` 팩토리.

| 카테고리 | 대상 | diffuse | metalness | roughness | 기타 |
|---|---|---|---|---|---|
| `whiteShell` | body, thigh, shin, upper-arm (+프리미티브 bodyShell) | (0.80, 0.80, 0.82) | 0.0 | 0.42 | clearcoat 0.25/clearcoatRoughness 0.5 — **옵션 플래그, 기본 off** (비용+번아웃 변수) |
| `servoBlack` | lower-arm, 모터 본체 | (0.11, 0.11, 0.12) | 0.0 | 0.55 | 새틴. roughness 0.6 초과 금지(스펙큘러 사멸) |
| `aluminum` | shoulder, hip-yaw, hip-roll, ankle, neck | (0.62, 0.63, 0.65) | **0.85** | 0.35 | metalness 1.0 금지 — 128×64 IBL 해상도에서 순금속은 얼룩짐 |
| `rubberFoot` | foot | (0.08, 0.08, 0.08) | 0.0 | 0.90 | 무광 고무 |
| `helmetDark` | head | (0.16, 0.17, 0.19) | 0.0 | 0.30 | 살짝 글로시한 헬멧 |
| `emissiveLED` | 눈/로고/정수리 LED | 기존 `.constant` + emission **유지** | — | — | PBR 전환 제외 |

배선 변경:
- `MeshRig.swift` 291행 `linkColor(for:name:)` → `RigMaterials.material(forLinkNamed:)` 교체
  (링크명 매칭 로직은 기존 패턴 재사용).
- `STLLoader.parseBinarySTL` 의 머티리얼 생성부(140행 부근) 제거 — **geometry 만 반환**하고
  머티리얼은 호출자가 주입(시그니처에서 `diffuse:` 제거).
- `DarwinOP2Rig` 의 `makeBox`/`darkMat`/`lightCapMat` 류도 RigMaterials 경유로 교체.
- **highlight 충돌 주의**: 머티리얼을 카테고리당 공유 인스턴스로 만들면 `emission` 변경이
  전 부위에 전파된다. 메시가 21개뿐이라 배칭 이득이 작으므로 **메시별 개별 머티리얼 유지**
  (RigMaterials 는 prototype 을 `copy()` 해 반환). 기존 `originalEmissions` 캐시 로직 그대로 동작.

### 1-D. STL Normal Smoothing

신규 `Visualization/STLNormalSmoother.swift` (~180줄), `STLLoader.swift` 수정.

crease-angle 방식:
1. vertex 위치를 **1e-5 m 격자로 양자화** → `[QuantizedPos: [faceIndex]]` 해시 (O(n)).
2. 각 vertex 에 대해 같은 위치를 공유하는 face normal 중 **자기 face normal 과의 각도가
   crease angle 이하인 것만 평균**(면적 가중이 이상적이나 단순 평균 허용).
3. crease angle 기본 **35°** — 서보 하우징 직각 모서리는 hard 유지, 쉘 곡면은 smooth.
4. **뒤집힌 face normal 방어**: 인접 평균과 내적 < 0 이면 flip 후 평균 (STL 품질 편차 대비).

- vertex dedup(인덱스 공유)은 **하지 않음** — per-face-vertex 레이아웃 유지, normal 배열만 교체.
  (메시 총합 수 MB·1회 로드라 메모리 이득보다 단순성 우선.)
- 적용 위치: `parseBinarySTL` 에서 `SCNGeometrySource` 생성 직전
  `STLNormalSmoother.smooth(positions:normals:creaseAngleDeg: 35)` 호출.
  로드 시간 증가 예상 < 50ms / 21메시 (1회성).
- `isDoubleSided = true` 는 유지.

### 1-E. Cockpit 동시 보정

`CockpitChaseSceneView.swift` 도 동일 MeshRig 를 쓰므로 같은 커밋에서 조명 보정:
key 420→**700**, ambient 240→**삭제** + IBL(teal tint, intensity 0.6) 적용.

### (d) Wave 1 검증

- 헤드리스 스냅샷 4종(walkReady 정면/측면/등/머리 클로즈업) `writePNG` 생성 → 육안 비교 기록.
- `SceneExposureTests` 휘도 클리핑 assert (위 1-B).
- 신규 `STLNormalSmootherTests`: ① 코드 생성 단위 정육면체 STL → 모서리 normal 이 face normal
  유지(90° > 35°) ② 구 근사 메시 → 인접 normal 연속성 확인.
- Cockpit 실행 화면 육안 확인 (`bash scripts/run-app.sh`).

### (e) 리스크: 중상

최대 리스크는 **노출 밸런스 재튜닝 루프** — 완화책: 수치를 `SceneStage` 상수로 집결(W0에서 완료)
+ 스냅샷 테스트를 튜닝 도구로 사용. aluminum 이 IBL 해상도 한계로 얼룩지면
roughness +0.1 또는 metalness 0.7 로 후퇴.

## 4. Wave 2 — 화면별 환경 프리셋 + 셰이더 그리드 (난이도 M)

### 2-A. `ScenePreset` 추상화

신규 `Visualization/Scene/SceneEnvironment.swift` (~220줄)

```swift
public enum ScenePreset: String, Sendable { case studio, teach, walkLab, motion, cockpit }

public struct SceneEnvironmentSpec {        // preset별 정적 테이블 (값 타입)
    var iblTint: (zenith: NSColor, horizon: NSColor, ground: NSColor)
    var iblIntensity: CGFloat
    var keyIntensity: CGFloat; var keyColor: NSColor
    var rimIntensity: CGFloat
    var floorAlbedo: NSColor; var floorRoughness: CGFloat
    var grid: GridStyle          // minor/major 간격, 색, fade 거리, 마킹
    var props: [PropKind]        // .originAxes, .distanceMarks, .startLine, .workMat, .stageSpot
}
```

주입 구조: `RobotScene3D.init(..., preset: ScenePreset = .studio)` → `Robot3DViewport` 동일
파라미터 추가 → 각 화면 호출부 1줄 수정(`StudioView.swift`, `Teach/TeachModeView.swift`,
`WalkLab/WalkLabSceneSection.swift`, `Motion/MotionStudioCanvas.swift`).
`RobotSceneCoordinator.init(preset:)` 이 `SceneStage.build(spec:)` 호출.
preset 의 런타임 변경은 **지원하지 않음**(화면당 고정 — 코디네이터 재생성 비용 회피).

**화면별 스펙 초기값**

| | Studio | Teach | WalkLab | Motion | Cockpit |
|---|---|---|---|---|---|
| 무드 | 중성 엔지니어링 스튜디오 | 따뜻한 워크벤치 | 계측 랩 (쿨톤) | 무대 (어둡고 콘트라스트) | FPV 그리드 호라이즌 (기존 teal 계승) |
| IBL intensity | 1.0 | 1.0 | 0.9 | 0.7 | 0.55 |
| IBL horizon tint | (0.52, 0.55, 0.60) | (0.60, 0.55, 0.48) warm | (0.48, 0.55, 0.62) | (0.35, 0.35, 0.42) | (0.10, 0.22, 0.26) teal |
| Key | 550 warm white | 520 warm (3600K 느낌) | 560 neutral (5500K) | 650 (spot 성) | 420 cool |
| 바닥 albedo / rough | 0.10 / 0.85 | 0.13 warm gray / 0.90 | 0.09 / 0.80 | 0.05 / 0.95 | 0.04 dark teal / 0.90 |
| 그리드 | minor 0.1m / major 0.5m, 회색 0.30 | major 0.25m 만, 옅게 | minor 0.1 / major 0.5 + **진행축 0.5m 거리마킹** + 출발선 | major 1m 만, 알파 0.15 | major 0.5m emissive teal, fade 12m |
| props | originAxes | workMat (0.6×0.6m 라운드 테두리) | distanceMarks, startLine, originAxes | stageSpot | 없음 (호라이즌만) |

- WalkLab 거리마킹 숫자(0.5m–4.0m, 8개): **`SCNText` 금지**(폴리곤 비용·alloc 큼) —
  `NSImage` lockFocus 로 1회 사전 렌더한 텍스트 텍스처를 입힌 plane 8개.
- Motion `stageSpot`: `SCNLight.type = .spot`, intensity 300, inner 25°/outer 50°,
  위치 (0, 2.5, 0.5), **castsShadow = false** — 그림자 패스는 key 1개만 유지.

### 2-B. 안티앨리어싱 그리드 셰이더 (실린더 그리드 대체)

신규 `Visualization/Scene/GridFloorMaterial.swift` (~140줄)

- `SCNFloor` 머티리얼에 **fragment shader modifier** 적용 — "pristine grid" 기법:

```metal
// shaderModifiers[.surface] 개략 (구현 시 Metal 문법 정확화)
#pragma arguments
float minorStep; float majorStep; float4 lineColor; float fadeDistance; float lineWidthPx;
#pragma body
float2 p = /* world-space xz */;
float2 wMinor = fwidth(p / minorStep);
float2 gMinor = abs(fract(p / minorStep - 0.5) - 0.5) / wMinor;   // 픽셀폭 정규화
float minorLine = 1.0 - saturate(min(gMinor.x, gMinor.y) / lineWidthPx);
// major 동일 계산 후 max(), 카메라 거리 fade: saturate(1 - dist / fadeDistance)
_surface.diffuse.rgb = mix(_surface.diffuse.rgb, lineColor.rgb, line * fade);
```

- **world xz 좌표 수급이 유일한 기술 리스크**: SCNFloor 는 무한 평면이라 texcoord 가 불안정 —
  geometry modifier 에서 world position 을 varying 으로 넘기는 방식이 안전.
  **실패 시 폴백(권장 경로)**: SCNFloor → 40×40m `SCNPlane` 으로 교체하면 texcoord 기반으로
  단순화되며 zFar 60 안에서 시각 차이 없음.
- 기존 실린더 그리드 `makeGrid()`(36노드)는 `legacyGrid()` 로 보존하고 상수 플래그로 전환
  가능하게 유지. Cockpit 자체 그리드(58노드 emissive)도 동일 머티리얼의 teal 파라미터로 교체.
- 효과: draw call 약 -36(-58 Cockpit), 거리 무관 일정 픽셀폭 라인(모아레/시머링 감소 —
  fwidth AA + MSAA4X 결합).

### (d) 검증

- preset 5종 × 대표 포즈 스냅샷 5장 생성·기록.
- 그리드 모아레: 실기 orbit 으로 육안 확인.
- idle CPU: 셰이더는 GPU 상주라 idle tick skip 과 무관함을 Instruments 로 확인.

### (e) 리스크: 중 (그리드 world 좌표 1건, 폴백 경로 확보됨)

## 5. Wave 3 — 로봇공학 오버레이 (난이도 L · 핵심 차별화 · W0 만 의존)

### 구조

신규 디렉터리 `Visualization/Overlays/`:

| 파일 | 책임 |
|---|---|
| `RobotOverlaySet.swift` (~80줄) | `OptionSet`: `.com, .supportPolygon, .jointAxis, .footContact, .horizon, .trajectory, .limitWarning` + preset 별 기본값 테이블 |
| `RobotOverlayLayer.swift` (~250줄) | 모든 오버레이 노드 풀 소유. `RobotSceneCoordinator` 가 1개 보유. **`applyPose` 와 같은 호출 경로에서만 `update(pose:rig:data:)` 갱신 — 자체 타이머 금지** (idle 계약 유지) |
| `CoMSupportOverlay.swift` (~200줄) | 3-A |
| `JointAxisOverlay.swift` (~180줄) | 3-B |
| `FootContactOverlay.swift` (~150줄) | 3-C |
| `HorizonOverlay.swift` (~120줄) | 3-D |
| `TrajectoryOverlay.swift` (~140줄) | 3-E |

- 데이터 주입: `RobotScene3D` 에 `overlayData: SceneOverlayData?` 파라미터 추가.
  `struct SceneOverlayData { var fsrLeft, fsrRight: FsrReading?; var comOverride: SIMD3<Double>?;
  var zmpVerdict: ZMPMonitor.Verdict? }` — WalkLab 은 `WalkLabSession` 텔레메트리에서 채움.
- **선행 커밋(필수)**: rig 추상화 `protocol RigSkeleton { func linkWorldPosition(_:) -> SCNVector3;
  func jointAnchor(_:) -> SCNNode? }` 를 `MeshRig`/`DarwinOP2Rig` 양쪽에 채택 —
  프리미티브 폴백 환경에서의 크래시 방지. (MeshRig 의 `jointAxes` 를 `private(set)` 노출, 1줄.)

### 3-A. CoM 투영점 + 지지 다각형

- CoM: URDF inertial 질량 상수 테이블 × `RigSkeleton.linkWorldPosition` 가중 평균.
- 시각화:
  - 바닥 투영 disc(반경 0.012m, cyan emission, `.constant`)
  - CoM 본체 → 투영점 수직 점선(plane + dash 텍스처 1장)
  - 지지 다각형: 양발 `worldTransform` × 발 사각형 4코너(**0.104×0.066m — `ZMPMonitor` padding
    상수와 정합 확인**) 8점 → convex hull(Andrew monotone chain, 8점이라 trivial) →
    `SCNGeometryElement(.line)` 폐곡선 + 반투명 fill plane.
- 색 = `ZMPMonitor.Verdict`: safe=systemGreen / borderline=systemYellow / unsafe·veto=systemRed.
  WalkLab 은 세션 lastVerdict 주입, Teach 는 ZMPMonitor 를 observe 모드로 재사용해 자체 계산.
- 풀: 노드 4개 고정(disc/점선/hull line/fill). line geometry 재생성은 pose 변경 시(≤10Hz)만 —
  8점 hull 이라 alloc 미미. 거슬리면 8세그먼트 고정 실린더 풀로 대체(2차 최적화).

### 3-B. 관절 축 + 한계각 아크

- 트리거: 기존 `highlight: JointID?` 와 동기 — 선택 관절에만 표시.
- 구성:
  1. 회전축 양방향 화살표 — 길이 0.09m, 반경 0.0025 실린더 + cone 팁.
     색: pitch=green / roll=red / yaw=blue (RViz 관례).
  2. 한계각 아크 — `JointID.degreeLimits` 를 반경 0.045m 아크(`SCNShape` 베지어 + extrude 0.002,
     알파 0.35)로.
  3. 현재각 마커(아크 위 작은 sphere) — 한계 85% 초과 시 아크 amber, 95% 초과 시 red.
- 좌표: joint 회전을 따라가지 않도록 **anchor 의 부모(frame) 쪽**에 attach, 축 방향은
  `jointAxes[j]` 사용.
- 풀: 화살표/아크 1세트만 — 관절 변경 시 reparent + geometry 갱신.

### 3-C. 발 접지 인디케이터 (FSR)

- 데이터: `FsrReading`(cell 4 + CoP). 미연결/시뮬 시 **sole worldPosition.y < 0.005m 휴리스틱**.
- 시각화: 발당 2×2 압력 quad(압력 → 알파 0→0.7, orange emission) + 접지 중 발 둘레
  ring(반경 0.07m, 알파 0.5) + CoP cyan dot.
- 풀: 발당 6노드 × 2 = 12 고정, `isHidden` 토글.

### 3-D. IMU 수평선 (3D artificial horizon)

- 허리 높이 y=0.30 에 반경 0.45m 수평 ring(토러스 r=0.002, 알파 0.4) + 전방 방위 tick 4개.
- **`tiltNode` 바깥(scene root)에 부착** — 로봇이 기울면 ring 대비 기울기가 즉시 읽힘.
  수치 표기는 기존 SwiftUI HUD 담당(3D 는 기하만).
- Cockpit: 동일 ring 을 rigAnchor 위치 추종(높이 고정)으로 — 체이스 뷰의 호라이즌 게이지.

### 3-E. 엔드이펙터 궤적

- footTrace 200-풀 패턴 일반화: 트랙당 160 풀, **최소 이동 4mm 이상일 때만 push**(정지 누적 방지),
  0-alloc 갱신.
- Motion 키프레임 재생 시 손끝 L/R 트랙 활성. WalkLab 은 기존 footTrace 유지(중복 회피).

### 3-F. 관절 한계 근접 경고

- `applyPose` 경로에서 20관절 `pose.radians(j)` vs `degreeLimits` 비율 비교(비용 무시 가능).
  ≥85% amber / ≥95% red 를 해당 링크 mesh emission tint 로.
- **emission 채널 충돌 해결이 설계 포인트**: highlight(orange 0.55)와 같은 채널 —
  `MeshRig` 에 단일 진입점 `setEmissionState(joint:state:)` 신설
  (`enum EmissionState { none, highlight, warn85, warn95 }`, 우선순위 warn95 > warn85 > highlight).
  기존 `highlight()` 는 내부적으로 이를 경유, `originalEmissions` 캐시 재사용.

### 기본 on/off 매트릭스 + 토글 UI

| 오버레이 | Studio | Teach | WalkLab | Motion | Cockpit |
|---|:-:|:-:|:-:|:-:|:-:|
| CoM + 지지다각형 | – | ✓ | ✓ | – | – |
| 관절 축 + 한계 아크 | ✓(선택 관절) | ✓(선택 관절) | – | ✓(선택 관절) | – |
| FSR 접지 | – | ✓ | ✓ | – | ✓ |
| IMU 수평선 | – | – | ✓ | – | ✓ |
| EE 궤적 | – | – | (기존 footTrace) | ✓ | – |
| 한계 근접 경고 | ✓ | ✓ | ✓ | ✓ | – |

토글 UI: `ViewportControls.swift` 에 오버레이 팝오버(체크박스 목록) 추가 —
`@Published var overlays: RobotOverlaySet` 경량 store, preset 기본값에서 시작.

### (d) 검증

- 오버레이별 헤드리스 스냅샷 — 특히 한계각 아크는 min/max/중앙 3포즈.
- 지지 다각형 좌표가 `ZMPMonitor` 기존 단위테스트와 정합하는 테스트 신설.
- WalkLab 60초 구동 → Instruments Allocations 그래프 평탄 확인(풀링 검증).

### (e) 리스크: 중
최대 리스크는 rig 추상화 누락으로 프리미티브 폴백에서 크래시 — `RigSkeleton` 선행 커밋으로 차단.

## 6. Wave 4 — 모델 디테일 + 카메라 연출 (난이도 M · 독립)

### 4-A. MeshRig 머리 디테일 (S)

- 프리미티브 rig 에만 있는 보라 LED 눈(디스크 2, 반경 0.012, emission 0.85)/이마 카메라
  실린더/정수리 녹색 LED 를 MeshRig 의 head_tilt anchor 에 이식 — 헬퍼 `attachHeadDetails(to:)`
  (~60줄, `MeshRig.swift`).
- STL head 는 URDF frame 기준이라 프리미티브 좌표 직접 이식 불가 —
  초기값 (±0.021, 0.015, 0.048) 부근에서 스냅샷 반복 튜닝으로 확정.

### 4-B. 부드러운 프리셋 전환 + 턴테이블 (M)

`InteractiveSceneView.swift`:
- ViewCube `goToFace`/`resetCamera` 의 `instant: true`(425·466행) → ease 전환.
  전환용 smoothing 별도 상수 0.18(기존 0.32보다 느긋), 도달 epsilon 시 플래그 해제.
  **azimuth 최단경로 보정 필수**: `desired = current + shortestAngleDelta(current, target)` —
  현재 절대값 대입이라 2π 가까이 도는 케이스 존재.
  "버튼=즉시" 과거 사용자 요청 이력 고려 **전환 ≤ 0.4s** 튜닝 + `instant` 1줄 롤백 가능 유지.
- 턴테이블: `public var turntableRadPerSec: CGFloat = 0` — tick 에서 `desiredAzimuth += rate/60`.
  **`isFullyIdle`(307행) 조건에 `turntableRadPerSec != 0` 추가 필수** — idle skip 과 충돌.
  ViewportControls 토글, 기본 off (idle CPU 계약 예외는 "사용자가 켰을 때만").

### 4-C. DOF 시네마틱 토글 (S · 옵트인)

- `SCNCamera.wantsDepthOfField = true`, `focusDistance = 카메라-타깃 거리`(tick 갱신),
  `fStop = 5.6`, `apertureBladeCount = 6`.
- Studio/Motion 의 "시네마틱" 토글에서만, 기본 off. **스냅샷 renderer 에는 미적용**(테스트 결정성).

### 4-D. Cockpit 체이스캠 lag/lean (M)

`CockpitChaseSceneView.swift`:
1. 카메라를 rigAnchor 자식 → **scene root 직속**으로 이동.
   `SCNSceneRendererDelegate.renderer(_:updateAtTime:)`(Cockpit 은 원래 연속 30fps 렌더라 신규
   부하 아님)에서 rigAnchor 후방 오프셋을 **위치 lerp 0.12 / heading lerp 0.08** 로 추적.
2. 속도 추정(전회 position 차분)으로 **lean**: 전진 속도 비례 카메라 pitch 다운 최대 2.5°
   + FOV 50→54 킥(0.3m/s 에서 최대).
3. 기존 zoom 로직(min 0.6/max 4.0, x=0/y=0.95 invariant)은 desired distance 변수로 흡수.
   LookAt constraint 는 유지.

### (d) 검증
- `shortestAngleDelta` 수학 단위테스트. 체이스캠은 시뮬 헤딩 스윕 입력으로 lag 수렴 테스트.
- 4-A 는 클로즈업 스냅샷, 4-C 는 토글 on/off 스냅샷 비교.

## 7. Wave 5 — 성능 가드 통합 검증 (난이도 S · 커밋 = 테스트/문서)

| 항목 | 가드 | 측정 |
|---|---|---|
| IBL | 128×64 고정(수십 KB), preset 당 1회 생성·캐시 | 로드 시간 로그 |
| Shadow | 1024 map × key 1개만 (spot/rim castsShadow=false) | GPU frame time (Xcode FPS gauge) |
| 그리드 | 셰이더 1패스, 노드 -36 (Cockpit -58) | draw call 수 (Xcode scene 디버거) |
| 오버레이 | 전 노드 풀링, pose 변경 시만 갱신, 자체 타이머 0 | Instruments Allocations 평탄성 |
| idle 계약 | 신규 tick 루프 금지(턴테이블만 명시 예외), `isFullyIdle` 조건 갱신 | idle CPU % 전후 비교 (v1.14.8 기준선) |
| snapshot | `renderImage(pose:preset:overlays:)` 시그니처 확장, shader modifier/IBL 의 SCNRenderer 동작 확인 | 기존 `writePNG` 회귀 + preset 5종 |
| burn-out | `SceneExposureTests` CI 상시화 | 휘도 클리핑 비율 assert |

산출물: preset 5종 × 대표 포즈 스냅샷 기준선(`docs/reports/` 또는 테스트 fixture) + 본 문서에
실측치 업데이트.

## 8. 의존 관계 · 권장 순서

```
W0 (분리)  ──▶  W1 (PBR+IBL)  ──▶  W2 (프리셋+그리드)  ──▶  W5 (검증)
   │                                                          ▲
   └─────▶  W3 (오버레이, W1/W2와 병렬 가능) ─────────────────┤
W4 (디테일+카메라) — 독립, 아무 때나 ─────────────────────────┘
```

권장: W0 → W1 → W2 → W3 → W4 → W5. 커밋 스코프는 `ui` 또는 `visualization`
(예: `feat(ui): Wave 1 — PBR 머티리얼 + 절차적 IBL + STL normal smoothing`).

## 9. 구현 세션 착수 가이드

```sh
make doctor                                   # 도구 확인
bash scripts/build-mac.sh --swift             # Rust vendor + swift build
swift test --package-path app/ui/DarwinForge  # 반드시 serial (--parallel 금지: UserDefaults 공유)
bash scripts/run-app.sh                       # 실행 확인 (mic/TCC 기능은 .app 번들 필수)
```

- 스냅샷 diff 절차: 변경 전 `RobotScene3D.writePNG(pose:to:)` 로 기준 PNG 생성 → 변경 후 재생성 →
  `compare`(ImageMagick) 또는 픽셀 루프 테스트로 diff. W0 은 diff 0 이 합격 기준.
- 조명/노출 수치는 모두 `SceneStage.swift` 상수 — 튜닝은 이 파일만 만지고 `SceneExposureTests` 로 가드.
- 새 파일은 전부 800줄 미만 유지(이 설계의 분할 기준이 그 한도 내).
- CI: macos-14 `latest-stable` Xcode — Sendable/MainActor 패턴 주의(기존 ci.yml 참조).
