# Nintendo Switch v1 Darwin GLB 렌더링 성능 검토

작성일: 2026-06-05
대상: Nintendo Switch 초기 모델(v1/Erista, Switchroot L4T Ubuntu 예정) + `tools/switch-pilot/web/assets/darwin.glb`
상태: 실 Switch 미검증. 로컬 GLB 파싱 + 공개 하드웨어 자료 기반 정량 추정.

---

## 1. 결론

현재 번들에 들어간 `darwin.glb`는 **Switch v1 성능상 충분히 렌더링 가능한 수준**이다.

냉정하게 말하면 병목은 GLB 폴리곤 수가 아니다. 병목 후보는 다음 순서다.

1. Switchroot 브라우저의 WebGL/import-map 호환성
2. WebGL과 MJPEG 카메라 스트림을 동시에 돌릴 때의 브라우저/GPU/메모리 안정성
3. 장시간 kiosk 운용 중 브라우저 메모리 증가
4. 모델 자체의 시각 품질: 현재 GLB는 POSITION + INDICES만 있고 NORMAL/TEXTURE가 없다

따라서 권장 운영 정책은 다음이다.

- **카메라 꺼짐 / 연결 전 fallback:** WebGL Darwin GLB 30fps 가능성이 높다.
- **카메라 라이브:** 현재 코드처럼 WebGL을 pause하고 MJPEG만 우선해야 한다.
- **목표 fps:** Switch 실기 전까지 60fps가 아니라 **30fps cap**이 맞다.
- **안전 fallback:** WebGL 실패 시 CSS robot figure가 반드시 보여야 한다.

---

## 2. 로컬 GLB 실측값

분석 대상:

```text
tools/switch-pilot/web/assets/darwin.glb
```

파싱 결과:

| 항목 | 값 |
|---|---:|
| 파일 크기 | 562,972 bytes, 약 550KB |
| glTF 버전 | 2.0 binary GLB |
| JSON chunk | 18,012 bytes |
| BIN chunk | 544,932 bytes |
| scene | 1 |
| node | 60 |
| mesh | 21 |
| material | 6 |
| primitive/draw-call 후보 | 21 |
| texture/image | 0 |
| vertex attribute | POSITION only |
| vertex 수 합계 | 15,123 |
| triangle 수 추정 | 30,288 |
| index buffer | 363,456 bytes |
| position buffer | 181,476 bytes |
| bounding box | 약 126 × 157 × 239 units |

중요한 해석:

- **30k triangles**는 2026년 기준으로는 매우 작은 실시간 3D 모델이다.
- texture가 없어서 VRAM/메모리 부담이 거의 없다.
- primitive 21개는 draw call 21개 수준이므로 Three.js/browser에서도 부담이 낮다.
- 다만 NORMAL이 없으므로 조명 품질이 기대보다 밋밋하거나 이상할 수 있다. 필요하면 offline bake 단계에서 vertex normal을 추가하는 것이 좋다. 그래도 모델 크기는 대략 +180KB 수준이라 성능 부담은 여전히 낮다.

---

## 3. Switch v1 하드웨어 기준

Nintendo 공식 스펙은 Switch 콘솔의 내장 화면이 6.2인치 1280×720이고, CPU/GPU는 NVIDIA Custom Tegra라고만 공개한다. Nintendo 공식 페이지 기준으로 TV mode는 최대 1080p, handheld/tabletop은 최대 720p다.

NVIDIA Tegra X1 공식 whitepaper 기준:

- Maxwell GPU
- 256 CUDA cores
- FP32 peak 512 GFLOPS
- FP16 peak 1024 GFLOPS
- 16 texture units
- 16 ROPs
- LPDDR4-1600 64-bit, 25.6 GB/s
- memory size up to 4GB
- OpenGL ES 3.1 / OpenGL 4.5 / CUDA 6.0 지원

초기 Switch의 실제 휴대 모드 GPU 클럭은 공개 개발자 자료 기반 보도에서 307.2MHz로 알려져 있다. 이 값은 NVIDIA X1 1GHz 기준의 약 30.7%다. 따라서 보수적으로 단순 선형 환산하면:

