import AVFoundation
import Foundation
import SmartTubeIOSCore
import os

private let fetchLog = CrashlyticsLogger(category: "Download")

// MARK: - DownloadFetching

/// Seam between the download queue (`VideoDownloadService`) and YouTube:
/// "work out which CDN files to fetch" and, later, "turn the fetched files into one
/// AVPlayer-ready MP4". The bytes themselves travel through a `BackgroundTransferring`.
/// Tests supply a fake; production uses `InnerTubeDownloadFetcher`.
public protocol DownloadFetching: Sendable {
    /// Resolves signed CDN URLs (and the User-Agent each needs). Throws if nothing is downloadable.
    func resolve(video: Video) async throws -> DownloadPlan

    /// Like `resolve(video:)`, but when `audioOnly` is true the plan carries only the audio track.
    /// Fetchers that cannot do audio-only inherit a default that ignores the flag.
    func resolve(video: Video, audioOnly: Bool) async throws -> DownloadPlan

    /// Merges (video + audio) and passthrough-remuxes the staged files into a finished MP4 temp
    /// file owned by the caller. Must not delete the staged inputs; honours task cancellation.
    func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL

    /// Like `assemble(videoId:stagedParts:)`; when `audioOnly` is true and the staged file also
    /// carries video (a muxed fallback), only the audio track is kept.
    func assemble(videoId: String, stagedParts: [DownloadPart: URL], audioOnly: Bool) async throws -> URL
}

extension DownloadFetching {
    public func resolve(video: Video, audioOnly: Bool) async throws -> DownloadPlan {
        try await resolve(video: video)
    }

    public func assemble(videoId: String, stagedParts: [DownloadPart: URL], audioOnly: Bool) async throws -> URL {
        try await assemble(videoId: videoId, stagedParts: stagedParts)
    }
}

struct DownloadFetchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - InnerTubeDownloadFetcher

/// Production fetcher: resolves a muxed MP4 (Web, then Android client) or falls back to adaptive
/// video + audio streams, then passthrough-remuxes so the moov atom is first and AVPlayer can
/// play the file.
public final class InnerTubeDownloadFetcher: DownloadFetching {
    private let api: InnerTubeAPI

    public init(api: InnerTubeAPI) {
        self.api = api
    }

    /// Foreground session used only to probe that a resolved URL is accepted by the CDN.
    private static let probeSession = URLSession(configuration: .ephemeral)

