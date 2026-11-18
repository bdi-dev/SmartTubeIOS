#if os(tvOS)
import SmartTubeIOSCore
import SwiftUI

// MARK: - MPVCommentsPanel
//
// Top-level comments on the right of the playing video. The video keeps playing in the left
// part of the screen (`MPVPlayerView` scales the surface by `videoScale`); this panel only
// draws the list. Focus stays inside it while it is open: each comment row is focusable, so
// the remote scrolls the list, the focused row shows its full text, and reaching the last few
// rows loads the next page (`MPVPlayerViewModel.commentFocused`).

struct MPVCommentsPanel: View {
    /// Share of the screen width the video keeps while the panel is open.
    static let videoScale: CGFloat = 0.62
    static let transitionDuration: Double = 0.3

    let vm: MPVPlayerViewModel
    var focus: FocusState<MPVPlayerView.FocusTarget?>.Binding

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // The video shows through the left part; this area takes no focus.
                Color.clear
                    .frame(width: geometry.size.width * Self.videoScale)
                    .allowsHitTesting(false)
                panel
                    .frame(width: geometry.size.width * (1 - Self.videoScale))
                    .frame(maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            content
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.8))
        .focusSection()
        .accessibilityIdentifier(MPVPlayerView.ID.commentsPanel)
    }

    /// "Comments", with the count YouTube shows when it is known.
    private var title: String {
        let base = String(localized: "Comments", bundle: .module)
        guard let count = vm.commentsCountText else { return base }
        return "\(base) (\(count))"
    }

    @ViewBuilder
    private var content: some View {
        switch vm.commentsState {
        case .idle, .loading:
            placeholder {
                ProgressView()
                    .controlSize(.large)
                Text("Loading comments", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .disabled:
            placeholder {
                Text("Comments are turned off.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .failed:
            VStack(spacing: 24) {
                Text("Could not load comments.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                Button(String(localized: "Retry", bundle: .module)) {
                    vm.retryComments()
                }
                .focused(focus, equals: .commentsPanel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(vm.comments) { comment in
                        commentRow(comment, target: .comment(comment.id))
                        if comment.hasReplies {
                            repliesToggleRow(comment)
                            if vm.expandedThreadID == comment.id {
                                threadRows(comment)
                            }
                        }
                    }
                    if vm.isLoadingMoreComments {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// A single focusable stand-in for the list while there is nothing to list yet, so the
    /// panel keeps focus (and Back keeps closing the panel rather than the player).
    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 20) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused(focus, equals: .commentsPanel)
    }

    /// One comment. Replies (`isReply`) are indented and use a smaller avatar.
    private func commentRow(
        _ comment: Comment, target: MPVPlayerView.FocusTarget, isReply: Bool = false
    ) -> some View {
        let isFocused = focus.wrappedValue == target
        let avatar: CGFloat = isReply ? 40 : 56
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                AsyncImage(url: comment.authorAvatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(.white.opacity(0.15))
                }
                .frame(width: avatar, height: avatar)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.author)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if !comment.publishedTime.isEmpty {
                        Text(comment.publishedTime)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 16)
                if !comment.likeCount.isEmpty {
                    Label(comment.likeCount, systemImage: AppSymbol.thumbsUp)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Text(comment.text)
                .font(.callout)
                // Unfocused rows are clipped to a few lines; the focused row shows it all.
                .lineLimit(isFocused ? nil : 6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(isFocused ? 0.2 : 0.06))
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .focusable()
        .focused(focus, equals: target)
        .accessibilityElement(children: .combine)
        .padding(.leading, isReply ? Self.replyIndent : 0)
    }

    static let replyIndent: CGFloat = 48

    // MARK: Reply threads

    /// "12 replies" under a comment: Select opens the thread under it, Select again closes it.
    private func repliesToggleRow(_ comment: Comment) -> some View {
        let target = MPVPlayerView.FocusTarget.repliesToggle(comment.id)
        let expanded = vm.expandedThreadID == comment.id
        let label = comment.replyCountText ?? String(localized: "Replies", bundle: .module)
        return actionRow(label, systemImage: expanded ? "chevron.up" : "chevron.down", target: target) {
            vm.toggleReplies(for: comment)
        }
        .accessibilityIdentifier(MPVPlayerView.ID.repliesToggle)
        .padding(.leading, Self.replyIndent)
    }

    /// The rows of the open thread under `comment`: replies, a spinner or Retry, "Show more".
    @ViewBuilder
    private func threadRows(_ comment: Comment) -> some View {
        switch vm.repliesState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        case .failed:
            actionRow(
                String(localized: "Could not load replies. Retry", bundle: .module),
                systemImage: "arrow.clockwise", target: .repliesRetry(comment.id)
            ) {
                vm.retryReplies()
            }
            .padding(.leading, Self.replyIndent)
        case .loaded:
            ForEach(vm.replies) { reply in
                commentRow(reply, target: .reply(reply.id), isReply: true)
            }
            if vm.isLoadingMoreReplies {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else if vm.canLoadMoreReplies {
                actionRow(
                    String(localized: "Show more replies", bundle: .module),
                    systemImage: "chevron.down", target: .repliesMore(comment.id)
                ) {
                    vm.loadMoreReplies()
                }
                .padding(.leading, Self.replyIndent)
            }
        }
    }

    /// A compact focusable row with an action, drawn like the comment rows.
    private func actionRow(
        _ title: String, systemImage: String, target: MPVPlayerView.FocusTarget,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus.wrappedValue == target
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(isFocused ? 0.2 : 0.06))
                )
        }
        .buttonStyle(PanelRowButtonStyle())
        .focused(focus, equals: target)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// No system focus platter: the panel draws its own row highlight.
private struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif
