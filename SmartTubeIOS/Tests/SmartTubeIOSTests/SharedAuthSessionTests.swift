import Foundation
import Testing

@testable import InnerTubeKit

// A view model's own `InnerTubeAPI()` (ChannelViewModel) must inherit the signed-in account,
// otherwise channel requests are signed out and the History fallback never runs.

@Suite("SharedAuthSession", .serialized)
struct SharedAuthSessionTests {

    @Test("a new public-init API inherits token and SAPISID; sign-out clears both")
    func inheritsAndClears() async {
        let main = InnerTubeAPI()
        await main.setAuthToken("tok")
        await main.setSAPISID("sid")
        defer { SharedAuthSession.shared.setToken(nil) }

        let channelAPI = InnerTubeAPI()
        #expect(await channelAPI.authToken == "tok")
        #expect(await channelAPI.hasSAPISID)

        await main.setAuthToken(nil)
        let afterSignOut = InnerTubeAPI()
        #expect(await afterSignOut.authToken == nil)
        #expect(await afterSignOut.hasSAPISID == false)
    }

    @Test("test-init instances neither read nor publish the shared session")
    func testInitIsolated() async {
        SharedAuthSession.shared.setToken(nil)
        let isolated = InnerTubeAPI(authToken: nil, session: .shared)
        await isolated.setAuthToken("x")
        #expect(SharedAuthSession.shared.token == nil)
    }
}
