# Sensor Stack — DARwIn-OP / OP2 센서 구성

> 사용 가능한 모든 센서, 그 위치, 우리 forge-core에서 어떻게 노출되는지.

## 한눈 보기

| 센서 | 위치 | 주체 | 단위 | 비고 |
|------|------|------|------|------|
| 3-축 자이로 | CM-730/740 | Z, Y, X (38–43) | ±500 dps, 10-bit ADC | 보드 기준 |
| 3-축 가속도 | CM-730/740 | X, Y, Z (44–49) | ±4 g, 10-bit ADC | 보드 기준 |
| 배터리 전압 | CM-730/740 | 50 | 0.1 V | LiPo 9 V 이하 = warning |
| 마이크 (좌/우) | CM-730 only | 51–52, 67–68 | 10-bit | OP2에서 제거 |
| 외부 ADC | CM-730/740 | 53–80 | 10-bit | FSR/추가 센서 입력 |
| 버튼 (mode/start) | CM-730/740 | 30 | 비트 | |
| 카메라 | head | USB | YUV 1600×1200 @ 30 fps | Logitech C905 (OP1 stock) |
| FSR (옵션) | 발바닥 | Dynamixel ID 111/112 | 4 sensor × 2 발 | |

## IMU (자이로 + 가속도)

CM 보드 위 칩셋(InvenSense MPU60xx 계열로 추정). 라이프사이클:

1. 보드 부팅 시 자동 calibrate (정지 상태 가정 — Walking 시작 전 보드를 흔들지 말 것)
2. 매 8 ms cycle 마다 BULK_READ로 6 채널 (gyro 3 + accel 3) 읽기
3. forge-core가 raw → SI 단위 변환 (`raw - 512` 후 스케일)
4. Phase 5 Sprint 5에서 complementary filter 또는 Madgwick으로 자세(roll/pitch/yaw) 추정

```
gyro_dps = (raw - 512) * (500 / 512)
accel_g  = (raw - 512) * (4 / 512)
```

## 카메라

- **OP1 stock**: Logitech QuickCam Pro 9000 / C905, USB UVC, 1600×1200 max, 30 fps@640×480
- **OP2 stock**: 동일 또는 후속 (가끔 C920로 교체된 복원 사례 있음)
- macOS 측: 로봇이 켜져 있고 호스트에 USB로 연결되어 있다면 일반 UVC 카메라로 인식 (`AVCaptureDevice` 또는 `UVCCamera`)

> 우리 앱이 카메라 영상을 직접 받는 두 가지 방법:
> 1. **호스트 직결** — 사용자가 로봇 카메라 USB를 Mac에 직접 연결 (가장 단순)
> 2. **로봇 패스스루** — 로봇 onboard PC가 비디오 서버, Mac이 클라이언트 (Phase 5 Sprint 6에서 결정. ADR 후속)

## FSR (Force Sensitive Resistor)

옵션 부품. 발바닥에 4개씩 8개. ROBOTIS FSR 보드가 Dynamixel bus에 ID 111/112로 등장 → MX-28과 같은 방식으로 read 가능. 우리는 그냥 또 다른 Dynamixel device로 처리.

용도:
- 발바닥 무게 분포 → ZMP 추정 보강
- 발이 땅에 닿았는지 검출 (Walking phase 전환)

## 마이크 (OP1 only)

CM-730의 ADC 51, 52 (좌), 67, 68 (우)에서 10-bit 마이크 샘플. 8 kHz 정도가 한계. 우리 앱에서는 **noise floor 모니터링** 용도로만 사용 (음성 인식은 stretch goal).

## 버튼

`BUTTON` 레지스터 (주소 30) 비트:
- bit 0: MODE
- bit 1: START

Walking 시작/중지를 사용자가 로봇에서 트리거하는 데 사용. forge-core가 폴링하여 UI에 이벤트 전달.

## LED

- **LED_PANEL** (주소 25): 가슴 3개 단색 LED, 비트마스크
- **LED_HEAD** (주소 26-27): 머리 좌·우 2개, RGB565
- **LED_EYE** (주소 28-29): 눈 좌·우 2개, RGB565

UI에서 "이 로봇 어느 거?" 식별용으로 우리 앱이 head LED를 짧게 깜빡이는 기능 제공 (Sprint 2).

## 출처

- ROBOTIS e-Manual: <https://emanual.robotis.com/docs/en/platform/op/references/>
- `research/robotis-official/ROBOTIS-OP-Series-Data/.../Hardware/Electronics/CM-730 Sub-Controller Reference.pdf`
- `research/robotis-official/ROBOTIS-OP2/cm_740_module/src/cm_740_module.cpp`
- `darwinop-ens/darwin-op` `Framework/src/hardware/CM730.cpp`
