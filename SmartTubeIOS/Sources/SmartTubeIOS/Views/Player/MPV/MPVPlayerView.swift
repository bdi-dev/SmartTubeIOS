#if os(tvOS)
import SmartTubeIOSCore
import SwiftUI
import UIKit

private let mpvViewLog = CrashlyticsLogger(category: "MPVPlayer")

// MARK: - MPVPlayerView
//
// tvOS player screen for the opt-in mpv engine.
//
// Remote handling is left to the tvOS focus engine rather than routed in software:
//   • Controls hidden — one full-screen focus target (`surface`). Select / up / down bring
//     the controls up, left / right jump by the configured seek steps, Play/Pause toggles.
//   • Controls visible — real `Button`s and `Menu`s in two focus sections (scrubber row,
//     transport row), so the Siri Remote moves between them spatially and Menu/Back
//     dismisses the overlay before it leaves the player.

struct MPVPlayerView: View {
    let video: Video
    let api: InnerTubeAPI
    /// Called when the user asks to play this video with the standard (AVPlayer) player
    /// after mpv could not open it.
    let onFallback: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var store
    @Environment(AuthService.self) private var auth

    /// Created in `.task`, not `init`: the view struct is re-created on every parent
    /// update and each view model owns a live mpv core.
    @State private var vm: MPVPlayerViewModel?
    /// The video being played; differs from `video` after up-next / autoplay moved on.
    @State private var playing: Video?
    @FocusState private var focus: FocusTarget?
    /// The transport-row button focus last rested on. Down from the scrubber returns here,
    /// so the focus engine re-enters the row at the button the user left.
    @State private var lastTransportFocus: FocusTarget = .playPause
    /// Set while Down from the scrubber is handing focus back to `lastTransportFocus`; keeps
    /// the row locked to that one button until focus lands there.
    @State private var restoringTransportFocus: FocusTarget?

    enum FocusTarget: Hashable {
        case surface
        case scrubber
        case seekBack, playPause, seekForward
        case previous, next
        case captions, speed, quality, audio, chapters, comments
        case related(String)
        /// The comments panel when it has no comment rows to focus (loading, off, failed).
        case commentsPanel
        case comment(String)
        /// Rows of an open reply thread; the id is the parent comment's.
        case repliesToggle(String)
        case reply(String)
        case repliesMore(String)
        case repliesRetry(String)
        case skipSegment
        case errorRetry, errorFallback, errorNext, errorClose

        /// Buttons in the transport row (including the menus on its right).
        var isTransport: Bool {
            switch self {
            case .seekBack, .playPause, .seekForward, .previous, .next,
                .captions, .speed, .quality, .audio, .chapters, .comments:
                return true
            default:
                return false
            }
        }
    }

