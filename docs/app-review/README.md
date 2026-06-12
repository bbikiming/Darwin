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

### 🔴 P0 — 재제출 차단 (해결됨, merge + archive 대기)

1. **[2026-06-11 반려] entitlements 5개 false 제거**
   - 상세: `2026-06-11-rejection-2.4.5-entitlements.md`
   - 조치: PR #43 (`claude/fix-appstore-entitlements`)
   - 남은 작업: PR merge → CFBundleVersion bump → archive → 재업로드

### 🟡 P1 — 재제출 시 함께 준비 (잠재 반려 위험)

2. **USB 외부 하드웨어 의존성 (Guideline 2.4.5 / 2.1)**
   - `com.apple.security.device.usb` entitlement 사용
   - App Review 는 실 ROBOTIS-OP2 robot 없이 검토 불가능
   - **조치 필요**: App Review Notes 에 "하드웨어 없이 동작하는 시뮬레이션 모드" 명시
     + 데모 영상 첨부 권장
   - 템플릿: `app-review-notes-template.md`

3. **음성 인식 / 마이크 권한 (Guideline 5.1.1)**
   - `NSSpeechRecognitionUsageDescription` / `NSMicrophoneUsageDescription` 존재 ✓
   - usage description 명확함 ✓ — 추가 조치 불필요 (기록만)

4. **Local Network 권한 (Guideline 5.1.1)**
   - `NSLocalNetworkUsageDescription` 존재 ✓ (Pilot Relay + Tello)
   - 추가 조치 불필요

### 🟢 P2 — 확인 완료 (조치 불필요)

5. **암호화 수출 규정 (Export Compliance)**
   - `ITSAppUsesNonExemptEncryption = false` ✓ — HTTPS 표준만 사용
6. **App Sandbox**
   - `com.apple.security.app-sandbox = true` ✓
7. **카메라 권한**
   - `NSCameraUsageDescription` 의도적 누락 (현재 미사용) ✓

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
