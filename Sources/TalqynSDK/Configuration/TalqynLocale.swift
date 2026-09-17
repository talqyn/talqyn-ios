import Foundation

/// The language a request is served in.
///
/// The contract accepts exactly three values, `en`, `ru`, and `kk`; anything
/// else is rejected with `422`. That is why this is a closed enumeration rather
/// than an extensible wrapper: an unknown locale is a programming error, not a
/// value to pass through.
public enum TalqynLocale: String, Sendable, Codable, CaseIterable {
    /// English. The default.
    case en
    /// Russian.
    case ru
    /// Kazakh.
    case kk

    /// Maps an app language code onto a supported locale.
    ///
    /// Anything that is neither Kazakh nor Russian resolves to ``en``: a tenant
    /// catalog is translated into these three languages only, so falling back
    /// to the default locale is the only meaningful answer for the rest.
    ///
    /// - Parameter languageCode: A language identifier such as `"kk"`,
    ///   `"kk-KZ"`, or `Locale.current.languageCode`. May be `nil`.
    /// - Returns: ``kk`` when the code starts with `kk`, ``ru`` when it starts
    ///   with `ru`, otherwise ``en``.
    public static func matching(languageCode: String?) -> TalqynLocale {
        switch languageCode?.lowercased().prefix(2) {
        case "kk": return .kk
        case "ru": return .ru
        default: return .en
        }
    }
}

/// The ordering applied to a listing request.
///
/// Values map one-to-one onto the `sort` field of `POST /v1/search/full`.
public enum TalqynSort: String, Sendable, Codable, CaseIterable {
    /// Server-side relevance ranking. The default.
    case relevance
    /// Cheapest first.
    case priceAscending = "price_asc"
    /// Most expensive first.
    case priceDescending = "price_desc"
    /// Deepest discount first.
    case discountDescending = "discount_desc"
}
