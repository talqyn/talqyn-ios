import Foundation

/// How prices are written on cards and in filter summaries.
public struct TalqynPriceFormatter: Sendable {
    /// Formats a price.
    public var format: @Sendable (Double) -> String

    /// Creates a formatter.
    ///
    /// - Parameter format: The formatting closure.
    public init(_ format: @escaping @Sendable (Double) -> String) {
        self.format = format
    }

    /// `449 990 ₸`: grouped by thousands with a space, no fraction unless the
    /// price has one.
    public static let tenge: TalqynPriceFormatter = {
        let formatters = TalqynGroupedNumberFormatters()
        return TalqynPriceFormatter { value in
            "\(formatters.string(from: value))\u{00A0}₸"
        }
    }()
}

/// The two number formatters a price needs, built once.
///
/// A price is written on every card of every re-render while an answer
/// streams, and a `NumberFormatter` is expensive to build. It is not declared
/// `Sendable`, so the shared pair sits behind a lock.
private final class TalqynGroupedNumberFormatters: @unchecked Sendable {
    private let lock = NSLock()
    private let whole = TalqynGroupedNumberFormatters.make(fractionDigits: 0)
    private let fractional = TalqynGroupedNumberFormatters.make(fractionDigits: 2)

    func string(from value: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter = value.rounded() == value ? whole : fractional
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func make(fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{00A0}"
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }
}
