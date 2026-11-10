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
/// A named shopper's id is yours, in your own format. It is asserted by the
/// device and confirmed by nobody, so being unguessable is the only thing
/// protecting somebody else's conversations — and choosing such an id is the
/// storefront's responsibility. A random one (a UUID, an opaque account id) is
/// fine; an enumerable one such as a CRM row number exposes other shoppers'
/// history to anyone who substitutes it. If your account ids are enumerable,
/// map each to a stable random id on your backend and pass that through
/// ``user(_:)-swift.enum.case``.
public enum TalqynDeviceIdentity: Sendable, Equatable {
    /// A guest token: no `user_id` is sent. The consultant works, no history is
    /// recorded.
    case guest

    /// A persistent anonymous UUID, generated on first use and kept in the
    /// configured ``TalqynUserIDStore``.
    case persistentAnonymous

    /// An explicit shopper id, for example the account's id from your backend
    /// after sign-in: 1 to 128 characters of `[A-Za-z0-9._:-]`.
    ///
    /// A UUID is sent lowercased, as the server stores it, so that one account
    /// written two ways stays one shopper. Any other id is sent exactly as
    /// given and is case-sensitive. An id of another form fails the first
    /// request with ``TalqynError/invalidConfiguration(_:)``.
    case user(String)

    /// An explicit shopper id that is a UUID.
    ///
    /// The same as ``user(_:)-swift.enum.case`` with the UUID's lowercase
    /// string.
    public static func user(_ id: UUID) -> TalqynDeviceIdentity {
        .user(id.uuidString.lowercased())
    }
}

extension TalqynDeviceIdentity {
    /// The longest shopper id the server accepts.
    static let maxShopperIDLength = 128

    /// The id as it goes on the wire, or `nil` when the server would refuse
    /// it: anything but 1 to 128 characters of `[A-Za-z0-9._:-]`.
    ///
    /// A UUID is lowercased, which is what the server does to it; an id the
    /// server knows nothing about the spelling of is left alone.
    static func wireShopperID(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxShopperIDLength else { return nil }
        let allowed = scalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", ":", "-": return true
            default: return false
            }
        }
        guard allowed else { return nil }
        return UUID(uuidString: raw) != nil ? raw.lowercased() : raw
    }
}

/// The secret stays out of logs, crash reports, and the debugger.
///
/// Swift prints a struct from its stored properties, so every way of printing
/// the credentials would show the client secret — string interpolation,
/// `String(reflecting:)`, `dump`, `po` — and so would the default printing of
/// anything that holds them, ``TalqynConfiguration`` first of all: a struct
/// prints its properties through their debug descriptions and dumps them
/// through their mirrors. All three are replaced here, and each shows
/// `clientSecret: ***`. The shopper's id is hidden the same way; see
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

/// A shopper's id is what their history is read under, so it stays out of
/// print the way the client secret does: a named shopper prints as `user(***)`,
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

    /// No children: the id of a named shopper is the one thing a mirror would
    /// add.
    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}
