import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

// MARK: - DownloadStore tests
//
// Covers the destinationURL guarantee introduced in task #224:
//   - Percent-encoding produces a bijective mapping (no two distinct videoIds
//     can produce the same filename).
//   - Standard YouTube 11-char IDs pass through unchanged (no encoding needed).
// and the status / relative-path / reconcile behaviour of the personal downloads library.

private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DownloadStoreTests-\(UUID().uuidString)", isDirectory: true)
}

private func makeEntry(
    _ id: String, status: DownloadedVideo.Status = .queued, fileName: String? = nil
) -> DownloadedVideo {
    DownloadedVideo(
        videoId: id, title: "T", channelTitle: "C", thumbnailURL: nil, duration: 10,
        fileName: fileName ?? "\(id).mp4", downloadedAt: Date(timeIntervalSince1970: 1000),
        status: status)
}

@Suite("DownloadStore – destinationURL")
@MainActor
struct DownloadStoreDestinationURLTests {

    @Test("Standard YouTube IDs are unchanged after percent-encoding")
    func standardYouTubeIdUnchanged() {
        let store = DownloadStore(directory: makeTempDirectory())
        let url = store.destinationURL(for: "dQw4w9WgXcQ")
        #expect(url.lastPathComponent.hasSuffix(".mp4"))
        #expect(url.lastPathComponent.contains("dQw4w9WgXcQ"))
    }

    @Test("Two distinct IDs never produce the same destination URL")
    func distinctIDsProduceDistinctURLs() {
        let store = DownloadStore(directory: makeTempDirectory())
        let url1 = store.destinationURL(for: "abc123")
        let url2 = store.destinationURL(for: "abc-123")
        #expect(url1 != url2, "Distinct video IDs must map to distinct file URLs")
    }

    @Test("destinationURL is deterministic for the same videoId")
    func deterministicURL() {
        let store = DownloadStore(directory: makeTempDirectory())
        #expect(store.destinationURL(for: "testVideo123") == store.destinationURL(for: "testVideo123"))
    }
}

@Suite("DownloadStore – status, paths and reconcile")
@MainActor
struct DownloadStoreLifecycleTests {

    @Test("Old manifest with absolute fileURL and no status decodes as complete")
    func oldManifestDecode() throws {
        let json = """
            [{"videoId":"abc","title":"T","channelTitle":"C","duration":42,
              "fileURL":"file:///old/container/SmartTubeDownloads/abc.mp4",
              "downloadedAt":0}]
            """
        let decoded = try JSONDecoder().decode([DownloadedVideo].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].fileName == "abc.mp4")
        #expect(decoded[0].status == .complete)
    }

    @Test("Old manifest on disk loads and resolves against the current directory")
    func oldManifestResolvesAgainstCurrentDirectory() throws {
        let dir = makeTempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("abc.mp4"))
        let json = """
            [{"videoId":"abc","title":"T","channelTitle":"C","duration":42,
              "fileURL":"file:///gone/abc.mp4","downloadedAt":0}]
            """
        try Data(json.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        let store = DownloadStore(directory: dir)
        let entry = try #require(store.entry(for: "abc"))
        #expect(entry.status == .complete)
        #expect(store.video(for: entry)?.localFileURL == dir.appendingPathComponent("abc.mp4"))
    }

    @Test("finalize marks complete only after the file exists")
    func finalizeCompletesAfterMove() throws {
        let dir = makeTempDirectory()
        let store = DownloadStore(directory: dir)
        let name = store.fileName(for: "vid1")
        store.upsert(makeEntry("vid1", status: .merging, fileName: name))
        #expect(store.entry(for: "vid1")?.status == .merging)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: temp)
        #expect(store.finalize(videoId: "vid1", from: temp))

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(store.entry(for: "vid1")?.status == .complete)
        #expect(store.video(for: try #require(store.entry(for: "vid1")))?.localFileURL != nil)
    }

    @Test("finalize with a missing temp file fails and never marks complete")
    func finalizeFailureDoesNotComplete() {
        let dir = makeTempDirectory()
        let store = DownloadStore(directory: dir)
        store.upsert(makeEntry("vid2", status: .merging))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).mp4")
        #expect(!store.finalize(videoId: "vid2", from: missing))
        #expect(store.entry(for: "vid2")?.status == .failed)
        #expect(store.video(for: store.entry(for: "vid2")!) == nil)
    }

    @Test("reconcile marks a complete entry with a missing file as failed")
    func reconcileMissingFile() throws {
        let dir = makeTempDirectory()
        let first = DownloadStore(directory: dir)
        first.upsert(makeEntry("gone", status: .complete))
        let second = DownloadStore(directory: dir)
        #expect(second.entry(for: "gone")?.status == .failed)
    }

    @Test("reconcile fails interrupted downloads and deletes stray .partial files")
    func reconcileInterruptedAndPartial() throws {
        let dir = makeTempDirectory()
        let first = DownloadStore(directory: dir)
        first.upsert(makeEntry("busy", status: .downloading))
        let partial = dir.appendingPathComponent("busy.partial")
        try Data("p".utf8).write(to: partial)
        #expect(FileManager.default.fileExists(atPath: partial.path))

        let second = DownloadStore(directory: dir)
        #expect(second.entry(for: "busy")?.status == .failed)
        #expect(second.entry(for: "busy")?.errorMessage == "Interrupted")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
}
