import Foundation
import TalqynTestSupport
@testable import TalqynSDK

extension TestFixtures {
    /// The device-token authorizer on its own, with a clock the test controls.
    static func authorizer(
        transport: StubTransport,
        clock: FakeClock,
        identity: TalqynDeviceIdentity = .guest,
        store: TalqynUserIDStore = TalqynInMemoryUserIDStore(),
        logHandler: (@Sendable (TalqynLogEvent) -> Void)? = nil
    ) -> TalqynDeviceTokenAuthorizer {
        let builder = TalqynRequestBuilder(
            baseURL: TestFixtures.baseURL, apiVersion: "v1", timeout: 30
        )
        return TalqynDeviceTokenAuthorizer(
            credentials: deviceToken(identity: identity),
            store: store,
            minter: TalqynDeviceTokenMinter(builder: builder, transport: transport, logHandler: logHandler),
            logHandler: logHandler,
            now: { clock.now }
        )
    }
}
