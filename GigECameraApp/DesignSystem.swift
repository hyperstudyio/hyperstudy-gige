//
//  DesignSystem.swift
//  GigEVirtualCamera
//
//  Created on 6/24/25.
//

import SwiftUI

struct DesignSystem {
    // MARK: - Colors
    //
    // Semantic colors first; raw hues only when nothing else fits. Every named
    // color resolves through NSColor's system palette so it adapts to light/
    // dark mode and high-contrast preferences automatically.
    struct Colors {
        // Status indicators (use these instead of Color.green / .red / .yellow
        // / .orange so the UI follows the system appearance and accessibility
        // contrast settings).
        static let statusSuccess = Color(nsColor: .systemGreen)
        static let statusWarning = Color(nsColor: .systemYellow)
        static let statusError = Color(nsColor: .systemRed)
        static let statusOrange = Color(nsColor: .systemOrange)
        static let statusInfo = Color(nsColor: .systemBlue)

        // Legacy aliases retained so existing call sites keep compiling.
        static let statusGreen = statusSuccess
        static let statusRed = statusError

        // Text + chrome.
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textOnAccent = Color.white
        static let separator = Color(nsColor: .separatorColor)
        static let border = Color(nsColor: .separatorColor)

        // Surfaces.
        static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
        static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
        /// Pure-black surface for video preview; intentionally NOT semantic so
        /// it stays black in both light and dark mode (matches what
        /// professional video apps do).
        static let videoSurface = Color.black
        static let logSurface = Color(nsColor: .black).opacity(0.35)

        // Log-level colors (resolve through the system palette).
        static let logError = Color(nsColor: .systemRed)
        static let logWarning = Color(nsColor: .systemYellow)
        static let logInfo = Color(nsColor: .labelColor)
        static let logDebug = Color(nsColor: .secondaryLabelColor)
        static let logCategory = Color(nsColor: .systemTeal)

        static let primary = Color.accentColor
    }

    // MARK: - Typography
    //
    // San Francisco (system default) is the right typeface for a clinical /
    // pro tool. Rounded is reserved for the largest display title only.
    struct Typography {
        static let largeTitle = Font.system(.largeTitle, design: .default).weight(.semibold)
        static let title = Font.system(.title, design: .default).weight(.semibold)
        static let headline = Font.system(.headline, design: .default)
        static let body = Font.system(.body)
        static let callout = Font.system(.callout)
        static let caption = Font.system(.caption)
        static let footnote = Font.system(.footnote)
    }
    
    // MARK: - Spacing
    struct Spacing {
        static let xxSmall: CGFloat = 4
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 10
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 20
        static let xxLarge: CGFloat = 24
    }
    
    // MARK: - Corner Radius
    struct CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 16
    }
    
    // MARK: - Animation
    struct Animation {
        static let fast = SwiftUI.Animation.easeInOut(duration: 0.2)
        static let medium = SwiftUI.Animation.easeInOut(duration: 0.3)
        static let slow = SwiftUI.Animation.easeInOut(duration: 0.5)
        static let spring = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.8)
    }
}

// MARK: - View Modifiers

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DesignSystem.Spacing.medium)
            .background(DesignSystem.Colors.backgroundSecondary)
            .cornerRadius(DesignSystem.CornerRadius.medium)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}