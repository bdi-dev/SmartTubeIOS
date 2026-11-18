#if os(tvOS)
import SmartTubeIOSCore
import SwiftUI

// MARK: - TVSidebarRootView
//
// tvOS top-level layout that replaces the top tab bar (`MainTVTabView`) when
// `AppSettings.useSidebarHome` is on (the default on tvOS). A left sidebar lists Search,
// every enabled browse section (History and Playlists are separate items), Settings and
// Account. The chosen item fills the content column on the right.
//
// The sidebar is 300 pt wide while focus is inside it and an icon rail (100 pt) otherwise.
// The content column always keeps the rail width and the expanded sidebar overlays it, so
// the grid does not reflow while focus moves.

/// One row of the tvOS sidebar. `.account` is an action, never a selected destination.
enum TVSidebarItem: Hashable {
    case search
    case section(BrowseSection)
    case settings
    case account
}

private enum TVSidebarLayout {
    static let railWidth: CGFloat = 100
    static let expandedWidth: CGFloat = 300
}

struct TVSidebarRootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(\.innerTubeAPI) private var api
    @State private var searchVM = SearchViewModel()
    @State private var selection: TVSidebarItem = .section(BrowseSection(type: .home))
    @State private var showSignIn = false
    @FocusState private var focusedItem: TVSidebarItem?

    /// Browse sections in the order the settings list them (same list as the old chip bar).
    private var sections: [BrowseSection] { HomeView.visibleSections(for: store.settings) }

    private var items: [TVSidebarItem] {
        [.search] + sections.map { .section($0) } + [.settings, .account]
    }

    private var isExpanded: Bool { focusedItem != nil }

    var body: some View {
        @Bindable var browseVM = browseVM
        ZStack(alignment: .leading) {
            content
                .padding(.leading, TVSidebarLayout.railWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            sidebar
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .environment(searchVM)
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onChange(of: items) { _, newItems in
            // A section hidden in Settings can no longer be selected; fall back to the first one.
            if !newItems.contains(selection) {
                selection = sections.first.map { .section($0) } ?? .search
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .activeChannelDidChange) {
                selection = .section(BrowseSection(type: .home))
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .navigateToSearch) {
                selection = .search
            }
        }
        // Deep link: a video named from outside the browse UI opens straight in the player.
        .fullScreenCover(item: $browseVM.deepLinkedVideo) { video in
            PlayerScreen(video: video, api: api)
        }
    }

    // MARK: - Content column

    private var content: some View {
        NavigationStack {
            switch selection {
            case .section(let section):
                HomeView(api: api, initialSection: section)
                    // A new section gets a fresh view (and feed) rather than swapping state inside
                    // one HomeView, which keeps pagination and load triggers per section.
                    .id(section.id)
            case .search:
                SearchView()
            case .settings:
                SettingsView()
            case .account:
                EmptyView()
            }
        }
        // Menu/Back from the content column returns focus to the selected sidebar item.
        .onExitCommand { focusedItem = selection }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(.search, title: String(localized: "Search", bundle: .module), symbol: AppSymbol.search)
            ForEach(sections) { section in
                row(.section(section), title: section.title, symbol: section.type.sidebarSymbol)
            }
            row(.settings, title: String(localized: "Settings", bundle: .module), symbol: AppSymbol.settings)
            Spacer(minLength: 0)
            accountRow
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 12)
        .frame(width: isExpanded ? TVSidebarLayout.expandedWidth : TVSidebarLayout.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .focusSection()
        .defaultFocus($focusedItem, selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv.sidebar")
    }

    private func row(_ item: TVSidebarItem, title: String, symbol: String) -> some View {
        let isSelected = selection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 36)
                if isExpanded {
                    Text(verbatim: title)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isSelected ? Color.primary.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.borderless)
        .focused($focusedItem, equals: item)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("tv.sidebar.\(item.identifierSuffix)")
    }

    /// Signed out: opens the sign-in sheet. Signed in: opens Settings, where the account
    /// details and sign-out live.
    private var accountRow: some View {
        Button {
            if auth.isSignedIn {
                selection = .settings
            } else {
                showSignIn = true
            }
        } label: {
            HStack(spacing: 16) {
                AsyncImage(url: auth.accountAvatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: AppSymbol.personCircle)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                if isExpanded {
                    if auth.isSignedIn {
                        Text(verbatim: auth.accountName ?? String(localized: "Account", bundle: .module))
                            .font(.headline)
                            .lineLimit(1)
                    } else {
                        Text("Sign In", bundle: .module)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderless)
        .focused($focusedItem, equals: .account)
        .accessibilityLabel(
            auth.isSignedIn
                ? Text(verbatim: auth.accountName ?? String(localized: "Account", bundle: .module))
                : Text("Sign In", bundle: .module)
        )
        .accessibilityIdentifier("tv.sidebar.account")
    }
}

// MARK: - Helpers

extension TVSidebarItem {
    /// Stable suffix for `tv.sidebar.<suffix>` accessibility identifiers.
    fileprivate var identifierSuffix: String {
        switch self {
        case .search: return "search"
        case .section(let section): return section.type.rawValue
        case .settings: return "settings"
        case .account: return "account"
        }
    }
}

extension BrowseSection.SectionType {
    /// SF Symbol shown in the sidebar for this section.
    fileprivate var sidebarSymbol: String {
        switch self {
        case .home: return AppSymbol.home
        case .recommended: return AppSymbol.trending
        case .subscriptions: return AppSymbol.subscriptions
        case .history: return AppSymbol.history
        case .playlists: return AppSymbol.playlists
        case .channels: return AppSymbol.channel
        case .shorts: return AppSymbol.shorts
        case .music: return AppSymbol.music
        case .news: return AppSymbol.news
        case .gaming: return AppSymbol.gaming
        case .live: return AppSymbol.live
        case .sports: return AppSymbol.sports
        case .watchLater: return AppSymbol.watchLater
        case .settings: return AppSymbol.settings
        }
    }
}
#endif
