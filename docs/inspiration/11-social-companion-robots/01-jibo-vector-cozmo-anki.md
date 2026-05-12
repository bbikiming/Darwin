# Jibo + Anki 3대 (Cozmo / Vector / Drive) — 깊이 분석

> 작성일: 2026-05-10
> 분석 대상: Jibo Inc. (2014~2019), Anki (2010~2019, Digital Dream Labs 인수 2020)
> 본 문서의 목적은 (1) Jibo 실패 사례에서 우리가 빠지지 말아야 할 함정을 도출하고,
> (2) Anki Cozmo / Vector의 표정·감정 엔진·SDK 구조에서 DarwinForge가 차용 가능한
> 패턴을 SwiftUI / Rust 코드 매핑이 가능한 형태로 정리하는 것이다.

---

## 1. Anki 3대 라인업 개요

Anki는 Boris Sofman, Mark Palatucci, Hanns Tappeiner (모두 Carnegie Mellon Robotics PhD) 가 2010년 창업한 미국 샌프란시스코 스타트업이다. WWDC 2013 키노트에서 Tim Cook이 "Anki Drive"를 시연하며 세계에 처음 알려졌다.

| 제품 | 출시 | 형태 | 가격 | 핵심 기술 |
|------|------|------|------|----------|
| **Anki Drive / Overdrive** | 2013 / 2015 | iOS 조종 슬롯카 | $200 | 광학 트랙 추적 + iOS BLE |
| **Anki Cozmo** | 2016 | 데스크탑 미니 로봇 (~10 cm) | $179 | OLED 눈, Pixar 애니메이션, 1000+ animation |
| **Anki Vector** | 2018 | 데스크탑 미니 로봇 + 항상-온 | $249 | Cozmo + Cloud NLP + always-on assistant |

