# App Store 심사 관리

DarwinForge 의 Mac App Store / Developer ID 심사 이력 + 미해결 조치 사항 추적.

> **앱 정보**
> - Bundle ID: `com.robotis.darwinforge`
> - Team ID: `JM4LJMU49Q`
> - 최소 OS: macOS 14.0
> - 카테고리: macOS 전용 (ROBOTIS DARwIn-OP / OP2 제어)

---

## 문서 구조

| 파일 | 내용 |
|---|---|
| `README.md` (이 파일) | 심사 이력 요약 + 현황 dashboard |
| **`2026-06-13-pass-master-plan.md`** | **★ 심사 통과 마스터 플랜 — 전체 수정 항목 상세 (구현 터미널용)** |
| `2026-06-11-rejection-2.4.5-entitlements.md` | 반려 #1 상세 (entitlements) + 조치 |
| `resubmission-checklist.md` | 재제출 전 체크리스트 (반복 사용) |
| `app-review-notes-template.md` | App Review 팀 전달 노트 템플릿 (하드웨어 의존성) |

---

## 심사 이력 dashboard

| # | 날짜 | 버전 | 결과 | 사유 | 상태 |
|---|---|---|---|---|---|
| 1 | 2026-06-11 | 1.23.0 (579) | 🔴 반려 | Guideline 2.4.5(i) — entitlements false 값 | ✅ 조치 (PR #43) → 재제출 대기 |

---

## 현재 미해결 조치 사항

> **★ 전체 상세는 `2026-06-13-pass-master-plan.md` 참조** — 아래는 요약 dashboard.

### 🔴 P0 — 재제출 차단 / 핵심 기능 파손

1. **[2026-06-11 반려] entitlements 5개 false 제거** — ✅ 조치됨 (PR #43), merge 대기
2. **`com.apple.security.device.serial` 부재** — ⬜ 미조치. sandbox 에서 `/dev/cu.*` open 거부 → **robot 연결 자체 불가** (마스터 플랜 §1)
3. **CFBundleVersion 자동 bump 부재** — ⬜ 미조치. 소스=2, 반려 build=579 → 업로드 거부 (마스터 플랜 §2)
4. **sandbox 활성 상태 기능 검증 0회** — ⬜ 미조치. 12항목 체크리스트 (마스터 플랜 §3)

### 🟡 P1 — 휴먼 리뷰 반려 위험

5. **ROBOTIS 상표/사칭 (5.2.1)** — ⬜ **사용자 의사결정 필요**. bundle ID `com.robotis.*` + 저작권 "© ROBOTIS" vs README "unofficial" 모순 (마스터 플랜 §5)
6. **Claude CLI 외부 프로세스 의존 기능** — ⬜ 미조치. 리뷰어 환경에서 깨진 기능으로 보임 → gate/숨김 (마스터 플랜 §4)
7. **SynthBridge `cargo` 의존** — ⬜ 미조치. production 확정 실패 → gate (마스터 플랜 §4)
8. **SSH/scp/ping 서브프로세스** — ⬜ sandbox 검증 필요 (마스터 플랜 §4)
9. **ComingSoonOverlay placeholder** — ⬜ 사용처 조사 + 정리 (마스터 플랜 §7)
10. **하드웨어 의존 Review Notes + 데모 영상** — ⬜ 템플릿 ✓, 영상 미제작 (마스터 플랜 §6)
11. **App Privacy 라벨** — ⬜ 음성 데이터 선언 필요 (마스터 플랜 §8)

### 🟢 P2 — 확인 완료 / 방어적

12. Export Compliance ✓ · App Sandbox ✓ · 카메라 의도적 누락 ✓ · NSBonjourServices ✓ · 카테고리 ✓ · 아이콘 1254px ✓ · provisioning 자동 embed ✓
13. NSAllowsLocalNetworking 명시 — 권장 (IP literal 은 ATS 면제라 현재도 동작, 마스터 플랜 §9.1)

---

## 재제출 워크플로

```
1. PR #43 merge (entitlements fix)
2. docs/app-review/resubmission-checklist.md 전체 확인
3. CFBundleVersion bump (build number — 동일 build 재업로드 불가)
4. bash scripts/archive-app.sh  (App Store method)
5. App Store Connect → 새 build 업로드
6. App Review Notes 작성 (app-review-notes-template.md 기반)
7. 재심사 제출
8. 결과를 본 dashboard 에 기록
```

---

## 참고 자료

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Technical Q&A QA1773 — Common app sandboxing issues](https://developer.apple.com/library/archive/qa/qa1773/_index.html)
- [App Sandbox documentation](https://developer.apple.com/documentation/security/app_sandbox)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime)
- 빌드/사인 스크립트: `scripts/archive-app.sh`
- entitlements 가이드: `docs/walk-lab/PILOT_PRODUCTION_ENTITLEMENTS.md`
