#if !os(tvOS)
import SmartTubeIOSCore
import SwiftUI

// MARK: - NASStatusTarget

/// The server a status page asks, and the host it shows. Nil when no URL or token is set.
struct NASStatusTarget {
    let client: any YtDlpServerClient
    let host: String

    init?(baseURL: URL?, token: String?) {
        let trimmed = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL, !trimmed.isEmpty else { return nil }
        client = URLSessionYtDlpServerClient(baseURL: baseURL, token: trimmed)
        host = baseURL.host ?? baseURL.absoluteString
    }

    /// The target from the saved settings and Keychain token.
    static func current() -> NASStatusTarget? {
        let cfg = YtDlpServerConfig.current()
        return NASStatusTarget(baseURL: cfg.baseURL, token: cfg.token)
    }
}

// MARK: - NASStatusView

/// What the NAS server is doing and how full it is. Shared by the Downloads info sheet (wrapped in
/// a NavigationStack by `NASStatusSheet`) and the Settings NAS page (pushed). Read-only.
struct NASStatusView: View {
    @State private var model: NASStatusViewModel
    private let host: String

    /// Usage at or above this share of the cap is drawn in warning colour.
    private static let warningFraction = 0.9
    /// Only the newest failures are listed.
    private static let failureLimit = 5

    init(client: any YtDlpServerClient, host: String) {
        _model = State(initialValue: NASStatusViewModel(client: client))
        self.host = host
    }

    var body: some View {
        List {
            switch model.state {
            case .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            case .loaded(let status):
                loadedSections(status)
            case .unreachable(let message):
                messageSection(message)
            case .serverTooOld:
                messageSection("This server is too old for the status page. Update the yt-dlp server.")
            case .rejected:
                messageSection("Token revoked or wrong")
            }
        }
        .accessibilityIdentifier(AccessibilityID.Settings.nasStatusList)
        .navigationTitle("NAS")
        .refreshable { await model.refresh() }
        .task { await model.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: AppSymbol.refresh)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.nasStatusRefreshButton)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func loadedSections(_ status: YtDlpServerStatus) -> some View {
        Section("Connection") {
            LabeledContent("Server", value: host)
            LabeledContent("Reachable", value: "Yes")
            LabeledContent("Last checked") {
                if let checkedAt = model.checkedAt {
                    Text(checkedAt, style: .relative)
                }
            }
            if let ms = model.roundTripMilliseconds {
                LabeledContent("Round trip", value: "\(ms) ms")
            }
        }

        Section("Server") {
            LabeledContent("API version", value: "\(status.apiVersion)")
            LabeledContent("yt-dlp version", value: status.ytdlpVersion ?? "Not found")
            LabeledContent(
                "Uptime",
                value: Duration.seconds(status.uptimeSeconds).formatted(
                    .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
        }

        Section {
            LabeledContent("Videos", value: "\(status.you.videoCount)")
            LabeledContent(
                "Kept", value: "\(status.you.kept.count) · \(formatByteCount(status.you.kept.bytes))")
            LabeledContent(
                "Unkept", value: "\(status.you.unkept.count) · \(formatByteCount(status.you.unkept.bytes))")
            capGauge(used: status.you.unkept.bytes, cap: status.you.capBytes)
        } header: {
            Text("Your usage")
        } footer: {
            Text("An admin sets this. Unkept files over the cap are evicted oldest first.")
        }

        Section("Storage") {
            LabeledContent(
                "Free", value: "\(formatByteCount(status.disk.freeBytes)) of \(formatByteCount(status.disk.totalBytes))"
            )
        }

        Section("Activity") {
            LabeledContent("Running", value: "\(status.jobs.running)")
            LabeledContent("Queued", value: "\(status.jobs.queued)")
            if status.recentFailures.isEmpty {
                Text("No recent failures")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(status.recentFailures.prefix(Self.failureLimit)) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.videoId)
                            .font(.caption.monospaced())
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(failure.at, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if let server = status.server {
            Section {
                LabeledContent("Profiles", value: "\(server.profiles)")
                LabeledContent("Files", value: "\(server.totalFiles)")
                LabeledContent("Size", value: formatByteCount(server.totalBytes))
            } header: {
                Text("All users")
            } footer: {
                Text("Each file on disk is counted once.")
            }
        }
    }

    @ViewBuilder
    private func messageSection(_ message: String) -> some View {
        Section {
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier(AccessibilityID.Settings.nasStatusMessage)
        }
    }

    /// "12.4 GB of 20 GB" as a gauge, warning colour once the share reaches the threshold.
    @ViewBuilder
    private func capGauge(used: Int64, cap: Int64) -> some View {
        let nearCap = cap > 0 && Double(used) / Double(cap) >= Self.warningFraction
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Unkept cap", value: formatByteCount(cap))
            if cap > 0 {
                ProgressView(value: Double(min(used, cap)), total: Double(cap))
                    .tint(nearCap ? .orange : .accentColor)
                Text("\(formatByteCount(used)) of \(formatByteCount(cap))")
                    .font(.caption)
                    .foregroundStyle(nearCap ? Color.orange : Color.secondary)
            }
        }
    }
}

// MARK: - NASStatusSheet

/// The Downloads info sheet: the status page in its own NavigationStack, with a Done button.
struct NASStatusSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let target = NASStatusTarget.current() {
                NASStatusView(client: target.client, host: target.host)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        }
    }
}
#endif