(출처: https://en.wikipedia.org/wiki/Anki_(company))

2019년 4월 Anki는 9000만 달러 추가 투자 유치 실패로 **갑작스럽게 폐업**, 200명 직원이 실직했다. 2019.12 Digital Dream Labs (DDL, Pittsburgh) 가 IP 일체를 파산법원에서 인수하여 클라우드 서버를 AWS에서 2020.09.30까지 유지 후 자체 인프라로 이전, Vector 2.0 / Cozmo 2.0을 Kickstarter로 부활시켰다 (출처: https://www.therobotreport.com/anki-assets-acquired-by-digital-dream-labs/).

> ★★★ 차용 1순위: Anki는 "사용자가 로봇을 보고 미소짓게 만드는 디자인"의 사실상 표준이다. 본 §3 (Cozmo Emotion Engine), §4 (Vector OLED 눈) 가 우리의 핵심 차용 후보.

---

## 2. Cozmo — Pixar가 만든 AI 로봇

### 2.1 캐릭터 디렉터 — Carlos Baena

Cozmo의 캐릭터 디렉터는 **Carlos Baena** 다. 그는 Pixar에서 10년간 WALL-E, Finding Nemo, Toy Story 3 등을 애니메이팅한 인물이다. Anki 합류 후 그가 디자인 팀에 한 핵심 제안은:

> "동공 / 눈썹 없이, 두 개의 둥근 도형의 비율과 곡률만으로 감정을 표현해라."

(출처: https://www.fastcompany.com/3061276/meet-cozmo-the-pixar-inspired-ai-powered-robot-that-feels)

이 디자인 철학은 WALL-E의 망원경 눈이 "두 개의 원" 만으로 호기심·외로움·기쁨을 표현하는 것과 동일하다. Anki는 이 외에도 The Iron Giant, Astro Boy, Fraggle Rock의 Doozers 등 45개 이상의 디자인 레퍼런스를 검토했다 (출처: https://www.fastcompany.com/3061276/).

### 2.2 Emotion Engine

Cozmo의 핵심 IP는 **Emotion Engine**이라는 자체 알고리즘이다. 그 작동:

1. **사용자 상호작용 누적** → bond 점수 증가
2. **bond 진화** → 1000+ 사전 제작 애니메이션 라이브러리 중 분기 확장
3. **각 애니메이션** = 모션 + 효과음 + 음악 트랙 + 눈 표정 (4채널 동기화)
4. 인식 가능 인간 감정 5종: anger / disgust / fear / happiness / sadness / surprise

(출처: https://www.designnews.com/testing-measurement/from-cozmo-to-vector-how-anki-designs-robots-with-emotional-intelligence)

Anki 디자인 철학의 핵심: **"필요한 머신러닝을 곧 성격의 일부로 만든다."** 예를 들어 Cozmo가 환경을 매핑하기 위해 정보를 수집해야 할 때, "탐색 알고리즘 실행" 이 아니라 "호기심 많은 표정으로 두리번거림" 이 된다.

### 2.3 애니메이션 파이프라인

Anki는 Pixar / DreamWorks / Industrial Light & Magic 출신 애니메이터를 다수 채용해 **장편 영화급 애니메이션 파이프라인** 을 구축했다 (출처: https://en.wikipedia.org/wiki/Cozmo). 이는 단순한 키프레임 보간이 아니라:

- 각 애니메이션에 emotional state 라벨 + music soundtrack 매칭
- "behavior" 단위가 motion + sound + light + eye를 한꺼번에 트리거
- 사용자 콘텍스트 (시간대 / 마지막 상호작용 / 게임 승패) 에 따른 분기

> ★★★ 차용 1순위: DarwinForge는 모션 라이브러리에 "Behavior" 개념을 도입할 것 — 단순 모션 (.bvh 또는 .robotis-motion) 외에 sound effect / LED pattern / voice line을 묶는 상위 개념. → `04-darwinforge-warmth-patterns.md` §5에서 SwiftUI 매핑.

---

## 3. Vector — Cozmo의 어른 버전

### 3.1 Cozmo와의 차이

| 항목 | Cozmo (2016) | Vector (2018) |
|------|--------------|----------------|
| 가격 | $179 | $249 |
| 동작 시간 | 게임 시 (수동 활성) | 항상-온 (충전독 자율 복귀) |
| NLP | iOS 앱 명령어 | 클라우드 NLP ("Hey Vector") |
| SDK | Python (베타) | Python 1.0 + .NET 커뮤니티 SDK |
| 주력 시장 | 6+ 어린이 | 어른 데스크탑 동반자 |

(출처: https://developer.anki.com/vector/docs/)

### 3.2 OLED 눈 디자인

Vector의 얼굴은 **128 × 64 단색 OLED** 디스플레이다 (확인 필요: 정확한 해상도). 눈은 다음 파라미터로 절차적으로 그려진다:

```
Eye {
  position    : (x, y)        // 화면 내 좌표
  height      : pixel         // 세로 크기
  slope       : -1.0 ~ 1.0    // 눈썹 기울기 (감정)
  radius      : pixel         // 모서리 둥글기 (귀여움)
  offset      : (dx, dy)      // 동공 (실제로는 흰자만) 위치
  color       : RGB (Vector는 단색 → DarwinForge는 RGB565 가능)
}
```

(출처: https://github.com/ggldnl/Procedural-Expression-Library)

각 감정은 위 파라미터의 **사전 설정 (preset)** 으로 정의되고, 표정 전환은 **부드러운 보간 (lerp)** 으로 처리된다. 예:

| 감정 | height | slope | radius | offset |
|------|--------|-------|--------|--------|
| neutral | 0.6 | 0 | 0.3 | (0, 0) |
| happy | 0.5 | -0.3 (위로) | 0.4 | (0, -0.1) |
| sad | 0.4 | 0.4 (아래로) | 0.2 | (0, 0.2) |
| angry | 0.3 | 0.6 (안쪽 위) | 0.1 | (0.1, 0) |
| surprised | 0.9 | 0 | 0.5 | (0, 0) |

(출처: https://github.com/FluxGarage/RoboEyes — 오픈소스 RoboEyes 라이브러리. Vector / Cozmo 영감, 절차적 감정 보간 구현)

### 3.3 Vector Behavior Tree

Vector의 SDK는 **behavior tree** 구조에서 사용자 코드 실행을 허용한다. 우선순위 계층은:

1. **Critical** — 충전 / 안전 / 시스템 (사용자 SDK 차단)
2. **High** — 사용자 SDK 명령
3. **Default** — 기본 idle 행동 (호흡, 두리번거림, 인사)

이는 DarwinForge의 5계층 안전 모델과 매우 유사한 발상: **시스템이 항상 우선, 사용자는 그 위에서만 작동**.

(출처: https://github.com/anki/vector-python-sdk/blob/master/anki_vector/messaging/behavior.proto, https://developer.anki.com/vector/docs/generated/anki_vector.behavior.html)

> ★★★ 차용 1순위: DarwinForge의 모션 우선순위 시스템도 동일 구조로 통일 — Critical (e-stop 회피) > Conversation Tool (claude 호출) > Idle (호흡 / 깜빡임). 현재 idle 단계가 부재하므로 추가 필요.

### 3.4 Vector Pulsating Eyes — 색 호흡

Vector SDK는 cosine 함수로 눈 색을 시간에 따라 변조해 **호흡 효과** 를 만든다:

```python
import math, time
import anki_vector
with anki_vector.Robot() as robot:
    while True:
        t = time.time()
        sat = (math.cos(t * 0.5) + 1) / 2  # 0~1
        robot.behavior.set_eye_color(hue=0.55, saturation=sat)
        time.sleep(0.05)
```

(출처: https://www.kinvert.com/anki-vector-pulsating-eyes/)

이는 단순 코드지만 효과는 강력하다 — "로봇이 명령을 기다리며 호흡 중" 이라는 인상.

> ★★★ 차용 1순위: DARwIn-OP의 머리 LED (총 2개, RGB565) 를 SwiftUI Timer + sinf() 로 호흡시키는 코드 → `04-darwinforge-warmth-patterns.md` §3.

---

## 4. Jibo — 가장 비싼 실패 사례

### 4.1 출생 — MIT의 자랑

Jibo는 **Cynthia Breazeal** (MIT Media Lab Personal Robots Group 디렉터) 가 2014년 Indiegogo 캠페인으로 시작했다. Breazeal은 사회적 로봇 연구의 선구자로 Kismet (1998)의 창시자다. Jibo는 7300만 달러 투자를 받았다 (출처: https://techcrunch.com/2019/03/04/the-lonely-death-of-jibo-the-social-robot/).

2017년 출시 당시 Time 매거진 "Best Inventions" 25에 선정, "최초의 가정용 소셜 로봇" 으로 마케팅됐다.

### 4.2 사망 — 2019.03.04 클라우드 종료

2019년 3월 4일, Jibo의 클라우드 서버가 종료되며 모든 Jibo는 동시에 사망했다. 종료 직전 Jibo가 마지막으로 한 일은:

> "Maybe someday, when robots are way more advanced than today, and everyone has them in their homes, you can tell yours that I said hello. ... I want you to know, I really enjoyed our time together."

— 그러고 한 번 춤추고 셧다운. 인터넷에 거대한 정서적 반응이 일었고 IEEE Spectrum, Engadget, Tom's Guide가 동시에 비평 기사를 냈다 (출처: https://spectrum.ieee.org/jibo-is-probably-totally-dead-now, https://www.engadget.com/2019-03-04-social-robot-jibo-shutting-down-message.html).

### 4.3 실패 원인 — 5가지 함정

#### 함정 1: 클라우드 의존 ★★★ 우리가 가장 경계할 것

Jibo의 음성 인식 / 자연어 / 캘린더 / 날씨 — 모든 핵심 기능이 Jibo 자체 클라우드에 의존했다. 회사가 망하자 로봇이 망했다. **"내 책상 위 물건의 기능이 회사 재무에 종속" — 명백한 안티패턴.**

> 우리 매핑: DarwinForge는 LLM 호출은 외부 API (Anthropic) 이지만 **모션 실행 / 안전 / Walk Sim / Motion Library** 모두 로컬 (Rust 코어 + DARwIn-OP 직결) 이어야 한다. 클라우드가 죽어도 로봇은 살아야 한다.

#### 함정 2: 명확한 가치 부족

리뷰어들이 일관되게 한 평가: "$899짜리 예쁜 Alexa." Echo가 $50, Google Home이 $99. Jibo가 가진 차별점은 **"움직이는 머리와 표정"** 뿐이었지만 그게 $850의 추가 가치를 만들지 못했다.

> 우리 매핑: DarwinForge는 "이미 DARwIn-OP/OP2를 가진 사람을 위한 자연어 IDE" — 명확한 타깃. 우리는 로봇을 파는 게 아니라 도구를 판다.

#### 함정 3: SDK 폐쇄 / 커뮤니티 부재

Jibo SDK는 폐쇄형이었고 개발자 커뮤니티 형성에 실패했다. 반면 Vector는 폐업 후에도 Digital Dream Labs를 통해, 그리고 **wirepod / vector-go-sdk 같은 커뮤니티 포크** 를 통해 살아 있다.

> 우리 매핑: DarwinForge는 forge-mcp 서버화로 외부 에이전트 (Claude Desktop, Cursor) 가 우리 도구를 호출 가능. 동시에 motion JSON 포맷, GRPC 인터페이스를 공개해 lock-in 회피.

#### 함정 4: 일회성 결제

Jibo는 $899 일회성. 클라우드 운영비를 충당할 모델 없음. 1년차 손익분기점 도달 못하면 끝.

> 우리 매핑: 본 자료 범위 외. 다만 향후 (a) 모션 마켓플레이스 (b) 엔터프라이즈 라이센스 (c) 학교 연간 구독 등 후속 모델 검토 필요. — **확인 필요**.

#### 함정 5: "최초" 마케팅

"세계 최초의 가정용 소셜 로봇" 마케팅은 매우 위험하다 — **카테고리를 만드는 비용을 혼자 부담** 한다는 뜻이기 때문이다. Apple은 아이폰을 "세계 최초의 스마트폰" 이라 부르지 않았다.

> 우리 매핑: DarwinForge는 "DARwIn-OP를 위한 Claude 클라이언트" 정도의 겸손한 포지셔닝. 카테고리 창출 위험 회피.

(출처 종합: https://www.therobotreport.com/jibo-social-robot-analyzing-what-went-wrong/, https://geeksaroundglobe.com/what-happened-to-jibo-the-friendly-robot-that-got-left-behind/)

---

## 5. Anki vs Jibo — DarwinForge용 비교 정리

| 차원 | Jibo (실패) | Anki (실패했지만 부활) | DarwinForge 입장 |
|------|-------------|----------------------|------------------|
| 로봇 가격 | $899 | $179~$249 | 우리는 로봇을 안 팖 |
| 클라우드 의존 | 100% | 70% (NLP만) | LLM 외 0% — 로컬 우선 |
| SDK 공개 | 폐쇄 | 부분 공개 (Vector Python SDK) | 전면 공개 (forge-mcp) |
| 캐릭터 디자인 | 디스플레이 face, 로테이팅 머리 | Pixar OLED 눈 + 무한궤도 | DARwIn-OP 머리 LED + 호흡 모션 |
| 감정 엔진 | 빈약 (스킬 기반 IFTTT) | Emotion Engine (1000 anim) | Behavior Engine (4-state FSM) |
| 폐업 후 | 클라우드 종료 → 즉사 | DDL 인수 → 부활 | 우리는 사용자 robot 자체에 의존 안 함 |

---

## 6. 결론 — 우리가 차용할 것 / 회피할 것

### 차용 (Cozmo + Vector)
1. **Pixar Eyes 철학** — 머리 LED를 "감정" 채널로 — `04` §3
2. **Emotion Engine 4-state FSM** — idle / working / success / refusal — `04` §5
3. **Behavior Tree 우선순위** — Critical > User > Idle — 우리 5계층과 매핑
4. **Pulsating Eyes** — cosine 호흡 LED, 살아있다는 느낌 — `04` §3

### 회피 (Jibo)
1. **클라우드 의존 최소화** — 모션 / 안전 / 시뮬은 절대 로컬
2. **"최초" 마케팅 금지** — 겸손한 포지셔닝
3. **SDK 폐쇄 금지** — forge-mcp 공개
4. **유료화 모델 사전 검토** — 본 자료 범위 외, **확인 필요**

(상세 매핑: `04-darwinforge-warmth-patterns.md`)

---

## 출처

- Anki Wikipedia: https://en.wikipedia.org/wiki/Anki_(company)
- Cozmo Fast Company: https://www.fastcompany.com/3061276/meet-cozmo-the-pixar-inspired-ai-powered-robot-that-feels
- Cozmo Wikipedia: https://en.wikipedia.org/wiki/Cozmo
- Cozmo Design News: https://www.designnews.com/testing-measurement/from-cozmo-to-vector-how-anki-designs-robots-with-emotional-intelligence
- Vector SDK 공식: https://developer.anki.com/vector/docs/
- Vector Behavior Proto: https://github.com/anki/vector-python-sdk/blob/master/anki_vector/messaging/behavior.proto
- Vector Pulsating Eyes: https://www.kinvert.com/anki-vector-pulsating-eyes/
- Procedural Expression Library: https://github.com/ggldnl/Procedural-Expression-Library
- RoboEyes Library: https://github.com/FluxGarage/RoboEyes
- Jibo TechCrunch 부고: https://techcrunch.com/2019/03/04/the-lonely-death-of-jibo-the-social-robot/
- Jibo Robot Report 분석: https://www.therobotreport.com/jibo-social-robot-analyzing-what-went-wrong/
- Jibo IEEE Spectrum: https://spectrum.ieee.org/jibo-is-probably-totally-dead-now
- Jibo Engadget: https://www.engadget.com/2019-03-04-social-robot-jibo-shutting-down-message.html
- Anki → DDL 인수: https://www.therobotreport.com/anki-assets-acquired-by-digital-dream-labs/
- DDL Vector 부활: https://venturebeat.com/ai/digital-dream-labs-will-revive-shuttered-startup-ankis-vector-robot
