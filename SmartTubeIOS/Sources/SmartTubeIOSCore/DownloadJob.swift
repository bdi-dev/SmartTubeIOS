import Foundation

// MARK: - DownloadPart

/// One CDN file that makes up a download: a muxed MP4, or the video / audio halves of an
/// adaptive pair that are merged after both arrive.
public enum DownloadPart: String, Codable, Sendable, CaseIterable {
    case muxed, video, audio
}

// MARK: - DownloadTransferID

/// Identity of a single background transfer. Encoded in `URLSessionTask.taskDescription` so it
/// survives app termination (the system keeps the description with the task).
public struct DownloadTransferID: Hashable, Sendable {
    public let videoId: String
    public let part: DownloadPart

    public init(videoId: String, part: DownloadPart) {
        self.videoId = videoId
        self.part = part
    }

    /// `"<part>:<videoId>"`, e.g. `"video:dQw4w9WgXcQ"`.
    public var taskDescription: String { "\(part.rawValue):\(videoId)" }

    public init?(taskDescription: String?) {
        guard let taskDescription, let colon = taskDescription.firstIndex(of: ":"),
            let part = DownloadPart(rawValue: String(taskDescription[..<colon]))
        else { return nil }
        let id = String(taskDescription[taskDescription.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        self.init(videoId: id, part: part)
    }
}

// MARK: - DownloadPlan

/// What to fetch for one video: resolved CDN URLs and the User-Agent each was signed for.
public struct DownloadPlan: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable {
        public let part: DownloadPart
        public let url: URL
        public let userAgent: String
        /// Extra request headers (e.g. a bearer token for the yt-dlp companion server). Empty for
        /// YouTube CDN URLs, which are authorised by the signed URL itself.
        public let headers: [String: String]

        public init(part: DownloadPart, url: URL, userAgent: String, headers: [String: String] = [:]) {
            self.part = part
            self.url = url
            self.userAgent = userAgent
            self.headers = headers
        }

        private enum CodingKeys: String, CodingKey { case part, url, userAgent, headers }

        /// Header names that carry credentials. They live only on the in-memory request and are
        /// never written to `job.json`: the token belongs in the Keychain, not in a plaintext file.
        private static let credentialHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie"]

        private static func withoutCredentials(_ headers: [String: String]) -> [String: String] {
            headers.filter { !credentialHeaders.contains($0.key.lowercased()) }
        }

        /// Tolerant: job records written before `headers` existed decode with no headers, and
        /// credential headers saved by older builds are discarded.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            part = try container.decode(DownloadPart.self, forKey: .part)
            url = try container.decode(URL.self, forKey: .url)
            userAgent = try container.decode(String.self, forKey: .userAgent)
            let stored = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            headers = Self.withoutCredentials(stored)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(part, forKey: .part)
            try container.encode(url, forKey: .url)
            try container.encode(userAgent, forKey: .userAgent)
            try container.encode(Self.withoutCredentials(headers), forKey: .headers)
        }
    }

    public let parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    /// True when video and audio arrive separately and must be merged.
    public var needsMerge: Bool { parts.count > 1 }
}

// MARK: - DownloadJob

/// Per-video record persisted at `Staging/<videoId>/job.json` so that, after the app was
/// suspended or killed, the next launch knows what was in flight.
public struct DownloadJob: Codable, Sendable, Equatable {
    public let videoId: String
    public let plan: DownloadPlan
    /// Parts whose bytes are safely in the staging directory.
    public var donePartNames: Set<DownloadPart>

    public init(videoId: String, plan: DownloadPlan, donePartNames: Set<DownloadPart> = []) {
        self.videoId = videoId
        self.plan = plan
        self.donePartNames = donePartNames
    }

    public var expectedParts: [DownloadPart] { plan.parts.map(\.part) }
    public var needsMerge: Bool { plan.needsMerge }
    public var isComplete: Bool { Set(expectedParts).isSubset(of: donePartNames) }
}

// MARK: - DownloadStaging

/// Layout of `<downloadsDir>/Staging`. Pure file-system helpers, safe to call from any thread.
public struct DownloadStaging: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(for videoId: String) -> URL {
        root.appendingPathComponent(videoId, isDirectory: true)
    }

    public func stagedFile(videoId: String, part: DownloadPart) -> URL {
        directory(for: videoId).appendingPathComponent("\(part.rawValue).tmp")
    }

    public func jobURL(for videoId: String) -> URL {
        directory(for: videoId).appendingPathComponent("job.json")
    }

    public func hasStagedFile(videoId: String, part: DownloadPart) -> Bool {
        FileManager.default.fileExists(atPath: stagedFile(videoId: videoId, part: part).path)
    }

    public func save(_ job: DownloadJob) throws {
        try FileManager.default.createDirectory(at: directory(for: job.videoId), withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: jobURL(for: job.videoId), options: .atomic)
    }

    /// Loads the job and reconciles `donePartNames` with the files that really exist: a part
    /// moved into staging just before a crash counts as done even if `job.json` lags behind.
    public func load(videoId: String) -> DownloadJob? {
        guard let data = try? Data(contentsOf: jobURL(for: videoId)),
            var job = try? JSONDecoder().decode(DownloadJob.self, from: data)
        else { return nil }
        job.donePartNames = Set(job.expectedParts.filter { hasStagedFile(videoId: videoId, part: $0) })
        return job
    }

    public func remove(videoId: String) {
        try? FileManager.default.removeItem(at: directory(for: videoId))
    }
}
