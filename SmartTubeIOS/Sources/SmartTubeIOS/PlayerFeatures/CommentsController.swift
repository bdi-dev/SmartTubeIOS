import Foundation
import SmartTubeIOSCore

// MARK: - Comments
//
// Shared between PlaybackViewModel (standard player) and TOSPlayerViewModel
// (TOS player) — both fetched top-level comments via InnerTubeAPI with an
// identical "skip if already loaded or in flight" guard. `videoId` is
// supplied per call so each adapter can keep its own video-id resolution
// (`(vm.playerInfo?.video ?? video).id` vs. `self.videoId`).
//
// The iOS comments sheet also pages comments and opens one reply thread at a
// time (the tvOS panel does the same in MPVPlayerViewModel). Parsing lives in
// InnerTubeKit; this file only holds the state machine.

/// The part of `InnerTubeAPI` the comments controller needs. Tests pass a fake.
protocol CommentsFetching: Sendable {
    func fetchCommentPage(videoId: String, continuation: String?) async throws -> CommentPage
    func fetchCommentReplies(continuation: String) async throws -> CommentPage
}

extension InnerTubeAPI: CommentsFetching {}

/// Fetches and caches comments for a video: the first page, later pages, and one open reply thread.
@MainActor
@Observable
final class CommentsController {

    /// Load state of a reply thread's first page.
    enum ThreadState: Equatable {
        case loading
        case loaded
        case failed
    }

    /// Comments and replies kept in memory per video; paging stops at these counts.
    static let maxLoadedComments = 200
    static let maxLoadedReplies = 200

    private(set) var comments: [Comment] = []
    /// The first page is in flight.
    private(set) var isLoading = false
    /// The first page failed; `retryFirstPage()` tries again.
    private(set) var loadFailed = false
    /// The count YouTube shows for the video ("5.4M"), when known.
    private(set) var totalCountText: String?
    /// A page after the first one is in flight.
    private(set) var isLoadingMore = false
    /// A page after the first one failed; `loadNextPage()` tries the same token again.
    private(set) var loadMoreFailed = false

    /// The one comment whose reply thread is open; `nil` when every thread is closed.
    private(set) var expandedThreadID: String?
    private(set) var replies: [Comment] = []
    /// State of the open thread's first reply page.
    private(set) var repliesState: ThreadState = .loaded
    /// A reply page after the first one is in flight.
    private(set) var isLoadingMoreReplies = false
    /// A reply page after the first one failed; `loadMoreReplies()` tries the same token again.
    private(set) var repliesMoreFailed = false

    private let api: any CommentsFetching
    private let logError: (String) -> Void

    private var videoId: String?
    private var nextToken: String?
    private var repliesNextToken: String?
    /// The open thread's first reply token, kept so a failed first page can be retried.
    private var threadFirstToken: String?
    private var commentsTask: Task<Void, Never>?
    private var repliesTask: Task<Void, Never>?
    /// Bumped whenever the open thread changes, so a reply page that lands after its thread was
    /// collapsed or replaced is dropped.
    private var threadGeneration = 0

    init(api: any CommentsFetching, logError: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.logError = logError
    }

    /// Whether a page after the loaded comments can be requested.
    var canLoadMoreComments: Bool {
        nextToken != nil && comments.count < Self.maxLoadedComments
    }

    /// Whether a page after the loaded replies can be requested.
    var canLoadMoreReplies: Bool {
        repliesNextToken != nil && replies.count < Self.maxLoadedReplies
    }

    // MARK: Comments

    /// Fetches the first page of comments for `videoId`. No-op if already loaded or in flight.
    func load(videoId: String) {
        guard comments.isEmpty, !isLoading else { return }
        self.videoId = videoId
        isLoading = true
        loadFailed = false
        commentsTask = Task {
            do {
                let page = try await self.api.fetchCommentPage(videoId: videoId, continuation: nil)
                self.comments = Array(page.comments.prefix(Self.maxLoadedComments))
                self.nextToken = page.nextToken
                self.totalCountText = page.totalCountText
            } catch {
                self.loadFailed = true
                self.logError("fetchComments failed: \(String(describing: error))")
            }
            self.isLoading = false
        }
    }

