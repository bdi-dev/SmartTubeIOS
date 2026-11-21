#if !os(tvOS)
import SmartTubeIOSCore
import SwiftUI

// MARK: - DownloadActionButton
//
// The single "Download" menu item used by video cards, Shorts cards and the web player's
// overflow menu. Label reflects the video's download status; tapping queues it.

enum DownloadActionLabel {
    static func title(for status: DownloadedVideo.Status?) -> LocalizedStringKey {
        switch status {
        case .complete: return "Downloaded"
        case .queued, .downloading, .merging: return "Downloading…"
        case .failed, nil: return "Download"
        }
    }

    static func isEnabled(for status: DownloadedVideo.Status?) -> Bool {
        switch status {
        case .complete, .queued, .downloading, .merging: return false
        case .failed, nil: return true
        }
    }
}

struct DownloadActionButton: View {
    let video: Video
    @Environment(VideoDownloadService.self) private var downloadService

    var body: some View {
        let status = downloadService.status(for: video.id)
        Button {
            downloadService.enqueue(video: video)
        } label: {
            Label(DownloadActionLabel.title(for: status), systemImage: AppSymbol.download)
        }
        .disabled(!DownloadActionLabel.isEnabled(for: status))
    }
}
#endif
