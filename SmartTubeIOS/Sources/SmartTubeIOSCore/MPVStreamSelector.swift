import Foundation

// MARK: - MPVStreamPlan

/// One concrete thing the mpv player engine can be asked to open for a video.
///
/// Unlike the AVPlayer path, mpv plays YouTube's adaptive streams directly: a video-only
/// URL plus a separate audio URL, in any container/codec FFmpeg understands (WebM/VP9/Opus
/// included). No `AVMutableComposition`, no HLS proxying.
public struct MPVStreamPlan: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Separate video and audio streams: a pair of YouTube "adaptive format" files, or
        /// one HLS variant playlist plus its audio rendition playlist.
        case adaptive(video: URL, audio: URL)
        /// HLS master manifest — mpv picks the highest-bitrate variant by itself. Last
        /// resort: it ignores the quality cap and what the device decodes smoothly.
        case hls(URL)
        /// Single stream carrying both tracks (progressive file, or a muxed HLS variant).
        case muxed(URL)
    }

    public let source: Source
    /// True when the URLs are HLS playlists rather than direct media files. The two are
    /// authorised differently by the CDN, so when one direct file is refused the other
    /// direct files usually are too, while HLS still plays.
    public let isHLS: Bool
    /// Vertical resolution, when known (unknown for HLS — the demuxer decides).
    public let height: Int?
    public let fps: Int?
    public let codec: MPVVideoCodec?
    public let isHDR: Bool

    public init(
        source: Source, isHLS: Bool = false, height: Int?, fps: Int?, codec: MPVVideoCodec?, isHDR: Bool = false
    ) {
        self.source = source
        self.isHLS = isHLS
        self.height = height
        self.fps = fps
        self.codec = codec
        self.isHDR = isHDR
    }

    /// Short user-facing label, e.g. `"2160p60 VP9"`, `"1080p H.264"`, `"Auto (HLS)"`.
    public var label: String {
        switch source {
        case .hls:
            return "Auto (HLS)"
        case .adaptive, .muxed:
            guard let height else { return "Unknown" }
            let rate = (fps ?? 0) > 30 ? "\(fps ?? 0)" : ""
            let hdr = isHDR ? " HDR" : ""
            let codecName = codec.map { " \($0.displayName)" } ?? ""
            return "\(height)p\(rate)\(hdr)\(codecName)"
        }
    }
}

// MARK: - MPVVideoCodec

public enum MPVVideoCodec: String, CaseIterable, Sendable {
    case h264
    case hevc
    case vp9
    case av1

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        }
    }

    /// Derives the codec from a YouTube `mimeType`, e.g. `video/webm; codecs="vp9"` or
    /// `video/mp4; codecs="avc1.640028"`. Returns nil for anything unrecognised.
    public init?(mimeType: String) {
        let lower = mimeType.lowercased()
        if lower.contains("avc1") || lower.contains("avc3") {
            self = .h264
        } else if lower.contains("hvc1") || lower.contains("hev1") {
            self = .hevc
        } else if lower.contains("vp09") || lower.contains("vp9") {
            self = .vp9
        } else if lower.contains("av01") {
            self = .av1
        } else {
            return nil
        }
    }

    /// True for the 10-bit HDR profiles YouTube serves (`vp09.02…` = VP9 profile 2,
    /// `av01.0.xxM.10…` = AV1 10-bit).
    static func isHDR(mimeType: String) -> Bool {
        let lower = mimeType.lowercased()
        if lower.contains("vp09.02") || lower.contains("vp9.2") { return true }
        if let range = lower.range(of: "av01.") {
            // av01.<profile>.<level><tier>.<bitDepth>
            let parts = lower[range.lowerBound...].split(separator: ".")
            if parts.count >= 4, parts[3].hasPrefix("10") || parts[3].hasPrefix("12") { return true }
        }
        return false
    }
}

// MARK: - MPVDecodeCapabilities

/// What the device can decode without dropping frames. The UI layer supplies the set of
/// hardware codecs (and corrects it if mpv ends up decoding one in software); this type
/// just carries the answer so the selection logic stays a pure function.
public struct MPVDecodeCapabilities: Equatable, Sendable {
    /// Codecs VideoToolbox can decode in hardware on this device.
    public var hardwareCodecs: Set<MPVVideoCodec>
    /// Tallest stream worth software-decoding. Above this, a software-only codec is
    /// skipped in favour of a hardware-decodable one at a lower resolution — smooth 1080p
    /// beats stuttering 4K.
    public var softwareMaxHeight: Int
    /// Highest frame rate worth software-decoding at `softwareMaxHeight`.
    public var softwareMaxFPS: Int
    /// The display's vertical resolution; streams taller than this are never chosen
    /// automatically.
    public var displayHeight: Int

