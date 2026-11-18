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
                        commentRow(comment)
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

    private func commentRow(_ comment: Comment) -> some View {
        let isFocused = focus.wrappedValue == .comment(comment.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                AsyncImage(url: comment.authorAvatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(.white.opacity(0.15))
                }
                .frame(width: 56, height: 56)
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
        .focused(focus, equals: .comment(comment.id))
        .accessibilityElement(children: .combine)
    }
}
#endif
