# 05 — Vision Pipeline (ROBOTIS-OP2 Factory Firmware)

## TL;DR

ROBOTIS-OP2의 공장 펌웨어 비전 스택은 **V4L2 YUYV 캡처 → YUV→RGB→HSV 변환 → 단일-색상 HSV(hue/saturation/value) 임계화 → erosion+dilation → 픽셀 누적 centroid**로 구성된 단순 파이프라인이다. 카메라는 320×240 @ 30 FPS 고정 해상도로 동작하며, 공장에서 출하되는 데모는 `BallFinder` 1개 + RGB 3색 `ColorFinder`(빨강/노랑/파랑)를 동시에 돌려 RoboCup 스타일 축구(주황 공)와 색 인식 인터랙션을 함께 수행한다. **goal/field/line 검출 코드와 [Goal]/[Field]/[Line] config 섹션은 이 펌웨어 트리에 존재하지 않는다** — RoboCup용 풀 스택이 아니라 SDK 데모 수준의 비전이다.

---

## Camera config

### 캡처 파라미터 (하드코딩)

`Framework/src/vision/Camera.cpp` — 해상도/시야각 정적 상수:

```cpp
int Camera::WIDTH  = 320;
int Camera::HEIGHT = 240;

// from Camera.h
static const double VIEW_V_ANGLE = 46.0; //degree
static const double VIEW_H_ANGLE = 58.0; //degree
```

`Linux/build/LinuxCamera.cpp` — V4L2 초기화 (Line 73, 119, 141):

```cpp
sprintf(devName, "/dev/video%d", deviceIndex);            // device path
fmt.fmt.pix.width       = Camera::WIDTH;                  // 320
fmt.fmt.pix.height      = Camera::HEIGHT;                 // 240
fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;              // YUV 4:2:2
fmt.fmt.pix.field       = V4L2_FIELD_INTERLACED;
fps.parm.capture.timeperframe.numerator   = 1;
fps.parm.capture.timeperframe.denominator = 30;           // 30 FPS
```

**자동제어 비활성화** (LinuxCamera.cpp Line 227-230) — 색 임계 안정성 확보:

```cpp
v4l2SetControl(V4L2_CID_EXPOSURE_AUTO, V4L2_EXPOSURE_MANUAL);
v4l2SetControl(V4L2_CID_AUTO_WHITE_BALANCE, 0);
v4l2SetControl(V4L2_CID_AUTOGAIN, 0);
v4l2SetControl(V4L2_CID_HUE_AUTO, 0);
```

V4L2 mmap 버퍼 4개로 stream 캡처 → 매 프레임 **H/V flip** 적용 (카메라가 머리에 거꾸로 장착되어 있음) → YUV→RGB→HSV 변환 (`Linux/build/LinuxCamera.cpp` Line 389-392):

```cpp
ImgProcess::HFlipYUV(fbuffer->m_YUVFrame);
ImgProcess::VFlipYUV(fbuffer->m_YUVFrame);
ImgProcess::YUVtoRGB(fbuffer);
ImgProcess::RGBtoHSV(fbuffer);
```

### `[Camera]` 섹션 — tutorial/camera/config.ini

```ini
[Camera]
Brightness  = -1    # reset value
Contrast    = -1    # reset value
Saturation  = -1    # reset value
Gain        = 255
Exposure    = 1000
```

(`-1` = "device 기본값으로 reset", 다른 값은 V4L2_CID_BRIGHTNESS/CONTRAST/SATURATION/GAIN/EXPOSURE_ABSOLUTE로 직접 push)

### 자동제어/노출 매핑 (CameraSettings 클래스, `Linux/include/LinuxCamera.h` Line 27-32)

```cpp
int brightness; /* 0 ~ 255 */
int contrast;   /* 0 ~ 255 */
int saturation; /* 0 ~ 255 */
int gain;       /* 0 ~ 255 */
int exposure;   /* 0 ~ 10000 */

CameraSettings() :
    brightness(-1),  contrast(-1),  saturation(-1),
    gain(255),       exposure(1000)
{}
```

