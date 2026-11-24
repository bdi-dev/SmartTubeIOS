import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

private let base = URL(string: "https://server.example:8787")!

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var seenBodies: [Data?] = []
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        Self.seenBodies.append(Self.bodyData(of: request))
        let (code, body) = Self.handler?(request) ?? (500, "")
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)
        else {
            Issue.record("StubProtocol needs a request URL and a valid HTTP response")
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
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
