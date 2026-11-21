import Foundation

/// Tunables for the personal downloads library. One definition per threshold.
public enum DownloadTuning {
    /// Maximum number of downloads processed concurrently by `VideoDownloadService`.
    public static let maxConcurrent = 2
}
