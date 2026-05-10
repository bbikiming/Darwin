# 광학 / IMU 모션 캡처 — DarwinForge 적용 가능성

> 사람의 모션을 "외부 장치로" 잡는 두 갈래 정통 기법.
> 광학(optical)은 카메라가 마커를 보고, IMU(inertial)는 사람이 센서를
> 입는다. DarwinForge는 macOS 데스크탑 앱이라 광학 스튜디오는 외부에
> 의존, IMU는 자체 통합 가능. Rokoko가 가장 현실적 후보.
>
> 작성일: 2026-05-10. 출처 URL 필수.

---

## 1. Vicon — 영국, 광학 스튜디오 표준 (1984~)

Vicon Motion Systems (Oxford Metrics) 는 1984년 영국에서 창업해 약 40년간 **수동 패시브 마커 + 적외선 카메라** 광학 모션 캡처의 사실상 표준이다. 영화 (Avatar, Avengers), 게임 (FIFA, NBA 2K), 의생체역학, 로봇 학습 (DeepMind 등) 에서 광범위하게 쓰인다.

### 1.1 카메라 라인업

| 라인업 | 해상도 | 프레임률 | 정확도 | 가격대 (대당) |
|--------|--------|----------|--------|----------------|
| **Valkyrie VK26 / VK16** | 26 MP / 16 MP | 200 / 300 fps | 0.1 mm | $25K~40K |
| **Vantage V16 / V8 / V5** | 16 / 8 / 5 MP | 120~420 fps | 0.2 mm | $15K~25K |
| **Vero v2.2 / v1.3X** | 2.2 / 1.3 MP | 250~330 fps | 0.5 mm | $7K~12K |

