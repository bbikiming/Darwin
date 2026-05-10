# Webots (Cyberbotics) — DARwIn-OP 검증 1순위

## 한 줄 소개

물리 기반 3D 로봇 시뮬레이터. **DARwIn-OP를 표준 라이브러리에 포함**하고
있어서 우리가 따로 모델을 만들 필요가 없다.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 개발사 | Cyberbotics (스위스, 1998 창립) |
| 라이선스 | **Apache 2.0** (2018년 오픈 소스 전환) |
| 플랫폼 | Linux / macOS / Windows |
| 물리 엔진 | ODE (Open Dynamics Engine), 보강된 contact 모델 |
| 컨트롤러 언어 | C, C++, Python, Java, MATLAB, ROS, ROS2 |
| 빌트인 로봇 | NAO, Pepper, **DARwIn-OP**, ATLAS, e-puck, TurtleBot, UR5/10 등 100+ |
| 최신 버전 | R2024b (2024 후반) — 확인 필요 |

## DARwIn-OP 빌트인 모델

`webots/projects/robots/robotis/darwin-op/` 위치. 다음을 포함:

- **Mesh + URDF** — 20-DOF, MX-28 모터 모델
- **`darwin-op.proto`** — 시뮬 노드 정의
- **샘플 컨트롤러** — `controllers/walk/` (Walking 알고리즘 데모)
- **Cross-compilation 지원** — `Makefile.darwin-op`로 동일 컨트롤러를 sim
  과 실 로봇 양쪽에 빌드 (★ 핵심 기능)

→ 우리가 forge-core::walk를 Webots controller로 컴파일하면 sim에서 검증 후
같은 코드를 실 로봇에 그대로 배포 가능.

## UI / UX 분석

### 1. 메인 창 레이아웃

```
┌─────────────────────────────────────────────────────────┐
│  Menubar (File / Edit / Simulation / View / Tools)       │
├──────────┬──────────────────────────────────┬────────────┤
│          │                                  │            │
│  Scene   │       3D Viewport                │  Console   │
│  Tree    │       (OpenGL)                   │  (stdout)  │
│  (왼쪽) │                                  │  (오른쪽)  │
│          │                                  │            │
├──────────┴──────────────────────────────────┴────────────┤
│  Time Slider + Run / Pause / Step / Reset                │
└─────────────────────────────────────────────────────────┘
```

### 2. Scene Tree (씬 그래프)

VRML97 + 자체 확장(.wbt). 왼쪽 트리에서 노드 직접 편집 가능:

```
WorldInfo
  ├── basicTimeStep = 16  # ms (= 60 Hz 기본)
Viewpoint
TexturedBackgroundLight
DirectionalLight
RectangleArena {
  floorSize 4 4
  wallHeight 0.05
}
DEF DARWIN Robot {
  controller "walk"      # 컨트롤러 실행파일 이름
  children [
    # 20 DOF — Hinge2Joint × 20
    HingeJoint { ... }   # ID 1..20
    Camera { ... }
    Accelerometer { ... }
    Gyro { ... }
  ]
}
```

> ★ 차용: 우리도 `Robot` / `Joint` 모델을 SwiftData로 가지고 있는데, Webots
> 처럼 **씬 트리 사이드바 인스펙터** 패턴으로 노출하면 비전문가도 직관적.

### 3. 컨트롤러 인터페이스

Webots controller는 **별도 프로세스**로 실행되어 IPC로 sim과 통신:

```c
// C API 핵심
#include <webots/robot.h>
#include <webots/motor.h>

int main() {
    wb_robot_init();
    int timestep = wb_robot_get_basic_time_step();   // 16 ms
    WbDeviceTag motor = wb_robot_get_device("ShoulderR");
    wb_motor_set_position(motor, 1.5);   // rad

    while (wb_robot_step(timestep) != -1) {
        // sim 한 step 진행 — 그 사이 sensor read / motor write
    }
}
```

> ★ 차용: 우리 forge-core::walk는 이미 8 ms tick 모델. Webots의 16 ms는
> 두 배 느리지만 동일한 step-based 컨트롤 패턴. **forge-core::walk가 Webots
> controller로도 작동하도록 PosixSerial 대신 Webots IPC adapter를 두면**
> sim-to-real 동일 코드 가능.

### 4. ROS / ROS2 브리지

`webots_ros2` 패키지로 sim 측 모터/센서를 ROS2 토픽으로 노출. DarwinForge는
ROS를 안 쓰므로 직접 controller stub이 더 나음.

## DarwinForge 적용 제안

### Step 1 — Webots controller stub crate

```
app/core/forge-sim/
├── Cargo.toml
└── src/
    ├── lib.rs            # entry: forge_sim_run() — Webots controller hook
    ├── webots_ipc.rs     # libwebots stdin/stdout 통신
    └── adapter.rs        # SerialPort trait 구현 → Webots motor API로 변환
```

`forge-core::serial::SerialPort` trait을 Webots IPC로 구현하면 forge-cli `forge ping --port webots://localhost`가 sim 모터에 핑.

### Step 2 — sim-to-real 동등성 테스트

같은 motion 페이지를:
1. Webots로 재생 → 발 궤적 캡처
2. 실 로봇으로 재생 → IMU/관절 트레이스 캡처
3. **차이 그래프** SwiftUI 뷰 (`SimVsRealView`)

### Step 3 — 모션 라이브러리 미리보기

Motion Library 탭에서 `.mtn` 임포트한 후 **"sim 미리보기" 버튼** → Webots
프로세스 spawn → 3D 창에 재생.

## 출처

- 공식 사이트: https://cyberbotics.com/
- GitHub: https://github.com/cyberbotics/webots
- 사용 가이드 — DARwIn-OP: https://www.cyberbotics.com/doc/guide/darwin-op
- Webots ROS 2: https://github.com/cyberbotics/webots_ros2
- API 레퍼런스: https://cyberbotics.com/doc/reference/index
