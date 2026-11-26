import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

private func video(_ id: String = "dQw4w9WgXcQ") -> Video {
    Video(id: id, title: "T", channelTitle: "C", thumbnailURL: nil, duration: 60)
}

private final class FakeClient: YtDlpServerClient, @unchecked Sendable {
    var states: [YtDlpJobState]
    var created: [String] = []
    var requests: [YtDlpJobRequest] = []
    var polled = 0
    var createError: Error?
    init(_ states: [YtDlpJobState]) { self.states = states }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func createJob(_ request: YtDlpJobRequest) async throws -> YtDlpJobState {
        if let createError { throw createError }
        created.append(request.videoId)
        requests.append(request)
        return states.removeFirst()
    }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func jobState(videoId: String) async throws -> YtDlpJobState {
        polled += 1
        return states.isEmpty ? YtDlpJobState(status: "running") : states.removeFirst()
    }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func health() async throws -> YtDlpHealth { YtDlpHealth(ok: true, ytdlpVersion: "x") }
    // swiftlint:disable:next async_without_await
    func library(cursor: String?, limit: Int) async throws -> YtDlpLibraryPage {
        YtDlpLibraryPage(items: [], nextCursor: nil)
    }
    // swiftlint:disable:next async_without_await
    func setKeep(videoId: String, keep: Bool) async throws {}
    // swiftlint:disable:next async_without_await
    func deleteFromServer(videoId: String) async throws {}
    // swiftlint:disable:next async_without_await
    func me() async throws -> YtDlpMe { throw YtDlpServerError(message: "not used by these tests") }
}

private struct FakeAssembler: DownloadFetching {
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func resolve(video: Video) async throws -> DownloadPlan { throw DownloadFetchError(message: "unused") }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
        URL(fileURLWithPath: "/tmp/assembled-\(videoId)")
    }
}

private let base = URL(string: "https://server.example:8787")!

private func fetcher(_ client: FakeClient, maxWait: TimeInterval = 60) -> YtDlpServerFetcher {
    YtDlpServerFetcher(
        client: client, baseURL: base, token: "tok", assembler: FakeAssembler(), pollInterval: 1,
        maxWait: maxWait, sleep: { _ in })
}

@Suite("YtDlpServerFetcher")
struct YtDlpServerFetcherTests {
    @Test("polls until ready, then returns a one-part plan with the bearer header")
    func readyAfterPolling() async throws {
        let client = FakeClient([
            .init(status: "queued"), .init(status: "running"), .init(status: "ready", fileSize: 10),
        ])
        let plan = try await fetcher(client).resolve(video: video())
        #expect(client.created == ["dQw4w9WgXcQ"])
        #expect(client.polled == 2)
        let part = try #require(plan.parts.first)
        #expect(plan.parts.count == 1)
        #expect(part.part == .muxed)
        #expect(part.url.absoluteString == "https://server.example:8787/v1/files/dQw4w9WgXcQ.mp4")
        #expect(part.headers == ["Authorization": "Bearer tok"])
    }

    @Test("an already-ready job needs no polling")
    func immediatelyReady() async throws {
        let client = FakeClient([.init(status: "ready")])
        _ = try await fetcher(client).resolve(video: video())
        #expect(client.polled == 0)
    }

    @Test("a failed job surfaces the server's message")
    func failedJob() async {
        let client = FakeClient([.init(status: "running"), .init(status: "failed", error: "Video unavailable")])
        await #expect(throws: DownloadFetchError.self) { try await fetcher(client).resolve(video: video()) }
        let message = await Task { () -> String in
            do {
                _ = try await fetcher(FakeClient([.init(status: "failed", error: "Video unavailable")])).resolve(
                    video: video())
                return ""
            } catch { return error.localizedDescription }
        }.value
        #expect(message == "Video unavailable")
    }

    @Test("gives up after maxWait")
    func timesOut() async {
        let client = FakeClient([.init(status: "running")])
        do {
            _ = try await fetcher(client, maxWait: 3).resolve(video: video())
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription.contains("too long"))
        }
        #expect(client.polled == 3)
    }

    @Test("client errors propagate and cancellation is honoured")
    func errorsAndCancellation() async {
        let client = FakeClient([])
        client.createError = YtDlpServerError(message: "The yt-dlp server rejected the token")
        await #expect(throws: YtDlpServerError.self) { try await fetcher(client).resolve(video: video()) }

        let task = Task { try await fetcher(FakeClient([.init(status: "running")])).resolve(video: video()) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("assembly is delegated to the native assembler")
    func assemblyDelegates() async throws {
        let url = try await fetcher(FakeClient([])).assemble(videoId: "abc", stagedParts: [:])
        #expect(url.lastPathComponent == "assembled-abc")
    }
}

// MARK: - Routing

private struct StubFetcher: DownloadFetching {
    let label: String
    var fails: Bool = false
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func resolve(video: Video) async throws -> DownloadPlan {
        if fails { throw DownloadFetchError(message: "\(label) failed") }
        guard let url = URL(string: "https://\(label).test/x") else {
            throw DownloadFetchError(message: "invalid test URL")
        }
        return DownloadPlan(parts: [.init(part: .muxed, url: url, userAgent: label)])
    }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(label)")
    }
}

