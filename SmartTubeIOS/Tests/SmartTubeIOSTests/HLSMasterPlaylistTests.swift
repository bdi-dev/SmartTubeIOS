import Foundation
import Testing

@testable import InnerTubeKit

// MARK: - HLSMasterPlaylistTests

@Suite("HLS Master Playlist")
struct HLSMasterPlaylistTests {

    private let masterURL = URL(string: "https://manifest.example.com/api/manifest/hls_variant/master.m3u8")!

    /// Shaped like a YouTube master playlist: demuxed variants that name an audio group,
    /// two audio groups (low / high bitrate), quoted attribute values containing commas.
    private let manifest = """
        #EXTM3U
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:URI="https://manifest.example.com/audio/233/en.m3u8",TYPE=AUDIO,GROUP-ID="233",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:URI="https://manifest.example.com/audio/234/de.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="Deutsch",LANGUAGE="de",DEFAULT=NO,AUTOSELECT=YES
        #EXT-X-MEDIA:URI="https://manifest.example.com/audio/234/en.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=7418000,CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=60,VIDEO-RANGE=SDR,AUDIO="234",CLOSED-CAPTIONS=NONE
        https://manifest.example.com/video/299.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=27987000,CODECS="vp09.00.51.08,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=59.940,VIDEO-RANGE=SDR,AUDIO="234"
        video/315.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=30000000,CODECS="vp09.02.51.10,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=60,VIDEO-RANGE=PQ,AUDIO="234"
        https://manifest.example.com/video/337.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=311000,CODECS="avc1.4D4015,mp4a.40.5",RESOLUTION=426x240,AUDIO="233"
        https://manifest.example.com/video/133.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.42001E,mp4a.40.2",RESOLUTION=640x360
        https://manifest.example.com/video/18.m3u8
        """

    private func parsed() throws -> HLSMasterPlaylist {
        try #require(HLSMasterPlaylist(manifest: manifest, baseURL: masterURL))
    }

    @Test("every STREAM-INF becomes a variant, in manifest order")
    func variants_allParsed() throws {
        let playlist = try parsed()
        #expect(playlist.variants.map(\.height) == [1080, 2160, 2160, 240, 360])
        #expect(playlist.variants.map(\.bandwidth) == [7_418_000, 27_987_000, 30_000_000, 311_000, 800_000])
    }

    @Test("codec, frame rate and dynamic range are read from the attribute list")
    func variant_attributes() throws {
        let playlist = try parsed()
        let h264 = playlist.variants[0]
        #expect(h264.videoCodec == "avc1.64002A")
        #expect(h264.fps == 60)
        #expect(h264.width == 1920)
        #expect(!h264.isHDR)

        // Fractional FRAME-RATE rounds; a quoted CODECS value keeps its inner comma.
        let vp9 = playlist.variants[1]
        #expect(vp9.videoCodec == "vp09.00.51.08")
        #expect(vp9.fps == 60)

        #expect(playlist.variants[2].isHDR)
        // No FRAME-RATE attribute → 30.
        #expect(playlist.variants[3].fps == 30)
    }

    @Test("relative variant URIs resolve against the master playlist URL")
    func variant_relativeURI() throws {
        let playlist = try parsed()
        #expect(
            playlist.variants[1].url.absoluteString
                == "https://manifest.example.com/api/manifest/hls_variant/video/315.m3u8")
    }

    @Test("a variant pairs with the default rendition of its own audio group")
    func audioRendition_defaultOfGroup() throws {
        let playlist = try parsed()
        let high = try #require(playlist.audioRendition(for: playlist.variants[0]))
        #expect(high.groupID == "234")
        #expect(high.language == "en")
        #expect(high.url.absoluteString == "https://manifest.example.com/audio/234/en.m3u8")

        let low = try #require(playlist.audioRendition(for: playlist.variants[3]))
        #expect(low.groupID == "233")
    }

    @Test("a variant without an AUDIO group carries its own audio")
    func audioRendition_muxedVariant() throws {
        let playlist = try parsed()
        #expect(playlist.variants[4].audioGroup == nil)
        #expect(playlist.audioRendition(for: playlist.variants[4]) == nil)
    }

    @Test("falls back to the first rendition when the group has no default")
    func audioRendition_noDefault() throws {
        let text = """
            #EXTM3U
            #EXT-X-MEDIA:URI="a/fr.m3u8",TYPE=AUDIO,GROUP-ID="aud",NAME="Français",LANGUAGE="fr"
            #EXT-X-MEDIA:URI="a/es.m3u8",TYPE=AUDIO,GROUP-ID="aud",NAME="Español",LANGUAGE="es"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="avc1.4D401F",RESOLUTION=1280x720,AUDIO="aud"
            v/720.m3u8
            """
        let playlist = try #require(HLSMasterPlaylist(manifest: text, baseURL: masterURL))
        #expect(playlist.audioRendition(for: playlist.variants[0])?.language == "fr")
    }

    @Test("subtitle renditions are not mistaken for audio")
    func media_nonAudioIgnored() throws {
        let text = """
            #EXTM3U
            #EXT-X-MEDIA:URI="s/en.m3u8",TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="avc1.4D401F",RESOLUTION=1280x720,SUBTITLES="subs"
            v/720.m3u8
            """
        let playlist = try #require(HLSMasterPlaylist(manifest: text, baseURL: masterURL))
        #expect(playlist.audioRenditions.isEmpty)
    }

    @Test("text with no variants is not a master playlist")
    func noVariants_returnsNil() {
        #expect(HLSMasterPlaylist(manifest: "", baseURL: masterURL) == nil)
        let mediaPlaylist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:5
            #EXTINF:5.0,
            seg0.ts
            """
        #expect(HLSMasterPlaylist(manifest: mediaPlaylist, baseURL: masterURL) == nil)
    }

    @Test("attribute lists keep commas that sit inside quotes")
    func attributes_quotedCommas() {
        let attributes = HLSMasterPlaylist.attributes(in: #"BANDWIDTH=10,CODECS="a,b",NAME="x=y",DEFAULT=YES"#)
        #expect(attributes == ["BANDWIDTH": "10", "CODECS": "a,b", "NAME": "x=y", "DEFAULT": "YES"])
    }
}
