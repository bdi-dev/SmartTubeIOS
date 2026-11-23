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
    func createJob(_ request: YtDlpJobRequest) async throws -> YtDlpJobState {
        if let createError { throw createError }
        created.append(request.videoId)
        requests.append(request)
        return states.removeFirst()
    }
    func jobState(videoId: String) async throws -> YtDlpJobState {
        polled += 1
        return states.isEmpty ? YtDlpJobState(status: "running") : states.removeFirst()
    }
    func health() async throws -> YtDlpHealth { YtDlpHealth(ok: true, ytdlpVersion: "x") }
    func library(cursor: String?, limit: Int) async throws -> YtDlpLibraryPage {
        YtDlpLibraryPage(items: [], nextCursor: nil)
    }
    func setKeep(videoId: String, keep: Bool) async throws {}
    func deleteFromServer(videoId: String) async throws {}
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

/// Stands in for the fallback check. Replies with a scripted `jobState` result and counts the calls.
/// It fails on `createJob`, because the check must never start a job.
private final class ProbeClient: YtDlpServerClient, @unchecked Sendable {
    let reply: Result<YtDlpJobState, YtDlpServerError>
    var jobStateCalls = 0
    init(_ reply: Result<YtDlpJobState, YtDlpServerError> = .failure(YtDlpServerError(message: "nf", status: 404))) {
        self.reply = reply
    }
    func createJob(_ request: YtDlpJobRequest) async throws -> YtDlpJobState {
        throw YtDlpServerError(message: "the check must not create a job")
    }
    func jobState(videoId: String) async throws -> YtDlpJobState {
        jobStateCalls += 1
        return try reply.get()
    }
    func health() async throws -> YtDlpHealth { YtDlpHealth(ok: true, ytdlpVersion: nil) }
    func library(cursor: String?, limit: Int) async throws -> YtDlpLibraryPage {
        YtDlpLibraryPage(items: [], nextCursor: nil)
    }
    func setKeep(videoId: String, keep: Bool) async throws {}
    func deleteFromServer(videoId: String) async throws {}
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
    private func userAgent(_ f: ConfigurableDownloadFetcher, audioOnly: Bool = false) async throws -> String {
        try await f.resolve(video: video(), audioOnly: audioOnly).parts[0].userAgent
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
            makeServer: { _ in StubFetcher(label: "server") }, makeProbe: { _ in ProbeClient() })
        await #expect(throws: CancellationError.self) { try await f.resolve(video: video()) }
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

