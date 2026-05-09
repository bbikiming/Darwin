# app/ui/

SwiftUI 앱 본체. macOS 14+ 네이티브.

## 현재 상태

[`DarwinForge/`](DarwinForge/) — Phase 1~4 사이에 작성된 SwiftPM 패키지(11 targets). Phase 4에서 `app/core/` Rust 크레이트가 등장하면 일부 Swift 모듈(`DynamixelKit`, `RobotKit`)은 Rust로 대체되거나 thin wrapper가 된다.

## 빌드

Mac에서:
```sh
swift build  --package-path app/ui/DarwinForge
swift test   --package-path app/ui/DarwinForge
xed app/ui/DarwinForge/Package.swift   # Xcode에서 열기
```
