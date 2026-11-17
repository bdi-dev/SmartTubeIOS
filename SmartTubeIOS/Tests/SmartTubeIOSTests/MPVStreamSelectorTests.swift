import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

// MARK: - MPVStreamSelectorTests

@Suite("mpv Stream Selector")
struct MPVStreamSelectorTests {

    // MARK: Fixtures

    private func video(
        _ height: Int, fps: Int = 30, codecs: String, container: String = "mp4", bitrate: Int = 1_000_000
    )
        -> VideoFormat
    {
        VideoFormat(
            label: "\(height)p", width: height * 16 / 9, height: height, fps: fps,
            mimeType: "video/\(container); codecs=\"\(codecs)\"",
            url: URL(string: "https://cdn.example.com/v/\(height)-\(fps)-\(codecs)"), bitrate: bitrate)
    }

    private func audio(
        bitrate: Int, xtags: String? = nil, container: String = "mp4", codecs: String = "mp4a.40.2"
    )
        -> VideoFormat
    {
        var components = URLComponents(string: "https://cdn.example.com/a/\(bitrate)")!
        if let xtags { components.queryItems = [URLQueryItem(name: "xtags", value: xtags)] }
        return VideoFormat(
            label: "audio", width: 0, height: 0, fps: 0,
            mimeType: "audio/\(container); codecs=\"\(codecs)\"", url: components.url, bitrate: bitrate)
    }

    private func muxed(_ height: Int) -> VideoFormat {
        VideoFormat(
            label: "\(height)p", width: height * 16 / 9, height: height, fps: 30,
            mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
            url: URL(string: "https://cdn.example.com/muxed/\(height)"), bitrate: 600_000)
    }

