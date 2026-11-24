import SmartTubeIOSCore
import SwiftUI

// MARK: - DownloadsView

/// Shows videos that have been downloaded to the device via VideoDownloadService.
/// Each row displays the thumbnail, title, channel, duration, file size, and
/// download date. Tapping a row plays the video from the local file (no network
/// required). Swipe-to-delete removes both the MP4 and the DownloadStore record.

struct DownloadsView: View {
    @Environment(DownloadStore.self) private var downloadStore
    @Environment(SettingsStore.self) private var settingsStore

    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(VideoDownloadService.self) private var downloadService
    @State private var nasLibrary: NASLibraryViewModel?
    #else
    @State private var selectedVideo: Video?
    #endif

    @State private var deleteConfirmationVideoId: String?

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        tvOSBody
        #endif
    }

    #if os(iOS)
    /// The two download switches, always visible at the top.
    private var downloadToggles: some View {
        @Bindable var settings = settingsStore
        return VStack(spacing: 0) {
            Toggle("Enable downloads", isOn: $settings.settings.downloadsEnabled)
                .accessibilityIdentifier(AccessibilityID.Downloads.enableToggle)
                .onChange(of: settings.settings.downloadsEnabled) { _, _ in downloadService.refreshPolicy() }
            Divider().padding(.vertical, 6)
            Toggle("Enable cellular", isOn: $settings.settings.allowCellularDownloads)
                .accessibilityIdentifier(AccessibilityID.Downloads.cellularToggle)
                .disabled(!settings.settings.downloadsEnabled)
                .onChange(of: settings.settings.allowCellularDownloads) { _, _ in downloadService.refreshPolicy() }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var iOSBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                storageSummary
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            downloadToggles

            if downloadStore.entries.isEmpty && !(nasLibrary?.isVisible ?? false) {
                emptyState
            } else {
                List {
                    ForEach(downloadStore.entries.sorted { $0.downloadedAt > $1.downloadedAt }) { entry in
                        DownloadedVideoRow(
                            entry: entry,
                            holdReason: downloadService.holdReason,
                            onRetry: { downloadService.retry(videoId: entry.videoId) },
                            onPause: { downloadService.pause(videoId: entry.videoId) },
                            onResume: { downloadService.resume(videoId: entry.videoId) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let video = downloadStore.video(for: entry) {
                                playerRouter.openLocal(video: video)
                            }
                        }
                        .contextMenu {
                            if entry.status == .complete {
                                ShareLink(
                                    item: DownloadExportItem(
                                        source: downloadStore.fileURL(for: entry),
                                        fileName: DownloadExport.fileName(for: entry)),
                                    preview: SharePreview(entry.title)
                                ) {
                                    Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                                }
                                .accessibilityIdentifier(AccessibilityID.Downloads.share(entry.videoId))
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.Downloads.videoRow(entry.videoId))
                    }
                    .onDelete { indexSet in
                        let sorted = downloadStore.entries.sorted { $0.downloadedAt > $1.downloadedAt }
                        for idx in indexSet {
                            deleteConfirmationVideoId = sorted[idx].videoId
                        }
                    }
                    if let nas = nasLibrary, nas.isVisible {
                        nasSection(nas)
                    }
                }
                .listStyle(.plain)
                .refreshable { await nasLibrary?.refresh() }
            }
        }
        .task {
            if nasLibrary == nil {
                nasLibrary = Self.makeNASLibrary(store: downloadStore)
            }
            await nasLibrary?.appear()
        }
        .alert(
            "Delete Download",
            isPresented: Binding(
                get: { deleteConfirmationVideoId != nil },
                set: { if !$0 { deleteConfirmationVideoId = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let vid = deleteConfirmationVideoId {
                    downloadService.cancel(videoId: vid)
                    downloadStore.remove(videoId: vid)
                }
                deleteConfirmationVideoId = nil
            }
            Button("Cancel", role: .cancel) {
                deleteConfirmationVideoId = nil
            }
        } message: {
            Text("This video will be removed from your device. You can re-download it from the player.")
        }
    }

    /// The server is consulted only when a URL and token are set; otherwise the section stays hidden.
    private static func makeNASLibrary(store: DownloadStore) -> NASLibraryViewModel {
        let cfg = YtDlpServerConfig.current()
        var client: (any YtDlpServerClient)?
        if cfg.isConfigured, let baseURL = cfg.baseURL, let token = cfg.token {
            client = URLSessionYtDlpServerClient(baseURL: baseURL, token: token)
        }
        return NASLibraryViewModel(client: client, store: store)
    }

    /// "Available on NAS": the server's copies this device does not hold. Tap downloads to the
    /// device; leading swipe deletes the NAS copy; trailing swipe keeps or unkeeps it.
    @ViewBuilder
    private func nasSection(_ nas: NASLibraryViewModel) -> some View {
        Section {
            ForEach(nas.available) { item in
                NASLibraryRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        downloadService.enqueue(video: Video(libraryItem: item), forceServer: true)
                    }
                    .swipeActions(edge: .leading) {
                        Button(role: .destructive) {
                            Task { await nas.deleteFromNAS(videoId: item.videoId) }
                        } label: {
                            Label("Delete from NAS", systemImage: AppSymbol.trash)
                        }
                        .accessibilityIdentifier(AccessibilityID.Downloads.nasDelete(item.videoId))
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await nas.setKeep(videoId: item.videoId, keep: !item.keep) }
                        } label: {
                            Label(
                                item.keep ? "Unkeep" : "Keep",
                                systemImage: item.keep ? AppSymbol.pinSlash : AppSymbol.pin)
                        }
                        .accessibilityIdentifier(AccessibilityID.Downloads.nasKeep(item.videoId))
                    }
                    .task(id: item.videoId) { await nas.loadMoreIfNeeded(after: item.videoId) }
                    .accessibilityIdentifier(AccessibilityID.Downloads.nasRow(item.videoId))
            }
            if let message = nas.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityID.Downloads.nasMessage)
            }
        } header: {
            Text("Available on NAS")
                .accessibilityIdentifier(AccessibilityID.Downloads.nasSection)
        }
    }

    /// "2.6 GB used · 45 GB free", turning orange with a note when space is low. Informational only:
    /// the app never deletes downloads by itself.
    private var storageSummary: some View {
        let used = downloadStore.totalBytes()
        let free = DownloadStore.availableBytes(at: downloadStore.downloadsDirectory)
        let low = downloadStore.isLowOnDisk()
        return VStack(alignment: .trailing, spacing: 2) {
            Text(
                free.map { "\(formatByteCount(used)) used · \(formatByteCount($0)) free" }
                    ?? "\(formatByteCount(used)) used"
            )
            .font(.caption)
            .foregroundStyle(low ? Color.orange : Color.secondary)
            .accessibilityIdentifier(AccessibilityID.Downloads.storageSummary)
            if low {
                Text("Low storage — new downloads may fail")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AccessibilityID.Downloads.lowStorageWarning)
            }
        }
    }
    #else
    private var tvOSBody: some View {
        emptyState
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.to.line.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No Downloaded Videos")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Download a video from the player to watch it offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.emptyState")
    }
}

