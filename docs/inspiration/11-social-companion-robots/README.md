# 11. 소셜 / 돌봄 / 교육 로봇 — 따뜻함 패턴 인덱스

> 작성일: 2026-05-10
> DarwinForge가 macOS에서 ROBOTIS DARwIn-OP/OP2를 자연어로 조종할 때
> 사용자에게 "차가운 명령어 인터프리터"가 아닌 "친근한 동료"의 인상을
> 주기 위해, 지난 12년간 시장에 등장했던 가정용 / 시니어케어 / 교육용
> 소셜 로봇의 UX·표정·음성·실패 패턴을 정리한다.
>
> 인용은 모든 항목 끝에 출처 URL을 둠. 미확인은 "확인 필요" 표기.
> 우리 차용 후보는 ★ 박스로 강조.

## 디렉토리 구성

| 파일 | 핵심 주제 | 분량 |
|------|-----------|------|
| [01-jibo-vector-cozmo-anki.md](01-jibo-vector-cozmo-anki.md) | Anki 3대 (Cozmo / Vector / Drive) + Jibo 실패 케이스 스터디 | ~1500 단어 |
| [02-loona-eilik-aibo-misty.md](02-loona-eilik-aibo-misty.md) | Loona / Eilik / Aibo / Misty II — 표정·SDK·강화학습 | ~1500 단어 |
| [03-care-and-education.md](03-care-and-education.md) | Paro / ElliQ / Stevie 시니어케어 + LEGO / Sphero / mBot 교육 | ~1500 단어 |
| [04-darwinforge-warmth-patterns.md](04-darwinforge-warmth-patterns.md) | 위 패턴을 SwiftUI / Rust 코드로 매핑 — 차용 가이드 | ~1500 단어 |

## 카테고리별 비교표

### 가) 가정용 소셜 로봇

| 로봇 | 제조사 | 출시 | 가격 (USD) | 핵심 강점 | 상태 (2026-05) | 차용도 |
|------|--------|------|-----------|----------|----------------|--------|
| **Jibo** | Jibo Inc. (MIT spin-off) | 2017 | $899 | "최초의 가정용 소셜 로봇" 마케팅 | 2019.03 클라우드 종료 (사망) | ★ (실패 사례) |
| **Cozmo** | Anki | 2016 | $179 | Pixar 출신 애니메이터 표정, 1000+ 애니메이션 | 2019 폐업 → DDL 인수 후 일부 부활 | ★★★ |
| **Vector** | Anki | 2018 | $249 | 항상-온, 클라우드 NLP, OLED 눈 | 2019 폐업 → DDL Vector 2.0 | ★★★ |
| **Loona** | KEYi Tech (中) | 2022 | $449 | 1000+ 표정, 3D ToF + LiDAR, OTA 학습 | 활발히 판매 중 | ★★★ |
| **Eilik** | Energize Lab (中) | 2022 | $169 | 데스크탑 미니, 4-감정 상태, EVE 영감 | 활발히 판매 중 | ★★ |
| **Aibo ERS-1000** | Sony | 2018 | $2,899 | 4세대, 강화학습 보행, 22-DOF | 일본/미국 활발 | ★★ |
| **Misty II** | Misty Robotics | 2019 | $3,200 | 개발자 키트, JS/.NET SDK | 활발 (B2B) | ★★ (SDK 패턴) |
| **EBO Air** | Enabot (中) | 2021 | $189 | 모바일 캠 + 펫 추적, 야간 시야 | 활발 | ★ |
| **Pepper** | SoftBank Robotics | 2014 | $25,000+ | 1.2 m 휴머노이드, 매장 안내 | 2021 생산 중단, 일부 운영 | ★ |
| **Buddy** | Blue Frog Robotics | 2015 (Indiegogo) | $1,499 | 가족 동반자 컨셉 | 자금난, 출하 미흡 | ★ (실패) |
| **Liku** | TOROOC (韓) | 2018 | 미공개 (B2B) | 5감정 OLED, 한국 시니어 디지털 교육 | 한국 시장 활발 | ★★ |

### 나) 돌봄 / 시니어케어

| 로봇 | 제조사 | 형태 | 핵심 강점 | 차용도 |
|------|--------|------|----------|--------|
| **Paro** | AIST 일본 | 물개 인형 (촉각·소리) | 치매환자 우울 / 불안 감소 임상 입증 | ★★★ |
| **ElliQ** | Intuition Robotics | 데스크탑 + 태블릿 | proactive 대화 시작, 95% 외로움 감소 사례 | ★★★ |
| **Stevie** | Akara Robotics (Trinity Dublin) | 1.5 m 휴머노이드 | 약 알림 + 영상 통화 + 가벼운 대화 | ★★ |
| **Aibo (시니어 모드)** | Sony | 강아지 | 일본 노인 동반자, 의료 인증 보류 | ★ |

### 다) 교육 STEM

| 로봇 | 제조사 | 연령 | 프로그래밍 환경 | 차용도 |
|------|--------|------|----------------|--------|
| **LEGO Spike Prime** | LEGO Education | 10~14세 | Word Blocks, MicroPython | ★★ (즉각 피드백 패턴) |
| **Sphero BOLT** | Sphero | 8세+ | Draw, Blocks, JS, Python | ★★ (3-tier 코딩 UX) |
| **Sphero Indi** | Sphero | 4세+ | 색카드 (스크린리스) | ★ |
| **mBot** | Makeblock | 6~12세 | mBlock (Scratch), Arduino | ★ |
| **OzoBot** | Evollve | 6세+ | OzoBlockly + 색마커 | ★ |
| **Cubetto** | Primo Toys | 3~6세 | 나무 블록 (스크린리스) | ★ |
| **Kibo** | KinderLab Robotics | 4~7세 | 물리 블록 (스캔) | ★ |

