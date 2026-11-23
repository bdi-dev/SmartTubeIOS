import Foundation
import SmartTubeIOSCore
import os

private let ytDlpLog = Logger(subsystem: appSubsystem, category: "YtDlpServer")

// MARK: - Client seam

/// State of a job on the companion server (see tools/ytdlp-server/README.md).
public struct YtDlpJobState: Decodable, Sendable, Equatable {
    public let status: String
    public let progress: Double?
    public let error: String?
    public let fileSize: Int64?

    public init(status: String, progress: Double? = nil, error: String? = nil, fileSize: Int64? = nil) {
        self.status = status
        self.progress = progress
        self.error = error
        self.fileSize = fileSize
    }
}

public struct YtDlpHealth: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let ytdlpVersion: String?
    /// Reported by server API version 2 and later. Absent on older servers, so it is optional.
    public let apiVersion: Int?

    public init(ok: Bool, ytdlpVersion: String?, apiVersion: Int? = nil) {
        self.ok = ok
        self.ytdlpVersion = ytdlpVersion
        self.apiVersion = apiVersion
    }
}

/// One finished download on the server, as listed by `GET /v1/library`.
public struct YtDlpLibraryItem: Decodable, Sendable, Equatable {
    public let videoId: String
    public let title: String
    public let channelTitle: String
    public let duration: Double?
    public let thumbnailURL: String?
    public let keep: Bool
    public let downloadedAt: Date
    public let fileSize: Int64?

    public init(
        videoId: String, title: String, channelTitle: String, duration: Double?, thumbnailURL: String?,
        keep: Bool, downloadedAt: Date, fileSize: Int64?
    ) {
        self.videoId = videoId
        self.title = title
        self.channelTitle = channelTitle
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.keep = keep
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
    }

    private enum CodingKeys: String, CodingKey {
        case videoId, title, channelTitle, duration, thumbnailURL, keep, downloadedAt, fileSize
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try container.decode(String.self, forKey: .videoId)
        title = try container.decode(String.self, forKey: .title)
        channelTitle = try container.decode(String.self, forKey: .channelTitle)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL)
        keep = try container.decode(Bool.self, forKey: .keep)
        // The server writes `%Y-%m-%dT%H:%M:%SZ`, which ISO8601DateFormatter's default options read.
        let stamp = try container.decode(String.self, forKey: .downloadedAt)
        guard let date = ISO8601DateFormatter().date(from: stamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .downloadedAt, in: container, debugDescription: "Unreadable date \(stamp)")
        }
        downloadedAt = date
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
    }
}

/// One page of `GET /v1/library`. `nextCursor` is nil on the last page.
public struct YtDlpLibraryPage: Decodable, Sendable, Equatable {
    public let items: [YtDlpLibraryItem]
    public let nextCursor: String?

    public init(items: [YtDlpLibraryItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// The body of `POST /v1/jobs`. Metadata is sent only when present. `keep` is sent only when set,
/// because the server defaults to `true`. Values the server would reject (over-long text, a
/// non-https thumbnail, a negative duration) are dropped or clipped here, so a job never fails
/// with a 400 over its metadata.
public struct YtDlpJobRequest: Sendable, Equatable {
    public let videoId: String
    public let title: String?
    public let channelTitle: String?
    public let duration: Double?
    public let thumbnailURL: String?
    public let keep: Bool?

    public init(
        videoId: String, title: String? = nil, channelTitle: String? = nil, duration: Double? = nil,
        thumbnailURL: String? = nil, keep: Bool? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.channelTitle = channelTitle
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.keep = keep
    }

    /// Builds the request for a video. Empty metadata (such as the placeholder title used when only
    /// streaming) is omitted rather than sent as an empty string.
    public init(video: Video, keep: Bool? = nil) {
        self.init(
            videoId: video.id,
            title: Self.clip(video.title, max: 300),
            channelTitle: Self.clip(video.channelTitle, max: 200),
            duration: video.duration.flatMap { $0 >= 0 && $0.isFinite ? $0 : nil },
            thumbnailURL: video.thumbnailURL.flatMap {
                $0.scheme == "https" && $0.absoluteString.count <= 500 ? $0.absoluteString : nil
            },
            keep: keep)
    }

    private static func clip(_ text: String, max: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(max))
    }

    /// The JSON object for the request. Absent optionals are left out, not sent as null.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["videoId": videoId]
        if let title { object["title"] = title }
        if let channelTitle { object["channelTitle"] = channelTitle }
        if let duration { object["duration"] = duration }
        if let thumbnailURL { object["thumbnailURL"] = thumbnailURL }
        if let keep { object["keep"] = keep }
        return object
    }
}

/// The calls the app makes to the companion server. Tests supply a fake.
public protocol YtDlpServerClient: Sendable {
    func createJob(_ request: YtDlpJobRequest) async throws -> YtDlpJobState
    func jobState(videoId: String) async throws -> YtDlpJobState
    func health() async throws -> YtDlpHealth
    func library(cursor: String?, limit: Int) async throws -> YtDlpLibraryPage
    func setKeep(videoId: String, keep: Bool) async throws
    func deleteFromServer(videoId: String) async throws
}

struct YtDlpServerError: LocalizedError {
    let message: String
    /// The HTTP status, or nil when the server never replied (offline, timeout). Lets callers tell
    /// a 401 from a 404 from a timeout.
    let status: Int?