기본값은 gain=255 (최대), exposure=1000 — 실내 형광등 환경 가정.

---

## Color detection model

### 색공간

**HSV** (Hue/Saturation/Value)를 사용. RGB → HSV는 `Framework/src/vision/ImgProcess.cpp::RGBtoHSV`에서 직접 손코딩되어 있으며, 결과는 `FrameBuffer::m_HSVFrame`에 4바이트/픽셀 (H high byte / H low byte / S / V) 형태로 저장된다.

YCbCr는 **사용하지 않는다**. V4L2 입력은 YUYV(YUV 4:2:2)지만 즉시 RGB로 변환되고, 분할은 HSV 공간에서 수행된다.

### Threshold 표현: centroid + offset (NOT min/max range)

`Framework/include/ColorFinder.h`:

```cpp
class ColorFinder
{
private:
    Point2D m_center_point;
    void Filtering(Image* img);

public:
    int m_hue;             /* 0 ~ 360 */
    int m_hue_tolerance;   /* 0 ~ 180 */
    int m_min_saturation;  /* 0 ~ 100 */
    int m_min_value;       /* 0 ~ 100 */
    double m_min_percent;  /* 0.0 ~ 100.0 */
    double m_max_percent;  /* 0.0 ~ 100.0 */

    std::string color_section;
    Image*  m_result;       // binary mask, 1 byte/pixel

    ColorFinder();
    ColorFinder(int hue, int hue_tol, int min_sat, int min_val,
                double min_per, double max_per);

    void LoadINISettings(minIni* ini);
    void LoadINISettings(minIni* ini, const std::string &section);
    void SaveINISettings(minIni* ini);
    void SaveINISettings(minIni* ini, const std::string &section);

    Point2D& GetPosition(Image* hsv_img);
};
```

Hue는 **중심값 + 허용 범위**(원형 wrap-around 처리)로 정의되고, S/V는 단순 **최소 임계**만 사용 (max 없음). `min_percent`/`max_percent`는 검출된 픽셀 비율 게이트 — 너무 작거나(노이즈) 너무 큰(잘못된 큰 색상 덩어리, 예: 배경) blob을 reject한다.

### Hue wrap-around (ColorFinder.cpp Line 51-82)

```cpp
h_max = m_hue + m_hue_tolerance;
h_min = m_hue - m_hue_tolerance;
if(h_max > 360) h_max -= 360;
if(h_min < 0)   h_min += 360;

// inside loop:
if( ((int)s > m_min_saturation) && ((int)v > m_min_value) )
{
    if(h_min <= h_max)  // normal range
    {
        if((h_min < (int)h) && ((int)h < h_max))
            m_result->m_ImageData[i] = 1;
    }
    else                // wraps around 0/360 (e.g. red)
    {
        if((h_min < (int)h) || ((int)h < h_max))
            m_result->m_ImageData[i] = 1;
    }
}
```

### 동시 색상 개수

**최대 4개까지 병렬 실행 가능** (데모 main.cpp가 실제로 4개 인스턴스 사용):

```cpp
ColorFinder* ball_finder   = new ColorFinder();              // ini의 [Find Color] (orange ball)
ColorFinder* red_finder    = new ColorFinder(0,   15, 45, 0, 0.3, 50.0);  // [RED]
ColorFinder* yellow_finder = new ColorFinder(60,  15, 45, 0, 0.3, 50.0);  // [YELLOW]
ColorFinder* blue_finder   = new ColorFinder(225, 15, 45, 0, 0.3, 50.0);  // [BLUE]
```

CPU 비용은 색당 약 320×240 = 76,800 픽셀 × (filter + 3×3 erode + 3×3 dilate) — Intel Atom 호스트에서 30 FPS를 유지하려면 4개가 사실상 상한.

---

## Factory color thresholds

### Source: `robotis/Linux/project/tutorial/color_filtering/config.ini`

