import Foundation
import Testing

@testable import InnerTubeKit

// Parsing of the comments continuation responses, run against trimmed live captures
// (see CommentsPageFixtures.swift). No network.

@Suite("Comments paging")
struct CommentsPagingTests {

    private let api = InnerTubeAPI()

    private func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("first /next response yields the comments token and the count text")
    func firstNextResponse() async throws {
        let response = try json(CommentsPageFixtures.firstNext)
        #expect(api.parseCommentsCountText(from: response) == CommentsPageFixtures.firstNextCountText)
        #expect(api.parseCommentsContinuationToken(from: response) == CommentsPageFixtures.firstNextToken)
    }

    @Test("first comments page keeps display order and reads the like count from toolbar")
    func firstPageComments() async throws {
        let page = api.parseCommentPage(from: try json(CommentsPageFixtures.page1))

        #expect(page.comments.map(\.id) == CommentsPageFixtures.page1CommentIDs)
        let first = try #require(page.comments.first)
        #expect(first.author == "@CaptainHYOJUN")
        #expect(first.text.hasPrefix("14"))
        #expect(first.publishedTime == "3 days ago")
        #expect(first.likeCount == "549")
        #expect(first.authorAvatarURL != nil)
    }

    @Test("reply entities are not top-level comments and reply tokens are not the next page")
    func repliesAreSkipped() async throws {
        let page = api.parseCommentPage(from: try json(CommentsPageFixtures.page1))

        #expect(page.comments.count == 3)
        #expect(!page.comments.contains { $0.id == "reply-1" })
        #expect(page.nextToken != "SYNTHETIC-REPLY-TOKEN-MUST-BE-IGNORED")
    }

    @Test("the next-page token is the item-level continuation of the page")
    func nextTokenOfFirstPage() async throws {
        let page = api.parseCommentPage(from: try json(CommentsPageFixtures.page1))
        #expect(page.nextToken == CommentsPageFixtures.page1NextToken)
    }

    @Test("a second page appends its comments and carries the following token")
    func secondPage() async throws {
        let page = api.parseCommentPage(from: try json(CommentsPageFixtures.page2))
        #expect(page.comments.map(\.id) == CommentsPageFixtures.page2CommentIDs)
        #expect(page.nextToken == CommentsPageFixtures.page2NextToken)
    }

    @Test("the last page has no next token")
    func lastPage() async throws {
        let page = api.parseCommentPage(from: try json(CommentsPageFixtures.page2Last))
        #expect(page.comments.count == 2)
        #expect(page.nextToken == nil)
    }

    @Test("a response without comments or a comments panel yields an empty page")
    func emptyResponse() async throws {
        let response = try json(#"{"responseContext": {}}"#)
        let page = api.parseCommentPage(from: response)
        #expect(page.comments.isEmpty)
        #expect(page.nextToken == nil)
        #expect(api.parseCommentsCountText(from: response) == nil)
        #expect(api.parseCommentsContinuationToken(from: response) == nil)
    }

    @Test("responses in the legacy commentRenderer shape still parse")
    func legacyCommentRenderer() async throws {
        let response = try json(
            #"""
            {"onResponseReceivedEndpoints": [{"reloadContinuationItemsCommand": {"continuationItems": [
              {"commentRenderer": {
                "commentId": "legacy-1",
                "authorText": {"simpleText": "@legacy"},
                "contentText": {"runs": [{"text": "Old shape"}]},
                "voteCount": {"simpleText": "12"},
                "publishedTimeText": {"runs": [{"text": "1 year ago"}]},
                "isLiked": true
              }}
            ]}}]}
            """#)
        let page = api.parseCommentPage(from: response)
        let only = try #require(page.comments.first)
        #expect(page.comments.count == 1)
        #expect(only.id == "legacy-1")
        #expect(only.author == "@legacy")
        #expect(only.text == "Old shape")
        #expect(only.likeCount == "12")
        #expect(only.isLiked)
    }
}
