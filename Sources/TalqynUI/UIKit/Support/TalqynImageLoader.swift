#if os(iOS)
import UIKit

/// Loads product images.
///
/// The SDK ships ``TalqynURLImageLoader``; substitute your own to reuse the
/// app's cache or its image pipeline.
public protocol TalqynImageLoading: Sendable {
    /// Loads an image.
    ///
    /// - Parameter url: The image address.
    /// - Returns: The decoded image.
    /// - Throws: Any error; the card then shows its placeholder.
    func image(for url: URL) async throws -> UIImage

    /// An image already in memory, or `nil`.
    ///
    /// A card re-created while an answer streams shows a cached image at once
    /// instead of fading it in again. Optional: the default has no cache and
    /// every image fades in.
    ///
    /// - Parameter url: The image address.
    func cachedImage(for url: URL) -> UIImage?
}

public extension TalqynImageLoading {
    /// No cache: every image is loaded through ``image(for:)``.
    func cachedImage(for url: URL) -> UIImage? { nil }
}

/// The default loader: `URLSession` and an in-memory cache.
public final class TalqynURLImageLoader: TalqynImageLoading, @unchecked Sendable {
    /// One loader for the process, and the screens' default, so every screen
    /// shares its memory cache: a card seen in the consultant comes up at once
    /// in the comparison opened from it, and on the next consultant screen,
    /// instead of loading and fading in again.
    public static let shared = TalqynURLImageLoader()

    private let session: URLSession
    private let cache = NSCache<NSURL, UIImage>()
    private let maxPixelSize: CGFloat

    /// The longest side an image is kept at, in pixels, unless the loader is
    /// built with its own: the screens' largest picture — a carousel tile —
    /// at three pixels to the point, with room to spare.
    public static let defaultMaxPixelSize: CGFloat = 600

    /// Creates a loader.
    ///
    /// - Parameters:
    ///   - session: The session to fetch through. Defaults to a session with
    ///     the system's disk cache, which is what images want.
    ///   - maxPixelSize: The longest side an image is kept at, in pixels. A
    ///     catalog's pictures are made for a product page, and a card shows
    ///     them a few times smaller: kept whole, two hundred of them decoded
    ///     are hundreds of megabytes. `0` keeps every image as it came.
    public init(session: URLSession = .shared, maxPixelSize: CGFloat = TalqynURLImageLoader.defaultMaxPixelSize) {
        self.session = session
        self.maxPixelSize = maxPixelSize
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    public func image(for url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let (data, _) = try await session.data(from: url)
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        // Decoding happens once here rather than on first draw.
        let decoded = await Self.prepared(image, maxPixelSize: maxPixelSize)
        cache.setObject(decoded, forKey: url as NSURL, cost: Self.decodedBytes(of: decoded))
        return decoded
    }

    /// The image decoded, and scaled down when it is larger than the screens
    /// show it.
    private static func prepared(_ image: UIImage, maxPixelSize: CGFloat) async -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixels.width, pixels.height)
        guard maxPixelSize > 0, longest > maxPixelSize else { return await image.byPreparingForDisplay() ?? image }
        let ratio = maxPixelSize / longest
        let target = CGSize(width: floor(image.size.width * ratio), height: floor(image.size.height * ratio))
        if let thumbnail = await image.byPreparingThumbnail(ofSize: target) { return thumbnail }
        return await image.byPreparingForDisplay() ?? image
    }

    private static func decodedBytes(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    public func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }
}

/// An image view that loads its content and forgets it on reuse.
///
/// Until the image is there — and when it never comes — a small placeholder
/// stands in the middle, so a card reads as a card with a missing picture
/// rather than as a grey hole. A loaded image fades in; a cached one does not.
final class TalqynRemoteImageView: UIImageView {
    private var task: Task<Void, Never>?
    private var currentURL: URL?
    private let placeholderView = UIImageView()

    // `UIImageView` has designated initializers of its own beyond `frame`, so
    // the empty one is not inherited and is spelled out.
    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.isAccessibilityElement = false
        addSubview(placeholderView)
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderView.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
            placeholderView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sets what stands in for a missing image.
    func setPlaceholder(_ image: UIImage?, tint: UIColor) {
        placeholderView.image = image?.talqynSized(20)
        placeholderView.tintColor = tint
        updatePlaceholder()
    }

    func setImage(url: URL?, loader: TalqynImageLoading) {
        guard url != currentURL else { return }
        task?.cancel()
        currentURL = url
        if let url, let cached = loader.cachedImage(for: url) {
            image = cached
            updatePlaceholder()
            return
        }
        image = nil
        updatePlaceholder()
        guard let url else { return }
        task = Task { [weak self] in
            guard let image = try? await loader.image(for: url), !Task.isCancelled else { return }
            guard let self, self.currentURL == url else { return }
            UIView.transition(
                with: self,
                duration: TalqynMotion.duration(0.2),
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.image = image
                self.updatePlaceholder()
            }
        }
    }

    private func updatePlaceholder() {
        placeholderView.isHidden = image != nil || placeholderView.image == nil
    }
}
#endif