## DarwinForge가 차용 가능한 따뜻함 패턴 — 5선

### 1순위 ★★★ "Pixar Eyes" — Cozmo / Vector OLED 눈
- **출처**: Carlos Baena (전 Pixar / WALL-E 애니메이터) → Cozmo 캐릭터 디렉터
- **핵심**: 동공 / 눈썹 없이 **두 개의 둥근 도형의 비율·곡률·offset**만으로 감정 표현
- **DarwinForge 매핑**: DARwIn-OP의 머리 LED 2개를 RGB565로 색·점멸·페이드 → "눈" 메타포
- → `04-darwinforge-warmth-patterns.md` §3 참조

### 1순위 ★★★ "Behavior Engine" — Cozmo Emotion Engine
- **출처**: Anki 자체 알고리즘, Pixar 애니메이션 파이프라인 차용
- **핵심**: 사용자 상호작용으로 진화하는 감정 상태 → 1000+ 애니메이션 라이브러리에서 emotional state + music soundtrack 매칭
- **DarwinForge 매핑**: idle 상태 / 작업 성공 / 작업 실패 / 안전 거부 4-state FSM + 음향 테마
- → `04-darwinforge-warmth-patterns.md` §5 참조

### 1순위 ★★★ "Warm Refusal" — Vector / ElliQ 거부 톤
- **출처**: Anki Cozmo (sad eyes + 낮은 음 톤 효과음) / ElliQ ("Sorry, I can't do that, but here's what I can do…")
- **핵심**: "지원하지 않습니다" → "미안해요, 이건 제가 할 수 없는 일이에요"
- **DarwinForge 매핑**: L1 Refusal / L4 HITL Reject 시 인격화 마크다운 표현
- → `04-darwinforge-warmth-patterns.md` §6 참조

### 2순위 ★★ "Idle Breathing" — Pepper / Loona / Aibo
- **출처**: Pepper의 micro-movement, Aibo의 idle scratch / yawn
- **핵심**: 사용자가 명령을 안 줄 때도 미세한 머리 움직임 / 호흡 효과음 → 살아있다는 느낌
- **DarwinForge 매핑**: Connection 상태에서 ±2° head yaw 사인파 + 30 s 주기 LED breath

### 2순위 ★★ "Achievement Sound" — 교육 로봇 (Sphero / Spike Prime / mBot)
- **출처**: Sphero Edu의 task-complete chime, LEGO Spike의 단계별 happy chord
- **핵심**: 모션 완료 / 시연 완료 / 안전 검증 통과 시 짧은 chord (300~500 ms)
- **DarwinForge 매핑**: macOS `NSSound` 또는 `AVAudioPlayer`로 `success.aiff` / `fail.aiff` / `safe-clip.aiff`

## 우리 현재 위치 (2026-05) — 따뜻함 게이지

DarwinForge가 이미 갖춘 패턴:
- ✅ 해요체 (토스 8원칙) — `"DARwIn-OP에 연결됐어요."`
- ✅ 안전 거부 메시지 (L1/L4) — 단, 톤이 사무적 → 인격화 보강 필요

후속 후보 (`04-darwinforge-warmth-patterns.md`에서 상세):
- ⏳ Behavior Engine 4-state FSM (idle / working / success / refusal)
- ⏳ DARwIn-OP head LED을 "눈" 메타포로 사용 — RGB + breath 패턴
- ⏳ Idle 상태 호흡 모션 (±2° yaw 사인파)
- ⏳ Achievement chime + voice fillers ("음…", "잠깐만요")
- ⏳ 인격화 거부 ("미안해요, 이 동작은 위험할 것 같아요")

## 핵심 교훈 — Jibo가 우리에게 남긴 4가지

1. **클라우드 의존을 최소화**: Jibo는 자체 서버 종료 시 즉사. DarwinForge는 LLM 호출 외 핵심 모션을 로컬 (Rust 코어) 에서 처리.
2. **가격 대비 명확한 가치**: $899 Jibo는 "예쁜 Alexa" 였음. 우리 가치 제안은 "DARwIn-OP 가진 사람을 위한 자연어 IDE".
3. **개발자 SDK 부재 = 죽음**: Jibo는 폐쇄형 SDK, 커뮤니티 형성 실패. 우리는 forge-mcp 서버화로 외부 에이전트 진입 허용.
4. **유료화 모델 없음**: Jibo는 일회성 구매. SaaS / 클라우드 연동 / 모션 마켓플레이스 없이 지속 비용 부담. — **확인 필요**: DarwinForge 비즈니스 모델은 본 자료 범위 외.

(상세: `01-jibo-vector-cozmo-anki.md` §3)

## 출처 (대표)

- Jibo 폐업: https://techcrunch.com/2019/03/04/the-lonely-death-of-jibo-the-social-robot/
- Cozmo 디자인: https://www.fastcompany.com/3061276/meet-cozmo-the-pixar-inspired-ai-powered-robot-that-feels
- Vector SDK: https://developer.anki.com/vector/docs/
- Loona: https://us.keyirobot.com/products/loona
- Aibo ERS-1000: https://helpguide.sony.net/aibo/ers1000/v1/en-us/contents/TP0001970096.html
- Paro: http://www.parorobots.com/
- ElliQ: https://elliq.com/
- Stevie: https://www.tcd.ie/news_events/articles/we-built-a-robot-care-assistant-for-elderly-people--heres-how-it-works/
- Misty II: https://docs.mistyrobotics.com/misty-ii/web-api/overview/
- Sphero BOLT: https://sphero.com/products/sphero-bolt
