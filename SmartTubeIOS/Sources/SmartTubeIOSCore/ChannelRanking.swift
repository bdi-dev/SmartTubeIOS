import Foundation

/// Orders a channel list so the channels the viewer watches most, and most recently, come first.
public enum ChannelRanking {
    /// How many channels are promoted above the alphabetical remainder.
    public static let topCount = 15

    /// `watchedChannelIds` is every watched video's channel id, most recent first (repeats
    /// allowed). Each watch scores `1 / (1 + position / 10)`, so frequency and recency both
    /// count. The top `topCount` scoring channels lead; the rest keep their incoming order.
    public static func ranked(_ channels: [Channel], watchedChannelIds: [String]) -> [Channel] {
        var scores: [String: Double] = [:]
        for (position, id) in watchedChannelIds.enumerated() {
            scores[id, default: 0] += 1.0 / (1.0 + Double(position) / 10.0)
        }
        let top = channels.filter { scores[$0.id] != nil }
            .sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
            .prefix(topCount)
        let topIds = Set(top.map(\.id))
        return Array(top) + channels.filter { !topIds.contains($0.id) }
    }
}
