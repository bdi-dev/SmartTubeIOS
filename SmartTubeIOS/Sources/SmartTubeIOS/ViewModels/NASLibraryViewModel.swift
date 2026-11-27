import Foundation
import SmartTubeIOSCore
import os

private let nasLog = Logger(subsystem: appSubsystem, category: "NASLibrary")

// MARK: - NASLibraryViewModel

/// The "Available on NAS" list: the yt-dlp server's finished downloads that this device does not
/// hold. Pages load one at a time with the server's keyset cursor, so new downloads do not shift
/// the pages. The section is hidden unless the server reports API version 2 or later.
@MainActor
@Observable
final class NASLibraryViewModel {
    /// Rows requested per page (the server's default).
    static let pageSize = 50
    /// Pages keep loading until this many rows are visible, so a page of rows already on this device
    /// cannot stall paging.
    static let minimumVisibleRows = 20
    /// The first server API version with the library, keep and delete endpoints.
    static let minimumAPIVersion = 2
    /// Download states in which this device already holds, or is fetching, a video. Those rows leave
    /// the list so a second tap cannot silently do nothing.
    static let localStatuses: Set<DownloadedVideo.Status> = [.queued, .downloading, .merging, .complete]

    enum Gate: Equatable { case unchecked, hidden, visible }

    private(set) var gate: Gate = .unchecked
    /// Every row loaded from the server, including ones this device already holds.
    private(set) var items: [YtDlpLibraryItem] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    /// A one-line problem for the section, or nil when there is none.
    private(set) var message: String?

    /// nil when no server is configured; the section then stays hidden.
    private let client: (any YtDlpServerClient)?
    private let store: DownloadStore
    /// Set once a page has loaded. Until then a failed load hides the section.
    private var hasLoadedPage = false

    init(client: (any YtDlpServerClient)?, store: DownloadStore) {
        self.client = client
        self.store = store
    }

    var isVisible: Bool { gate == .visible }

    /// The loaded rows that this device does not hold or fetch.
    var available: [YtDlpLibraryItem] {
        let local = Set(store.entries.filter { Self.localStatuses.contains($0.status) }.map(\.videoId))
        return items.filter { !local.contains($0.videoId) }
    }

    // MARK: - Loading

    /// Called when the screen appears. Checks the gate once, then loads the first page.
    func appear() async {
        if gate == .unchecked { gate = await evaluateGate() }
        guard isVisible, !hasLoadedPage else { return }
        await reload()
    }

    /// Pull-to-refresh. Reloads page 1, and checks the gate again if the section was hidden.
    func refresh() async {
        if gate != .visible { gate = await evaluateGate() }
        guard isVisible else { return }
        await reload()
    }

    /// Called when a row appears. The last visible row loads the next page.
    func loadMoreIfNeeded(after videoId: String) async {
        guard videoId == available.last?.videoId, let cursor = nextCursor else { return }
        if await fetchPage(cursor: cursor) {
            await fillVisibleRows()
        }
    }

    private func reload() async {
        guard await fetchPage(cursor: nil) else { return }
        await fillVisibleRows()
    }

    /// Keeps loading pages while too few rows are visible.
    private func fillVisibleRows() async {
        while available.count < Self.minimumVisibleRows, let cursor = nextCursor {
            guard await fetchPage(cursor: cursor) else { return }
        }
    }

    /// Loads one page. A first page replaces the rows; a later page appends. Returns false when the
    /// page did not load. A failure keeps the rows already shown.
    private func fetchPage(cursor: String?) async -> Bool {
        guard let client, !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.library(cursor: cursor, limit: Self.pageSize)
            if cursor == nil {
                items = page.items
            } else {
                items.append(contentsOf: page.items)
            }
            nextCursor = page.nextCursor
            hasLoadedPage = true
            message = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            nasLog.notice("NAS library page failed: \(error.localizedDescription, privacy: .public)")
            if Self.isUnauthorized(error) {
                // The server is up but the token is not: show why, instead of hiding or leaving stale rows.
                items = []
                nextCursor = nil
                message = Self.message(for: error)
            } else if hasLoadedPage {
                message = Self.message(for: error)
            } else {
                gate = .hidden
            }
            return false
        }
    }

    private func evaluateGate() async -> Gate {
        guard let client else { return .hidden }
        do {
            let health = try await client.health()
            let supported = health.ok && (health.apiVersion ?? 0) >= Self.minimumAPIVersion
            return supported ? .visible : .hidden
        } catch {
            return .hidden
        }
    }

    // MARK: - Actions

    /// Keeps or unkeeps the NAS copy. The row changes only after the server confirms.
    func setKeep(videoId: String, keep: Bool) async {
        guard let client else { return }
        do {
            try await client.setKeep(videoId: videoId, keep: keep)
            if let index = items.firstIndex(where: { $0.videoId == videoId }) {
                items[index].keep = keep
            }
            message = nil
        } catch {
            message = Self.message(for: error)
        }
    }

    /// Deletes the NAS copy. A 409 means the server is still downloading it, so the row stays.
    func deleteFromNAS(videoId: String) async {
        guard let client else { return }
        do {
            try await client.deleteFromServer(videoId: videoId)
            items.removeAll { $0.videoId == videoId }
            message = nil
        } catch let error as YtDlpServerError where error.status == 409 {
            message = String(localized: "Still downloading on the NAS", bundle: .module)
        } catch {
            message = Self.message(for: error)
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        (error as? YtDlpServerError)?.status == 401
    }

    private static func message(for error: Error) -> String {
        if isUnauthorized(error) {
            return String(localized: "Token revoked or wrong", bundle: .module)
        }
        if let serverError = error as? YtDlpServerError {
            guard serverError.status != nil else {
                return String(localized: "NAS unreachable", bundle: .module)
            }
            return serverError.message
        }
        return error.localizedDescription
    }
}