// MARK: - DownloadedVideoRow

private struct DownloadedVideoRow: View {
    let entry: DownloadedVideo
    var holdReason: DownloadHoldReason?
    let onRetry: () -> Void
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    @Environment(DownloadStore.self) private var downloadStore

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var fileSizeDescription: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: downloadStore.fileURL(for: entry).path),
            let bytes = attrs[.size] as? Int64
        else { return "" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }

    private var durationDescription: String {
        guard entry.duration > 0 else { return "" }
        return formatDuration(entry.duration)
    }

    private var percentText: String { "\(Int((entry.progress * 100).rounded()))%" }

    /// "Paused", or "34 MB of 80 MB · 3.1 MB/s" while data is flowing.
    private var transferDetail: String {
        if entry.isPaused { return String(localized: "Paused", bundle: .module) }
        switch holdReason {
        case .disabled: return String(localized: "Downloads are off", bundle: .module)
        case .waitingForWiFi: return String(localized: "Waiting for Wi-Fi", bundle: .module)
        case nil: break
        }
        var parts: [String] = []
        if entry.bytesExpected > 0 {
            parts.append(
                "\(formatByteCount(entry.bytesReceived)) of \(formatByteCount(entry.bytesExpected))")
        }
        if entry.bytesPerSecond > 0 {
            parts.append("\(formatByteCount(Int64(entry.bytesPerSecond)))/s")
        }
        return parts.isEmpty ? String(localized: "Starting…", bundle: .module) : parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusView: some View {
        switch entry.status {
        case .complete:
            EmptyView()
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Downloads.status(entry.videoId))
        case .downloading:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ProgressView(value: entry.progress)
                        .tint(entry.isPaused ? .secondary : .accentColor)
                        .accessibilityIdentifier(AccessibilityID.Downloads.progress(entry.videoId))
                    Text(percentText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.Downloads.percent(entry.videoId))
                    Button {
                        entry.isPaused ? onResume() : onPause()
                    } label: {
                        Image(systemName: entry.isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(entry.isPaused ? "Resume download" : "Pause download")
                    .accessibilityIdentifier(
                        entry.isPaused ? "downloads.resume.\(entry.videoId)" : "downloads.pause.\(entry.videoId)")
                }
                Text(transferDetail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Downloads.status(entry.videoId))
            }
        case .merging:
            Text("Merging…").font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Downloads.status(entry.videoId))
        case .failed:
            HStack(spacing: 8) {
                Text(entry.errorMessage ?? String(localized: "Download failed", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry", action: onRetry)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.Downloads.retry(entry.videoId))
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().foregroundStyle(.secondary.opacity(0.3))
                }
            }
            .frame(width: 100, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(entry.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusView
                HStack(spacing: 8) {
                    if entry.isAudioOnly {
                        HStack(spacing: 3) {
                            Image(systemName: AppSymbol.audioDownload)
                            Text("Audio")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityIdentifier(AccessibilityID.Downloads.audioBadge(entry.videoId))
                    }
                    if !durationDescription.isEmpty {
                        Text(durationDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if entry.status == .complete, !fileSizeDescription.isEmpty {
                        Text(fileSizeDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.dateFormatter.string(from: entry.downloadedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - NASLibraryRow

#if os(iOS)
/// One "Available on NAS" row: thumbnail, title, channel, duration, size, and a pin when kept.
private struct NASLibraryRow: View {
    let item: YtDlpLibraryItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.thumbnailURL.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle().foregroundStyle(.secondary.opacity(0.3))
                }
            }
            .frame(width: 100, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(item.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let duration = item.duration, duration > 0 {
                        Text(formatDuration(duration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let size = item.fileSize {
                        Text(formatByteCount(size))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if item.keep {
                        Image(systemName: AppSymbol.pin)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Kept on NAS")
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
#endif
