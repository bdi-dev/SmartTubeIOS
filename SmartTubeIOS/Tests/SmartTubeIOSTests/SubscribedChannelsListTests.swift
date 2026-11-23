import Foundation
import Testing

@testable import InnerTubeKit

// Fixtures here are SHAPE-BASED (hand-trimmed to the renderer structure the TV client uses;
// ids and titles are invented). None is a verbatim signed-in response: no such capture was
// available. The signed-out /guide shape (guideEntryRenderer under guideSection items, with
// collapsed entries in guideCollapsibleEntryRenderer.expandableItems) is the REAL structure.

private func channelTile(_ id: String, _ title: String, avatar: Bool = true) -> [String: Any] {
    var header: [String: Any] = [:]
    if avatar {
        header = ["tileHeaderRenderer": ["thumbnail": ["thumbnails": [["url": "https://yt3.example/\(id)=s88"]]]]]
    }
    return [
        "tileRenderer": [
            "contentType": "TILE_CONTENT_TYPE_CHANNEL",
            "onSelectCommand": ["browseEndpoint": ["browseId": id]],
            "metadata": ["tileMetadataRenderer": ["title": ["simpleText": title]]],
            "header": header,
        ] as [String: Any]
    ]
}

private func listPage(_ tiles: [[String: Any]], next: String?) -> [String: Any] {
    var contents: [[String: Any]] = tiles
    if let next {
        contents.append(["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": next]]]]
        )
    }
    return ["contents": ["tvBrowseRenderer": ["content": ["tvSecondaryNavRenderer": ["items": contents]]]]]
}

private func guideEntry(_ id: String, _ title: String) -> [String: Any] {
    [
        "guideEntryRenderer": [
            "navigationEndpoint": ["browseEndpoint": ["browseId": id]],
            "formattedTitle": ["simpleText": title],
            "thumbnail": ["thumbnails": [["url": "https://yt3.example/\(id)=s48"]]],
        ] as [String: Any]
    ]
}

private final class ChannelListStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedBodies: [[String: Any]] = []
    nonisolated(unsafe) static var pages: [String: [String: Any]] = [:]  // token ("" = first) -> response

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = Data()
        if let s = request.httpBodyStream {
            s.open()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while case let n = s.read(buf, maxLength: 4096), n > 0 { body.append(buf, count: n) }
            buf.deallocate()
            s.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.requestedBodies.append(json)
        let token = json["continuation"] as? String ?? ""
        let page = Self.pages[token] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: page)) ?? Data()
        let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Subscribed channel list", .serialized)
struct SubscribedChannelsListTests {

    @Test("FEchannels tiles parse with avatars, in order, de-duplicated")
    func parsesTiles() async {
        let api = InnerTubeAPI(authToken: "t", session: .shared)
        let json = listPage(
            [channelTile("UCa", "Alpha"), channelTile("UCb", "Beta", avatar: false), channelTile("UCa", "Alpha")],
            next: nil)
        let channels = await api.parseChannelListTiles(from: json)
        #expect(channels.map(\.id) == ["UCa", "UCb"])
        #expect(channels[0].thumbnailURL != nil)
        #expect(channels[1].thumbnailURL == nil)
    }

    @Test("continuation token is found in continuationItemRenderer and nextContinuationData")
    func findsContinuation() async {
        let api = InnerTubeAPI(authToken: "t", session: .shared)
        #expect(await api.findContinuationToken(in: listPage([], next: "tok1")) == "tok1")
        let legacy: [String: Any] = ["continuations": [["nextContinuationData": ["continuation": "tok2"]]]]
        #expect(await api.findContinuationToken(in: legacy) == "tok2")
        #expect(await api.findContinuationToken(in: listPage([], next: nil)) == nil)
    }

    @Test("guide scan walks collapsed expandableItems and reports them")
    func guideCollapsed() async {
        let api = InnerTubeAPI(authToken: "t", session: .shared)
        let guide: [String: Any] = [
            "items": [
                [
                    "guideSubscriptionsSectionRenderer": [
                        "items": [
                            guideEntry("UC1", "One"), guideEntry("UC2", "Two"),
                            [
                                "guideCollapsibleEntryRenderer": [
                                    "expandableItems": [guideEntry("UC3", "Three"), guideEntry("UC4", "Four")]
                                ]
                            ],
                        ]
                    ]
                ]
            ]
        ]
        let scan = await api.scanGuide(guide)
        #expect(scan.channels.count == 4)
        #expect(scan.collapsibleEntries == 1)
        #expect(scan.expandableItemEntries == 2)
    }

    @Test("merge unions by id, fills avatar/title gaps and sorts")
    func merges() {
        let a = [Channel(id: "UC1", title: "Zed"), Channel(id: "UC2", title: "")]
        let b = [
            Channel(id: "UC2", title: "Bob", thumbnailURL: URL(string: "https://x/y")),
            Channel(id: "UC3", title: "Amy"),
        ]
        let m = InnerTubeAPI.mergeChannelLists([a, b])
        #expect(m.map(\.title) == ["Amy", "Bob", "Zed"])
        #expect(m[1].thumbnailURL != nil)
    }

    @Test("fetchSubscribedChannels follows FEchannels continuations beyond the capped guide")
    func pagesPastCappedGuide() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ChannelListStub.self]
        ChannelListStub.requestedBodies = []
        // Guide carries 2 channels; the list carries 5 across 3 pages (3 overlap the guide-less set).
        ChannelListStub.pages = [
            "": listPage([channelTile("UC1", "A"), channelTile("UC2", "B")], next: "p2"),
            "p2": listPage([channelTile("UC3", "C"), channelTile("UC4", "D")], next: "p3"),
            "p3": listPage([channelTile("UC5", "E")], next: nil),
        ]
        let api = InnerTubeAPI(authToken: "t", session: URLSession(configuration: cfg))
        let channels = try await api.fetchSubscribedChannels()
        #expect(channels.map(\.id) == ["UC1", "UC2", "UC3", "UC4", "UC5"])
        let browseIds = ChannelListStub.requestedBodies.compactMap { $0["browseId"] as? String }
        #expect(browseIds.first == "FEchannels")
    }

    @Test("a failing later page keeps the channels already collected")
    func partialOnLaterFailure() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ChannelListStub.self]
        ChannelListStub.requestedBodies = []
        // p2 is missing -> stub answers 200 with {} -> parse yields empty page, loop stops.
        ChannelListStub.pages = ["": listPage([channelTile("UC1", "A")], next: "p2")]
        let api = InnerTubeAPI(authToken: "t", session: URLSession(configuration: cfg))
        let channels = try await api.fetchSubscribedChannels()
        #expect(channels.map(\.id) == ["UC1"])
    }
}
