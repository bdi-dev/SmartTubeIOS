import AVFoundation
import Foundation
import SmartTubeIOSCore
import os

private let fetchLog = CrashlyticsLogger(category: "Download")

// MARK: - DownloadFetching

/// Progress / phase events emitted while a download is being fetched.
public enum DownloadFetchEvent: Sendable, Equatable {
    /// Fraction of bytes downloaded, 0…1.
    case progress(Double)
    /// Bytes are on disk; adaptive streams are being merged / the file is being remuxed.
    case merging
}

/// Seam between the download queue (`VideoDownloadService`) and the network:
/// "resolve a stream, download it, and hand back a finished, AVPlayer-ready MP4 temp file".
/// Tests supply a fake; production uses `InnerTubeDownloadFetcher`.
public protocol DownloadFetching: Sendable {
    /// Returns a temp file URL (owned by the caller from now on). Throws on failure and
    /// cleans up its own intermediate files. Must honour task cancellation.
    func fetch(video: Video, onEvent: @escaping @Sendable (DownloadFetchEvent) -> Void) async throws -> URL
}

struct DownloadFetchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - InnerTubeDownloadFetcher

/// Production fetcher: resolves a muxed MP4 (Web, then Android client) or falls back to merging
/// adaptive video + audio streams, then passthrough-remuxes so the moov atom is first and
/// AVPlayer can play the file.
public final class InnerTubeDownloadFetcher: DownloadFetching {
    private let api: InnerTubeAPI

    public init(api: InnerTubeAPI) {
        self.api = api
    }

    /// URLSession used for all YouTube CDN downloads.
    /// httpAdditionalHeaders cannot override User-Agent on iOS — must use URLRequest.setValue.
    private static let cdnSession = URLSession(configuration: .default)

    /// Builds a URLRequest for a YouTube CDN URL.
    /// - `alr=yes` signals the CDN to respond with the full stream rather than an
    ///   initial probe chunk. Without it, adaptive-stream URLs often return 403.
    /// - `userAgent` must match the client that signed the URL (`c=` parameter):
    ///   Web → desktop Chrome, TV-auth → Cobalt, iOS → native iOS app UA.
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

    // MARK: DownloadFetching

    public func fetch(
        video: Video, onEvent: @escaping @Sendable (DownloadFetchEvent) -> Void
    ) async throws -> URL {
        let videoId = video.id
        if let tempURL = await tryDirectDownload(videoId: videoId, onEvent: onEvent) {
            onEvent(.merging)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            return try await passthroughRemux(inputURL: tempURL, videoId: videoId, suffix: "muxed")
        }

        fetchLog.notice("[download] direct download failed, trying adaptive merge fallback")
        let androidInfo = try await api.fetchPlayerInfoAndroid(videoId: videoId)
        fetchLog.notice("[download] adaptive fallback formats=\(androidInfo.formats.count)")
        guard let videoURL = androidInfo.bestAdaptiveVideoURL,
            let audioURL = androidInfo.bestAdaptiveAudioURL
        else {
            fetchLog.error("[download] ❌ no adaptive video/audio streams found")
            throw DownloadFetchError(message: "No downloadable stream found for this video")
        }
        onEvent(.progress(0))
        let mergedURL = try await mergeAdaptiveStreams(
            videoURL: videoURL, audioURL: audioURL, videoId: videoId,
            userAgent: InnerTubeClients.Android.userAgent, onEvent: onEvent)
        defer { try? FileManager.default.removeItem(at: mergedURL) }
        return try await passthroughRemux(inputURL: mergedURL, videoId: videoId, suffix: "merged")
    }

    // MARK: Stream resolution

