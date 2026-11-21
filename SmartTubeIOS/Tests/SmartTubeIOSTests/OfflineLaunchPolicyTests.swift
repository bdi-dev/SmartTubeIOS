import Testing

@testable import SmartTubeIOSCore

@Suite("OfflineLaunchPolicy")
struct OfflineLaunchPolicyTests {
    @Test("opens Downloads when offline with saved videos, once")
    func opensWhenOffline() {
        #expect(
            OfflineLaunchPolicy.shouldOpenDownloads(isOnline: false, hasCompleteDownloads: true, alreadyApplied: false))
        #expect(
            !OfflineLaunchPolicy.shouldOpenDownloads(isOnline: false, hasCompleteDownloads: true, alreadyApplied: true))
    }

    @Test("stays put when online, status unknown, or nothing is downloaded")
    func staysPut() {
        #expect(
            !OfflineLaunchPolicy.shouldOpenDownloads(isOnline: true, hasCompleteDownloads: true, alreadyApplied: false))
        #expect(
            !OfflineLaunchPolicy.shouldOpenDownloads(isOnline: nil, hasCompleteDownloads: true, alreadyApplied: false))
        #expect(
            !OfflineLaunchPolicy.shouldOpenDownloads(
                isOnline: false, hasCompleteDownloads: false, alreadyApplied: false))
    }
}
