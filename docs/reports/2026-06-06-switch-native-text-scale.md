# Switch Native Text Scale 기준

작성일: 2026-06-06

## 목적

DARwIn Switch 조종석의 텍스트가 Nintendo Switch 네이티브 UI처럼 보이도록, 1280x720 휴대 모드 화면에서 과도하게 큰 버튼/상태 텍스트를 낮추고 실시간 조종 값은 즉시 읽히는 크기로 유지한다.

## 근거

- Nintendo 지원 문서의 TV 출력 설정에는 Switch 출력 해상도 선택지로 720p가 포함된다. Switch 1 휴대 화면도 1280x720 캔버스이므로 조종석 검증 기준은 1280x720으로 둔다.
- 공개된 Nintendo Switch HOME Menu 20.0.0 캡처는 원본 1280x720 이미지로 제공된다. HOME UI는 상단 상태/버튼성 텍스트가 대략 12-16px 급이고, 화면 제목/주요 항목만 더 크게 보인다.
- 일반 플랫폼 접근성 기준에서는 보통 UI 텍스트 하한을 11pt 이상으로 본다. Switch 휴대 사용은 720p 소형 화면이라 보조 라벨은 11-12px 아래로 내리지 않는다.
- Switch 커뮤니티에서는 이식 게임의 작은 UI 텍스트가 반복적으로 문제로 언급된다. 따라서 데이터 조종석은 “작게 많이”보다 “계층을 명확히”가 우선이다.

참조:

- Nintendo Support, TV Output: https://www.nintendo.com/en-gb/Support/Troubleshooting/How-to-Adjust-the-TV-Settings-on-Nintendo-Switch-1508497.html
- Nintendo Switch HOME Menu 20.0.0 screenshot, 1280x720: https://www.mariowiki.com/File:Nintendo_Switch_Menu20.0.0.jpg
- Apple UI Design Tips, minimum readable text 11pt and 44pt hit targets: https://developer.apple.com/design/tips/
- Nintendo Life, Switch small-text readability issue overview: https://www.nintendolife.com/guides/nintendo-switch-games-with-small-text-the-worst-offenders-how-to-use-zoom-on-switch

## 적용 스케일

| 용도 | 적용 범위 |
| --- | --- |
| 보조 라벨/캡션 | 11-12px |
| 상단 탭/상태 칩 | 12-13px |
| 카드 제목 | 12-14px |
| 카드 내부 값 | 14-16px |
| 도크 버튼 라벨 | 16px |
| 일반 상태 강조 | 20-24px |
| 실시간 계기 숫자 | 28-36px |

## 이번 조정

- 상단 제목, 미션 캡션, Joy-Con rail 라벨, trigger 상태값을 한 단계 낮춤.
- 계기판 카드 제목과 보조 라벨을 12px 중심으로 정리.
- 시스템 상태 강조어를 28px에서 24px로 낮춰 카드가 덜 답답하게 보이도록 조정.
- 도크 버튼 라벨을 18-21px에서 16-18px로 낮춰 Nintendo 홈/시스템 메뉴에 가까운 밀도로 조정.
- 서비스워커 캐시를 `v15`로 올려 Switch 설치 후 기존 CSS 캐시가 남지 않도록 처리.