/// Stands in for the fallback check. Replies with a scripted `jobState` result and counts the calls.
/// It fails on `createJob`, because the check must never start a job.
private final class ProbeClient: YtDlpServerClient, @unchecked Sendable {
    let reply: Result<YtDlpJobState, YtDlpServerError>
    var jobStateCalls = 0
    init(_ reply: Result<YtDlpJobState, YtDlpServerError> = .failure(YtDlpServerError(message: "nf", status: 404))) {
        self.reply = reply
    }
    // swiftlint:disable:next async_without_await
    func createJob(_ request: YtDlpJobRequest) async throws -> YtDlpJobState {
        throw YtDlpServerError(message: "the check must not create a job")
    }
    // swiftlint:disable:next async_without_await
    func jobState(videoId: String) async throws -> YtDlpJobState {
        jobStateCalls += 1
        return try reply.get()
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
    // swiftlint:disable:next async_without_await
    func me() async throws -> YtDlpMe { throw YtDlpServerError(message: "not used by these tests") }
}

private func router(
    mode: YtDlpMode, configured: Bool = true, nativeFails: Bool = false, serverFails: Bool = false,
    probe: ProbeClient = ProbeClient()
) -> ConfigurableDownloadFetcher {
    ConfigurableDownloadFetcher(
        native: StubFetcher(label: "native", fails: nativeFails),
        config: {
            YtDlpServerConfig(mode: mode, baseURL: configured ? base : nil, token: configured ? "tok" : nil)
        },
        makeServer: { _ in StubFetcher(label: "server", fails: serverFails) },
        makeProbe: { _ in probe })
}

@Suite("ConfigurableDownloadFetcher")
struct ConfigurableDownloadFetcherTests {
    private func userAgent(_ downloader: ConfigurableDownloadFetcher, audioOnly: Bool = false) async throws -> String {
        try await downloader.resolve(video: video(), audioOnly: audioOnly).parts[0].userAgent
    }

    @Test("off always uses the native extractor, even when the server is configured")
    func off() async throws {
        #expect(try await userAgent(router(mode: .off)) == "native")
    }

    @Test("always uses the server, and errors clearly when it is not set up")
    func always() async throws {
        #expect(try await userAgent(router(mode: .always)) == "server")
        await #expect(throws: DownloadFetchError.self) {
            try await router(mode: .always, configured: false).resolve(video: video())
        }
    }

    @Test("the default unconfigured server fetcher throws the not-set-up message")
    func unconfiguredServerFetcher() {
        do {
            _ = try UnconfiguredServerFetcher().resolve(video: video())
            Issue.record("expected resolve to throw")
        } catch let error as DownloadFetchError {
            #expect(error.message == "The yt-dlp server is not set up (Settings > Downloads)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("fallback uses native first, the server only when native fails")
    func fallback() async throws {
        #expect(try await userAgent(router(mode: .fallback)) == "native")
        #expect(try await userAgent(router(mode: .fallback, nativeFails: true)) == "server")
    }

    @Test("fallback with no server configured reports the native error")
    func fallbackUnconfigured() async {
        do {
            _ = try await router(mode: .fallback, configured: false, nativeFails: true).resolve(video: video())
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "native failed")
        }
    }

    @Test("fallback reports the server error when both fail")
    func bothFail() async {
        do {
            _ = try await router(mode: .fallback, nativeFails: true, serverFails: true).resolve(video: video())
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "server failed")
        }
    }

    @Test("fallback does not swallow cancellation")
    func fallbackCancellation() async {
        let downloader = ConfigurableDownloadFetcher(
            native: CancellingFetcher(), config: { YtDlpServerConfig(mode: .fallback, baseURL: base, token: "t") },
            makeServer: { _ in StubFetcher(label: "server") }, makeProbe: { _ in ProbeClient() })
        await #expect(throws: CancellationError.self) { try await downloader.resolve(video: video()) }
    }

