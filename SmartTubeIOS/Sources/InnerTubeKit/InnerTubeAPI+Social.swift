import Foundation
import os

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - Social interaction endpoints (like/dislike, next, comments)

extension InnerTubeAPI {

    // MARK: - Like / Dislike

    /// Sends a like for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.LIKE`.
    public func like(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/like", body: body)
    }

    /// Sends a dislike for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.DISLIKE`.
    public func dislike(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/dislike", body: body)
    }

    /// Removes any existing like or dislike for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.REMOVE_LIKE`.
    public func removeLike(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/removelike", body: body)
    }

    /// Adds a video to the authenticated user's Watch Later playlist (id "WL").
    /// Uses the TVHTML5 client's `browse_edit_playlist` endpoint with ACTION_ADD_VIDEO,
    /// mirroring the Android SmartTube `PlaylistPresenter` → `ACTION_ADD_VIDEO` flow.
    /// Requires authentication.
    ///
    /// Returns the new entry's `setVideoId` when the response carries one
    /// (`playlistEditResults[].playlistEditVideoAddedResultData.setVideoId`), so a video shown
    /// in the Watch Later list before YouTube's index catches up can still be removed (#157).
    @discardableResult
    public func addToWatchLater(videoId: String) async throws -> String? {
        var body = makeBody(client: tvClientContext)
        body["playlistId"] = "WL"
        body["actions"] = [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]]
        let response = try await postTV(endpoint: "browse/edit_playlist", body: body)
        let setVideoId = Self.findPlaylistEntryToken(in: response)
        tubeLog.notice(
            "addToWatchLater videoId=\(videoId, privacy: .public) setVideoId=\(setVideoId ?? "nil", privacy: .public)")
        return setVideoId
    }

    /// Removes a video from the authenticated user's Watch Later playlist (id \"WL\").
    ///
    /// Unlike `addToWatchLater` (which only needs the video ID), removal is keyed by
    /// `setVideoId` — the playlist-entry token from that video's `playlistVideoRenderer`
    /// (see `parsePlaylistVideoRenderer` in InnerTubeAPI+VideoRenderers.swift). A playlist
    /// can hold the same video more than once, so InnerTube's `ACTION_REMOVE_VIDEO` removes
    /// a specific *entry*, not "any entry with this video ID" — sending the raw video ID
    /// under a `removedVideoId` key (the previous behavior, #122) is not a field this action
    /// recognizes and the removal silently fails.
    /// Requires authentication.
    public func removeFromWatchLater(setVideoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["playlistId"] = "WL"
        body["actions"] = [["setVideoId": setVideoId, "action": "ACTION_REMOVE_VIDEO"]]
        _ = try await postTV(endpoint: "browse/edit_playlist", body: body)
        tubeLog.notice("removeFromWatchLater setVideoId=\(setVideoId, privacy: .public)")
    }

    /// Adds a video to an arbitrary user playlist (#8). Same mechanics as `addToWatchLater`,
    /// generalized to any `playlistId` from `fetchUserPlaylists()`.
    /// Requires authentication.
    public func addToPlaylist(playlistId: String, videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["playlistId"] = playlistId
        body["actions"] = [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]]
        _ = try await postTV(endpoint: "browse/edit_playlist", body: body)
        tubeLog.notice("addToPlaylist playlistId=\(playlistId, privacy: .public) videoId=\(videoId, privacy: .public)")
    }

    /// Removes a video from an arbitrary user playlist (#8). Same mechanics as
    /// `removeFromWatchLater` — keyed by `setVideoId`, not the raw video ID (see that
    /// function's doc comment for why).
    /// Requires authentication.
    public func removeFromPlaylist(playlistId: String, setVideoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["playlistId"] = playlistId
        body["actions"] = [["setVideoId": setVideoId, "action": "ACTION_REMOVE_VIDEO"]]
        _ = try await postTV(endpoint: "browse/edit_playlist", body: body)
        tubeLog.notice(
            "removeFromPlaylist playlistId=\(playlistId, privacy: .public) setVideoId=\(setVideoId, privacy: .public)"
        )
    }

    /// Sends a feed feedback signal to YouTube.
    /// Used for "Not interested", "Don't like this video", and "Don't recommend channel" —
    /// all three actions share this endpoint and differ only in their `feedbackToken`.
    /// Tokens are parsed from `videoRenderer.menu.menuRenderer.items` in the feed response.
    /// Requires authentication.
    public func sendFeedback(token: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["feedbackTokens"] = [token]
        _ = try await postTV(endpoint: "feedback", body: body)
        tubeLog.notice("sendFeedback token=\(token.prefix(20), privacy: .public)…")
    }

    /// Sends a feed feedback signal when no pre-fetched token is available.
    ///
    /// The TV client home feed omits per-video feedback menu items, so
    /// `Video.notInterestedToken` / `dontLikeToken` / `hideChannelToken` are `nil`
    /// for authenticated home-feed results. This method fetches the token on-demand
    /// via a WEB client `/next` request for the given video, then calls `sendFeedback`.
    ///
    /// - Parameters:
    ///   - videoId: The YouTube video ID to act on.
    ///   - iconType: The InnerTube icon type string identifying the action:
    ///     `"NOT_INTERESTED"`, `"DISLIKE"`, or `"BLOCK_CHANNEL"`.
    ///
    /// If YouTube's response does not include a matching token, the method returns
    /// silently (it logs a warning but does not throw) so the caller's hide-from-feed
    /// notification can still be posted.
    public func sendFeedbackForVideo(videoId: String, iconType: String) async throws {
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        let nextData = try await post(endpoint: "next", body: body)
        guard let token = parseFeedbackToken(iconType: iconType, from: nextData) else {
            tubeLog.warning(
                "sendFeedbackForVideo: no \(iconType, privacy: .public) token in /next for videoId=\(videoId, privacy: .public)"
            )
            return
        }
        try await sendFeedback(token: token)
    }

    /// Walks a `/next` (WEB) response and returns the first `feedbackEndpoint` token
    /// whose `menuServiceItemRenderer.icon.iconType` matches `iconType`.
    private func parseFeedbackToken(iconType: String, from json: [String: Any]) -> String? {
        var found: String? = nil
        func walk(_ obj: Any, depth: Int = 0) {
            guard found == nil, depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let svc = dict["menuServiceItemRenderer"] as? [String: Any],
                    let endpoint = svc["serviceEndpoint"] as? [String: Any],
                    let token = (endpoint["feedbackEndpoint"] as? [String: Any])?["feedbackToken"] as? String,
                    let type = (svc["icon"] as? [String: Any])?["iconType"] as? String,
                    type == iconType
                {
                    found = token
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        return found
    }

    // MARK: - Next (related videos / SuggestionsController equivalent)

    /// Fetches related/suggested videos and the current like status for a video.
    /// When authenticated, uses TVHTML5 on youtubei.googleapis.com so the Bearer
    /// token is accepted and the response includes the user's current like state.
    /// Without auth, falls back to the WEB client (like status will be .none).
    /// Mirrors Android's SuggestionsController + LikeDislikePresenter.
    public func fetchNextInfo(videoId: String) async throws -> NextInfo {
        let isAuth = authToken != nil
        var tvBody = makeBody(client: isAuth ? tvClientContext : webClientContext)
        tvBody["videoId"] = videoId

        if isAuth {
            // TV client (/next) returns like status + related but omits
            // engagementPanels (where chapters live). Make a second sequential
            // WEB /next call to extract chapters — no auth needed.
            // (async let cannot be used here: [String:Any] is not Sendable in Swift 6.)
            var webBody = makeBody(client: webClientContext)
            webBody["videoId"] = videoId
            let tvData = try await postTV(endpoint: "next", body: tvBody)
            let webData = try await post(endpoint: "next", body: webBody)
            let videos = parseRelatedVideos(from: webData)  // WEB client has compactVideoRenderer; TV client does not
            let status = parseLikeStatus(from: tvData)
            let chapters = parseChapters(from: webData)
            tubeLog.notice(
                "fetchNextInfo (auth) → related=\(videos.count, privacy: .public) chapters=\(chapters.count, privacy: .public)"
            )
            return NextInfo(relatedVideos: videos, likeStatus: status, chapters: chapters)
        } else {
            let data = try await post(endpoint: "next", body: tvBody)
            let videos = parseRelatedVideos(from: data)
            let chapters = parseChapters(from: data)
            tubeLog.notice(
                "fetchNextInfo (anon) → related=\(videos.count, privacy: .public) chapters=\(chapters.count, privacy: .public)"
            )
            return NextInfo(relatedVideos: videos, likeStatus: .none, chapters: chapters)
        }
    }

    // MARK: - Comments

    /// Fetches the first page of top-level comments for a video.
    /// Returns an empty array when comments are disabled or the token is absent.
    public func fetchComments(videoId: String) async throws -> [Comment] {
        try await fetchCommentPage(videoId: videoId).comments
    }

    /// Fetches one page of top-level comments.
    ///
    /// - Parameters:
    ///   - videoId: The video whose comments to load.
    ///   - continuation: The `nextToken` of the previous page. `nil` loads the first page:
    ///     that takes an extra `/next` call to find the comments token and the count.
    /// - Returns: The page's comments in display order, the token for the following page
    ///   (`nil` on the last page), and the count text on the first page.
    ///   Empty with a `nil` token when comments are disabled.
    public func fetchCommentPage(videoId: String, continuation: String? = nil) async throws -> CommentPage {
        var token = continuation
        var totalCountText: String? = nil
        if token == nil {
            var body = makeBody(client: webClientContext)
            body["videoId"] = videoId
            let nextData = try await post(endpoint: "next", body: body)
            totalCountText = parseCommentsCountText(from: nextData)
            guard let first = parseCommentsContinuationToken(from: nextData) else {
                tubeLog.notice("fetchCommentPage: no comments token for videoId=\(videoId, privacy: .public)")
                return CommentPage(comments: [], nextToken: nil, totalCountText: totalCountText)
            }
            token = first
        }
        let commentsBody = makeBody(client: webClientContext, continuationToken: token)
        let commentsData = try await post(endpoint: "next", body: commentsBody)
        let page = parseCommentPage(from: commentsData)
        tubeLog.notice(
            "fetchCommentPage videoId=\(videoId, privacy: .public) → \(page.comments.count, privacy: .public) comments, more=\(page.nextToken != nil, privacy: .public)"
        )
        return CommentPage(comments: page.comments, nextToken: page.nextToken, totalCountText: totalCountText)
    }

    // MARK: - Private social parsers

    /// Parses the user's current like/dislike state from a `/next` response.
    ///
    /// Handles two layouts:
    /// - WEB client: `videoPrimaryInfoRenderer.likeStatus` → string "LIKE" / "DISLIKE" / "INDIFFERENT"
    /// - TV/WEB client: `segmentedLikeDislikeButtonRenderer.{like,dislike}Button.toggleButtonRenderer.isToggled`
    private func parseLikeStatus(from json: [String: Any]) -> LikeStatus {
        var found: LikeStatus? = nil
        func walk(_ obj: Any, depth: Int = 0) {
            guard found == nil else { return }
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                // Strategy 1: direct likeStatus string (videoPrimaryInfoRenderer on WEB)
                if let statusStr = dict["likeStatus"] as? String {
                    switch statusStr {
                    case "LIKE": found = .like
                    case "DISLIKE": found = .dislike
                    default: found = LikeStatus.none
                    }
                    return
                }
                // Strategy 2: segmentedLikeDislikeButtonRenderer (WEB + TV clients)
                if let seg = dict["segmentedLikeDislikeButtonRenderer"] as? [String: Any] {
                    let liked =
                        (seg["likeButton"] as? [String: Any])
                        .flatMap { $0["toggleButtonRenderer"] as? [String: Any] }
                        .flatMap { $0["isToggled"] as? Bool } ?? false
                    let disliked =
                        (seg["dislikeButton"] as? [String: Any])
                        .flatMap { $0["toggleButtonRenderer"] as? [String: Any] }
                        .flatMap { $0["isToggled"] as? Bool } ?? false
                    found = liked ? .like : disliked ? .dislike : LikeStatus.none
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        tubeLog.notice("parseLikeStatus → \(String(describing: found ?? .none), privacy: .public)")
        return found ?? .none
    }

    /// Parses related / suggested videos from a `/next` response.
    /// Related videos appear as `compactVideoRenderer` in `secondaryResults`.
    private func parseRelatedVideos(from json: [String: Any]) -> [Video] {
        var videos: [Video] = []
        var rendererKeysFound: Set<String> = []
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                // Collect any *Renderer keys for diagnostics
                for k in dict.keys where k.hasSuffix("Renderer") { rendererKeysFound.insert(k) }
                if let r = dict["compactVideoRenderer"] as? [String: Any],
                    let v = parseVideoRenderer(r)
                {
                    videos.append(v)
                } else {
                    for value in dict.values { walk(value, depth: depth + 1) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        if videos.isEmpty { videos = parseEndScreenVideos(from: json) }
        tubeLog.notice(
            "[parseRelatedVideos] found=\(videos.count, privacy: .public) rendererKeys=\(rendererKeysFound.sorted().joined(separator: ","), privacy: .public)"
        )
        return Array(videos.prefix(25))
    }

    /// Fallback for responses that carry no `compactVideoRenderer` (YouTube's newer watch
    /// layouts): the end-screen suggestions (`endScreenVideoRenderer`) are still present and
    /// are the videos YouTube itself offers next.
    private func parseEndScreenVideos(from json: [String: Any]) -> [Video] {
        var videos: [Video] = []
        var seen = Set<String>()
        func text(_ value: Any?) -> String {
            guard let dict = value as? [String: Any] else { return "" }
            if let simple = dict["simpleText"] as? String { return simple }
            return (dict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        }
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let r = dict["endScreenVideoRenderer"] as? [String: Any],
                    let id = r["videoId"] as? String, seen.insert(id).inserted
                {
                    let thumbs = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                    let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
                    videos.append(
                        Video(
                            id: id, title: text(r["title"]), channelTitle: text(r["shortBylineText"]),
                            thumbnailURL: thumb, duration: parseDuration(text(r["lengthText"]))))
                } else {
                    for value in dict.values { walk(value, depth: depth + 1) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        return videos.filter { !$0.title.isEmpty }
    }

    /// Parses video chapters from a `/next` response.
    /// Chapters live in `engagementPanels[].engagementPanelSectionListRenderer
    ///   .content.macroMarkersListRenderer.contents[].macroMarkersListItemRenderer`.
    /// Each item carries a `title` text object and either
    ///   - `onTap.watchEndpoint.startTimeSeconds` (Int) — preferred, or
    ///   - `timeDescription` text object — fallback (parsed via `parseDuration`).
    private func parseChapters(from json: [String: Any]) -> [Chapter] {
        var chapters: [Chapter] = []
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let renderer = dict["macroMarkersListItemRenderer"] as? [String: Any] {
                    let title = (renderer["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    // startTimeSeconds arrives as Int, Double, or NSNumber depending on
                    // how JSONSerialization bridges the JSON number — handle all three.
                    let startTime: TimeInterval? = {
                        if let watchEndpoint = (renderer["onTap"] as? [String: Any])
                            .flatMap({ $0["watchEndpoint"] as? [String: Any] })
                        {
                            let raw = watchEndpoint["startTimeSeconds"]
                            if let n = raw as? Int { return TimeInterval(n) }
                            if let n = raw as? Double { return n }
                            if let n = raw as? NSNumber { return n.doubleValue }
                            if let s = raw as? String { return TimeInterval(s) }
                        }
                        // Fallback: parse the visible time description (e.g. "1:23")
                        return (renderer["timeDescription"] as? [String: Any])
                            .flatMap { extractText($0) }
                            .flatMap { parseDuration($0) }
                    }()
                    if let t = startTime {
                        chapters.append(Chapter(title: title, startTime: t))
                    }
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        return chapters.sorted { $0.startTime < $1.startTime }
    }

    /// The comments panels of a `/next` response: the `engagementPanelSectionListRenderer`
    /// whose `panelIdentifier` or header title contains "comment".
    private nonisolated func commentsPanels(in json: [String: Any]) -> [[String: Any]] {
        guard let panels = json["engagementPanels"] as? [[String: Any]] else { return [] }
        return panels.compactMap { panel -> [String: Any]? in
            guard let pslr = panel["engagementPanelSectionListRenderer"] as? [String: Any] else { return nil }
            let panelId = pslr["panelIdentifier"] as? String ?? ""
            let headerTitle: String = {
                let header = pslr["header"] as? [String: Any]
                let thr = header?["engagementPanelTitleHeaderRenderer"] as? [String: Any]
                return (thr?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
            }()
            guard panelId.lowercased().contains("comment") || headerTitle.lowercased().contains("comment") else {
                return nil
            }
            return pslr
        }
    }

    /// The comment count as YouTube shows it, from the comments panel's title header
    /// (`contextualInfo`, e.g. "5.4M"). `nil` when the response does not carry one.
    nonisolated func parseCommentsCountText(from json: [String: Any]) -> String? {
        for pslr in commentsPanels(in: json) {
            let header = pslr["header"] as? [String: Any]
            let thr = header?["engagementPanelTitleHeaderRenderer"] as? [String: Any]
            if let text = (thr?["contextualInfo"] as? [String: Any]).flatMap({ extractText($0) }), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Finds the comments continuation token inside the `engagementPanels` of a
    /// `/next` response — looks for the panel whose `panelIdentifier` or header title
    /// contains "comment".
    nonisolated func parseCommentsContinuationToken(from json: [String: Any]) -> String? {
        for pslr in commentsPanels(in: json) {
            var found: String? = nil
            func findToken(_ obj: Any, depth: Int = 0) {
                guard found == nil else { return }
                guard depth < 50 else { return }
                if let dict = obj as? [String: Any] {
                    if let contItem = dict["continuationItemRenderer"] as? [String: Any],
                        let endpoint = contItem["continuationEndpoint"] as? [String: Any],
                        let cmd = endpoint["continuationCommand"] as? [String: Any],
                        let t = cmd["token"] as? String
                    {
                        found = t
                        return
                    }
                    for v in dict.values { findToken(v, depth: depth + 1) }
                } else if let arr = obj as? [Any] {
                    for item in arr { findToken(item, depth: depth + 1) }
                }
            }
            findToken(pslr["content"] as Any)
            if let t = found { return t }
        }
        return nil
    }

    /// Converts a `commentEntityPayload` (InnerTube v2 entity format) into a `Comment`.
    /// Like counts live in `toolbar` (`likeCountNotliked`); older responses kept them in
    /// `properties.toolbarState`, which is still read as a fallback.
    private nonisolated func comment(fromEntityPayload cep: [String: Any]) -> Comment {
        let properties = cep["properties"] as? [String: Any]
        let author = cep["author"] as? [String: Any]
        let toolbar = cep["toolbar"] as? [String: Any]
        let toolbarState = properties?["toolbarState"] as? [String: Any]
        return Comment(
            id: properties?["commentId"] as? String ?? UUID().uuidString,
            author: author?["displayName"] as? String ?? "",
            authorAvatarURL: (author?["avatarThumbnailUrl"] as? String).flatMap { URL(string: $0) },
            text: (properties?["content"] as? [String: Any])?["content"] as? String ?? "",
            likeCount: toolbar?["likeCountNotliked"] as? String ?? toolbarState?["likeCountNotliked"] as? String ?? "",
            publishedTime: properties?["publishedTime"] as? String ?? "",
            isLiked: (toolbarState?["likeState"] as? String) == "LIKE_STATE_LIKED"
        )
    }

    /// Every comment entity in a response, keyed by its `entityKey`.
    private nonisolated func commentEntities(in json: [String: Any]) -> [String: Comment] {
        guard let frameworkUpdates = json["frameworkUpdates"] as? [String: Any],
            let entityBatch = frameworkUpdates["entityBatchUpdate"] as? [String: Any],
            let mutations = entityBatch["mutations"] as? [[String: Any]]
        else { return [:] }
        var entities: [String: Comment] = [:]
        for mutation in mutations {
            guard let key = mutation["entityKey"] as? String,
                let payload = mutation["payload"] as? [String: Any],
                let cep = payload["commentEntityPayload"] as? [String: Any]
            else { continue }
            entities[key] = comment(fromEntityPayload: cep)
        }
        return entities
    }

    /// Parses one page of top-level comments from a comments continuation `/next` response.
    ///
    /// Display order comes from the `onResponseReceivedEndpoints` item list, which
    /// references each comment by `commentKey`; the entity mutations only hold the data.
    /// Replies are not top-level and are skipped, including the reply continuation tokens
    /// nested inside each thread. The next-page token is the continuation item that sits
    /// directly in that item list.
    nonisolated func parseCommentPage(from json: [String: Any]) -> CommentPage {
        let entities = commentEntities(in: json)
        var ordered: [Comment] = []
        var sawCommentItems = false
        var nextToken: String? = nil

        for endpoint in json["onResponseReceivedEndpoints"] as? [[String: Any]] ?? [] {
            for commandKey in ["reloadContinuationItemsCommand", "appendContinuationItemsAction"] {
                guard let command = endpoint[commandKey] as? [String: Any],
                    let items = command["continuationItems"] as? [[String: Any]]
                else { continue }
                for item in items {
                    let commentKey: String? =
                        ((item["commentThreadRenderer"] as? [String: Any])?["commentViewModel"] as? [String: Any])
                        .flatMap { $0["commentViewModel"] as? [String: Any] }
                        .flatMap { $0["commentKey"] as? String }
                        ?? (item["commentViewModel"] as? [String: Any])?["commentKey"] as? String
                    if let commentKey {
                        sawCommentItems = true
                        if let comment = entities[commentKey] { ordered.append(comment) }
                    } else if let renderer = item["continuationItemRenderer"] as? [String: Any] {
                        nextToken = Self.firstContinuationToken(in: renderer) ?? nextToken
                    }
                }
            }
        }

        // Responses without the item list (older shapes): fall back to the entity order.
        if !sawCommentItems, ordered.isEmpty {
            let comments = parseComments(from: json)
            return CommentPage(comments: comments, nextToken: nextToken, totalCountText: nil)
        }
        return CommentPage(comments: ordered, nextToken: nextToken, totalCountText: nil)
    }

    /// The first `continuationCommand.token` under a `continuationItemRenderer`. Searches only
    /// inside that renderer, so tokens of reply streams elsewhere in the response are not used.
    private static func firstContinuationToken(in node: Any, depth: Int = 0) -> String? {
        guard depth < 20 else { return nil }
        if let dict = node as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any],
                let token = command["token"] as? String
            {
                return token
            }
            for value in dict.values {
                if let token = firstContinuationToken(in: value, depth: depth + 1) { return token }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let token = firstContinuationToken(in: value, depth: depth + 1) { return token }
            }
        }
        return nil
    }

    /// Parses `commentRenderer` objects from a comments continuation `/next` response.
    private nonisolated func parseComments(from json: [String: Any]) -> [Comment] {
        var comments: [Comment] = []

        // New entity-based format (YouTube InnerTube v2):
        // frameworkUpdates.entityBatchUpdate.mutations[].payload.commentEntityPayload
        // The comment list in onResponseReceivedEndpoints now holds only `commentViewModel`
        // key-references; the actual data is in entity mutations.
        if let frameworkUpdates = json["frameworkUpdates"] as? [String: Any],
            let entityBatch = frameworkUpdates["entityBatchUpdate"] as? [String: Any],
            let mutations = entityBatch["mutations"] as? [[String: Any]]
        {
            for mutation in mutations {
                guard let payload = mutation["payload"] as? [String: Any],
                    let cep = payload["commentEntityPayload"] as? [String: Any]
                else { continue }
                comments.append(comment(fromEntityPayload: cep))
            }
            if !comments.isEmpty {
                tubeLog.notice("parseComments: entity format → \(comments.count, privacy: .public) comments")
                return comments
            }
        }

        // Legacy format: commentRenderer nested in the response tree.
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let cr = dict["commentRenderer"] as? [String: Any] {
                    let id = cr["commentId"] as? String ?? UUID().uuidString
                    let author = (cr["authorText"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let avatarURL = ((cr["authorThumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                        .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }
                    let text = (cr["contentText"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let likeCount = (cr["voteCount"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let publishedTime = (cr["publishedTimeText"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let isLiked = cr["isLiked"] as? Bool ?? false
                    comments.append(
                        Comment(
                            id: id,
                            author: author,
                            authorAvatarURL: avatarURL,
                            text: text,
                            likeCount: likeCount,
                            publishedTime: publishedTime,
                            isLiked: isLiked
                        ))
                    return
                }
                for v in dict.values { walk(v, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        if !comments.isEmpty {
            tubeLog.notice(
                "parseComments: legacy commentRenderer format → \(comments.count, privacy: .public) comments")
        } else {
            let topKeys = Array(json.keys.prefix(6))
            tubeLog.notice("parseComments: 0 comments — top-level keys: \(topKeys, privacy: .public)")
        }
        return comments
    }

    // MARK: - Private: parseVideoRenderer passthrough
    // Social parsers (parseRelatedVideos) call parseVideoRenderer which lives in
    // InnerTubeAPI+VideoRenderers.swift. Because both files declare extensions on the
    // same actor, Swift resolves the call correctly at compile time.
}
