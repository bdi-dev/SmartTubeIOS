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
// The sidebar is an icon rail while focus is in the content and expands to show labels when
// focus enters it. The content column keeps one layout size and slides (and dims) to make
// room, so the grid does not reflow while the sidebar animates. While a player is on screen
// the sidebar is hidden and the content fills the screen.

/// One row of the tvOS sidebar. `.account` is an action, never a selected destination.
enum TVSidebarItem: Hashable {
    case search
    case section(BrowseSection)
    case settings
    case account
}

private enum TVSidebarLayout {
    /// Total width of the collapsed rail, from the screen edge: leading margin, a 72 pt row
    /// (40 pt icon plus its padding) and trailing padding. This is both the width the sidebar
    /// draws and the slot reserved for it, so nothing is ever drawn under the rail.
    static let railWidth: CGFloat = 128
    static let expandedWidth: CGFloat = 440
    /// Gap between the rail's edge and the content. Grids add no padding of their own on tvOS.
    static let contentLeadingGap: CGFloat = 56
    /// Margin to the screen edge. The sidebar sits inside the 80 pt tvOS safe area on purpose.
    static let leadingMargin: CGFloat = 40
}

// MARK: - Player visibility
//
// Players are pushed inside the content column's NavigationStack (HomeView, SearchView,
// playlists, channels). `PlayerScreen` reports through this binding so the sidebar can get
// out of the way and the player fills the whole screen.

private struct TVPlayerPresentedKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}

extension EnvironmentValues {
    var tvPlayerPresented: Binding<Bool>? {
        get { self[TVPlayerPresentedKey.self] }
        set { self[TVPlayerPresentedKey.self] = newValue }
    }
}

struct TVSidebarRootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(\.innerTubeAPI) private var api
    @State private var searchVM = SearchViewModel()
    @State private var selection: TVSidebarItem = .section(BrowseSection(type: .home))
    @State private var showSignIn = false
    @State private var playerPresented = false
    @FocusState private var focusedItem: TVSidebarItem?
    /// True while focus is somewhere in the content column. Preferred at launch so the app
    /// opens on the selected section instead of the sidebar's first row.
    @FocusState private var contentFocused: Bool

    /// Browse sections in the order the settings list them (same list as the old chip bar).
    private var sections: [BrowseSection] { HomeView.visibleSections(for: store.settings) }

    private var isExpanded: Bool { focusedItem != nil && !playerPresented }

    var body: some View {
        @Bindable var browseVM = browseVM
        // The sidebar and the content are siblings. The sidebar's layout width is always the
        // rail; when expanded it draws wider than that and the content slides right by the
        // difference. The content keeps one layout size, so the grid reflows once (when the
        // sidebar appears or disappears for the player), never while the sidebar animates.
        HStack(spacing: 0) {
            sidebar
                .frame(width: playerPresented ? 0 : TVSidebarLayout.railWidth, alignment: .leading)
                .opacity(playerPresented ? 0 : 1)
                .disabled(playerPresented)
                .zIndex(1)
            content
                .padding(.leading, TVSidebarLayout.contentLeadingGap)
                .offset(x: isExpanded ? TVSidebarLayout.expandedWidth - TVSidebarLayout.railWidth : 0)
                .opacity(isExpanded ? 0.5 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                .focused($contentFocused)
        }
        .defaultFocus($contentFocused, true)
        // The rail sits close to the screen edge instead of inside the 80 pt tvOS safe area;
        // otherwise that inset stacks on top of the rail and the content's own padding.
        .ignoresSafeArea(.container, edges: .leading)
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
        .environment(searchVM)
        .environment(\.tvPlayerPresented, $playerPresented)
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onChange(of: sections) { _, newSections in
            // A section hidden in Settings can no longer be selected; fall back to the first one.
            if case .section(let current) = selection, !newSections.contains(current) {
                selection = newSections.first.map { .section($0) } ?? .search
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
        // A root-level cover sits above the sidebar.
        .fullScreenCover(item: $browseVM.deepLinkedVideo) { video in
            PlayerScreen(video: video, api: api)
        }
    }

    // MARK: - Content column

    private var content: some View {
        NavigationStack {
            Group {
                switch selection {
                case .section(let section):
                    HomeView(api: api, initialSection: section)
                case .search:
                    SearchView()
                case .settings:
                    SettingsView()
                case .account:
                    EmptyView()
                }
            }
            // On the stack's root view (not the stack) so it only fires while a root screen has
            // focus: pushed screens and the player handle Back themselves and pop normally.
            // Back at the top of the content moves focus to the selected sidebar row; Back
            // there is not handled and exits the app.
            .onExitCommand { focusedItem = selection }
        }
        // A different destination gets a fresh stack (and feed) so pushes and pagination state
        // never leak between sections.
        .id(selection)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(.search, title: String(localized: "Search", bundle: .module), symbol: AppSymbol.search)
            ForEach(sections) { section in
                row(.section(section), title: section.title, symbol: section.type.sidebarSymbol)
            }
            row(.settings, title: String(localized: "Settings", bundle: .module), symbol: AppSymbol.settings)
            Spacer(minLength: 0)
            accountRow
        }
        .padding(.vertical, 40)
        .padding(.leading, TVSidebarLayout.leadingMargin)
        .padding(.trailing, 16)
        .frame(width: isExpanded ? TVSidebarLayout.expandedWidth : TVSidebarLayout.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv.sidebar")
    }

    private func row(_ item: TVSidebarItem, title: String, symbol: String) -> some View {
        let isSelected = selection == item
        return Button {
            selection = item
        } label: {
            TVSidebarRowLabel(title: title, showsTitle: isExpanded) {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(TVSidebarRowStyle(isSelected: isSelected))
        .focused($focusedItem, equals: item)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("tv.sidebar.\(item.identifierSuffix)")
    }

    /// Signed out: opens the sign-in sheet. Signed in: opens Settings, where the account
    /// details and sign-out live.
    private var accountRow: some View {
        let title = auth.isSignedIn
            ? (auth.accountName ?? String(localized: "Account", bundle: .module))
            : String(localized: "Sign In", bundle: .module)
        return Button {
            if auth.isSignedIn {
                selection = .settings
            } else {
                showSignIn = true
            }
        } label: {
            TVSidebarRowLabel(title: title, showsTitle: isExpanded) {
                AsyncImage(url: auth.accountAvatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: AppSymbol.personCircle)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            }
        }
        .buttonStyle(TVSidebarRowStyle(isSelected: false))
        .focused($focusedItem, equals: .account)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier("tv.sidebar.account")
    }
}

// MARK: - Row appearance

/// Icon and label of a sidebar row. Both inherit the colour and weight set by
/// `TVSidebarRowStyle`, so they always look the same.
private struct TVSidebarRowLabel<Icon: View>: View {
    let title: String
    let showsTitle: Bool
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 18) {
            icon()
                .frame(width: 40, height: 40)
            if showsTitle {
                Text(verbatim: title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// One focus treatment for the whole row: a rounded highlight behind icon and label, both
/// switching to the same colour. The selected row that is not focused gets a quiet tint.
private struct TVSidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.92) : (isSelected ? Color.primary.opacity(0.16) : Color.clear))
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
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