    @Test("fallback uses the server when it already has the file, without extracting")
    func fallbackProbeReady() async throws {
        let probe = ProbeClient(.success(YtDlpJobState(status: "ready")))
        #expect(try await userAgent(router(mode: .fallback, probe: probe)) == "server")
        #expect(probe.jobStateCalls == 1)
    }

    @Test("fallback extracts natively when the server has no file (404)")
    func fallbackProbeNotFound() async throws {
        let probe = ProbeClient(.failure(YtDlpServerError(message: "nf", status: 404)))
        #expect(try await userAgent(router(mode: .fallback, probe: probe)) == "native")
        #expect(probe.jobStateCalls == 1)
    }

    @Test("fallback extracts natively when the check times out")
    func fallbackProbeTimeout() async throws {
        let probe = ProbeClient(.failure(YtDlpServerError(message: "Could not reach the yt-dlp server", status: nil)))
        #expect(try await userAgent(router(mode: .fallback, probe: probe)) == "native")
    }

    @Test("fallback extracts natively when the token is rejected (401)")
    func fallbackProbeUnauthorised() async throws {
        let probe = ProbeClient(.failure(YtDlpServerError(message: "rejected the token", status: 401)))
        #expect(try await userAgent(router(mode: .fallback, probe: probe)) == "native")
    }

    @Test("fallback does not check the server when it is not configured")
    func fallbackProbeUnconfigured() async throws {
        let probe = ProbeClient(.success(YtDlpJobState(status: "ready")))
        #expect(try await userAgent(router(mode: .fallback, configured: false, probe: probe)) == "native")
        #expect(probe.jobStateCalls == 0)
    }

    @Test("fallback skips the check for audio-only downloads")
    func fallbackProbeAudioOnly() async throws {
        let probe = ProbeClient(.success(YtDlpJobState(status: "ready")))
        #expect(try await userAgent(router(mode: .fallback, probe: probe), audioOnly: true) == "native")
        #expect(probe.jobStateCalls == 0)
    }

    @Test("off never contacts the server")
    func offNeverProbes() async throws {
        let probe = ProbeClient(.success(YtDlpJobState(status: "ready")))
        #expect(try await userAgent(router(mode: .off, probe: probe)) == "native")
        #expect(probe.jobStateCalls == 0)
    }

    @Test("always does not run the check before using the server")
    func alwaysNeverProbes() async throws {
        let probe = ProbeClient(.success(YtDlpJobState(status: "ready")))
        #expect(try await userAgent(router(mode: .always, probe: probe)) == "server")
        #expect(probe.jobStateCalls == 0)
    }

    private func forcedUserAgent(_ downloader: ConfigurableDownloadFetcher) async throws -> String {
        try await downloader.resolve(video: video(), audioOnly: false, forceServer: true).parts[0].userAgent
    }

    @Test("forceServer uses the server even when the mode is off")
    func forceServerWithModeOff() async throws {
        #expect(try await forcedUserAgent(router(mode: .off)) == "server")
    }

    @Test("forceServer with no server configured fails with the not-set-up message")
    func forceServerUnconfigured() async {
        do {
            _ = try await forcedUserAgent(router(mode: .off, configured: false))
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("not set up"))
        }
    }

    @Test("a NAS library item becomes a Video with its metadata")
    func videoFromLibraryItem() throws {
        let item = YtDlpLibraryItem(
            videoId: "dQw4w9WgXcQ", title: "T", channelTitle: "C", duration: 61.5,
            thumbnailURL: "https://i.example/x.jpg", keep: true,
            downloadedAt: Date(timeIntervalSince1970: 0), fileSize: 1)
        let video = Video(libraryItem: item)
        #expect(video.id == "dQw4w9WgXcQ")
        #expect(video.title == "T")
        #expect(video.channelTitle == "C")
        #expect(video.duration == 61.5)
        #expect(video.thumbnailURL == URL(string: "https://i.example/x.jpg"))
    }
}

private struct CancellingFetcher: DownloadFetching {
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func resolve(video: Video) async throws -> DownloadPlan { throw CancellationError() }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL { URL(fileURLWithPath: "/x") }
}

// MARK: - Config, plan headers, HTTP client

private final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func get(service: String, key: String) -> String? { values["\(service)/\(key)"] }
    func set(service: String, key: String, value: String?) { values["\(service)/\(key)"] = value }
    func delete(service: String, key: String) { values["\(service)/\(key)"] = nil }
}