    enum ID {
        static let surface = "mpvPlayer.surface"
        static let scrubber = "mpvPlayer.scrubber"
        static let playPause = "mpvPlayer.playPauseButton"
        static let seekBack = "mpvPlayer.seekBackButton"
        static let seekForward = "mpvPlayer.seekForwardButton"
        static let quality = "mpvPlayer.qualityMenu"
        static let previous = "mpvPlayer.previousButton"
        static let next = "mpvPlayer.nextButton"
        static let audio = "mpvPlayer.audioMenu"
        static let chapters = "mpvPlayer.chaptersMenu"
        static let related = "mpvPlayer.relatedVideoButton"
        static let relatedShelf = "mpvPlayer.relatedShelf"
        static let comments = "mpvPlayer.commentsButton"
        static let commentsPanel = "mpvPlayer.commentsPanel"
        static let repliesToggle = "mpvPlayer.repliesToggle"
        static let speed = "mpvPlayer.speedMenu"
        static let captions = "mpvPlayer.captionsMenu"
        static let skipSegment = "mpvPlayer.skipSegmentButton"
        static let streamBadge = "mpvPlayer.streamBadge"
        static let errorMessage = "mpvPlayer.errorMessage"
        static let fallbackButton = "mpvPlayer.useStandardPlayerButton"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let vm {
                // A fresh identity per video: no focus, scrub or overlay state carries over.
                playerBody(vm)
                    .id(ObjectIdentifier(vm))
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: (playing ?? video).id) {
            // Moving to another video replaces the whole view model — one engine per video.
            vm?.stop()
            vm = nil
            let model = MPVPlayerViewModel(
                video: playing ?? video, api: api, settings: store.settings, isSignedIn: auth.isSignedIn)
            model.autoSkipUnavailable = playing != nil
            model.onPlayVideo = { next in playing = next }
            vm = model
            model.start()
        }
        .onDisappear { vm?.stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: vm?.handleBackground()
            case .active: vm?.handleForeground()
            default: break
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func playerBody(_ vm: MPVPlayerViewModel) -> some View {
        ZStack {
            if let engine = vm.engine {
                MPVVideoSurface(layer: engine.layer)
                    .id(ObjectIdentifier(engine))
                    .ignoresSafeArea()
                    // Shrinks toward the left edge, vertically centred, while the panel is open.
                    .scaleEffect(vm.commentsVisible ? MPVCommentsPanel.videoScale : 1, anchor: .leading)
            }

            if vm.errorMessage == nil {
                if vm.commentsVisible {
                    MPVCommentsPanel(vm: vm, focus: $focus)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if vm.relatedShelfVisible {
                    relatedShelf(vm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if vm.controlsVisible {
                    controlsOverlay(vm)
                        .transition(.opacity)
                } else {
                    surfaceTarget(vm)
                    if vm.progressFlashVisible {
                        VStack {
                            Spacer()
                            progressBar(vm, focused: false)
                                .padding(.horizontal, 80)
                                .padding(.bottom, 70)
                        }
                        // Scrim so the bar and times stay readable over bright video.
                        .background(
                            LinearGradient(
                                colors: [.clear, .clear, .black.opacity(0.7)],
                                startPoint: .top, endPoint: .bottom
                            )
                            .ignoresSafeArea()
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
            }

            if vm.isLoading || vm.isBuffering {
                loadingIndicator(vm)
            }

            if let segment = vm.toastSegment, vm.errorMessage == nil, !vm.relatedShelfVisible, !vm.commentsVisible {
                skipSegmentButton(segment, vm)
            }

            if let message = vm.errorMessage {
                errorOverlay(message, vm)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: vm.progressFlashVisible)
        .animation(.easeOut(duration: 0.25), value: vm.relatedShelfVisible)
        .animation(.easeInOut(duration: MPVCommentsPanel.transitionDuration), value: vm.commentsVisible)
        .onPlayPauseCommand { vm.togglePlayPause() }
        // Back peels one layer at a time: comments panel, shelf, controls, then the player.
        .onExitCommand {
            if vm.commentsVisible {
                // Inside an open thread the first Back returns to its parent comment.
                if let parent = vm.expandedThreadID, isThreadFocus(focus, parent: parent) {
                    focus = .comment(parent)
                    vm.collapseReplies()
                } else {
                    vm.closeComments()
                }
            } else if vm.relatedShelfVisible {
                vm.closeRelatedShelf()
            } else if vm.controlsVisible, vm.errorMessage == nil, !vm.videoEnded {
                vm.hideControls()
            } else {
                close(vm)
            }
        }
        // A system menu takes focus away from every target here; keep the overlay up
        // underneath it. Any other focus change counts as interaction.
        .onChange(of: focus) { oldFocus, newFocus in
            mpvViewLog.debug(
                "[focus] \(String(describing: oldFocus)) → \(String(describing: newFocus)) controls=\(vm.controlsVisible)"
            )
            // Focus leaving a menu button for "nothing" means its menu just opened.
            let menuButtons: [FocusTarget?] = [.captions, .speed, .quality, .audio, .chapters]
            vm.holdControls = newFocus == nil && menuButtons.contains(oldFocus) && vm.controlsVisible
            if newFocus != nil, newFocus != .surface, vm.controlsVisible { vm.showControls() }
            if let target = restoringTransportFocus {
                if newFocus == target { restoringTransportFocus = nil }
            } else if let newFocus, newFocus.isTransport {
                lastTransportFocus = newFocus
            }
            if case .related(let id)? = newFocus { vm.relatedCardFocused(id) }
            if case .comment(let id)? = newFocus { vm.commentFocused(id) }
        }
        // Comments load after the panel opens: when they arrive, focus moves from the panel's
        // placeholder (or nothing, once it is gone) onto the first comment.
        .onChange(of: vm.commentsState) { _, state in
            guard vm.commentsVisible, state == .loaded, focus == nil || focus == .commentsPanel,
                let first = vm.comments.first
            else { return }
            focus = .comment(first.id)
        }
        // Every fresh show of the overlay starts on Play, as it always has.
        .onChange(of: vm.controlsVisible) { _, visible in
            if visible { lastTransportFocus = .playPause }
        }
        // With the controls hidden, focus sits on the video surface, whose Select brings
        // the controls up. Hand focus to the skip button when it appears so one press of
        // Select skips the segment; when it goes away focus falls back to the surface.
        .onChange(of: vm.toastSegment?.id) { _, segmentID in
            if segmentID != nil, !vm.controlsVisible, !vm.relatedShelfVisible, !vm.commentsVisible {
                focus = .skipSegment
            }
        }
        // Safety net: the focused control can leave the hierarchy in the same update that
        // shows or hides the overlay (e.g. the skip button at the end of the video), and
        // the focus engine then sometimes settles on nothing until the next key press.
        // Give it a moment, then put focus where that state expects it.
        .task(id: vm.controlsVisible) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, focus == nil, vm.errorMessage == nil, !vm.holdControls,
                !vm.relatedShelfVisible, !vm.commentsVisible
            else { return }
            focus = vm.controlsVisible ? restoredTransportFocus(vm) : (vm.toastSegment != nil ? .skipSegment : .surface)
        }
        // The shelf and the surface come and go with this flag, and the focused view leaves
        // the hierarchy with them. Opening puts focus on a card; closing returns it to the
        // surface, so Select and the remote keep working without a stray press.
        .task(id: vm.relatedShelfVisible) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, vm.errorMessage == nil else { return }
            if vm.relatedShelfVisible {
                focus = relatedShelfFocus(vm)
            } else if !vm.controlsVisible, !vm.commentsVisible, focus == nil || isRelatedCard(focus) {
                focus = vm.toastSegment != nil ? .skipSegment : .surface
            }
        }
        // The panel takes focus when it opens (first comment, else its placeholder). Closing
        // returns focus to the surface, as the controls are hidden while the panel is open.
        .task(id: vm.commentsVisible) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, vm.errorMessage == nil else { return }
            if vm.commentsVisible {
                let first: FocusTarget? = vm.comments.first.map { FocusTarget.comment($0.id) }
                focus = first ?? .commentsPanel
            } else if !vm.controlsVisible, !vm.relatedShelfVisible, focus == nil || isCommentsFocus(focus) {
                focus = vm.toastSegment != nil ? .skipSegment : .surface
            }
        }
    }

    /// Focus on the replies row or any row of the thread opened under `parent`.
    private func isThreadFocus(_ target: FocusTarget?, parent: String) -> Bool {
        switch target {
        case .repliesToggle(let id)?, .repliesMore(let id)?, .repliesRetry(let id)?: return id == parent
        case .reply?: return true  // only the open thread's replies are on screen
        default: return false
        }
    }

    private func isCommentsFocus(_ target: FocusTarget?) -> Bool {
        switch target {
        case .comment?, .commentsPanel?, .repliesToggle?, .reply?, .repliesMore?, .repliesRetry?: return true
        default: return false
        }
    }

    /// The card focus should land on when the shelf opens: the one last focused in this
    /// video, else the first.
    private func relatedShelfFocus(_ vm: MPVPlayerViewModel) -> FocusTarget? {
        let cards = vm.relatedVideos.prefix(8)
        if let id = vm.relatedShelfFocusID, cards.contains(where: { $0.id == id }) {
            return .related(id)
        }
        return cards.first.map { .related($0.id) }
    }

    private func isRelatedCard(_ target: FocusTarget?) -> Bool {
        if case .related? = target { return true }
        return false
    }

    /// The remembered transport button, or Play when that button is no longer rendered
    /// (Previous/Next, chapters, audio, captions and quality depend on the video).
    /// Mirrors the conditions used by `transportRow`.
    private func restoredTransportFocus(_ vm: MPVPlayerViewModel) -> FocusTarget {
        switch lastTransportFocus {
        case .previous: return vm.canPlayPrevious ? .previous : .playPause
        case .next: return vm.canPlayNext ? .next : .playPause
        case .chapters: return vm.chapters.isEmpty ? .playPause : .chapters
        case .audio: return vm.audioOptions.count > 1 ? .audio : .playPause
        case .captions: return vm.captionTracks.isEmpty ? .playPause : .captions
        case .quality: return vm.selectablePlans.count > 1 ? .quality : .playPause
        case .comments: return vm.canShowComments ? .comments : .playPause
        default: return lastTransportFocus
        }
    }

    /// The only transport button that may take focus right now: the remembered one while the
    /// timeline is focused or focus is being handed back to it. Nil when the row is free.
    private func transportFocusLock(_ vm: MPVPlayerViewModel) -> FocusTarget? {
        guard focus == .scrubber || restoringTransportFocus != nil else { return nil }
        return restoringTransportFocus ?? restoredTransportFocus(vm)
    }

    /// Returns focus to the remembered transport button once the engine's own move from the
    /// scrubber has landed, and keeps that move from rewriting `lastTransportFocus`.
    private func restoreTransportFocus(_ vm: MPVPlayerViewModel) {
        let target = restoredTransportFocus(vm)
        restoringTransportFocus = target
        Task { @MainActor in
            await Task.yield()
            focus = target
            lastTransportFocus = target
            // If focus was already there no change fires; do not stay in restoring mode.
            try? await Task.sleep(for: .milliseconds(400))
            if restoringTransportFocus == target { restoringTransportFocus = nil }
        }
    }

    private func close(_ vm: MPVPlayerViewModel) {
        vm.stop()
        dismiss()
    }

    // MARK: - Surface (controls hidden)

    private func surfaceTarget(_ vm: MPVPlayerViewModel) -> some View {
        Button {
            vm.showControls()
        } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(MPVSurfaceButtonStyle())
        .focused($focus, equals: .surface)
        .onMoveCommand { direction in
            switch direction {
            case .left: vm.seekRelative(seconds: -Double(store.settings.seekBackSeconds))
            case .right: vm.seekRelative(seconds: Double(store.settings.seekForwardSeconds))
            case .down:
                // Down opens the related shelf; with nothing to show, it brings up the controls.
                if vm.relatedVideos.isEmpty { vm.showControls() } else { vm.openRelatedShelf() }
            default: vm.showControls()
            }
        }
        .accessibilityLabel(Text("Video", bundle: .module))
        .accessibilityIdentifier(ID.surface)
        .ignoresSafeArea()
    }

    // MARK: - Controls overlay

    private func controlsOverlay(_ vm: MPVPlayerViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(vm)
            Spacer()
            if vm.videoEnded, !vm.relatedVideos.isEmpty {
                upNextRow(vm)
                    .focusSection()
                    .padding(.bottom, 32)
            }
            scrubber(vm)
                .focusSection()
            transportRow(vm)
                .focusSection()
                .padding(.top, 28)
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .defaultFocus($focus, .playPause)
    }

    private func header(_ vm: MPVPlayerViewModel) -> some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                Text(vm.video.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(vm.video.channelTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let badge = streamBadge(vm) {
                Text(badge)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.15), in: Capsule())
                    .accessibilityIdentifier(ID.streamBadge)
            }
        }
        .foregroundStyle(.white)
    }

    /// e.g. `"2160p60 VP9 · Hardware"`.
    private func streamBadge(_ vm: MPVPlayerViewModel) -> String? {
        guard let plan = vm.activePlan else { return nil }
        var label = plan.label
        if plan.height == nil, let size = vm.videoSize {
            label = "\(size.height)p (HLS)"
        }
        switch vm.hardwareDecoder {
        case .none: return label
        case .some("no"): return label + " · " + String(localized: "Software", bundle: .module)
        case .some: return label + " · " + String(localized: "Hardware", bundle: .module)
        }
    }

    // MARK: Scrubber

    private func scrubber(_ vm: MPVPlayerViewModel) -> some View {
        progressBar(vm, focused: focus == .scrubber)
            .focusable()
            .focused($focus, equals: .scrubber)
            .onMoveCommand { direction in
                switch direction {
                case .left: vm.scrub(by: -scrubStep(vm))
                case .right: vm.scrub(by: scrubStep(vm))
                case .down:
                    // `onMoveCommand` does not consume the move: the focus engine also
                    // steps down to the button nearest the scrubber (+30) and ignores
                    // `defaultFocus` for directional moves. Let it finish, then put focus
                    // back on the button the user left.
                    vm.commitScrub()
                    restoreTransportFocus(vm)
                default: break
                }
            }
            .onTapGesture { vm.commitScrub() }
            .accessibilityElement()
            .accessibilityLabel(Text("Playback position", bundle: .module))
            .accessibilityValue(Text(formatDuration(vm.isScrubbing ? vm.scrubTime : vm.currentTime)))
            .accessibilityIdentifier(ID.scrubber)
    }

    /// 10 s steps, widening for long videos so a film is still crossable.
    private func scrubStep(_ vm: MPVPlayerViewModel) -> TimeInterval {
        max(10, (vm.duration / 120).rounded())
    }

    private func progressBar(_ vm: MPVPlayerViewModel, focused: Bool) -> some View {
        let time = vm.isScrubbing ? vm.scrubTime : vm.currentTime
        let duration = vm.duration
        return VStack(spacing: 12) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
                let buffered = duration > 0 ? min(max((vm.currentTime + vm.cacheAhead) / duration, 0), 1) : 0
                let barHeight: CGFloat = focused ? 14 : 8
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.35)).frame(width: width * buffered)
                    Capsule().fill(Color.accentColor).frame(width: width * fraction)
                    if duration > 0 {
                        ForEach(vm.chapters.dropFirst()) { chapter in
                            Rectangle()
                                .fill(.black.opacity(0.7))
                                .frame(width: 3)
                                .offset(x: width * min(max(chapter.startTime / duration, 0), 1))
                        }
                        ForEach(vm.sponsorSegments) { segment in
                            let start = min(max(segment.start / duration, 0), 1)
                            let end = min(max(segment.end / duration, 0), 1)
                            Rectangle()
                                .fill(segment.category.color)
                                .frame(width: max(width * (end - start), 3))
                                .offset(x: width * start)
                        }
                    }
                }
                .frame(height: barHeight)
                .clipShape(Capsule())
                // The thumb sits on top of the clipped track, not inside it.
                .overlay(alignment: .leading) {
                    if focused {
                        Circle()
                            .fill(.white)
                            .frame(width: 30, height: 30)
                            .shadow(color: .black.opacity(0.5), radius: 6)
                            .offset(x: width * fraction - 15)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 30)

            HStack {
                Text(formatDuration(time))
                    .fontWeight(vm.isScrubbing ? .bold : .regular)
                Spacer()
                if let chapter = vm.currentChapter {
                    Text(chapter.title)
                        .lineLimit(1)
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                Text(duration > 0 ? formatDuration(duration) : "--:--")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    // MARK: Transport row

    private func transportRow(_ vm: MPVPlayerViewModel) -> some View {
        HStack(spacing: 28) {
            if vm.canPlayPrevious {
                Button {
                    vm.playPrevious()
                } label: {
                    Image(systemName: AppSymbol.previousTrack)
                }
                .focused($focus, equals: .previous)
                .transportFocusable(.previous, only: transportFocusLock(vm))
                .accessibilityLabel(Text("Previous", bundle: .module))
                .accessibilityIdentifier(ID.previous)
            }

            Button {
                vm.seekRelative(seconds: -Double(store.settings.seekBackSeconds))
            } label: {
                Image(systemName: AppSymbol.seekBackward(store.settings.seekBackSeconds))
            }
            .focused($focus, equals: .seekBack)
            .transportFocusable(.seekBack, only: transportFocusLock(vm))
            .accessibilityLabel(Text("Skip Back", bundle: .module))
            .accessibilityIdentifier(ID.seekBack)

            Button {
                vm.togglePlayPause()
            } label: {
                Image(systemName: vm.videoEnded ? AppSymbol.replay : (vm.isPlaying ? AppSymbol.pause : AppSymbol.play))
                    .frame(minWidth: 44)
            }
            .focused($focus, equals: .playPause)
            .transportFocusable(.playPause, only: transportFocusLock(vm))
            .accessibilityLabel(
                vm.isPlaying ? Text("Pause", bundle: .module) : Text("Play", bundle: .module)
            )
            .accessibilityIdentifier(ID.playPause)

            Button {
                vm.seekRelative(seconds: Double(store.settings.seekForwardSeconds))
            } label: {
                Image(systemName: AppSymbol.seekForward(store.settings.seekForwardSeconds))
            }
            .focused($focus, equals: .seekForward)
            .transportFocusable(.seekForward, only: transportFocusLock(vm))
            .accessibilityLabel(Text("Skip Forward", bundle: .module))
            .accessibilityIdentifier(ID.seekForward)

            if vm.canPlayNext {
                Button {
                    vm.playNext()
                } label: {
                    Image(systemName: AppSymbol.nextTrack)
                }
                .focused($focus, equals: .next)
                .transportFocusable(.next, only: transportFocusLock(vm))
                .accessibilityLabel(Text("Next", bundle: .module))
                .accessibilityIdentifier(ID.next)
            }

            Spacer()

            if !vm.chapters.isEmpty {
                chaptersMenu(vm)
            }
            if vm.audioOptions.count > 1 {
                audioMenu(vm)
            }
            if vm.canShowComments {
                commentsButton(vm)
            }
            if !vm.captionTracks.isEmpty {
                captionsMenu(vm)
            }
            speedMenu(vm)
            if vm.selectablePlans.count > 1 {
                qualityMenu(vm)
            }
        }
        .font(.title3)
        // Down from the bottom row has nowhere to go in the overlay: it raises the shelf.
        .onMoveCommand { direction in
            if direction == .down, !vm.relatedVideos.isEmpty { vm.openRelatedShelf() }
        }
    }

    private func commentsButton(_ vm: MPVPlayerViewModel) -> some View {
        Button {
            vm.openComments()
        } label: {
            Image(systemName: AppSymbol.comments)
        }
        .focused($focus, equals: .comments)
        .transportFocusable(.comments, only: transportFocusLock(vm))
        .accessibilityLabel(Text("Comments", bundle: .module))
        .accessibilityIdentifier(ID.comments)
    }

    private func chaptersMenu(_ vm: MPVPlayerViewModel) -> some View {
        Menu {
            ForEach(vm.chapters) { chapter in
                Button {
                    vm.jump(to: chapter)
                } label: {
                    menuRow(
                        "\(formatDuration(chapter.startTime))  \(chapter.title)",
                        selected: vm.currentChapter?.id == chapter.id)
                }
            }
        } label: {
            Label(String(localized: "Chapters", bundle: .module), systemImage: AppSymbol.chapterList)
                .labelStyle(.iconOnly)
        }
        .focused($focus, equals: .chapters)
        .transportFocusable(.chapters, only: transportFocusLock(vm))
        .accessibilityIdentifier(ID.chapters)
    }

    private func audioMenu(_ vm: MPVPlayerViewModel) -> some View {
        let current = vm.effectiveAudio
        return Menu {
            ForEach(vm.audioOptions) { option in
                Button {
                    vm.selectAudio(option)
                } label: {
                    menuRow(option.name, selected: current == option)
                }
            }
        } label: {
            Label(String(localized: "Audio", bundle: .module), systemImage: AppSymbol.audioTrack)
                .labelStyle(.iconOnly)
        }
        .focused($focus, equals: .audio)
        .transportFocusable(.audio, only: transportFocusLock(vm))
        .accessibilityIdentifier(ID.audio)
    }

    /// Suggestions offered once the video has ended (and autoplay did not take over).
    private func upNextRow(_ vm: MPVPlayerViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Up Next", bundle: .module)
                .font(.headline)
            relatedCards(vm)
        }
        .foregroundStyle(.white)
    }

    /// Related videos raised over the bottom third of the playing video. The video keeps
    /// playing behind a scrim that darkens only the bottom of the frame.
    private func relatedShelf(_ vm: MPVPlayerViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Related", bundle: .module)
                .font(.headline)
            relatedCards(vm)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 80)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.6), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .focusSection()
        // Up from the top row of cards leaves the shelf; Back closes it through `onExitCommand`.
        .onMoveCommand { direction in
            if direction == .up { vm.closeRelatedShelf() }
        }
        .accessibilityIdentifier(ID.relatedShelf)
    }

    private func relatedCards(_ vm: MPVPlayerViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 28) {
                ForEach(vm.relatedVideos.prefix(8)) { related in
                    relatedCard(related, vm)
                }
            }
            // Room inside the scroll content for the `.card` focus lift (~1.1x scale) and its
            // shadow; with clipping off the glow draws over the surrounding margins instead of
            // being cut at the scroll view's edges (first/last card included).
            .padding(.horizontal, Self.shelfFocusInset)
            .padding(.vertical, Self.shelfFocusInset)
        }
        .scrollClipDisabled()
        // Cancel the inset in layout so the cards still line up with the header text.
        .padding(.horizontal, -Self.shelfFocusInset)
        .padding(.vertical, -Self.shelfFocusInset + 20)
    }

