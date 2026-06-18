# Mac DarwinForge 앱 최신화·재설치 + 로봇 메시 동기화 수정

- 작성일: 2026-06-18 (목)
- 대상: `/Applications/DarwinForge.app`, `scripts/build-app.sh`, `scripts/build-mac.sh`, `scripts/sync-meshes.sh`
- 결론 요약: **이 Mac의 DarwinForge 앱을 구버전 1.11.2 → 최신 1.24.0(build 739)으로 재설치했다.**
  설치 중 fresh 빌드 환경에서 **로봇 3D 모델이 렌더되지 않는 결함**(STL 메시 gitignore + 동기화
  자동화 부재)을 발견·수정했다. 빌드 파이프라인이 빌드 전 항상 메시를 동기화하도록 보강했다.

---

## 1. 작업 배경

- 요청: DarwinForge 앱을 최신 구현본으로 팔로업·최신화하고, 문서 업데이트·커밋·푸시 후
  이 PC에서 구버전 제거하고 최신 버전만 설치.
- 현황 파악:
  - Mac SwiftUI 앱의 **최신 구현본은 default 브랜치 `claude/robotis-darwin-op-setup-oyzTi`**.
    당시 작업 브랜치 `claude/ally-w1-core`(Windows Ally FPV 콕핏 전용)는 Mac 앱 49커밋이
    누락돼 있었고, 두 브랜치는 `app/ally`(ally-input/ally-link/ally-cli) 13파일에서 충돌.
  - 따라서 위험한 머지 없이 **default 브랜치를 격리 worktree로 빌드 → 설치**하는 전략을 채택.
  - 설치 전 `/Applications/DarwinForge.app` = **1.11.2** (2026-06-13 빌드, 구버전 회귀).

## 2. 설치 결과

| 항목 | 값 |
|---|---|
| 이전(제거) | 1.11.2 |
| 설치(최신) | **1.24.0 (build 739)**, `com.yuseokkim.darwinforge`, arm64 |
| 빌드 소스 | `claude/robotis-darwin-op-setup-oyzTi` (origin 기본 브랜치 tip 27269bb) |
| 설치 방식 | clean swap (구버전 backup 없이 제거 → 최신만 설치). `/Applications` 잔여물 0 |
| 서명 | adhoc (로컬 실행용). `codesign --verify` 의 "unsealed contents in bundle root"·
  `spctl: rejected` 는 SwiftPM 리소스 번들 구조 + adhoc 서명의 정상 거동 (quarantine 제거로 실행 OK) |

## 3. 발견한 결함 — 로봇 3D 모델 미렌더

### 증상
재설치 직후 사용자 입회 확인: **3D 뷰포트에 로봇 모델이 안 보이고 바닥만 렌더**.

### 근본 원인
- 로봇은 `vendor/robotis-op2-common/meshes/*.stl` 21개를 `STLLoader` 가
  `Resources/Meshes/<name>.stl`(`Bundle.module`)에서 로드해 렌더한다. 실패 시 프리미티브
  폴백 rig 으로 떨어진다.
- 그런데 `app/ui/DarwinForge/Sources/DarwinForgeUI/Resources/Meshes/*.stl` 는
  **`.gitignore` 대상**(`app/ui/DarwinForge/.gitignore`)이라 git에 추적되지 않는다.
- 메인 체크아웃에는 과거에 로컬 수동복사된 메시가 남아 있지만, **fresh clone / git worktree
  체크아웃에는 메시가 없다.** 동기화 자동화 스크립트도 없었다.
- 결과: worktree에서 빌드한 `.app` 번들에 STL 0개 → 21개 메시 로드 전부 실패 →
  로봇 미렌더. (헤드리스 swift test 환경의 "바닥만 렌더" 와 동일 메커니즘.)

### 진단 증거
- 설치 번들 메시 검색: STL 0개.
- `Package.swift`: `resources: [.copy("Resources/Meshes"), …]` 선언은 있으나 디렉터리 부재.
- `vendor/.../meshes/geo_op_body.stl` md5 == 메인 체크아웃 `Resources/Meshes/geo_op_body.stl`
  md5 (`6cfadc31…`) → vendor가 SSOT.

## 4. 수정

### 4.1 즉시 복구
worktree의 `Resources/Meshes`에 vendor 메시 21개 복사 → 재빌드 → 재설치.
- 검증: 재빌드 번들 `DarwinForge_DarwinForgeUI.bundle/Meshes/` 에 21 STL,
  설치본 실행 후 unified log `STL load failed` **0건**, 크래시 0건.

### 4.2 근본 수정 (재발 방지)
- 신규 `scripts/sync-meshes.sh` — vendor(SSOT) → `Resources/Meshes` 멱등 동기화. 단독 실행 가능.
- `scripts/build-app.sh` (설치/배포 경로) — `swift build` 전 `sync-meshes.sh` 호출.
  `--skip-rust` 경로에서도 독립 수행.
- `scripts/build-mac.sh` (`make run`/`make app`/`--swift` 개발 경로) — `swift build` 전 호출.
- 검증: `Resources/Meshes` 삭제(fresh checkout 시뮬) 후 `sync-meshes.sh` → 21개 복원.
  세 스크립트 `bash -n` 통과.

## 5. 문서 업데이트
- `README.md` 빌드 섹션 — 메시 동기화 + 수동 명령 안내.
- `CLAUDE.md` Build & run — 메시 gitignore/동기화 동작 명시.
- `docs/MAC_RUN_GUIDE.md` 트러블슈팅 — "로봇이 안 보이고 바닥만 렌더" 행 추가.
- 본 보고서.

## 6. 변경 분류 / 추적
- 빌드 수정 + 문서: PR https://github.com/bbikiming/Darwin/pull/44
  (branch `fix/build-mesh-sync`, base = `claude/robotis-darwin-op-setup-oyzTi`).
  default 브랜치 직접 푸시는 정책상 차단되어 PR로 리뷰 경유.
- W0 실패원인 보고서 SUPERSEDED 배너: `claude/ally-w1-core` (커밋 b5c8966).

## 7. 잔여
- PR #44 리뷰·머지 (머지되면 모든 빌드 경로에서 fresh checkout 로봇 렌더 보장).
- 사용자 육안 최종 확인(스크린샷 권한 미부여로 로그 증거로 갈음).
