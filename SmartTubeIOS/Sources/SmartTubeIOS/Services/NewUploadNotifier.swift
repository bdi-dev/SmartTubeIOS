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
    /// Identity the feed belongs to (the signed-in account or Brand Account), appended to the
    /// baseline tag so switching identity takes its own silent baseline instead of announcing
    /// uploads that were already there. `nil` for device-wide feeds.
    func baselineScope() async -> String?
}

extension UploadFeedSource {
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    public func baselineScope() async -> String? { nil }
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

/// The signed-in account's subscription feed. Empty when signed out or on any error, so a failed
/// fetch never looks like "no new videos" to the baseline logic (empty feeds record nothing).
struct SubscriptionsUploadSource: UploadFeedSource {
    let api: any InnerTubeAPIProtocol
    func latestUploads() async -> [Video] {
        (try? await api.fetchSubscriptions(continuationToken: nil).videos) ?? []
    }
    func baselineScope() async -> String? { await api.historyOwnerKey }
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

    /// Feeds to check, each with its own baseline tag.
    private let sources: [(tag: String, source: any UploadFeedSource)]
    private let poster: any UploadNotificationPosting
    private let seen: SeenUploadsStore
    private let now: @Sendable () -> Date
    private var lastCheck: Date?

    init(
        sources: [(tag: String, source: any UploadFeedSource)],
        poster: any UploadNotificationPosting = SystemUploadNotificationPoster(),
        seen: SeenUploadsStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sources = sources
        self.poster = poster
        self.seen = seen
        self.now = now
    }

    /// A single local feed (used by tests).
    convenience init(
        source: any UploadFeedSource,
        poster: any UploadNotificationPosting = SystemUploadNotificationPoster(),
        seen: SeenUploadsStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(sources: [(SeenUploadsStore.localSource, source)], poster: poster, seen: seen, now: now)
    }

    /// Production: the channels followed locally plus the signed-in account's subscriptions.
    public convenience init(api: any InnerTubeAPIProtocol) {
        self.init(sources: [
            (SeenUploadsStore.localSource, LocalFollowsUploadSource(api: api)),
            (SeenUploadsStore.subscriptionsSource, SubscriptionsUploadSource(api: api)),
        ])
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

        let blocked = Set(settings.blockedChannels.keys)
        var knownIds = await seen.seenIds()
        var toNotify: [Video] = []
        var checked = 0
        for (baseTag, source) in sources {
            let tag = await source.baselineScope().map { "\(baseTag):\($0)" } ?? baseTag
            let feed = await source.latestUploads()
            checked += feed.count
            let result = NewUploadDetector.evaluate(
                feed: feed, seenIds: knownIds, hasBaseline: await seen.hasBaseline(for: tag),
                isMuted: { video in video.channelId.map(blocked.contains) ?? false })
            await seen.markSeen(result.allIds, source: tag)
            knownIds.formUnion(result.allIds)  // a video in two feeds is announced once
            toNotify.append(contentsOf: result.toNotify)
        }
        toNotify = Array(toNotify.prefix(NewUploadDetector.maxAlertsPerCheck))
        for video in toNotify { await poster.post(video) }
        uploadLog.notice(
            "checked \(checked, privacy: .public) uploads from \(self.sources.count, privacy: .public) sources, announced \(toNotify.count, privacy: .public)"
        )
        return toNotify.count
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
