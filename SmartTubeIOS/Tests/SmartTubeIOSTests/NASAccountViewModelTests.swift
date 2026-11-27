import Foundation
import Testing

@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

/// Answers `/v1/me` with a scripted result. Every other call is unused here.
private final class AccountFakeClient: YtDlpServerClient, @unchecked Sendable {
    let reply: Result<YtDlpMe, Error>
    init(_ reply: Result<YtDlpMe, Error>) { self.reply = reply }

    // swiftlint:disable:next async_without_await
    func me() async throws -> YtDlpMe { try reply.get() }
    // swiftlint:disable:next async_without_await
    func status() async throws -> YtDlpServerStatus {
        throw YtDlpServerError(message: "not used by these tests")
    }
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

@Suite("NAS account state")
@MainActor
struct NASAccountViewModelTests {
    @Test("a valid token shows the name and role")
    func signedIn() async {
        let client = AccountFakeClient(.success(YtDlpMe(id: "u1", name: "Sam", role: .user)))
        let vm = NASAccountViewModel()
        await vm.load(client: client)
        #expect(vm.state == .signedIn(name: "Sam", role: .user))
    }

    @Test("an admin token reports the admin role")
    func adminRole() async {
        let client = AccountFakeClient(.success(YtDlpMe(id: "admin", name: "Ian", role: .admin)))
        let vm = NASAccountViewModel()
        await vm.load(client: client)
        #expect(vm.state == .signedIn(name: "Ian", role: .admin))
    }

    @Test("a 401 means the token is revoked or wrong")
    func rejected() async {
        let client = AccountFakeClient(.failure(YtDlpServerError(message: "rejected", status: 401)))
        let vm = NASAccountViewModel()
        await vm.load(client: client)
        #expect(vm.state == .rejected)
    }

    @Test("a 404 means an older server without /v1/me, which hides the row")
    func unsupported() async {
        let client = AccountFakeClient(.failure(YtDlpServerError(message: "no route", status: 404)))
        let vm = NASAccountViewModel()
        await vm.load(client: client)
        #expect(vm.state == .unsupported)
    }

    @Test("no reply from the server is reported as unreachable")
    func unreachable() async {
        let client = AccountFakeClient(.failure(YtDlpServerError(message: "offline", status: nil)))
        let vm = NASAccountViewModel()
        await vm.load(client: client)
        #expect(vm.state == .unreachable)
    }

    @Test("with no client (no URL or token) the state is idle")
    func noClient() async {
        let vm = NASAccountViewModel()
        await vm.load(client: nil)
        #expect(vm.state == .idle)
    }
}
