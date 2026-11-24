#if !os(tvOS)
import CoreTransferable
import Foundation
import SmartTubeIOSCore
import UniformTypeIdentifiers

// MARK: - DownloadExport

/// Share/export of a finished download under a readable name (e.g. "Open Ocean 10 Hours.mp4")
/// instead of the video-id based storage name. The export is explicit and user-initiated: the
/// original file stays in app storage untouched.
enum DownloadExport {
    /// Creates (or refreshes) a copy of `source` under `fileName` in a temporary export folder and
    /// returns its URL. Uses a hard link when possible so no extra disk space is used.
    static func stage(source: URL, fileName: String) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(fileName)
        try? fm.removeItem(at: dest)
        do {
            try fm.linkItem(at: source, to: dest)
        } catch {
            try fm.copyItem(at: source, to: dest)
        }
        return dest
    }

    static func fileName(for entry: DownloadedVideo) -> String {
        FriendlyFileName.make(
            title: entry.title, videoId: entry.videoId, fileExtension: entry.isAudioOnly ? "m4a" : "mp4")
    }
}

/// What the share sheet exports. The friendly-named file is only created when the user actually
/// picks a destination.
struct DownloadExportItem: Transferable {
    let source: URL
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { item in
            SentTransferredFile(try DownloadExport.stage(source: item.source, fileName: item.fileName))
        }
    }
}
#endif
