# research/community/

> ROBOTIS DARwIn-OP / OP2 의 **커뮤니티 fork·확장 저장소** 아카이브.
>
> 공식 / 준공식 자료는 [`research/robotis-official/`](../robotis-official/) 에 있고,
> 여기는 사용자·연구실·기업이 자체 변경을 적용한 자료를 보존한다. 출처별 의도·라이선스·
> 핵심 contribution 을 분리 추적하므로, 우리 코어가 알고리즘을 인용하거나 페이지를 추출할
> 때 출처와 라이선스 호환성을 즉시 확인할 수 있다.
>
> 갱신: 2026-05-12 (Phase 1 확장 — 커뮤니티 모션 DB 구축).

## 목록

| 디렉토리 | Upstream | 라이선스 | 클론 commit | 핵심 contribution |
|----------|----------|----------|-------------|--------------------|
| [`robot_personal_assistant_op2/`](robot_personal_assistant_op2/_NOTES.md) | [PersonalAssistantGradProject/...op2](https://github.com/PersonalAssistantGradProject/robot_personal_assistant_op2) | `package.xml` TODO (미선언) | `f6cfc3a7` (2023-11-01) | OP2 실기체 ROS 노드 (얼굴/음성/posture) + ergonomic 모션 페이지 100~108 + 인사 페이지 250~255 |
| [`nimbro-op/`](nimbro-op/_NOTES.md) | [NimbRo/nimbro-op](https://github.com/NimbRo/nimbro-op) | BSD-3 (SW) · CC BY-NC-SA 3.0 (CAD) | `5572d413` (2012-10-30) | DARwIn-OP v1.5.0 위 25-patch (보행 튜닝, MotionManager torque, fall protection, AngleEstimator, UDP telemetry, mirrored ActionEditor) |
| [`darwinop-ens-darwin-op/`](darwinop-ens-darwin-op/_NOTES.md) | [darwinop-ens/darwin-op](https://github.com/darwinop-ens/darwin-op) | Apache 2.0 (ROBOTIS 상속) | `fe301d0b` (2015-11-23) | **OP1 framework SourceForge → GitHub 정본 미러.** Walking/Action/Kinematics 헤더의 1차 reference |
| [`_gpl-isolated/HROS5-Framework/`](_gpl-isolated/HROS5-Framework/_NOTES.md) | [Interbotix/HROS5-Framework](https://github.com/Interbotix/HROS5-Framework) | **GPL v3 (격리)** | `a0640f19` (2016-07-03, archived 2021) | **개선 모션 편집기 `rme`** (개별 limb torque) + PS3 컨트롤러 데모 + motion_src/dest 변환 페어 |

> 디렉토리 이름 규칙: `<owner>-<repo>` 또는 `<repo>` (충돌 시 owner 접두). 격리 대상은
> `_gpl-isolated/` 하위.

## 격리 정책

`_gpl-isolated/` 하위는 GPL 라이선스. **`forge-core`, `forge-cli`, `DarwinForge` Swift 패키지
어디에도 코드 임포트 금지**. 사실(facts)·알고리즘 인용만 OK. 자세히 →
[`_gpl-isolated/README.md`](_gpl-isolated/README.md).

## 모션 카탈로그

각 저장소의 `motion_4096.bin` (및 보조 `.bin`) 은 [`motions/external/`](../../motions/external/)
에 SHA-256·페이지 카탈로그·cross-source 비교가 정리되어 있다. 핵심 인덱스 →
[`motions/external/README.md`](../../motions/external/README.md).

## 메타데이터

| 파일 | 역할 |
|------|------|
| `_metadata/remote-heads.txt` | 각 upstream 의 HEAD 커밋 (Phase 1 ls-remote 결과) |

## 새 저장소 추가 절차

1. **라이선스 확인** — LICENSE / LICENSE.md / package.xml `<license>` 태그.
   GPL 이면 `_gpl-isolated/` 하위로, 그 외는 톱 레벨.
2. **shallow clone** — `git clone --depth 1 https://… <dir>`.
3. **메타 캡처** — `git rev-parse HEAD` → `_metadata/remote-heads.txt` 갱신.
4. **`_NOTES.md` 작성** — 메타 / 구조 / 핵심 파일 / 활용 방식 / 주의.
5. **모션 파일 카탈로그** — `python3 scripts/research/extract_motion_pages.py … --csv motions/external/_catalog/<id>.csv --only-populated` 실행.
6. **`motions/external/MANIFEST.toml` 갱신** — `[[motion]]` 블록 추가.
7. **`research/INDEX.md` · `vendor/LICENSES.md` · `_metadata/remote-heads.txt` 갱신**.
8. **이 README 의 "목록" 표에 한 줄 추가**.