```text
Tegra X1 FP32 peak at 1GHz: 512 GFLOPS
Switch handheld 307.2MHz estimate: 512 × 0.3072 = 약 157 GFLOPS
Switch docked 768MHz estimate: 512 × 0.768 = 약 393 GFLOPS
```

실제 브라우저/WebGL에서는 드라이버, compositor, JavaScript, thermal, governor 때문에 이론값을 그대로 쓰면 안 된다. 그래도 이 GLB는 이론 성능 대비 너무 작다.

---

## 4. 렌더링 부하 계산

### 4-1. Geometry throughput

현재 GLB:

```text
30,288 triangles / frame
```

목표 fps별 처리량:

| 목표 | triangles/sec |
|---|---:|
| 30fps | 908,640 triangles/sec |
| 60fps | 1,817,280 triangles/sec |

판단:

- 1.8M triangles/sec는 Tegra X1급 GPU에는 매우 낮은 수치다.
- 브라우저 오버헤드를 10배로 과장해도 18M triangles/sec 수준이다.
- 모델만 놓고 보면 30fps는 충분, 60fps도 가능성이 있다.
- 그러나 조종석은 안정성이 더 중요하므로 30fps cap이 맞다.

### 4-2. Pixel/framebuffer throughput

Switch 내장 화면:

```text
1280 × 720 = 921,600 pixels/frame
```

전체 화면을 전부 WebGL로 칠한다고 가정한 최악값:

| 목표 | pixels/sec |
|---|---:|
| 30fps | 27.65 Mpixels/sec |
| 60fps | 55.30 Mpixels/sec |

RGBA color buffer + depth buffer를 단순 계산하면:

```text
color 1280×720×4 bytes = 3.52 MiB
depth 1280×720×4 bytes = 3.52 MiB
color+depth/frame ≈ 7.03 MiB
30fps ≈ 211 MiB/s
60fps ≈ 422 MiB/s
```

NVIDIA X1 whitepaper의 memory bandwidth 25.6GB/s와 비교하면, 단순 framebuffer 대역폭은 매우 낮다. 실제 브라우저 compositor와 UI layer를 감안해도 모델 렌더링 자체가 메모리 대역폭 병목이 될 가능성은 낮다.

### 4-3. Asset load / memory

런타임 주요 asset:

| 파일 | 크기 |
|---|---:|
| `darwin.glb` | 약 550KB |
| `three.module.min.js` | 약 655KB |
| `GLTFLoader.js` | 약 106KB |

대략적인 런타임 메모리:

- GLB vertex/index buffer: 약 0.55MB raw
- normals를 추가해도 약 +0.18MB
- WebGL framebuffer/backbuffer/depth: 10-30MB 범위 추정
- Three.js object/JS overhead: 수 MB에서 수십 MB 가능

Switch v1의 4GB RAM 환경에서 이 모델 하나는 메모리 병목이 아니다. 문제는 MJPEG 카메라, 브라우저 프로세스, 장시간 누수, 데스크톱/kiosk 세션과 합산될 때다.

---

## 5. 위험 평가

| 항목 | 위험도 | 판단 |
|---|---:|---|
| GLB geometry 수 | 낮음 | 30k triangles는 충분히 작다 |
| GLB 파일 크기 | 낮음 | 550KB, 로컬 asset |
| texture/VRAM | 낮음 | texture/image 없음 |
| draw call | 낮음-중간 | 21개는 문제 없어 보이나 browser/driver에 따라 확인 필요 |
| WebGL/Three.js 브라우저 호환성 | 중간 | Switchroot browser에서 import map/WebGL2/driver 상태 확인 필요 |
| MJPEG 카메라와 동시 구동 | 중간-높음 | WebGL + MJPEG 동시 구동은 피해야 함 |
| 장시간 kiosk 안정성 | 중간 | 10-30분 이상 실기 soak test 필요 |
| 모델 시각 품질 | 중간 | NORMAL 없음. 성능보다 조명/표현 문제가 더 큼 |

---

## 6. 적용 권장

현재 코드 방향은 맞다.

`tools/switch-pilot/web/robot3d.js`는 이미 30fps cap을 사용한다.

