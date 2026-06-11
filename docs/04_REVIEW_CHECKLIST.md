# 04 — 리뷰 체크리스트 (Review Checklist)

> 각 P 구현 완료 시 이 체크리스트로 검수하고, 결과를 `05_FABLE_REVIEW_RESULT.md` 에
> 기록한다. **리뷰 미통과 = 태스크 미완료** (이슈 발견 시 수정 후 재리뷰 — 예외 없음).

## A. 안전 (하나라도 위반 시 즉시 반려)

- [ ] E-STOP 경로에 스로틀·디바운스·배칭·추가 비동기 홉이 **추가되지 않았다** (제거/병행 채널만 허용)
- [ ] 파일 기반 명령/E-STOP/텔레메트리 폴백 경로가 보존됐다 (UDP/stdin 은 가산)
- [ ] 클램프/거버너의 최종 소유가 로봇 측이다 (클라이언트 클램프는 UX 레이어)
- [ ] 정지 시퀀스의 DSP 게이팅(Walking.cpp 375-411) 무변경
- [ ] 토크 컷은 E-STOP·FALLEN 경로만 (워치독 티어는 토크 유지)
- [ ] 실기 절차가 포함된 변경이면: 크래들+다리 토크 해제+배터리 차단 전제가 문서화됐다
- [ ] Walking.cpp 를 만졌다면: diff 가 밸런스 블록 한정 + 플래그 게이트 + 롤백 경로 동봉

## B. 계약·정합

- [ ] 프로토콜 변경 시 `docs/ssh-parity-contract.md` 가 **동일 커밋**에서 개정됐다
- [ ] 구버전 공존: V1/구 펌웨어 폴백 경로가 동작한다 (NO_ACK·미인식 토큰 처리 불변)
- [ ] 래칭·슬루·거버너·게이트 스케줄·LPF 상수가 지정된 단일 정의 파일에만 존재한다
- [ ] 모드 간 패리티: 콕핏/Switch/G01 매핑 의미론이 패리티 표와 일치한다
- [ ] 3D 변경 시: 30fps·isFullyIdle·0-alloc 풀·wantsHDR=false 계약 유지, 헤드리스
      renderImage/writePNG 회귀 없음

## C. 품질 (golden principles 적용분)

- [ ] 증거 기반 완료: 테스트 수·빌드 로그·스냅샷·벤치 수치가 보고에 첨부됐다
- [ ] 테스트 선행/동반: 새 로직에 단위 테스트, 합격 기준(03)의 해당 항목 전부 커버
- [ ] Swift 테스트 serial 실행 확인 (UserDefaults 공유 — 새 키 추가 시 특히)
- [ ] 파일 ≤800줄·함수 ≤50줄·중첩 ≤4 (초과 시 분리 근거 명시)
- [ ] 시크릿/토큰 하드코딩 0 (UDP 토큰은 세션 프로비저닝 경유)
- [ ] 이뮤터블 패턴(Swift struct/let 우선), 불필요한 전역 가변 상태 없음
- [ ] C++03 제약 준수(로봇 코드): 신규 의존성 pthread 한정, 예외/RTTI 미의존

## D. 절차

- [ ] Conventional Commit (scope: ui/connection/serial/firmware/walklab/switch/docs)
- [ ] `docs/design/README.md` §1 표 + `implementation-prompts.md` 체크박스 갱신
- [ ] `06_IMPLEMENTATION_SUMMARY.md` 에 결과 1절 적립
- [ ] 외부(2차) 검수: Codex 리뷰 또는 별도 세션 Fable 교차 리뷰 수행, 결과를 05 에 기록
- [ ] 실기 보류 항목이 있으면 "로봇 연결일 벤치 목록"(02 §2 트랙 B)에 명시적으로 남겼다

## 리뷰 절차

1. 셀프 체크(A→D) → 2. 자동화 증거 수집(테스트/빌드) → 3. 외부 검수(Codex `/codex review`
   또는 신규 세션 교차 리뷰) → 4. 이슈 분류(CRITICAL/HIGH 즉시 수정, MEDIUM 가능 시) →
   5. 재검수 → 6. `05_FABLE_REVIEW_RESULT.md` 기록 + 머지.