@Suite("YtDlpServerConfig and plan headers")
struct YtDlpConfigTests {
    @Test("isConfigured needs both a URL and a token; isEnabled also needs a non-off mode")
    func flags() {
        #expect(!YtDlpServerConfig(mode: .always, baseURL: base, token: nil).isConfigured)
        #expect(!YtDlpServerConfig(mode: .always, baseURL: base, token: "").isConfigured)
        #expect(!YtDlpServerConfig(mode: .always, baseURL: nil, token: "t").isConfigured)
        #expect(YtDlpServerConfig(mode: .off, baseURL: base, token: "t").isConfigured)
        #expect(!YtDlpServerConfig(mode: .off, baseURL: base, token: "t").isEnabled)
        #expect(YtDlpServerConfig(mode: .fallback, baseURL: base, token: "t").isEnabled)
    }

    @Test("the token round-trips through the keychain; blank clears it")
    func token() throws {
        let keychain = MemoryKeychain()
        let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        YtDlpServerConfig.saveToken("  secret \n", keychain: keychain, defaults: defaults)
        #expect(YtDlpServerConfig.current(defaults: defaults, keychain: keychain).token == "secret")
        YtDlpServerConfig.saveToken("   ", keychain: keychain, defaults: defaults)
        #expect(YtDlpServerConfig.current(defaults: defaults, keychain: keychain).token == nil)
    }

    @Test("persisted settings feed the config")
    func persisted() throws {
        let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        var settings = AppSettings()
        settings.ytDlpMode = .fallback
        settings.ytDlpServerURL = base
        defaults.set(try JSONEncoder().encode(settings), forKey: AppSettings.persistenceKey)
        let cfg = YtDlpServerConfig.current(defaults: defaults, keychain: MemoryKeychain())
        #expect(cfg.mode == .fallback)
        #expect(cfg.baseURL == base)
    }

    @Test("settings default to off and old settings JSON decodes")
    func defaults() throws {
        #expect(AppSettings().ytDlpMode == .off)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.ytDlpMode == .off)
        #expect(old.ytDlpServerURL == nil)
    }

    @Test("a plan part written before headers existed decodes with none")
    func tolerantPartDecode() throws {
        let json = #"{"part":"muxed","url":"https://x.test/a","userAgent":"UA"}"#
        let part = try JSONDecoder().decode(DownloadPlan.Part.self, from: Data(json.utf8))
        #expect(part.headers.isEmpty)
        let round = try JSONDecoder().decode(
            DownloadPlan.Part.self,
            from: JSONEncoder().encode(DownloadPlan.Part(part: .muxed, url: base, userAgent: "U", headers: ["A": "B"])))
        #expect(round.headers == ["A": "B"])
    }

    @Test("credential headers are never persisted and are dropped from old records")
    func credentialsNotPersisted() throws {
        let part = DownloadPlan.Part(
            part: .muxed, url: base, userAgent: "U", headers: ["Authorization": "Bearer secret", "X-Keep": "1"])
        #expect(part.headers["Authorization"] == "Bearer secret")  // in-memory request still has it
        let data = try JSONEncoder().encode(part)
        #expect(String(bytes: data, encoding: .utf8)?.contains("secret") == false)
        let round = try JSONDecoder().decode(DownloadPlan.Part.self, from: data)
        #expect(round.headers == ["X-Keep": "1"])
        let legacy =
            #"{"part":"muxed","url":"https://x.test/a","userAgent":"UA","headers":{"authorization":"Bearer old"}}"#
        #expect(try JSONDecoder().decode(DownloadPlan.Part.self, from: Data(legacy.utf8)).headers.isEmpty)
    }
}

@Suite("YtDlpServerStream")
struct YtDlpServerStreamTests {
    @Test("returns the server file with the bearer header once the job is ready")
    func streamsServerFile() async throws {
        let client = FakeClient([.init(status: "queued"), .init(status: "ready", fileSize: 10)])
        let config = YtDlpServerConfig(mode: .fallback, baseURL: base, token: "tok")
        let stream = try await YtDlpServerStream.resolve(
            videoId: "dQw4w9WgXcQ", config: config, client: client, pollInterval: 1, sleep: { _ in })
        #expect(stream.url == base.appendingPathComponent("v1/files/dQw4w9WgXcQ.mp4"))
        #expect(stream.headers["Authorization"] == "Bearer tok")
        #expect(client.created == ["dQw4w9WgXcQ"])
    }

