import Foundation
import Testing

@testable import InnerTubeKit

@Suite("Thumbnail rung selection by required pixel width")
struct ThumbnailChainTests {
    private let video = Video(id: "abc", title: "t", channelTitle: "c")

    private func names(_ width: CGFloat) -> [String] {
        video.thumbnailChain(requiredPixelWidth: width).map(\.lastPathComponent)
    }

    @Test("iPad-sized card (about 760px) starts at hq720 and steps down")
    func largeCardStartsAtHq720() {
        #expect(names(760) == ["hq720.jpg", "sddefault.jpg", "hqdefault.jpg", "mqdefault.jpg"])
    }

    @Test("Width between hqdefault and hq720 starts at sddefault")
    func midCardStartsAtSddefault() {
        #expect(names(555) == ["sddefault.jpg", "hqdefault.jpg", "mqdefault.jpg"])
    }

    @Test("A width exactly on a rung starts at that rung")
    func exactRungStartsAtRung() {
        #expect(names(640) == ["sddefault.jpg", "hqdefault.jpg", "mqdefault.jpg"])
        #expect(names(480) == ["hqdefault.jpg", "mqdefault.jpg"])
        #expect(names(320) == ["mqdefault.jpg"])
    }

    @Test("Widths beyond hq720 start at hq720, the largest rung")
    func oversizedStartsAtLargest() {
        #expect(names(4000).first == "hq720.jpg")
    }

    @Test("Tiny widths only request mqdefault")
    func tinyWidthIsMqOnly() {
        #expect(names(0) == ["mqdefault.jpg"])
    }

    @Test("Chain never includes maxresdefault (that stays a separate High Resolution setting)")
    func chainExcludesMaxRes() {
        #expect(!names(4000).contains("maxresdefault.jpg"))
    }
}
