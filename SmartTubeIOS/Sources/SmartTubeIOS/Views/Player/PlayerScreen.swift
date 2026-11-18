import SmartTubeIOSCore
import SwiftUI

// MARK: - PlayerScreen
//
// The "open this video" routing seam for platforms that present the player straight from
// a view (tvOS, macOS) — the counterpart of iOS's `PlayerRouter`.
//
// On tvOS it picks the player engine:
//   - `AppSettings.useMPVPlayerOnTV` on → the mpv engine (`MPVPlayerView`).
//   - Otherwise, or once mpv has given up on this video and the user asks for it → the
//     standard AVPlayer pipeline (`PlayerView`).
// The choice is made per video and never changes mid-playback: a fallback re-opens the
// video from scratch in the other engine rather than handing a running stream across.

struct PlayerScreen: View {
    let video: Video
    let api: InnerTubeAPI

    #if os(tvOS)
    @Environment(SettingsStore.self) private var store
    /// Set when mpv failed on this video and the user chose the standard player.
    @State private var fellBackToStandardPlayer = false
    /// Lets the sidebar layout hide itself while a player is on screen.
    @Environment(\.tvPlayerPresented) private var playerPresented
    #endif

    var body: some View {
        #if os(tvOS)
        Group {
            if store.settings.useMPVPlayerOnTV && !fellBackToStandardPlayer {
                MPVPlayerView(video: video, api: api) {
                    fellBackToStandardPlayer = true
                }
            } else {
                PlayerView(video: video, api: api)
            }
        }
        .onAppear { playerPresented?.wrappedValue = true }
        .onDisappear { playerPresented?.wrappedValue = false }
        #else
        PlayerView(video: video, api: api)
        #endif
    }
}