    init(message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }

    var errorDescription: String? { message }
}

/// `URLSession`-backed client. The token is sent as a bearer header on every call except `health`.
public struct URLSessionYtDlpServerClient: YtDlpServerClient {
    public let baseURL: URL
    public let token: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(baseURL: URL, token: String, session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        // A pasted token often carries a trailing space or newline, which the server rejects.
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.timeout = timeout
    }

    private static let defaultNotFound = "The yt-dlp server does not know this video"
    private static let missingFile = "The yt-dlp server does not have this file"

    private func request(
        _ path: String, query: [(name: String, value: String)] = [], method: String = "GET",
        authorised: Bool = true
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        let prefix = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = prefix + path
        if !query.isEmpty {
            // Encode everything outside the alphanumerics so "+", "/" and "=" in a base64 cursor
            // reach the server intact (a raw "+" would be read back as a space).
            components.percentEncodedQuery = query.map { item in
                "\(item.name)=\(item.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            }.joined(separator: "&")
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if authorised { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Sends the request and returns the body of a 2xx reply. Maps failures to status-carrying errors.
    private func perform(_ req: URLRequest, notFound: String) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw YtDlpServerError(message: "Could not reach the yt-dlp server: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return data
        case 401:
            throw YtDlpServerError(message: "The yt-dlp server rejected the token", status: status)
        case 404:
            throw YtDlpServerError(message: notFound, status: status)
        default:
            throw YtDlpServerError(message: "The yt-dlp server returned HTTP \(status)", status: status)
        }
    }

    private func send<T: Decodable>(
        _ req: URLRequest, as: T.Type, notFound: String = defaultNotFound
    ) async throws -> T {
        let data = try await perform(req, notFound: notFound)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw YtDlpServerError(message: "The yt-dlp server sent an unexpected reply", status: nil)
        }
    }

    public func createJob(_ job: YtDlpJobRequest) async throws -> YtDlpJobState {
        var req = try request("v1/jobs", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: job.jsonObject)
        return try await send(req, as: YtDlpJobState.self)
    }

    public func jobState(videoId: String) async throws -> YtDlpJobState {
        try await send(try request("v1/jobs/\(videoId)"), as: YtDlpJobState.self)
    }

    public func health() async throws -> YtDlpHealth {
        try await send(try request("v1/health", authorised: false), as: YtDlpHealth.self)
    }

    public func library(cursor: String?, limit: Int) async throws -> YtDlpLibraryPage {
        var query: [(name: String, value: String)] = []
        if let cursor { query.append((name: "cursor", value: cursor)) }
        query.append((name: "limit", value: String(limit)))
        return try await send(
            try request("v1/library", query: query), as: YtDlpLibraryPage.self,
            notFound: "The yt-dlp server has no library endpoint (update the server)")
    }

    public func setKeep(videoId: String, keep: Bool) async throws {
        var req = try request("v1/files/\(videoId)/keep", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["keep": keep])
        _ = try await perform(req, notFound: Self.missingFile)
    }

    public func deleteFromServer(videoId: String) async throws {
        _ = try await perform(try request("v1/files/\(videoId)", method: "DELETE"), notFound: Self.missingFile)
    }
}

extension Video {
    /// The video for a NAS library item, so the item can be downloaded to the device.
    public init(libraryItem item: YtDlpLibraryItem) {
        self.init(
            id: item.videoId, title: item.title, channelTitle: item.channelTitle,
            thumbnailURL: item.thumbnailURL.flatMap(URL.init(string:)), duration: item.duration)
    }
}

// MARK: - YtDlpServerFetcher

/// Resolves a download by asking the companion server to fetch the video, waiting until it is
/// ready, and returning a one-part plan that points at the finished file on the server. The bytes
/// then travel through the normal background session; assembly reuses the native fetcher.
public final class YtDlpServerFetcher: DownloadFetching {
    public static let pollInterval: TimeInterval = 2
    /// Give up waiting for the server after this long (a very long video can take a while).
    public static let maxWait: TimeInterval = 30 * 60

    private let client: any YtDlpServerClient
    private let baseURL: URL
    private let token: String
    private let assembler: any DownloadFetching
    private let pollInterval: TimeInterval
    private let maxPolls: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Sent as `keep` on job creation. nil leaves it out, so the server keeps the file (its default).
    private let keep: Bool?

    public init(
        client: any YtDlpServerClient, baseURL: URL, token: String, assembler: any DownloadFetching,
        keep: Bool? = nil,
        pollInterval: TimeInterval = YtDlpServerFetcher.pollInterval,
        maxWait: TimeInterval = YtDlpServerFetcher.maxWait,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.token = token
        self.assembler = assembler
        self.keep = keep
        self.pollInterval = pollInterval
        self.maxPolls = max(1, Int(maxWait / max(pollInterval, 0.001)))
        self.sleep = sleep
    }

    public func resolve(video: Video) async throws -> DownloadPlan {
        let id = video.id
        var state = try await client.createJob(YtDlpJobRequest(video: video, keep: keep))
        var polls = 0
        while true {
            try Task.checkCancellation()
            switch state.status {
            case "ready":
                return plan(for: id)
            case "failed":
                throw DownloadFetchError(message: state.error ?? "The yt-dlp server could not fetch this video")
            default:
                polls += 1
                if polls > maxPolls {
                    throw DownloadFetchError(message: "The yt-dlp server took too long to prepare this video")
                }
                try await sleep(pollInterval)
                state = try await client.jobState(videoId: id)
            }
        }
    }

    private func plan(for videoId: String) -> DownloadPlan {
        let url = baseURL.appendingPathComponent("v1/files/\(videoId).mp4")
        ytDlpLog.notice("server file ready for \(videoId, privacy: .public)")
        return DownloadPlan(parts: [
            .init(part: .muxed, url: url, userAgent: "SmartTube", headers: ["Authorization": "Bearer \(token)"])
        ])
    }

    public func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
        try await assembler.assemble(videoId: videoId, stagedParts: stagedParts)
    }

    public func assemble(videoId: String, stagedParts: [DownloadPart: URL], audioOnly: Bool) async throws -> URL {
        try await assembler.assemble(videoId: videoId, stagedParts: stagedParts, audioOnly: audioOnly)
    }
}

// MARK: - Streaming from the server

/// Asks the companion server for a video and returns a stream the player can open directly (the
/// finished file on the server, with the bearer token). Used by "Play from yt-dlp Server" and as
/// the last resort when no plain stream is available. The server fetches and merges the video
/// itself, so this is the route to full quality for videos the app cannot decrypt.
public enum YtDlpServerStream {
    /// Waits for the server to finish the job, which can take a while for long videos.
    public static func resolve(
        videoId: String, config: YtDlpServerConfig,
        client: (any YtDlpServerClient)? = nil,
        pollInterval: TimeInterval = YtDlpServerFetcher.pollInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> Video.DirectStream {
        guard let baseURL = config.baseURL, let token = config.token, !token.isEmpty else {
            throw DownloadFetchError(message: "The yt-dlp server is not set up")
        }
        // Streaming is a one-off view, not a download, so the server keeps nothing from it (keep: false).
        let fetcher = YtDlpServerFetcher(
            client: client ?? URLSessionYtDlpServerClient(baseURL: baseURL, token: token),
            baseURL: baseURL, token: token, assembler: UnsupportedAssembler(), keep: false,
            pollInterval: pollInterval, sleep: sleep)
        let plan = try await fetcher.resolve(video: Video(id: videoId, title: "", channelTitle: ""))
        guard let part = plan.parts.first else {
            throw DownloadFetchError(message: "The yt-dlp server returned no file")
        }
        return Video.DirectStream(
            url: part.url, userAgent: part.userAgent, qualityLabel: "yt-dlp", headers: part.headers)
    }

    /// Never assembles: streaming plays the server's finished file as is.
    private struct UnsupportedAssembler: DownloadFetching {
        func resolve(video: Video) async throws -> DownloadPlan {
            throw DownloadFetchError(message: "Not supported")
        }
        func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
            throw DownloadFetchError(message: "Not supported")
        }
    }
}

// MARK: - ConfigurableDownloadFetcher

/// Chooses, per download, between the app's own extractor and the companion server according to
/// the current settings (`YtDlpMode`). With the default `.off` it behaves exactly like the native
/// fetcher. Read at call time, so changing the setting needs no restart.
public final class ConfigurableDownloadFetcher: DownloadFetching {
    private let native: any DownloadFetching
    private let config: @Sendable () -> YtDlpServerConfig
    private let makeServer: @Sendable (YtDlpServerConfig) -> any DownloadFetching
    private let makeProbe: @Sendable (YtDlpServerConfig) throws -> any YtDlpServerClient

