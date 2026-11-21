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
    var polled = 0
    var createError: Error?
    init(_ states: [YtDlpJobState]) { self.states = states }
    func createJob(videoId: String) async throws -> YtDlpJobState {
        if let createError { throw createError }
        created.append(videoId)
        return states.removeFirst()
    }
    func jobState(videoId: String) async throws -> YtDlpJobState {
        polled += 1
        return states.isEmpty ? YtDlpJobState(status: "running") : states.removeFirst()
    }
    func health() async throws -> YtDlpHealth { YtDlpHealth(ok: true, ytdlpVersion: "x") }
}

private struct FakeAssembler: DownloadFetching {
    func resolve(video: Video) async throws -> DownloadPlan { throw DownloadFetchError(message: "unused") }
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
    func resolve(video: Video) async throws -> DownloadPlan {
        if fails { throw DownloadFetchError(message: "\(label) failed") }
        return DownloadPlan(parts: [.init(part: .muxed, url: URL(string: "https://\(label).test/x")!, userAgent: label)]
        )
    }
    func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(label)")
    }
}

private func router(
    mode: YtDlpMode, configured: Bool = true, nativeFails: Bool = false, serverFails: Bool = false
) -> ConfigurableDownloadFetcher {
    ConfigurableDownloadFetcher(
        native: StubFetcher(label: "native", fails: nativeFails),
        config: {
            YtDlpServerConfig(mode: mode, baseURL: configured ? base : nil, token: configured ? "tok" : nil)
        },
        makeServer: { _ in StubFetcher(label: "server", fails: serverFails) })
}

@Suite("ConfigurableDownloadFetcher")
struct ConfigurableDownloadFetcherTests {
    private func userAgent(_ f: ConfigurableDownloadFetcher) async throws -> String {
        try await f.resolve(video: video()).parts[0].userAgent
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
        let f = ConfigurableDownloadFetcher(
            native: CancellingFetcher(), config: { YtDlpServerConfig(mode: .fallback, baseURL: base, token: "t") },
            makeServer: { _ in StubFetcher(label: "server") })
        await #expect(throws: CancellationError.self) { try await f.resolve(video: video()) }
    }
}

private struct CancellingFetcher: DownloadFetching {
    func resolve(video: Video) async throws -> DownloadPlan { throw CancellationError() }
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
    func token() {
        let keychain = MemoryKeychain()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        YtDlpServerConfig.saveToken("  secret \n", keychain: keychain, defaults: defaults)
        #expect(YtDlpServerConfig.current(defaults: defaults, keychain: keychain).token == "secret")
        YtDlpServerConfig.saveToken("   ", keychain: keychain, defaults: defaults)
        #expect(YtDlpServerConfig.current(defaults: defaults, keychain: keychain).token == nil)
    }

    @Test("persisted settings feed the config")
    func persisted() throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        var s = AppSettings()
        s.ytDlpMode = .fallback
        s.ytDlpServerURL = base
        defaults.set(try JSONEncoder().encode(s), forKey: AppSettings.persistenceKey)
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
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (code, body) = Self.handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("URLSessionYtDlpServerClient", .serialized)
struct URLSessionYtDlpServerClientTests {
    private func client() -> URLSessionYtDlpServerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        return URLSessionYtDlpServerClient(baseURL: base, token: "tok", session: URLSession(configuration: config))
    }

    @Test("createJob POSTs the video id with the bearer token")
    func createJob() async throws {
        StubProtocol.handler = { _ in (202, #"{"status":"queued","progress":0}"#) }
        let state = try await client().createJob(videoId: "dQw4w9WgXcQ")
        #expect(state.status == "queued")
        let req = try #require(StubProtocol.seen.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/jobs")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("health sends no token")
    func healthNoToken() async throws {
        StubProtocol.handler = { _ in (200, #"{"ok":true,"ytdlpVersion":"2026.1"}"#) }
        let health = try await client().health()
        #expect(health.ytdlpVersion == "2026.1")
        #expect(StubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("HTTP errors map to readable messages")
    func errors() async {
        StubProtocol.handler = { _ in (401, "{}") }
        do {
            _ = try await client().jobState(videoId: "dQw4w9WgXcQ")
            Issue.record("expected an error")
        } catch { #expect(error.localizedDescription.contains("rejected the token")) }
        StubProtocol.handler = { _ in (500, "{}") }
        do {
            _ = try await client().jobState(videoId: "dQw4w9WgXcQ")
            Issue.record("expected an error")
        } catch { #expect(error.localizedDescription.contains("HTTP 500")) }
    }
}
