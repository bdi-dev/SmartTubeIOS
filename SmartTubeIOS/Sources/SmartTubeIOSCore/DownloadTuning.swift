import Foundation

/// Tunables for the personal downloads library. One definition per threshold.
public enum DownloadTuning {
    /// Maximum number of downloads processed concurrently by `VideoDownloadService`.
    public static let maxConcurrent = 2

    /// Identifier of the single background `URLSession` that carries every CDN transfer.
    /// It must be identical across launches so the system can hand finished work back to us.
    public static let backgroundSessionIdentifier = "com.void.smarttube.app.downloads"
}