```ini
[Camera]
# -1 : reset control
Brightness  = -1    # reset value
Contrast    = -1    # reset value
Saturation  = -1    # reset value
Gain        = 255
Exposure    = 1000

[Find Color]
hue             = 355
hue_tolerance   = 15
min_saturation  = 60
min_value       = 15
min_percent     = 0.1
max_percent     = 50.0
```

이게 ROBOTIS가 공장에서 출하한 **유일한 실제 [Find Color] 섹션 예제**다. Hue 355 ± 15 = **340–360 + 0–10** 범위 → 빨강(red)/주황(orange) 영역. RoboCup 공식 공이 주황색이므로 이 값은 "orange ball" 디폴트로 통한다.

### Source: `robotis/Linux/project/tutorial/head_tracking/config.ini`

```ini
[Camera]
# -1 : reset control
Brightness  = -1    # reset value
Contrast    = -1    # reset value
Saturation  = -1    # reset value
Gain        = 255
Exposure    = 1000

[Find Color]
hue             = 355
hue_tolerance   = 15
min_saturation  = 60
min_value       = 15
min_percent     = 0.2
max_percent     = 15.0
```

`color_filtering`과 동일한 색 정의지만 `min_percent`가 0.1 → 0.2로 올라가고 `max_percent`가 50 → 15로 좁아진다. head_tracking은 "가까이 있는 공만 추적"하려고 더 좁은 크기 윈도우를 쓴다 — 너무 가까운 공(50%)이나 너무 멀어서 점처럼 보이는 공(0.1%)을 배제.

### Source: `robotis/Linux/project/tutorial/camera/config.ini`

```ini
[Camera]
Brightness  = -1    # reset value
Contrast    = -1    # reset value
Saturation  = -1    # reset value
Gain        = 255
Exposure    = 1000
```

(이 튜토리얼은 색 검출 없음 — 카메라 파라미터 시연 전용)

### Source: 데모 (`robotis/Linux/project/demo/main.cpp`) — config.ini 디스크에 없음

데모 바이너리는 `../../../Data/config.ini` (즉 `robotis/Data/config.ini`)에서 ini를 읽지만, **공장 트리에는 이 파일이 동봉되지 않는다**. 사용자가 GUI(Roboplus / 웹 UI)에서 튜닝하면 그때 처음 생성된다. 그래서 데모 코드 자체가 fallback constructor에 디폴트를 박아놨다:

| Finder | Hue | Hue tol | Min sat | Min val | Min % | Max % | 추정 색상 |
|---|---|---|---|---|---|---|---|
| `ball_finder` | 356 | 15 | 50 | 10 | 0.07 | 30.0 | 주황 공 (ColorFinder() 디폴트 생성자) |
| `red_finder`  | 0   | 15 | 45 | 0  | 0.3  | 50.0 | 빨강 |
| `yellow_finder` | 60 | 15 | 45 | 0  | 0.3  | 50.0 | 노랑 |
| `blue_finder` | 225 | 15 | 45 | 0  | 0.3  | 50.0 | 파랑 |

(`Framework/src/vision/ColorFinder.cpp` Line 15-25 + `demo/main.cpp` Line 76-86)

`[Goal]`/`[Field]`/`[Line]` 섹션은 — **반복**하지만 — 펌웨어 어디에도 없다. 골 검출/필드 라인 검출은 이 SDK 버전에 미구현이다.

---

## Ball detection

### 알고리즘 (centroid 누적)

`Framework/src/vision/ColorFinder.cpp::GetPosition` (Line 128-162):

```cpp
Point2D& ColorFinder::GetPosition(Image* hsv_img)
{
    int sum_x = 0, sum_y = 0, count = 0;

    Filtering(hsv_img);              // HSV → binary mask m_result

    ImgProcess::Erosion(m_result);   // 3x3 AND (noise 제거)
    ImgProcess::Dilation(m_result);  // 3x3 OR  (구멍 메우기)

    for(int y = 0; y < m_result->m_Height; y++)
        for(int x = 0; x < m_result->m_Width; x++)
            if(m_result->m_ImageData[m_result->m_Width * y + x] > 0)
            { sum_x += x; sum_y += y; count++; }

    if(count <= (hsv_img->m_NumberOfPixels * m_min_percent / 100) ||
       count >  (hsv_img->m_NumberOfPixels * m_max_percent / 100))
    {
        m_center_point.X = -1.0;     // sentinel: not found
        m_center_point.Y = -1.0;
    }
    else
    {
        m_center_point.X = sum_x / count;
        m_center_point.Y = sum_y / count;
    }
    return m_center_point;
}
```

