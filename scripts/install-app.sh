#!/usr/bin/env bash
# DarwinForge.app 번들 빌드 + /Applications 설치.
#
# 동작:
#   1. swift build -c release 로 release binary 생성
#   2. tmp 에 DarwinForge.app/Contents/{MacOS, Resources, Info.plist} 구성
#   3. AppIcon.swift 에서 PNG (16/32/128/256/512 + @2x) 생성 → iconset → icns
#   4. /Applications/DarwinForge.app 으로 rsync (기존 버전 덮어쓰기)
#   5. open /Applications/DarwinForge.app
#
# 의존성: swift 6+, iconutil (macOS 기본).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="$REPO_ROOT/app/ui/DarwinForge"
APP_NAME="DarwinForge"
BUNDLE_ID="com.darwinforge.app"
DEST_DIR="/Applications"
TMP_DIR="$(mktemp -d -t darwinforge-install-XXXXXX)"
APP_BUNDLE="$TMP_DIR/$APP_NAME.app"

cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "▶ Building $APP_NAME (release)..."
cd "$PKG_ROOT"
swift build -c release --product DarwinForgeApp 2>&1 | tail -5

EXEC_PATH="$PKG_ROOT/.build/release/DarwinForgeApp"
if [ ! -f "$EXEC_PATH" ]; then
    echo "ERROR: 빌드 결과 없음 — $EXEC_PATH" >&2
    exit 1
fi

echo "▶ $APP_NAME.app 번들 구성..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Executable 복사 (DarwinForgeApp → MacOS/DarwinForge — bundle 이름과 일치).
cp "$EXEC_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Info.plist — 최소 필수 키 + Bundle ID + Icon 참조.
VERSION="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "dev")"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>DarwinForge</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0-$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>원격 조종 화면에서 로봇의 제어 브리지와 8080 카메라 미리보기에 연결합니다.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# === AppIcon.icns 생성 ===
# 우선순위 (Phase G13, 2026-05-15 — 영구 PNG 아이콘 적용):
#   1. ICON_SOURCE env var 가 가리키는 PNG (명시 override)
#   2. $REPO_ROOT/app/icon/AppIcon.png (표준 영구 경로)
#   3. Swift 단일 실행기로 AppIcon.swift 의 기하학 도형 fallback (legacy)
echo "▶ AppIcon.icns 생성..."
ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Phase G13 — 표준 영구 경로 자동 인식. ICON_SOURCE 명시 안 했고 표준 PNG 가 있으면 사용.
DEFAULT_ICON_PATH="$REPO_ROOT/app/icon/AppIcon.png"
if [ -z "${ICON_SOURCE:-}" ] && [ -f "$DEFAULT_ICON_PATH" ]; then
    ICON_SOURCE="$DEFAULT_ICON_PATH"
    echo "  ✓ 표준 영구 PNG 자동 사용: app/icon/AppIcon.png"
fi

# macOS iconset 표준 사이즈 — Apple HIG.
ICONSET_SIZES=(
    "icon_16x16.png 16"
    "icon_16x16@2x.png 32"
    "icon_32x32.png 32"
    "icon_32x32@2x.png 64"
    "icon_128x128.png 128"
    "icon_128x128@2x.png 256"
    "icon_256x256.png 256"
    "icon_256x256@2x.png 512"
    "icon_512x512.png 512"
    "icon_512x512@2x.png 1024"
)

if [ -n "${ICON_SOURCE:-}" ] && [ -f "$ICON_SOURCE" ]; then
    echo "  외부 아이콘 사용: $ICON_SOURCE"
    for entry in "${ICONSET_SIZES[@]}"; do
        name="${entry%% *}"
        size="${entry##* }"
        sips -s format png -z "$size" "$size" "$ICON_SOURCE" \
            --out "$ICONSET_DIR/$name" >/dev/null 2>&1 \
            || { echo "  error: sips 리사이즈 실패 ($name)" >&2; exit 1; }
        echo "  ✓ $name (${size}×${size})"
    done
    # iconset → icns.
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "▶ AppIcon.icns 생성 완료 (외부 PNG 기반)"
else

# Swift 단일 실행기 — DarwinForgeApp 빌드 결과를 재사용해 PNG 추출 (fallback).
ICON_TOOL="$TMP_DIR/icon-tool.swift"
cat > "$ICON_TOOL" <<'SWIFT'
import AppKit
import Foundation