    /// How long the fallback check waits for the server before extracting natively.
    public static let probeTimeout: TimeInterval = 5

    public init(
        native: any DownloadFetching,
        config: @escaping @Sendable () -> YtDlpServerConfig = { YtDlpServerConfig.current() },
        makeServer: (@Sendable (YtDlpServerConfig) -> any DownloadFetching)? = nil,
        makeProbe: (@Sendable (YtDlpServerConfig) throws -> any YtDlpServerClient)? = nil
    ) {
        self.native = native
        self.config = config
        self.makeServer =
            makeServer ?? { cfg in
                YtDlpServerFetcher(
                    client: URLSessionYtDlpServerClient(baseURL: cfg.baseURL!, token: cfg.token!),
                    baseURL: cfg.baseURL!, token: cfg.token!, assembler: native)
            }
        self.makeProbe =
            makeProbe ?? { (cfg: YtDlpServerConfig) throws -> any YtDlpServerClient in
                guard let baseURL = cfg.baseURL, let token = cfg.token else {
                    throw DownloadFetchError(message: "The yt-dlp server is not set up (Settings > Downloads)")
                }
                return URLSessionYtDlpServerClient(
                    baseURL: baseURL, token: token, timeout: ConfigurableDownloadFetcher.probeTimeout)
            }
    }