```javascript
const FRAME_MS = 1000 / 30;
```

그리고 `tools/switch-pilot/web/app.js`는 카메라 라이브 상태에서 3D를 끄는 정책을 갖고 있다.

```javascript
if (window.__darwinRobot3D) window.__darwinRobot3D.setActive(cameraLevel !== "camera-live");
```

이 정책은 유지해야 한다.

추가 권장:

1. import map이 없는 브라우저에서도 깨지지 않도록 Three.js vendor import를 상대경로화한다.
2. `localStorage.getItem("darwinNo3D")`는 try/catch로 감싼다.
3. 3D 활성화 전 WebGL context 생성 가능 여부를 검사한다.
4. Switch 실기에서는 30fps cap 유지, pixelRatio는 1.0-1.25로 시작한다.
5. GLB에 vertex normals를 추가한 버전을 만들어 조명 품질을 확인한다.
6. 카메라가 살아 있으면 WebGL은 계속 pause한다.

---

## 7. 실기 검증 기준

RCM jig 확보 후 Switchroot에서 다음을 측정한다.

### 7-1. WebGL capability

```bash
glxinfo | egrep 'OpenGL vendor|OpenGL renderer|OpenGL version'
```

브라우저에서:

```javascript
document.createElement("canvas").getContext("webgl")
document.createElement("canvas").getContext("webgl2")
```

### 7-2. 3D 단독

조건:

- camera disabled
- `darwinNo3D` unset
- 1280×720 kiosk

합격 기준:

- 첫 표시 3초 이내
- 30fps 근처 또는 눈에 띄는 stutter 없음
- CPU/GPU 온도 상승이 급격하지 않음
- 10분 동안 브라우저 crash 없음

### 7-3. 카메라 우선 모드

조건:

- MJPEG camera live
- WebGL paused

합격 기준:

- 카메라 프레임이 유지됨
- 3D canvas render loop가 돌지 않음
- HUD 글자가 보임
- 10분 동안 메모리 증가가 감당 가능

### 7-4. 금지 조건

아래 상태를 기본값으로 만들면 안 된다.

- MJPEG live + WebGL auto-rotate 동시 30fps
- WebGL 실패 시 blank stage
- 60fps 강제
- texture-heavy GLB로 교체
- full-screen post-processing / bloom / shadow map

---

## 8. 최종 판단

**가능하다.** 현재 Darwin GLB는 Switch v1의 원시 GPU 성능 대비 매우 작다.

하지만 표현을 정확히 하면:

```text
Darwin GLB 단독 30fps 렌더링: 가능성 높음
Darwin GLB 단독 60fps 렌더링: 가능성 있음, 그러나 굳이 목표로 삼지 않음
MJPEG 카메라와 WebGL 동시 상시 구동: 권장하지 않음
Switchroot 브라우저에서 첫 부팅 즉시 3D 보장: 아직 미검증
```

따라서 제품 전략은 "3D 모델을 메인 기능으로 밀기"가 아니라 **카메라가 없을 때의 고급 fallback / 상태 시각화**로 쓰는 것이 맞다. 카메라가 연결되면 카메라가 우선이고, 3D는 멈추는 현재 정책이 성능상 가장 합리적이다.

---

## Sources

- Nintendo official Switch specs: <https://www.nintendo.com/us/gaming-systems/switch/tech-specs/>
- NVIDIA Tegra X1 newsroom: <https://nvidianews.nvidia.com/news/nvidia-launches-tegra-x1-mobile-super-chip>
- NVIDIA Tegra X1 whitepaper: <https://images.nvidia.com/content/pdf/tegra/Tegra-X1-whitepaper-v1.0.pdf>
- Digital Foundry clock-speed report mirror: <https://www.gamespot.com/articles/nintendo-switch-specs-cpu-and-gpu-clock-speeds-rep/1100-6446363/>
- iFixit Nintendo Switch teardown: <https://www.ifixit.com/Teardown/Nintendo%2BSwitch%2BTeardown/78263>
- Switchroot L4T Ubuntu summary: <https://wiidatabase.de/switch-downloads/hacks/l4t-ubuntu/>

