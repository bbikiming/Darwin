# Nintendo Switch v1 Darwin GLB 렌더링 성능 검토

작성일: 2026-06-05
대상: Nintendo Switch 초기 모델(v1/Erista, Switchroot L4T Ubuntu 예정) + `tools/switch-pilot/web/assets/darwin.glb`
상태: 실 Switch 미검증. 로컬 GLB 파싱 + 공개 하드웨어 자료 기반 정량 추정.
업데이트: 2026-06-05 Codex가 `darwin.glb`에 vertex normal을 직접 주입하고, 머리 mesh의 180도 역방향 문제를 수정 완료.

---

## 1. 결론

현재 번들에 들어간 `darwin.glb`는 **Switch v1 성능상 충분히 렌더링 가능한 수준**이다.

냉정하게 말하면 병목은 GLB 폴리곤 수가 아니다. 병목 후보는 다음 순서다.

1. Switchroot 브라우저의 WebGL/Three.js ES module 호환성
2. WebGL과 MJPEG 카메라 스트림을 동시에 돌릴 때의 브라우저/GPU/메모리 안정성
3. 장시간 kiosk 운용 중 브라우저 메모리 증가
4. 모델 자체의 시각 품질: 현재 GLB는 POSITION + NORMAL + INDICES이며 texture/shadow는 없다

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
| 파일 크기 | 750,396 bytes, 약 733KB |
| glTF 버전 | 2.0 binary GLB |
| JSON chunk | 23,960 bytes |
| BIN chunk | 726,408 bytes |
| scene | 1 |
| node | 60 |
| mesh | 21 |
| material | 6 |
| primitive/draw-call 후보 | 21 |
| texture/image | 0 |
| vertex attribute | POSITION + NORMAL |
| vertex 수 합계 | 15,123 |
| triangle 수 추정 | 30,288 |
| index buffer | 363,456 bytes |
| position buffer | 181,476 bytes |
| normal buffer | 181,476 bytes |
| bounding box | 약 126 × 157 × 239 units |

중요한 해석:

- **30k triangles**는 2026년 기준으로는 매우 작은 실시간 3D 모델이다.
- texture가 없어서 VRAM/메모리 부담이 거의 없다.
- primitive 21개는 draw call 21개 수준이므로 Three.js/browser에서도 부담이 낮다.
- vertex normal을 추가했으므로 Hemisphere/Directional Light 기반의 입체감은 이전보다 정상적으로 나온다.
- 머리 mesh는 기존 bake 결과에서 180도 반대로 돌아가 있어, `geo_op_head`의 yaw를 교정했다. 정면 렌더에서 머리의 카메라/눈 구멍이 몸통 정면과 같은 방향으로 보이는 것을 Chrome GPU headless 렌더로 확인했다.
- `robot3d-test.html`은 정면/좌측/우측/후면 4분할 검수 화면으로 보강했다. 검수 스크린샷은 `docs/assets/darwin-model-qa-4view.png`에 저장했다.
- 실제 cockpit 화면에서도 조종 UI와 3D 모델이 동시에 보이도록 보강했다. `robot3d.js`는 모델 활성화 시 즉시 resize + render를 수행하고, cockpit는 mount 전에 WebGL 컨테이너를 먼저 표시해 숨겨진 canvas에 첫 프레임이 그려지는 문제를 막는다. Mac dry-run 캡처는 `docs/assets/darwin-cockpit-control-with-model.png`에 저장했다.
- 설치된 Switch에서 직접 열 수 있는 런타임 진단 페이지 `model-check.html`을 추가했다. 30fps cap 기준 평균 FPS, 최근 FPS, 평균/최대 프레임 간격, 느린 프레임 수를 표시한다. Mac Chrome headless 캡처는 `docs/assets/darwin-model-check-runtime.png`에 저장했지만, 이 수치는 Switch 실기 판정값이 아니다.
- 다만 texture, shadow, PBR roughness 세부 조정은 없으므로 "고급 fallback / 상태 시각화" 용도라는 제품 전략은 그대로 유지한다.

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
| `darwin.glb` | 약 733KB |
| `three.module.min.js` | 약 655KB |
| `GLTFLoader.js` | 약 106KB |

대략적인 런타임 메모리:

- GLB position/normal/index buffer: 약 0.69MB raw
- WebGL framebuffer/backbuffer/depth: 10-30MB 범위 추정
- Three.js object/JS overhead: 수 MB에서 수십 MB 가능

