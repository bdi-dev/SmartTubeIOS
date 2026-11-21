import AuthenticationServices
import SmartTubeIOSCore
import SwiftUI

// MARK: - SettingsView
//
// App preferences.  Mirrors the Android settings presenters
// (PlayerData, MainUIData, SponsorBlockData, DeArrowData, AccountsData).

public struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @State private var showSignIn = false
    @State private var reportSent = false
    #if os(tvOS)
    @State private var showGithubQR = false
    #endif
    /// #126: whether the current visit to this screen has already passed the PIN
    /// check. Reset to `false` on `.onDisappear` (see body) so leaving and coming back
    /// to Settings (e.g. switching tabs) re-locks it — a parental-control PIN that
    /// only had to be entered once per app launch wouldn't stop a kid who's already
    /// seen the tab switch away and back.
    @State private var isUnlocked = false
    @State private var parentalControlsSheetMode: ParentalControlsMode?

    public init() {}

    public var body: some View {
        Group {
            if let pinHash = store.settings.settingsPINHash, !isUnlocked {
                SettingsPINLockView(expectedHash: pinHash) { isUnlocked = true }
            } else {
                settingsForm
            }
        }
        .onDisappear {
            if store.settings.settingsPINHash != nil { isUnlocked = false }
        }
    }

    private var settingsForm: some View {
        Form {
            accountSection
            playerSection
            generalSection
            #if !os(tvOS)
            downloadsSection
            #endif
            uiSection
            sponsorBlockSection
            deArrowSection
            parentalControlsSection
            #if os(macOS) || os(tvOS)
            experimentalSection
            #endif
            aboutSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        // Hide the blank navigation bar on iOS and tvOS — a visible nav bar on tvOS
        // conflicts with the TabView tab bar scroll-hide animation (issue #102 / gh-34).
        // .navigationBar placement is unavailable on macOS.
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(tvOS)
        .sheet(isPresented: $showGithubQR) {
            GitHubQRView()
        }
        #endif
        .sheet(item: $parentalControlsSheetMode) { mode in
            ParentalControlsSheet(mode: mode)
        }
    }

    // MARK: - Parental Controls

    private var parentalControlsSection: some View {
        Section {
            if store.settings.settingsPINHash == nil {
                Button("Set PIN") { parentalControlsSheetMode = .set }
                    .accessibilityIdentifier("settings.setPINButton")
            } else {
                Button("Change PIN") { parentalControlsSheetMode = .change }
                    .accessibilityIdentifier("settings.changePINButton")
                Button("Remove PIN", role: .destructive) { parentalControlsSheetMode = .remove }
                    .accessibilityIdentifier("settings.removePINButton")
            }
        } header: {
            Text("Parental Controls")
        } footer: {
            Text("When a PIN is set, it must be entered every time this Settings screen is opened.")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            if auth.isSignedIn {
                HStack {
                    #if os(tvOS)
                    let avatarSize: CGFloat = 64
                    #else
                    let avatarSize: CGFloat = 40
                    #endif
                    AsyncImage(url: auth.accountAvatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure, .empty:
                            Circle().fill(Color.secondary.opacity(0.3))
                                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                        @unknown default:
                            Circle().fill(Color.secondary.opacity(0.3))
                        }
                    }
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                    Text(auth.accountName ?? "Unknown")
                }
                NavigationLink {
                    ChannelSwitcherView()
                } label: {
                    LabeledContent("Channel", value: auth.activeChannel?.name ?? "")
                }
                .accessibilityIdentifier("settings.channelLink")
                Button("Sign Out", role: .destructive) { auth.signOut() }
            } else {
                Button("Sign in with Google") { showSignIn = true }
                    .accessibilityIdentifier("settings.signInButton")
                    .sheet(isPresented: $showSignIn) { SignInView() }
            }
        }
    }

    // MARK: - Player

    private var playerSection: some View {
        @Bindable var store = store
        return Section("Player") {
            #if os(iOS)
            Toggle("YouTube Web Player", isOn: $store.settings.useTOSPlayerOnIOS)
                .accessibilityIdentifier("settings.useTOSPlayerOnIOSToggle")
            #endif

            SettingsPicker(
                "Playback Speed", selection: $store.settings.playbackSpeed,
                options: AppSettings.availableSpeeds.map {
                    .init(title: $0 == 1.0 ? "Normal" : String(format: "%g×", $0), value: $0)
                })

            #if !os(iOS)
            SettingsPicker(
                "Default Quality", selection: $store.settings.preferredQuality,
                options: AppSettings.VideoQuality.allCases.map {
                    .init(title: $0.rawValue.capitalized, value: $0)
                }
            )
            .accessibilityIdentifier("settings.preferredQualityPicker")

            SettingsPicker(
                "Preferred Audio Language", selection: $store.settings.preferredAudioLanguage,
                options: [
                    .init(title: "System Default", value: nil as String?),
                    .init(title: "English", value: "en" as String?, separatorBefore: true),
                    .init(title: "Spanish", value: "es" as String?),
                    .init(title: "French", value: "fr" as String?),
                    .init(title: "German", value: "de" as String?),
                    .init(title: "Japanese", value: "ja" as String?),
                    .init(title: "Korean", value: "ko" as String?),
                    .init(title: "Portuguese (Brazil)", value: "pt-BR" as String?),
                    .init(title: "Chinese (Simplified)", value: "zh-Hans" as String?),
                    .init(title: "Original Track Only", value: "original" as String?, separatorBefore: true),
                ]
            )
            .accessibilityIdentifier("settings.preferredAudioLanguageRow")
            #endif

            #if os(tvOS)
            SettingsPicker(
                "Seek Back", selection: $store.settings.seekBackSeconds,
                options: AppSettings.availableSeekOptions.map { .init(title: "\($0) s", value: $0) }
            )
            .accessibilityIdentifier("settings.seekBackRow")
            SettingsPicker(
                "Seek Forward", selection: $store.settings.seekForwardSeconds,
                options: AppSettings.availableSeekOptions.map { .init(title: "\($0) s", value: $0) }
            )
            .accessibilityIdentifier("settings.seekForwardRow")
            #elseif os(macOS)
            Stepper(
                "Seek Back: \(store.settings.seekBackSeconds) s",
                value: $store.settings.seekBackSeconds,
                in: 5...60,
                step: 5
            )
            .accessibilityIdentifier("settings.seekBackRow")
            Stepper(
                "Seek Forward: \(store.settings.seekForwardSeconds) s",
                value: $store.settings.seekForwardSeconds,
                in: 5...60,
                step: 5
            )
            .accessibilityIdentifier("settings.seekForwardRow")
            #endif

            #if !os(iOS)
            SettingsPicker(
                "Hide Controls After", selection: $store.settings.controlsHideTimeout,
                options: [2, 3, 4, 5, 8, 10].map { .init(title: "\($0)s", value: $0) })

            SettingsPicker(
                "Video Fit", selection: $store.settings.videoGravityMode,
                options: [
                    .init(title: "Fit (letterbox)", value: AppSettings.VideoGravityMode.fit),
                    .init(title: "Fill (crop)", value: AppSettings.VideoGravityMode.fill),
                ])
            #endif

            Toggle("Loop Video", isOn: $store.settings.loopEnabled)
            Toggle("Shuffle", isOn: $store.settings.shuffleEnabled)

            Toggle("Autoplay next video", isOn: $store.settings.autoplayEnabled)
            Toggle("Background Playback", isOn: $store.settings.backgroundPlaybackEnabled)
            #if !os(iOS)
            Toggle("Prefer H.264 Codec", isOn: $store.settings.preferH264)
                .accessibilityIdentifier("settings.preferH264Toggle")
            #endif
        }
    }

    // MARK: - General

    private var generalSection: some View {
        @Bindable var store = store
        return Section {
            SettingsPicker(
                "Watch History", selection: $store.settings.historyState,
                options: [
                    .init(title: "Enabled", value: AppSettings.HistoryState.enabled),
                    .init(title: "Disabled", value: AppSettings.HistoryState.disabled),
                ])
            if !LocalWatchHistoryStore.shared.entries.isEmpty {
                Button("Clear Watch History on This Device", role: .destructive) {
                    LocalWatchHistoryStore.shared.clear()
                }
                .accessibilityIdentifier("settings.clearLocalHistoryButton")
            }
            Toggle("Sync to iCloud", isOn: $store.settings.iCloudSyncEnabled)
                .disabled(!Self.iCloudAvailable)
                .accessibilityIdentifier("settings.iCloudSyncToggle")
            if !Self.iCloudAvailable {
                // No iCloud account, or this build was signed without the iCloud entitlement
                // (free Apple ID — see docs/how-to/free-account-build.md).
                Text("iCloud sync is unavailable: no iCloud account, or this build has iCloud switched off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.iCloudUnavailableNote")
            }
        } header: {
            Text("General")
        } footer: {
            Text(
                "Watch history is saved on this device. SmartTube also tries to report watches to your YouTube account, but YouTube may not always record them."
            )
        }
    }

    /// `true` when this device/build can use iCloud key-value sync.
    private static var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

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
    private var downloadsSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Auto-download Watch Later", isOn: $store.settings.autoDownloadWatchLater)
                .accessibilityIdentifier("settings.autoDownloadWatchLaterToggle")
            Toggle("Only on Wi-Fi", isOn: $store.settings.autoDownloadOnlyOnWiFi)
                .disabled(!store.settings.autoDownloadWatchLater)
                .accessibilityIdentifier("settings.autoDownloadWiFiOnlyToggle")
            YtDlpServerSettingsRows()
            #if os(iOS)
            Toggle("New upload alerts", isOn: $store.settings.notifyNewUploads)
                .accessibilityIdentifier("settings.notifyNewUploadsToggle")
                .onChange(of: store.settings.notifyNewUploads) { _, on in
                    Task { await applyNewUploadAlerts(on) }
                }
            #endif
        } header: {
            Text("Downloads")
        } footer: {
            Text(
                "New Watch Later videos (up to 5 at a time, under 3 hours) are downloaded when you open the app. New upload alerts are local notifications for channels you follow in SmartTube and for your signed-in subscriptions. The optional yt-dlp server is your own machine running tools/ytdlp-server; use an https:// address (for example from Tailscale). Downloads are never deleted automatically."
            )
        }
    }
    #endif

    // MARK: - UI

    private enum ThumbnailStyle: Hashable {
        case standard, highResolution, compact
    }

    /// UI-only view over the two independent `compactThumbnails` / `highResThumbnails` flags.
    private var thumbnailStyle: Binding<ThumbnailStyle> {
        Binding(
            get: {
                if store.settings.compactThumbnails { return .compact }
                return store.settings.highResThumbnails ? .highResolution : .standard
            },
            set: { style in
                store.settings.compactThumbnails = style == .compact
                store.settings.highResThumbnails = style == .highResolution
            }
        )
    }

    private var uiSection: some View {
        @Bindable var store = store
        return Section("Interface") {
            #if os(tvOS)
            Toggle("Sidebar Home", isOn: $store.settings.useSidebarHome)
                .accessibilityIdentifier("settings.useSidebarHomeToggle")
            #endif
            SettingsPicker(
                "Theme", selection: $store.settings.themeName,
                options: AppSettings.ThemeName.allCases.map { .init(title: $0.rawValue, value: $0) }
            )
            .accessibilityIdentifier("settings.themeRow")
            SettingsPicker(
                "Accent Color", selection: $store.settings.accentColor,
                options: AppSettings.AccentColorChoice.allCases.map {
                    .init(title: $0.displayName, value: $0, icon: $0.swatch)
                }
            )
            .accessibilityIdentifier("settings.accentColorPicker")
            SettingsPicker(
                "Thumbnails", selection: thumbnailStyle,
                options: [
                    .init(title: "Standard", value: ThumbnailStyle.standard),
                    .init(title: "High Resolution", value: ThumbnailStyle.highResolution),
                    .init(title: "Compact", value: ThumbnailStyle.compact),
                ]
            )
            .accessibilityIdentifier("settings.thumbnailStylePicker")
            #if !os(tvOS)
            SettingsPicker(
                "Columns (Portrait)", selection: $store.settings.gridColumnsPortrait,
                options: AppSettings.availableGridColumnCounts.map { .init(title: "\($0)", value: $0) }
            )
            .disabled(store.settings.compactThumbnails)
            .accessibilityIdentifier("settings.gridColumnsPortraitPicker")
            SettingsPicker(
                "Columns (Landscape)", selection: $store.settings.gridColumnsLandscape,
                options: AppSettings.availableGridColumnCounts.map { .init(title: "\($0)", value: $0) }
            )
            .disabled(store.settings.compactThumbnails)
            .accessibilityIdentifier("settings.gridColumnsLandscapePicker")
            #endif
            Toggle("Hide Shorts", isOn: $store.settings.hideShorts)
                .accessibilityIdentifier("settings.hideShortsToggle")
            Toggle("Hide Live Shorts", isOn: $store.settings.hideLiveShorts)
                .accessibilityIdentifier("settings.hideLiveShortsToggle")
            Toggle("Hide Video Premieres", isOn: $store.settings.hideVideoPremieres)
                .accessibilityIdentifier("settings.hideVideoPremieresToggle")
            Toggle("Per-Device Recommendations", isOn: $store.settings.perDeviceRecommendationsEnabled)
                .accessibilityIdentifier("settings.perDeviceRecommendationsToggle")
            Toggle("Hide Watched Videos", isOn: $store.settings.hideWatchedVideos)
                .accessibilityIdentifier("settings.hideWatchedVideosToggle")
            if store.settings.hideWatchedVideos {
                #if os(tvOS)
                // tvOS has no Stepper.
                SettingsPicker(
                    "Watched threshold", selection: $store.settings.hideWatchedThreshold,
                    options: Array(stride(from: 50, through: 100, by: 5)).map {
                        .init(title: "\($0)%", value: Double($0) / 100)
                    }
                )
                .accessibilityIdentifier("settings.hideWatchedThresholdStepper")
                #else
                Stepper(
                    "Watched threshold: \(Int(store.settings.hideWatchedThreshold * 100))%",
                    value: $store.settings.hideWatchedThreshold, in: 0.5...1.0, step: 0.05
                )
                .accessibilityIdentifier("settings.hideWatchedThresholdStepper")
                #endif
            }
            #if os(iOS)
            if #available(iOS 26.0, *) {
                Toggle("Disable Liquid Glass", isOn: $store.settings.disableLiquidGlass)
                    .accessibilityIdentifier("settings.disableLiquidGlassToggle")
            }
            #endif
            NavigationLink("Visible Sections") {
                SectionsSettingsView()
                    .environment(store)
            }
            .accessibilityIdentifier("settings.visibleSectionsLink")
        }
    }

    // MARK: - SponsorBlock

    private var sponsorBlockSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Enable SponsorBlock", isOn: $store.settings.sponsorBlockEnabled)
                .accessibilityIdentifier("settings.sponsorBlockToggle")

            if store.settings.sponsorBlockEnabled {
                ForEach(SponsorSegment.Category.allCases, id: \.self) { cat in
                    HStack {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 10, height: 10)
                        SettingsPicker(
                            LocalizedStringKey(cat.displayName),
                            selection: Binding(
                                get: { store.settings.sponsorBlockActions[cat] ?? .nothing },
                                set: { store.settings.sponsorBlockActions[cat] = $0 }
                            ),
                            options: [
                                .init(title: "Skip", value: AppSettings.SponsorBlockAction.skip),
                                .init(title: "Show Toast", value: AppSettings.SponsorBlockAction.showToast),
                                .init(title: "Nothing", value: AppSettings.SponsorBlockAction.nothing),
                            ]
                        )
                        .accessibilityIdentifier("settings.sponsorBlock.\(cat.rawValue)")
                    }
                }

                // Minimum segment duration
                SettingsPicker(
                    "Min. Segment Length", selection: $store.settings.sponsorBlockMinSegmentDuration,
                    options: [
                        .init(title: "Off", value: 0.0),
                        .init(title: "1s", value: 1.0),
                        .init(title: "2s", value: 2.0),
                        .init(title: "5s", value: 5.0),
                        .init(title: "10s", value: 10.0),
                    ])

                // Excluded channels
                NavigationLink("Excluded Channels (\(store.settings.sponsorBlockExcludedChannels.count))") {
                    SponsorBlockExcludedChannelsView()
                }
                .accessibilityIdentifier("settings.sponsorBlockExcludedChannels")
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Skip \u{2014} auto-skips. Show Toast \u{2014} shows a skip button. Nothing \u{2014} plays through.")
        }
    }

    // MARK: - DeArrow

    private var deArrowSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Enable DeArrow", isOn: $store.settings.deArrowEnabled)
        } header: {
            Text("DeArrow")
        } footer: {
            Text("Replace clickbait titles and thumbnails with community-sourced alternatives.")
        }
    }

    // MARK: - Experimental (macOS)

    #if os(macOS)
    private var experimentalSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("IFrame Player (TOS-compliant, shows ads)", isOn: $store.settings.useTOSPlayerOnMac)
                .accessibilityIdentifier("settings.useTOSPlayerOnMacToggle")
        } header: {
            Text("Experimental")
        } footer: {
            Text(
                "Uses YouTube's official embedded player instead of the direct stream pipeline. Quality selection is unavailable. Ads will play. Useful for videos that refuse to play via the standard path."
            )
        }
    }
    #endif

    // MARK: - Experimental (tvOS)

    #if os(tvOS)
    private var experimentalSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("mpv Player", isOn: $store.settings.useMPVPlayerOnTV)
                .accessibilityIdentifier("settings.useMPVPlayerOnTVToggle")
        } header: {
            Text("Experimental")
        } footer: {
            Text(
                "Plays through mpv instead of the system player: opens YouTube's separate video and audio streams directly, including VP9. Chapters, the queue, autoplay and audio-track selection are not available in this player yet. Videos mpv cannot open can be played with the standard player."
            )
        }
    }
    #endif

    // MARK: - About

    private var aboutSection: some View {
        @Bindable var store = store
        return Section {
            LabeledContent("Version", value: appVersion)
            Toggle("Disable Analytics & Crash Reporting", isOn: $store.settings.disableAnalytics)
                .accessibilityIdentifier("settings.disableAnalyticsToggle")
            Text("Restart the app for this to take effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if os(tvOS)
            Button {
                showGithubQR = true
            } label: {
                Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            #else
            Link(destination: URL(string: "https://github.com/milika/SmartTubeIOS")!) {
                Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            #endif
            Button {
                CrashlyticsLogger.sendDiagnosticReport()
                reportSent = true
            } label: {
                if reportSent {
                    Label("Report Sent", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Send Diagnostic Report", systemImage: "ladybug")
                }
            }
            .disabled(reportSent || store.settings.disableAnalytics)
            .accessibilityIdentifier("settings.sendDiagnosticReportButton")
            Button("Reset All Settings", role: .destructive) { store.reset() }
                .accessibilityIdentifier("settings.resetAllButton")
        } header: {
            Text("About")
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - GitHubQRView (tvOS)

#if os(tvOS)
private struct GitHubQRView: View {
    @Environment(\.dismiss) private var dismiss

    private let githubURL = "https://github.com/milika/SmartTubeIOS"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)

                    Text("SmartTube on GitHub")
                        .font(.largeTitle).fontWeight(.bold)

                    Text("Scan the QR code with your phone to view the project on GitHub.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                QRCodeView(content: githubURL)
                    .frame(width: 280, height: 280)
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Text(githubURL)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
                    .font(.headline)
            }
            .padding(40)
        }
    }
}
#endif

// MARK: - SectionsSettingsView

/// Lets the user configure which sections appear in the sidebar / tab bar.
/// Mirrors Android's `MainUIData` section ordering/enabling UI.
struct SectionsSettingsView: View {
    @Environment(SettingsStore.self) private var store

    private let allSections = BrowseSection.allSections

    /// #156: visible sections in the user's own order (drag-to-reorder below), each
    /// resolved back to its `BrowseSection` for a title/icon.
    private var visibleSections: [BrowseSection] {
        store.settings.enabledSections.compactMap { type in allSections.first { $0.type == type } }
    }

    private var hiddenSections: [BrowseSection] {
        allSections.filter { !store.settings.enabledSections.contains($0.type) }
    }

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                ForEach(visibleSections) { section in
                    HStack {
                        Text(section.title)
                        Spacer()
                        Button {
                            // Don't allow disabling the last section.
                            guard store.settings.enabledSections.count > 1 else { return }
                            store.settings.enabledSections.removeAll { $0 == section.type }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.settings.enabledSections.count <= 1)
                    }
                }
                .onMove { offsets, destination in
                    store.settings.enabledSections.move(fromOffsets: offsets, toOffset: destination)
                }
            } header: {
                Text("Visible — drag to reorder")
            }

            if !hiddenSections.isEmpty {
                Section("Hidden") {
                    ForEach(hiddenSections) { section in
                        Button {
                            // Append to the end of the user's current order, rather than
                            // recomputing from canonical order, so re-enabling a section
                            // doesn't discard any reordering already done above.
                            store.settings.enabledSections.append(section.type)
                        } label: {
                            HStack {
                                Text(section.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Visible Sections")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - SponsorBlockExcludedChannelsView

/// Lists channels excluded from SponsorBlock processing.
/// Channels can be added from ChannelView and removed here via swipe-to-delete.
struct SponsorBlockExcludedChannelsView: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let sortedChannels = store.settings.sponsorBlockExcludedChannels
            .sorted { $0.value.localizedCompare($1.value) == .orderedAscending }
        return List {
            if sortedChannels.isEmpty {
                ContentUnavailableView(
                    "No Excluded Channels",
                    systemImage: "person.crop.circle.badge.minus",
                    description: Text(
                        "Open a channel and tap \u{201C}Exclude from SponsorBlock\u{201D} to add it here.")
                )
            } else {
                ForEach(sortedChannels, id: \.key) { channelId, title in
                    Text(title)
                }
                .onDelete { indices in
                    let ids = indices.map { sortedChannels[$0].key }
                    ids.forEach { store.settings.sponsorBlockExcludedChannels.removeValue(forKey: $0) }
                }
            }
        }
        .navigationTitle("Excluded Channels")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        #endif
    }
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
            .accessibilityIdentifier("settings.ytDlpModePicker")
            if store.settings.ytDlpMode != .off {
                TextField("Server URL", text: $urlText)
                    #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.ytDlpURLField")
                    .onChange(of: urlText) { _, text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.settings.ytDlpServerURL = URL(string: trimmed).flatMap {
                            $0.scheme != nil && $0.host != nil ? $0 : nil
                        }
                        testResult = nil
                    }
                SecureField("Token", text: $tokenText)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.ytDlpTokenField")
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
                .accessibilityIdentifier("settings.ytDlpTestButton")
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.ytDlpTestResult")
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
