#if os(tvOS)
import Foundation
import Libmpv
import QuartzCore
import SmartTubeIOSCore
import VideoToolbox
import os

private let mpvLog = CrashlyticsLogger(category: "MPVEngine")

// MARK: - MPVEngineEvent

/// What the libmpv core reports back. Delivered through `MPVEngine.events` and consumed
/// on the main actor by `MPVPlayerViewModel`.
enum MPVEngineEvent: Sendable, Equatable {
    /// The demuxer opened the file and playback is about to start.
    case fileLoaded
    /// Playback resumed after a seek (or the first frame was shown).
    case playbackRestart
    /// The file could not be opened or decoding aborted. Payload is mpv's error string.
    case loadFailed(String)
    case timePosition(Double)
    case duration(Double)
    case paused(Bool)
    /// True while playback is stalled waiting for the network cache.
    case buffering(Bool)
    /// The playhead reached the end (`keep-open` holds the last frame).
    case endReached(Bool)
    case videoSize(width: Int, height: Int)
    /// Active hardware decoder (`"videotoolbox"`), or `"no"` for software decoding.
    case hardwareDecoder(String)
    /// Seconds of media buffered ahead of the playhead.
    case cacheAhead(Double)
}

// MARK: - MPVMetalLayer

/// MoltenVK briefly sets `drawableSize` to 1×1 to force a presentation to complete, which
/// flickers and can leave the layer stuck at 1×1 (mpv-player/mpv#13651). Ignore those.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

// MARK: - MPVEngine

/// Thin Swift wrapper around one libmpv core rendering into a `CAMetalLayer` through
/// libplacebo + MoltenVK (`vo=gpu-next`).
///
/// Threading: libmpv's client API is thread-safe. Commands are issued from the main actor;
/// a dedicated thread blocks in `mpv_wait_event` and forwards events into `events`. That
/// same thread owns teardown — `shutdown()` asks the core to quit, and the event thread
/// destroys the handle once it sees `MPV_EVENT_SHUTDOWN`, so the handle is never freed
/// while a wait is in flight.
final class MPVEngine: @unchecked Sendable {

    /// Layer mpv draws into. Host it in a view and keep its frame in sync with the bounds.
    let layer: MPVMetalLayer
    let events: AsyncStream<MPVEngineEvent>

    private let handle: OpaquePointer
    /// Set once `shutdown()` has asked the core to quit; no command touches `handle` after.
    private let isShutDown = OSAllocatedUnfairLock(initialState: false)

    /// Wraps the handle so it can cross into the event thread.
    private struct Handle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    // MARK: Lifecycle

    /// Returns nil when libmpv could not be created or initialised.
    @MainActor
    init?() {
        guard let handle = mpv_create() else {
            mpvLog.error("mpv_create failed")
            return nil
        }
        self.handle = handle

        let layer = MPVMetalLayer()
        layer.framebufferOnly = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        self.layer = layer

        let (stream, continuation) = AsyncStream.makeStream(
            of: MPVEngineEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.events = stream

        // --- Options that must be set before mpv_initialize -------------------------------
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        Self.check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid), "wid")
        let options: [(String, String)] = [
            // Rendering: libplacebo on Vulkan-over-Metal.
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            // Decode in hardware whenever VideoToolbox has a decoder; falls back to software.
            ("hwdec", "videotoolbox"),
            ("video-rotate", "no"),
            // Keep the core alive between files and hold the last frame at the end, so
            // end-of-video is a property change (`eof-reached`) rather than an unload.
            ("idle", "yes"),
            ("keep-open", "yes"),
            // No built-in input layer: the SwiftUI overlay owns all interaction. (MPVKit's
            // tvOS build has no Lua, so there is no OSC or ytdl hook to switch off.)
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("sub-auto", "no"),
            // Network cache sized for an Apple TV: generous read-ahead for 4K bitrates
            // without risking a jetsam kill.
            ("cache", "yes"),
            ("demuxer-max-bytes", "96MiB"),
            ("demuxer-max-back-bytes", "24MiB"),
            ("demuxer-readahead-secs", "30"),
            ("network-timeout", "20"),
        ]
        for (name, value) in options {
            Self.check(mpv_set_option_string(handle, name, value), name)
        }
        #if DEBUG
        mpv_request_log_messages(handle, "info")
        #else
        mpv_request_log_messages(handle, "warn")
        #endif