    private func forcedUserAgent(_ f: ConfigurableDownloadFetcher) async throws -> String {
        try await f.resolve(video: video(), audioOnly: false, forceServer: true).parts[0].userAgent
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
    nonisolated(unsafe) static var seenBodies: [Data?] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        Self.seenBodies.append(Self.bodyData(of: request))
        let (code, body) = Self.handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// URLSession hands the body to a protocol as a stream, not as `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("URLSessionYtDlpServerClient", .serialized)
struct URLSessionYtDlpServerClientTests {
    private func client() -> URLSessionYtDlpServerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        StubProtocol.seenBodies = []
        return URLSessionYtDlpServerClient(baseURL: base, token: "tok", session: URLSession(configuration: config))
    }

    @Test("createJob POSTs the video id with the bearer token")
    func createJob() async throws {
        StubProtocol.handler = { _ in (202, #"{"status":"queued","progress":0}"#) }
        let state = try await client().createJob(YtDlpJobRequest(videoId: "dQw4w9WgXcQ"))
        #expect(state.status == "queued")
        let req = try #require(StubProtocol.seen.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/jobs")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    private func postedJSON() throws -> [String: Any] {
        let body = try #require(StubProtocol.seenBodies.first ?? nil)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("a download's createJob sends the metadata and leaves keep out")
    func createJobSendsMetadata() async throws {
        StubProtocol.handler = { _ in (202, #"{"status":"queued"}"#) }
        let video = Video(
            id: "dQw4w9WgXcQ", title: "Title", channelTitle: "Channel",
            thumbnailURL: URL(string: "https://i.example/x.jpg"), duration: 61.5)
        _ = try await client().createJob(YtDlpJobRequest(video: video))
        let json = try postedJSON()
        #expect(json["videoId"] as? String == "dQw4w9WgXcQ")
        #expect(json["title"] as? String == "Title")
        #expect(json["channelTitle"] as? String == "Channel")
        #expect(json["duration"] as? Double == 61.5)
        #expect(json["thumbnailURL"] as? String == "https://i.example/x.jpg")
        #expect(json["keep"] == nil)
    }

    @Test("streaming's createJob sends keep: false")
    func createJobKeepFalse() async throws {
        StubProtocol.handler = { _ in (202, #"{"status":"queued"}"#) }
        _ = try await client().createJob(YtDlpJobRequest(videoId: "dQw4w9WgXcQ", keep: false))
        let json = try postedJSON()
        #expect(json["keep"] as? Bool == false)
        #expect(json["title"] == nil)
    }

    @Test("health sends no token")
    func healthNoToken() async throws {
        StubProtocol.handler = { _ in (200, #"{"ok":true,"ytdlpVersion":"2026.1"}"#) }
        let health = try await client().health()
        #expect(health.ytdlpVersion == "2026.1")
        #expect(StubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    private func queryString(of request: URLRequest) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    }

    @Test("library sends the cursor percent-encoded and the limit, as a GET")
    func libraryQuery() async throws {
        StubProtocol.handler = { _ in (200, #"{"items":[],"nextCursor":null}"#) }
        _ = try await client().library(cursor: "ab+/=", limit: 50)
        let req = try #require(StubProtocol.seen.first)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/v1/library")
        #expect(queryString(of: req) == "cursor=ab%2B%2F%3D&limit=50")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("library without a cursor omits it")
    func libraryFirstPage() async throws {
        StubProtocol.handler = { _ in (200, #"{"items":[],"nextCursor":null}"#) }
        _ = try await client().library(cursor: nil, limit: 20)
        #expect(StubProtocol.seen.first.flatMap(queryString(of:)) == "limit=20")
    }

    @Test("setKeep PUTs the flag to the keep route")
    func setKeepRequest() async throws {
        StubProtocol.handler = { _ in (200, #"{"ok":true,"keep":false}"#) }
        try await client().setKeep(videoId: "dQw4w9WgXcQ", keep: false)
        let req = try #require(StubProtocol.seen.first)
        #expect(req.httpMethod == "PUT")
        #expect(req.url?.path == "/v1/files/dQw4w9WgXcQ/keep")
        let body = try #require(StubProtocol.seenBodies.first ?? nil)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        #expect(json == ["keep": false])
    }

    @Test("deleteFromServer DELETEs the file route")
    func deleteRequest() async throws {
        StubProtocol.handler = { _ in (200, #"{"deleted":true}"#) }
        try await client().deleteFromServer(videoId: "dQw4w9WgXcQ")
        let req = try #require(StubProtocol.seen.first)
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.path == "/v1/files/dQw4w9WgXcQ")
    }

    @Test("401 and 404 carry their status and are distinguishable")
    func statusCarried() async {
        StubProtocol.handler = { _ in (401, "{}") }
        do {
            _ = try await client().library(cursor: nil, limit: 5)
            Issue.record("expected an error")
        } catch let error as YtDlpServerError {
            #expect(error.status == 401)
        } catch { Issue.record("wrong error \(error)") }

        StubProtocol.handler = { _ in (404, "{}") }
        do {
            try await client().deleteFromServer(videoId: "dQw4w9WgXcQ")
            Issue.record("expected an error")
        } catch let error as YtDlpServerError {
            #expect(error.status == 404)
            #expect(!error.message.contains("does not know"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test("the request timeout is injectable")
    func injectableTimeout() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        StubProtocol.seenBodies = []
        StubProtocol.handler = { _ in (200, #"{"ok":true}"#) }
        let fast = URLSessionYtDlpServerClient(
            baseURL: base, token: "tok", session: URLSession(configuration: config), timeout: 5)
        _ = try await fast.health()
        #expect(StubProtocol.seen.first?.timeoutInterval == 5)
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