    public init(
        hardwareCodecs: Set<MPVVideoCodec>,
        softwareMaxHeight: Int = 1080,
        softwareMaxFPS: Int = 30,
        displayHeight: Int = 2160
    ) {
        self.hardwareCodecs = hardwareCodecs
        self.softwareMaxHeight = softwareMaxHeight
        self.softwareMaxFPS = softwareMaxFPS
        self.displayHeight = displayHeight
    }

    /// Whether a stream of this shape is expected to play without dropped frames.
    public func isSmooth(codec: MPVVideoCodec, height: Int, fps: Int) -> Bool {
        if hardwareCodecs.contains(codec) { return true }
        if height > softwareMaxHeight { return false }
        // 60 fps software decode is only budgeted for up to 720p.
        if fps > softwareMaxFPS && height > 720 { return false }
        return true
    }
}

// MARK: - MPVStreamSelector

/// Pure stream-selection policy for the mpv player engine: turns a `PlayerInfo` into an
/// ordered list of `MPVStreamPlan`s, best first. The caller opens the first plan and walks
/// down the list when one fails to open.
public enum MPVStreamSelector {

    /// - Parameters:
    ///   - info: Player response from any client profile.
    ///   - hlsMaster: The parsed master playlist behind `info.hlsURL`, when it could be
    ///     fetched. Lets each HLS variant be ranked like any other stream instead of
    ///     leaving the choice to the demuxer.
    ///   - maxHeight: The user's quality cap (`nil` = Auto, bounded by the display).
    ///   - preferH264: Rank H.264 above more efficient codecs at the same resolution.
    ///   - allowHDR: When false, 10-bit HDR variants are only used if nothing else exists.
    ///   - capabilities: What this device decodes smoothly.
    public static func plans(
        for info: PlayerInfo,
        hlsMaster: HLSMasterPlaylist? = nil,
        maxHeight: Int?,
        preferH264: Bool,
        allowHDR: Bool,
        capabilities: MPVDecodeCapabilities
    ) -> [MPVStreamPlan] {
        var plans: [MPVStreamPlan] = []

        // Adaptive pairs. Skipped entirely when the CDN would reject them anyway:
        //   • SABR URLs (c=TVHTML5) serve UMP, not a media container.
        //   • rqh=1 URLs need a PoToken the caller has not applied.
        let adaptiveUsable = !info.containsSabrFormats && !info.containsRqhAdaptiveFormats
        if adaptiveUsable, let audio = bestAudio(in: info.formats) {
            for video in rankedVideoFormats(
                info.formats, maxHeight: maxHeight, preferH264: preferH264, allowHDR: allowHDR,
                capabilities: capabilities)
            {
                guard let url = video.url else { continue }
                plans.append(
                    MPVStreamPlan(
                        source: .adaptive(video: url, audio: audio),
                        height: video.height,
                        fps: video.fps,
                        codec: MPVVideoCodec(mimeType: video.mimeType),
                        isHDR: MPVVideoCodec.isHDR(mimeType: video.mimeType)
                    ))
            }
        }

        // HLS variants, ranked by the same policy. Each becomes its own plan: the variant
        // playlist plus the audio rendition its group names.
        if let hlsMaster {
            var variantsByURL: [URL: HLSMasterPlaylist.Variant] = [:]
            let variantFormats: [VideoFormat] = hlsMaster.variants.compactMap { variant in
                guard let codec = variant.videoCodec, variant.height > 0 else { return nil }
                variantsByURL[variant.url] = variant
                return VideoFormat(
                    label: "\(variant.height)p", width: variant.width, height: variant.height, fps: variant.fps,
                    mimeType: "video/mp4; codecs=\"\(codec)\"", url: variant.url, bitrate: variant.bandwidth)
            }
            for format in rankedVideoFormats(
                variantFormats, maxHeight: maxHeight, preferH264: preferH264, allowHDR: allowHDR,
                capabilities: capabilities)
            {
                guard let url = format.url, let variant = variantsByURL[url] else { continue }
                let source: MPVStreamPlan.Source
                if let audio = hlsMaster.audioRendition(for: variant) {
                    source = .adaptive(video: url, audio: audio.url)
                } else {
                    source = .muxed(url)
                }
                plans.append(
                    MPVStreamPlan(
                        source: source,
                        isHLS: true,
                        height: variant.height,
                        fps: variant.fps,
                        codec: MPVVideoCodec(mimeType: format.mimeType),
                        isHDR: variant.isHDR || MPVVideoCodec.isHDR(mimeType: format.mimeType)
                    ))
            }
        }

        if let hls = info.hlsURL {
            plans.append(MPVStreamPlan(source: .hls(hls), isHLS: true, height: nil, fps: nil, codec: nil))
        }

        let muxed = info.formats
            .filter { isMuxed($0) && $0.url != nil }
            .sorted { ($0.height, $0.bitrate ?? 0) > ($1.height, $1.bitrate ?? 0) }
        if let best = muxed.first, let url = best.url {
            plans.append(
                MPVStreamPlan(
                    source: .muxed(url), height: best.height, fps: best.fps,
                    codec: MPVVideoCodec(mimeType: best.mimeType)))
        }
        return plans
    }