    private static let shelfFocusInset: CGFloat = 50

    private func relatedCard(_ related: Video, _ vm: MPVPlayerViewModel) -> some View {
        Button {
            vm.play(related: related)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                AsyncImage(url: related.thumbnailURL) { image in
                    image.resizable().aspectRatio(16 / 9, contentMode: .fill)
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: 320, height: 180)
                .clipped()
                Text(related.title)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(width: 320, alignment: .leading)
            }
        }
        .buttonStyle(.card)
        .focused($focus, equals: .related(related.id))
        .accessibilityIdentifier(ID.related)
    }

    private func captionsMenu(_ vm: MPVPlayerViewModel) -> some View {
        Menu {
            Button {
                vm.selectCaption(nil)
            } label: {
                menuRow(String(localized: "Off", bundle: .module), selected: vm.selectedCaption == nil)
            }
            ForEach(vm.captionTracks) { track in
                Button {
                    vm.selectCaption(track)
                } label: {
                    menuRow(track.name, selected: vm.selectedCaption == track)
                }
            }
        } label: {
            Label(String(localized: "Captions", bundle: .module), systemImage: AppSymbol.captions)
                .labelStyle(.iconOnly)
        }
        .focused($focus, equals: .captions)
        .transportFocusable(.captions, only: transportFocusLock(vm))
        .accessibilityIdentifier(ID.captions)
    }

    private func speedMenu(_ vm: MPVPlayerViewModel) -> some View {
        Menu {
            ForEach(AppSettings.availableSpeeds, id: \.self) { speed in
                Button {
                    vm.setSpeed(speed)
                } label: {
                    menuRow(Self.speedLabel(speed), selected: vm.playbackSpeed == speed)
                }
            }
        } label: {
            Text(Self.speedLabel(vm.playbackSpeed))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .focused($focus, equals: .speed)
        .transportFocusable(.speed, only: transportFocusLock(vm))
        .accessibilityLabel(Text("Playback Speed", bundle: .module))
        .accessibilityIdentifier(ID.speed)
    }

    private func qualityMenu(_ vm: MPVPlayerViewModel) -> some View {
        Menu {
            ForEach(Array(vm.selectablePlans.enumerated()), id: \.offset) { _, plan in
                Button {
                    vm.select(plan: plan)
                } label: {
                    menuRow(plan.label, selected: vm.activePlan?.label == plan.label)
                }
            }
        } label: {
            Text(vm.activePlan?.height.map { "\($0)p" } ?? String(localized: "Quality", bundle: .module))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .focused($focus, equals: .quality)
        .transportFocusable(.quality, only: transportFocusLock(vm))
        .accessibilityLabel(Text("Quality", bundle: .module))
        .accessibilityIdentifier(ID.quality)
    }

    @ViewBuilder
    private func menuRow(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: AppSymbol.checkmark)
        } else {
            Text(title)
        }
    }

    private static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    // MARK: - Loading / SponsorBlock / error

    private func loadingIndicator(_ vm: MPVPlayerViewModel) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            if let status = vm.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .allowsHitTesting(false)
    }

    private func skipSegmentButton(_ segment: SponsorSegment, _ vm: MPVPlayerViewModel) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    vm.skipToastSegment()
                } label: {
                    Label(
                        String(localized: "Skip \(segment.category.displayName)", bundle: .module),
                        systemImage: AppSymbol.nextTrack)
                }
                .focused($focus, equals: .skipSegment)
                .accessibilityIdentifier(ID.skipSegment)
            }
        }
        .padding(.horizontal, 80)
        // Sits above the transport row when the controls are up, and clear of the
        // progress flash when they are not.
        .padding(.bottom, vm.controlsVisible ? 300 : 170)
        .focusSection()
    }

    private func errorOverlay(_ message: String, _ vm: MPVPlayerViewModel) -> some View {
        VStack(spacing: 36) {
            Image(systemName: AppSymbol.warning)
                .font(.system(size: 72))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(maxWidth: 1100)
                .accessibilityIdentifier(ID.errorMessage)
            HStack(spacing: 32) {
                Button(String(localized: "Use Standard Player", bundle: .module)) {
                    vm.stop()
                    onFallback()
                }
                .focused($focus, equals: .errorFallback)
                .accessibilityIdentifier(ID.fallbackButton)

                Button(String(localized: "Try Again", bundle: .module)) {
                    vm.retry()
                }
                .focused($focus, equals: .errorRetry)

                if vm.canPlayNext {
                    Button(String(localized: "Play Next", bundle: .module)) {
                        vm.playNext()
                    }
                    .focused($focus, equals: .errorNext)
                }

                Button(String(localized: "Close", bundle: .module)) {
                    close(vm)
                }
                .focused($focus, equals: .errorClose)
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
        .defaultFocus($focus, .errorFallback)
    }
}

// MARK: - MPVSurfaceButtonStyle

/// The surface is a focus target, not a visible control: no lift, no highlight.
private struct MPVSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
    }
}