요약: **HSV 임계 → 1픽셀 erosion → 1픽셀 dilation → on 픽셀들의 평균 좌표 (centroid)**. Hough/blob clustering/contour 같은 건 없다. 만약 같은 색이 화면에 두 군데 있으면 centroid는 그 둘 사이 중간으로 잘못 잡힌다 (알려진 한계).

### 출력 좌표 → 카메라각 변환

`Framework/src/vision/BallTracker.cpp::SearchAndTracking` Line 115-120 — pixel → degrees:

```cpp
Point2D center = Point2D(Camera::WIDTH/2, Camera::HEIGHT/2);  // (160, 120)
Point2D offset = pos - center;
offset *= -1;                                                 // 축 반전
offset.X *= (Camera::VIEW_H_ANGLE / (double)Camera::WIDTH);   // 58°/320 ≈ 0.18°/px
offset.Y *= (Camera::VIEW_V_ANGLE / (double)Camera::HEIGHT);  // 46°/240 ≈ 0.19°/px
ball_position = offset;
Head::GetInstance()->MoveTracking(ball_position);
```

**거리 추정은 없다.** Mono-camera 단안이고 ball의 known size 기반 distance estimation 코드는 부재. `BallFollower`가 "tilt 각도가 bottom limit에 닿았는지"로 "공이 발 앞까지 왔는지"를 간접적으로만 판단 (BallFollower.cpp Line 95).

### Tuning parameters — BallTracker

`Framework/include/BallTracker.h`:

```cpp
static const int NoBallMaxCount = 15, NotFoundMaxCount = 100;
static const double TiltTopLimit = 25, TiltBottomLimit = -12, PanLimit = 65;
```

- `NoBallMaxCount=15` — 15프레임 연속 미검출 시 머리 탐색 모드 진입
- `NotFoundMaxCount=100` — 100프레임(약 3초) 미검출 시 `-1` 반환 (search 포기)
- `TiltTopLimit=25°` / `TiltBottomLimit=-12°` — 머리 tilt 범위 (수평~발끝)
- `PanLimit=65°` — 좌우 회전 한계

### Tuning parameters — BallFollower

`Framework/src/vision/BallFollower.cpp` 생성자 (Line 21-46):

```cpp
m_NoBallMaxCount   = 10;
m_KickBallMaxCount = 10;
m_KickTopAngle     = -5.0;    // tilt 각도 below this = 공이 발 앞
m_KickRightAngle   = -30.0;   // pan 범위
m_KickLeftAngle    =  30.0;
m_FollowMaxFBStep  = 30.0;    // 전진 보폭 최대
m_FollowMinFBStep  =  5.0;
m_FollowMaxRLTurn  = 35.0;    // 회전 최대각/걸음
m_FitFBStep        =  3.0;    // 킥 직전 미세조정 보폭
m_FitMaxRLTurn     = 35.0;
m_UnitFBStep       =  0.3;    // 보폭 가속도
m_UnitRLTurn       =  1.0;
```

상태머신:

1. ball 미검출 → 머리 home으로 → 정지
2. ball 검출 + pan 범위 밖 → 제자리 회전만 (FBStep=0)
3. ball 검출 + pan 범위 내 + tilt 위 → 전진 추적 (FOLLOW)
4. ball 검출 + tilt 바닥 + Y > KickTopAngle → 미세조정 (FIT)
5. ball 검출 + tilt 바닥 + Y < KickTopAngle → 10프레임 카운트 후 KICK (좌/우 결정은 pan 부호)

