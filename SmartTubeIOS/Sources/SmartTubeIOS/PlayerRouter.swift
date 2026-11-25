#if os(iOS)
import Foundation
import SmartTubeIOSCore

// MARK: - PlayerRouter
//
// Single "open this video" decision point for iOS.
//
// Every place in the app that lets the user tap a video (Home, Search, Browse,
// Channel, Playlist, Library, RSS, and the deep-link / Share-Extension handlers
// in RootView) calls `open(video:api:)` instead of reaching into
// `PlayerStateStore` or `TOSPlayerStateStore` directly. That keeps the
// TOS-vs-AVPlayer routing decision — and the mini-player conflict rule — in one
// place instead of duplicated across every view.
//
// Routing rules:
//   - If `settingsStore.useTOSPlayerOnIOS` is true (the default — always on except
//     for UI tests that opt out) and this video hasn't previously hit a fatal embed
//     error (TOSPlayerStateStore.fallbackVideoId), present the WKWebView-based
//     TOS-compliant player.
//   - Otherwise present the AVPlayer-based pipeline.
// In both cases, any active mini-player for the *other* pipeline is stopped
// first — AVPlayer and TOS playback are mutually exclusive.
@MainActor
@Observable
public final class PlayerRouter {
    private let playerState: PlayerStateStore
    private let tosState: TOSPlayerStateStore
    private let settingsStore: SettingsStore

    public init(playerState: PlayerStateStore, tosState: TOSPlayerStateStore, settingsStore: SettingsStore) {
        self.playerState = playerState
        self.tosState = tosState
        self.settingsStore = settingsStore
    }

    /// Plays a downloaded video (`video.localFileURL` set). Local files always use the AVPlayer
    /// pipeline, never the web player; any active web-player session is stopped first.
    public func openLocal(video: Video) {
        if tosState.presentation != .hidden { tosState.stop() }
        playerState.play(video: video)
    }

    /// Plays `video` in the YouTube web player regardless of the setting. Used from the native
    /// player's error screen when a video can't be played natively (for example an encrypted stream).
    public func openInWebPlayer(video: Video, api: InnerTubeAPI) {
        if playerState.presentation != .hidden { playerState.stop() }
        tosState.play(video: video, api: api, incognito: false)
    }

    /// Plays `video` in the native AVPlayer pipeline (adaptive streams, quality picker). Fails on
    /// encrypted streams, in which case its error screen offers the web player.
    public func openInNativePlayer(video: Video) {
        if tosState.presentation != .hidden { tosState.stop() }
        playerState.play(video: video)
    }

    /// `openInStreamPlayer` for button actions. When no plain stream exists and the yt-dlp server
    /// is set up, falls back to it; otherwise shows a toast.
    public func playStream(video: Video, api: InnerTubeAPI) {
        Task { [self] in
            if await openInStreamPlayer(video: video, api: api) { return }
            if YtDlpServerConfig.current().isConfigured {
                await playFromServer(video: video)
                return
            }
            ToastCenter.shared.show(
                title: String(localized: "Stream unavailable", bundle: .module),
                message: String(localized: "No plain video file was available for this video.", bundle: .module))
        }
    }

    /// Plays `video` from the user's yt-dlp server: the server fetches it, then the file streams to
    /// the custom player. Works for videos the app cannot decrypt; waits while the server prepares it.
    public func playFromServer(video: Video) {
        Task { [self] in await playFromServer(video: video) }
    }

    private func playFromServer(video: Video) async {
        let config = YtDlpServerConfig.current()
        guard config.isConfigured else {
            ToastCenter.shared.show(
                title: String(localized: "yt-dlp server not set up", bundle: .module),
                message: String(localized: "Add its address and token in Settings > Downloads.", bundle: .module))
            return
        }
        ToastCenter.shared.show(
            title: String(localized: "Preparing on your server", bundle: .module),
            message: String(localized: "Playback starts when the server has the video.", bundle: .module))
        do {
            var direct = video
            direct.directStream = try await YtDlpServerStream.resolve(videoId: video.id, config: config)
            if tosState.presentation != .hidden { tosState.stop() }
            playerState.play(video: direct, replacingSource: true)
        } catch {
            ToastCenter.shared.show(
                title: String(localized: "Server could not play this", bundle: .module),
                message: error.localizedDescription)
        }
    }

    /// Plays `video` in the custom native player by streaming a plain MP4 (the same lookup the
    /// downloader uses). Quality is limited to that file's (often 360p-720p), and live streams and
    /// some videos have none. Returns `false`, leaving whatever is playing untouched, when no
    /// stream is available.
    @discardableResult
    public func openInStreamPlayer(video: Video, api: InnerTubeAPI) async -> Bool {
        guard let stream = await InnerTubeDownloadFetcher.muxedStream(api: api, videoId: video.id) else {
            return false
        }
        var direct = video
        direct.directStream = stream
        if tosState.presentation != .hidden { tosState.stop() }
        playerState.play(video: direct, replacingSource: true)
        return true
    }

    /// Open `video` in whichever player pipeline is currently preferred.
    /// `incognito` (#94) skips recording this video to watch history / resume
    /// position — currently only honored by the TOS pipeline (the iOS default);
    /// the legacy AVPlayer pipeline's history recording isn't wired to it yet.
    public func open(video: Video, api: InnerTubeAPI, incognito: Bool = false) {
        if settingsStore.useTOSPlayerOnIOS && tosState.fallbackVideoId != video.id {
            if playerState.presentation != .hidden { playerState.stop() }
            tosState.play(video: video, api: api, incognito: incognito)
            return
        }
        if tosState.presentation != .hidden { tosState.stop() }
        playerState.play(video: video)
    }
}
#endif  // os(iOS)
