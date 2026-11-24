import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("DownloadStorage")
@MainActor
struct DownloadStorageTests {

    private func makeStore() throws -> (DownloadStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DownloadStore(directory: dir), dir)
    }

    private func entry(_ id: String, status: DownloadedVideo.Status) -> DownloadedVideo {
        DownloadedVideo(
            videoId: id, title: "T", channelTitle: "C", thumbnailURL: nil, duration: 1,
            fileName: "\(id).mp4", downloadedAt: Date(timeIntervalSince1970: 1), status: status)
    }

    @Test("totalBytes sums only complete entries that exist on disk")
    func totalBytesSumsCompleteFiles() throws {
        let (store, dir) = try makeStore()
        try Data(count: 1000).write(to: dir.appendingPathComponent("a.mp4"))
        try Data(count: 500).write(to: dir.appendingPathComponent("b.mp4"))
        try Data(count: 9999).write(to: dir.appendingPathComponent("c.mp4"))  // not complete → ignored
        store.upsert(entry("a", status: .complete))
        store.upsert(entry("b", status: .complete))
        store.upsert(entry("c", status: .downloading))
        store.upsert(entry("missing", status: .complete))  // reconcile may fail it; either way 0 bytes
        #expect(store.totalBytes() == 1500)
    }

    @Test("an empty library is 0 bytes")
    func emptyLibraryIsZero() throws {
        let (store, _) = try makeStore()
        #expect(store.totalBytes() == 0)
    }

    @Test("availableBytes reports free space for an existing directory")
    func availableBytesIsPositive() throws {
        let (_, dir) = try makeStore()
        let free = DownloadStore.availableBytes(at: dir)
        #expect((free ?? 0) > 0)
    }

    @Test("formatByteCount produces a human-readable string")
    func formatsBytes() {
        #expect(formatByteCount(2_600_000_000).contains("GB"))
        #expect(formatByteCount(10_000_000).contains("MB"))
    }
}
