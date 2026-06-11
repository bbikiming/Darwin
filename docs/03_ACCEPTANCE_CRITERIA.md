# 03 — 합격 기준 (Acceptance Criteria)

> 각 P 의 "완료"를 선언하기 위한 측정 가능 기준. 설계 문서의 검증 절에서 추출·정규화.
> **증거 없는 완료 선언 금지** — 테스트 수/벤치 수치/스냅샷을 함께 제시해야 한다.
> 실기(로봇) 기준은 코드 머지 시점이 아니라 "로봇 연결일" 벤치에서 판정한다.

## 0. 공통 기준 (모든 P)

- [ ] `bash scripts/build-mac.sh --swift` 성공 (0 errors)
- [ ] `swift test --package-path app/ui/DarwinForge` 전체 통과 (**serial — `--parallel` 금지**)
- [ ] Rust 변경 시 `cargo test --workspace` + `make lint`(fmt+clippy `-D warnings`) 통과
- [ ] 로봇 C++ 변경 시 호스트 빌드 테스트(`firmware-patches/.../tests/`) 통과
- [ ] 안전 불변식(README §3) 위반 0 — 리뷰 체크리스트(04) 통과
- [ ] `docs/design/README.md` 표 + `implementation-prompts.md` 체크박스 갱신

## P3 — 전송 묶음 (W1 + O0·O1)

| 기준 | 판정 방법 | 시점 |
|---|---|---|
| TEL 파서 ≥11 토큰 하위호환 (구 11·신 13 모두 파싱) | 단위 테스트 | 코드 |
| 클럭 오프셋 EWMA 수렴 (모의 ACK 시계열) | 단위 테스트 | 코드 |
| PersistentSSHChannel: sentinel 왕복·폴백 전환·latestWins 코얼레싱 | 단위 테스트(목 프로세스) | 코드 |
| E-STOP 큐 우회(sendEmergencyStopNow) — 대기 명령 0개 통과 | 단위 테스트 | 코드 |
| 브로커리지: latest-wins 슬롯 seq 단조·역행 폐기 | 호스트 테스트 | 코드 |
| 워치독 티어: 0.6s 진폭→0 슬루 → 2.5s Stop → 토크 유지 | 호스트 테스트(가짜 시계) | 코드 |
| UDP E-STOP 리스너: 토큰 불일치 거부·수신 즉시 Stop 호출 | 호스트 테스트 | 코드 |
| 파일 폴 폴백: UDP/stdin 비활성 시 100ms 복귀 | 호스트 테스트 | 코드 |
| 명령 실효율 ≥**20Hz** (10s 스틱, ACK/s) | 실기 벤치 | 로봇 |
| 입력→로봇 적용 유선 **p95 ≤120ms** | tracer | 로봇 |
| E-STOP→walking=0 유선 **p95 ≤60ms** | UDP 발사→TEL 전환 | 로봇 |
| 케이블 분리 → 0.6s 제자리 → 2.5s 정지 | 실기 | 로봇 |

## P4 — 온보드 O2 (거버너·twist v2)

- 코드: V2↔V1 파서 왕복 테스트 · twist 변환식 Mac/로봇 동형 대조 · 거버너 경계표
  (1.15 초과 스케일다운) · 래치 슬루 한계(|ΔX|≤8 등) 단위 테스트 · blevel→게인 스케일 배선 테스트.
- 실기: 스텝 응답 정착 시간 **≥30% 단축**(O0 기준선 대비).

## P6 — bus D1+D2

- 코드: **동치 테스트**(키프레임 6포즈 = 시간 기반 동일 시각 포즈, 회귀 0) · 래칭 경계 테스트 ·
  IMU 20ms 폴 분기 테스트 · FSR 파싱 테스트.
- 실기: 직진 5m yaw 드리프트 D1 전후 개선 수치화 · 서보 온도 10분 추이 정상 · 진동 없음
  (있으면 step 30ms 후퇴) · 버스 점유 ~5–6% 로그.

## P7 — handheld H1+H2

- 코드: 매핑(데드존 0.10·곡선 1.35·intensity^0.7) 테이블 테스트 · ARM/E-STOP 정산 테스트 ·
  **3중 failsafe**(release 합성/EVIOCGKEY 실패/1.5s 추정) 각 분기 테스트 · 소스 중재
  (estop>local>network) 테스트.
- 실기: E-STOP ≤**20ms** · 패드 전원 OFF/동글 뽑기 → failsafe 티어 진입 · 10분 CPU <5%.

## P9 — 온보드 O4 (TEL2)

- 코드: v1/v2/결손 토큰 파서 테스트 · 손실 >20% 시 SSH 폴 승격(목) · active_source 자리.
- 실기: UDP 30Hz 수신율 · HUD 위상 표시와 보행 영상 대조.

## P10 — handheld H3

- 코드: V2 패킷 직렬화·seq·전송 폴백(UDP→SSH) 전환 테스트(Python) · keepalive 250ms.
- 실기: Switch→로봇 실효율 ≥20Hz · estop UDP 경로 동작.

## P11 — 3D W3

- RigSkeleton 선행 커밋 존재 · 오버레이별 헤드리스 스냅샷(한계아크 3포즈 포함) ·
  ZMPMonitor 좌표 정합 테스트 · 풀링(자체 타이머 0, pose 경로 갱신만) 코드 확인 ·
  매트릭스 기본값(화면×오버레이) 테스트.

## P12 — 3D W4+W5

- shortestAngleDelta 단위 테스트 · 턴테이블 on 시 isFullyIdle 예외 동작 테스트 ·
  DOF 스냅샷 제외 확인 · W5 실측치(§7 표) 기입 + 스냅샷 기준선 갱신.

## P1 — H0 프로브 (로봇 전용)

- 보고서에 포함: VID/PID·바인딩 드라이버·event 노드·축 범위·버튼 코드 ·
  **단절 거동(release 합성 여부)** · 절전 타임아웃 · Wi-Fi 공존 결과 → H1 코드 테이블 초안.
- 로봇 영구 변경 0 (휘발성 new_id 만 허용).

## P8 — 온보드 O3 (코드 머지 기준만 — 튜닝은 별도 승인)

- 전 항목 플래그 기본 OFF · Walking.cpp diff 가 밸런스 블록 한정 · LPF/CoP 부호/risk 단위
  테스트 · 롤백 스크립트 동봉.
