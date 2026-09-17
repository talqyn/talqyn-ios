#if os(iOS)
import UIKit

/// What the consultant screens look like: the client's colors and fonts.
///
/// The SDK draws every element itself; the app registers the palette and the
/// type once and every screen follows it. Register custom font files with the
/// system before building ``Fonts`` from their names — the SDK only refers to
/// fonts, it does not load them.
///
/// ```swift
/// let theme = TalqynTheme(
///     colors: .init(accent: .brand, ...),
///     fonts: .custom(regular: "MuseoSansCyrl-500", bold: "MuseoSansCyrl-700")
/// )
/// let screen = TalqynConsultantViewController(talqyn: talqyn, theme: theme)
/// ```
///
/// Every color is a `UIColor`, so a dynamic color — from an asset catalog or
/// from ``Colors/init(light:dark:)`` — gives the screens a dark appearance.
/// ``appearance`` pins which half is used when the screens must not follow the
/// device.
public struct TalqynTheme: Sendable {
    /// The palette. Named by role, not by shade, so an app maps its own tokens
    /// onto it without guessing what "grey 65" is for.
    public struct Colors: Sendable {
        /// Buttons, links, the shopper's bubble, the active state of a chip.
        public var accent: UIColor
        /// Text on ``accent``.
        public var onAccent: UIColor
        /// The screen background.
        public var background: UIColor
        /// Cards, the composer, the navigation bar.
        public var surface: UIColor
        /// Notices, chips, the clarify card — one step off the surface.
        public var surfaceSecondary: UIColor
        /// Dividers and chip outlines.
        public var border: UIColor
        /// Body text, prices, titles.
        public var textPrimary: UIColor
        /// Secondary text: status lines, labels, product titles.
        public var textSecondary: UIColor
        /// Placeholders, struck-through prices, disabled controls.
        public var textTertiary: UIColor
        /// The shopper's own message. Defaults to ``accent``; set it when the
        /// brand's bubble is not the brand's button.
        public var bubble: UIColor
        /// Text on ``bubble``. Defaults to ``onAccent``.
        public var onBubble: UIColor
        /// A turn that degraded: products are there, the text is not.
        public var warning: UIColor
        /// A turn that failed.
        public var error: UIColor
        /// The stars of a product's rating. Its own role rather than
        /// ``warning``: a brand whose warning is orange does not necessarily
        /// want orange stars.
        public var rating: UIColor
        /// What falls under the composer and the scroll-to-bottom button.
        /// Carry the strength in the alpha — `.black.withAlphaComponent(0.12)`
        /// is the default — and use `.clear` for a flat design with no shadows
        /// at all.
        public var shadow: UIColor

        /// Creates a palette.
        ///
        /// Pass dynamic `UIColor`s — from an asset catalog, or from
        /// ``init(light:dark:)`` — to follow the device's appearance. Flat
        /// colors are drawn as given, whatever the appearance.
        public init(
            accent: UIColor,
            onAccent: UIColor = .white,
            background: UIColor,
            surface: UIColor,
            surfaceSecondary: UIColor,
            border: UIColor,
            textPrimary: UIColor,
            textSecondary: UIColor,
            textTertiary: UIColor,
            bubble: UIColor? = nil,
            onBubble: UIColor? = nil,
            warning: UIColor = .systemYellow,
            error: UIColor = .systemRed,
            rating: UIColor = .systemYellow,
            shadow: UIColor = UIColor.black.withAlphaComponent(0.12)
        ) {
            self.accent = accent
            self.onAccent = onAccent
            self.background = background
            self.surface = surface
            self.surfaceSecondary = surfaceSecondary
            self.border = border
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.textTertiary = textTertiary
            self.bubble = bubble ?? accent
            self.onBubble = onBubble ?? onAccent
            self.warning = warning
            self.error = error
            self.rating = rating
            self.shadow = shadow
        }

