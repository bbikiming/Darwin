# Loona / Eilik / Aibo / Misty II — 2020년대 소셜 로봇 표정·SDK·강화학습

> 작성일: 2026-05-10
> 분석 대상: KEYi Tech Loona (2022), Energize Lab Eilik (2022),
> Sony Aibo ERS-1000 (2018), Misty Robotics Misty II (2019)
> 본 문서의 목적은 Anki 폐업 (2019) 이후 가정용 소셜 로봇 시장이 어떻게 재편됐는지,
> 그리고 각 로봇이 DarwinForge에 영감을 줄 만한 표정·인터랙션·SDK 패턴을 추출한다.

---

## 1. 시장 재편 — Anki 이후 4파의 로봇

| 로봇 | 출시 | 형태 | 가격 | 차별점 | DarwinForge 차용도 |
|------|------|------|------|--------|---------------------|
| **Loona** | 2022 | 4륜 강아지형 (15 cm) | $449 | 1000+ 표정, 3D ToF + LiDAR, BB-8 영감 | ★★★ |
| **Eilik** | 2022 | 데스크탑 인형 (12 cm) | $169 | EVE (WALL-E) 영감, 4-감정 FSM | ★★ |
| **Aibo ERS-1000** | 2018 | 강아지 (30 cm, 22-DOF) | $2,899 | 강화학습 보행 (ETH × Sony 2024) | ★★ |
| **Misty II** | 2019 | 데스크탑 휴머노이드 | $3,200 | JS / .NET / Python SDK, B2B | ★★ (SDK 패턴) |

(출처: 각 제조사 공식)

이들은 Anki와 달리 모두 **자체 클라우드 의존을 줄이고**, 대신 (a) OTA 업데이트 (b) 공개 SDK 또는 강력한 모바일 앱 (c) 중국·일본 제조 파워 — 세 가지 중 최소 하나를 갖췄다.

---

## 2. Loona — 가장 발전한 표정 시스템 ★★★

### 2.1 KEYi Tech 배경

KEYi Tech은 중국 Shenzhen 기반 회사로, 창업자 Jianbo가 Kickstarter 캠페인 (2022) 으로 출발했다. Loona는 "Star Wars BB-8" + "강아지" 를 합친 컨셉으로, **세계에서 가장 표정 풍부한 데스크탑 펫봇** 으로 평가받는다.