    private func info(_ formats: [VideoFormat], hls: Bool = false) -> PlayerInfo {
        PlayerInfo(
            video: Video(id: "abc", title: "Title", channelTitle: "Channel"),
            formats: formats,
            hlsURL: hls ? URL(string: "https://manifest.example.com/master.m3u8") : nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    /// A 4K Apple TV that decodes H.264/HEVC/VP9 in hardware.
    private let tv4K = MPVDecodeCapabilities(hardwareCodecs: [.h264, .hevc, .vp9], displayHeight: 2160)
    /// Same display, but VP9 is software-only (older tvOS).
    private let tv4KNoVP9 = MPVDecodeCapabilities(hardwareCodecs: [.h264, .hevc], displayHeight: 2160)

    private func plans(
        _ info: PlayerInfo, hlsMaster: HLSMasterPlaylist? = nil, maxHeight: Int? = nil, preferH264: Bool = false,
        allowHDR: Bool = false, capabilities: MPVDecodeCapabilities
    ) -> [MPVStreamPlan] {
        MPVStreamSelector.plans(
            for: info, hlsMaster: hlsMaster, maxHeight: maxHeight, preferH264: preferH264, allowHDR: allowHDR,
            capabilities: capabilities)
    }

    private var youtubeLadder: [VideoFormat] {
        [
            video(2160, fps: 60, codecs: "vp9", container: "webm", bitrate: 26_000_000),
            video(2160, fps: 60, codecs: "av01.0.13M.08", bitrate: 20_000_000),
            video(1440, fps: 60, codecs: "vp9", container: "webm", bitrate: 13_000_000),
            video(1080, fps: 60, codecs: "avc1.64002A", bitrate: 7_000_000),
            video(1080, fps: 60, codecs: "vp9", container: "webm", bitrate: 5_000_000),
            video(720, fps: 60, codecs: "avc1.640020", bitrate: 4_000_000),
            video(360, codecs: "avc1.4D401E", bitrate: 800_000),
            audio(bitrate: 130_000),
            muxed(360),
        ]
    }

    // MARK: Codec detection

    @Test(
        "codec is derived from the mimeType",
        arguments: [
            ("video/mp4; codecs=\"avc1.640028\"", MPVVideoCodec.h264),
            ("video/webm; codecs=\"vp9\"", .vp9),
            ("video/mp4; codecs=\"vp09.00.51.08\"", .vp9),
            ("video/mp4; codecs=\"av01.0.12M.08\"", .av1),
            ("video/mp4; codecs=\"hvc1.1.6.L150\"", .hevc),
        ])
    func codec_fromMimeType(mimeType: String, expected: MPVVideoCodec) {
        #expect(MPVVideoCodec(mimeType: mimeType) == expected)
    }

    @Test("10-bit VP9 profile 2 and 10-bit AV1 count as HDR; 8-bit streams do not")
    func hdr_detection() {
        #expect(MPVVideoCodec.isHDR(mimeType: "video/webm; codecs=\"vp09.02.51.10.01.09.16.09.00\""))
        #expect(MPVVideoCodec.isHDR(mimeType: "video/mp4; codecs=\"av01.0.13M.10.0.110.09.16.09.0\""))
        #expect(!MPVVideoCodec.isHDR(mimeType: "video/webm; codecs=\"vp09.00.51.08\""))
        #expect(!MPVVideoCodec.isHDR(mimeType: "video/mp4; codecs=\"av01.0.13M.08\""))
        #expect(!MPVVideoCodec.isHDR(mimeType: "video/mp4; codecs=\"avc1.640028\""))
    }

    // MARK: Ranking

    @Test("with VP9 hardware decode, the tallest VP9 stream wins — WebM included")
    func ranking_vp9Hardware_picks4K() {
        let best = plans(info(youtubeLadder), capabilities: tv4K).first
        #expect(best?.height == 2160)
        #expect(best?.codec == .vp9)
        #expect(best?.label == "2160p60 VP9")
    }

    @Test("without VP9 hardware decode, smooth 1080p H.264 beats software 4K")
    func ranking_noVP9Hardware_staysOnH264() {
        // Adaptive plans only — the muxed 360p fallback always sits at the very end.
        let ranked = plans(info(youtubeLadder), capabilities: tv4KNoVP9).filter {
            if case .adaptive = $0.source { return true } else { return false }
        }
        #expect(ranked.first?.height == 1080)
        #expect(ranked.first?.codec == .h264)
        // The software-only 4K streams are still offered, just ranked below everything smooth.
        let firstSoftware4K = ranked.firstIndex { $0.height == 2160 }
        let lastSmooth = ranked.lastIndex { $0.height == 360 && $0.codec == .h264 }
        #expect(firstSoftware4K != nil)
        #expect(lastSmooth != nil)
        if let firstSoftware4K, let lastSmooth { #expect(firstSoftware4K > lastSmooth) }
    }

    @Test("AV1 is never chosen over a hardware codec at the same resolution")
    func ranking_av1BehindHardwareCodecs() {
        let ranked = plans(info(youtubeLadder), capabilities: tv4K)
        let vp9Index = ranked.firstIndex { $0.height == 2160 && $0.codec == .vp9 }
        let av1Index = ranked.firstIndex { $0.height == 2160 && $0.codec == .av1 }
        #expect(vp9Index != nil && av1Index != nil)
        if let vp9Index, let av1Index { #expect(vp9Index < av1Index) }
    }

    @Test("the user's quality cap bounds the choice")
    func ranking_respectsQualityCap() {
        let best = plans(info(youtubeLadder), maxHeight: 1080, capabilities: tv4K).first
        #expect(best?.height == 1080)
    }

    @Test("Auto never exceeds the display's resolution")
    func ranking_autoBoundedByDisplay() {
        let tvHD = MPVDecodeCapabilities(hardwareCodecs: [.h264, .hevc, .vp9], displayHeight: 1080)
        let best = plans(info(youtubeLadder), capabilities: tvHD).first
        #expect(best?.height == 1080)
    }

    @Test("when every stream exceeds the cap, the closest one is used")
    func ranking_everythingAboveCap_picksLowest() {
        let formats = [
            video(2160, codecs: "vp9", container: "webm"), video(1440, codecs: "vp9", container: "webm"),
            audio(bitrate: 130_000),
        ]
        let best = plans(info(formats), maxHeight: 720, capabilities: tv4K).first
        #expect(best?.height == 1440)
    }

    @Test("preferH264 ranks H.264 first at the same resolution")
    func ranking_preferH264() {
        let best = plans(info(youtubeLadder), maxHeight: 1080, preferH264: true, capabilities: tv4K).first
        #expect(best?.codec == .h264)
        let efficient = plans(info(youtubeLadder), maxHeight: 1080, preferH264: false, capabilities: tv4K).first
        #expect(efficient?.codec == .vp9)
    }

    @Test("HDR variants are held back unless allowed")
    func ranking_hdrOnlyWhenAllowed() {
        let formats = [
            video(2160, fps: 60, codecs: "vp09.02.51.10", container: "webm", bitrate: 30_000_000),
            video(2160, fps: 60, codecs: "vp09.00.51.08", container: "webm", bitrate: 26_000_000),
            audio(bitrate: 130_000),
        ]
        #expect(plans(info(formats), capabilities: tv4K).first?.isHDR == false)
        #expect(plans(info(formats), allowHDR: true, capabilities: tv4K).first?.isHDR == true)
    }

    @Test("software decode budget: 1080p30 and 720p60 are smooth, 1080p60 and 1440p are not")
    func capabilities_softwareBudget() {
        let softwareOnly = MPVDecodeCapabilities(hardwareCodecs: [], displayHeight: 2160)
        #expect(softwareOnly.isSmooth(codec: .vp9, height: 1080, fps: 30))
        #expect(softwareOnly.isSmooth(codec: .vp9, height: 720, fps: 60))
        #expect(!softwareOnly.isSmooth(codec: .vp9, height: 1080, fps: 60))
        #expect(!softwareOnly.isSmooth(codec: .vp9, height: 1440, fps: 30))
        #expect(tv4K.isSmooth(codec: .vp9, height: 2160, fps: 60))
    }

    // MARK: Audio

    @Test("audio: highest bitrate wins, Opus/WebM included")
    func audio_highestBitrate() {
        let formats = [
            audio(bitrate: 128_000), audio(bitrate: 160_000, container: "webm", codecs: "opus"),
            audio(bitrate: 50_000),
        ]
        #expect(MPVStreamSelector.bestAudio(in: formats)?.absoluteString.contains("/a/160000") == true)
    }

    @Test("audio: the original track beats a higher-bitrate dub or DRC variant")
    func audio_prefersOriginalTrack() {
        let formats = [
            audio(bitrate: 160_000, xtags: "acont=dubbed-auto:lang=es"),
            audio(bitrate: 140_000, xtags: "drc=1"),
            audio(bitrate: 128_000, xtags: "acont=original:lang=en"),
        ]
        #expect(MPVStreamSelector.bestAudio(in: formats)?.absoluteString.contains("/a/128000") == true)
    }

    // MARK: Plan assembly

    @Test("plans run adaptive → HLS → muxed")
    func plans_order() {
        let ranked = plans(info(youtubeLadder, hls: true), capabilities: tv4K)
        guard case .adaptive = ranked.first?.source else {
            Issue.record("expected an adaptive plan first")
            return
        }
        let hlsIndex = ranked.firstIndex { if case .hls = $0.source { return true } else { return false } }
        let muxedIndex = ranked.firstIndex { if case .muxed = $0.source { return true } else { return false } }
        #expect(hlsIndex != nil && muxedIndex != nil)
        if let hlsIndex, let muxedIndex { #expect(hlsIndex < muxedIndex) }
        #expect(ranked.last?.height == 360)
    }

    @Test("adaptive plans are dropped when every URL needs a PoToken (rqh=1)")
    func plans_rqhAdaptiveSkipped() {
        let rqh = VideoFormat(
            label: "1080p", width: 1920, height: 1080, fps: 30, mimeType: "video/mp4; codecs=\"avc1.640028\"",
            url: URL(string: "https://cdn.example.com/videoplayback?rqh=1&itag=137"), bitrate: 4_000_000)
        let ranked = plans(info([rqh, audio(bitrate: 130_000)], hls: true), capabilities: tv4K)
        #expect(ranked.count == 1)
        #expect(ranked.first?.label == "Auto (HLS)")
    }

    @Test("adaptive plans are dropped for SABR responses")
    func plans_sabrAdaptiveSkipped() {
        let sabr = VideoFormat(
            label: "1080p", width: 1920, height: 1080, fps: 30, mimeType: "video/mp4; codecs=\"avc1.640028\"",
            url: URL(string: "https://cdn.example.com/videoplayback?c=TVHTML5&itag=137"), bitrate: 4_000_000)
        let ranked = plans(info([sabr, audio(bitrate: 130_000)], hls: true), capabilities: tv4K)
        #expect(ranked.allSatisfy { if case .adaptive = $0.source { return false } else { return true } })
    }

    @Test("no audio stream means no adaptive plans")
    func plans_noAudio_noAdaptive() {
        let ranked = plans(info([video(1080, codecs: "avc1.640028"), muxed(360)]), capabilities: tv4K)
        #expect(ranked.count == 1)
        guard case .muxed = ranked.first?.source else {
            Issue.record("expected the muxed fallback")
            return
        }
    }

    @Test("nothing playable yields no plans")
    func plans_empty() {
        #expect(plans(info([]), capabilities: tv4K).isEmpty)
    }

    // MARK: HLS variants

    private var hlsMaster: HLSMasterPlaylist {
        let text = """
            #EXTM3U
            #EXT-X-MEDIA:URI="https://m.example.com/a/234.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="English",DEFAULT=YES
            #EXT-X-STREAM-INF:BANDWIDTH=7418000,CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=60,AUDIO="234"
            https://m.example.com/v/1080-avc.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=5022000,CODECS="vp09.00.41.08,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=60,AUDIO="234"
            https://m.example.com/v/1080-vp9.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=27987000,CODECS="vp09.00.51.08,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=60,AUDIO="234"
            https://m.example.com/v/2160-vp9.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.42001E,mp4a.40.2",RESOLUTION=640x360
            https://m.example.com/v/360-muxed.m3u8
            """
        return HLSMasterPlaylist(manifest: text, baseURL: URL(string: "https://m.example.com/master.m3u8")!)!
    }

    @Test("HLS variants are ranked individually and paired with their audio rendition")
    func hlsVariants_rankedAndPaired() {
        let ranked = plans(info([], hls: true), hlsMaster: hlsMaster, capabilities: tv4K)
        let best = ranked.first
        #expect(best?.label == "2160p60 VP9")
        #expect(best?.isHLS == true)
        #expect(
            best?.source
                == .adaptive(
                    video: URL(string: "https://m.example.com/v/2160-vp9.m3u8")!,
                    audio: URL(string: "https://m.example.com/a/234.m3u8")!))
    }

    @Test("HLS variants obey the same decode policy as direct streams")
    func hlsVariants_followDecodePolicy() {
        let best = plans(info([], hls: true), hlsMaster: hlsMaster, capabilities: tv4KNoVP9).first
        #expect(best?.label == "1080p60 H.264")
    }

    @Test("an HLS variant without an audio group is a single muxed stream")
    func hlsVariants_muxedVariant() {
        let ranked = plans(info([], hls: true), hlsMaster: hlsMaster, capabilities: tv4K)
        let muxedVariant = ranked.first { $0.height == 360 }
        #expect(muxedVariant?.source == .muxed(URL(string: "https://m.example.com/v/360-muxed.m3u8")!))
        #expect(muxedVariant?.isHLS == true)
    }

    @Test("direct streams come before HLS variants, and the bare master is the last HLS plan")
    func hlsVariants_orderedAfterDirect() {
        let ranked = plans(info(youtubeLadder, hls: true), hlsMaster: hlsMaster, capabilities: tv4K)
        #expect(ranked.first?.isHLS == false)
        let firstHLS = ranked.firstIndex { $0.isHLS }
        let lastDirectAdaptive = ranked.lastIndex {
            if case .adaptive = $0.source { return !$0.isHLS } else { return false }
        }
        #expect(firstHLS != nil && lastDirectAdaptive != nil)
        if let firstHLS, let lastDirectAdaptive { #expect(firstHLS > lastDirectAdaptive) }
        let masterIndex = ranked.firstIndex { if case .hls = $0.source { return true } else { return false } }
        let lastVariant = ranked.lastIndex { $0.isHLS && $0.height != nil }
        if let masterIndex, let lastVariant { #expect(masterIndex > lastVariant) }
    }
}
