import SmartTubeIOSCore
import SwiftUI

// MARK: - Comments overlay
//
// Shared between PlayerView (standard player, including tvOS) and
// TOSPlayerView — both rendered an identical dim-backdrop bottom sheet
// listing `CommentRowView`s. tvOS-only focus handling stays behind
// `#if os(tvOS)` since PlayerView renders this on tvOS too.

/// Dim-backdrop bottom sheet listing video comments, or a loading/empty state.
struct CommentsOverlayView: View {
    let comments: [Comment]
    let isLoading: Bool
    let onDismiss: () -> Void
    #if os(tvOS)
    var focusNamespace: Namespace.ID
    #endif
    var accessibilityId: String? = nil
    /// When set, the list comes from the controller (paging and reply threads) and `comments` /
    /// `isLoading` are ignored. The iOS TOS player passes it; tvOS keeps the plain list.
    var controller: CommentsController? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Comments")
                        .fontWeight(.semibold)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 4)
                Divider()
                if let controller {
                    ControllerCommentsList(controller: controller)
                } else if isLoading {
                    ProgressView()
                        .padding(40)
                } else if comments.isEmpty {
                    Text("No comments available.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(comments) { comment in
                                CommentRowView(comment: comment)
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 400)
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            #if os(tvOS)
            .focusScope(focusNamespace)
            .onExitCommand { onDismiss() }
            #endif
            .padding(.horizontal, 8)
            .safeAreaPadding(.horizontal)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier(accessibilityId)
    }
}

// MARK: - Controller-driven list

/// The comments list when a `CommentsController` drives it: loading, empty and retry states,
/// a page-on-scroll sentinel at the end, and a reply thread under each comment that has one.
private struct ControllerCommentsList: View {
    let controller: CommentsController

    var body: some View {
        if controller.isLoading {
            ProgressView()
                .padding(40)
        } else if controller.loadFailed {
            VStack(spacing: 12) {
                Text("Could not load comments.")
                    .foregroundStyle(.secondary)
                TextRetryButton(title: "Retry") { controller.retryFirstPage() }
            }
            .padding(40)
        } else if controller.comments.isEmpty {
            Text("No comments available.")
                .foregroundStyle(.secondary)
                .padding(40)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.comments) { comment in
                        CommentThreadView(comment: comment, controller: controller)
                    }
                    pagingFooter
                }
                .padding()
            }
            .frame(maxHeight: 400)
        }
    }

    @ViewBuilder
    private var pagingFooter: some View {
        if controller.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else if controller.loadMoreFailed {
            TextRetryButton(title: "Could not load more comments. Retry") {
                controller.loadNextPage()
            }
        } else if controller.canLoadMoreComments {
            // Fetches the next page when it scrolls into view, and again whenever the list grows.
            // A failed page shows Retry instead, so it does not loop.
            Color.clear
                .frame(height: 1)
                .task(id: controller.comments.count) {
                    controller.loadNextPage()
                }
        }
    }
}

/// One comment, its "N replies" toggle, and the open thread under it when it is the expanded one.
private struct CommentThreadView: View {
    let comment: Comment
    let controller: CommentsController

    /// Replies are indented by the avatar column; the reply toggle lines up with the text.
    private static let replyIndent: CGFloat = 36
    private static let toggleIndent: CGFloat = 46

    private var isExpanded: Bool { controller.expandedThreadID == comment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommentRowView(comment: comment)
            if comment.hasReplies {
                repliesToggle
                if isExpanded {
                    threadRows
                }
            }
        }
    }

    private var repliesToggle: some View {
        Button {
            controller.toggleReplies(for: comment)
        } label: {
            Label(
                comment.replyCountText ?? String(localized: "Replies", bundle: .module),
                systemImage: isExpanded ? AppSymbol.chevronUp : AppSymbol.chevronDown
            )
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Self.toggleIndent)
        .accessibilityHint(isExpanded ? "Hides replies" : "Shows replies")
    }

    @ViewBuilder
    private var threadRows: some View {
        switch controller.repliesState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.leading, Self.replyIndent)
        case .failed:
            TextRetryButton(title: "Could not load replies. Retry") {
                controller.retryReplies()
            }
            .padding(.leading, Self.replyIndent)
        case .loaded:
            ForEach(controller.replies) { reply in
                CommentRowView(comment: reply)
                    .padding(.leading, Self.replyIndent)
            }
            if controller.isLoadingMoreReplies {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.leading, Self.replyIndent)
            } else if controller.repliesMoreFailed {
                TextRetryButton(title: "Could not load more replies. Retry") {
                    controller.loadMoreReplies()
                }
                .padding(.leading, Self.replyIndent)
            } else if controller.canLoadMoreReplies {
                TextRetryButton(title: "Show more replies") {
                    controller.loadMoreReplies()
                }
                .padding(.leading, Self.toggleIndent)
            }
        }
    }
}

/// A plain text button with a 44 pt tap height, for retry and "show more" rows.
private struct TextRetryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    @ViewBuilder
    func accessibilityIdentifier(_ id: String?) -> some View {
        if let id {
            self.accessibilityIdentifier(id)
        } else {
            self
        }
    }
}
