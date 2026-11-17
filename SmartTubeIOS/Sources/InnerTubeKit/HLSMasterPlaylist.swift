import Foundation

// MARK: - HLSMasterPlaylist
//
// Full-fidelity parse of an HLS master playlist: every video variant with its codec,
// frame rate, dynamic range and audio group, plus the audio renditions those groups name.
//
// The older helpers in HLSManifestParser.swift collapse a manifest to `height → URL`
// because AVPlayer does its own variant selection. A player engine that picks the variant
// itself (mpv) needs the rest: two variants at the same height differ by codec and frame
// rate, and the audio lives in separate renditions.

public struct HLSMasterPlaylist: Equatable, Sendable {

    /// One `#EXT-X-STREAM-INF` entry.
    public struct Variant: Equatable, Sendable {
        public let url: URL
        public let width: Int
        public let height: Int
        /// `FRAME-RATE`, rounded; 30 when the attribute is absent.
        public let fps: Int
        /// `BANDWIDTH` in bits per second.
        public let bandwidth: Int
        /// The video entry of `CODECS`, e.g. `"avc1.640028"` or `"vp09.00.51.08"`.
        public let videoCodec: String?
        /// `VIDEO-RANGE` is `PQ` or `HLG`.
        public let isHDR: Bool
        /// `AUDIO` group id; nil when the variant carries its own audio.
        public let audioGroup: String?
    }

    /// One `#EXT-X-MEDIA:TYPE=AUDIO` entry.
    public struct AudioRendition: Equatable, Sendable {
        public let groupID: String
        public let url: URL
        public let name: String
        public let language: String?
        public let isDefault: Bool
    }

    public let variants: [Variant]
    public let audioRenditions: [AudioRendition]

    public init(variants: [Variant], audioRenditions: [AudioRendition]) {
        self.variants = variants
        self.audioRenditions = audioRenditions
    }

    /// The rendition to pair with a variant: the default one of its audio group (YouTube
    /// marks the original-language track `DEFAULT=YES`), else the group's first.
    public func audioRendition(for variant: Variant) -> AudioRendition? {
        guard let group = variant.audioGroup else { return nil }
        let candidates = audioRenditions.filter { $0.groupID == group }
        return candidates.first { $0.isDefault } ?? candidates.first
    }

    // MARK: Parsing

    /// Parses master-playlist text. Returns nil when it contains no video variants
    /// (e.g. it is a media playlist, or not HLS at all).
    public init?(manifest: String, baseURL: URL) {
        var variants: [Variant] = []
        var renditions: [AudioRendition] = []
        var pendingStreamInfo: [String: String]?

        func resolve(_ reference: String) -> URL? {
            URL(string: reference, relativeTo: baseURL)?.absoluteURL
        }

        for rawLine in manifest.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingStreamInfo = Self.attributes(in: String(line.dropFirst("#EXT-X-STREAM-INF:".count)))

            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = Self.attributes(in: String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard attributes["TYPE"] == "AUDIO",
                    let group = attributes["GROUP-ID"],
                    let uri = attributes["URI"], let url = resolve(uri)
                else { continue }
                renditions.append(
                    AudioRendition(
                        groupID: group,
                        url: url,
                        name: attributes["NAME"] ?? "",
                        language: attributes["LANGUAGE"],
                        isDefault: attributes["DEFAULT"] == "YES"
                    ))

            } else if !line.hasPrefix("#"), let info = pendingStreamInfo {
                // The first URI line after EXT-X-STREAM-INF belongs to it.
                pendingStreamInfo = nil
                guard let url = resolve(line) else { continue }
                var width = 0
                var height = 0
                if let resolution = info["RESOLUTION"] {
                    let parts = resolution.lowercased().split(separator: "x")
                    if parts.count == 2 {
                        width = Int(parts[0]) ?? 0
                        height = Int(parts[1]) ?? 0
                    }
                }
                let range = info["VIDEO-RANGE"]?.uppercased()
                variants.append(
                    Variant(
                        url: url,
                        width: width,
                        height: height,
                        fps: info["FRAME-RATE"].flatMap(Double.init).map { Int($0.rounded()) } ?? 30,
                        bandwidth: info["BANDWIDTH"].flatMap(Int.init) ?? 0,
                        videoCodec: Self.videoCodec(in: info["CODECS"]),
                        isHDR: range == "PQ" || range == "HLG",
                        audioGroup: info["AUDIO"]
                    ))
            }
        }

        guard !variants.isEmpty else { return nil }
        self.variants = variants
        self.audioRenditions = renditions
    }

    /// Splits an HLS attribute list (`KEY=value,KEY="quoted, value"`) into a dictionary.
    /// Commas inside double quotes do not separate attributes; quotes are stripped.
    static func attributes(in list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var insideQuotes = false

        func commit() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""
            value = ""
            readingValue = false
        }

        for character in list {
            if insideQuotes {
                if character == "\"" { insideQuotes = false } else { value.append(character) }
            } else if character == "\"" && readingValue {
                insideQuotes = true
            } else if character == "," {
                commit()
            } else if character == "=" && !readingValue {
                readingValue = true
            } else if readingValue {
                value.append(character)
            } else {
                key.append(character)
            }
        }
        commit()
        return result
    }

    /// Picks the video codec out of a `CODECS` value such as `"vp09.00.51.08,mp4a.40.2"`.
    static func videoCodec(in codecs: String?) -> String? {
        guard let codecs else { return nil }
        let videoPrefixes = ["avc1", "avc3", "hvc1", "hev1", "vp09", "vp9", "av01", "dvh1", "dvhe"]
        return
            codecs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { entry in videoPrefixes.contains { entry.lowercased().hasPrefix($0) } }
    }
}