// MARK: - MPVVideoSurface

/// Hosts the engine's Metal layer and keeps its frame and scale in step with the view.
private struct MPVVideoSurface: UIViewRepresentable {
    let layer: MPVMetalLayer

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.attach(layer)
        return view
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {
        // The view is reused when the player moves to the next video, but each video has its
        // own engine and layer — show the current one.
        uiView.attach(layer)
    }

    final class SurfaceView: UIView {
        private var videoLayer: CAMetalLayer?

        func attach(_ layer: CAMetalLayer) {
            guard videoLayer !== layer else { return }
            videoLayer?.removeFromSuperlayer()
            videoLayer = layer
            self.layer.addSublayer(layer)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let videoLayer else { return }
            // No implicit animation: the layer must track the bounds exactly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            videoLayer.contentsScale = window?.screen.nativeScale ?? traitCollection.displayScale
            CATransaction.commit()
        }
    }
}

private extension View {
    /// While the timeline owns focus, only the remembered transport button may take it. The
    /// focus engine moves focus before any state change from the Down press can render, and
    /// it picks the button nearest the bar (and ignores `defaultFocus` for directional
    /// moves), so the row has to offer a single candidate up front.
    @ViewBuilder
    func transportFocusable(_ target: MPVPlayerView.FocusTarget, only locked: MPVPlayerView.FocusTarget?) -> some View {
        if let locked, locked != target {
            focusable(false)
        } else {
            self
        }
    }
}
#endif
