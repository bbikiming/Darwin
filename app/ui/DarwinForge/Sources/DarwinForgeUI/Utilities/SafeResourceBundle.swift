import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// V297-11 CRASH FIX (2026-05-27) — Bundle.module 의 fatalError 회피.
///
/// # 문제
///
/// SwiftPM 가 생성하는 `Bundle.module` accessor 는 .app 루트의 resource bundle 을
/// 첫 candidate 로 본다. 우리 archive-app.sh 는 codesign 호환을 위해 .app 루트의
/// .bundle 사본을 제거하므로, TestFlight 배포 시 Bundle.module 가 못 찾고 즉시
/// `fatalError("unable to find bundle named ...")` 로 앱 강제 종료.
///
/// 첫 화면 (DarwinForgeLogo) 가 wordmark 이미지 로드 직후 발생 → 사용자가 어떤
/// 화면도 못 봄.
///
/// # 비유
///
/// 도서관 책 찾기 — Bundle.module 은 "1번 책장에 없으면 즉시 항복". 우리 helper 는
/// 1번 → 2번 → 3번 책장 순회 후 못 찾으면 빈손으로 돌아옴 (앱 죽음 아님).
///
/// # 검색 순서
///
/// 1. `Bundle.main.bundleURL/Contents/Resources/<name>.bundle` — macOS .app 표준 위치
/// 2. `Bundle.main.resourceURL/<name>.bundle` — 1번과 동일 경로 (대안 표현)
/// 3. `Bundle.main.bundleURL/<name>.bundle` — .app 루트 (SwiftPM dev 경로)
/// 4. `Bundle(for: BundleFinder.self).resourceURL/<name>.bundle` — module bundle
///
/// 못 찾으면 `nil` 반환. caller 는 텍스트 fallback 또는 throw 로 정상 처리.
public enum SafeResourceBundle {

    /// SwiftPM 가 생성하는 bundle name 추론.
    /// 우리 프로젝트: `DarwinForge_DarwinForgeUI`, `DarwinForge_DarwinForgeApp`.
    public static let defaultModuleNames = [
        "DarwinForge_DarwinForgeUI",
        "DarwinForge_DarwinForgeApp",
    ]

    /// 이름으로 resource bundle 찾기. 못 찾으면 nil.
    public static func find(moduleName: String) -> Bundle? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(moduleName).bundle"),
            Bundle.main.resourceURL?.appendingPathComponent("\(moduleName).bundle"),
            Bundle.main.bundleURL.appendingPathComponent("\(moduleName).bundle"),
            Bundle(for: BundleFinder.self).resourceURL?.appendingPathComponent("\(moduleName).bundle"),
        ]
        for candidate in candidates {
            guard let url = candidate else { continue }
            if fm.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    /// 여러 module 후보에서 첫 번째로 찾은 bundle 반환.
    public static func findAny(moduleNames: [String] = SafeResourceBundle.defaultModuleNames) -> Bundle? {
        for name in moduleNames {
            if let b = find(moduleName: name) { return b }
        }
        return nil
    }

    #if canImport(AppKit)
    /// Image 안전 lookup. 모든 bundle 못 찾으면 nil 반환 (fatalError 아님).
    public static func image(named name: String,
                              moduleNames: [String] = SafeResourceBundle.defaultModuleNames) -> NSImage? {
        // 1. 후보 module bundle 들 순회.
        for moduleName in moduleNames {
            if let bundle = find(moduleName: moduleName),
               let image = bundle.image(forResource: NSImage.Name(name)) {
                return image
            }
        }
        // 2. Bundle.main 의 Asset catalog 또는 직접 파일.
        if let image = Bundle.main.image(forResource: NSImage.Name(name)) {
            return image
        }
        // 3. Bundle.main 의 resourceURL 에서 PNG / SVG 직접 시도.
        for ext in ["png", "svg", "pdf"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
    #endif

    /// Resource URL 안전 lookup.
    public static func url(forResource name: String,
                            withExtension ext: String?,
                            subdirectory: String? = nil,
                            moduleNames: [String] = SafeResourceBundle.defaultModuleNames) -> URL? {
        for moduleName in moduleNames {
            if let bundle = find(moduleName: moduleName),
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}

/// SafeResourceBundle 가 module bundle 의 resourceURL 을 조회할 때 사용하는 anchor.
/// Swift 의 `Bundle(for: AnyClass.self)` 는 그 class 가 정의된 모듈의 bundle 반환.
private final class BundleFinder {}
