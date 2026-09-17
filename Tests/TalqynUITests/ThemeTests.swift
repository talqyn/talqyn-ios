#if os(iOS)
import UIKit
import XCTest
@testable import TalqynUI

@MainActor
final class ThemeTests: XCTestCase {
    private let light = TalqynTheme.Colors(
        accent: .red, background: .white, surface: .white, surfaceSecondary: .lightGray,
        border: .gray, textPrimary: .black, textSecondary: .darkGray, textTertiary: .gray
    )
    private let dark = TalqynTheme.Colors(
        accent: .orange, background: .black, surface: .darkGray, surfaceSecondary: .black,
        border: .darkGray, textPrimary: .white, textSecondary: .lightGray, textTertiary: .gray
    )

    private func resolved(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UIColor {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    /// The two flat palettes become one that follows the appearance.
    func testPairedPaletteResolvesPerAppearance() {
        let paired = TalqynTheme.Colors(light: light, dark: dark)
        XCTAssertEqual(resolved(paired.accent, .light), resolved(.red, .light))
        XCTAssertEqual(resolved(paired.accent, .dark), resolved(.orange, .dark))
        XCTAssertEqual(resolved(paired.background, .light), resolved(.white, .light))
        XCTAssertEqual(resolved(paired.background, .dark), resolved(.black, .dark))
        XCTAssertEqual(resolved(paired.textPrimary, .dark), resolved(.white, .dark))
    }

    /// Every role is paired, not just the ones a screen happens to use first.
    func testEveryRoleIsPaired() {
        let paired = TalqynTheme.Colors(light: light, dark: dark)
        let roles: [(String, KeyPath<TalqynTheme.Colors, UIColor>)] = [
            ("accent", \.accent), ("onAccent", \.onAccent), ("background", \.background),
            ("surface", \.surface), ("surfaceSecondary", \.surfaceSecondary), ("border", \.border),
            ("textPrimary", \.textPrimary), ("textSecondary", \.textSecondary),
            ("textTertiary", \.textTertiary), ("bubble", \.bubble), ("onBubble", \.onBubble),
            ("warning", \.warning), ("error", \.error), ("rating", \.rating), ("shadow", \.shadow),
        ]
        for (name, role) in roles {
            XCTAssertEqual(
                resolved(paired[keyPath: role], .light), resolved(light[keyPath: role], .light),
                "\(name) does not follow the light palette"
            )
            XCTAssertEqual(
                resolved(paired[keyPath: role], .dark), resolved(dark[keyPath: role], .dark),
                "\(name) does not follow the dark palette"
            )
        }
    }

    /// Notices and the clarify card stand off the screen in both appearances.
    /// In light mode the system's tertiary grouped background is the grouped
    /// background itself, so the default takes a grey of its own there.
    func testTheDefaultSecondarySurfaceStandsOffTheBackground() {
        let colors = TalqynTheme.Colors.system
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertNotEqual(
                resolved(colors.surfaceSecondary, style), resolved(colors.background, style),
                "the secondary surface vanishes into the screen in style \(style.rawValue)"
            )
        }
        XCTAssertEqual(
            resolved(colors.surfaceSecondary, .light), UIColor(red: 0xE9 / 255, green: 0xE9 / 255, blue: 0xEF / 255, alpha: 1)
        )
        XCTAssertEqual(resolved(colors.surfaceSecondary, .dark), resolved(.tertiarySystemGroupedBackground, .dark))
    }

    /// The shopper's bubble falls back to the accent, so a palette written
    /// before the role existed looks the same.
    func testBubbleDefaultsToTheAccent() {
        XCTAssertEqual(light.bubble, light.accent)
        XCTAssertEqual(light.onBubble, light.onAccent)
        let own = TalqynTheme.Colors(
            accent: .red, background: .white, surface: .white, surfaceSecondary: .lightGray,
            border: .gray, textPrimary: .black, textSecondary: .darkGray, textTertiary: .gray,
            bubble: .blue, onBubble: .yellow
        )
        XCTAssertEqual(own.bubble, .blue)
        XCTAssertEqual(own.onBubble, .yellow)
    }

    /// The icon set is all defaults until an app replaces a role, and a role
    /// set to `nil` draws nothing rather than falling back to a symbol.
    func testIconsDefaultToSymbolsAndTakeReplacements() {
        XCTAssertNotNil(TalqynTheme.Icons.system.emptyState)
        XCTAssertNotNil(TalqynTheme.Icons.system.send)
        XCTAssertNotNil(TalqynTheme.Icons.system.rateHelpfulOn)

        var icons = TalqynTheme.Icons.system
        let own = UIImage(systemName: "star")
        icons.newChat = own
        icons.emptyState = nil
        XCTAssertEqual(icons.newChat, own)
        XCTAssertNil(icons.emptyState)
        XCTAssertNotNil(icons.history, "replacing one role must not disturb the others")
    }

    /// A symbol takes the size the screen asks for; an app's own artwork keeps
    /// the size it was drawn at, because a symbol configuration means nothing
    /// to it.
    func testSizingASymbolLeavesOtherArtworkAlone() throws {
        let symbol = try XCTUnwrap(UIImage(systemName: "star"))
        XCTAssertGreaterThan(
            symbol.talqynSized(28).size.height, symbol.size.height,
            "a symbol should grow to the asked size"
        )

        let drawn = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        XCTAssertEqual(drawn.talqynSized(28).size, drawn.size, "artwork must not be resized by an icon size")
    }

    /// The metrics are the screen's design until an app moves them.
    func testMetricsCarryTheDesignAndAreReplaceable() {
        XCTAssertEqual(TalqynTheme.Metrics.default.cornerRadius, 12)
        XCTAssertEqual(TalqynTheme.Metrics.default.composerRadius, 28)
        XCTAssertEqual(TalqynTheme.Metrics.default.chipHeight, 36)
        XCTAssertEqual(TalqynTheme.Metrics.default.cardRadius, 8)
        XCTAssertEqual(TalqynTheme.Metrics.default.bubbleRadius, 16)
        XCTAssertEqual(TalqynTheme.Metrics.default.maxContentWidth, 720)

        let square = TalqynTheme(metrics: .init(cornerRadius: 4, composerRadius: 8, chipHeight: 28))
        XCTAssertEqual(square.cornerRadius, 4, "the card radius still reads off the theme")
        XCTAssertEqual(square.metrics.composerRadius, 8)
        XCTAssertEqual(TalqynChipView(theme: square, title: "Yes").intrinsicChipHeight, 28)
    }

    /// Reduce motion takes the travel out and leaves the change: a duration
    /// of zero, and no animated scroll. Read from the system, so the test
    /// states the rule rather than the device's current setting.
    func testMotionFollowsTheSystemPreference() {
        if TalqynMotion.isReduced {
            XCTAssertEqual(TalqynMotion.duration(0.45), 0)
            XCTAssertFalse(TalqynMotion.animates())
        } else {
            XCTAssertEqual(TalqynMotion.duration(0.45), 0.45)
            XCTAssertTrue(TalqynMotion.animates())
            XCTAssertFalse(TalqynMotion.animates(false), "a caller asking for no animation still gets none")
        }
    }

    /// A chip or a thumb is drawn at its design size and still takes a
    /// finger-sized tap.
    func testSmallControlsTakeAFingerSizedTap() {
        let chip = TalqynChipView(theme: .default, title: "Yes")
        chip.frame = CGRect(x: 0, y: 0, width: 60, height: 36)
        XCTAssertTrue(chip.point(inside: CGPoint(x: 30, y: -3), with: nil), "4 points above a 36-point chip")
        XCTAssertFalse(chip.point(inside: CGPoint(x: 30, y: -6), with: nil))

        let thumb = TalqynHitAreaButton(type: .system)
        thumb.frame = CGRect(x: 0, y: 0, width: 36, height: 32)
        XCTAssertTrue(thumb.point(inside: CGPoint(x: -3, y: -5), with: nil))
        XCTAssertFalse(thumb.point(inside: CGPoint(x: -5, y: 16), with: nil))
    }

    /// Haptics are on unless the app runs its own.
    func testHapticsCanBeTurnedOff() {
        XCTAssertTrue(TalqynTheme().hapticsEnabled)
        XCTAssertFalse(TalqynTheme(hapticsEnabled: false).hapticsEnabled)
    }

    /// A pinned appearance is carried to the screens as an override, which is
    /// what makes a dynamic palette resolve to the half the theme asked for.
    func testAppearanceMapsToAnInterfaceStyle() {
        XCTAssertEqual(TalqynTheme.Appearance.system.interfaceStyle, .unspecified)
        XCTAssertEqual(TalqynTheme.Appearance.light.interfaceStyle, .light)
        XCTAssertEqual(TalqynTheme.Appearance.dark.interfaceStyle, .dark)
        XCTAssertEqual(TalqynTheme().appearance.interfaceStyle, .unspecified)
    }
}
#endif