Switch v1의 4GB RAM 환경에서 이 모델 하나는 메모리 병목이 아니다. 문제는 MJPEG 카메라, 브라우저 프로세스, 장시간 누수, 데스크톱/kiosk 세션과 합산될 때다.

---

## 5. 위험 평가

| 항목 | 위험도 | 판단 |
|---|---:|---|
| GLB geometry 수 | 낮음 | 30k triangles는 충분히 작다 |
| GLB 파일 크기 | 낮음 | 733KB, 로컬 asset |
| texture/VRAM | 낮음 | texture/image 없음 |
| draw call | 낮음-중간 | 21개는 문제 없어 보이나 browser/driver에 따라 확인 필요 |
| WebGL/Three.js 브라우저 호환성 | 중간 | import map 의존은 제거됨. Switchroot browser의 WebGL/ES module/driver 상태 확인 필요 |
| MJPEG 카메라와 동시 구동 | 중간-높음 | WebGL + MJPEG 동시 구동은 피해야 함 |
| 장시간 kiosk 안정성 | 중간 | 10-30분 이상 실기 soak test 필요 |
| 모델 시각 품질 | 낮음-중간 | NORMAL 적용 완료. texture/shadow가 없어 실기 조명감 확인은 필요 |

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

### 6-1. 조종 중 모델 확인 가능성

판단:

```text
카메라가 live가 아닐 때: 조종 UI + WebGL Darwin GLB 동시 표시 가능
카메라가 live일 때: 조종 UI + MJPEG 우선, WebGL GLB는 pause 권장
Switch 실기에서의 최종 판단: RCM/Switchroot 이후 real-GPU 확인 필요
```

현재 cockpit는 다음 조건을 만족한다.

- 조종 권한, deadman, 보행/머리 입력 readout, 연결/로봇 상태 패널은 3D 모델과 같은 화면에 남아 있다.
- `robot3d.js`는 30fps cap과 낮은 DPR cap을 유지한다.
- 3D 상태는 HUD에 `3D 모델 표시`, `3D 일시정지`, `3D 로드 실패` 등으로 표시된다.
- 카메라가 live가 아니면 3D 모델을 보여주고, 카메라가 live가 되면 WebGL render loop를 멈춘다.
- `http://127.0.0.1:8765/model-check.html`은 Switch 현장에서 충분/주의/불충분을 바로 판정하는 런타임 페이지로 패키지에 포함된다.

따라서 "스위치에서 조종하면서 모델링을 확인"하는 UX는 **카메라 미사용/카메라 실패/카메라 대기 fallback 모드에서는 충분히 가능하도록 설계됐다.** 반대로 카메라 영상과 3D 모델을 동시에 상시 표시하는 방식은 Switch v1에서 안정성 리스크가 크므로 기본 정책으로 두면 안 된다.

추가 권장:

1. Three.js vendor import 상대경로화는 적용 완료. import map 의존성을 다시 만들지 않는다.
2. `localStorage.getItem("darwinNo3D")` try/catch는 적용 완료. 유지한다.
3. 3D 활성화 전 WebGL context 생성 가능 여부 검사는 적용 완료. 유지한다.
4. Switch 실기에서는 30fps cap 유지, pixelRatio는 1.0-1.25부터 확인한다.
5. vertex normal은 적용 완료. 실기에서는 조명감, 계단 현상, 첫 표시 시간을 확인한다.
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
- `http://127.0.0.1:8765/model-check.html`을 Switch 자체 브라우저에서 실행

합격 기준:

- 첫 표시 3초 이내
- `model-check.html` 결과 `충분`
- 평균 24fps 이상
- 최대 프레임 간격 120ms 이하
- CPU/GPU 온도 상승이 급격하지 않음
- 10분 동안 브라우저 crash 없음

주의 기준:

- `model-check.html` 결과 `주의`
- 18-24fps 또는 간헐적 stutter
- 이 경우 3D는 카메라 fallback/status view로만 사용하고, MJPEG camera live와 동시 상시 구동하지 않는다.

불합격 기준:

- `model-check.html` 결과 `불충분`
- 18fps 미만, blank canvas, WebGL crash, 또는 장시간 후 브라우저 hang
- 이 경우 setup에서 3D model toggle을 OFF로 두고 CSS robot figure fallback을 사용한다.

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
