#if os(iOS)
import BackgroundTasks
import Foundation
import SmartTubeIOSCore
import UserNotifications
import os

private let uploadLog = Logger(subsystem: appSubsystem, category: "NewUploads")

// MARK: - Seams

/// Where fresh uploads come from. Production: the channels the user follows locally (no account
/// needed), through the same RSS-first service the Subscriptions feed uses.
public protocol UploadFeedSource: Sendable {
    func latestUploads() async -> [Video]
}

/// Raises the actual alerts. Production: `UNUserNotificationCenter` local notifications.
public protocol UploadNotificationPosting: Sendable {
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    func post(_ video: Video) async
}

struct LocalFollowsUploadSource: UploadFeedSource {
    let api: any InnerTubeAPIProtocol
    func latestUploads() async -> [Video] {
        await LocalSubscriptionFeedService.shared.fetchFeed(api: api)
    }
}

/// Local (not push) notifications: no entitlement or paid membership involved. Tapping one opens
/// the video through the app's `smarttube://` URL scheme.
struct SystemUploadNotificationPoster: UploadNotificationPosting {
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func post(_ video: Video) async {
        let content = UNMutableNotificationContent()
        content.title =
            video.channelTitle.isEmpty ? String(localized: "New video", bundle: .module) : video.channelTitle
        content.body = video.title
        content.sound = .default
        content.threadIdentifier = video.channelId ?? video.channelTitle
        content.userInfo = ["videoId": video.id]
        let request = UNNotificationRequest(identifier: "upload-\(video.id)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            uploadLog.error("could not post notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - NewUploadNotifier

/// Checks for new uploads and announces them. Opt-in, throttled, silent on the first run (it only
/// records a baseline), capped per check, and respects blocked channels.
@MainActor
public final class NewUploadNotifier {
    public static let refreshTaskIdentifier = "com.void.smarttube.app.refresh"
    /// Minimum gap between checks, whether triggered by foregrounding or by background refresh.
    public static let minInterval: TimeInterval = 15 * 60

    private let source: any UploadFeedSource
    private let poster: any UploadNotificationPosting
    private let seen: SeenUploadsStore
    private let now: @Sendable () -> Date
    private var lastCheck: Date?

    init(
        source: any UploadFeedSource,
        poster: any UploadNotificationPosting = SystemUploadNotificationPoster(),
        seen: SeenUploadsStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.poster = poster
        self.seen = seen
        self.now = now
    }

    public convenience init(api: any InnerTubeAPIProtocol) {
        self.init(source: LocalFollowsUploadSource(api: api))
    }

    /// Asks for permission (the system prompt appears once). `true` if alerts can be shown.
    public func enable() async -> Bool {
        if await poster.isAuthorized() { return true }
        return await poster.requestAuthorization()
    }

    /// Runs a check when alerts are enabled and the last one was long enough ago.
    /// - Returns: how many alerts were raised.
    @discardableResult
    public func checkIfDue(settings: AppSettings, force: Bool = false) async -> Int {
        guard settings.notifyNewUploads else { return 0 }
        if !force, let last = lastCheck, now().timeIntervalSince(last) < Self.minInterval { return 0 }
        lastCheck = now()
        guard await poster.isAuthorized() else { return 0 }

        let feed = await source.latestUploads()
        let blocked = Set(settings.blockedChannels.keys)
        let knownIds = await seen.seenIds()
        let baseline = await seen.hasBaseline
        let result = NewUploadDetector.evaluate(
            feed: feed, seenIds: knownIds, hasBaseline: baseline,
            isMuted: { video in video.channelId.map(blocked.contains) ?? false })
        await seen.markSeen(result.allIds)
        for video in result.toNotify { await poster.post(video) }
        let unseen = feed.filter { !knownIds.contains($0.id) }.count
        uploadLog.notice(
            "checked \(feed.count, privacy: .public) uploads (baseline \(baseline, privacy: .public), unseen \(unseen, privacy: .public)), announced \(result.toNotify.count, privacy: .public)"
        )
        return result.toNotify.count
    }

    // MARK: Background refresh

    /// Registers the BGAppRefresh handler. Must run before the app finishes launching.
    public static func registerBackgroundRefresh(_ handler: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            let work = Task { @MainActor in
                await handler()
                scheduleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks the system to wake the app for a refresh in about an hour (the system decides when).
    public static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            uploadLog.error("could not schedule refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func cancelBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
    }
}
#endif
