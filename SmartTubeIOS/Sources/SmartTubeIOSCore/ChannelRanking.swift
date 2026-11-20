import Foundation

/// Orders a channel list so the channels the viewer watches most, and most recently, come first.
public enum ChannelRanking {
    /// How many channels are promoted above the alphabetical remainder.
    public static let topCount = 15

    /// `watchedChannelIds` is every watched video's channel id, most recent first (repeats
    /// allowed). Each watch scores `1 / (1 + position / 10)`, so frequency and recency both
    /// count. The top `topCount` scoring channels lead; the rest keep their incoming order.
    public static func ranked(_ channels: [Channel], watchedChannelIds: [String]) -> [Channel] {
        let groups = split(channels, watchedChannelIds: watchedChannelIds)
        return groups.frequent + groups.rest
    }

    /// The same ranking as `ranked`, returned as the promoted group and the remainder so the
    /// view can show where the frequent channels end.
    public static func split(
        _ channels: [Channel],
        watchedChannelIds: [String]
    ) -> (frequent: [Channel], rest: [Channel]) {
        var scores: [String: Double] = [:]
        for (position, id) in watchedChannelIds.enumerated() {
            scores[id, default: 0] += 1.0 / (1.0 + Double(position) / 10.0)
        }
        let top = Array(channels.filter { scores[$0.id] != nil }
            .sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
            .prefix(topCount))
        let topIds = Set(top.map(\.id))
        return (top, channels.filter { !topIds.contains($0.id) })
    }
}