        /// A palette that follows the appearance: every color resolves to the
        /// one from `light` or from `dark`.
        ///
        /// This is the short way to a dark mode when the app's colors are
        /// plain values rather than asset-catalog sets: write the two palettes
        /// flat and let the SDK pair them up.
        ///
        /// ```swift
        /// let colors = TalqynTheme.Colors(light: .brandLight, dark: .brandDark)
        /// ```
        ///
        /// Which of the two is used follows the device, unless the theme's
        /// ``TalqynTheme/appearance`` pins it.
        ///
        /// - Parameters:
        ///   - light: The palette for a light appearance.
        ///   - dark: The palette for a dark one.
        public init(light: Colors, dark: Colors) {
            func pair(_ key: KeyPath<Colors, UIColor>) -> UIColor {
                UIColor { $0.userInterfaceStyle == .dark ? dark[keyPath: key] : light[keyPath: key] }
            }
            accent = pair(\.accent)
            onAccent = pair(\.onAccent)
            background = pair(\.background)
            surface = pair(\.surface)
            surfaceSecondary = pair(\.surfaceSecondary)
            border = pair(\.border)
            textPrimary = pair(\.textPrimary)
            textSecondary = pair(\.textSecondary)
            textTertiary = pair(\.textTertiary)
            bubble = pair(\.bubble)
            onBubble = pair(\.onBubble)
            warning = pair(\.warning)
            error = pair(\.error)
            rating = pair(\.rating)
            shadow = pair(\.shadow)
        }

