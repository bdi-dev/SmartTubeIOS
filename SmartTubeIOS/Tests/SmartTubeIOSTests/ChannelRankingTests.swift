import XCTest

@testable import SmartTubeIOSCore

final class ChannelRankingTests: XCTestCase {
    private func ch(_ id: String) -> Channel { Channel(id: id, title: id) }

    func testWatchedChannelsLeadByFrequencyAndRecency() {
        let list = ["a", "b", "c", "d"].map(ch)
        let out = ChannelRanking.ranked(list, watchedChannelIds: ["c", "b", "c", "c"])
        XCTAssertEqual(out.map(\.id), ["c", "b", "a", "d"])
    }

    func testNoHistoryKeepsOrder() {
        let list = ["a", "b"].map(ch)
        XCTAssertEqual(ChannelRanking.ranked(list, watchedChannelIds: []).map(\.id), ["a", "b"])
    }
}
