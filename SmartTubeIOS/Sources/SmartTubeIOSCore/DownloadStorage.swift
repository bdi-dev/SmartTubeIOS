import Foundation

// MARK: - DownloadStorage
//
// Read-only storage figures for the Downloads screen. Nothing here deletes anything: the app
// never removes a download without an explicit user action.

extension DownloadStore {
    /// Total size on disk of every finished download. Entries whose file is missing count as 0.
    public func totalBytes() -> Int64 {
        entries
            .filter { $0.status == .complete }
            .reduce(into: Int64(0)) { total, entry in
                let size =
                    (try? FileManager.default.attributesOfItem(atPath: fileURL(for: entry).path)[.size]) as? Int64
                total += size ?? 0
            }
    }

    /// Free space on the volume holding `directory`, favouring the "important usage" figure the
    /// system reports to users. `nil` if it cannot be read.
    public nonisolated static func availableBytes(at directory: URL) -> Int64? {
        #if os(tvOS)
        // tvOS has no "important usage" figure.
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
        #else
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// `true` when free space is known and below `DownloadTuning.lowDiskWarningBytes`.
    public func isLowOnDisk() -> Bool {
        guard let free = Self.availableBytes(at: downloadsDirectory) else { return false }
        return free < DownloadTuning.lowDiskWarningBytes
    }
}

/// Formats a byte count the way the Downloads screen shows it ("2.6 GB").
public func formatByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