    /// Tries Web client then Android client for a direct muxed MP4 download.
    /// Returns the temp file URL on success, nil if no muxed stream could be found.
    /// Note: TVHTML5-signed CDN URLs always return 403 when fetched without session cookies,
    /// so the Android client (c=ANDROID URLs) is used as the reliable fallback.
    private func tryDirectDownload(
        videoId: String, onEvent: @escaping @Sendable (DownloadFetchEvent) -> Void
    ) async -> URL? {
        let candidates: [(String, String, () async throws -> PlayerInfo)] = [
            (
                "Web", InnerTubeClients.Web.userAgent,
                { [api] in try await api.fetchPlayerInfoForDownload(videoId: videoId) }
            ),
            (
                "Android", InnerTubeClients.Android.userAgent,
                { [api] in try await api.fetchPlayerInfoAndroid(videoId: videoId) }
            ),
        ]
        for (label, clientUA, fetch) in candidates {
            if Task.isCancelled { return nil }
            guard let info = try? await fetch() else {
                fetchLog.notice("[download] \(label) client failed or UNPLAYABLE, trying next")
                continue
            }
            fetchLog.notice("[download] \(label) formats=\(info.formats.count) hlsURL=\(info.hlsURL != nil)")
            guard let muxedURL = info.bestMuxedDownloadURL else {
                fetchLog.notice("[download] \(label) — no muxed MP4, trying next")
                continue
            }
            fetchLog.notice("[download] \(label) ✅ muxed URL found, downloading")
            onEvent(.progress(0))
            if let tempURL = try? await downloadToTemp(
                url: muxedURL, videoId: videoId, userAgent: clientUA,
                onProgress: { onEvent(.progress($0)) })
            {
                let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
                fetchLog.notice("[download] \(label) download complete bytes=\(size)")
                guard size > 0 else {
                    fetchLog.notice("[download] \(label) — 0 bytes, YouTube rejected URL, trying next")
                    try? FileManager.default.removeItem(at: tempURL)
                    continue
                }
                return tempURL
            }
        }
        return nil
    }

    private func downloadToTemp(
        url: URL, videoId: String, userAgent: String = InnerTubeClients.iOS.userAgent,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let req = Self.cdnRequest(for: url, userAgent: userAgent)
        let delegate = ProgressDelegate { written, expected in
            if expected > 0 { onProgress(min(Double(written) / Double(expected), 1)) }
        }
        let (tempURL, response) = try await Self.cdnSession.download(for: req, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
        fetchLog.notice("[download] downloadToTemp status=\(status) bytes=\(size)")
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId).mp4")
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
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

    /// Downloads best adaptive video-only and audio-only MP4 streams concurrently,
    /// then merges them into a single MP4 using AVAssetWriter for true passthrough
    /// (sample-level copy, no re-encode of codec data).
    private func mergeAdaptiveStreams(
        videoURL: URL, audioURL: URL, videoId: String,
        userAgent: String = InnerTubeClients.iOS.userAgent,
        onEvent: @escaping @Sendable (DownloadFetchEvent) -> Void
    ) async throws -> URL {
        // Download both streams concurrently with explicit UA per-request. Progress is the mean
        // of the two streams' fractions.
        let fractions = OSAllocatedUnfairLock(initialState: [0.0, 0.0])
        func delegate(_ index: Int) -> ProgressDelegate {
            ProgressDelegate { written, expected in
                guard expected > 0 else { return }
                let mean = fractions.withLock { state -> Double in
                    state[index] = min(Double(written) / Double(expected), 1)
                    return (state[0] + state[1]) / 2
                }
                onEvent(.progress(mean))
            }
        }
        let videoReq = Self.cdnRequest(for: videoURL, userAgent: userAgent)
        let audioReq = Self.cdnRequest(for: audioURL, userAgent: userAgent)
        let videoDelegate = delegate(0)
        let audioDelegate = delegate(1)
        async let videoTemp = Self.cdnSession.download(for: videoReq, delegate: videoDelegate)
        async let audioTemp = Self.cdnSession.download(for: audioReq, delegate: audioDelegate)
        let (videoResult, audioResult) = try await (videoTemp, audioTemp)
        onEvent(.merging)

        let videoStatus = (videoResult.1 as? HTTPURLResponse)?.statusCode ?? 0
        let audioStatus = (audioResult.1 as? HTTPURLResponse)?.statusCode ?? 0
        let videoFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-vid.mp4")
        let audioFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-aud.mp4")
        try? FileManager.default.removeItem(at: videoFile)
        try? FileManager.default.removeItem(at: audioFile)
        try FileManager.default.moveItem(at: videoResult.0, to: videoFile)
        try FileManager.default.moveItem(at: audioResult.0, to: audioFile)

        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int) ?? 0
        let audioSize = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? 0
        fetchLog.notice(
            "[download] adaptive downloaded videoStatus=\(videoStatus) video=\(videoSize)B audioStatus=\(audioStatus) audio=\(audioSize)B"
        )

        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }

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

// MARK: - ProgressDelegate

/// Task-level delegate that reports byte progress. The async `download(for:delegate:)` API
/// delivers `didWriteData` to a `URLSessionDownloadDelegate` task delegate.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onBytes: @Sendable (_ written: Int64, _ expected: Int64) -> Void

    init(onBytes: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onBytes = onBytes
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        onBytes(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The async download API moves the file itself; nothing to do.
    }
}