    /// Video-only formats in the order they should be attempted.
    ///
    /// Ordering, most significant first:
    ///   1. Within the cap (user quality cap, else the display height).
    ///   2. Decodes smoothly on this device (hardware codec, or small enough for software).
    ///   3. SDR before HDR unless `allowHDR`.
    ///   4. Taller, then higher frame rate.
    ///   5. Codec preference (H.264 first when `preferH264`, else hardware codecs by
    ///      efficiency, then software codecs).
    ///   6. Higher bitrate.
    /// One entry per (height, fps, codec, HDR) — duplicates from multi-audio uploads collapse.
    public static func rankedVideoFormats(
        _ formats: [VideoFormat],
        maxHeight: Int?,
        preferH264: Bool,
        allowHDR: Bool,
        capabilities: MPVDecodeCapabilities
    ) -> [VideoFormat] {
        let cap = min(maxHeight ?? Int.max, max(capabilities.displayHeight, 1))

        struct Candidate {
            let format: VideoFormat
            let codec: MPVVideoCodec
            let isHDR: Bool
            let withinCap: Bool
            let smooth: Bool
            let codecRank: Int
        }

        func codecRank(_ codec: MPVVideoCodec) -> Int {
            if preferH264 && codec == .h264 { return 0 }
            let hardware = capabilities.hardwareCodecs.contains(codec)
            // Hardware codecs by compression efficiency, then software codecs by decode cost.
            switch (hardware, codec) {
            case (true, .av1): return 1
            case (true, .vp9): return 2
            case (true, .hevc): return 3
            case (true, .h264): return 4
            case (false, .h264): return 5
            case (false, .vp9): return 6
            case (false, .hevc): return 7
            case (false, .av1): return 8
            }
        }

        var seen = Set<String>()
        let candidates: [Candidate] = formats.compactMap { format in
            guard isVideoOnly(format), format.url != nil, format.height > 0,
                let codec = MPVVideoCodec(mimeType: format.mimeType)
            else { return nil }
            let hdr = MPVVideoCodec.isHDR(mimeType: format.mimeType)
            return Candidate(
                format: format,
                codec: codec,
                isHDR: hdr,
                withinCap: format.height <= cap,
                smooth: capabilities.isSmooth(codec: codec, height: format.height, fps: format.fps),
                codecRank: codecRank(codec)
            )
        }

        let sorted = candidates.sorted { a, b in
            if a.withinCap != b.withinCap { return a.withinCap }
            if a.smooth != b.smooth { return a.smooth }
            if !allowHDR, a.isHDR != b.isHDR { return !a.isHDR }
            if a.format.height != b.format.height {
                // Within the cap prefer taller; when everything exceeds the cap prefer the
                // closest (shortest) stream instead.
                return a.withinCap ? a.format.height > b.format.height : a.format.height < b.format.height
            }
            if a.format.fps != b.format.fps { return a.format.fps > b.format.fps }
            if allowHDR, a.isHDR != b.isHDR { return a.isHDR }
            if a.codecRank != b.codecRank { return a.codecRank < b.codecRank }
            return (a.format.bitrate ?? 0) > (b.format.bitrate ?? 0)
        }

        return sorted.compactMap { candidate in
            let key =
                "\(candidate.format.height)-\(candidate.format.fps)-\(candidate.codec.rawValue)-\(candidate.isHDR)"
            return seen.insert(key).inserted ? candidate.format : nil
        }
    }