        /// A neutral palette on system colors: follows light and dark mode and
        /// looks like nobody's brand, which is the point of a default.
        ///
        /// The grouped family throughout: in dark mode `systemBackground` is
        /// as black as the grouped background, and cards drawn on it vanish
        /// into the screen. One level departs from it in light mode: there the
        /// tertiary grouped background is the grouped background itself,
        /// #F2F2F7, and notices and the clarify card drawn on it would vanish
        /// the same way. The secondary surface is a grey of its own in light
        /// mode, #E9E9EF — the Android SDK's — and the tertiary grouped
        /// background in dark mode, where the levels do stay apart.
        public static let system = Colors(
            accent: .systemBlue,
            onAccent: .white,
            background: .systemGroupedBackground,
            surface: .secondarySystemGroupedBackground,
            surfaceSecondary: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.tertiarySystemGroupedBackground.resolvedColor(with: traits)
                    : UIColor(red: 0xE9 / 255, green: 0xE9 / 255, blue: 0xEF / 255, alpha: 1)
            },
            border: .separator,
            textPrimary: .label,
            textSecondary: .secondaryLabel,
            textTertiary: .tertiaryLabel
        )
    }

    /// The icons the screens draw. Named by role, like the palette.
    ///
    /// Defaults are SF Symbols; an app with its own icon set passes its own
    /// images and the screens stop looking like the only system-drawn screen
    /// in the app. Pass template images (`withRenderingMode(.alwaysTemplate)`,
    /// or a template asset) for the SDK's tint to reach them; a multicolor
    /// icon is drawn as it is.
    ///
    /// ```swift
    /// var icons = TalqynTheme.Icons.system
    /// icons.newChat = UIImage(named: "pds.edit")!
    /// ```
    ///
    /// A `nil` role draws nothing — an empty screen without its sparkle, a
    /// button with only its label.
    public struct Icons: Sendable {
        /// Over the title on an empty screen.
        public var emptyState: UIImage?
        /// Opens the chat history, on the left of the bar.
        public var history: UIImage?
        /// Starts a new chat, on the right of the bar.
        public var newChat: UIImage?
        /// Sends the question.
        public var send: UIImage?
        /// Stops an answer while it streams.
        public var stop: UIImage?
        /// Jumps to the end of the transcript.
        public var scrollToBottom: UIImage?
        /// Closes a screen the SDK presented — and the consultant itself, when
        /// it was presented rather than pushed.
        public var close: UIImage?
        /// Goes back from the consultant to the screen it was pushed from.
        public var back: UIImage?
        /// The chosen option of a clarifying question.
        public var checkmark: UIImage?
        /// Rates an answer up.
        public var rateHelpful: UIImage?
        /// The same, once the shopper has. A symbol has a filled twin; custom
        /// art needs its own, or it repeats the unrated one and the tint does
        /// the talking.
        public var rateHelpfulOn: UIImage?
        /// Rates an answer down.
        public var rateNotHelpful: UIImage?
        /// The same, once the shopper has.
        public var rateNotHelpfulOn: UIImage?
        /// Copies an answer.
        public var copyAnswer: UIImage?
        /// Deletes a conversation from the history.
        public var deleteChat: UIImage?
        /// The chip that opens a filtered listing.
        public var filters: UIImage?
        /// The chip that opens the comparison table.
        public var comparison: UIImage?
        /// Puts the shopper's own question back into the composer.
        public var editQuestion: UIImage?
        /// Stands where a product image is missing or still on its way.
        public var imagePlaceholder: UIImage?
        /// An empty star of a product's rating.
        public var ratingStar: UIImage?
        /// A filled star of a product's rating.
        public var ratingStarFilled: UIImage?

        /// Creates an icon set. Every role defaults to its SF Symbol.
        public init(
            emptyState: UIImage? = UIImage(systemName: "sparkles"),
            history: UIImage? = UIImage(systemName: "clock"),
            newChat: UIImage? = UIImage(systemName: "square.and.pencil"),
            send: UIImage? = UIImage(systemName: "arrow.up.circle.fill"),
            stop: UIImage? = UIImage(systemName: "stop.circle.fill"),
            scrollToBottom: UIImage? = UIImage(systemName: "arrow.down"),
            close: UIImage? = UIImage(systemName: "xmark"),
            back: UIImage? = UIImage(systemName: "chevron.backward"),
            checkmark: UIImage? = UIImage(systemName: "checkmark"),
            rateHelpful: UIImage? = UIImage(systemName: "hand.thumbsup"),
            rateHelpfulOn: UIImage? = UIImage(systemName: "hand.thumbsup.fill"),
            rateNotHelpful: UIImage? = UIImage(systemName: "hand.thumbsdown"),
            rateNotHelpfulOn: UIImage? = UIImage(systemName: "hand.thumbsdown.fill"),
            copyAnswer: UIImage? = UIImage(systemName: "doc.on.doc"),
            deleteChat: UIImage? = UIImage(systemName: "trash"),
            filters: UIImage? = UIImage(systemName: "magnifyingglass"),
            comparison: UIImage? = UIImage(systemName: "scale.3d"),
            editQuestion: UIImage? = UIImage(systemName: "pencil"),
            imagePlaceholder: UIImage? = UIImage(systemName: "photo"),
            ratingStar: UIImage? = UIImage(systemName: "star"),
            ratingStarFilled: UIImage? = UIImage(systemName: "star.fill")
        ) {
            self.emptyState = emptyState
            self.history = history
            self.newChat = newChat
            self.send = send
            self.stop = stop
            self.scrollToBottom = scrollToBottom
            self.close = close
            self.back = back
            self.checkmark = checkmark
            self.rateHelpful = rateHelpful
            self.rateHelpfulOn = rateHelpfulOn
            self.rateNotHelpful = rateNotHelpful
            self.rateNotHelpfulOn = rateNotHelpfulOn
            self.copyAnswer = copyAnswer
            self.deleteChat = deleteChat
            self.filters = filters
            self.comparison = comparison
            self.editQuestion = editQuestion
            self.imagePlaceholder = imagePlaceholder
            self.ratingStar = ratingStar
            self.ratingStarFilled = ratingStarFilled
        }

        /// The SF Symbols the screens were designed on.
        public static let system = Icons()
    }

    /// The type scale. Sizes follow the original design of the screen; an app
    /// supplies its family through ``custom(regular:bold:)`` or picks every
    /// font by hand.
    ///
    /// The fonts follow the system text size (Dynamic Type): every font is
    /// read back scaled for the current content size category, up to
    /// ``maximumScale`` times its design size. Set ``maximumScale`` to 1 for
    /// fonts the app has already scaled itself.
    public struct Fonts: Sendable {
        /// The design sizes, as handed in.
        private struct Design: Sendable {
            var title, headline, body, bodyBold, callout, label, footnote, captionBold, caption, micro: UIFont
        }

        private var design: Design

        /// How far the fonts grow with the system text size, as a multiple of
        /// their design size. 1 turns scaling off. Defaults to 1.6, about the
        /// first accessibility size: cards and chips stay laid out as designed
        /// while text is markedly larger.
        public var maximumScale: CGFloat

        /// The empty-state title. 18, bold.
        public var title: UIFont {
            get { scaled(design.title, .title3) }
            set { design.title = newValue }
        }
        /// The navigation title and answer headings. 16, bold.
        public var headline: UIFont {
            get { scaled(design.headline, .headline) }
            set { design.headline = newValue }
        }
        /// Answer text, bubbles, the composer. 15, regular.
        public var body: UIFont {
            get { scaled(design.body, .body) }
            set { design.body = newValue }
        }
        /// Emphasis inside answer text. 15, bold.
        public var bodyBold: UIFont {
            get { scaled(design.bodyBold, .body) }
            set { design.bodyBold = newValue }
        }
        /// Product titles in a row card, the clarify message. 14, regular.
        public var callout: UIFont {
            get { scaled(design.callout, .callout) }
            set { design.callout = newValue }
        }
        /// Labels and small buttons. 13, bold.
        public var label: UIFont {
            get { scaled(design.label, .footnote) }
            set { design.label = newValue }
        }
        /// Notices, secondary text. 13, regular.
        public var footnote: UIFont {
            get { scaled(design.footnote, .footnote) }
            set { design.footnote = newValue }
        }
        /// Section headers, ratings, comparison cells. 12, bold.
        public var captionBold: UIFont {
            get { scaled(design.captionBold, .caption1) }
            set { design.captionBold = newValue }
        }
        /// Compact product titles, reviews count. 12, regular.
        public var caption: UIFont {
            get { scaled(design.caption, .caption1) }
            set { design.caption = newValue }
        }
        /// The character counter. 11, regular.
        public var micro: UIFont {
            get { scaled(design.micro, .caption2) }
            set { design.micro = newValue }
        }

        /// Creates a type scale font by font.
        ///
        /// - Parameter maximumScale: See ``maximumScale``.
        public init(
            title: UIFont,
            headline: UIFont,
            body: UIFont,
            bodyBold: UIFont,
            callout: UIFont,
            label: UIFont,
            footnote: UIFont,
            captionBold: UIFont,
            caption: UIFont,
            micro: UIFont,
            maximumScale: CGFloat = 1.6
        ) {
            design = Design(
                title: title, headline: headline, body: body, bodyBold: bodyBold, callout: callout,
                label: label, footnote: footnote, captionBold: captionBold, caption: caption, micro: micro
            )
            self.maximumScale = maximumScale
        }

        /// The factor the body text is scaled by right now, for layout that
        /// has to keep up with the type: a tile width, a minimum row height.
        var currentScale: CGFloat {
            guard maximumScale > 1 else { return 1 }
            return min(maximumScale, UIFontMetrics(forTextStyle: .body).scaledValue(for: 1))
        }

        private func scaled(_ font: UIFont, _ style: UIFont.TextStyle) -> UIFont {
            guard maximumScale > 1 else { return font }
            return UIFontMetrics(forTextStyle: style).scaledFont(for: font, maximumPointSize: font.pointSize * maximumScale)
        }

        /// The system font at the screen's sizes.
        public static let system = Fonts(
            title: .systemFont(ofSize: 18, weight: .bold),
            headline: .systemFont(ofSize: 16, weight: .bold),
            body: .systemFont(ofSize: 15),
            bodyBold: .systemFont(ofSize: 15, weight: .bold),
            callout: .systemFont(ofSize: 14),
            label: .systemFont(ofSize: 13, weight: .bold),
            footnote: .systemFont(ofSize: 13),
            captionBold: .systemFont(ofSize: 12, weight: .bold),
            caption: .systemFont(ofSize: 12),
            micro: .systemFont(ofSize: 11)
        )

        /// The screen's sizes on the app's own typefaces.
        ///
        /// A name the system does not know falls back to the system font of the
        /// same size and weight rather than to nothing.
        ///
        /// - Parameters:
        ///   - regular: The PostScript name of the regular face.
        ///   - bold: The PostScript name of the bold face.
        public static func custom(regular: String, bold: String) -> Fonts {
            func font(_ name: String, _ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
                UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
            }
            return Fonts(
                title: font(bold, 18, .bold),
                headline: font(bold, 16, .bold),
                body: font(regular, 15, .regular),
                bodyBold: font(bold, 15, .bold),
                callout: font(regular, 14, .regular),
                label: font(bold, 13, .bold),
                footnote: font(regular, 13, .regular),
                captionBold: font(bold, 12, .bold),
                caption: font(regular, 12, .regular),
                micro: font(regular, 11, .regular)
            )
        }
    }

    /// Which appearance the screens are drawn in.
    ///
    /// It decides which half of a dynamic color is used — the palette's own,
    /// an asset catalog's, or ``Colors/init(light:dark:)`` — and it carries
    /// the same way to the material behind the composer and to the system
    /// controls inside the screens.
    public enum Appearance: Sendable {
        /// Whatever the device is set to. The default.
        case system
        /// Always light, even on a device in dark mode.
        case light
        /// Always dark, even on a device in light mode.
        case dark

        var interfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// The shapes and the rhythm: what is round by how much, and how wide the
    /// margins are.
    ///
    /// The sizes are the screen's design; an app whose language is squarer —
    /// or rounder — moves them all from one place rather than living with a
    /// consultant that rounds differently from the rest of it.
    public struct Metrics: Sendable {
        /// Cards, notices, the clarify card. Defaults to 12.
        public var cornerRadius: CGFloat
        /// The composer's pill. Defaults to 28; drop it for a squarer input.
        public var composerRadius: CGFloat
        /// A chip's height. Defaults to 36.
        public var chipHeight: CGFloat
        /// A chip's radius. `nil` — the default — keeps it a pill, whatever
        /// its height; a number squares it off with the rest of the language.
        public var chipRadius: CGFloat?
        /// The margin down both sides of the transcript. Defaults to 16.
        public var horizontalMargin: CGFloat
        /// The image of a card that stands at the full width. Defaults to 84.
        public var rowCardImageSize: CGFloat
        /// The width of a tile in the carousel, at the design text size.
        /// Defaults to 175; it grows with the type.
        public var compactCardWidth: CGFloat
        /// Product cards and the images inside them. Defaults to 8.
        public var cardRadius: CGFloat
        /// The shopper's message bubble; its bottom-trailing corner stays
        /// square. Defaults to 16.
        public var bubbleRadius: CGFloat
        /// The widest the conversation column grows. On a phone the screen is
        /// narrower and this changes nothing; on an iPad a line of the answer
        /// would otherwise run the width of the display. Defaults to 720.
        public var maxContentWidth: CGFloat

        /// Creates a set of metrics.
        public init(
            cornerRadius: CGFloat = 12,
            composerRadius: CGFloat = 28,
            chipHeight: CGFloat = 36,
            chipRadius: CGFloat? = nil,
            horizontalMargin: CGFloat = 16,
            rowCardImageSize: CGFloat = 84,
            compactCardWidth: CGFloat = 175,
            cardRadius: CGFloat = 8,
            bubbleRadius: CGFloat = 16,
            maxContentWidth: CGFloat = 720
        ) {
            self.cornerRadius = cornerRadius
            self.composerRadius = composerRadius
            self.chipHeight = chipHeight
            self.chipRadius = chipRadius
            self.horizontalMargin = horizontalMargin
            self.rowCardImageSize = rowCardImageSize
            self.compactCardWidth = compactCardWidth
            self.cardRadius = cardRadius
            self.bubbleRadius = bubbleRadius
            self.maxContentWidth = maxContentWidth
        }

        /// The sizes the screens were designed at.
        public static let `default` = Metrics()
    }

    /// The palette.
    public var colors: Colors

    /// The type scale.
    public var fonts: Fonts

    /// The icons.
    public var icons: Icons

    /// The shapes and margins.
    public var metrics: Metrics

    /// Light, dark, or whatever the device says.
    public var appearance: Appearance

    /// Whether a tap on a chip, a card, or the send button answers with a
    /// light knock. Off for an app that runs its own haptics policy — or none.
    public var hapticsEnabled: Bool

    /// The radius of cards, notices, and the clarify card. Chips and the
    /// composer have their own in ``Metrics``.
    public var cornerRadius: CGFloat { metrics.cornerRadius }

    /// Creates a theme.
    ///
    /// - Parameters:
    ///   - colors: The palette. Defaults to ``Colors/system``.
    ///   - fonts: The type scale. Defaults to ``Fonts/system``.
    ///   - icons: The icons. Defaults to SF Symbols.
    ///   - metrics: Shapes and margins. Defaults to the screen's design.
    ///   - appearance: Light, dark, or the device's. Defaults to the device's.
    ///   - hapticsEnabled: Whether taps knock back. Defaults to `true`.
    public init(
        colors: Colors = .system,
        fonts: Fonts = .system,
        icons: Icons = .system,
        metrics: Metrics = .default,
        appearance: Appearance = .system,
        hapticsEnabled: Bool = true
    ) {
        self.colors = colors
        self.fonts = fonts
        self.icons = icons
        self.metrics = metrics
        self.appearance = appearance
        self.hapticsEnabled = hapticsEnabled
    }

    /// System colors and system fonts.
    public static let `default` = TalqynTheme()
}
#endif