    /// Asks whether the server already holds a finished file for this video. Uses `jobState`, never
    /// `createJob` (which would start a run). Every failure, including a 404 and a timeout, means
    /// "not there", so the native extractor runs as before. A 401 is logged. Only cancellation escapes.
    private func serverHasReadyFile(videoId: String, _ cfg: YtDlpServerConfig) async throws -> Bool {
        do {
            return try await makeProbe(cfg).jobState(videoId: videoId).status == "ready"
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let serverError = error as? YtDlpServerError, serverError.status == 401 {
                ytDlpLog.notice("yt-dlp server rejected the token during the NAS check; extracting natively")
            } else {
                ytDlpLog.debug("yt-dlp server has no ready file for \(videoId, privacy: .public); extracting natively")
            }
            return false
        }
    }

    public func resolve(video: Video) async throws -> DownloadPlan {
        try await resolve(video: video, audioOnly: false)
    }

    public func resolve(video: Video, audioOnly: Bool, forceServer: Bool) async throws -> DownloadPlan {
        guard forceServer else { return try await resolve(video: video, audioOnly: audioOnly) }
        // The NAS list download: the file is known to be on the server, so skip the mode and the check.
        let cfg = config()
        guard cfg.isConfigured else {
            throw DownloadFetchError(message: "The yt-dlp server is not set up (Settings > Downloads)")
        }
        return try await makeServer(cfg).resolve(video: video, audioOnly: audioOnly)
    }

    public func resolve(video: Video, audioOnly: Bool) async throws -> DownloadPlan {
        let cfg = config()
        switch cfg.mode {
        case .off:
            return try await native.resolve(video: video, audioOnly: audioOnly)
        case .always:
            guard cfg.isConfigured else {
                throw DownloadFetchError(message: "The yt-dlp server is not set up (Settings > Downloads)")
            }
            return try await makeServer(cfg).resolve(video: video, audioOnly: audioOnly)
        case .fallback:
            // Server first when it is set up. Audio-only is skipped: the server returns a full MP4.
            if cfg.isConfigured, !audioOnly, try await serverHasReadyFile(videoId: video.id, cfg) {
                return try await makeServer(cfg).resolve(video: video, audioOnly: audioOnly)
            }
            do {
                return try await native.resolve(video: video, audioOnly: audioOnly)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard cfg.isConfigured else { throw error }
                ytDlpLog.notice(
                    "native extractor failed, trying the yt-dlp server: \(error.localizedDescription, privacy: .public)"
                )
                return try await makeServer(cfg).resolve(video: video, audioOnly: audioOnly)
            }
        }
    }

    // Both routes finish with the same passthrough remux, so assembly is always native.
    public func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
        try await native.assemble(videoId: videoId, stagedParts: stagedParts)
    }

    public func assemble(videoId: String, stagedParts: [DownloadPart: URL], audioOnly: Bool) async throws -> URL {
        try await native.assemble(videoId: videoId, stagedParts: stagedParts, audioOnly: audioOnly)
    }
}
