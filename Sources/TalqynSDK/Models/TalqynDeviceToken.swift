import Foundation

/// A device token issued by `POST /v1/consultant/token`.
///
/// ``Talqyn`` mints, caches, and reissues these on its own; the type is public
/// so an app can inspect what it is running under.
public struct TalqynDeviceToken: Sendable, Equatable {
    /// The token string, sent as `Authorization: Bearer tlqd_…`.
    public var token: String

    /// When the token expires, by the **server's** clock.
    ///
    /// Use ``expiresIn`` to decide when to reissue: device clocks drift, and the
    /// SDK counts from local time at the moment the response arrived.
    public var expiresAt: Date?

    /// How many seconds the token lives from the moment it was issued.
    public var expiresIn: TimeInterval

    /// The shopper the token is bound to, in canonical form.
    ///
    /// `nil` means a guest token: the consultant works, no history is recorded.
    public var userID: String?
}

extension TalqynDeviceToken: Decodable {
    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case userID = "user_id"
    }

    /// Decodes a mint response.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` when the response carries no `token`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        expiresAt = container.date(.expiresAt)
        expiresIn = container.value(.expiresIn, default: TimeInterval(900))
        userID = container.optional(.userID)
    }
}

/// The token stays out of logs, crash reports, and the debugger.
///
/// Whoever reads the token can act as its shopper until it expires, and the
/// shopper id is what a history is read under — yet Swift prints a struct from
/// its stored properties, whichever way it is printed. The description, the
/// debug description, and the mirror are replaced, so string interpolation,
/// `String(reflecting:)`, `dump`, and `po` show only what an app inspecting the
/// token needs: when it expires, and whether it names a shopper.
extension TalqynDeviceToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The token without its secrets:
    /// `TalqynDeviceToken(expiresAt: 2026-08-26 12:15:00 +0000, expiresIn: 900.0, guest: false)`.
    public var description: String {
        "TalqynDeviceToken(expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"), expiresIn: \(expiresIn), guest: \(userID == nil))"
    }

    /// The same as ``description``.
    public var debugDescription: String { description }

    /// The expiry and whether the token is a guest's, for `dump` and the
    /// debugger.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: ["expiresAt": expiresAt as Any, "expiresIn": expiresIn, "guest": userID == nil],
            displayStyle: .struct
        )
    }
}