    /// Builds a URLRequest for a YouTube CDN URL.
    /// - `alr=yes` signals the CDN to respond with the full stream rather than an
    ///   initial probe chunk. Without it, adaptive-stream URLs often return 403.
    /// - `userAgent` must match the client that signed the URL (`c=` parameter):
    ///   Web → desktop Chrome, TV-auth → Cobalt, iOS → native iOS app UA.
    ///   httpAdditionalHeaders cannot override User-Agent on iOS — must use URLRequest.setValue.
    static func cdnRequest(
        for url: URL, userAgent: String = InnerTubeClients.iOS.userAgent
    ) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "alr" }) {
            queryItems.append(URLQueryItem(name: "alr", value: "yes"))
        }
        components?.queryItems = queryItems
        let finalURL = components?.url ?? url
        var req = URLRequest(url: finalURL)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    // MARK: Stream resolution

    public func resolve(video: Video, audioOnly: Bool) async throws -> DownloadPlan {
        guard audioOnly else { return try await resolve(video: video) }
        for (label, clientUA, fetch) in clientCandidates(videoId: video.id) {
            if Task.isCancelled { throw CancellationError() }
            guard let info = try? await fetch(), let audioURL = info.bestAdaptiveAudioURL else {
                fetchLog.notice("[download] \(label) — no audio stream, trying next")
                continue
            }
            guard await Self.probe(url: audioURL, userAgent: clientUA) else {
                fetchLog.notice("[download] \(label) — CDN rejected audio URL, trying next")
                continue
            }
            fetchLog.notice("[download] \(label) ✅ audio URL accepted")
            return DownloadPlan(parts: [.init(part: .audio, url: audioURL, userAgent: clientUA)])
        }
        // No direct audio-only URL (YouTube often serves only muxed streams with usable URLs):
        // fetch the muxed file and keep just its audio track at assembly time.
        fetchLog.notice("[download] no audio-only stream, falling back to muxed + extract")
        if let plan = await resolveMuxed(videoId: video.id) { return plan }
        throw DownloadFetchError(message: "No audio stream found for this video")
    }

    /// Clients to try, in order: Web first (its CDN URLs download reliably), then Android.
    private func clientCandidates(videoId: String) -> [(String, String, () async throws -> PlayerInfo)] {
        [
            (
                "Web", InnerTubeClients.Web.userAgent,
                { [api] in try await api.fetchPlayerInfoForDownload(videoId: videoId) }
            ),
            (
                "Android", InnerTubeClients.Android.userAgent,
                { [api] in try await api.fetchPlayerInfoAndroid(videoId: videoId) }
            ),
        ]
    }

    public func resolve(video: Video) async throws -> DownloadPlan {
        let videoId = video.id
        if let plan = await resolveMuxed(videoId: videoId) { return plan }

        fetchLog.notice("[download] no usable muxed stream, trying adaptive fallback")
        let androidInfo = try await api.fetchPlayerInfoAndroid(videoId: videoId)
        fetchLog.notice("[download] adaptive fallback formats=\(androidInfo.formats.count)")
        guard let videoURL = androidInfo.bestAdaptiveVideoURL,
            let audioURL = androidInfo.bestAdaptiveAudioURL
        else {
            fetchLog.error("[download] ❌ no adaptive video/audio streams found")
            throw DownloadFetchError(message: "No downloadable stream found for this video")
        }
        let ua = InnerTubeClients.Android.userAgent
        return DownloadPlan(parts: [
            .init(part: .video, url: videoURL, userAgent: ua),
            .init(part: .audio, url: audioURL, userAgent: ua),
        ])
    }

    /// Tries Web client then Android client for a direct muxed MP4. A candidate is accepted only
    /// if the CDN answers a one-byte range probe, which preserves the old "try the next client
    /// when the first URL is rejected" behaviour now that the real transfer runs in the background.
    /// Note: TVHTML5-signed CDN URLs always return 403 when fetched without session cookies,
    /// so the Android client (c=ANDROID URLs) is used as the reliable fallback.
    private func resolveMuxed(videoId: String) async -> DownloadPlan? {
        guard let stream = await Self.muxedStream(api: api, videoId: videoId) else { return nil }
        return DownloadPlan(parts: [.init(part: .muxed, url: stream.url, userAgent: stream.userAgent)])
    }

    /// The best plain MP4 (video + audio in one file) YouTube will serve for `videoId`, with the
    /// User-Agent its URL was signed for. Tries the Web client then Android and accepts a URL only
    /// if the CDN answers a one-byte range probe. Shared by downloads and "Play in Native Player".
    public static func muxedStream(api: InnerTubeAPI, videoId: String) async -> Video.DirectStream? {
        let candidates: [(String, String, () async throws -> PlayerInfo)] = [
            (
                "Web", InnerTubeClients.Web.userAgent,
                { try await api.fetchPlayerInfoForDownload(videoId: videoId) }
            ),
            (
                "Android", InnerTubeClients.Android.userAgent,
                { try await api.fetchPlayerInfoAndroid(videoId: videoId) }
            ),
        ]
        for (label, clientUA, fetch) in candidates {
            if Task.isCancelled { return nil }
            guard let info = try? await fetch() else {
                fetchLog.notice("[stream] \(label) client failed or UNPLAYABLE, trying next")
                continue
            }
            fetchLog.notice("[stream] \(label) formats=\(info.formats.count) hlsURL=\(info.hlsURL != nil)")
            guard let muxedFormat = info.bestMuxedFormat, let muxedURL = muxedFormat.url else {
                fetchLog.notice("[stream] \(label) — no muxed MP4, trying next")
                continue
            }
            guard await probe(url: muxedURL, userAgent: clientUA) else {
                fetchLog.notice("[stream] \(label) — CDN rejected URL, trying next")
                continue
            }
            fetchLog.notice("[stream] \(label) ✅ muxed URL accepted")
            return Video.DirectStream(url: muxedURL, userAgent: clientUA, qualityLabel: muxedFormat.qualityLabel)
        }
        return nil
    }

    private static func probe(url: URL, userAgent: String) async -> Bool {
        var req = cdnRequest(for: url, userAgent: userAgent)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await probeSession.data(for: req),
            let status = (response as? HTTPURLResponse)?.statusCode
        else { return false }
        return status == 200 || status == 206
    }

    // MARK: Assemble

    public func assemble(videoId: String, stagedParts: [DownloadPart: URL], audioOnly: Bool) async throws -> URL {
        guard audioOnly, let muxed = stagedParts[.muxed] else {
            return try await assemble(videoId: videoId, stagedParts: stagedParts)
        }
        let input = try Self.linkAsMP4(muxed, videoId: videoId, suffix: "mux-audio-in")
        defer { try? FileManager.default.removeItem(at: input) }
        return try await extractAudio(inputURL: input, videoId: videoId)
    }

    /// Writes an audio-only MP4 containing just the audio track of `inputURL`, without re-encoding.
    private func extractAudio(inputURL: URL, videoId: String) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DownloadFetchError(message: "This video has no audio track")
        }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        guard
            let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw URLError(.cannotCreateFile) }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)

        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-audio-extract.mp4")
        try? FileManager.default.removeItem(at: destURL)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw URLError(.badServerResponse)
        }
        session.outputURL = destURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        if let error = session.error {
            try? FileManager.default.removeItem(at: destURL)
            throw error
        }
        return destURL
    }

    public func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
        if let muxed = stagedParts[.muxed] {
            let input = try Self.linkAsMP4(muxed, videoId: videoId, suffix: "muxed-in")
            defer { try? FileManager.default.removeItem(at: input) }
            return try await passthroughRemux(inputURL: input, videoId: videoId, suffix: "muxed")
        }
        if stagedParts.count == 1, let audio = stagedParts[.audio] {
            // Audio-only download: the staged file is an AAC-in-MP4 track.
            let input = try Self.linkAsMP4(audio, videoId: videoId, suffix: "audio-in")
            defer { try? FileManager.default.removeItem(at: input) }
            return try await passthroughRemux(inputURL: input, videoId: videoId, suffix: "audio")
        }
        guard let video = stagedParts[.video], let audio = stagedParts[.audio] else {
            throw DownloadFetchError(message: "Downloaded files are incomplete")
        }
        let videoFile = try Self.linkAsMP4(video, videoId: videoId, suffix: "vid")
        defer { try? FileManager.default.removeItem(at: videoFile) }
        let audioFile = try Self.linkAsMP4(audio, videoId: videoId, suffix: "aud")
        defer { try? FileManager.default.removeItem(at: audioFile) }
        let mergedURL = try await mergeAdaptiveStreams(videoFile: videoFile, audioFile: audioFile, videoId: videoId)
        defer { try? FileManager.default.removeItem(at: mergedURL) }
        return try await passthroughRemux(inputURL: mergedURL, videoId: videoId, suffix: "merged")
    }

    /// Staged files carry a `.tmp` extension, which AVFoundation cannot use to infer the container.
    /// Expose them under an `.mp4` name via a hard link (copy if linking fails) without disturbing
    /// the staged original, so an interrupted merge can be retried after relaunch.
    private static func linkAsMP4(_ staged: URL, videoId: String, suffix: String) throws -> URL {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent("\(videoId)-\(suffix).mp4")
        try? fm.removeItem(at: dest)
        do {
            try fm.linkItem(at: staged, to: dest)
        } catch {
            try fm.copyItem(at: staged, to: dest)
        }
        return dest
    }

    // MARK: Remux / merge

    /// Remuxes an MP4 file into a new container using passthrough (no re-encoding).
    /// `shouldOptimizeForNetworkUse` puts the moov atom first, which AVPlayer needs to start
    /// playback without reading the whole file.
    private func passthroughRemux(inputURL: URL, videoId: String, suffix: String) async throws -> URL {
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId)-\(suffix)-remux.mp4")
        try? FileManager.default.removeItem(at: destURL)
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw URLError(.badServerResponse)
        }
        session.outputURL = destURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        if let error = session.error {
            fetchLog.error("[download] passthrough remux error: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: destURL)
            throw error
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        fetchLog.notice("[download] passthrough remux done bytes=\(size)")
        return destURL
    }

    /// Merges separate video-only and audio-only MP4 files into a single MP4 using AVAssetWriter
    /// for true passthrough (sample-level copy, no re-encode of codec data).
    private func mergeAdaptiveStreams(videoFile: URL, audioFile: URL, videoId: String) async throws -> URL {
        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int) ?? 0
        let audioSize = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? 0
        fetchLog.notice("[download] adaptive merge input video=\(videoSize)B audio=\(audioSize)B")
        guard videoSize > 0, audioSize > 0 else {
            throw URLError(.zeroByteResource)
        }

        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-merged.mp4")
        try? FileManager.default.removeItem(at: destURL)

        // Use AVAssetWriter for true passthrough mux — reads compressed samples directly
        // from the source tracks and writes them to the new container without decoding.
        let videoAsset = AVURLAsset(url: videoFile)
        let audioAsset = AVURLAsset(url: audioFile)

        let videoTrackSrc = try await videoAsset.loadTracks(withMediaType: .video).first
        let audioTrackSrc = try await audioAsset.loadTracks(withMediaType: .audio).first
        guard let videoTrackSrc, let audioTrackSrc else {
            throw URLError(.badServerResponse)
        }

        let videoFmt = try await videoTrackSrc.load(.formatDescriptions).first!
        let audioFmt = try await audioTrackSrc.load(.formatDescriptions).first!

        let writer = try AVAssetWriter(outputURL: destURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFmt)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFmt)
        videoInput.expectsMediaDataInRealTime = false
        audioInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        writer.add(audioInput)

        let videoReader = try AVAssetReader(asset: videoAsset)
        let audioReader = try AVAssetReader(asset: audioAsset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrackSrc, outputSettings: nil)
        let audioOut = AVAssetReaderTrackOutput(track: audioTrackSrc, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        audioOut.alwaysCopiesSampleData = false
        videoReader.add(videoOut)
        audioReader.add(audioOut)

        writer.startWriting()
        videoReader.startReading()
        audioReader.startReading()
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "com.smarttube.merge", qos: .userInitiated)
            nonisolated(unsafe) let videoInput = videoInput
            nonisolated(unsafe) let videoOut = videoOut
            nonisolated(unsafe) let audioInput = audioInput
            nonisolated(unsafe) let audioOut = audioOut
            nonisolated(unsafe) let writer = writer

            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if let buf = videoOut.copyNextSampleBuffer() {
                        videoInput.append(buf)
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.enter()
            audioInput.requestMediaDataWhenReady(on: queue) {
                while audioInput.isReadyForMoreMediaData {
                    if let buf = audioOut.copyNextSampleBuffer() {
                        audioInput.append(buf)
                    } else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.notify(queue: queue) {
                writer.finishWriting {
                    if let err = writer.error {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume()
                    }
                }
            }
        }

        let mergedSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        fetchLog.notice("[download] adaptive merge done bytes=\(mergedSize)")
        return destURL
    }
}