스튜디오 1대 구축은 보통 8~24대 카메라가 필요하며, 캘리브레이션 / 동기화 / 처리용 PoE 스위치까지 합치면 **총 $50K ~ $250K** 수준 (출처: Vicon https://www.vicon.com/hardware/cameras/).

### 1.2 소프트웨어 스택 + SDK

- **Tracker** (실시간 객체 트래킹), **Nexus** (의생체역학), **Shogun** (영화 / 캐릭터)
- **Datastream SDK**: C / .NET / Python / MATLAB 바인딩, TCP / UDP, 100~1000 Hz 마커 스트림
- 출력: **C3D** (마커 시계열) + **FBX / BVH** (스켈레톤 솔브 후)

(출처: Vicon DataStream SDK https://www.vicon.com/software/datastream-sdk/)

### 1.3 DarwinForge 적용 가능성

**△ 연구실 한정**. 가격 / 공간 / 캘리브레이션 부담이 macOS 데스크탑 앱의 사용자 시나리오와 맞지 않는다. 그러나 Datastream SDK가 표준이라 대학·연구실 사용자가 자체 데이터를 추출해 BVH로 import 하는 경로는 의미 있음. forge-core::mocap::bvh_loader가 그 진입점.

---

## 2. OptiTrack — NaturalPoint, 가성비 광학 (2005~)

OptiTrack (NaturalPoint) 은 미국 오리건 기반으로, Vicon보다 같은 정확도에서 가격을 30~50% 낮춰 대학 연구실 / 인디 게임 / VR 업계의 표준이 됐다.

### 2.1 PrimeX 시리즈

| 모델 | 해상도 | fps | 라이트닝 거리 | 가격대 |
|------|--------|-----|----------------|--------|
| PrimeX 41 | 4.1 MP | 180 fps | 30 m | $7K |
| PrimeX 22 | 2.2 MP | 360 fps | 20 m | $5K |
| PrimeX 13 / 13W | 1.3 MP | 240 fps | 15 m | $2.5K~3.5K |
| Slim 13E (위치 트래킹) | 1.3 MP | 120 fps | 7 m | $1.5K |

(출처: OptiTrack https://optitrack.com/cameras/primex-41/)

### 2.2 Motive 소프트웨어 + NatNet SDK

- **Motive 3.x**: 윈도우 전용 GUI (Mac 미지원, Wine / Parallels 우회 필요)
- **NatNet SDK**: 멀티플랫폼 (Win / macOS / Linux), C++ / C# / Python / Unity / Unreal / ROS 바인딩, **multicast UDP** 기반
- 출력: **C3D** / **FBX** / **CSV** / 실시간 NatNet 스트림

(출처: NatNet SDK https://docs.optitrack.com/developer-tools/natnet-sdk)

### 2.3 DarwinForge 적용 가능성

**★ 대학 보유 시 직접 사용 가능**. Motive는 윈도우 전용이지만 NatNet SDK는 macOS 지원. forge-core::mocap::natnet 모듈을 만들면 multicast UDP로 마커 스트림 수신 → SMPL 솔버 → DARwIn-OP 리타겟 가능. KAIST / POSTECH / 서울대 / KIST 등 한국 연구실에 OptiTrack이 흔하므로 협업 가능성.

---

## 3. Rokoko Smartsuit Pro II — IMU 슈트, 인디 영화·게임 표준 ★★★

덴마크 Copenhagen 기반 Rokoko Electronics는 2014년 창업, "스튜디오 없이 입고 다닐 수 있는 모션 캡처" 컨셉으로 IMU 슈트 시장을 개척했다.

### 3.1 사양

- **19개 IMU** (LSM6DSO 또는 동등 9DoF) — 척추 5, 팔 6, 다리 8
- **Wi-Fi 5 GHz / USB-C** 동시 지원
- 100 Hz 샘플링 (OSC / WebSocket 스트림)
- 15 시간 배터리, 충전식
- 가격: **$2,495** (Pro II, 2025년 기준)
- 추가 옵션: **Smart Gloves Lite/Pro** ($995/$1,995, 손가락 7개 IMU/glove)
- **Headcam** (얼굴 캡처), **Smartgloves**

(출처: Rokoko https://www.rokoko.com/products/smartsuit-pro)

### 3.2 Rokoko Studio + LiveStream API

- **Rokoko Studio**: macOS / Windows / Linux 네이티브 앱 (Apple Silicon 네이티브!)
- **LiveStream API**: 무료, JSON over UDP (port 14043) 기본, Custom Binary 옵션
- 페이로드: 각 관절의 quaternion + position + velocity, 60~100 Hz
- 출력 포맷: **FBX** / **BVH** / **CSV** / **USD** / **glTF**

샘플 페이로드 (출처: https://github.com/Rokoko/rokoko-studio-live-blender):

```json
{
  "scene": {
    "actors": [{
      "name": "actor1",
      "body": {
        "hip":      { "position": [...], "rotation": {"x":..,"y":..,"z":..,"w":..} },
        "spine":    { ... },
        "leftUpLeg":{ ... },
        ...
      }
    }],
    "props": []
  }
}
```

> ★ 차용: forge-core::mocap::rokoko_listener 신규 모듈. tokio::net::UdpSocket 으로 14043 포트 listen, JSON parse → SMPL skeleton (23 joints) 매핑 → DARwIn-OP retarget. Swift 측에서는 `RokokoBridge.swift` 가 status indicator (연결 / 끊김 / FPS) 표시.

### 3.3 DarwinForge 적용 가능성 — ★★★ 1순위

가장 현실적. 이유:

1. macOS Apple Silicon 네이티브 → Continuity Camera 식 자연스러운 등장
2. LiveStream API가 무료 + 표준 JSON → Rust tokio로 200줄 내 listener 구현 가능
3. 슈트 입고 10분이면 사용자 시범 가능 → "사람 → DARwIn-OP" 직접 시연 가능

단점: 슈트 $2,495는 일반 사용자 진입 부담. 보유한 기관 / 스타트업 대상.

---

## 4. Xsens MVN — Movella 인수, 산업 IMU 표준

Xsens는 1999년 네덜란드 Enschede 창업, 2022년 Movella에 인수됐다. 산업 / 방위 / 영화 (Avatar 2 in-set tracking) / 의료 / 스포츠 분야에서 IMU 모션 캡처의 정통 표준.

### 4.1 라인업

| 모델 | 센서 수 | 무선 | 정확도 | 가격대 |
|------|---------|------|--------|--------|
| **MVN Awinda** | 17 | ✓ (proprietary 2.4 GHz) | 0.5° (정적) / 1° (동적) | ~$12K |
| **MVN Link** | 17 | ✓ (Body Pack + Wi-Fi) | 0.5° / 1° | ~$25K |
| **MTw Awinda** | 1~7 (개별) | ✓ | 동일 | ~$3K~ |

(출처: Movella https://www.movella.com/products/mocap-pro/xsens-mvn-awinda)

### 4.2 MVN Analyze / Animate + SDK

- **MVN Analyze**: 의생체역학용 (보행, 운동선수)
- **MVN Animate**: 영화 / 게임용
- **MVN SDK** (C / C++) + **Python API**, Real-time TCP 스트림
- 출력: **MVNX** (XML 표준) / **FBX** / **BVH** / **C3D**

(출처: Movella MVN SDK https://www.movella.com/support/software-documentation)

### 4.3 DarwinForge 적용 가능성 — ★★ 정확도 최고

Rokoko 대비 정확도 우위 (특히 동적 동작), Wi-Fi 5 GHz 안정성. 그러나 **5~10배 가격**, Windows 전용 SDK가 강함 (macOS 부분 지원). 대학 연구실 / 산업 R&D 부서 보유 시에만 의미. forge-core::mocap::mvnx_loader 로 MVNX 파일 import 경로만 우선 지원하면 충분.

---

## 5. Perception Neuron (Noitom) — 가성비 IMU

중국 Noitom Technology의 Perception Neuron 시리즈는 2014년 Kickstarter 발산 이후 인디 / 학생 / 유튜버 시장에서 가장 많이 팔린 IMU 슈트.

### 5.1 라인업

| 모델 | 센서 | 무선 | 가격 |
|------|------|------|------|
| Perception Neuron Studio | 17 (full body) + 손가락 옵션 | ✓ | $1,495 |
| Perception Neuron 3 | 17 | ✓ | $799 |
| Perception Neuron Pro / 32 | 17 / 32 | ✓ | $1,500~3,000 |

(출처: Noitom https://www.noitom.com/perception-neuron-studio)

### 5.2 Axis Studio + SDK

- **Axis Studio**: Windows / macOS GUI
- **Axis Neuron SDK**: TCP/UDP 스트리밍, BVH 표준 포맷
- 출력: **BVH** / **FBX** / **CSV**

### 5.3 DarwinForge 적용 가능성 — ★★ 가성비

진입 가격 $799가 매력적. 그러나 정확도 / 캘리브레이션 안정성은 Rokoko / Xsens 대비 떨어짐 (사용자 보고 다수 — 출처 확인 필요). BVH 표준 출력이라 forge-core::mocap::bvh_loader 한 줄 변경으로 호환.

---

## 6. SHADOW Motion Capture — 의생체역학 특화

Motion Workshop (시애틀) 의 SHADOW Motion Capture는 의생체역학 / 의료 분석 강점. C3D 출력 + Real-time SDK. 가격 $5K~15K. 본 보고서에서는 깊이 분석 생략, 의료 / 재활 분야 사용자가 있을 경우 별도 조사.

(출처: Motion Workshop https://www.motionnode.com/ — "확인 필요" 최신 가격)

---

## 7. PhaseSpace Impulse — 능동 LED 모션 캡처

미국 PhaseSpace의 Impulse X2/X3 시리즈는 **능동 LED 마커**를 쓴다. 패시브 반사 마커 대비 ID 추적이 강건하고 occlusion에 강하다. VR / 의생체역학 / 일부 영화에서 사용.

- 가격: $20K~100K (소규모 셋업)
- LED 600~720 fps, ID 자동 식별
- SDK: **OWL** (Object-Oriented Wireless Library, C++)

(출처: PhaseSpace https://www.phasespace.com/x2-motion-capture/)

DarwinForge 적용도 △. Vicon / OptiTrack과 같은 카테고리이며 macOS 사용자에게 직접 의미는 약함.

---

## 8. 비교 요약 — DarwinForge 관점

### 8.1 정확도 vs 가격 매트릭스

```
정확도 ↑
  0.1mm  | Vicon Vantage     ← 영화·연구
  0.5mm  | OptiTrack PrimeX  ← 가성비 광학
  1.0mm  | (광학 보급형)
   1°    | Xsens MVN         ← IMU 정밀
   2°    | Rokoko Pro II ★   ← 우리 1순위
   3°    | Perception Neuron ← 가성비 IMU
   5°    | ARKit Body        ← (다음 문서)
   ─────────────────────────────
        $1K  $5K  $20K  $100K  →  가격
```

### 8.2 DarwinForge 통합 우선 순위

| 순위 | 시스템 | 통합 방식 | 작업량 |
|------|--------|-----------|--------|
| ★★★ 1순위 | **Rokoko LiveStream** | tokio UDP listener + JSON parse + 리타겟 | 1~2주 |
| ★★ 2순위 | **BVH 표준 import** | 모든 IMU/광학 시스템 공통 fallback | 3~5일 |
| ★★ 2순위 | **OptiTrack NatNet** | multicast UDP + binary protocol | 1~2주 |
| ★ 3순위 | **Xsens MVNX** | XML 파일 import, real-time 생략 | 1주 |
| ★ 3순위 | **Vicon Datastream** | 연구실 협업 시 (rare) | 2주+ |

### 8.3 Rust forge-core::mocap 모듈 초안 (광학 / IMU 부분)

```rust
// app/core/forge-core/src/mocap/mod.rs (제안)
pub mod bvh;        // BVH parser + writer (모든 시스템 공통)
pub mod rokoko;     // Rokoko LiveStream JSON-over-UDP
pub mod natnet;     // OptiTrack NatNet binary multicast
pub mod mvnx;       // Xsens MVNX XML
pub mod c3d;        // Vicon C3D 마커 시계열 (의생체역학)

pub use bvh::{BvhSkeleton, BvhFrame, parse_bvh, write_bvh};
pub use rokoko::{RokokoListener, RokokoActor, RokokoFrame};
```

(출처: 본 보고서 §8 — 본인 작성)

---

## 9. ★ 차용 박스 — 즉시 적용 후보

> ★ 차용 1: forge-core::mocap::rokoko 모듈 — Rokoko LiveStream API의 14043
> UDP 포트 listen, 100 Hz JSON 페이로드 → SMPL 23 joint quaternion 매핑.
> Swift 측 `MocapView.swift` 에서 connection status / FPS / actor 수
> 표시. 데모 모드에서 사용자가 슈트를 입고 라이브로 DARwIn-OP를
> 움직이는 시나리오.
>
> ★ 차용 2: forge-core::mocap::bvh — Biovision BVH 표준 파서. Mixamo /
> Rokoko / Perception Neuron / Xsens 모두가 BVH 출력을 지원하므로 단일
> import 경로 확보. 사용자가 .bvh 파일을 SwiftUI 앱에 drag & drop →
> 자동 리타겟 → 모션 라이브러리 추가.
>
> ★ 차용 3: 위 두 모듈 위에 retarget 레이어. 이는
> `04-retargeting-pipeline-for-darwin-op.md` 에서 상세 다룬다.

(출처: 본 보고서 §9 — 본인 작성)

---

## 10. 정리

광학 시스템은 정확도 1순위지만 macOS 사용자 환경에 직접 통합 어려움. **IMU 슈트 (Rokoko)** 가 macOS 네이티브 + LiveStream API + 가격 ($2,495) 의 균형으로 1순위 후보. 다만 모든 광학 / IMU 시스템이 **BVH** 또는 **FBX** 로 export 가능하므로, DarwinForge가 BVH import 한 채널만 잘 만들어 두면 거의 모든 시스템과 간접 호환 가능. 다음 문서 [02-markerless-and-mobile.md](02-markerless-and-mobile.md) 에서 마커 없는 / 카메라 1대만 쓰는 차세대 옵션을 다룬다.

(출처: 본 결론 — 본인 작성, 인용은 §1~§9 출처 참조)
