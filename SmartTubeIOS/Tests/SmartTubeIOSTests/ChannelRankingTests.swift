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

    func testSplitSeparatesWatchedGroupFromRest() {
        let list = ["a", "b", "c", "d"].map(ch)
        let out = ChannelRanking.split(list, watchedChannelIds: ["c", "b", "c", "c"])
        XCTAssertEqual(out.frequent.map(\.id), ["c", "b"])
        XCTAssertEqual(out.rest.map(\.id), ["a", "d"])
    }

    func testSplitWithNoHistoryHasNoFrequentGroup() {
        let list = ["a", "b"].map(ch)
        let out = ChannelRanking.split(list, watchedChannelIds: [])
        XCTAssertTrue(out.frequent.isEmpty)
        XCTAssertEqual(out.rest.map(\.id), ["a", "b"])
    }

    func testSplitCapsFrequentGroupAtTopCount() {
        let ids = (0..<20).map { "c\($0)" }
        let list = ids.map(ch)
        // Watch every channel once, in list order, so each scores differently but all have history.
        let out = ChannelRanking.split(list, watchedChannelIds: ids)
        XCTAssertEqual(out.frequent.count, ChannelRanking.topCount)
        XCTAssertEqual(out.rest.count, 20 - ChannelRanking.topCount)
        XCTAssertEqual(out.frequent.count + out.rest.count, 20)
    }
}
