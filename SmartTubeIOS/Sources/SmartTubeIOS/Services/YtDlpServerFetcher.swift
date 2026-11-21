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
}

/// The calls the app makes to the companion server. Tests supply a fake.
public protocol YtDlpServerClient: Sendable {
    func createJob(videoId: String) async throws -> YtDlpJobState
    func jobState(videoId: String) async throws -> YtDlpJobState
    func health() async throws -> YtDlpHealth
}

struct YtDlpServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// `URLSession`-backed client. The token is sent as a bearer header on every call except `health`.
public struct URLSessionYtDlpServerClient: YtDlpServerClient {
    public let baseURL: URL
    public let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    private func request(_ path: String, method: String = "GET", authorised: Bool = true) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 30
        if authorised { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw YtDlpServerError(message: "Could not reach the yt-dlp server: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw YtDlpServerError(message: "The yt-dlp server sent an unexpected reply")
            }
        case 401:
            throw YtDlpServerError(message: "The yt-dlp server rejected the token")
        case 404:
            throw YtDlpServerError(message: "The yt-dlp server does not know this video")
        default:
            throw YtDlpServerError(message: "The yt-dlp server returned HTTP \(status)")
        }
    }

    public func createJob(videoId: String) async throws -> YtDlpJobState {
        var req = request("v1/jobs", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["videoId": videoId])
        return try await send(req, as: YtDlpJobState.self)
    }

    public func jobState(videoId: String) async throws -> YtDlpJobState {
        try await send(request("v1/jobs/\(videoId)"), as: YtDlpJobState.self)
    }

    public func health() async throws -> YtDlpHealth {
        try await send(request("v1/health", authorised: false), as: YtDlpHealth.self)
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

    public init(
        client: any YtDlpServerClient, baseURL: URL, token: String, assembler: any DownloadFetching,
        pollInterval: TimeInterval = YtDlpServerFetcher.pollInterval,
        maxWait: TimeInterval = YtDlpServerFetcher.maxWait,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.token = token
        self.assembler = assembler
        self.pollInterval = pollInterval
        self.maxPolls = max(1, Int(maxWait / max(pollInterval, 0.001)))
        self.sleep = sleep
    }

    public func resolve(video: Video) async throws -> DownloadPlan {
        let id = video.id
        var state = try await client.createJob(videoId: id)
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

// MARK: - ConfigurableDownloadFetcher

/// Chooses, per download, between the app's own extractor and the companion server according to
/// the current settings (`YtDlpMode`). With the default `.off` it behaves exactly like the native
/// fetcher. Read at call time, so changing the setting needs no restart.
public final class ConfigurableDownloadFetcher: DownloadFetching {
    private let native: any DownloadFetching
    private let config: @Sendable () -> YtDlpServerConfig
    private let makeServer: @Sendable (YtDlpServerConfig) -> any DownloadFetching

    public init(
        native: any DownloadFetching,
        config: @escaping @Sendable () -> YtDlpServerConfig = { YtDlpServerConfig.current() },
        makeServer: (@Sendable (YtDlpServerConfig) -> any DownloadFetching)? = nil
    ) {
        self.native = native
        self.config = config
        self.makeServer =
            makeServer ?? { cfg in
                YtDlpServerFetcher(
                    client: URLSessionYtDlpServerClient(baseURL: cfg.baseURL!, token: cfg.token!),
                    baseURL: cfg.baseURL!, token: cfg.token!, assembler: native)
            }
    }

    public func resolve(video: Video) async throws -> DownloadPlan {
        try await resolve(video: video, audioOnly: false)
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
