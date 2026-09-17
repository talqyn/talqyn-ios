import Foundation

/// A product card.
///
/// The same shape everywhere Talqyn returns products: instant search, listings,
/// the consultant's results, and chat transcripts.
public struct TalqynProduct: Sendable, Equatable, Identifiable, Hashable {
    /// Talqyn's internal product id.
    ///
    /// It does not exist in your catalog. Its only purpose is to tie Talqyn's
    /// own responses together: the `[p:ID]` markers in consultant text,
    /// ``TalqynProductClickEvent/talqynID``, comparison tables, and transcript
    /// hydration. To act on a product in **your** world, use ``externalID``.
    public var talqynID: Int

    /// The product id in **your** system — the offer id or SKU you supplied in
    /// the feed or push.
    ///
    /// Everything you do on your side keys off this: opening a product page,
    /// adding to a cart, reconciling with your catalog.
    ///
    /// Optional by contract. A card without an external id is possible, and the
    /// SDK does not hide it: whether to display such a product is the app's
    /// decision, not the SDK's.
    public var externalID: String?

    /// The product title in the requested locale.
    public var title: String

    /// The product slug, when the catalog carries one.
    public var slug: String?

    /// The brand's display name.
    public var brandName: String?

    /// The brand in the form the `brandID` request parameter accepts.
    public var brandID: Int?

    /// The brand in the form `filters["brand"]` accepts on a listing request.
    public var brandSlug: String?

    /// The brand's logo, or `nil` when the brand has none.
    public var brandLogoURL: URL?

    /// The category path from root to leaf, in the requested locale.
    public var categoryPath: [String]

    /// The current price.
    public var price: Double?

    /// The price before the discount, or `nil` when there is no discount.
    public var priceBefore: Double?

    /// Whether the product is in stock for the place the request named.
    ///
    /// `nil` when the response did not say. Only an explicit `false` means
    /// the product cannot be bought: a card without the field is not marked
    /// as out of stock.
    public var inStock: Bool?

    /// The average review score.
    public var rating: Double?

    /// How many reviews the score is based on.
    public var reviewsCount: Int

    /// The product image.
    public var imageURL: URL?

    /// The product page on your storefront.
    public var productURL: URL?

    /// The relevance score.
    ///
    /// `nil` indicates degraded results — the reranker was unavailable and the
    /// order comes from RRF instead. Scores are not comparable across responses.
    public var score: Double?

    /// The stable identity of the card: ``talqynID``.
    public var id: Int { talqynID }

    /// Whether there is a struck-through price to show.
    public var hasDiscount: Bool {
        guard let price, let priceBefore else { return false }
        return priceBefore > price
    }

    /// Creates a product card.
    ///
    /// Cards normally arrive decoded from a response; this initializer exists
    /// for previews, fixtures, and tests.
    ///
    /// - Parameters:
    ///   - talqynID: Talqyn's internal product id.
    ///   - externalID: The product id in your system.
    ///   - title: The product title.
    ///   - slug: The product slug.
    ///   - brandName: The brand's display name.
    ///   - brandID: The brand id accepted by the `brandID` parameter.
    ///   - brandSlug: The brand slug accepted by `filters["brand"]`.
    ///   - brandLogoURL: The brand logo.
    ///   - categoryPath: The category path from root to leaf.
    ///   - price: The current price.
    ///   - priceBefore: The price before the discount.
    ///   - inStock: Whether the product is in stock; `nil` when unknown.
    ///   - rating: The average review score.
    ///   - reviewsCount: How many reviews the score is based on.
    ///   - imageURL: The product image.
    ///   - productURL: The product page on your storefront.
    ///   - score: The relevance score.
    public init(
        talqynID: Int,
        externalID: String? = nil,
        title: String,
        slug: String? = nil,
        brandName: String? = nil,
        brandID: Int? = nil,
        brandSlug: String? = nil,
        brandLogoURL: URL? = nil,
        categoryPath: [String] = [],
        price: Double? = nil,
        priceBefore: Double? = nil,
        inStock: Bool? = nil,
        rating: Double? = nil,
        reviewsCount: Int = 0,
        imageURL: URL? = nil,
        productURL: URL? = nil,
        score: Double? = nil
    ) {
        self.talqynID = talqynID
        self.externalID = externalID
        self.title = title
        self.slug = slug
        self.brandName = brandName
        self.brandID = brandID
        self.brandSlug = brandSlug
        self.brandLogoURL = brandLogoURL
        self.categoryPath = categoryPath
        self.price = price
        self.priceBefore = priceBefore
        self.inStock = inStock
        self.rating = rating
        self.reviewsCount = reviewsCount
        self.imageURL = imageURL
        self.productURL = productURL
        self.score = score
    }
}