---

## Goal detection

**미구현.** 공장 펌웨어에는 골/필드/라인 검출 코드가 없다. 데모(`SOCCER` mode)는 공을 향해 걸어가서 킥하는 것까지만 한다 — 골을 향해 정렬하는 로직은 없다 (다른 색 인스턴스를 추가로 만들어 동일한 ColorFinder centroid를 사용하면 되지만, 출하 펌웨어는 그 코드를 포함하지 않는다).

`VisionMode`(`Linux/project/demo/VisionMode.cpp`)는 "골 검출"이 아니라 **인터랙티브 색 인식 데모** — 빨강/노랑/파랑 색 카드를 보여주면 motion + mp3로 반응:

| 색 조합 | Action ID | MP3 |
|---|---|---|
| RED         | 4  | Thank you.mp3 |
| YELLOW      | 41 | Introduction.mp3 |
| BLUE        | 24 | Wow.mp3 |
| RED+YELLOW  | 38 | Bye bye.mp3 |
| RED+BLUE    | 54 | Clap please.mp3 |
| BLUE+YELLOW | 15→1 | Sit down → Stand up.mp3 |
| ALL         | 27 | Oops.mp3 |

(`Linux/project/demo/VisionMode.cpp` Line 31-65)

---

## Image processing pipeline

### 풀 파이프라인 (한 프레임당)

```
V4L2 YUYV mmap buffer (320×240, 4 bytes/2px)
    │
    ▼ ImgProcess::HFlipYUV  (좌우 뒤집기 — 카메라 거꾸로 장착)
    │
    ▼ ImgProcess::VFlipYUV  (상하 뒤집기)
    │
    ▼ ImgProcess::YUVtoRGB  (YUYV → RGB, 320×240×3)
    │   r = (y + 359*v) >> 8
    │   g = (y -  88*u - 183*v) >> 8
    │   b = (y + 454*u) >> 8
    │
    ▼ ImgProcess::RGBtoHSV  (RGB → HSV, 320×240×4)
    │   H: 0~360 (16-bit, 상위/하위 바이트 분리)
    │   S: 0~100 (8-bit, *100/255)
    │   V: 0~100 (8-bit, *100/255)
    │
    ▼ ColorFinder::Filtering  (HSV → binary mask, 320×240×1)
    │   if S > m_min_saturation AND V > m_min_value
    │       AND H in [hue ± tol]:
    │       mask[i] = 1
    │
    ▼ ImgProcess::Erosion   (3x3 AND, 노이즈 제거)
    │
    ▼ ImgProcess::Dilation  (3x3 OR, 구멍 메우기)
    │
    ▼ ColorFinder centroid  (on 픽셀들의 평균 (x, y))
    │   percent gate: count / total ∈ [min_percent, max_percent] / 100
    │
    ▼ BallTracker            (pixel → camera angle → Head::MoveTracking)
    │
    ▼ BallFollower           (pan/tilt → 보행 명령)
    │
    ▼ mjpg_streamer.send_image  (RGB 또는 YUV → JPEG quality 80 → HTTP/8080)
```

**해상도는 모든 단계에서 320×240 유지** — 다운샘플링/피라미드 없음.

### 모폴로지 디테일

`ImgProcess.cpp::Erosion/Dilation` Line 109-206 — 3x3 SE의 9픽셀 AND (erosion) / OR (dilation)를 unsigned char로 직접 비트 연산:

```cpp
// Erosion
temp_img[y*W+x] = img[(y-1)*W+(x-1)] & img[(y-1)*W+x] & img[(y-1)*W+(x+1)]
                & img[y*W+(x-1)]     & img[y*W+x]     & img[y*W+(x+1)]
                & img[(y+1)*W+(x-1)] & img[(y+1)*W+x] & img[(y+1)*W+(x+1)];

// Dilation: AND → OR
```

각 1회씩만 적용 — opening (erode then dilate) 1회 효과. 큰 노이즈는 못 잡는다.

---

## MJPG streamer

