import Foundation
import Observation
import os

private let downloadStoreLog = Logger(subsystem: appSubsystem, category: "DownloadStore")

// MARK: - DownloadedVideo

/// A record representing a video that has been (or is being) downloaded to the device's local storage.
/// Persisted in `Documents/SmartTubeDownloads/manifest.json`.
///
/// The file is referenced by `fileName` relative to the store's downloads directory, never by an
/// absolute URL: the app container path changes across reinstalls/updates.
public struct DownloadedVideo: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued, downloading, merging, complete, failed
    }

    public var id: String { videoId }
    public let videoId: String
    public let title: String
    public let channelTitle: String
    public let thumbnailURL: URL?
    public let duration: Double
    public let fileName: String
    public let downloadedAt: Date
    public var status: Status
    public var errorMessage: String?
    /// 0…1. Only meaningful while `status == .downloading`.
    public var progress: Double
    /// `true` for a download that saved only the audio track (smaller; plays as audio).
    public let isAudioOnly: Bool
    /// `true` while a running download is suspended by the user. Only meaningful for `.downloading`.
    public var isPaused: Bool

    public init(
        videoId: String,
        title: String,
        channelTitle: String,
        thumbnailURL: URL?,
        duration: Double,
        fileName: String,
        downloadedAt: Date,
        status: Status = .queued,
        errorMessage: String? = nil,
        progress: Double = 0,
        isAudioOnly: Bool = false,
        isPaused: Bool = false
    ) {
        self.videoId = videoId
        self.title = title
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.fileName = fileName
        self.downloadedAt = downloadedAt
        self.status = status
        self.errorMessage = errorMessage
        self.progress = progress
        self.isAudioOnly = isAudioOnly
        self.isPaused = isPaused
    }

    private enum CodingKeys: String, CodingKey {
        case videoId, title, channelTitle, thumbnailURL, duration, fileName, downloadedAt
        case status, errorMessage, progress, isAudioOnly, isPaused
        /// Legacy manifests stored an absolute `fileURL` and had no `status`.
        case fileURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decode(String.self, forKey: .title)
        channelTitle = try c.decode(String.self, forKey: .channelTitle)
        thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        duration = try c.decode(Double.self, forKey: .duration)
        downloadedAt = try c.decode(Date.self, forKey: .downloadedAt)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        isAudioOnly = try c.decodeIfPresent(Bool.self, forKey: .isAudioOnly) ?? false
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        if let name = try c.decodeIfPresent(String.self, forKey: .fileName) {
            fileName = name
            status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .complete
        } else {
            // Legacy entry: absolute fileURL, implicitly complete.
            let legacy = try c.decode(URL.self, forKey: .fileURL)
            fileName = legacy.lastPathComponent
            status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .complete
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(title, forKey: .title)
        try c.encode(channelTitle, forKey: .channelTitle)
        try c.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try c.encode(duration, forKey: .duration)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(downloadedAt, forKey: .downloadedAt)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(progress, forKey: .progress)
        try c.encode(isAudioOnly, forKey: .isAudioOnly)
        try c.encode(isPaused, forKey: .isPaused)
    }

    /// Synthesises a `Video` with `localFileURL` resolved against `directory`, suitable for
    /// `PlaybackViewModel.load(video:)`. Returns `nil` unless the download is complete.
    public func video(in directory: URL) -> Video? {
        guard status == .complete else { return nil }
        var v = Video(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            thumbnailURL: thumbnailURL,
            duration: duration
        )
        v.localFileURL = directory.appendingPathComponent(fileName)
        return v
    }
}

// MARK: - DownloadStore

/// Persistent in-app registry of downloaded videos.
///
/// Downloaded MP4s are stored under `Documents/SmartTubeDownloads/<videoId>.mp4`.
/// A JSON manifest (`manifest.json` in the same directory) records metadata for
/// each download so the `DownloadsView` can display title, thumbnail, and duration
/// without opening each MP4.
///
/// `VideoDownloadService` calls `upsert(_:)`, `setProgress`, `setStatus` and `finalize`.
/// `DownloadsView` calls `remove(videoId:)` when the user swipes to delete.
/// `PlaybackViewModel+Loading` reads `Video.localFileURL` (populated by
/// `video(for:)`) to skip the network fetch entirely.
@Observable
@MainActor
public final class DownloadStore {
    public static let shared = DownloadStore()

    public private(set) var entries: [DownloadedVideo] = []

    public let downloadsDirectory: URL

    private var manifestURL: URL {
        downloadsDirectory.appendingPathComponent("manifest.json")
    }

