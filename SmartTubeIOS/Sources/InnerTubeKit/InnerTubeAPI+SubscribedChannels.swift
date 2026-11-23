import Foundation

// MARK: - Subscribed channel list sources
//
// The TV guide sidebar is not guaranteed to carry the whole subscription list: YouTube
// collapses it behind a "Show more" entry and may move the rest elsewhere. The TV client's
// dedicated channel list (`browseId` "FEchannels") lists every subscribed channel as
// `TILE_CONTENT_TYPE_CHANNEL` tiles and pages through continuations, so it is the primary
// source; the guide is merged in (it carries avatars) and the video-tile feed remains the
// last resort.

/// Result of one walk over a guide response: channels plus what the response said about
/// collapsed / paged subscription entries (used for diagnostics).
struct GuideChannelScan {
    var channels: [Channel]
    var collapsibleEntries: Int
    var expandableItemEntries: Int
    var hasContinuation: Bool
}

extension InnerTubeAPI {

    /// Upper bound on FEchannels pages (about 20-30 tiles each) so a misbehaving
    /// continuation loop can never spin forever.
    static let maxChannelListPages = 40

    /// Parses `TILE_CONTENT_TYPE_CHANNEL` tiles (and WEB channel renderers) from a TV
    /// browse response, in response order, de-duplicated by channel id.
    func parseChannelListTiles(from json: [String: Any]) -> [Channel] {
        var channels: [Channel] = []
        var seen = Set<String>()

        func add(_ channel: Channel?) {
            guard let channel, seen.insert(channel.id).inserted else { return }
            channels.append(channel)
        }

        func fromTile(_ tile: [String: Any]) -> Channel? {
            guard (tile["contentType"] as? String) == "TILE_CONTENT_TYPE_CHANNEL" else { return nil }
            let select = tile["onSelectCommand"] as? [String: Any]
            let id: String? =
                (select?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
                ?? ((select?["innertubeCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"]
                as? String
                ?? ((tile["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"]
                as? String
            guard let id, !id.isEmpty else { return nil }
            let meta = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
            let title = (meta?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
            let header = (tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any]
            let thumb = ((header?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
            return Channel(id: id, title: title, thumbnailURL: thumb)
        }

        func fromRenderer(_ r: [String: Any]) -> Channel? {
            guard let id = r["channelId"] as? String, !id.isEmpty else { return nil }
            let title = (r["title"] as? [String: Any]).flatMap { extractText($0) } ?? (r["title"] as? String) ?? ""
            let thumb = ((r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
            return Channel(id: id, title: title, thumbnailURL: thumb)
        }

        func walk(_ obj: Any, _ depth: Int) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let tile = dict["tileRenderer"] as? [String: Any] {
                    if let c = fromTile(tile) {
                        add(c)
                        return
                    }
                }
                for key in ["channelRenderer", "gridChannelRenderer", "compactChannelRenderer"] {
                    if let r = dict[key] as? [String: Any], let c = fromRenderer(r) {
                        add(c)
                        return
                    }
                }
                for v in dict.values { walk(v, depth + 1) }
            } else if let arr = obj as? [Any] {
                for v in arr { walk(v, depth + 1) }
            }
        }
        walk(json, 0)
        return channels
    }

    /// The first continuation token anywhere in a browse response.
    func findContinuationToken(in json: [String: Any]) -> String? {
        func walk(_ obj: Any, _ depth: Int) -> String? {
            guard depth < 50 else { return nil }
            if let dict = obj as? [String: Any] {
                if let next = dict["nextContinuationData"] as? [String: Any],
                    let t = next["continuation"] as? String, !t.isEmpty
                {
                    return t
                }
                if let cmd = dict["continuationCommand"] as? [String: Any],
                    let t = cmd["token"] as? String, !t.isEmpty
                {
                    return t
                }
                for v in dict.values { if let t = walk(v, depth + 1) { return t } }
            } else if let arr = obj as? [Any] {
                for v in arr { if let t = walk(v, depth + 1) { return t } }
            }
            return nil
        }
        return walk(json, 0)
    }

    /// Scans a /guide response: channels (including those inside collapsed
    /// `guideCollapsibleEntryRenderer.expandableItems`, which `parseGuideChannels` walks
    /// because it visits every nested object) plus signals about collapsed sections.
    func scanGuide(_ json: [String: Any]) -> GuideChannelScan {
        var collapsible = 0
        var expandable = 0
        var continuation = false
        func walk(_ obj: Any, _ depth: Int) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if dict["guideCollapsibleEntryRenderer"] != nil { collapsible += 1 }
                if let items = dict["expandableItems"] as? [Any] { expandable += items.count }
                if dict["nextContinuationData"] != nil || dict["continuationCommand"] != nil { continuation = true }
                for v in dict.values { walk(v, depth + 1) }
            } else if let arr = obj as? [Any] {
                for v in arr { walk(v, depth + 1) }
            }
        }
        walk(json, 0)
        return GuideChannelScan(
            channels: parseGuideChannels(from: json),
            collapsibleEntries: collapsible,
            expandableItemEntries: expandable,
            hasContinuation: continuation)
    }

    /// Merges channel lists by id: first-seen order, a later non-empty title or avatar fills
    /// a gap, result sorted alphabetically (same ordering the guide parser used).
    nonisolated static func mergeChannelLists(_ lists: [[Channel]]) -> [Channel] {
        var byId: [String: Channel] = [:]
        var order: [String] = []
        for list in lists {
            for c in list {
                if var existing = byId[c.id] {
                    if existing.title.isEmpty { existing.title = c.title }
                    if existing.thumbnailURL == nil { existing.thumbnailURL = c.thumbnailURL }
                    byId[c.id] = existing
                } else {
                    byId[c.id] = c
                    order.append(c.id)
                }
            }
        }
        var merged = order.compactMap { byId[$0] }
        merged.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return merged
    }

    /// Pages through the TV client's dedicated channel list. Returns whatever was collected
    /// if a later page fails (a partial list beats none); throws only when page 1 fails.
    func fetchChannelListPaged() async throws -> (channels: [Channel], pages: Int, truncated: Bool) {
        var all: [[Channel]] = []
        var token: String?
        var pages = 0
        var truncated = false
        while pages < Self.maxChannelListPages {
            var body = makeBody(client: tvClientContext, continuationToken: token)
            if token == nil { body["browseId"] = "FEchannels" }
            let data: [String: Any]
            do {
                data = try await postTV(endpoint: "browse", body: body)
            } catch {
                if pages == 0 { throw error }
                truncated = true
                break
            }
            pages += 1
            let page = parseChannelListTiles(from: data)
            all.append(page)
            let next = findContinuationToken(in: data)
            if page.isEmpty || next == nil || next == token { break }
            token = next
        }
        if pages >= Self.maxChannelListPages { truncated = true }
        return (InnerTubeAPI.mergeChannelLists(all), pages, truncated)
    }
}
