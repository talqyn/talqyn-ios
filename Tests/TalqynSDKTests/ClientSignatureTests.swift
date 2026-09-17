import XCTest
import TalqynTestSupport
@testable import TalqynSDK

/// The reference values come from the server's own algorithm
/// (`app/services/cip/device_token.sign_mint_request`): signing has to match it
/// byte for byte, or minting answers 401.
final class ClientSignatureTests: XCTestCase {
    private let keyID = "ck_3f9a1c2b7d4e"
    private let secret = "s3cr3t-client-key-value-32-chars-long"
    private let timestamp = "1756208100"
    private let nonce = "8c1d0b6e2f4a9b3c7d5e1f0a"

    func testSignatureMatchesServerReference() {
        let body = Data(#"{"storefront":"myshop","user_id":"6f1c2b9a-3e47-4b8f-9a10-2c5d8e7f4a01"}"#.utf8)
        let signature = TalqynClientSignature.sign(
            secret: secret, keyID: keyID, timestamp: timestamp, nonce: nonce, body: body
        )
        XCTAssertEqual(signature, "ec3c1408b51f7abe58002c92db2d8d45411312188f3b81da618f83607140e92b")
    }

    func testGuestBodySignatureMatchesServerReference() {
        let body = Data(#"{"storefront":"myshop"}"#.utf8)
        let signature = TalqynClientSignature.sign(
            secret: secret, keyID: keyID, timestamp: timestamp, nonce: nonce, body: body
        )
        XCTAssertEqual(signature, "cb146efcb273072c067e6753eb782d317004c9657c1e5e7d3fbe6a7515973afe")
    }

    func testSigningInputShape() {
        let input = TalqynClientSignature.signingInput(
            keyID: keyID, timestamp: timestamp, nonce: nonce, body: Data(#"{"storefront":"myshop"}"#.utf8)
        )
        let text = String(data: input, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "talqyn-device-mint-v1")
        XCTAssertEqual(lines[1], keyID)
        XCTAssertEqual(lines[2], timestamp)
        XCTAssertEqual(lines[3], nonce)
        XCTAssertEqual(lines[4].count, 64)
    }

    func testHeadersCarryEverythingServerRequires() {
        let headers = TalqynClientSignature.headers(
            keyID: keyID, secret: secret, body: Data("{}".utf8)
        )
        XCTAssertEqual(headers["X-Client-Key"], keyID)
        XCTAssertNotNil(headers["X-Client-Timestamp"])
        XCTAssertEqual(headers["X-Client-Sig"]?.count, 64)

        let nonce = headers["X-Client-Nonce"] ?? ""
        // Server contract: 16-64 characters of [A-Za-z0-9_-].
        XCTAssertTrue((16...64).contains(nonce.count), "nonce length out of range: \(nonce.count)")
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        XCTAssertTrue(nonce.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testNonceIsFreshEveryTime() {
        let nonces = Set((0..<200).map { _ in TalqynClientSignature.makeNonce() })
        XCTAssertEqual(nonces.count, 200, "nonce repeated — the server would reject the request as replayed")
    }
}
