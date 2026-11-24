import Foundation
import Testing

@testable import InnerTubeKit

// MARK: - LockupPublishedTimeTests
//
// Channel Videos-tab cards showed only the view count: the WEB `lockupViewModel` there has a
// SINGLE metadata row [views, age] (no channel row), and the parser skipped row 0 on the
// assumption it was the channel. Fixtures mirror a REAL signed-out capture of
// UCBJycsmduvYEL83R_U4JriQ (trimmed to ids/titles/metadata); the Home/search two-row shape
// (channel row with a browse command run, then [views, age]) is SHAPE-BASED.

@Suite("lockupViewModel published time")
struct LockupPublishedTimeTests {

    private let api = InnerTubeAPI()

    private func lockup(id: String, rows: [[String: Any]]) -> [String: Any] {
        [
            "lockupViewModel": [
                "contentId": id,
                "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                "contentImage": [
                    "thumbnailViewModel": [
                        "image": [
                            "sources": [["url": "https://i.ytimg.com/vi/\(id)/hq720.jpg", "width": 720, "height": 404]]
                        ]
                    ]
                ],
                "metadata": [
                    "lockupMetadataViewModel": [
                        "title": ["content": "Title \(id)"],
                        "metadata": ["contentMetadataViewModel": ["metadataRows": rows, "delimiter": " \u{2022} "]],
                    ]
                ],
                "rendererContext": [
                    "commandContext": ["onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": id]]]]
                ],
            ]
        ]
    }

    private func part(_ text: String) -> [String: Any] { ["text": ["content": text]] }

    private func parse(_ items: [[String: Any]]) async throws -> [Video] {
        try await api.parseVideoGroupForTesting(["items": items], title: nil).videos
    }

    @Test("channel Videos tab: single row [views, age] fills views and published time")
    func channelTabSingleRow() async throws {
        let rows: [[String: Any]] = [["metadataParts": [part("2.8M views"), part("1 day ago")]]]
        let v = try #require(try await parse([lockup(id: "KTDJiVpSDTI", rows: rows)]).first)
        #expect(v.viewCount == 2_800_000)
        #expect(v.publishedTimeText == "1 day ago")
        let age = try #require(v.publishedAt)
        #expect(abs(Date().timeIntervalSince(age) - 86_400) < 120)
        #expect(v.channelTitle == "")
        #expect(v.thumbnailURL?.absoluteString.contains("KTDJiVpSDTI") == true)
    }

    @Test("older channel video keeps the raw text for the card")
    func monthsAgo() async throws {
        let rows: [[String: Any]] = [["metadataParts": [part("72K views"), part("2 months ago")]]]
        let v = try #require(try await parse([lockup(id: "A", rows: rows)]).first)
        #expect(v.viewCount == 72_000)
        #expect(v.publishedTimeText == "2 months ago")
        #expect(v.publishedAt != nil)
    }

    @Test("Home shape: channel row then [views, age] still works")
    func homeTwoRows() async throws {
        let channelPart: [String: Any] = [
            "text": [
                "content": "MKBHD",
                "commandRuns": [
                    ["onTap": ["innertubeCommand": ["browseEndpoint": ["browseId": "UCBJycsmduvYEL83R_U4JriQ"]]]]
                ],
            ]
        ]
        let rows: [[String: Any]] = [
            ["metadataParts": [channelPart]],
            ["metadataParts": [part("1.2M views"), part("3 weeks ago")]],
        ]
        let v = try #require(try await parse([lockup(id: "B", rows: rows)]).first)
        #expect(v.channelTitle == "MKBHD")
        #expect(v.channelId == "UCBJycsmduvYEL83R_U4JriQ")
        #expect(v.viewCount == 1_200_000)
        #expect(v.publishedTimeText == "3 weeks ago")
    }

    @Test("Streamed prefix parses; a live watching count is not an age")
    func streamedAndLive() async throws {
        let streamed: [[String: Any]] = [["metadataParts": [part("10K views"), part("Streamed 4 days ago")]]]
        let live: [[String: Any]] = [["metadataParts": [part("1.5K watching")]]]
        let vs = try await parse([lockup(id: "C", rows: streamed), lockup(id: "D", rows: live)])
        #expect(vs[0].publishedAt != nil)
        #expect(vs[0].viewCount == 10_000)
        #expect(vs[1].publishedAt == nil)
        #expect(vs[1].publishedTimeText == nil)
        #expect(vs[1].viewCount == 1_500)
    }

    @Test("non-English age text is kept positionally and never read as views")
    func nonEnglish() async throws {
        let rows: [[String: Any]] = [["metadataParts": [part("72 Tsd. Aufrufe"), part("vor 2 Monaten")]]]
        let v = try #require(try await parse([lockup(id: "E", rows: rows)]).first)
        #expect(v.publishedTimeText == "vor 2 Monaten")
        #expect(v.publishedAt == nil)
        #expect(v.viewCount == 72)
    }
}
