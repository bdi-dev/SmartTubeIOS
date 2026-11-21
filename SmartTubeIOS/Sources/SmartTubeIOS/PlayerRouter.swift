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

    /// `openInStreamPlayer` for button actions: shows a toast when no plain stream exists.
    public func playStream(video: Video, api: InnerTubeAPI) {
        Task { [self] in
            if await openInStreamPlayer(video: video, api: api) { return }
            ToastCenter.shared.show(
                title: String(localized: "Stream unavailable", bundle: .module),
                message: String(localized: "No plain video file was available for this video.", bundle: .module))
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
        playerState.play(video: direct)
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