### Build path

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/streamer/`

| 파일 | 역할 |
|---|---|
| `mjpg_streamer.cpp` (3,594 B) | thin C++ wrapper, 외부 send_image API |
| `mjpg_streamer.h` (914 B) | mjpg_streamer 클래스 선언 |
| `httpd.cpp` (40,460 B) | HTTP/1.0 server, multipart MJPEG response, ?action 라우팅 |
| `httpd.h` (10,954 B) | globals/context 구조체, ball_finder/red_finder 등 정적 멤버 |
| `jpeg_utils.cpp` (6,636 B) | libjpeg-turbo wrapper, RGB/YUYV → JPEG (quality 80) |
| `jpeg_utils.h` (1,091 B) | API |

[mjpg-streamer](https://github.com/jacksonliam/mjpg-streamer) 프로젝트의 fork — ROBOTIS가 in-tree로 imported.

### Default port

`Linux/build/streamer/mjpg_streamer.cpp` Line 37 (and Line 62):

```cpp
server.conf.port = htons(8080);    // TCP 8080, 하드코딩
```

CLI/ini 노출 없음. 동시 연결 처리: `pthread_create` per client connection.

### HTTP routes

`httpd.cpp` Line 892-944:

| Route | Action |
|---|---|
| `GET /?action=snapshot` | 단일 JPEG 한 장 |
| `GET /?action=stream` | multipart/x-mixed-replace MJPEG 스트림 |
| `GET /?action=command&command=<cmd>` | httpd::ball_finder/red_finder/yellow_finder/blue_finder 파라미터 조정 (영숫자 + `_-=&.`만 허용, 길이 ≤ 100) |
| `GET /<path>` | `./www/` 정적 파일 (index.html, functions.js, favicon.ico) |

### HTML interface

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/www/index.html` (16,880 B):

- 타이틀: "DARwIn-OP Demo"
- 메뉴: 탭(`extendmenu`) 기반 컨트롤 패널 (head pan/tilt, ColorFinder hue 슬라이더)
- 키보드 단축키 (화살표/스페이스) — 코드 상에서는 주석 처리되어 있음
- `AJAX_get('/?action=command&command=...')`로 비동기 명령 전송
- MJPEG stream 임베드: `<img src="/?action=stream">`

데모 바이너리(`./demo`)를 실행하면 자동으로 `./www/`를 server root로 마운트한다 (`mjpg_streamer.cpp` Line 17: `#define WWW_FOLDER "./www/"`).

### 메모리/스레딩 디테일

- 글로벌 더블 버퍼 (`globals.buf`) + `pthread_mutex_t db` + `pthread_cond_t db_update` — 캡처 스레드가 frame 갱신 시 broadcast, HTTP 응답 스레드는 wait
- `send_image()`는 `httpd::ClientRequest == true`일 때만 JPEG 인코딩 (idle CPU 절약)
- `compress_yuyv_to_jpeg` / `compress_rgb_to_jpeg`, JPEG **quality 80** 고정

---

## What this means for Darwin

### 현재 상태

Darwin 프로젝트는 이미 Rust 비전 스켈레톤을 가지고 있다 (확인됨):

```
/Users/bbikiming/Documents/vibe_coding/Darwin/app/core/forge-core/src/vision/
├── mod.rs           // 모듈 진입점, "Sprint 6 MVP"
├── frame.rs         // Frame/Pixel 타입
└── segmentation.rs  // detect_blob, HsvRange
```

`mod.rs` 헤더 코멘트: *"카메라 캡처는 Mac AVFoundation에서 이뤄지므로 우리 Rust 코어는 이미지 처리 알고리즘만 담당. RGBA → HSV 변환, 색 segmentation, 단순 blob detection."*

→ **이미 방향이 ROBOTIS-OP2 파이프라인과 정확히 일치한다.** ROBOTIS의 V4L2 캡처 부분은 macOS에서 무의미하지만 (AVFoundation으로 대체), HSV segmentation + erosion/dilation + centroid 알고리즘은 그대로 이식 가능.

