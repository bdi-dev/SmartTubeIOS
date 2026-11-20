import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOS

// CommentsController paging and reply threads, against a fake API. No network, no sleeps:
// tests await `waitUntilIdle()` for the requests in flight.

/// Scripted comments API. Each continuation key (`first` for the first page) pops its queued
/// results in order, and repeats the last one once only that is left.
private actor FakeCommentsAPI: CommentsFetching {
    struct Failure: Error {}

    private var pages: [String: [Result<CommentPage, Failure>]] = [:]
    private var replies: [String: [Result<CommentPage, Failure>]] = [:]
    private(set) var requestedKeys: [String] = []

    func queuePage(_ key: String, _ result: Result<CommentPage, Failure>) {
        pages[key, default: []].append(result)
    }

    func queueReplies(_ token: String, _ result: Result<CommentPage, Failure>) {
        replies[token, default: []].append(result)
    }

    func fetchCommentPage(videoId: String, continuation: String?) async throws -> CommentPage {
        let key = continuation ?? "first"
        requestedKeys.append(key)
        return try Self.next(&pages, key: key)
    }

    func fetchCommentReplies(continuation: String) async throws -> CommentPage {
        requestedKeys.append("replies:" + continuation)
        return try Self.next(&replies, key: continuation)
    }

    private static func next(
        _ store: inout [String: [Result<CommentPage, Failure>]], key: String
    ) throws -> CommentPage {
        guard let queue = store[key], !queue.isEmpty else { throw Failure() }
        if queue.count > 1 {
            store[key] = Array(queue.dropFirst())
        }
        return try queue[0].get()
    }
}

private func comment(
    _ id: String, replyToken: String? = nil, replyCount: String? = nil
) -> InnerTubeKit.Comment {
    InnerTubeKit.Comment(
        id: id, author: "@\(id)", authorAvatarURL: nil, text: "text \(id)", likeCount: "",
        publishedTime: "", isLiked: false, replyCountText: replyCount,
        replyContinuationToken: replyToken)
}

private func page(_ comments: [InnerTubeKit.Comment], next: String?) -> CommentPage {
    CommentPage(comments: comments, nextToken: next, totalCountText: nil)
}

@Suite("Comments controller")
@MainActor
struct CommentsControllerTests {

    @Test("first page loads the comments and the count, and keeps the next token")
    func firstPage() async {
        let api = FakeCommentsAPI()
        await api.queuePage(
            "first",
            .success(
                CommentPage(
                    comments: [comment("a"), comment("b")], nextToken: "p2", totalCountText: "5.4M")))
        let controller = CommentsController(api: api)

        controller.load(videoId: "v1")
        await controller.waitUntilIdle()

        #expect(controller.comments.map(\.id) == ["a", "b"])
        #expect(controller.totalCountText == "5.4M")
        #expect(controller.canLoadMoreComments)
        #expect(!controller.isLoading)
        #expect(!controller.loadFailed)
    }

    @Test("a second load while the first is loaded does nothing")
    func loadIsIdempotent() async {
        let api = FakeCommentsAPI()
        await api.queuePage("first", .success(page([comment("a")], next: nil)))
        let controller = CommentsController(api: api)

        controller.load(videoId: "v1")
        await controller.waitUntilIdle()
        controller.load(videoId: "v1")
        await controller.waitUntilIdle()

        #expect(await api.requestedKeys == ["first"])
    }

    @Test("next page appends comments and skips ids already shown")
    func pagingAppendsAndDedupes() async {
        let api = FakeCommentsAPI()
        await api.queuePage("first", .success(page([comment("a"), comment("b")], next: "p2")))
        await api.queuePage("p2", .success(page([comment("b"), comment("c")], next: nil)))
        let controller = CommentsController(api: api)

        controller.load(videoId: "v1")
        await controller.waitUntilIdle()
        controller.loadNextPage()
        await controller.waitUntilIdle()

        #expect(controller.comments.map(\.id) == ["a", "b", "c"])
        #expect(!controller.canLoadMoreComments)
    }

    @Test("a failed next page shows the retry state, and retrying loads the same token")
    func pagingFailureThenRetry() async {
        let api = FakeCommentsAPI()
        await api.queuePage("first", .success(page([comment("a")], next: "p2")))
        await api.queuePage("p2", .failure(FakeCommentsAPI.Failure()))
        await api.queuePage("p2", .success(page([comment("b")], next: nil)))
        let controller = CommentsController(api: api)

        controller.load(videoId: "v1")
        await controller.waitUntilIdle()
        controller.loadNextPage()
        await controller.waitUntilIdle()

        #expect(controller.loadMoreFailed)
        #expect(controller.comments.map(\.id) == ["a"])

        controller.loadNextPage()
        await controller.waitUntilIdle()

        #expect(!controller.loadMoreFailed)
        #expect(controller.comments.map(\.id) == ["a", "b"])
        #expect(await api.requestedKeys == ["first", "p2", "p2"])
    }

