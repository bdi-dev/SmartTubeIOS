import Foundation
import Testing

@testable import InnerTubeKit

// Reply threads of the comments panel, parsed from trimmed live captures
// (see CommentRepliesFixtures.swift). No network.

@Suite("Comment replies")
struct CommentRepliesTests {

    private let api = InnerTubeAPI()

    private func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("top-level comments carry the reply count text and first reply token")
    func threadsCarryReplyInfo() throws {
        let page = api.parseCommentPage(from: try json(CommentRepliesFixtures.topLevelPage))

        #expect(page.comments.map(\.id) == CommentRepliesFixtures.topLevelIDs)
        #expect(page.comments.map(\.replyCountText) == CommentRepliesFixtures.replyCountTexts)
        #expect(page.comments.first?.replyContinuationToken == CommentRepliesFixtures.firstReplyToken)
        #expect(page.comments.allSatisfy { $0.hasReplies })
        // Reply streams are not the page's own continuation.
        #expect(page.nextToken == nil)
    }

    @Test("a comment without a replies renderer has no reply info")
    func commentWithoutReplies() throws {
        let page = api.parseCommentPage(from: try json(CommentsPageFixtures.page1))
        let plain = try #require(page.comments.last)
        #expect(plain.replyCountText == nil)
        #expect(plain.replyContinuationToken == nil)
        #expect(!plain.hasReplies)
    }

    @Test("the first reply page lists replies in order and ends with the show-more token")
    func firstReplyPage() throws {
        let page = api.parseCommentPage(from: try json(CommentRepliesFixtures.replyPage1))

        #expect(page.comments.map(\.id) == CommentRepliesFixtures.replyPage1IDs)
        #expect(page.nextToken == CommentRepliesFixtures.secondReplyToken)
        let first = try #require(page.comments.first)
        #expect(first.author == "@egdog_tm")
        #expect(first.text == "The biggest comrade ever")
        #expect(first.publishedTime == "6 years ago")
        #expect(first.replyContinuationToken == nil)
    }

    @Test("the token chain reaches the last reply page, which has no further token")
    func tokenChain() throws {
        let second = api.parseCommentPage(from: try json(CommentRepliesFixtures.replyPage2))
        #expect(second.comments.map(\.id) == CommentRepliesFixtures.replyPage2IDs)
        #expect(second.nextToken == nil)
    }
}
