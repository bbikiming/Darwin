# RoboPlus Action — 휴머노이드 모션 저작 도구

## 한 줄 소개

ROBOTIS의 Windows-전용 GUI 모션 에디터. DARwIn-OP / Bioloid / OP3 호환.
Page/Step 모델의 원조.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 개발사 | ROBOTIS Co., Ltd. |
| 플랫폼 | Windows (32-bit, XP~10) ⚠️ macOS 미지원 |
| 라이선스 | 독점 (무료 배포) |
| 파일 포맷 | `.mtn` (텍스트) + `motion_4096.bin` (CM 메모리 이미지) |
| 통신 | USB 직결 (FTDI) → CM-510/CM-530/CM-700/**CM-730/CM-740** |
| 후속 | R+ Motion (모바일, 단순화) — 데스크톱 후속 부재 |

## UI / UX 분석

### 메인 창

```
┌─────────────────────────────────────────────────────────┐
│  Menubar                                                 │
├──────────┬──────────────────────────────────────────────┤
│  Page    │  Step Table (한 page의 step들)               │
│  List    │   No │ ID 1 │ ID 2 │ … │ Pause │ Play │ Opt │
│  (1..256)│   1  │ 2048 │ 1500 │ … │   0   │  32  │ ... │
│          │   2  │ 2050 │ 1500 │ … │   4   │  16  │     │
│          │   …                                          │
│          │                                              │
├──────────┼──────────────────────────────────────────────┤
│  3D      │  Compliance Slider per joint (0..7)          │
│  Pose    │   ID 1: ████████░░  5                        │
│  Preview │   ID 2: ██████░░░░  3                        │
│          │   …                                          │
└──────────┴──────────────────────────────────────────────┘
```

### 핵심 인터랙션

1. **Page 메타데이터** — name (14자), Next Page, Exit Page, Repeat, Speed.
2. **Step 추가** — 한 행에 31개 관절 + 시간 + 옵션을 입력.
3. **모터 토크 OFF + 사람이 자세 잡기 + "Get Pose"** ★
   - Step의 모든 관절 위치를 현재 실 로봇 상태에서 한 번에 가져옴.
   - 우리가 가장 차용해야 할 흐름 — 비전문가가 모션 만들 때 천재적.
4. **재생** — Page/Step 단위로 실 로봇에 재생.
5. **외부 파일 import/export** — `.mtn` 텍스트.

### 단축키 (확인 필요)

- F5 — 모션 재생 (선택된 Page)
- Ctrl + G — Get Pose (현재 자세 캡처)
- Ctrl + S — 저장

## DarwinForge 적용 — 이미 채택

✅ Page/Step 데이터 모델 → `forge-core::motion::page::{MotionPage, MotionStep}`
✅ `.mtn` 텍스트 round-trip → `parse_mtn / write_mtn`
✅ Compliance 0..7 — `MotionPage.compliance: [u8; 31]`

## DarwinForge 적용 — 미채택 (차용 후보)

### ★ 1순위 — Get Pose 흐름

```swift
// app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/CapturePoseButton.swift
struct CapturePoseButton: View {
    @EnvironmentObject var store: ConnectionStore

    var body: some View {
        Button {
            Task { await capturePose() }
        } label: {
            Label("현재 자세 캡처", systemImage: "camera.viewfinder")
        }
        .help("토크 OFF 후 손으로 자세를 잡고 클릭")
    }

    private func capturePose() async {
        guard let bus = store.bus else { return }
        var positions: [UInt16] = Array(repeating: 2048, count: 31)
        for j in JointID.allCases {
            if let s = try? bus.readState(j) {
                positions[Int(j.rawValue)] = s.presentPosition
            }
        }
        // ConversationView에 capture 메시지 추가
        // 또는 MotionLibraryView의 새 step 행에 직접 입력
    }
}
```

### ★ 2순위 — Step Table 그리드 편집

`MotionLibraryView`에 페이지 디테일을 열면 31×N 그리드로 직접 편집 가능.
SwiftUI `Table`로 충분.

### ★ 3순위 — 3D 자세 미리보기

3D 모델 (URDF) + SceneKit으로 현재 step의 자세 시각화.
`HumaRobotics/darwin_description` URDF + 메시(STL) 활용.

## 출처

- RoboPlus 다운로드: https://www.robotis.us/robotplus/
- 매뉴얼 (구 wiki): http://support.robotis.com/en/software/roboplus/roboplus_motion_main.htm
- Action 파일 포맷 분석 (커뮤니티): research/SURVEY.md 참조
