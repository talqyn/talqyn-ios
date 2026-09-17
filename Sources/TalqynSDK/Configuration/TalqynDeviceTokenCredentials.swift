import Foundation

/// The storefront client key shipped inside an app build.
///
/// The SDK authenticates one way: a client key (`id` + `secret`) signs a call to
/// `POST /v1/consultant/token`, and every subsequent request travels under the
/// short-lived `tlqd_` token it returns. The token lives for minutes, grants
/// exactly three scopes (consultant, search, and the events of its own
/// shopper), has its own rate-limit bucket, and names the shopper it belongs to
/// — which is what makes per-shopper chat history possible at all.
///
/// The tenant's `tlq_` key has no place in an app and is deliberately not
/// accepted here: it stops being a secret on release day (it can be extracted
/// from the IPA), it can only be revoked by shipping a new build, and it shares
/// a single per-minute bucket across every installation. It stays a backend
/// credential.
///
/// The secret never travels over the network: a mint request carries only the
/// key id, a timestamp, a nonce, and an HMAC over the request body
/// (``TalqynClientSignature``). Revocation and rotation are scoped to a single
/// storefront — a new key goes out with the next build while the old one keeps
/// working until the last build carrying it has updated.
///
/// - SeeAlso: ``TalqynConfiguration/credentials``
public struct TalqynDeviceTokenCredentials: Sendable, Equatable {
    /// The storefront slug issued during onboarding. Addressing, not a secret.
    public var storefront: String

    /// The client key id. Sent in the `X-Client-Key` header.
    public var clientKeyID: String

    /// The client key secret. Never transmitted; used only to sign requests.
    public var clientSecret: String

    /// Who the issued token names as the shopper.
    ///
    /// Defaults to ``TalqynDeviceIdentity/persistentAnonymous``.
    public var identity: TalqynDeviceIdentity

    /// Creates the storefront's credentials.
    ///
    /// - Parameters:
    ///   - storefront: The storefront slug issued during onboarding.
    ///   - clientKeyID: The client key id, sent as `X-Client-Key`.
    ///   - clientSecret: The client key secret used to sign mint requests.
    ///   - identity: Who the token names as the shopper. Defaults to a
    ///     persistent anonymous UUID.
    public init(
        storefront: String,
        clientKeyID: String,
        clientSecret: String,
        identity: TalqynDeviceIdentity = .persistentAnonymous
    ) {
        self.storefront = storefront
        self.clientKeyID = clientKeyID
        self.clientSecret = clientSecret
        self.identity = identity
    }
}

/// Who a device token names as the shopper.
///
/// Exactly one thing depends on this, and it is a significant one: chat history.
/// A guest has none — conversations stay anonymous forever and
/// `GET /v1/consultant/chats` returns an empty list — whereas a named shopper
/// gets a history that reopens under the same id on the next launch. This is why
/// the id **must survive app restarts**.
///
/// The server accepts UUIDs only. The id is asserted by the device and confirmed
/// by nobody, so being unguessable is the only thing protecting somebody else's
/// conversations: an enumerable id such as a CRM row number would expose other
/// shoppers' history by iteration. A CRM identifier therefore does not belong
/// here — if history has to follow a shopper across devices, map your own id to
/// a stable UUID on your backend and pass it through ``user(_:)``.
public enum TalqynDeviceIdentity: Sendable, Equatable {
    /// A guest token: no `user_id` is sent. The consultant works, no history is
    /// recorded.
    case guest

    /// A persistent anonymous UUID, generated on first use and kept in the
    /// configured ``TalqynUserIDStore``.
    case persistentAnonymous

    /// An explicit shopper UUID, for example one handed out by your backend
    /// after sign-in.
    case user(UUID)
}

/// The secret stays out of logs, crash reports, and the debugger.
///
/// Swift prints a struct from its stored properties, so every way of printing
/// the credentials would show the client secret — string interpolation,
/// `String(reflecting:)`, `dump`, `po` — and so would the default printing of
/// anything that holds them, ``TalqynConfiguration`` first of all: a struct
/// prints its properties through their debug descriptions and dumps them
/// through their mirrors. All three are replaced here, and each shows
/// `clientSecret: ***`. The shopper's UUID is hidden the same way; see
/// ``TalqynDeviceIdentity``.
extension TalqynDeviceTokenCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The credentials with the secret masked:
    /// `TalqynDeviceTokenCredentials(storefront: myshop, clientKeyID: ck_3f9a1c2b7d4e, clientSecret: ***, identity: guest)`.
    public var description: String {
        "TalqynDeviceTokenCredentials(storefront: \(storefront), clientKeyID: \(clientKeyID), clientSecret: ***, identity: \(identity))"
    }

    /// The same as ``description``: a debug print is where a secret leaks
    /// first.
    public var debugDescription: String { description }

    /// The properties with the secret masked, for `dump` and the debugger.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "storefront": storefront,
                "clientKeyID": clientKeyID,
                "clientSecret": "***",
                "identity": identity,
            ],
            displayStyle: .struct
        )
    }
}

/// A shopper's UUID is what their history is read under, so it stays out of
/// print the way the client secret does: ``user(_:)`` prints as `user(***)`,
/// on its own and inside the credentials.
extension TalqynDeviceIdentity: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `guest`, `persistentAnonymous`, or `user(***)`.
    public var description: String {
        switch self {
        case .guest: return "guest"
        case .persistentAnonymous: return "persistentAnonymous"
        case .user: return "user(***)"
        }
    }

    /// The same as ``description``.
    public var debugDescription: String { description }

    /// No children: the UUID of ``user(_:)`` is the one thing a mirror would
    /// add.
    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}