### 무엇을 가져와야 하나

1. **HSV threshold + percent gate 모델** — `ColorFinder`의 (hue, hue_tol, min_sat, min_val, min_pct, max_pct) 6-튜플은 **검증된 RoboCup 표준**. 이 표현을 Rust struct로 그대로 가져오는 게 출발점.

2. **3×3 Erosion + Dilation** — 50줄짜리 알고리즘. `imageproc` crate에 이미 있지만, ROBOTIS 코드처럼 binary mask로 단순화하면 더 빠르다. `app/core/forge-core/src/vision/segmentation.rs`에 morphology 모듈 추가.

3. **Centroid 누적** — 사실상 4줄짜리 알고리즘. 단점도 함께 이식: 같은 색 두 군데면 centroid가 사이에 떨어진다. 이는 mid-term에 **connected-component labeling**으로 업그레이드해야 한다 (RoboCup 2014년 이후 표준).

4. **카메라각 변환 공식** — `BallTracker.cpp` Line 115-120의 pixel → degrees 매핑. Darwin은 카메라 시야각(VIEW_H_ANGLE=58°, VIEW_V_ANGLE=46°)만 알면 동일하게 적용 가능.

5. **Default thresholds (orange ball)** — `hue=355, tol=15, min_sat=60, min_val=15, min_pct=0.1, max_pct=50.0`은 RoboCup orange ball에 검증된 값. **튜닝 시작점**으로 그대로 사용 가능.

### 무엇을 가져오지 말아야 하나

- **YUYV → RGB → HSV 손코딩 변환** — `image`/`palette` crate 사용.
- **3색 동시 인식 → 인터랙티브 데모 (`VisionMode`)** — 데모로서는 재미있지만 Darwin의 사용 시나리오와 다름.
- **mjpg_streamer (in-tree fork)** — Mac에서는 macOS AVFoundation + `axum`/`actix-web` MJPEG 응답이 더 간결.
- **`[Goal]`/`[Field]`/`[Line]` 섹션** — 존재하지 않으니 가져올 게 없다.

### 이게 RoboCup-specific인가? — 절반은 그렇다

- **Orange ball (hue 355) / yellow goal post / blue field**은 RoboCup Soccer Humanoid League 컬러 컨벤션.
- **그러나** ColorFinder 자체는 RoboCup-specific이 아니라 **임의의 HSV 색을 추적하는 범용 모듈**이다. 빨강 큐브, 노랑 마커, 파란 옷 — 어떤 색이든 hue 값만 바꿔 추적 가능.
- Darwin의 사용 시나리오(예: "사람이 들고 있는 물체를 추적", "AR 마커 인식", "특정 색 카드로 트리거")에 그대로 응용 가능하며, 시작 임계값으로 ROBOTIS factory thresholds를 사용하면 즉시 동작한다.

### Rust 포트 경로 제안

기존 `app/core/forge-core/src/vision/` 구조를 확장:

```
app/core/forge-core/src/vision/
├── mod.rs               (이미 있음) 모듈 진입점 + re-export
├── frame.rs             (이미 있음) Frame { width, height, data: Vec<u8>, pixel_size }
├── segmentation.rs      (이미 있음) HsvRange, detect_blob → 확장
├── color_finder.rs      (신규)   ColorFinder { hue, tol, min_sat, min_val, min_pct, max_pct }
│                                 fn find(&self, frame_hsv) -> Option<Point2D>
├── morphology.rs        (신규)   erode_3x3(mask) / dilate_3x3(mask) 함수
├── transforms.rs        (신규)   yuyv_to_rgb, rgb_to_hsv (image crate 사용)
└── tracker.rs           (신규)   pixel_to_camera_angle(p, fov) + BallTracker 상태머신
```

추가로 `app/core/forge-core/src/vision/presets.rs` — RoboCup 임계값을 const로:

