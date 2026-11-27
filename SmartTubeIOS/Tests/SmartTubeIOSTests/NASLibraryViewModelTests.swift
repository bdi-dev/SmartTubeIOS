import Foundation
import Testing

@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

/// Scripted stand-in for the yt-dlp server. Pages are served in order; failures are set per test.
private final class NASFakeClient: YtDlpServerClient, @unchecked Sendable {
    var healthResult: Result<YtDlpHealth, Error> = .success(YtDlpHealth(ok: true, ytdlpVersion: "x", apiVersion: 2))
    var pages: [YtDlpLibraryPage]
    var libraryFailure: Error?
    var setKeepFailure: Error?
    var deleteFailure: Error?
    private(set) var healthCalls = 0
    private(set) var cursors: [String?] = []
    private(set) var keepCalls: [(videoId: String, keep: Bool)] = []
    private(set) var deletedIds: [String] = []

    init(pages: [YtDlpLibraryPage] = []) { self.pages = pages }

    func health() throws -> YtDlpHealth {
        healthCalls += 1
        return try healthResult.get()
    }

    func library(cursor: String?, limit: Int) throws -> YtDlpLibraryPage {
        cursors.append(cursor)
        if let libraryFailure { throw libraryFailure }
        return pages.isEmpty ? YtDlpLibraryPage(items: [], nextCursor: nil) : pages.removeFirst()
    }

    func setKeep(videoId: String, keep: Bool) throws {
        keepCalls.append((videoId: videoId, keep: keep))
        if let setKeepFailure { throw setKeepFailure }
    }

    func deleteFromServer(videoId: String) throws {
        if let deleteFailure { throw deleteFailure }
        deletedIds.append(videoId)
    }

    func me() throws -> YtDlpMe {
        throw YtDlpServerError(message: "not used by these tests")
    }

    func createJob(_ request: YtDlpJobRequest) throws -> YtDlpJobState {
        throw YtDlpServerError(message: "not used by these tests")
    }

    func jobState(videoId: String) throws -> YtDlpJobState {
        throw YtDlpServerError(message: "not used by these tests")
    }
}

private func item(_ id: String, keep: Bool = false) -> YtDlpLibraryItem {
    YtDlpLibraryItem(
        videoId: id, title: "Title \(id)", channelTitle: "Channel", duration: 60, thumbnailURL: nil,
        keep: keep, downloadedAt: Date(timeIntervalSince1970: 0), fileSize: 1_000)
}

/// `count` rows with ids `prefix0` ... `prefix<count-1>`.
private func items(_ prefix: String, _ count: Int) -> [YtDlpLibraryItem] {
    (0..<count).map { item("\(prefix)\($0)") }
}

/// A store holding the given local downloads (a fresh directory each time).
@MainActor
private func makeStore(_ entries: [(String, DownloadedVideo.Status)] = []) -> DownloadStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NASLibraryTests-\(UUID().uuidString)", isDirectory: true)
    let store = DownloadStore(directory: directory)
    for (videoId, status) in entries {
        store.upsert(
            DownloadedVideo(
                videoId: videoId, title: videoId, channelTitle: "Channel", thumbnailURL: nil, duration: 60,
                fileName: "\(videoId).mp4", downloadedAt: Date(), status: status))
    }
    return store
}

