import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// DarwinForge Mobile Design Tokens.
///
/// Single source of truth for color, typography, spacing, radius, shadow and
/// motion. Inspired by Apple HIG + PRD §7.12. The goal is that *no* screen
/// or component reaches past these tokens to raw `Color(.systemRed)` /
/// `padding(13)` magic numbers.
public enum DS {

    // MARK: - Color

    public enum Color {

        // Surfaces
        public static var canvas: SwiftUI.Color {
            #if canImport(UIKit)
            SwiftUI.Color(UIColor.systemBackground)
            #else
            SwiftUI.Color(nsColor: .windowBackgroundColor)
            #endif
        }
        public static var surface: SwiftUI.Color {
            #if canImport(UIKit)
            SwiftUI.Color(UIColor.secondarySystemBackground)
            #else
            SwiftUI.Color(nsColor: .controlBackgroundColor)
            #endif
        }
        public static var elevated: SwiftUI.Color {
            #if canImport(UIKit)
            SwiftUI.Color(UIColor.tertiarySystemBackground)
            #else
            SwiftUI.Color(nsColor: .controlColor)
            #endif
        }
        public static var divider: SwiftUI.Color {
            #if canImport(UIKit)
            SwiftUI.Color(UIColor.separator)
            #else
            SwiftUI.Color(nsColor: .separatorColor)
            #endif
        }

        // Foreground roles
        public static let primaryText: SwiftUI.Color = .primary
        public static let secondaryText: SwiftUI.Color = .secondary
        public static let tertiaryText: SwiftUI.Color = .secondary.opacity(0.6)

        // Semantic
        public static let accent: SwiftUI.Color = .accentColor
        public static let success: SwiftUI.Color = SwiftUI.Color(red: 0.20, green: 0.78, blue: 0.35)
        public static let warning: SwiftUI.Color = SwiftUI.Color(red: 1.00, green: 0.62, blue: 0.04)
        public static let danger:  SwiftUI.Color = SwiftUI.Color(red: 0.98, green: 0.27, blue: 0.27)
        public static let info:    SwiftUI.Color = SwiftUI.Color(red: 0.20, green: 0.55, blue: 0.96)

        // Brand
        public static let brand:   SwiftUI.Color = SwiftUI.Color(red: 0.13, green: 0.45, blue: 0.92)
        public static let brandSoft: SwiftUI.Color = SwiftUI.Color(red: 0.13, green: 0.45, blue: 0.92).opacity(0.16)

        // Joystick / pad surfaces
        public static let padBase: SwiftUI.Color = SwiftUI.Color.gray.opacity(0.14)
        public static let padActive: SwiftUI.Color = SwiftUI.Color.accentColor.opacity(0.22)
        public static let padThumb: SwiftUI.Color = SwiftUI.Color.accentColor

        // Disabled
        public static let disabled: SwiftUI.Color = .secondary.opacity(0.45)
    }

    // MARK: - Typography

    public enum Font {
        public static var screenTitle: SwiftUI.Font { .title2.weight(.semibold) }
        public static var sectionTitle: SwiftUI.Font { .headline }
        public static var body: SwiftUI.Font { .body }
        public static var bodyEmphasis: SwiftUI.Font { .body.weight(.semibold) }
        public static var caption: SwiftUI.Font { .caption }
        public static var captionEmphasis: SwiftUI.Font { .caption.weight(.semibold) }
        public static var metric: SwiftUI.Font { .title3.monospacedDigit().weight(.semibold) }
        public static var metricLarge: SwiftUI.Font { .title.monospacedDigit().weight(.bold) }
        public static var button: SwiftUI.Font { .body.weight(.semibold) }
        public static var chipLabel: SwiftUI.Font { .subheadline.weight(.semibold) }
    }

    // MARK: - Spacing

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs:  CGFloat = 4
        public static let s:   CGFloat = 8
        public static let m:   CGFloat = 12
        public static let l:   CGFloat = 16
        public static let xl:  CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    public enum Radius {
        public static let xs: CGFloat = 6
        public static let s:  CGFloat = 10
        public static let m:  CGFloat = 14
        public static let l:  CGFloat = 18
        public static let xl: CGFloat = 24
        public static let pill: CGFloat = 999
    }

    // MARK: - Stroke

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let regular: CGFloat = 1
        public static let emphasis: CGFloat = 2
    }

    // MARK: - Shadow

    public struct Shadow {
        public let color: SwiftUI.Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat
    }

    public enum Shadows {
        public static let card = Shadow(color: .black.opacity(0.05),
                                        radius: 10, x: 0, y: 2)
        public static let elevated = Shadow(color: .black.opacity(0.12),
                                            radius: 18, x: 0, y: 6)
        public static let pressed = Shadow(color: .black.opacity(0.18),
                                           radius: 4, x: 0, y: 1)
    }

    // MARK: - Touch targets

    public enum Hit {
        public static let minimum: CGFloat = 44
        public static let estop:   CGFloat = 56
        public static let padZone: CGFloat = 72
    }

    // MARK: - Motion

    public enum Motion {
        public static var quick: Animation { .easeOut(duration: 0.12) }
        public static var standard: Animation { .easeInOut(duration: 0.22) }
        public static var slow: Animation { .easeInOut(duration: 0.36) }
        public static var spring: Animation { .spring(response: 0.36, dampingFraction: 0.7) }
    }
}

// MARK: - View modifiers

public extension View {
    /// Apply a DS shadow.
    func dsShadow(_ shadow: DS.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// Apply minimum hit target (centered).
    func dsMinHit(_ size: CGFloat = DS.Hit.minimum) -> some View {
        self.frame(minWidth: size, minHeight: size)
    }
}
