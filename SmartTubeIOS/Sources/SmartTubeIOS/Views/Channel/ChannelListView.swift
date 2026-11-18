import SmartTubeIOSCore
import SwiftUI

// MARK: - ChannelListView
//
// Displays the list of channels the authenticated user subscribes to.
// Shown when the "Channels" chip is selected in the Home chip bar.
// Mirrors the Android ChannelsBrowseFragment channel row layout.

struct ChannelListView: View {
    let channels: [Channel]
    let onSelect: (Channel) -> Void

    var body: some View {
        #if os(tvOS)
        // A List with Button rows gets the standard tvOS row focus platter, sized to the row and
        // clipped inside it. A `.plain` Button in a ScrollView is the poster-style effect (about
        // 1.1x scale plus lift) and is meant for artwork, not for full-width rows; on a row it
        // produced a platter far larger than the content that overlapped its neighbours.
        List {
            ForEach(channels) { channel in
                Button {
                    onSelect(channel)
                } label: {
                    ChannelListRow(channel: channel)
                }
            }
        }
        .listStyle(.plain)
        .focusSection()
        #else
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(channels) { channel in
                    ChannelListRow(channel: channel)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(channel) }
                    Divider()
                        .padding(.leading, 72)
                }
            }
        }
        #endif
    }
}

// MARK: - ChannelListRow

private struct ChannelListRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            avatar
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
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = channel.thumbnailURL {
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