@MainActor
@Suite("NASLibraryViewModel paging")
struct NASLibraryViewModelPagingTests {
    @Test("the first page loads on appear and opens the section")
    func firstPageLoads() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: items("p", 20), nextCursor: "c1")])
        let vm = NASLibraryViewModel(client: client, store: makeStore())

        await vm.appear()

        #expect(vm.gate == .visible)
        #expect(vm.items.count == 20)
        #expect(client.cursors == [nil])
    }

    @Test("a further page appends only when the last row appears")
    func secondPageAppends() async {
        let client = NASFakeClient(pages: [
            YtDlpLibraryPage(items: items("p", 20), nextCursor: "c1"),
            YtDlpLibraryPage(items: [item("q0")], nextCursor: nil),
        ])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        await vm.loadMoreIfNeeded(after: "p3")
        #expect(client.cursors == [nil])

        await vm.loadMoreIfNeeded(after: "p19")
        #expect(client.cursors == [nil, "c1"])
        #expect(vm.items.last?.videoId == "q0")
        #expect(vm.nextCursor == nil)
    }

    @Test("a page made only of rows already on this device loads the next page")
    func allLocalPageLoadsNext() async {
        let client = NASFakeClient(pages: [
            YtDlpLibraryPage(items: items("p", 20), nextCursor: "c1"),
            YtDlpLibraryPage(items: [item("q0")], nextCursor: nil),
        ])
        let store = makeStore(items("p", 20).map { ($0.videoId, DownloadedVideo.Status.complete) })
        let vm = NASLibraryViewModel(client: client, store: store)

        await vm.appear()

        #expect(client.cursors == [nil, "c1"])
        #expect(vm.available.map(\.videoId) == ["q0"])
    }

    @Test(
        "a row downloading or downloaded here leaves the list",
        arguments: [DownloadedVideo.Status.queued, .downloading, .merging, .complete])
    func localActiveStatusHidesRow(status: DownloadedVideo.Status) async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0"), item("p1")], nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore([("p0", status)]))

        await vm.appear()

        #expect(vm.available.map(\.videoId) == ["p1"])
    }

    @Test("a failed local download does not hide the NAS row")
    func failedLocalDoesNotHide() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0"), item("p1")], nextCursor: nil)])
        let vm = NASLibraryViewModel(
            client: client, store: makeStore([("p0", .failed)]))

        await vm.appear()

        #expect(vm.available.map(\.videoId) == ["p0", "p1"])
    }

    @Test("an API version below 2 or missing keeps the section hidden", arguments: [1, nil] as [Int?])
    func oldServerHidden(apiVersion: Int?) async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        client.healthResult = .success(YtDlpHealth(ok: true, ytdlpVersion: "x", apiVersion: apiVersion))
        let vm = NASLibraryViewModel(client: client, store: makeStore())

        await vm.appear()

        #expect(vm.gate == .hidden)
        #expect(client.cursors.isEmpty)
    }

    @Test("an unreachable server keeps the section hidden")
    func unreachableHidden() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        client.healthResult = .failure(YtDlpServerError(message: "offline", status: nil))
        let vm = NASLibraryViewModel(client: client, store: makeStore())

        await vm.appear()

        #expect(vm.gate == .hidden)
        #expect(client.cursors.isEmpty)
    }

    @Test("no configured server keeps the section hidden")
    func unconfiguredHidden() async {
        let vm = NASLibraryViewModel(client: nil, store: makeStore())

        await vm.appear()

        #expect(vm.gate == .hidden)
        #expect(vm.items.isEmpty)
    }

    @Test("the gate is checked once while the screen is open")
    func gateCachedWhileOpen() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: items("p", 20), nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())

        await vm.appear()
        await vm.appear()

        #expect(client.healthCalls == 1)
    }

    @Test("a failed page after a successful load keeps the rows and sets a message")
    func failureAfterLoadKeepsRows() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: items("p", 20), nextCursor: "c1")])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        client.libraryFailure = YtDlpServerError(message: "offline", status: nil)
        await vm.loadMoreIfNeeded(after: "p19")

        #expect(vm.items.count == 20)
        #expect(vm.message == "NAS unreachable")
    }
}

@MainActor
@Suite("NASLibraryViewModel actions")
struct NASLibraryViewModelActionTests {
    @Test("keep toggles the row once the server confirms")
    func keepToggles() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        await vm.setKeep(videoId: "p0", keep: true)