    /// Retries the first page after it failed.
    func retryFirstPage() {
        guard loadFailed, let videoId else { return }
        load(videoId: videoId)
    }

    /// Fetches the page after the loaded comments. Comments already shown are not repeated.
    func loadNextPage() {
        guard !isLoading, !isLoadingMore, let videoId, let token = nextToken, canLoadMoreComments
        else { return }
        isLoadingMore = true
        loadMoreFailed = false
        commentsTask = Task {
            do {
                let page = try await self.api.fetchCommentPage(videoId: videoId, continuation: token)
                let seen = Set(self.comments.map(\.id))
                let fresh = page.comments.filter { !seen.contains($0.id) }
                self.comments.append(
                    contentsOf: fresh.prefix(Self.maxLoadedComments - self.comments.count))
                self.nextToken = page.nextToken
            } catch {
                self.loadMoreFailed = true
                self.logError("fetchComments (next page) failed: \(String(describing: error))")
            }
            self.isLoadingMore = false
        }
    }

    // MARK: Replies

    /// Opens the reply thread under `comment` (its replies load now), or closes it when it is
    /// already open. Opening another thread closes the one that was open.
    func toggleReplies(for comment: Comment) {
        if expandedThreadID == comment.id {
            collapseReplies()
            return
        }
        guard let token = comment.replyContinuationToken else { return }
        repliesTask?.cancel()
        threadGeneration += 1
        expandedThreadID = comment.id
        threadFirstToken = token
        replies = []
        repliesNextToken = nil
        isLoadingMoreReplies = false
        repliesMoreFailed = false
        repliesState = .loading
        startReplyRequest(token: token, isFirstPage: true)
    }

    /// Closes the open reply thread, dropping any reply request still in flight.
    func collapseReplies() {
        repliesTask?.cancel()
        repliesTask = nil
        threadGeneration += 1
        expandedThreadID = nil
        threadFirstToken = nil
        replies = []
        repliesNextToken = nil
        isLoadingMoreReplies = false
        repliesMoreFailed = false
        repliesState = .loaded
    }

    /// Retries the open thread's first reply page after it failed.
    func retryReplies() {
        guard repliesState == .failed, let token = threadFirstToken else { return }
        repliesState = .loading
        startReplyRequest(token: token, isFirstPage: true)
    }

    /// Fetches the next reply page of the open thread (also retries a failed one).
    func loadMoreReplies() {
        guard repliesState == .loaded, !isLoadingMoreReplies, let token = repliesNextToken,
            canLoadMoreReplies
        else { return }
        isLoadingMoreReplies = true
        repliesMoreFailed = false
        startReplyRequest(token: token, isFirstPage: false)
    }

    private func startReplyRequest(token: String, isFirstPage: Bool) {
        let generation = threadGeneration
        repliesTask = Task {
            await self.fetchReplies(token: token, isFirstPage: isFirstPage, generation: generation)
        }
    }

    private func fetchReplies(token: String, isFirstPage: Bool, generation: Int) async {
        let result: Result<CommentPage, any Error>
        do {
            result = .success(try await api.fetchCommentReplies(continuation: token))
        } catch {
            result = .failure(error)
        }
        // The thread was collapsed or replaced while this page was in flight.
        guard generation == threadGeneration else { return }
        isLoadingMoreReplies = false
        switch result {
        case .success(let page):
            let seen = Set(replies.map(\.id))
            let fresh = page.comments.filter { !seen.contains($0.id) }
            replies.append(contentsOf: fresh.prefix(Self.maxLoadedReplies - replies.count))
            repliesNextToken = page.nextToken
            repliesState = .loaded
        case .failure(let error):
            logError("fetchCommentReplies failed: \(String(describing: error))")
            // A failed first page offers Retry in place of the thread; a failed later page keeps
            // the replies shown and offers Retry under them.
            if isFirstPage {
                repliesState = .failed
            } else {
                repliesMoreFailed = true
            }
        }
    }

    /// Waits for the requests in flight to finish. Tests use it to read the settled state.
    func waitUntilIdle() async {
        await commentsTask?.value
        await repliesTask?.value
    }
}