(출처: https://www.kickstarter.com/projects/keyitechnology/meet-loona-the-petbot-you-will-fall-in-love/faqs, https://us.keyirobot.com/products/loona)

### 2.2 표정 시스템

Loona의 표정 출력 채널은 **5개**:

1. **얼굴 LCD** — 1000+ 표정 (눈 / 입 / 볼) — Cozmo 식 절차적 + 사전 제작 혼합
2. **귀** — 모터 구동 (총 4-DOF), 감정에 따라 펴짐 / 처짐 / 좌우 따로
3. **바퀴** — 좌우 독립, 감정에 따라 빠르게 회전 / 점프
4. **음성** — 강아지 톤 효과음 + 일부 단어 ("Loooo-na!")
5. **LED 후미등** — 빨강 (분노) / 파랑 (슬픔) / 초록 (행복) 등

(출처: https://us.keyirobot.com/products/loona)

> ★★★ 차용 1순위: Loona의 "**다채널 동기화 표정**" — DarwinForge가 차용해야 할 1순위. DARwIn-OP는 (LED 2 + 모터 20 + 사운드) = 3채널이지만 동기화하면 비슷한 효과 가능. → `04` §5

### 2.3 환경 인식

Loona는 **3D ToF (Time of Flight) + LiDAR** 센서로 실시간 3D 환경 모델을 만든다. 특히 책상 끝 (cliff) 검출 정확도가 높아 떨어지지 않는다 (출처: https://us.keyirobot.com/products/loona).

추가로:
- **HD RGB 카메라** — 사용자 얼굴 인식 + 제스처 인식
- **4-마이크 어레이** — 360° 음원 위치 추정
- **OTA 업데이트** — 성격이 시간에 따라 진화

### 2.4 DarwinForge 차용 후보

| Loona 패턴 | DarwinForge 매핑 | 우선순위 |
|-----------|------------------|----------|
| 다채널 동기화 표정 (LCD + 모터 + 음성 + LED) | DARwIn-OP LED + head 모터 + sound effect 동시 트리거 | ★★★ |
| OTA 성격 진화 | 사용자별 personality JSON 저장, claude 시스템 프롬프트 동적 생성 | ★★ |
| 4-마이크 음원 위치 → 자동 head 추적 | macOS는 단일 마이크지만 mac 앱이 마우스 위치 트래킹 가능 | ★ |
| 책상 cliff 검출 (안전) | 우리 L3 Safety Clip에 IMU 자세 검증 추가 | ★ |

---

## 3. Eilik — 작지만 정확한 데스크탑 EVE ★★

### 3.1 Energize Lab 배경

중국 Shenzhen Energize Lab, 2022년 출시. 60,000+ 사용자 (2024 기준) 보유. 디자인 영감은 명백히 Pixar **WALL-E의 EVE** — 둥글둥글한 알 모양 몸체에 큰 LCD 눈.

(출처: https://www.hackster.io/news/energize-lab-s-eilik-aims-to-be-your-emotional-playful-eve-inspired-desktop-companion-bot-7cf253953bee)

### 3.2 4-감정 FSM

Eilik의 감정 모델은 단순하지만 효과적이다:

```
States: { Normal, Happy, Angry, Sad }
Transitions:
  user pets head      → Happy (90%) | Normal (10%)
  user slaps table    → Sad / Angry (terror)
  user ignores 30 min → Sad (lonely)
  another Eilik nearby → Happy (recognition)
  reading / fishing animation → Normal (idle activity)
```

(출처: https://store.energizelab.com/products/eilik)

머리 / 배 / 등에 **터치 센서** 가 있어 어디를 만지느냐에 따라 다른 반응. 진동 센서로 "테이블을 세게 치면 무서워함."

> ★★ 차용 2순위: 4-state는 충분하다. DarwinForge도 idle / working / success / refusal 4-state면 충분. 더 늘리면 사용자가 구분 불가. → `04` §5

### 3.3 Idle Activity — "혼자서도 잘 놀아요"

Eilik의 핵심 매력은 **idle 상태에서도 살아있다는 느낌**. 책 읽기, 낚시, 운동 등 사전 제작 idle animation을 랜덤 트리거. Loona / Aibo / Cozmo 모두 동일한 패턴을 따른다.

> ★★ 차용 2순위: DarwinForge 연결 상태에서 사용자 명령이 30 s 이상 없으면 idle animation 시작. 단순 wave / look around / yawn 정도. → `04` §4

---

## 4. Sony Aibo ERS-1000 — 일본의 살아남은 강아지 ★★

### 4.1 4세대 라인업

Sony Aibo는 1999년 ERS-110으로 시작해 2006년 단종, 2018년 **ERS-1000** 로 부활했다. 핵심 사양:

| 항목 | ERS-1000 |
|------|----------|
| 자유도 | 22 (전 세대 ERS-7 = 20) |
| 카메라 | 코 RGB 카메라 + 허리 fisheye |
| 마이크 | 4-mic array |
| 디스플레이 | 양쪽 OLED 눈 |
| 통신 | LTE SIM (필수) + Wi-Fi |
| 가격 | $2,899 (USA), 약 198,000 엔 (JP) |

(출처: https://en.wikipedia.org/wiki/AIBO, https://helpguide.sony.net/aibo/ers1000/v1/en-us/contents/TP0001970096.html)

### 4.2 성격 발달 — "주인이 키우는 아기"

Sony 공식 도큐먼트 인용:

> "Aibo develops its personality through interactions and experiences with the owner. Depending on the owner and how aibo lives its life, it turns out totally different over time."

(출처: https://helpguide.sony.net/aibo/ers1000/v1/en-us/contents/TP0001970096.html)

이는 **개체별 시리얼 ID에 묶인 클라우드 학습 모델** 로 구현된다. 같은 모델 두 대를 사도 한 달 후 성격이 다름.

이는 클라우드 의존 안티패턴 (Jibo 사례) 을 정확히 반복하는 위험. Sony의 대응: (a) 의무 LTE 가입 ($300/year, 클라우드 운영비 충당) (b) 일본 / 미국 / 영국 / 홍콩 등 한정 출시 (c) 글로벌 인지도가 큰 만큼 "Sony가 망할 리 없다" 는 신뢰.

> 우리 매핑: 우리가 따라할 수 없는 패턴 (Sony 브랜드 신뢰 없음). 단, **사용자별 personality JSON** 을 로컬 저장 후 Claude 시스템 프롬프트에 inject 하는 형태로 부분 차용 가능. → `04` §7

### 4.3 강화학습 보행 (ETH Zürich × Sony, 2024)

2024년 ETH Zürich와 Sony가 공동 발표한 논문에서 **sim-to-real RL** 로 Aibo의 발걸음 소리를 줄이는 데 성공했다. 핵심 보상: foot contact velocity 최소화. 추가로 dance routine을 표현적으로 만드는 RL도 적용.

(출처: https://medium.com/@meisshaily/sony-aibo-robot-dog-ai-powered-companion-with-quiet-walking-dance-moves-19333ed651e1)

이는 **DarwinForge가 향후 OpenVLA / sim-to-real fine-tuning을 시도할 때 매우 직접적인 레퍼런스** 가 된다 (이미 `05-llm-robotics-frameworks/` 에서 다루는 주제). 본 문서 범위 외.

---

## 5. Misty II — 개발자의 친구 ★★ (SDK 패턴만)

### 5.1 회사와 폐업

Misty Robotics는 2017년 Sphero 스핀오프로 출범, Misty II를 $3,200에 판매했다. 학교 / 연구소 / B2B 시장이 주요 고객. 2022년경 자금난으로 **사실상 폐업** — 단, GitHub 커뮤니티는 살아 있다 (확인 필요: 정확한 폐업 시점).

(출처: https://www.therobotreport.com/misty-ii-platform-robot-gets-net-sdk-misty-robotics-microsoft/)

### 5.2 SDK 구조 — DarwinForge가 가장 직접 참고할 패턴

Misty II의 가장 큰 강점은 **공개된 SDK** 였다:

| 인터페이스 | 언어 | 용도 |
|----------|------|------|
| **REST API** | 모든 언어 | 1회성 명령 (move arm, speak) |
| **WebSocket Events** | 모든 언어 | 실시간 이벤트 (face seen, touch detected) |
| **JavaScript SDK** | JS | 로봇 onboard 실행 (skill = code.js + meta.json) |
| **.NET SDK** | C# | enterprise 환경 |
| **Python SDK** | Python | 데이터 분석 / ML |
| **Skill Runner** | 웹 UI | skill 업로드 / 실행 / 디버그 |
| **API Explorer** | 웹 UI | REST 엔드포인트 테스트 |
| **Command Center** | 웹 UI | 사전 정의 동작 트리거 |

(출처: https://docs.mistyrobotics.com/misty-ii/web-api/overview/, https://github.com/MistyCommunity/JavaScript-SDK)

### 5.3 Skill 단위 — DarwinForge "Behavior" 와 매핑

Misty의 "Skill" = code.js + meta.json. meta.json 예:

```json
{
  "Name": "GreetUser",
  "UniqueId": "...",
  "Description": "Wave hand and say hello when face detected",
  "StartupRules": ["Manual"],
  "Language": "javascript",
  "BroadcastMode": "verbose",
  "TimeoutInSeconds": 600,
  "CleanupOnCancel": true,
  "WriteToLog": true
}
```

(출처: https://github.com/MistyCommunity/Documentation/blob/master/src/content/misty-ii/javascript-sdk/tutorials.md)

이 구조는 DarwinForge가 향후 "사용자 모션 라이브러리" 를 expose할 때 직접 참고 가능 — `.darwinforge-motion` 파일 형식으로 motion + meta + (선택적) tool_use 흐름 + 효과음 패키징.

> ★★ 차용 2순위: DarwinForge motion 포맷에 **meta.json 추가** — name / description / DOF 사용 / 안전 등급 / 음향 효과. 향후 Cozmo 스타일 "behavior" 로 확장 가능.

### 5.4 Web UI 도구들

Misty가 가진 3개 웹 도구는 우리 SwiftUI 앱과 직접 매핑된다:

| Misty 도구 | DarwinForge 대응 화면 | 차용 |
|-----------|---------------------|------|
| Command Center | Motion Library 탭 | 사전 정의 모션 트리거 — 이미 채택 |
| API Explorer | (없음) | DevConsole 탭 신설 후보 |
| Skill Runner | Conversation 탭 | claude tool_use 실행 트레이스 — 부분 채택 |

> ★ 차용 후보: **DevConsole 탭** — 개발자 / 고급 사용자용 raw GRPC 호출 + 로그 스트림. 현재 DarwinForge에 없음.

---

## 6. 비교표 — Loona vs Eilik vs Aibo vs Misty

| 차원 | Loona | Eilik | Aibo ERS-1000 | Misty II |
|------|-------|-------|---------------|----------|
| 가격 | $449 | $169 | $2,899 | $3,200 |
| 자유도 | ~10 (귀+바퀴+머리) | ~6 | 22 | ~10 |
| 표정 채널 | 5 (LCD+귀+바퀴+음성+LED) | 3 (LCD+모터+음성) | 4 (OLED+꼬리+귀+음성) | 4 (LCD+머리+팔+LED) |
| 클라우드 의존 | 부분 (옵션) | 거의 없음 | 100% (LTE 의무) | 부분 |
| SDK 공개 | 미공개 (앱만) | 미공개 | 미공개 (Sony 의도) | 공개 (가장 강함) |
| 강화학습 | 없음 | 없음 | ETH × Sony 보행 | 없음 |
| 활발 (2026-05) | ✅ | ✅ | ✅ | ⚠️ (커뮤니티만) |
| DarwinForge 차용도 | ★★★ (다채널 표정) | ★★ (4-state FSM) | ★★ (개체별 personality) | ★★ (SDK 패턴) |

---

## 7. DarwinForge 결론 — 이 문서에서 차용할 4가지

1. **Loona의 다채널 동기화 표정** — DARwIn-OP LED + 모터 + sound 동시 트리거. → `04` §5
2. **Eilik의 4-state FSM** — idle / working / success / refusal 단순화. → `04` §5
3. **Aibo의 사용자별 personality JSON** — Claude 시스템 프롬프트에 inject. → `04` §7
4. **Misty의 Skill 구조** — motion 파일에 meta.json 추가. → `04` §8

---

## 출처

- Loona 공식: https://us.keyirobot.com/products/loona
- Loona Kickstarter: https://www.kickstarter.com/projects/keyitechnology/meet-loona-the-petbot-you-will-fall-in-love/faqs
- Eilik 공식: https://store.energizelab.com/products/eilik
- Eilik Hackster: https://www.hackster.io/news/energize-lab-s-eilik-aims-to-be-your-emotional-playful-eve-inspired-desktop-companion-bot-7cf253953bee
- Aibo Wikipedia: https://en.wikipedia.org/wiki/AIBO
- Aibo Sony 도큐먼트: https://helpguide.sony.net/aibo/ers1000/v1/en-us/contents/TP0001970096.html
- Aibo ETH × Sony RL 보행: https://medium.com/@meisshaily/sony-aibo-robot-dog-ai-powered-companion-with-quiet-walking-dance-moves-19333ed651e1
- Misty Docs: https://docs.mistyrobotics.com/misty-ii/web-api/overview/
- Misty JS SDK GitHub: https://github.com/MistyCommunity/JavaScript-SDK
- Misty .NET SDK 출시: https://www.therobotreport.com/misty-ii-platform-robot-gets-net-sdk-misty-robotics-microsoft/
- Misty Skill 메타: https://github.com/MistyCommunity/Documentation/blob/master/src/content/misty-ii/javascript-sdk/tutorials.md
