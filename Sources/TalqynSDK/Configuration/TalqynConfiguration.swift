import Foundation

/// Everything the client needs to talk to Talqyn.
///
/// ``baseURL`` and ``credentials`` are required; every other value has a working
/// default.
///
/// ```swift
/// let configuration = TalqynConfiguration(
///     baseURL: Secrets.talqynBaseURL,
///     credentials: TalqynDeviceTokenCredentials(
///         storefront: "myshop",
///         clientKeyID: "ck_3f9a1c2b7d4e",
///         clientSecret: secret
///     ),
///     defaultLocale: .en,
///     defaultCityID: "10"
/// )
/// ```
public struct TalqynConfiguration: Sendable {
    /// The API host.
    ///
    /// The SDK ships no endpoint of its own: the host is named here like the
    /// client key next to it, and it belongs in the build configuration beside
    /// that key, because the two change together when an app moves between
    /// stands. A path prefix is preserved, so
    /// `https://gateway.example.com/talqyn` works as-is.
    public var baseURL: URL

    /// The storefront's client key, which the SDK turns into a device token.
    public var credentials: TalqynDeviceTokenCredentials

    /// The API version path segment. `v1` is canonical.
    ///
    /// Unprefixed paths remain working legacy aliases, but new integrations go
    /// through a version: a breaking contract change ships as a new prefix
    /// alongside this one rather than by changing it. Pass an empty string to
    /// address the unversioned aliases.
    public var apiVersion: String

    /// The locale applied to requests that do not name one.
    public var defaultLocale: TalqynLocale

    /// The shopper's city, applied to requests that name no place.
    ///
    /// The value is a `locations.external_id` **in your own catalog's
    /// numbering** — the same identifier the city carries in your feed. Obtain it
    /// from the `id` of an option in the `city` group of
    /// ``TalqynSearchAPI/filters(_:)``.
    public var defaultCityID: String?

    /// The shopper's specific store, applied to requests that name no place.
    ///
    /// Same numbering as ``defaultCityID``, taken from the `location` group.
    /// A store beats a city, both here and in the API.
    public var defaultLocationID: String?

    /// The storefront's A/B bucket.
    ///
    /// Echoed into Talqyn analytics so a pilot can be compared against your
    /// previous search; it has no effect on results. Must match
    /// `[A-Za-z0-9._:-]` and be at most 32 characters.
    public var variant: String?

    /// The timeout of an ordinary request, in seconds. Defaults to 30.
    public var timeout: TimeInterval

    /// How long to wait for the **first** byte of a consultant SSE stream, in
    /// seconds. Defaults to 60.
    ///
    /// A whole turn may take longer: the timer restarts on every chunk received.
    public var streamTimeout: TimeInterval

    /// When and how often to repeat a failed request. Defaults to
    /// ``TalqynRetryPolicy/default``.
    public var retryPolicy: TalqynRetryPolicy

    /// Where the persistent anonymous shopper UUID and the device clock
    /// correction are kept. Defaults to ``TalqynUserDefaultsIDStore``.
    public var userIDStore: TalqynUserIDStore

    /// The HTTP transport. Defaults to a private `URLSession`.
    ///
    /// Substitute your own to add certificate pinning, a proxy, or a traffic
    /// logger; tests use it to stub the network entirely.
    public var transport: TalqynHTTPTransport?