```rust
pub const ORANGE_BALL: ColorFinder = ColorFinder {
    hue: 355, hue_tolerance: 15,
    min_saturation: 60, min_value: 15,
    min_percent: 0.1, max_percent: 50.0,
};
pub const RED:    ColorFinder = ColorFinder { hue: 0,   hue_tolerance: 15, min_saturation: 45, min_value: 0, min_percent: 0.3, max_percent: 50.0 };
pub const YELLOW: ColorFinder = ColorFinder { hue: 60,  hue_tolerance: 15, min_saturation: 45, min_value: 0, min_percent: 0.3, max_percent: 50.0 };
pub const BLUE:   ColorFinder = ColorFinder { hue: 225, hue_tolerance: 15, min_saturation: 45, min_value: 0, min_percent: 0.3, max_percent: 50.0 };
```

→ ROBOTIS factory defaults를 그대로 const화해서 Darwin이 "out of the box"로 색 인식 가능.

### Sprint plan 제안 (2주 estimate)

- **Day 1-2**: `transforms.rs` (RGBA from AVFoundation → HSV) + 유닛 테스트
- **Day 3-4**: `color_finder.rs` + `morphology.rs` + property-based tests (single bright pixel → mask = 1)
- **Day 5-6**: `tracker.rs` pixel-to-angle 변환 + integration test (synthetic frame → expected angle)
- **Day 7-8**: AVFoundation FFI bridge (이미 있다면 skip) → live preview
- **Day 9-10**: SwiftUI Studio에 hue 슬라이더 + mask overlay UI (mjpg-streamer HTML interface의 모던 등가물)

---

## Evidence

인용한 모든 경로 (모두 절대 경로):

### 핵심 소스 (Framework)
1. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Camera.h` — 320×240, FOV 58°×46°
2. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/ColorFinder.h` — hue/sat/val + percent gate 모델
3. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/BallFollower.h` — pan/tilt → walk 명령
4. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/BallTracker.h` — search/track 상태머신
5. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Image.h` — YUV/RGB/HSV/BGRA 4중 FrameBuffer
6. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/ImgProcess.h` — color conversion + morphology API
7. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/vision/Camera.cpp` — width/height 정의
8. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/vision/ColorFinder.cpp` — hue wrap-around, centroid, percent gate
9. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/vision/BallFollower.cpp` — 상태머신 (NoBall/Follow/Fit/Kick) tuning 상수
10. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/vision/BallTracker.cpp` — pixel → camera angle 변환
11. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/vision/ImgProcess.cpp` — YUVtoRGB, RGBtoHSV, Erosion, Dilation, HFlip/VFlip
12. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/vision/Image.cpp` — Frame buffer construction

### Linux/V4L2/streamer
13. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxCamera.h` — CameraSettings struct
14. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/LinuxCamera.cpp` — V4L2 mmap, /dev/video0, YUYV, 30 FPS, auto-control disable
15. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/streamer/mjpg_streamer.cpp` — port 8080, www folder, pthread server
16. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/streamer/mjpg_streamer.h` — context/globals 멤버
17. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/streamer/httpd.cpp` — `?action=snapshot|stream|command` 라우팅
18. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/www/index.html` — DARwIn-OP Demo HTML 인터페이스

### Config & demo apps
19. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/color_filtering/config.ini` — [Find Color] hue=355
20. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/head_tracking/config.ini` — 좁은 percent window
21. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/camera/config.ini` — Gain=255, Exposure=1000
22. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/color_filtering/main.cpp` — minimal ColorFinder usage example
23. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp` — 4-color ball/red/yellow/blue, SOCCER/VISION/MOTION/READY modes
24. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/VisionMode.cpp` — color-card interaction state machine
25. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/VisionMode.h` — RED/YELLOW/BLUE bitflag

### 부재 확인 (negative evidence)
- `robotis/Linux/project/demo/config.ini` — **존재하지 않음** (런타임에 생성)
- `robotis/Data/config.ini` — **존재하지 않음** (사용자가 튜닝하면서 생성)
- `[Goal]` / `[Field]` / `[Line]` 섹션 — **펌웨어 어디에도 없음** (find/grep으로 검증)
