import Foundation
import Testing

@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

/// Answers `/v1/status` with a scripted result. Every other call is unused here.
private final class StatusFakeClient: YtDlpServerClient, @unchecked Sendable {
    let reply: Result<YtDlpServerStatus, Error>
    init(_ reply: Result<YtDlpServerStatus, Error>) { self.reply = reply }

    // swiftlint:disable:next async_without_await
    func status() async throws -> YtDlpServerStatus { try reply.get() }
    // swiftlint:disable:next async_without_await
    func me() async throws -> YtDlpMe { throw YtDlpServerError(message: "not used by these tests") }
    // swiftlint:disable:next async_without_await
    func createJob(_ request: YtDlpJobRequest) async throws -> YtDlpJobState {
        throw YtDlpServerError(message: "not used by these tests")
    }
    // swiftlint:disable:next async_without_await
    func jobState(videoId: String) async throws -> YtDlpJobState {
        throw YtDlpServerError(message: "not used by these tests")
    }
    // swiftlint:disable:next async_without_await
    func health() async throws -> YtDlpHealth { YtDlpHealth(ok: true, ytdlpVersion: nil) }
    // swiftlint:disable:next async_without_await
    func library(cursor: String?, limit: Int) async throws -> YtDlpLibraryPage {
        YtDlpLibraryPage(items: [], nextCursor: nil)
    }
    // swiftlint:disable:next async_without_await
    func setKeep(videoId: String, keep: Bool) async throws {}
    // swiftlint:disable:next async_without_await
    func deleteFromServer(videoId: String) async throws {}
}

private func sampleStatus(server: YtDlpServerStatus.ServerTotals? = nil) -> YtDlpServerStatus {
    YtDlpServerStatus(
        apiVersion: 5, ytdlpVersion: "2026.11.23", uptimeSeconds: 12345,
        disk: .init(freeBytes: 1, totalBytes: 2),
        you: .init(
            videoCount: 3, kept: .init(count: 1, bytes: 100), unkept: .init(count: 2, bytes: 200),
            capBytes: 21_474_836_480),
        jobs: .init(running: 0, queued: 0),
        recentFailures: [
            .init(videoId: "abcdefghijk", message: "Video unavailable", at: Date(timeIntervalSince1970: 0))
        ],
        server: server)
}

@Suite("NAS status state")
@MainActor
struct NASStatusViewModelTests {
    @Test("before the first reply the state is loading")
    func loading() {
        let vm = NASStatusViewModel(client: StatusFakeClient(.success(sampleStatus())))
        #expect(vm.state == .loading)
        #expect(vm.checkedAt == nil)
    }

    @Test("a user's reply loads the caller-scoped snapshot with no server block")
    func loadedUser() async {
        let vm = NASStatusViewModel(client: StatusFakeClient(.success(sampleStatus())))
        await vm.load()
        #expect(vm.state == .loaded(sampleStatus()))
        #expect(vm.checkedAt != nil)
        #expect(vm.roundTripMilliseconds != nil)
    }

    @Test("an admin's reply carries the server totals")
    func loadedAdmin() async {
        let totals = YtDlpServerStatus.ServerTotals(profiles: 3, totalFiles: 10, totalBytes: 999)
        let vm = NASStatusViewModel(client: StatusFakeClient(.success(sampleStatus(server: totals))))
        await vm.load()
        guard case .loaded(let status) = vm.state else {
            Issue.record("expected loaded, got \(vm.state)")
            return
        }
        #expect(status.server == totals)
    }

    @Test("no reply from the server is reported as unreachable with its reason")
    func unreachable() async {
        let client = StatusFakeClient(.failure(YtDlpServerError(message: "offline", status: nil)))
        let vm = NASStatusViewModel(client: client)
        await vm.load()
        #expect(vm.state == .unreachable("offline"))
        #expect(vm.roundTripMilliseconds == nil)
    }

    @Test("a 404 means the server predates /v1/status")
    func serverTooOld() async {
        let client = StatusFakeClient(.failure(YtDlpServerError(message: "no route", status: 404)))
        let vm = NASStatusViewModel(client: client)
        await vm.load()
        #expect(vm.state == .serverTooOld)
    }

    @Test("a 401 means the token is revoked or wrong")
    func rejected() async {
        let client = StatusFakeClient(.failure(YtDlpServerError(message: "rejected", status: 401)))
        let vm = NASStatusViewModel(client: client)
        await vm.load()
        #expect(vm.state == .rejected)
    }

    @Test("refresh replaces a loaded snapshot with the newest reply")
    func refreshReplaces() async {
        let vm = NASStatusViewModel(client: StatusFakeClient(.success(sampleStatus())))
        await vm.load()
        let newer = StatusFakeClient(.failure(YtDlpServerError(message: "offline", status: nil)))
        let refreshed = NASStatusViewModel(client: newer)
        await refreshed.refresh()
        #expect(refreshed.state == .unreachable("offline"))
    }

    @Test("the status reply decodes from the documented JSON")
    func decodesContract() throws {
        let json = """
            {"apiVersion":5,"ytdlpVersion":"2026.11.23","uptimeSeconds":12345,"disk":{"freeBytes":1,"totalBytes":2},\
            "you":{"videoCount":3,"kept":{"count":1,"bytes":100},"unkept":{"count":2,"bytes":200},"capBytes":21474836480},\
            "jobs":{"running":0,"queued":0},"recentFailures":[{"videoId":"abcdefghijk","message":"Video unavailable",\
            "at":"2026-11-27T10:00:00Z"}],"server":{"profiles":3,"totalFiles":10,"totalBytes":999}}
            """
        let status = try JSONDecoder().decode(YtDlpServerStatus.self, from: Data(json.utf8))
        #expect(status.apiVersion == 5)
        #expect(status.you.capBytes == 21_474_836_480)
        #expect(status.recentFailures.first?.videoId == "abcdefghijk")
        #expect(status.server?.totalFiles == 10)
    }
}