    /// Where SDK diagnostics are delivered.
    ///
    /// Tokens, client secrets, and shopper ids are never passed to it.
    public var logHandler: (@Sendable (TalqynLogEvent) -> Void)?

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - baseURL: The API host, from your build configuration.
    ///   - credentials: The storefront's client key.
    ///   - apiVersion: The version path segment. Defaults to `"v1"`.
    ///   - defaultLocale: The locale for requests that do not name one.
    ///   - defaultCityID: The shopper's city in your catalog's numbering.
    ///   - defaultLocationID: The shopper's store in your catalog's numbering.
    ///   - variant: The storefront's A/B bucket.
    ///   - timeout: The timeout of an ordinary request, in seconds.
    ///   - streamTimeout: The wait for the first byte of an SSE stream, in
    ///     seconds.
    ///   - retryPolicy: When and how often to repeat a failed request.
    ///   - userIDStore: Where the anonymous shopper UUID and the clock
    ///     correction are kept.
    ///   - transport: A replacement HTTP transport.
    ///   - logHandler: Where SDK diagnostics are delivered.
    public init(
        baseURL: URL,
        credentials: TalqynDeviceTokenCredentials,
        apiVersion: String = "v1",
        defaultLocale: TalqynLocale = .en,
        defaultCityID: String? = nil,
        defaultLocationID: String? = nil,
        variant: String? = nil,
        timeout: TimeInterval = 30,
        streamTimeout: TimeInterval = 60,
        retryPolicy: TalqynRetryPolicy = .default,
        userIDStore: TalqynUserIDStore = TalqynUserDefaultsIDStore(),
        transport: TalqynHTTPTransport? = nil,
        logHandler: (@Sendable (TalqynLogEvent) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.apiVersion = apiVersion
        self.defaultLocale = defaultLocale
        self.defaultCityID = defaultCityID
        self.defaultLocationID = defaultLocationID
        self.variant = variant
        self.timeout = timeout
        self.streamTimeout = streamTimeout
        self.retryPolicy = retryPolicy
        self.userIDStore = userIDStore
        self.transport = transport
        self.logHandler = logHandler
    }
}

/// When and how often a failed request is repeated.
///
/// Client errors (`4xx` other than `429`) are never repeated — a repeat
/// produces the same answer. `5xx` responses and dropped connections are
/// repeated with exponential backoff. `429`, and a `5xx` that names a wait, are
/// repeated after `Retry-After` — but only when that wait fits under
/// ``maxDelay``. A server asking for a minute is not answered with a five-second
/// retry into the same exhausted bucket: the error is surfaced at once, with
/// ``TalqynError/retryAfter`` for the app to act on.
///
/// The policy says how often; the request says whether at all. A request that
/// may have been carried out before its answer was lost is repeated only when
/// the server certainly did not carry it out: an event is repeated after a
/// `429` alone, a consultant turn — an LLM call, paid for — after a refusal it
/// got before it started, never after a connection that dropped under it.
///
/// Backoff waits carry jitter: each is drawn between half and all of its
/// exponential step. During an outage every installation fails at the same
/// moment, and without the spread they would all come back at the same moment
/// too.
public struct TalqynRetryPolicy: Sendable, Equatable {
    /// How many additional attempts to make after the first one fails.
    public var maxRetries: Int

    /// The first backoff interval, in seconds. Doubles on every attempt.
    public var baseDelay: TimeInterval

    /// The ceiling on any single wait, in seconds.
    ///
    /// Backoff is capped here. A `Retry-After` above it is not capped but
    /// declined: the request is not repeated at all. A search field must not
    /// hang for seconds on a keystroke, and a retry that comes back before the
    /// server said it would only adds a request to the exhausted bucket.
    public var maxDelay: TimeInterval

    /// Creates a retry policy.
    ///
    /// - Parameters:
    ///   - maxRetries: Additional attempts after the first failure.
    ///   - baseDelay: The first backoff interval, in seconds.
    ///   - maxDelay: The ceiling on any single wait, in seconds.
    public init(maxRetries: Int, baseDelay: TimeInterval = 0.3, maxDelay: TimeInterval = 5) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Two retries with a 0.3 s base delay, capped at 5 s. The default.
    public static let `default` = TalqynRetryPolicy(maxRetries: 2)

    /// No retries: the first failure is the result.
    public static let none = TalqynRetryPolicy(maxRetries: 0)

    /// The wait before the next attempt, or `nil` when the policy declines to
    /// repeat: the server named a wait longer than ``maxDelay``.
    ///
    /// - Parameter jitter: Where between half and all of the backoff step the
    ///   wait falls, from 0 to 1. Random by default; a test pins it. A
    ///   `Retry-After` is the server's own number and is not jittered.
    func delay(
        forAttempt attempt: Int,
        retryAfter: TimeInterval?,
        jitter: Double = Double.random(in: 0...1)
    ) -> TimeInterval? {
        if let retryAfter {
            guard retryAfter <= maxDelay else { return nil }
            return max(retryAfter, 0)
        }
        let step = min(baseDelay * pow(2, Double(attempt)), maxDelay)
        return step * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }
}

/// A diagnostic message emitted by the SDK.
///
/// Carries no secrets, tokens, or shopper identifiers.
public struct TalqynLogEvent: Sendable {
    /// The severity of a ``TalqynLogEvent``.
    public enum Level: String, Sendable {
        /// Routine internal detail, such as a token being minted.
        case debug
        /// Something worth noticing during normal operation.
        case info
        /// A condition that will degrade the integration if left alone.
        case warning
        /// A failure the SDK could not work around.
        case error
    }

    /// How severe the event is.
    public var level: Level

    /// A human-readable description of what happened.
    public var message: String

    /// The `X-Request-ID` of the request involved, when there is one.
    ///
    /// This is the value to quote when contacting Talqyn support.
    public var requestID: String?

    /// Creates a log event.
    ///
    /// - Parameters:
    ///   - level: How severe the event is.
    ///   - message: A human-readable description.
    ///   - requestID: The `X-Request-ID` of the request involved.
    public init(level: Level, message: String, requestID: String? = nil) {
        self.level = level
        self.message = message
        self.requestID = requestID
    }
}
