import SmartTubeIOSCore
import SwiftUI

// MARK: - ChannelView
//
// Displays channel info, subscriber count and a grid of recent uploads.
// Mirrors the Android `ChannelFragment`.

// MARK: - ChannelFilter

private enum ChannelFilter: String, CaseIterable {
    case all = "All"
    case shorts = "Shorts"
}

public struct ChannelView: View {
    public let channelId: String
    @State private var vm = ChannelViewModel()
    @State private var selectedVideo: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var filter: ChannelFilter = .all
    @State private var isFollowedLocally = false
    @Environment(SettingsStore.self) private var store
    @Environment(AuthService.self) private var auth
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.isLandscapeLayout) private var isLandscapeLayout
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init(channelId: String) {
        self.channelId = channelId
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.channel == nil {
                ProgressView("Loading channel…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(tvOS)
                    // Keeps focus in the page while it loads. With nothing focusable here the
                    // focus engine moves focus to the sidebar, and it stays there once the
                    // channel's buttons and grid appear.
                    .focusable()
                    #endif
                    .accessibilityIdentifier("channel.view")
            } else {
                content
            }
        }
        .navigationTitle(vm.channel?.title ?? "Channel")
        #if os(tvOS)
        // The header names the channel; the navigation bar would repeat it (and show the
        // SponsorBlock button as an unlabeled round control), so it is hidden on tvOS.
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear { vm.load(channelId: channelId) }
        .task(id: vm.channel?.id) {
            guard let id = vm.channel?.id else { return }
            isFollowedLocally = await LocalSubscriptionStore.shared.isFollowing(id)
        }
        #if !os(iOS) && !os(macOS)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerScreen(video: video, api: api)
        }
        #endif
        #if os(macOS)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        #if !os(macOS)
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex, api: api)
        }
        #endif
        .alert("Error", isPresented: .constant(vm.error != nil), presenting: vm.error) { _ in
            Button("Retry") { vm.load(channelId: channelId) }
            Button("Dismiss", role: .cancel) {}
        } message: { err in
            Text(err.localizedDescription)
        }
        #if !os(tvOS)
        .toolbar {
            if let channel = vm.channel {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Remove SponsorBlock Exclusion" : "Exclude from SponsorBlock",
                            systemImage: isExcluded
                                ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus"
                        )
                    }
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Remove SponsorBlock Exclusion" : "Exclude from SponsorBlock",
                            systemImage: isExcluded
                                ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus"
                        )
                    }
                    .accessibilityIdentifier("channel.sponsorBlockButton")
                }
                #endif
            }
        }
        #endif
    }

    private var content: some View {
        #if os(tvOS)
        tvContent
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Channel header
                if let channel = vm.channel {
                    channelHeader(channel)
                }

                // All / Shorts filter
                Picker("Filter", selection: $filter) {
                    ForEach(ChannelFilter.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .accessibilityIdentifier("channel.filterPicker")

                let filtered = filteredVideos
                if filter == .shorts {
                    if filtered.isEmpty && !vm.isLoading {
                        noShortsMessage
                    } else {
                        shortsGrid(filtered)
                    }
                } else {
                    videosGrid(filtered)
                }

                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .refreshable { vm.load(channelId: channelId) }
        .accessibilityIdentifier("channel.view")
        #endif
    }

    private var noShortsMessage: some View {
        ContentUnavailableView(
            "No Shorts",
            systemImage: "play.rectangle.on.rectangle",
            description: Text("This channel hasn't posted any Shorts, or they couldn't be loaded.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityIdentifier("channel.noShorts")
    }

    #if os(tvOS)
    // MARK: - tvOS layout
    //
    // One scrolling column: header (avatar, name, subscriber count, description, actions), the
    // All / Shorts tab control, then the same grid Home uses (`VideoGridSection`: 4 columns,
    // 40 pt spacing, system safe area plus the sidebar's leading content margin).

    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let channel = vm.channel {
                    tvChannelHeader(channel)
                }

                Picker("Filter", selection: $filter) {
                    ForEach(ChannelFilter.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("channel.filterPicker")

                if filter == .shorts {
                    if vm.shorts.isEmpty && !vm.isLoading {
                        noShortsMessage
                    } else {
                        tvShortsGrid(vm.shorts)
                    }
                } else {
                    VideoGridSection(
                        videos: filteredVideos,
                        onSelect: { selectedVideo = $0 },
                        loadMore: { vm.loadMore() }
                    )
                }

                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityIdentifier("channel.view")
    }

    private func tvChannelHeader(_ channel: Channel) -> some View {
        HStack(alignment: .top, spacing: 40) {
            AsyncImage(url: channel.thumbnailURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 160, height: 160)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 12) {
                Text(channel.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .accessibilityIdentifier("channel.title")
                if let subs = channel.subscriberCount, !subs.isEmpty {
                    Text(subs)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 24) {
                    if !auth.isSignedIn {
                        Button {
                            Task { await toggleFollow(channel) }
                        } label: {
                            Label(
                                isFollowedLocally ? "Unfollow" : "Follow",
                                systemImage: isFollowedLocally ? "bell.slash" : "bell"
                            )
                        }
                        .accessibilityIdentifier("channel.followButton")
                    }
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Remove SponsorBlock Exclusion" : "Exclude from SponsorBlock",
                            systemImage: isExcluded
                                ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus"
                        )
                    }
                    .accessibilityIdentifier("channel.sponsorBlockButton")
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channel.header")
    }

    /// Shorts are portrait (9:16): five per row. Rows of `HStack`, not `LazyVGrid`, because the
    /// tvOS focus engine cannot reach cells a lazy grid has not laid out (see `VideoGridSection`).
    private func tvShortsGrid(_ videos: [Video]) -> some View {
        let columnCount = 5
        return LazyVStack(alignment: .leading, spacing: videoGridRowSpacing) {
            ForEach(Array(stride(from: 0, to: videos.count, by: columnCount)), id: \.self) { startIdx in
                HStack(alignment: .top, spacing: videoGridRowSpacing) {
                    ForEach(0..<columnCount, id: \.self) { offset in
                        if startIdx + offset < videos.count {
                            let video = videos[startIdx + offset]
                            Button {
                                selectShort(video, from: videos)
                            } label: {
                                ShortsCardView(video: video, onTap: { selectShort(video, from: videos) })
                                    .aspectRatio(9 / 16, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("shorts.card.\(video.id)")
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .focusSection()
        .accessibilityIdentifier("channel.videoGrid")
    }
    #endif

    // MARK: - Filtered data

    private var filteredVideos: [Video] {
        switch filter {
        case .all: return vm.videos.filter { !store.settings.hideShorts || !$0.isShort }
        case .shorts: return vm.shorts
        }
    }

    // MARK: - Grid layouts (iOS, macOS; tvOS uses `tvContent`)

    #if !os(tvOS)
    private func videosGrid(_ videos: [Video]) -> some View {
        let compact = store.settings.compactThumbnails
        return Group {
            if compact {
                LazyVStack(spacing: 0) {
                    ForEach(videos) { video in
                        VideoCardView(video: video, compact: true)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                #if os(iOS)
                                playerRouter.open(video: video, api: api)
                                #else
                                selectedVideo = video
                                #endif
                            }
                            .onAppear {
                                if video.id == vm.videos.last?.id { vm.loadMore() }
                            }
                        Divider().padding(.horizontal)
                    }
                }
            } else {
                LazyVGrid(
                    columns: videoGridColumns(store.settings, landscape: isLandscapeLayout),
                    spacing: videoGridRowSpacing
                ) {
                    ForEach(videos) { video in
                        VideoCardView(video: video, compact: false)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                #if os(iOS)
                                playerRouter.open(video: video, api: api)
                                #else
                                selectedVideo = video
                                #endif
                            }
                            .onAppear {
                                if video.id == vm.videos.last?.id { vm.loadMore() }
                            }
                    }
                }
                .id(isLandscapeLayout)  // reset on column-count change — see VideoGridSection (#82)
                .padding()
            }
        }
    }

    private func shortsGrid(_ videos: [Video]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(videos) { video in
                VideoCardView(video: video)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .onTapGesture { selectShort(video, from: videos) }
            }
        }
        .padding(.horizontal)
        .accessibilityIdentifier("channel.videoGrid")
    }

    #endif

    private func selectShort(_ video: Video, from videos: [Video]) {
        let idx = videos.firstIndex(where: { $0.id == video.id }) ?? 0
        shortsPresentation = ShortsPresentation(videos: videos, startIndex: idx)
    }

    private func toggleSponsorBlockExclusion(for channel: Channel) {
        if store.settings.sponsorBlockExcludedChannels[channel.id] != nil {
            store.settings.sponsorBlockExcludedChannels.removeValue(forKey: channel.id)
        } else {
            store.settings.sponsorBlockExcludedChannels[channel.id] = channel.title
        }
    }

    private func channelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: channel.thumbnailURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.3))
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("channel.title")
                if let subs = channel.subscriberCount {
                    Text(subs)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !auth.isSignedIn {
                Button {
                    Task { await toggleFollow(channel) }
                } label: {
                    Label(
                        isFollowedLocally ? "Unfollow" : "Follow",
                        systemImage: isFollowedLocally ? "bell.slash" : "bell"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("channel.followButton")
            }
        }
        .padding()
        .background(.background)
        .accessibilityIdentifier("channel.header")
    }

    private func toggleFollow(_ channel: Channel) async {
        if isFollowedLocally {
            await LocalSubscriptionStore.shared.unfollow(channelId: channel.id)
            isFollowedLocally = false
        } else {
            let local = LocalChannel(
                id: channel.id,
                title: channel.title,
                thumbnailURL: channel.thumbnailURL
            )
            await LocalSubscriptionStore.shared.follow(local)
            isFollowedLocally = true
        }
    }
}
