import SmartTubeIOSCore
import SwiftUI

// MARK: - ChannelListView
//
// Displays the list of channels the authenticated user subscribes to.
// Shown when the "Channels" chip is selected in the Home chip bar.
// Mirrors the Android ChannelsBrowseFragment channel row layout.

struct ChannelListView: View {
    /// Frequently or recently watched channels, listed first under a "Frequent" header.
    let frequent: [Channel]
    /// Every other channel, listed under "All channels" when `frequent` is not empty.
    let others: [Channel]
    let onSelect: (Channel) -> Void

    var body: some View {
        #if os(tvOS)
        // A List with Button rows gets the standard tvOS row focus platter, sized to the row and
        // clipped inside it. A `.plain` Button in a ScrollView is the poster-style effect (about
        // 1.1x scale plus lift) and is meant for artwork, not for full-width rows; on a row it
        // produced a platter far larger than the content that overlapped its neighbours.
        let _ = print(
            "[CHANDIAG] ChannelListView body channels=\(frequent.count + others.count) uniqueIds=\(Set((frequent + others).map(\.id)).count)"
        )  // CHANDIAG (temporary)
        // Section headers are plain text and are not focusable, so focus still moves straight
        // from row to row. With no frequent group there is one headerless section.
        List {
            if frequent.isEmpty {
                Section {
                    tvRows(others)
                }
            } else {
                Section {
                    tvRows(frequent)
                } header: {
                    Text("Frequent")
                }
                Section {
                    tvRows(others)
                } header: {
                    Text("All channels")
                }
            }
        }
        .listStyle(.plain)
        .focusSection()
        #else
        ScrollView {
            LazyVStack(spacing: 0) {
                if !frequent.isEmpty {
                    groupHeader("Frequent")
                }
                ForEach(frequent) { channel in
                    phoneRow(channel)
                }
                if !frequent.isEmpty {
                    groupHeader("All channels")
                }
                ForEach(others) { channel in
                    phoneRow(channel)
                }
            }
        }
        #endif
    }

    #if os(tvOS)
    private func tvRows(_ channels: [Channel]) -> some View {
        ForEach(channels) { channel in
            Button {
                onSelect(channel)
            } label: {
                ChannelListRow(channel: channel)
            }
        }
    }
    #else
    private func phoneRow(_ channel: Channel) -> some View {
        VStack(spacing: 0) {
            // A Button, not onTapGesture, so VoiceOver announces it as a button and the whole
            // row is the activation target.
            Button {
                onSelect(channel)
            } label: {
                ChannelListRow(channel: channel)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Leading inset = row padding (16) + avatar (48) + spacing (12): starts under the name.
            Divider()
                .padding(.leading, 76)
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
    #endif
}

// MARK: - ChannelListRow

private struct ChannelListRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            avatar
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title.isEmpty ? "Unknown channel" : channel.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let count = channel.subscriberCount {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        // One VoiceOver element per channel: "name, subscribers", not each text run.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = channel.thumbnailURL {
            #if canImport(UIKit)
            CachedAvatarImage(url: url, size: 48) { avatarPlaceholder }
            #else
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                default:
                    avatarPlaceholder
                }
            }
            .frame(width: 48, height: 48)
            #endif
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 48, height: 48)
            .overlay(
                Image(systemName: AppSymbol.personCircle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            )
    }
}