    /// Best audio-only stream URL: the original-language, non-DRC track at the highest
    /// bitrate. Multi-audio uploads tag each track in the URL's `xtags` parameter
    /// (`acont=original` / `acont=dubbed-auto`, `drc=1`); untagged URLs are single-track.
    public static func bestAudio(in formats: [VideoFormat]) -> URL? {
        func score(_ format: VideoFormat) -> (Int, Int) {
            let tags = xtags(of: format.url)
            var rank = 2
            if tags.contains("acont=dubbed") || tags.contains("acont=descriptive") { rank = 0 }
            if tags.contains("drc=1") { rank = min(rank, 1) }
            return (rank, format.bitrate ?? 0)
        }
        return
            formats
            .filter { $0.mimeType.lowercased().hasPrefix("audio/") && $0.url != nil }
            .max { score($0) < score($1) }?
            .url
    }

    /// One selectable audio language of a multi-audio upload.
    public struct AudioOption: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let isOriginal: Bool
        public let url: URL
    }

    /// The audio languages of a multi-audio upload, original first. Each URL carries its
    /// language in `xtags` (`lang=es-US`); one stream per language is kept (non-DRC,
    /// highest bitrate). Empty for single-track uploads — there is nothing to choose.
    public static func audioOptions(in formats: [VideoFormat], locale: Locale = .current) -> [AudioOption] {
        var best: [String: (format: VideoFormat, original: Bool, rank: Int)] = [:]
        for format in formats where format.mimeType.lowercased().hasPrefix("audio/") {
            guard let url = format.url else { continue }
            let tags = xtags(of: url)
            guard
                let language = tags.split(separator: ":").compactMap({ pair -> String? in
                    pair.hasPrefix("lang=") ? normalizedLanguage(String(pair.dropFirst(5))) : nil
                }).first
            else { continue }
            let rank = tags.contains("drc=1") ? 0 : 1
            let original = tags.contains("acont=original")
            if let current = best[language],
                (current.rank, current.format.bitrate ?? 0) >= (rank, format.bitrate ?? 0)
            {
                continue
            }
            best[language] = (format, original, rank)
        }
        guard best.count > 1 else { return [] }
        return
            best
            .map { language, entry in
                AudioOption(
                    id: language,
                    name: locale.localizedString(forIdentifier: language) ?? language,
                    isOriginal: entry.original,
                    url: entry.format.url!
                )
            }
            .sorted { ($0.isOriginal ? 0 : 1, $0.name) < ($1.isOriginal ? 0 : 1, $1.name) }
    }

    /// The audio languages an HLS variant can be paired with: one rendition per language from
    /// the variant's audio group (the `DEFAULT=YES` one when a language has several).
    public static func audioOptions(
        in master: HLSMasterPlaylist, forVariant variantURL: URL, locale: Locale = .current
    ) -> [AudioOption] {
        guard let group = master.variants.first(where: { $0.url == variantURL })?.audioGroup else { return [] }
        var best: [String: HLSMasterPlaylist.AudioRendition] = [:]
        for rendition in master.audioRenditions where rendition.groupID == group {
            let language = rendition.language.map(normalizedLanguage) ?? rendition.name
            if let current = best[language], current.isDefault || !rendition.isDefault { continue }
            best[language] = rendition
        }
        guard best.count > 1 else { return [] }
        return
            best
            .map { language, rendition in
                AudioOption(
                    id: language,
                    name: locale.localizedString(forIdentifier: language) ?? rendition.name,
                    isOriginal: rendition.isDefault,
                    url: rendition.url
                )
            }
            .sorted { ($0.isOriginal ? 0 : 1, $0.name) < ($1.isOriginal ? 0 : 1, $1.name) }
    }

    /// Whether `option` is in the language of `identifier` (`en` matches `en-US`).
    public static func option(_ option: AudioOption, matches identifier: String) -> Bool {
        func code(_ value: String) -> String {
            value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        }
        return code(option.id) == code(identifier)
    }

    /// `xtags` is lower-cased for matching; restore BCP 47 casing (`en-us` → `en-US`).
    private static func normalizedLanguage(_ tag: String) -> String {
        tag.split(separator: "-").enumerated().map { index, part in
            index == 0 ? part.lowercased() : (part.count == 2 ? part.uppercased() : String(part))
        }.joined(separator: "-")
    }

    // MARK: - Helpers

    static func isVideoOnly(_ format: VideoFormat) -> Bool {
        format.mimeType.lowercased().hasPrefix("video/") && !format.mimeType.contains(", ")
    }

    static func isMuxed(_ format: VideoFormat) -> Bool {
        format.mimeType.lowercased().hasPrefix("video/") && format.mimeType.contains(", ")
    }

    private static func xtags(of url: URL?) -> String {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return ""
        }
        return items.first { $0.name == "xtags" }?.value?.lowercased() ?? ""
    }
}
