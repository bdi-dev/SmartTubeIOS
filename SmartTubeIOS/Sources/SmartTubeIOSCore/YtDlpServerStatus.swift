import Foundation

// MARK: - YtDlpServerStatus

/// The companion server's status from `GET /v1/status` (API version 5). Everything under `you` is
/// scoped to the caller; `server` is present only for admins.
public struct YtDlpServerStatus: Decodable, Sendable, Equatable {
    public let apiVersion: Int
    public let ytdlpVersion: String?
    public let uptimeSeconds: Double
    public let disk: Disk
    public let you: Account
    public let jobs: Jobs
    public let recentFailures: [Failure]
    /// Server-wide totals. Present only when the caller is an admin.
    public let server: ServerTotals?

    public init(
        apiVersion: Int, ytdlpVersion: String?, uptimeSeconds: Double, disk: Disk, you: Account, jobs: Jobs,
        recentFailures: [Failure], server: ServerTotals?
    ) {
        self.apiVersion = apiVersion
        self.ytdlpVersion = ytdlpVersion
        self.uptimeSeconds = uptimeSeconds
        self.disk = disk
        self.you = you
        self.jobs = jobs
        self.recentFailures = recentFailures
        self.server = server
    }

    /// Free and total bytes of the data volume.
    public struct Disk: Decodable, Sendable, Equatable {
        public let freeBytes: Int64
        public let totalBytes: Int64

        public init(freeBytes: Int64, totalBytes: Int64) {
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
        }
    }

    /// A count and byte total for one group of files.
    public struct Tally: Decodable, Sendable, Equatable {
        public let count: Int
        public let bytes: Int64

        public init(count: Int, bytes: Int64) {
            self.count = count
            self.bytes = bytes
        }
    }

    /// The caller's own usage. A shared video counts in full toward each owner.
    public struct Account: Decodable, Sendable, Equatable {
        public let videoCount: Int
        public let kept: Tally
        public let unkept: Tally
        /// The unkept cap for this caller. Only an admin can change it.
        public let capBytes: Int64

        public init(videoCount: Int, kept: Tally, unkept: Tally, capBytes: Int64) {
            self.videoCount = videoCount
            self.kept = kept
            self.unkept = unkept
            self.capBytes = capBytes
        }
    }

    /// Jobs the caller owns that are still running or waiting.
    public struct Jobs: Decodable, Sendable, Equatable {
        public let running: Int
        public let queued: Int

        public init(running: Int, queued: Int) {
            self.running = running
            self.queued = queued
        }
    }

    /// A recent failed job of the caller's, with a short reason.
    public struct Failure: Decodable, Sendable, Equatable, Identifiable {
        public var id: String { "\(videoId)@\(at.timeIntervalSince1970)" }
        public let videoId: String
        public let message: String
        public let at: Date

        public init(videoId: String, message: String, at: Date) {
            self.videoId = videoId
            self.message = message
            self.at = at
        }

        private enum CodingKeys: String, CodingKey {
            case videoId, message, at
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            videoId = try container.decode(String.self, forKey: .videoId)
            message = try container.decode(String.self, forKey: .message)
            // The server writes `%Y-%m-%dT%H:%M:%SZ`, which ISO8601DateFormatter's default options read.
            let stamp = try container.decode(String.self, forKey: .at)
            guard let date = ISO8601DateFormatter().date(from: stamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .at, in: container, debugDescription: "Unreadable date \(stamp)")
            }
            at = date
        }
    }

    /// Server-wide totals for admins. Physical files are counted once each.
    public struct ServerTotals: Decodable, Sendable, Equatable {
        public let profiles: Int
        public let totalFiles: Int
        public let totalBytes: Int64

        public init(profiles: Int, totalFiles: Int, totalBytes: Int64) {
            self.profiles = profiles
            self.totalFiles = totalFiles
            self.totalBytes = totalBytes
        }
    }
}