extension TalqynProduct: Decodable {
    private enum CodingKeys: String, CodingKey {
        case talqynID = "talqyn_id"
        case productID = "product_id"
        case externalID = "external_id"
        case title
        case slug
        case brandName = "brand_name"
        case brandID = "brand_id"
        case brandSlug = "brand_slug"
        case brandLogoURL = "brand_logo_url"
        case categoryPath = "category_path"
        case price
        case priceBefore = "price_before"
        case inStock = "in_stock"
        case rating
        case reviewsCount = "reviews_count"
        case imageURL = "image_url"
        case productURL = "url"
        case score
    }

    /// Decodes a product card.
    ///
    /// Every field except the identifier tolerates being absent or null.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.keyNotFound` when the card carries neither
    ///   `talqyn_id` nor its legacy alias `product_id`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `product_id` is the legacy name of the same field. The server still
        // accepts both, so a response carrying the old one must not break.
        guard let identifier: Int = container.optional(.talqynID) ?? container.optional(.productID)
        else {
            throw DecodingError.keyNotFound(
                CodingKeys.talqynID,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "product card carries no talqyn_id"
                )
            )
        }
        talqynID = identifier
        externalID = container.optional(.externalID)
        title = container.value(.title, default: "")
        slug = container.optional(.slug)
        brandName = container.optional(.brandName)
        brandID = container.optional(.brandID)
        brandSlug = container.optional(.brandSlug)
        brandLogoURL = TalqynProduct.url(container.optional(.brandLogoURL))
        categoryPath = container.array(.categoryPath)
        price = container.optional(.price)
        priceBefore = container.optional(.priceBefore)
        inStock = container.optional(.inStock)
        rating = container.optional(.rating)
        reviewsCount = container.value(.reviewsCount, default: 0)
        imageURL = TalqynProduct.url(container.optional(.imageURL))
        productURL = TalqynProduct.url(container.optional(.productURL))
        score = container.optional(.score)
    }

    /// A URL from a catalog string, parsed leniently: real feeds contain spaces
    /// and non-ASCII characters in paths, where a strict parser returns nil —
    /// an image must not vanish over that.
    ///
    /// A string that is a valid URL as written is taken as written. Otherwise
    /// what a URL may not carry is percent-encoded and what it may is kept. An
    /// escape already in place stays as it is — encoding its `%` again would
    /// ask for another file — while a stray `%` is encoded. The first `#`
    /// starts the fragment; a later one is part of it. The Android SDK walks
    /// the same bytes the same way, so a product shows the same image on both.
    static func url(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = strictURL(raw) { return url }
        return strictURL(percentEncoded(raw))
    }

    /// A URL exactly as written, or nil.
    ///
    /// Since iOS 17 `URL(string:)` percent-encodes what it cannot parse, by
    /// rules of its own — `a%20b c` comes out as `a%2520b%20c` — which would
    /// take the string past the walk below and give this platform different
    /// bytes from Android's.
    private static func strictURL(_ string: String) -> URL? {
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
            return URL(string: string, encodingInvalidCharacters: false)
        }
        return URL(string: string)
    }

    /// What a URL carries as it is, besides ASCII letters and digits. `%` and
    /// `#` have rules of their own; `[` and `]` belong to IPv6 hosts only.
    private static let keptPunctuation = Set("-._~:/?@!$&'()*+,;=".utf8)

    /// The string's UTF-8 bytes with everything a URL may not carry
    /// percent-encoded, in uppercase hex.
    private static func percentEncoded(_ raw: String) -> String {
        let bytes = Array(raw.utf8)
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(bytes.count + 16)
        var hasFragment = false
        for (index, byte) in bytes.enumerated() {
            let keeps: Bool
            switch byte {
            case UInt8(ascii: "%"):
                keeps = index + 2 < bytes.count && isHexDigit(bytes[index + 1]) && isHexDigit(bytes[index + 2])
            case UInt8(ascii: "#"):
                keeps = !hasFragment
                hasFragment = true
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                keeps = true
            default:
                keeps = keptPunctuation.contains(byte)
            }
            if keeps {
                encoded.append(byte)
            } else {
                encoded += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            }
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"),
             UInt8(ascii: "A")...UInt8(ascii: "F"):
            return true
        default:
            return false
        }
    }
}