        guard mpv_initialize(handle) >= 0 else {
            mpvLog.error("mpv_initialize failed")
            mpv_terminate_destroy(handle)
            continuation.finish()
            return nil
        }

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "dheight", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "hwdec-current", MPV_FORMAT_STRING)

        let boxedHandle = Handle(pointer: handle)
        // The layer must outlive the core's video output; the event thread keeps it alive
        // until the handle has been destroyed.
        nonisolated(unsafe) let retainedLayer = layer
        let thread = Thread {
            Self.runEventLoop(handle: boxedHandle, continuation: continuation)
            _ = retainedLayer
        }
        thread.name = "com.void.smarttube.mpv.events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        shutdown()
    }

    /// Stops playback and tears the core down asynchronously. Safe to call more than once.
    func shutdown() {
        let alreadyShutDown = isShutDown.withLock { state -> Bool in
            let previous = state
            state = true
            return previous
        }
        guard !alreadyShutDown else { return }
        // `quit` makes the core emit MPV_EVENT_SHUTDOWN; the event thread then destroys it.
        mpv_command_string(handle, "quit")
    }

    // MARK: Loading

    /// Opens `plan`, replacing whatever is playing.
    /// - Parameters:
    ///   - startAt: Position to start from (resume point or quality-switch position).
    ///   - userAgent: Sent on every media request so it matches the client profile that
    ///     signed the stream URLs.
    ///   - audioOverride: Audio stream to use instead of the plan's own.
    func load(_ plan: MPVStreamPlan, startAt: TimeInterval?, userAgent: String?, audioOverride: URL? = nil) {
        guard isAlive else { return }
        if let userAgent {
            setString("user-agent", userAgent)
        }
        if let startAt, startAt > 1 {
            setString("start", String(format: "%.3f", startAt))
        } else {
            setString("start", "none")
        }
        // `audio-files` persists across loads — always reset it. `append` takes the value
        // verbatim (no list-separator parsing), which matters because URLs contain ':'.
        command(["change-list", "audio-files", "clr", ""])
        let primary: URL
        switch plan.source {
        case .adaptive(let video, let audio):
            // A chosen language replaces the plan's audio: a direct audio file, or for an
            // HLS variant one of the renditions of its audio group.
            let audio = audioOverride ?? audio
            command(["change-list", "audio-files", "append", audio.absoluteString])
            primary = video
        case .hls(let url), .muxed(let url):
            primary = url
        }
        command(["loadfile", primary.absoluteString, "replace"])
        setFlag("pause", false)
    }

    /// Unloads the current file but keeps the core alive.
    func stopPlayback() {
        command(["stop"])
    }

    // MARK: Transport

    func setPaused(_ paused: Bool) {
        setFlag("pause", paused)
    }

    /// Frame-exact absolute seek. Issued asynchronously so the main thread never waits on
    /// the core while it is busy demuxing.
    ///
    /// - Parameter resume: Also unpause, strictly *after* the seek. Needed when leaving the
    ///   end of the file: `keep-open` pauses the core there and re-pauses it at once if it
    ///   is unpaused while still at the end, so the two must reach the core in this order.
    ///   Both go through the same asynchronous command queue to guarantee it.
    func seek(to seconds: TimeInterval, resume: Bool = false) {
        commandAsync(["seek", String(format: "%.3f", max(0, seconds)), "absolute+exact"])
        if resume {
            commandAsync(["set", "pause", "no"])
        }
    }

    /// The core's own pause state, or nil after shutdown. The view model re-reads this
    /// after every seek instead of trusting what it last asked for.
    func isPaused() -> Bool? {
        guard isAlive else { return nil }
        var flag: Int32 = 0
        guard mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &flag) >= 0 else { return nil }
        return flag != 0
    }

    func setSpeed(_ speed: Double) {
        setString("speed", String(format: "%.2f", speed))
    }

    // MARK: Subtitles

    /// Loads an external WebVTT track and selects it; pass nil to turn subtitles off.
    func setSubtitle(url: URL?, title: String?, language: String?) {
        command(["sub-remove"], logFailure: false)
        guard let url else {
            setString("sid", "no")
            return
        }
        command(["sub-add", url.absoluteString, "select", title ?? "", language ?? ""])
    }

    // MARK: Background handling

    /// Releasing the video track while backgrounded avoids a black frame on return (the
    /// Metal drawable is invalidated while the app is not visible).
    func setVideoEnabled(_ enabled: Bool) {
        setString("vid", enabled ? "auto" : "no")
    }

    // MARK: Decode capabilities

    /// Codecs to *assume* VideoToolbox decodes in hardware on this device.
    ///
    /// tvOS has no `VTIsHardwareDecodeAvailable`, so this is a starting assumption rather
    /// than a probe: H.264 and HEVC everywhere; VP9 once the OS lets an app opt into the
    /// supplemental VP9 decoder (tvOS 26.2+). AV1 is never assumed. The view model checks
    /// `currentHardwareDecoder()` after the first frame and drops a codec from the set
    /// when mpv actually fell back to software for it.
    static func assumedHardwareCodecs() -> Set<MPVVideoCodec> {
        var codecs: Set<MPVVideoCodec> = [.h264, .hevc]
        if #available(tvOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            codecs.insert(.vp9)
        }
        return codecs
    }

    /// The decoder in use for the current file: `"videotoolbox"` for hardware, `"no"` for
    /// software. Nil before the first frame or after shutdown.
    func currentHardwareDecoder() -> String? {
        guard isAlive, let cString = mpv_get_property_string(handle, "hwdec-current") else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    /// Whether an audio track is selected for the current file. False when the file has no
    /// audio, or when its external audio file failed to open (`aid` is `"no"`). Nil before
    /// a file is loaded or after shutdown.
    func hasAudioTrack() -> Bool? {
        guard isAlive, let cString = mpv_get_property_string(handle, "aid") else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString) != "no"
    }

    // MARK: - Private: commands & properties

    private var isAlive: Bool { !isShutDown.withLock { $0 } }

    private func command(_ args: [String], logFailure: Bool = true) {
        guard isAlive else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for pointer in cargs { free(UnsafeMutablePointer(mutating: pointer)) } }
        let status = mpv_command(handle, &cargs)
        if logFailure { Self.check(status, args.first ?? "command") }
    }

    private func commandAsync(_ args: [String]) {
        guard isAlive else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for pointer in cargs { free(UnsafeMutablePointer(mutating: pointer)) } }
        Self.check(mpv_command_async(handle, 0, &cargs), args.first ?? "command")
    }

    private func setString(_ name: String, _ value: String) {
        guard isAlive else { return }
        Self.check(mpv_set_property_string(handle, name, value), name)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard isAlive else { return }
        var flag: Int32 = value ? 1 : 0
        Self.check(mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag), name)
    }

    private static func check(_ status: Int32, _ context: String) {
        guard status < 0 else { return }
        mpvLog.error("mpv error (\(context)): \(String(cString: mpv_error_string(status)))")
    }

    // MARK: - Private: event loop (runs on the dedicated event thread)

    private static func runEventLoop(
        handle: Handle,
        continuation: AsyncStream<MPVEngineEvent>.Continuation
    ) {
        // time-pos changes every frame; the UI and SponsorBlock only need ~4 Hz.
        var lastReportedTime = -Double.infinity
        var videoWidth = 0
        var videoHeight = 0

        while true {
            guard let event = mpv_wait_event(handle.pointer, -1)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                continuation.finish()
                mpv_terminate_destroy(handle.pointer)
                return

            case MPV_EVENT_FILE_LOADED:
                lastReportedTime = -Double.infinity
                continuation.yield(.fileLoaded)

            case MPV_EVENT_PLAYBACK_RESTART:
                lastReportedTime = -Double.infinity
                continuation.yield(.playbackRestart)

            case MPV_EVENT_END_FILE:
                guard let data = event.data else { break }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    continuation.yield(.loadFailed(String(cString: mpv_error_string(end.error))))
                }

            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.data else { break }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let value = property.data, let cName = property.name else { break }
                let name = String(cString: cName)
                switch (name, property.format) {
                case ("time-pos", MPV_FORMAT_DOUBLE):
                    let time = value.assumingMemoryBound(to: Double.self).pointee
                    if abs(time - lastReportedTime) >= 0.25 {
                        lastReportedTime = time
                        continuation.yield(.timePosition(time))
                    }
                case ("duration", MPV_FORMAT_DOUBLE):
                    continuation.yield(.duration(value.assumingMemoryBound(to: Double.self).pointee))
                case ("demuxer-cache-duration", MPV_FORMAT_DOUBLE):
                    continuation.yield(.cacheAhead(value.assumingMemoryBound(to: Double.self).pointee))
                case ("pause", MPV_FORMAT_FLAG):
                    continuation.yield(.paused(value.assumingMemoryBound(to: Int32.self).pointee != 0))
                case ("paused-for-cache", MPV_FORMAT_FLAG):
                    continuation.yield(.buffering(value.assumingMemoryBound(to: Int32.self).pointee != 0))
                case ("eof-reached", MPV_FORMAT_FLAG):
                    continuation.yield(.endReached(value.assumingMemoryBound(to: Int32.self).pointee != 0))
                case ("dwidth", MPV_FORMAT_INT64):
                    videoWidth = Int(value.assumingMemoryBound(to: Int64.self).pointee)
                    if videoWidth > 0, videoHeight > 0 {
                        continuation.yield(.videoSize(width: videoWidth, height: videoHeight))
                    }
                case ("dheight", MPV_FORMAT_INT64):
                    videoHeight = Int(value.assumingMemoryBound(to: Int64.self).pointee)
                    if videoWidth > 0, videoHeight > 0 {
                        continuation.yield(.videoSize(width: videoWidth, height: videoHeight))
                    }
                case ("hwdec-current", MPV_FORMAT_STRING):
                    if let cString = value.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                        continuation.yield(.hardwareDecoder(String(cString: cString)))
                    }
                default:
                    break
                }

            case MPV_EVENT_LOG_MESSAGE:
                guard let data = event.data else { break }
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                guard let prefix = message.prefix, let level = message.level, let text = message.text else { break }
                let line = "[\(String(cString: prefix))] \(String(cString: text))"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch String(cString: level) {
                case "fatal", "error": mpvLog.error(line)
                case "warn": mpvLog.notice(line)
                default: mpvLog.debug(line)
                }

            default:
                break
            }
        }
    }
}
#endif
