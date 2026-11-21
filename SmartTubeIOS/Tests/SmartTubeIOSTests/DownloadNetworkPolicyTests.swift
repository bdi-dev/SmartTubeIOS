import Testing

@testable import SmartTubeIOSCore

@Suite("DownloadNetworkPolicy")
struct DownloadNetworkPolicyTests {
    @Test("downloads off holds everything, whatever the network")
    func disabled() {
        #expect(
            DownloadNetworkPolicy.holdReason(downloadsEnabled: false, allowCellular: true, onCellularOnly: false)
                == .disabled)
    }

    @Test("cellular off holds only while on mobile data")
    func cellular() {
        #expect(
            DownloadNetworkPolicy.holdReason(downloadsEnabled: true, allowCellular: false, onCellularOnly: true)
                == .waitingForWiFi)
        #expect(
            DownloadNetworkPolicy.holdReason(downloadsEnabled: true, allowCellular: false, onCellularOnly: false)
                == nil)
    }

    @Test("everything on means nothing is held; settings default to on")
    func allowed() {
        #expect(
            DownloadNetworkPolicy.holdReason(downloadsEnabled: true, allowCellular: true, onCellularOnly: true)
                == nil)
        #expect(AppSettings().downloadsEnabled && AppSettings().allowCellularDownloads)
    }
}