// AppIcon 정의 — DarwinForgeApp 모듈과 동일 (단일 파일 모드라 inline copy).
enum AppIcon {
    static func make(size: CGFloat = 1024) -> NSImage {
        let canvas = CGSize(width: size, height: size)
        let image = NSImage(size: canvas)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        drawBackground(in: ctx, size: canvas)
        drawOPGlyphs(in: ctx, size: canvas)
        return image
    }
    static func pngData(size: CGFloat) -> Data? {
        let image = make(size: size)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
    static func drawBackground(in ctx: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let cornerRadius = size.width * 0.2237
        let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
        let colors: [CGColor] = [
            CGColor(red: 1.00, green: 0.416, blue: 0.000, alpha: 1.0),
            CGColor(red: 1.00, green: 0.541, blue: 0.239, alpha: 1.0),
        ]
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
        ctx.setLineWidth(size.width * 0.012)
        ctx.addPath(bgPath); ctx.strokePath()
        ctx.restoreGState()
    }
    static func drawOPGlyphs(in ctx: CGContext, size: CGSize) {
        let s = size.width; let unit = s / 1024.0
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 16 * unit,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.15))
        drawDonut(in: ctx, center: CGPoint(x: 305 * unit, y: 512 * unit),
                  outerRadius: 200 * unit, innerRadius: 100 * unit)
        let pStemX = 580 * unit
        let stemRect = CGRect(x: pStemX, y: 312 * unit, width: 100 * unit, height: 400 * unit)
        let stemPath = CGPath(roundedRect: stemRect, cornerWidth: 50 * unit, cornerHeight: 50 * unit, transform: nil)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(stemPath); ctx.fillPath()
        drawDonut(in: ctx, center: CGPoint(x: pStemX + 100 * unit + 50 * unit, y: 612 * unit),
                  outerRadius: 130 * unit, innerRadius: 60 * unit)
        ctx.restoreGState()
    }
    static func drawDonut(in ctx: CGContext, center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat) {
        let outerRect = CGRect(x: center.x - outerRadius, y: center.y - outerRadius,
                                width: outerRadius * 2, height: outerRadius * 2)
        let innerRect = CGRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                width: innerRadius * 2, height: innerRadius * 2)
        let path = CGMutablePath()
        path.addEllipse(in: outerRect); path.addEllipse(in: innerRect)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(path); ctx.fillPath(using: .evenOdd)
    }
}

let outDir = ProcessInfo.processInfo.environment["ICONSET_DIR"]!
// macOS iconset 표준 — Apple HIG 권장.
let entries: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]
for entry in entries {
    guard let data = AppIcon.pngData(size: entry.size) else {
        FileHandle.standardError.write("Failed: \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(entry.name)
    try? data.write(to: url)
    print("  ✓ \(entry.name)")
}
SWIFT

ICONSET_DIR="$ICONSET_DIR" swift "$ICON_TOOL"

# iconset → icns.
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

fi  # end ICON_SOURCE branch

# === /Applications 설치 ===
echo "▶ /Applications/$APP_NAME.app 설치..."
if [ -d "$DEST_DIR/$APP_NAME.app" ]; then
    # 기존 버전 백업 (사용자 데이터 보존).
    BACKUP="$DEST_DIR/$APP_NAME.app.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$DEST_DIR/$APP_NAME.app" "$BACKUP"
    echo "  기존 버전 backup: $BACKUP"
fi
cp -R "$APP_BUNDLE" "$DEST_DIR/"

# macOS Quarantine 제거 — `swift build` 결과는 codesigned 아님.
xattr -dr com.apple.quarantine "$DEST_DIR/$APP_NAME.app" 2>/dev/null || true

# Finder 가 새 아이콘 인식하도록 LaunchServices DB 갱신.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$DEST_DIR/$APP_NAME.app" 2>/dev/null || true

echo ""
echo "✅ 설치 완료: $DEST_DIR/$APP_NAME.app"
echo "   • 버전: 1.0.0-$VERSION"
echo "   • Bundle ID: $BUNDLE_ID"
echo ""
echo "실행:"
echo "   open '$DEST_DIR/$APP_NAME.app'"