    @Test("a failed first page shows the retry state, and retrying loads it")
    func firstPageFailureThenRetry() async {
        let api = FakeCommentsAPI()
        await api.queuePage("first", .failure(FakeCommentsAPI.Failure()))
        await api.queuePage("first", .success(page([comment("a")], next: nil)))
        let controller = CommentsController(api: api)

        controller.load(videoId: "v1")
        await controller.waitUntilIdle()
        #expect(controller.loadFailed)
        #expect(controller.comments.isEmpty)

        controller.retryFirstPage()
        await controller.waitUntilIdle()
        #expect(!controller.loadFailed)
        #expect(controller.comments.map(\.id) == ["a"])
    }

    @Test("opening a thread loads its replies; closing it makes no request")
    func openAndCloseThread() async {
        let api = FakeCommentsAPI()
        await api.queueReplies("r1", .success(page([comment("r-1"), comment("r-2")], next: nil)))
        let parent = comment("a", replyToken: "r1", replyCount: "2 replies")
        let controller = CommentsController(api: api)

        controller.toggleReplies(for: parent)
        await controller.waitUntilIdle()
        #expect(controller.expandedThreadID == "a")
        #expect(controller.repliesState == .loaded)
        #expect(controller.replies.map(\.id) == ["r-1", "r-2"])

        controller.toggleReplies(for: parent)
        #expect(controller.expandedThreadID == nil)
        #expect(controller.replies.isEmpty)
        #expect(await api.requestedKeys == ["replies:r1"])
    }

    @Test("a failed first reply page shows retry, and retry loads the thread")
    func repliesFailureThenRetry() async {
        let api = FakeCommentsAPI()
        await api.queueReplies("r1", .failure(FakeCommentsAPI.Failure()))
        await api.queueReplies("r1", .success(page([comment("r-1")], next: nil)))
        let parent = comment("a", replyToken: "r1", replyCount: "1 reply")
        let controller = CommentsController(api: api)

        controller.toggleReplies(for: parent)
        await controller.waitUntilIdle()
        #expect(controller.repliesState == .failed)

        controller.retryReplies()
        await controller.waitUntilIdle()
        #expect(controller.repliesState == .loaded)
        #expect(controller.replies.map(\.id) == ["r-1"])
    }

    @Test("show more appends reply pages without repeating replies")
    func moreRepliesDedupe() async {
        let api = FakeCommentsAPI()
        await api.queueReplies("r1", .success(page([comment("r-1"), comment("r-2")], next: "r2")))
        await api.queueReplies("r2", .success(page([comment("r-2"), comment("r-3")], next: nil)))
        let parent = comment("a", replyToken: "r1", replyCount: "3 replies")
        let controller = CommentsController(api: api)

        controller.toggleReplies(for: parent)
        await controller.waitUntilIdle()
        #expect(controller.canLoadMoreReplies)

        controller.loadMoreReplies()
        await controller.waitUntilIdle()
        #expect(controller.replies.map(\.id) == ["r-1", "r-2", "r-3"])
        #expect(!controller.canLoadMoreReplies)
    }

    @Test("a failed later reply page keeps the replies shown and offers retry")
    func laterReplyPageFailure() async {
        let api = FakeCommentsAPI()
        await api.queueReplies("r1", .success(page([comment("r-1")], next: "r2")))
        await api.queueReplies("r2", .failure(FakeCommentsAPI.Failure()))
        let parent = comment("a", replyToken: "r1", replyCount: "5 replies")
        let controller = CommentsController(api: api)

        controller.toggleReplies(for: parent)
        await controller.waitUntilIdle()
        controller.loadMoreReplies()
        await controller.waitUntilIdle()

        #expect(controller.repliesState == .loaded)
        #expect(controller.repliesMoreFailed)
        #expect(controller.replies.map(\.id) == ["r-1"])
    }

    @Test("a reply page that lands after the thread was closed is dropped")
    func staleReplyPageDropped() async {
        let api = FakeCommentsAPI()
        await api.queueReplies("r1", .success(page([comment("r-1")], next: nil)))
        let parent = comment("a", replyToken: "r1", replyCount: "1 reply")
        let controller = CommentsController(api: api)

        controller.toggleReplies(for: parent)
        controller.collapseReplies()
        await controller.waitUntilIdle()

        #expect(controller.expandedThreadID == nil)
        #expect(controller.replies.isEmpty)
    }
}
