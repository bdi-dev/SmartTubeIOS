import Foundation
import SmartTubeIOSCore
import os

private let sessionLog = CrashlyticsLogger(category: "Download")

// MARK: - Events

/// Events emitted by the transfer layer, in the order the system delivered them.
public enum BackgroundTransferEvent: Sendable, Equatable {
    case progress(DownloadTransferID, written: Int64, expected: Int64)
    /// The part's bytes were moved into the staging directory.
    case staged(DownloadTransferID)
    case failed(DownloadTransferID, message: String)
    /// The system has delivered every event queued while the app was not running.
    case sessionEventsFinished
}

// MARK: - BackgroundTransferring

/// Seam between `VideoDownloadService` and the background `URLSession`. Tests supply a fake.
public protocol BackgroundTransferring: Sendable {
    /// Single ordered stream of transfer events. Buffers until consumed.
    var events: AsyncStream<BackgroundTransferEvent> { get }
    /// Where `didFinishDownloadingTo` stages finished files.
    var staging: DownloadStaging { get }
    /// Starts (or enqueues) a CDN transfer for `id`.
    func start(_ id: DownloadTransferID, url: URL, userAgent: String)
    /// Transfers the system still considers unfinished (running or suspended).
    func liveTransfers() async -> Set<DownloadTransferID>
    /// Cancels every transfer belonging to `videoId`.
    func cancel(videoId: String) async
    /// Suspends / resumes every running transfer of `videoId` (user pause). The system keeps the
    /// partial data, so a resumed transfer continues where it stopped.
    func pause(videoId: String) async
    func resume(videoId: String) async
    /// Invokes the completion handler stashed by `handleEventsForBackgroundURLSession`.
    @MainActor func backgroundEventsDidFinish()
}

// MARK: - BackgroundDownloadSession

/// Long-lived owner of the one background `URLSession` used for all downloads.
///
/// Created once (`shared`); the session identifier is `DownloadTuning.backgroundSessionIdentifier`.
/// The delegate is nonisolated and only forwards into an `AsyncStream`; the `@MainActor`
/// service consumes it. A finished temp file is moved into `Staging/<videoId>/<part>.tmp`
/// synchronously inside `didFinishDownloadingTo`, because the system deletes it on return.
public final class BackgroundDownloadSession: BackgroundTransferring, @unchecked Sendable {
    public static let shared = BackgroundDownloadSession()

    public let events: AsyncStream<BackgroundTransferEvent>
    public let staging: DownloadStaging

    private let delegate: Delegate
    private let session: URLSession

    @MainActor private var pendingCompletionHandler: (() -> Void)?

    public convenience init() {
        self.init(
            stagingRoot: DownloadStore.defaultDirectory.appendingPathComponent("Staging", isDirectory: true),
            configuration: Self.makeConfiguration())
    }

    init(stagingRoot: URL, configuration: URLSessionConfiguration) {
        let (stream, continuation) = AsyncStream<BackgroundTransferEvent>.makeStream(bufferingPolicy: .unbounded)
        let staging = DownloadStaging(root: stagingRoot)
        let delegate = Delegate(staging: staging, continuation: continuation)
        self.events = stream
        self.staging = staging
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: DownloadTuning.backgroundSessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return config
    }

    // MARK: BackgroundTransferring

    public func start(_ id: DownloadTransferID, url: URL, userAgent: String) {
        // Headers must be on the request: the User-Agent has to match the client that signed the URL.
        let request = InnerTubeDownloadFetcher.cdnRequest(for: url, userAgent: userAgent)
        let task = session.downloadTask(with: request)
        task.taskDescription = id.taskDescription
        task.resume()
    }

    public func liveTransfers() async -> Set<DownloadTransferID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { DownloadTransferID(taskDescription: $0.taskDescription) })
    }

    public func cancel(videoId: String) async {
        for task in await session.allTasks {
            if DownloadTransferID(taskDescription: task.taskDescription)?.videoId == videoId {
                task.cancel()
            }
        }
    }

    public func pause(videoId: String) async {
        for task in await session.allTasks
        where DownloadTransferID(taskDescription: task.taskDescription)?.videoId == videoId {
            task.suspend()
        }
    }

    public func resume(videoId: String) async {
        for task in await session.allTasks
        where DownloadTransferID(taskDescription: task.taskDescription)?.videoId == videoId {
            task.resume()
        }
    }

    // MARK: App delegate hook

    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. Touching `shared`
    /// has already re-created the session with this identifier, which makes the system deliver
    /// the queued events to the delegate. The handler is called once they have all been handled.
    @MainActor
    public func handleEventsForBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadTuning.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        pendingCompletionHandler = completionHandler
    }

    @MainActor
    public func backgroundEventsDidFinish() {
        let handler = pendingCompletionHandler
        pendingCompletionHandler = nil
        handler?()
    }

    // MARK: - Delegate

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let staging: DownloadStaging
        private let continuation: AsyncStream<BackgroundTransferEvent>.Continuation
        /// Last progress fraction forwarded per task, to avoid flooding the main actor.
        private let lastFraction = OSAllocatedUnfairLock(initialState: [Int: Double]())
        /// Tasks whose failure was already reported from `didFinishDownloadingTo`.
        private let reported = OSAllocatedUnfairLock(initialState: Set<Int>())

        init(staging: DownloadStaging, continuation: AsyncStream<BackgroundTransferEvent>.Continuation) {
            self.staging = staging
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard let id = DownloadTransferID(taskDescription: downloadTask.taskDescription) else { return }
            let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            let shouldForward = lastFraction.withLock { map -> Bool in
                let previous = map[downloadTask.taskIdentifier] ?? -1
                guard fraction - previous >= 0.005 else { return false }
                map[downloadTask.taskIdentifier] = fraction
                return true
            }
            guard shouldForward else { return }
            continuation.yield(.progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            guard let id = DownloadTransferID(taskDescription: downloadTask.taskDescription) else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                sessionLog.error("[download] \(id.taskDescription) HTTP \(status)")
                reported.withLock { _ = $0.insert(downloadTask.taskIdentifier) }
                continuation.yield(.failed(id, message: Self.message(forHTTPStatus: status)))
                return
            }
            // The system deletes `location` when this method returns: move it right now.
            let destination = staging.stagedFile(videoId: id.videoId, part: id.part)
            let fm = FileManager.default
            do {
                let size = (try? fm.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0
                guard size > 0 else { throw URLError(.zeroByteResource) }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: location, to: destination)
            } catch {
                reported.withLock { _ = $0.insert(downloadTask.taskIdentifier) }
                continuation.yield(.failed(id, message: error.localizedDescription))
                return
            }
            continuation.yield(.staged(id))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lastFraction.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
            let alreadyReported = reported.withLock { $0.remove(task.taskIdentifier) != nil }
            guard let error, !alreadyReported,
                let id = DownloadTransferID(taskDescription: task.taskDescription)
            else { return }
            // Cancellation is initiated by the service, which has already cleaned up.
            if (error as? URLError)?.code == .cancelled { return }
            continuation.yield(.failed(id, message: error.localizedDescription))
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            continuation.yield(.sessionEventsFinished)
        }

        private static func message(forHTTPStatus status: Int) -> String {
            switch status {
            case 403, 410:
                return "The download link expired or was rejected (HTTP \(status)). Tap Retry to fetch a new link."
            default:
                return "The server returned HTTP \(status). Tap Retry to try again."
            }
        }
    }
}
