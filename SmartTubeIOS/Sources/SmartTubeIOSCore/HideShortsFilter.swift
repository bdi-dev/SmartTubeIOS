import InnerTubeKit

// MARK: - Hide Shorts filter
//
// The Hide Shorts setting applies to every feed-style list, History included. It does not
// apply to a channel page's Shorts tab, which is a browse list of the channel's own Shorts
// and is not filtered by the setting.

extension Array where Element == Video {
    /// The list with Shorts removed when `hideShorts` is on; unchanged otherwise.
    public func removingShorts(if hideShorts: Bool) -> [Video] {
        hideShorts ? filter { !$0.isShort } : self
    }
}