    /// `Documents/SmartTubeDownloads`. Nonisolated so the background `URLSession` delegate can
    /// compute the staging directory without hopping to the main actor.
    public nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTubeDownloads")
    }

    private convenience init() {
        if ProcessInfo.processInfo.arguments.contains(DownloadTuning.resetLaunchArgument) {
            try? FileManager.default.removeItem(at: Self.defaultDirectory)
        }
        self.init(directory: Self.defaultDirectory)
    }

    /// Where finished background transfers and per-video job records wait for post-processing.
    public var staging: DownloadStaging {
        DownloadStaging(root: downloadsDirectory.appendingPathComponent("Staging", isDirectory: true))
    }

    /// Creates a store rooted at `directory` (tests inject a temp directory).
    public init(directory: URL) {
        downloadsDirectory = directory
        loadManifest()
        reconcile()
    }

    // MARK: - Public API

    /// The on-disk file name for a downloaded video.
    /// Percent-encodes the `videoId` to guarantee a 1-to-1 mapping between any
    /// video ID and its filename — avoids the theoretical collision that could
    /// occur when two IDs differ only in special characters stripped by a
    /// character-filter approach.
    public func fileName(for videoId: String) -> String {
        let encoded = videoId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? videoId
        return "\(encoded).mp4"
    }

    /// The on-disk destination for a downloaded video.
    public func destinationURL(for videoId: String) -> URL {
        downloadsDirectory.appendingPathComponent(fileName(for: videoId))
    }

    /// Resolves an entry's file against the current downloads directory.
    public func fileURL(for entry: DownloadedVideo) -> URL {
        downloadsDirectory.appendingPathComponent(entry.fileName)
    }

    /// A playable `Video` for `entry`, or `nil` unless the download is complete.
    public func video(for entry: DownloadedVideo) -> Video? {
        entry.video(in: downloadsDirectory)
    }

    public func entry(for videoId: String) -> DownloadedVideo? {
        entries.first { $0.videoId == videoId }
    }

    /// Adds or replaces a download record and persists the manifest.
    public func upsert(_ entry: DownloadedVideo) {
        if let i = entries.firstIndex(where: { $0.videoId == entry.videoId }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        saveManifest()
    }

    /// Updates in-flight progress (0…1). Not persisted: progress is meaningless across launches.
    public func setProgress(videoId: String, progress: Double) {
        guard let i = entries.firstIndex(where: { $0.videoId == videoId }) else { return }
        entries[i].progress = min(max(progress, 0), 1)
    }

    /// Marks a running download as paused/resumed by the user and persists it.
    public func setPaused(videoId: String, _ paused: Bool) {
        guard let i = entries.firstIndex(where: { $0.videoId == videoId }),
            entries[i].status == .downloading
        else { return }
        entries[i].isPaused = paused
        saveManifest()
    }

    public func setStatus(videoId: String, status: DownloadedVideo.Status, error: String? = nil) {
        guard let i = entries.firstIndex(where: { $0.videoId == videoId }) else { return }
        entries[i].status = status
        entries[i].errorMessage = error
        if status != .downloading { entries[i].isPaused = false }
        if status == .complete { entries[i].progress = 1 }
        saveManifest()
    }

    /// Moves a finished temp file into the downloads directory and marks the entry complete.
    /// The status flips to `.complete` only after the final file is in place.
    /// Returns `false` (and marks the entry failed) if any step fails.
    @discardableResult
    public func finalize(videoId: String, from tempURL: URL) -> Bool {
        guard let entry = entry(for: videoId) else { return false }
        let fm = FileManager.default
        let finalURL = downloadsDirectory.appendingPathComponent(entry.fileName)
        let partialURL = finalURL.deletingPathExtension().appendingPathExtension("partial")
        do {
            try ensureDirectory()
            try? fm.removeItem(at: partialURL)
            try fm.moveItem(at: tempURL, to: partialURL)
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: partialURL)
            } else {
                try fm.moveItem(at: partialURL, to: finalURL)
            }
        } catch {
            downloadStoreLog.error(
                "finalize failed for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: partialURL)
            setStatus(videoId: videoId, status: .failed, error: error.localizedDescription)
            return false
        }
        setStatus(videoId: videoId, status: .complete)
        return true
    }

    /// Deletes the MP4 file and removes the record from the manifest.
    public func remove(videoId: String) {
        if let entry = entry(for: videoId) {
            try? FileManager.default.removeItem(at: fileURL(for: entry))
        }
        staging.remove(videoId: videoId)
        entries.removeAll { $0.videoId == videoId }
        saveManifest()
    }

    // MARK: - Reconcile

    /// Repairs state left over from a previous launch: missing files and stray `.partial` files.
    /// Queued / downloading / merging entries are deliberately left alone: with a background
    /// `URLSession` they may still be running or fully staged. `VideoDownloadService` decides
    /// their fate after asking the session for its live tasks.
    func reconcile() {
        let fm = FileManager.default
        var changed = false
        for i in entries.indices {
            switch entries[i].status {
            case .complete:
                let path = downloadsDirectory.appendingPathComponent(entries[i].fileName).path
                if !fm.fileExists(atPath: path) {
                    entries[i].status = .failed
                    entries[i].errorMessage = "File missing"
                    changed = true
                }
            case .queued, .downloading, .merging, .failed:
                break
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: downloadsDirectory.path) {
            for name in names where name.hasSuffix(".partial") {
                try? fm.removeItem(at: downloadsDirectory.appendingPathComponent(name))
            }
        }
        if changed { saveManifest() }
    }

    // MARK: - Persistence

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
            let decoded = try? JSONDecoder().decode([DownloadedVideo].self, from: data)
        else {
            return
        }
        entries = decoded
    }

    private func saveManifest() {
        try? ensureDirectory()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Creates the downloads directory and excludes it from iCloud/device backup.
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        var dir = downloadsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}