    @Test("a failed job and a missing token both throw")
    func failures() async {
        let failing = FakeClient([.init(status: "failed", error: "boom")])
        let config = YtDlpServerConfig(mode: .always, baseURL: base, token: "tok")
        await #expect(throws: DownloadFetchError.self) {
            try await YtDlpServerStream.resolve(
                videoId: "dQw4w9WgXcQ", config: config, client: failing, pollInterval: 1, sleep: { _ in })
        }
        let noToken = YtDlpServerConfig(mode: .always, baseURL: base, token: nil)
        await #expect(throws: DownloadFetchError.self) {
            try await YtDlpServerStream.resolve(videoId: "dQw4w9WgXcQ", config: noToken)
        }
    }
}

@Suite("YtDlpLibrary decoding")
struct YtDlpLibraryDecodingTests {
    @Test("decodes a library page with a cursor")
    func page() throws {
        let json = """
            {"items":[{"videoId":"dQw4w9WgXcQ","title":"T","channelTitle":"C","duration":61.5,
            "thumbnailURL":"https://i.example/x.jpg","keep":true,"downloadedAt":"2026-11-23T10:00:00Z",
            "fileSize":1024}],"nextCursor":"YWJj"}
            """
        let page = try JSONDecoder().decode(YtDlpLibraryPage.self, from: Data(json.utf8))
        #expect(page.nextCursor == "YWJj")
        let item = try #require(page.items.first)
        #expect(item.videoId == "dQw4w9WgXcQ")
        #expect(item.keep)
        #expect(item.duration == 61.5)
        #expect(item.fileSize == 1024)
        #expect(item.downloadedAt == ISO8601DateFormatter().date(from: "2026-11-23T10:00:00Z"))
    }

    @Test("a null cursor decodes to nil on the last page")
    func nullCursor() throws {
        let page = try JSONDecoder().decode(YtDlpLibraryPage.self, from: Data(#"{"items":[],"nextCursor":null}"#.utf8))
        #expect(page.nextCursor == nil)
        #expect(page.items.isEmpty)
    }

    @Test("a health reply without apiVersion still decodes")
    func healthWithoutApiVersion() throws {
        let old = try JSONDecoder().decode(YtDlpHealth.self, from: Data(#"{"ok":true,"ytdlpVersion":"1"}"#.utf8))
        #expect(old.apiVersion == nil)
        let new = try JSONDecoder().decode(
            YtDlpHealth.self, from: Data(#"{"ok":true,"ytdlpVersion":"1","apiVersion":2}"#.utf8))
        #expect(new.apiVersion == 2)
    }
}

@Suite("URLSessionYtDlpServerClient token")
struct YtDlpServerClientTokenTests {
    @Test("a pasted token with surrounding whitespace is trimmed")
    func trimsToken() {
        let client = URLSessionYtDlpServerClient(baseURL: base, token: "  abc123\n")
        #expect(client.token == "abc123")
    }
}

@Suite("Job metadata and keep on the wire")
struct YtDlpJobMetadataTests {
    @Test("a download sends metadata and no keep; the fetcher passes keep through as nil")
    func downloadFetcherSendsMetadata() async throws {
        let client = FakeClient([.init(status: "ready")])
        let video = Video(
            id: "dQw4w9WgXcQ", title: "Title", channelTitle: "Channel",
            thumbnailURL: URL(string: "https://i.example/x.jpg"), duration: 60)
        _ = try await fetcher(client).resolve(video: video)
        let request = try #require(client.requests.first)
        #expect(request.title == "Title")
        #expect(request.channelTitle == "Channel")
        #expect(request.duration == 60)
        #expect(request.thumbnailURL == "https://i.example/x.jpg")
        #expect(request.keep == nil)
    }

    @Test("streaming sends keep: false and omits the placeholder empty title")
    func streamSendsKeepFalse() async throws {
        let client = FakeClient([.init(status: "ready")])
        let config = YtDlpServerConfig(mode: .fallback, baseURL: base, token: "tok")
        _ = try await YtDlpServerStream.resolve(
            videoId: "dQw4w9WgXcQ", config: config, client: client, pollInterval: 1, sleep: { _ in })
        let request = try #require(client.requests.first)
        #expect(request.keep == false)
        #expect(request.title == nil)
        #expect(request.channelTitle == nil)
    }

    @Test("over-long text is clipped and values the server rejects are dropped")
    func clipsAndDrops() {
        let video = Video(
            id: "dQw4w9WgXcQ", title: String(repeating: "t", count: 400), channelTitle: "  ",
            thumbnailURL: URL(string: "http://i.example/x.jpg"), duration: -1)
        let request = YtDlpJobRequest(video: video)
        #expect(request.title?.count == 300)
        #expect(request.channelTitle == nil)
        #expect(request.thumbnailURL == nil)
        #expect(request.duration == nil)
    }
}
