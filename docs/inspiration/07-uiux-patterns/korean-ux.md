# 한국어 UX 라이팅 — 토스 8원칙 외

> DarwinForge가 이미 토스 8원칙 + 해요체 통일을 채택했음. 본 문서는 그
> 정신을 더 깊이 다듬는 자료.

## 토스 UX 라이팅 8원칙 (요약)

원본: 토스 디자인 컨퍼런스 SLASH 22, 23, 24

1. **사용자 머릿속 단어로 말한다** — "Dynamixel"이 아니라 "모터", "시리얼
   포트"가 아니라 "USB 케이블"
2. **자기소개부터 한다** — 첫 화면에 무엇을 할 수 있는지 명확히
3. **반복하지 않는다** — 같은 단어 같은 화면에 두 번 나오지 않게
4. **간결하지만 친절하게** — 기능을 설명하되 짧게
5. **한 화면 한 메시지** — 화면당 핵심 메시지 1개
6. **부정형보다 긍정형** — "X를 안 하면 위험" → "Y를 하면 안전"
7. **정보 위계** — 가장 중요한 것이 가장 크게 / 가장 위에
8. **약속은 지킨다** — "잠시만 기다려요" 후 정말 잠시만

## DarwinForge 채용 점검

### 1. 사용자 머릿속 단어 — ✅ 채용
```swift
// KoreanUX.JointName
JointID.rShoulderPitch.koreanName  // "오른쪽 어깨 (앞뒤)"
// 사용자는 "R_SHOULDER_PITCH"가 아닌 한국어를 본다
```

### 2. 자기소개 — ✅ 채용
EmptyState의 환영문 + 4 추천 칩.

### 3. 반복하지 않는다 — ⚠️ 부분 채용
Action Button 문구가 화면마다 일관되게 통일되어야. 단어 통일 사전
(`KoreanUX.swift`) 확장 필요.

| 동작 | 표준 한국어 |
|------|------------|
| Connect | 연결하기 |
| Disconnect | 연결 끊기 |
| Save | 저장하기 |
| Cancel | 취소 |
| Delete | 삭제하기 |
| Confirm | 확인 |
| Reset | 처음으로 |
| Apply | 적용하기 |
| Refresh | 새로 읽기 |
| Edit | 고치기 |

### 4. 간결하지만 친절 — ✅ 채용 (해요체)
```
나쁨: "잠시 후 다시 시도해주세요"
좋음: "지금 응답이 느려요. 잠시 후 다시 해 볼까요?"
```

### 5. 한 화면 한 메시지 — ⚠️ 점검 필요
BoardStatusView가 모델 / 펌웨어 / 전압 / 버튼을 동시에 보여주는데, 사용자
머릿속에선 "지금 로봇이 건강한가?"가 1차 질문. → 상단에 큰 헬스 배지
(녹색·주황·빨강), 그 아래 세부 정보로 위계.

### 6. 부정형보다 긍정형 — ✅ 채용
```
나쁨: "위험! 토크 OFF 안 하면 모터 손상"
좋음: "안전을 위해 먼저 모든 토크를 꺼 주세요"
```

### 7. 정보 위계 — ⚠️ 부분
Joint Control의 우측 상태 그리드가 6개 필드 동등 크기. 핵심(Goal /
Present / Torque)이 강조되어야.

### 8. 약속 — ✅
"잠시만요…" 같은 메시지는 항상 1초 안에 결과 또는 진행 표시로 교체.

## 카카오 / 네이버 / 라인 라이팅 공통

- **존댓말 통일** — 해요체 (-아요/-어요) > 합쇼체 (-합니다)
- **명령형 회피** — "확인" 대신 "확인해 주세요"
- **단어 일관성** — "삭제" / "지우기" 혼용 금지

## 한국어 UI 음성 (VoiceOver)

macOS Speech Framework + `Locale("ko-KR")`.

```swift
Button("연결하기") { connect() }
    .accessibilityLabel("로봇과 USB 연결을 시작합니다")
    .accessibilityHint("이 버튼을 누르면 선택한 포트로 통신을 시도해요.")
```

## 한글 자모 정렬 / 검색

- macOS NSString의 `localizedStandardCompare` 사용 — 한글 자모 분해
  비교 자동.
- 검색 시 "ㄹㅂ" → "로봇" 매칭은 표준 라이브러리 부재. 자체 fuzzy 매처
  필요 (Sprint 10+ 후보).

## 출처

- 토스 SLASH 22 라이팅 발표: https://toss.tech/article/slash22-toss-content-design
- 카카오 디자인 가이드라인: https://design.kakao.com
- ROBOTIS e-Manual KR: https://emanual.robotis.com/docs/kr/
- 한국어 UX 라이팅 책 (참고): "사용자 입장에서 글쓰기" — UX writers 한국 협회
