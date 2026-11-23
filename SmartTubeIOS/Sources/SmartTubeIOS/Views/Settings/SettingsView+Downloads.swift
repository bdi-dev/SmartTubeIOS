import SmartTubeIOSCore
import SwiftUI

// The Downloads settings section and the yt-dlp server rows, moved out of SettingsView.swift to
// keep that file under the length limit. Pure move; the only change is that members used by the
// section are no longer private.

extension SettingsView {
    // MARK: - Downloads

    #if os(iOS)
    /// Turning alerts on asks for notification permission (reverting the switch if refused) and
    /// schedules background refresh; turning them off cancels it.
    private func applyNewUploadAlerts(_ on: Bool) async {
        guard on else {
            NewUploadNotifier.cancelBackgroundRefresh()
            return
        }
        let granted = await NewUploadNotifier(api: InnerTubeAPI()).enable()
        if granted {
            NewUploadNotifier.scheduleBackgroundRefresh()
        } else {
            store.settings.notifyNewUploads = false
        }
    }
    #endif

    #if !os(tvOS)
    var downloadsSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Auto-download Watch Later", isOn: $store.settings.autoDownloadWatchLater)
                .accessibilityIdentifier(AccessibilityID.Settings.autoDownloadWatchLaterToggle)
            Toggle("Only on Wi-Fi", isOn: $store.settings.autoDownloadOnlyOnWiFi)
                .disabled(!store.settings.autoDownloadWatchLater)
                .accessibilityIdentifier(AccessibilityID.Settings.autoDownloadWiFiOnlyToggle)
            YtDlpServerSettingsRows()
            #if os(iOS)
            Toggle("New upload alerts", isOn: $store.settings.notifyNewUploads)
                .accessibilityIdentifier(AccessibilityID.Settings.notifyNewUploadsToggle)
                .onChange(of: store.settings.notifyNewUploads) { _, on in
                    Task { await applyNewUploadAlerts(on) }
                }
            #endif
        } header: {
            Text("Downloads")
        } footer: {
            Text(
                "New Watch Later videos (up to 5 at a time, under 3 hours) are downloaded when you open the app. New upload alerts are local notifications for channels you follow in SmartTube and for your signed-in subscriptions. The optional yt-dlp server is your own machine running tools/ytdlp-server; reach it over Tailscale (an http:// address is fine there). It also fetches videos the app cannot play itself. Downloads are never deleted automatically."
            )
        }
    }
    #endif
}

// MARK: - yt-dlp server rows

#if !os(tvOS)
/// Settings for the optional yt-dlp companion server: when to use it, where it is, its token
/// (kept in the Keychain), and a connection test that also checks the token.
private struct YtDlpServerSettingsRows: View {
    @Environment(SettingsStore.self) private var store
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        @Bindable var store = store
        Group {
            Picker("yt-dlp server", selection: $store.settings.ytDlpMode) {
                Text("Off").tag(YtDlpMode.off)
                Text("Fallback").tag(YtDlpMode.fallback)
                Text("Always").tag(YtDlpMode.always)
            }
            .accessibilityIdentifier(AccessibilityID.Settings.ytDlpModePicker)
            if store.settings.ytDlpMode != .off {
                TextField("Server URL", text: $urlText)
                    #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.Settings.ytDlpURLField)
                    .onChange(of: urlText) { _, text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.settings.ytDlpServerURL = URL(string: trimmed).flatMap {
                            $0.scheme != nil && $0.host != nil ? $0 : nil
                        }
                        testResult = nil
                    }
                SecureField("Token", text: $tokenText)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.Settings.ytDlpTokenField)
                    .onChange(of: tokenText) { _, text in
                        YtDlpServerConfig.saveToken(text)
                        testResult = nil
                    }
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("Test connection")
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting || store.settings.ytDlpServerURL == nil || tokenText.isEmpty)
                .accessibilityIdentifier(AccessibilityID.Settings.ytDlpTestButton)
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.Settings.ytDlpTestResult)
                }
            }
        }
        .onAppear {
            urlText = store.settings.ytDlpServerURL?.absoluteString ?? ""
            tokenText = YtDlpServerConfig.current().token ?? ""
        }
    }

    /// Checks the server is reachable, then that the token is accepted (an unknown job id gives
    /// 404 when the token is fine and 401 when it is not).
    private func testConnection() async {
        guard let url = store.settings.ytDlpServerURL else { return }
        isTesting = true
        defer { isTesting = false }
        let client = URLSessionYtDlpServerClient(baseURL: url, token: tokenText)
        do {
            let health = try await client.health()
            let version = health.ytdlpVersion.map { "yt-dlp \($0)" } ?? "yt-dlp not found on the server"
            do {
                _ = try await client.jobState(videoId: "AAAAAAAAAAA")
                testResult = "Connected (\(version))."
            } catch let error as YtDlpServerError where error.message.contains("does not know") {
                testResult = "Connected (\(version)); token accepted."
            } catch {
                testResult = error.localizedDescription
            }
        } catch {
            testResult = error.localizedDescription
        }
    }
}
#endif
