import Foundation

/// The Talqyn client: search, consultant, events.
///
/// Create **one instance per app**. It holds the issued device token and the
/// defaults shared by every request — locale, place, A/B bucket — so a second
/// instance would mint a second token and run a second reissue schedule of its
/// own.
///
/// ```swift
/// let talqyn = Talqyn(configuration: TalqynConfiguration(
///     baseURL: Secrets.talqynBaseURL,
///     credentials: TalqynDeviceTokenCredentials(
///         storefront: "myshop",
///         clientKeyID: "ck_3f9a1c2b7d4e",
///         clientSecret: secret
///     ),
///     defaultLocale: .en
/// ))
///
/// let found = try await talqyn.search.search("iphone 15")
/// for try await event in talqyn.consultant.ask("need a laptop for school") {
///     // ...
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a client
/// - ``init(configuration:)``
/// - ``TalqynConfiguration``
///
/// ### Making requests
/// - ``search``
/// - ``consultant``
/// - ``events``
///
/// ### Managing the device token
/// - ``prepare()``
/// - ``setIdentity(_:)``
/// - ``currentIdentity()``
/// - ``currentUserID()``
///
/// ### Adjusting request defaults
/// - ``setPlace(cityID:locationID:)``
/// - ``setLocale(_:)``
/// - ``setVariant(_:)``
public final class Talqyn: Sendable {
    /// Instant search, the start screen, listings, and the filter panel.
    public let search: TalqynSearchAPI

    /// The consultant and the shopper's chat history.
    public let consultant: TalqynConsultantAPI

    /// Clicks and submitted queries.
    public let events: TalqynEventsAPI

    private let defaults: TalqynDefaultsBox
    private let authorizer: TalqynDeviceTokenAuthorizer

    /// Creates a client.
    ///
    /// Nothing is sent during initialization. The first request mints the
    /// device token on the way; call ``prepare()`` at launch to get that out of
    /// the way ahead of time.
    ///
    /// - Parameter configuration: Credentials, endpoint, defaults, and the
    ///   transport to use.
    public init(configuration: TalqynConfiguration) {
        let transport = configuration.transport ?? TalqynURLSessionTransport(
            timeout: configuration.timeout,
            streamTimeout: configuration.streamTimeout
        )
        let builder = TalqynRequestBuilder(
            baseURL: configuration.baseURL,
            apiVersion: configuration.apiVersion,
            timeout: configuration.timeout
        )

        authorizer = TalqynDeviceTokenAuthorizer(
            credentials: configuration.credentials,
            store: configuration.userIDStore,
            minter: TalqynDeviceTokenMinter(
                builder: builder,
                transport: transport,
                logHandler: configuration.logHandler
            ),
            logHandler: configuration.logHandler
        )

        let client = TalqynAPIClient(
            builder: builder,
            transport: transport,
            authorizer: authorizer,
            retryPolicy: configuration.retryPolicy,
            streamTimeout: configuration.streamTimeout,
            logHandler: configuration.logHandler
        )
        let defaults = TalqynDefaultsBox(configuration: configuration)

        self.defaults = defaults
        search = TalqynSearchAPI(client: client, defaults: defaults)
        consultant = TalqynConsultantAPI(
            client: client, defaults: defaults, logHandler: configuration.logHandler
        )
        events = TalqynEventsAPI(
            client: client, defaults: defaults, logHandler: configuration.logHandler
        )
    }

    // MARK: - Device token

    /// Mints the device token ahead of time, typically at app launch.
    ///
    /// Without it the first request pays for the mint, and the shopper waits two
    /// round trips instead of one.
    ///
    /// The error is usually safe to ignore — the next request will try again —
    /// with one exception: ``TalqynError/forbidden(detail:requestID:)`` means
    /// device-token issuance is not enabled for the storefront, which will not
    /// start working on its own. That is a conversation with Talqyn support.
    ///
    /// - Throws: ``TalqynError`` if the token could not be issued.
    public func prepare() async throws {
        _ = try await authorizer.prepare()
    }

    /// Changes who the SDK acts as: sign-in, sign-out, "leave my history".
    ///
    /// The current token is discarded, because it names the previous shopper and
    /// turns taken under it would land in **their** history.
    ///
    /// - Parameter identity: Who to act as from now on.
    public func setIdentity(_ identity: TalqynDeviceIdentity) async {
        await authorizer.setIdentity(identity)
    }

    /// Returns the shopper the SDK currently acts as.
    ///
    /// - Returns: The shopper id, or `nil` for a guest — the consultant works,
    ///   no history is recorded.
    public func currentUserID() async -> String? {
        await authorizer.currentUserID()
    }

    /// Returns the identity the SDK currently acts under, as it was set.
    ///
    /// Unlike ``currentUserID()``, this does not change when a token is
    /// issued: it is the value to compare when deciding whether the shopper
    /// changed.
    public func currentIdentity() async -> TalqynDeviceIdentity {
        await authorizer.currentIdentity()
    }

    // MARK: - Request defaults

    /// Sets the shopper's place for every subsequent request.
    ///
    /// Both values are ids of options from ``TalqynSearchAPI/filters(_:)`` — the
    /// `city` and `location` groups — that is, identifiers in **your** catalog's
    /// numbering.
    ///
    /// - Important: Changing the city **must** clear the store, which is why
    ///   both travel in one call. A store beats a city, so a new city paired
    ///   with a stale store would apply the stale one: the city change would
    ///   appear to work while doing nothing.
    ///
    /// - Parameters:
    ///   - cityID: The city, or `nil` to search the whole country.
    ///   - locationID: The specific store, or `nil` for the whole city.
    public func setPlace(cityID: String?, locationID: String? = nil) {
        defaults.update {
            $0.cityID = cityID
            $0.locationID = locationID
        }
    }

    /// Sets the locale of every subsequent request.
    ///
    /// - Parameter locale: The language to search and answer in.
    public func setLocale(_ locale: TalqynLocale) {
        defaults.update { $0.locale = locale }
    }

    /// Sets the storefront's A/B bucket.
    ///
    /// Echoed into Talqyn analytics so a pilot can be compared against your
    /// previous search; it has no effect on results.
    ///
    /// - Parameter variant: The bucket label — `[A-Za-z0-9._:-]`, at most 32
    ///   characters — or `nil` when no experiment is running.
    public func setVariant(_ variant: String?) {
        defaults.update { $0.variant = variant }
    }

    /// The place currently applied to requests that name none.
    public var currentPlace: (cityID: String?, locationID: String?) {
        let snapshot = defaults.current
        return (snapshot.cityID, snapshot.locationID)
    }

    /// The locale currently applied to requests that name none.
    public var currentLocale: TalqynLocale { defaults.current.locale }
}

public extension Talqyn {
    /// The SDK's version.
    ///
    /// Sent with every request as `X-Talqyn-SDK`, so that a report of "search
    /// broke in the app" can be narrowed to the builds it actually broke in.
    /// Quote it when contacting Talqyn support.
    static let version = "1.1.0"

    /// The value of the `X-Talqyn-SDK` header: platform and version.
    ///
    /// Public for a storefront that mints device tokens through its own
    /// transport — the header identifies the client on those requests too.
    static let clientHeader: String = {
        // The SDK ships to iOS; macOS is the platform the test suite runs on,
        // and naming it keeps a test run out of the iOS numbers on the server.
        #if os(iOS)
        let platform = "ios"
        #elseif os(macOS)
        let platform = "macos"
        #else
        let platform = "swift"
        #endif
        return "\(platform)/\(Talqyn.version)"
    }()
}