        #expect(client.keepCalls.map(\.keep) == [true])
        #expect(vm.items.first?.keep == true)
        #expect(vm.message == nil)
    }

    @Test("a failed keep leaves the row as it was and sets a message")
    func keepRollsBackOnFailure() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        client.setKeepFailure = YtDlpServerError(message: "The yt-dlp server returned HTTP 500", status: 500)
        await vm.setKeep(videoId: "p0", keep: true)

        #expect(vm.items.first?.keep == false)
        #expect(vm.message == "The yt-dlp server returned HTTP 500")
    }

    @Test("delete removes the row once the server confirms")
    func deleteRemovesRow() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0"), item("p1")], nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        await vm.deleteFromNAS(videoId: "p0")

        #expect(client.deletedIds == ["p0"])
        #expect(vm.items.map(\.videoId) == ["p1"])
    }

    @Test("a delete that fails keeps the row and sets a message")
    func deleteFailureKeepsRow() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        client.deleteFailure = YtDlpServerError(message: "offline", status: nil)
        await vm.deleteFromNAS(videoId: "p0")

        #expect(vm.items.map(\.videoId) == ["p0"])
        #expect(vm.message == "NAS unreachable")
    }

    @Test("a 409 on delete keeps the row and says the server is still downloading")
    func deleteWhileRunningKeepsRow() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        client.deleteFailure = YtDlpServerError(message: "conflict", status: 409)
        await vm.deleteFromNAS(videoId: "p0")

        #expect(vm.items.map(\.videoId) == ["p0"])
        #expect(vm.message == "Still downloading on the NAS")
    }
}

@MainActor
@Suite("NASLibraryViewModel offline and refresh")
struct NASLibraryViewModelRefreshTests {
    @Test("a server that is unreachable before any load keeps the section hidden")
    func unreachableBeforeLoadStaysHidden() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        client.libraryFailure = YtDlpServerError(message: "offline", status: nil)
        let vm = NASLibraryViewModel(client: client, store: makeStore())

        await vm.appear()

        #expect(vm.gate == .hidden)
        #expect(vm.items.isEmpty)
    }

    @Test("refresh reloads page 1 and replaces the rows")
    func refreshReloadsFirstPage() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: items("p", 20), nextCursor: "c1")])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        client.pages = [YtDlpLibraryPage(items: [item("q0")], nextCursor: nil)]
        await vm.refresh()

        #expect(client.cursors == [nil, nil])
        #expect(vm.items.map(\.videoId) == ["q0"])
        #expect(vm.nextCursor == nil)
    }

    @Test("a failed refresh after a load keeps the rows and sets the message")
    func failedRefreshKeepsRows() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: items("p", 3), nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        client.libraryFailure = YtDlpServerError(message: "offline", status: nil)
        await vm.refresh()

        #expect(vm.items.count == 3)
        #expect(vm.message == "NAS unreachable")
        #expect(vm.gate == .visible)
    }

    @Test("a rejected token shows the revoked message and no rows, and keeps the section visible")
    func unauthorizedShowsMessage() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: items("p", 3), nextCursor: nil)])
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()
        #expect(vm.items.count == 3)

        client.libraryFailure = YtDlpServerError(message: "rejected", status: 401)
        await vm.refresh()

        #expect(vm.items.isEmpty)
        #expect(vm.message == "Token revoked or wrong")
        #expect(vm.gate == .visible)
    }

    @Test("a rejected token before the first load still shows the message, not a hidden section")
    func unauthorizedBeforeFirstLoad() async {
        let client = NASFakeClient()
        client.libraryFailure = YtDlpServerError(message: "rejected", status: 401)
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()

        #expect(vm.items.isEmpty)
        #expect(vm.message == "Token revoked or wrong")
        #expect(vm.gate == .visible)
    }

    @Test("refresh checks the gate again when the section was hidden")
    func refreshRechecksHiddenGate() async {
        let client = NASFakeClient(pages: [YtDlpLibraryPage(items: [item("p0")], nextCursor: nil)])
        client.healthResult = .failure(YtDlpServerError(message: "offline", status: nil))
        let vm = NASLibraryViewModel(client: client, store: makeStore())
        await vm.appear()
        #expect(vm.gate == .hidden)

        client.healthResult = .success(YtDlpHealth(ok: true, ytdlpVersion: "x", apiVersion: 2))
        await vm.refresh()

        #expect(vm.gate == .visible)
        #expect(vm.items.map(\.videoId) == ["p0"])
    }
}
