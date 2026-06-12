# 재제출 체크리스트 (반복 사용)

매 App Store 재제출 전 전체 확인. 항목별 ✅ 후 제출.

---

## 1. 코드 / 빌드

- [ ] 최신 main(또는 dev branch) 기준 빌드 — `bash scripts/build-mac.sh -u --swift`
- [ ] 컴파일 error 0
- [ ] `swift test` 전체 통과
- [ ] 이전 반려 사유 해결 commit 이 포함되었는가? (git log 확인)

## 2. 버전 / 빌드 번호

- [ ] `CFBundleShortVersionString` (marketing version) — 적절히 증가 또는 유지
- [ ] **`CFBundleVersion` (build number) — 직전 업로드보다 반드시 큰 값**
  - 동일 build number 재업로드 불가 (App Store Connect 거부)
  - bump 명령:
    ```sh
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" \
      app/ui/DarwinForge/Sources/DarwinForgeApp/Info.plist
    ```

## 3. Entitlements (반려 #1 재발 방지)

- [ ] `DarwinForge-AppStore.entitlements` 에 `cs.*` 키가 **false 로 명시되지 않았는가**
  ```sh
  grep -A1 'cs\.' app/ui/DarwinForge/Sources/DarwinForgeApp/DarwinForge-AppStore.entitlements \
    | grep -q '<false/>' && echo "🔴 cs.* false 잔존 — 반려 위험" || echo "✅ OK"
  ```
- [ ] 모든 entitlements XML 유효성
  ```sh
  for f in AppStore DevID ""; do
    plutil -lint app/ui/DarwinForge/Sources/DarwinForgeApp/DarwinForge${f:+-$f}.entitlements
  done
  ```
- [ ] `com.apple.security.app-sandbox = true` 존재
- [ ] 사용하는 권한만 포함 (불필요 entitlement 없음)

## 4. Info.plist 권한 usage description

- [ ] `NSMicrophoneUsageDescription` (음성 명령) — 명확한 한국어 설명
- [ ] `NSSpeechRecognitionUsageDescription` (음성 인식)
- [ ] `NSLocalNetworkUsageDescription` (Pilot Relay + Tello)
- [ ] 미사용 권한의 usage description 은 제거 (예: `NSCameraUsageDescription` — 현재 미사용)

## 5. 코드 사인

- [ ] `bash scripts/archive-app.sh` 의 method = App Store
- [ ] `codesign --options runtime` (hardened runtime) 활성
- [ ] "Apple Distribution" 인증서 사용
- [ ] provisioning profile 의 application-identifier 일치

## 6. 외부 하드웨어 의존성 (Guideline 2.4.5 / 2.1)

- [ ] App Review Notes 작성 — `app-review-notes-template.md` 기반
- [ ] 하드웨어(ROBOTIS-OP2) 없이 동작하는 **시뮬레이션 모드** 명시
- [ ] 가능하면 데모 영상 첨부 (robot 동작 + 앱 UI)
- [ ] USB entitlement 정당성 설명

## 7. Export Compliance

- [ ] `ITSAppUsesNonExemptEncryption = false` (HTTPS 표준만 사용 시)

## 8. App Store Connect 메타데이터

- [ ] 스크린샷 (macOS 필수 사이즈)
- [ ] 앱 설명 / 키워드
- [ ] 지원 URL / 개인정보처리방침 URL
- [ ] 연령 등급
- [ ] 카테고리

## 9. 최종

- [ ] TestFlight 내부 테스트 1회 이상 (선택이나 권장)
- [ ] 제출 후 `docs/app-review/README.md` dashboard 에 기록
- [ ] 반려 시 새 `docs/app-review/YYYY-MM-DD-rejection-*.md` 작성

---

## 빠른 검증 스크립트

```sh
#!/usr/bin/env bash
# 재제출 전 자동 가드
set -e
APP=app/ui/DarwinForge/Sources/DarwinForgeApp

# 1. entitlements cs.* false 가드
for f in DarwinForge-AppStore DarwinForge-DevID DarwinForge; do
  if grep -A1 'cs\.' "$APP/$f.entitlements" 2>/dev/null | grep -q '<false/>'; then
    echo "🔴 $f.entitlements — cs.* false 잔존"; exit 1
  fi
  plutil -lint "$APP/$f.entitlements" >/dev/null && echo "✅ $f.entitlements valid"
done

# 2. app-sandbox 존재
grep -q 'com.apple.security.app-sandbox' "$APP/DarwinForge-AppStore.entitlements" \
  && echo "✅ app-sandbox 존재" || { echo "🔴 app-sandbox 누락"; exit 1; }

echo "✅ 재제출 entitlements 가드 통과"
```
