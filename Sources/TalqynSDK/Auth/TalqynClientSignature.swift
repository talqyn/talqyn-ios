import CryptoKit
import Foundation

/// Signs a device-token mint request with the storefront's client key.
///
/// `POST /v1/consultant/token` is guarded by this signature rather than by a
/// tenant key, because there is no tenant key on a device to guard it with. The
/// secret itself never travels: a request carries the key id, a timestamp, a
/// nonce, and an HMAC over the exact bytes of the body.
///
/// ```
/// signing_input = "talqyn-device-mint-v1" + "\n"
///               + key_id + "\n"
///               + timestamp + "\n"
///               + nonce + "\n"
///               + hex(SHA256(body_bytes))
/// X-Client-Sig  = hex(HMAC-SHA256(secret, signing_input))
/// ```
///
/// `body_bytes` must be **exactly** the bytes that go on the wire: serialize the
/// body once and sign what you send. Re-serializing can reorder keys or change
/// whitespace, and the signature will not match.
///
/// ``Talqyn`` performs this for you; the type is public so a storefront that
/// mints tokens through its own transport can reuse the same algorithm.
public enum TalqynClientSignature {
    /// The context label baked into every signing input.
    ///
    /// Changing it invalidates every shipped build at once, which is why the
    /// version lives inside the string itself.
    public static let context = "talqyn-device-mint-v1"

    /// The acceptance window for ``headers(keyID:secret:body:timestamp:nonce:)``,
    /// in seconds: the server accepts a timestamp within ±300 s of its own clock.
    ///
    /// A timestamp outside the window means either a badly skewed device clock
    /// or a replayed request.
    public static let maxSkew: TimeInterval = 300

    /// Builds the four signature headers for a mint request body.
    ///
    /// - Parameters:
    ///   - keyID: The client key id.
    ///   - secret: The client key secret. Used to sign; never sent.
    ///   - body: The exact request body bytes that will be transmitted.
    ///   - timestamp: The moment to stamp the request with. Defaults to now.
    ///   - nonce: The single-use request nonce. Defaults to a fresh random value.
    /// - Returns: `X-Client-Key`, `X-Client-Timestamp`, `X-Client-Nonce`, and
    ///   `X-Client-Sig`, ready to be merged into the request headers.
    public static func headers(
        keyID: String,
        secret: String,
        body: Data,
        timestamp: Date = Date(),
        nonce: String = TalqynClientSignature.makeNonce()
    ) -> [String: String] {
        let stamp = String(Int(timestamp.timeIntervalSince1970))
        let signature = sign(
            secret: secret, keyID: keyID, timestamp: stamp, nonce: nonce, body: body
        )
        return [
            "X-Client-Key": keyID,
            "X-Client-Timestamp": stamp,
            "X-Client-Nonce": nonce,
            "X-Client-Sig": signature,
        ]
    }

    /// Computes the `X-Client-Sig` value for a mint request.
    ///
    /// - Parameters:
    ///   - secret: The client key secret.
    ///   - keyID: The client key id.
    ///   - timestamp: Unix time in seconds, as a decimal string.
    ///   - nonce: The single-use request nonce.
    ///   - body: The exact request body bytes that will be transmitted.
    /// - Returns: `hex(HMAC-SHA256(secret, signingInput))`, 64 lowercase
    ///   hexadecimal characters.
    public static func sign(
        secret: String,
        keyID: String,
        timestamp: String,
        nonce: String,
        body: Data
    ) -> String {
        let input = signingInput(keyID: keyID, timestamp: timestamp, nonce: nonce, body: body)
        let code = HMAC<SHA256>.authenticationCode(
            for: input, using: SymmetricKey(data: Data(secret.utf8))
        )
        return hex(code)
    }

    /// Assembles the string that gets signed.
    ///
    /// The body enters as a digest rather than verbatim: the signature has to
    /// cover the exact bytes sent, without depending on how they would be
    /// encoded inside a header.
    ///
    /// - Parameters:
    ///   - keyID: The client key id.
    ///   - timestamp: Unix time in seconds, as a decimal string.
    ///   - nonce: The single-use request nonce.
    ///   - body: The exact request body bytes that will be transmitted.
    /// - Returns: The five newline-separated fields, UTF-8 encoded.
    public static func signingInput(
        keyID: String,
        timestamp: String,
        nonce: String,
        body: Data
    ) -> Data {
        let digest = hex(SHA256.hash(data: body))
        return Data([context, keyID, timestamp, nonce, digest].joined(separator: "\n").utf8)
    }

    /// Generates a single-use request nonce.
    ///
    /// The server remembers a nonce for the length of the acceptance window and
    /// rejects a repeat, so a fresh value is required for **every** mint request.
    ///
    /// - Returns: 24 hexadecimal characters, within the contract's 16–64
    ///   character `[A-Za-z0-9_-]` range.
    public static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
