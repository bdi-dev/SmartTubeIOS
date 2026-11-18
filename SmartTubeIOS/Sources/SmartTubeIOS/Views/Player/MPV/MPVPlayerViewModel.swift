#if os(tvOS)
import AVKit
import CoreMedia
import Foundation
import Observation
import SmartTubeIOSCore
import UIKit

private let mpvPlayerLog = CrashlyticsLogger(category: "MPVPlayer")

// MARK: - MPVPlayerViewModel
//
// Drives the opt-in mpv player engine on tvOS (`AppSettings.useMPVPlayerOnTV`).
//
// Deliberately separate from `PlaybackViewModel`: that type's stream cascade exists to work
// around what AVPlayer cannot open (adaptive WebM, separate audio, custom request headers).
// mpv opens those directly, so this view model needs only a short client-profile list and
// `MPVStreamSelector`'s ranking — no composition, no HLS proxy, no fallback cascade.
//
// One engine per video: a video that mpv cannot open is handed back to the AVPlayer path
// whole (see `PlayerScreen`); playback never migrates between engines mid-stream.

@MainActor
@Observable
final class MPVPlayerViewModel {

    // MARK: State

    private(set) var video: Video
    private(set) var isLoading = true
    /// Shown under the spinner while streams are being negotiated.
    private(set) var statusMessage: String?
    private(set) var isPlaying = false {
        didSet {
            // AVPlayer holds off the screensaver by itself; mpv needs it done explicitly.
            guard isPlaying != oldValue else { return }
            UIApplication.shared.isIdleTimerDisabled = isPlaying
        }
    }
    private(set) var isBuffering = false
    private(set) var videoEnded = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Seconds of media buffered ahead of the playhead.
    private(set) var cacheAhead: TimeInterval = 0
    /// Set when every stream of every client profile failed to open.
    private(set) var errorMessage: String?

    /// Every stream of the current video that could be opened, best first.
    private(set) var plans: [MPVStreamPlan] = []
    /// `plans` without repeats of the same quality (a quality can be reachable both as a
    /// direct file and as an HLS variant) — what the quality menu lists.
    var selectablePlans: [MPVStreamPlan] {
        var seenLabels = Set<String>()
        return plans.filter { seenLabels.insert($0.label).inserted }
    }
    private(set) var activePlan: MPVStreamPlan?
    /// `"videotoolbox"` when decoding in hardware, `"no"` for software, nil until known.
    private(set) var hardwareDecoder: String?
    private(set) var videoSize: (width: Int, height: Int)?

    private(set) var sponsorSegments: [SponsorSegment] = []
    /// Segment whose category is set to "show a skip button" and is playing right now.
    private(set) var toastSegment: SponsorSegment?

    private(set) var captionTracks: [CaptionTrack] = []
    private(set) var selectedCaption: CaptionTrack?

    // Chapters, up-next and audio languages
    private(set) var chapters: [Chapter] = []
    private(set) var relatedVideos: [Video] = []
    /// Formats and HLS master of the client that produced `plans`; the audio languages come
    /// from whichever of them the active stream uses.
    private var sourceFormats: [VideoFormat] = []
    private var sourceHLSMaster: HLSMasterPlaylist?
    /// The language the viewer chose; nil until they choose one.
    private(set) var selectedAudio: MPVStreamSelector.AudioOption?
    /// Audio languages the active stream can play; empty when there is only one track.
    var audioOptions: [MPVStreamSelector.AudioOption] {
        guard let plan = activePlan, case .adaptive(let video, _) = plan.source else { return [] }
        if plan.isHLS {
            guard let master = sourceHLSMaster else { return [] }
            return MPVStreamSelector.audioOptions(in: master, forVariant: video)
        }
        return MPVStreamSelector.audioOptions(in: sourceFormats)
    }
    /// What is (or will be) playing: the viewer's choice, else the system language when the
    /// video offers it, else the original track.
    var effectiveAudio: MPVStreamSelector.AudioOption? {
        if let selectedAudio { return selectedAudio }
        let options = audioOptions
        for identifier in Locale.preferredLanguages {
            if let match = options.first(where: { MPVStreamSelector.option($0, matches: identifier) }) { return match }
        }
        return options.first { $0.isOriginal }
    }
    private(set) var hasQueueNext = false
    var canPlayNext: Bool { hasQueueNext || !relatedVideos.isEmpty }
    var canPlayPrevious: Bool { (queueIndex ?? 0) > 0 }
    /// The chapter containing the playhead (or the scrub position while scrubbing).
    var currentChapter: Chapter? {
        let time = (isScrubbing ? scrubTime : currentTime) + 0.5
        return chapters.last { $0.startTime <= time }
    }
    /// True when this video was reached by autoplay / Next rather than picked by the viewer:
    /// if it turns out to be unplayable, move on to the following suggestion instead of
    /// stranding them on an error screen.
    var autoSkipUnavailable = false
    /// Set by the view: switch the player to another video (new view model, new engine).
    var onPlayVideo: ((Video) -> Void)?
    /// Position in the Current Queue when this video was started from it. Captured at
    /// init because `video` is later replaced by the player response's copy, which has none.
    private let queueIndex: Int?
    private(set) var playbackSpeed: Double

    private(set) var controlsVisible = false
    /// True for a moment after a seek made while the controls are hidden, so the progress
    /// bar can confirm the jump without bringing the whole overlay up.
    private(set) var progressFlashVisible = false
    /// Set by the view while a system menu (quality / speed / captions) is open, so the
    /// auto-hide timer does not pull the overlay out from under it.
    var holdControls = false
    private(set) var isScrubbing = false
    private(set) var scrubTime: TimeInterval = 0

    /// Non-nil for the life of the view model unless libmpv failed to initialise.
    let engine: MPVEngine?

    // MARK: Dependencies

    private let api: InnerTubeAPI
    private var settings: AppSettings
    private let isSignedIn: Bool
    private let tracker: WatchtimeTracker
    private let sponsorBlock = SponsorBlockService()
    private var capabilities: MPVDecodeCapabilities

    // MARK: Load bookkeeping

    /// Client profiles still to try, in order. Each yields a `PlayerInfo` whose streams are
    /// ranked by `MPVStreamSelector`.
    private var remainingClients: [MPVClientProfile] = []
    private var activeClient: MPVClientProfile?
    /// Plans of the active client that have not been attempted yet.
    private var untriedPlans: [MPVStreamPlan] = []
    private var resumePosition: TimeInterval?
    private var hasStartedPlayback = false
    private var isSkipInFlight = false
    /// False from the moment a stream is opened until its first frame, when the decoder
    /// actually in use is read back and checked against what the plan assumed.
    private var decoderVerified = false
    /// mpv's own `pause` property, as last reported by the core.
    private var enginePaused = false
    private var lastLoadError: String?

    private var eventTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var controlsHideTask: Task<Void, Never>?
    private var progressFlashTask: Task<Void, Never>?
    private var scrubCommitTask: Task<Void, Never>?

    // MARK: Init

    init(video: Video, api: InnerTubeAPI, settings: AppSettings, isSignedIn: Bool) {
        self.video = video
        self.queueIndex = video.playlistId == CurrentQueueStore.playlistID ? video.playlistIndex : nil
        self.api = api
        self.settings = settings
        self.isSignedIn = isSignedIn
        self.tracker = WatchtimeTracker(api: api)
        self.playbackSpeed = settings.playbackSpeed
        self.capabilities = MPVDecodeCapabilities(
            hardwareCodecs: MPVEngine.assumedHardwareCodecs(),
            displayHeight: Int(UIScreen.main.nativeBounds.height)
        )
        self.engine = MPVEngine()
        if engine == nil {
            errorMessage = String(localized: "The mpv player could not start.", bundle: .module)
            isLoading = false
        }
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - Loading

    func start() {
        guard let engine, eventTask == nil else { return }
        eventTask = Task { [weak self] in
            for await event in engine.events {
                guard let self else { return }
                self.handle(event)
            }
        }

        tracker.transition(to: video.id, cpn: InnerTubeAPI.generateCPN(), flushPosition: 0, flushDuration: 0)
        if settings.historyState == .enabled {
            LocalWatchHistoryStore.shared.record(video)
        }

        remainingClients = MPVClientProfile.order(isSignedIn: isSignedIn)
        loadTask = Task { [weak self] in
            guard let self else { return }
            if let saved = await VideoStateStore.shared.state(for: self.video.id), saved.position > 5 {
                self.resumePosition = saved.position
            }
            await self.openNextCandidate()
        }
        Task { [weak self] in await self?.loadSponsorSegments() }
        Task { [weak self] in await self?.loadNextInfo() }
    }

    /// Retries from the first client profile after a total failure.
    func retry() {
        errorMessage = nil
        isLoading = true
        lastLoadError = nil
        untriedPlans = []
        remainingClients = MPVClientProfile.order(isSignedIn: isSignedIn)
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.openNextCandidate() }
    }

    /// Opens the next untried stream, resolving the next client profile when the current
    /// one is exhausted. Sets `errorMessage` once nothing is left.
    private func openNextCandidate() async {
        guard let engine else { return }
        while untriedPlans.isEmpty {
            guard !remainingClients.isEmpty else {
                isLoading = false
                statusMessage = nil
                errorMessage =
                    lastLoadError
                    ?? String(localized: "No playable stream was found for this video.", bundle: .module)
                mpvPlayerLog.error("all client profiles exhausted for \(self.video.id): \(self.errorMessage ?? "")")
                if autoSkipUnavailable { skipUnavailableVideo() }
                return
            }
            let client = remainingClients.removeFirst()
            if hasStartedPlayback == false, activeClient != nil {
                statusMessage = String(localized: "Trying another source…", bundle: .module)
            }
            do {
                let info = try await client.fetch(videoId: video.id, api: api)
                let hlsMaster = await Self.fetchHLSMaster(info.hlsURL, userAgent: client.userAgent)
                guard !Task.isCancelled else { return }
                apply(info, hlsMaster: hlsMaster, from: client)
            } catch is CancellationError {
                return
            } catch {
                mpvPlayerLog.notice(
                    "client \(client.rawValue) failed for \(self.video.id): \(error.localizedDescription)")
                // Keep going: a bot check or sign-in demand is per client profile, so the
                // next profile often answers. The last error is what the user sees if
                // none does.
                lastLoadError = error.localizedDescription
            }
        }
        let plan = untriedPlans.removeFirst()
        activePlan = plan
        hardwareDecoder = nil
        decoderVerified = false
        let startAt = hasStartedPlayback ? currentTime : resumePosition
        mpvPlayerLog.notice(
            "open \(self.video.id) via \(self.activeClient?.rawValue ?? "?"): \(plan.label) startAt=\(Int(startAt ?? 0))s"
        )
        engine.load(plan, startAt: startAt, userAgent: activeClient?.userAgent, audioOverride: effectiveAudio?.url)
        engine.setSpeed(playbackSpeed)
    }

    /// Downloads and parses the HLS master playlist so its variants can be ranked
    /// individually. Nil on any failure — the plain master URL still works as a plan.
    private static func fetchHLSMaster(_ url: URL?, userAgent: String?) async -> HLSMasterPlaylist? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return HLSMasterPlaylist(manifest: text, baseURL: url)
    }

    private func apply(_ info: PlayerInfo, hlsMaster: HLSMasterPlaylist?, from client: MPVClientProfile) {
        activeClient = client
        let ranked = MPVStreamSelector.plans(
            for: info,
            hlsMaster: hlsMaster,
            maxHeight: settings.preferredQuality.maxHeight,
            preferH264: settings.preferH264,
            allowHDR: false,
            capabilities: capabilities
        )
        mpvPlayerLog.notice(
            "client \(client.rawValue): \(info.formats.count) formats (sabr=\(info.containsSabrFormats) rqh=\(info.containsRqhAdaptiveFormats)), hlsVariants=\(hlsMaster?.variants.count ?? 0) → \(ranked.count) plans, best=\(ranked.first?.label ?? "none")"
        )
        guard !ranked.isEmpty else { return }
        untriedPlans = ranked
        plans = ranked
        // Metadata comes from the first client that answers; later clients only add streams.
        if !info.video.title.isEmpty { video = info.video }
        if duration <= 0, let known = info.video.duration { duration = known }
        if captionTracks.isEmpty { captionTracks = info.captionTracks }
        sourceFormats = info.formats
        sourceHLSMaster = hlsMaster
        if !tracker.hasTrackingSession { tracker.setTrackingURLs(info.trackingURLs) }
    }

    private func loadSponsorSegments() async {
        guard settings.sponsorBlockEnabled else { return }
        if let channelId = video.channelId, settings.sponsorBlockExcludedChannels.keys.contains(channelId) {
            return
        }
        let categories = settings.activeSponsorCategories
        guard !categories.isEmpty else { return }
        let fetched = await sponsorBlock.fetchSegments(videoId: video.id, categories: categories)
        let minimum = settings.sponsorBlockMinSegmentDuration
        sponsorSegments = minimum > 0 ? fetched.filter { ($0.end - $0.start) >= minimum } : fetched
    }

    // MARK: - Engine events

    private func handle(_ event: MPVEngineEvent) {
        switch event {
        case .fileLoaded:
            isLoading = false
            statusMessage = nil
            errorMessage = nil
            videoEnded = false
            hasStartedPlayback = true
            isPlaying = !enginePaused
            if let caption = selectedCaption { applyCaption(caption) }
            showControls()

        case .playbackRestart:
            isSkipInFlight = false
            // Re-sync with the core's real pause state: a coalesced property change (for
            // example keep-open re-pausing at the end) produces no `.paused` event.
            if hasStartedPlayback, !videoEnded, let paused = engine?.isPaused() {
                enginePaused = paused
                isPlaying = !paused
            }
            // First frame of a newly opened stream: find out how it is really being decoded.
            if !decoderVerified, hasStartedPlayback, !isLoading, let decoder = engine?.currentHardwareDecoder() {
                decoderVerified = true
                hardwareDecoder = decoder
                applyDisplayCriteria()
                reconsiderPlanIfSoftwareDecoding(decoder: decoder)
            }

        case .loadFailed(let reason):
            mpvPlayerLog.notice("stream failed (\(self.activePlan?.label ?? "?")): \(reason)")
            lastLoadError = reason
            // A refused direct file means the CDN is refusing that whole class of URL for
            // this client — skip the other direct files and go to the HLS plans.
            if let failed = activePlan, !failed.isHLS, case .adaptive = failed.source {
                untriedPlans.removeAll { plan in
                    if case .adaptive = plan.source { return !plan.isHLS }
                    return false
                }
            }
            isLoading = true
            loadTask?.cancel()
            loadTask = Task { [weak self] in await self?.openNextCandidate() }

        case .timePosition(let time):
            // Position updates already in flight when the video ended (a real end, or a
            // skip-to-end) must not move the playhead back or re-offer a segment.
            guard !isScrubbing, !isSkipInFlight, !videoEnded else { return }
            currentTime = time
            checkSponsorSkip(at: time)
            if isPlaying, settings.historyState == .enabled, duration > 0 {
                let duration = self.duration
                Task { await tracker.checkpointIfDue(position: time, duration: duration) }
            }

        case .duration(let value):
            if value > 0 { duration = value }

        case .paused(let paused):
            enginePaused = paused
            if hasStartedPlayback, !videoEnded { isPlaying = !paused }

        case .buffering(let buffering):
            isBuffering = buffering

        case .endReached(let reached):
            guard reached, hasStartedPlayback, !videoEnded else { return }
            handlePlaybackEnd()

        case .videoSize(let width, let height):
            videoSize = (width, height)

        case .hardwareDecoder(let name):
            // Only meaningful once a file is playing; before that the property is just "no".
            guard hasStartedPlayback, !isLoading else { return }
            hardwareDecoder = name

        case .cacheAhead(let seconds):
            cacheAhead = seconds
        }
    }

    /// `MPVStreamSelector` ranked the active stream on the assumption that its codec decodes
    /// in hardware (`MPVEngine.assumedHardwareCodecs`). If mpv ended up decoding it in
    /// software instead, stop trusting that codec; and if software cannot sustain this
    /// stream's resolution and frame rate, reopen with the best plan that it can.
    private func reconsiderPlanIfSoftwareDecoding(decoder: String) {
        guard decoder == "no", let plan = activePlan, let codec = plan.codec, let height = plan.height,
            capabilities.hardwareCodecs.contains(codec)
        else { return }
        capabilities.hardwareCodecs.remove(codec)
        func isSmooth(_ candidate: MPVStreamPlan) -> Bool {
            guard let candidateCodec = candidate.codec, let candidateHeight = candidate.height else { return false }
            return capabilities.isSmooth(codec: candidateCodec, height: candidateHeight, fps: candidate.fps ?? 30)
        }
        guard !isSmooth(plan) else { return }
        // Prefer staying on the same kind of URL (HLS vs direct) that just worked.
        let smoothPlans = plans.filter(isSmooth)
        guard let replacement = smoothPlans.first(where: { $0.isHLS == plan.isHLS }) ?? smoothPlans.first,
            replacement != plan
        else { return }
        mpvPlayerLog.notice(
            "\(codec.displayName) at \(height)p is decoding in software — stepping down to \(replacement.label)")
        select(plan: replacement)
    }

    private func handlePlaybackEnd() {
        if settings.loopEnabled {
            seek(to: 0, resume: true)
            return
        }
        videoEnded = true
        isPlaying = false
        currentTime = duration
        toastSegment = nil
        engine?.setPaused(true)
        showControls(autoHide: false)
        saveProgress()
        Task { [weak self] in
            guard let self, let next = await self.nextVideo(automatic: true) else { return }
            mpvPlayerLog.notice("autoplay → \(next.id)")
            self.play(next)
        }
    }

    // MARK: - Up next, chapters, audio

    private func loadNextInfo() async {
        do {
            let info = try await api.fetchNextInfo(videoId: video.id)
            chapters = info.chapters
            relatedVideos = info.relatedVideos.filter { $0.id != video.id }
            mpvPlayerLog.notice("next info: \(self.relatedVideos.count) related, \(self.chapters.count) chapters")
        } catch {
            mpvPlayerLog.notice("next info failed: \(error.localizedDescription)")
        }
        if let index = queueIndex {
            hasQueueNext = await CurrentQueueStore.shared.videoAt(index: index + 1) != nil
        }
    }

    /// The video that follows this one: the Current Queue when it is playing, else the
    /// first (or, with shuffle, a random) suggestion. Automatic advance also honours the
    /// autoplay setting; an explicit "next" press does not.
    private func nextVideo(automatic: Bool) async -> Video? {
        if let index = queueIndex {
            if automatic, settings.queueShuffleEnabled {
                if let pick = await CurrentQueueStore.shared.remainingVideos(after: index).randomElement() {
                    return pick
                }
            } else if let next = await CurrentQueueStore.shared.videoAt(index: index + 1) {
                return next
            }
            await CurrentQueueStore.shared.clear()
        }
        if automatic {
            if settings.shuffleEnabled { return relatedVideos.randomElement() }
            return settings.autoplayEnabled ? relatedVideos.first : nil
        }
        return relatedVideos.first
    }

    private func play(_ next: Video) {
        CrashlyticsLogger.setIntendedVideo(id: next.id, title: next.title)
        onPlayVideo?(next)
    }

    func playNext() {
        Task { [weak self] in
            guard let self, let next = await self.nextVideo(automatic: false) else { return }
            self.play(next)
        }
    }

    /// Restarts the video when it has played a while, else steps back in the queue.
    func playPrevious() {
        if currentTime > 5 || !canPlayPrevious {
            seek(to: 0, resume: videoEnded)
            return
        }
        guard let index = queueIndex else { return }
        Task { [weak self] in
            guard let self, let previous = await CurrentQueueStore.shared.videoAt(index: index - 1) else { return }
            self.play(previous)
        }
    }

    /// Waits briefly for this video's own suggestions to arrive, then moves on.
    private func skipUnavailableVideo() {
        Task { [weak self] in
            for _ in 0..<10 {
                if let self, self.canPlayNext { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let self, self.errorMessage != nil, self.canPlayNext else { return }
            mpvPlayerLog.notice("skipping unavailable \(self.video.id)")
            self.playNext()
        }
    }

    func play(related video: Video) {
        play(video)
    }

    func jump(to chapter: Chapter) {
        guard hasStartedPlayback else { return }
        seek(to: chapter.startTime, resume: videoEnded)
        showControls()
    }

    /// Switches the audio language, keeping the picture and position.
    func selectAudio(_ option: MPVStreamSelector.AudioOption) {
        guard let engine, let plan = activePlan, option != effectiveAudio else { return }
        selectedAudio = option
        isLoading = true
        mpvPlayerLog.notice("audio → \(option.id) at \(Int(self.currentTime))s")
        engine.load(plan, startAt: currentTime, userAgent: activeClient?.userAgent, audioOverride: option.url)
        engine.setSpeed(playbackSpeed)
        if !isPlaying { engine.setPaused(true) }
    }

    // MARK: - Display criteria

    /// Asks the Apple TV to switch its output to the stream's frame rate and dynamic range,
    /// so 24/25/50 fps video is not judder-converted. Effective only when the viewer has
    /// "Match Content" turned on in the system settings.
    private func applyDisplayCriteria() {
        guard let plan = activePlan, let fps = plan.fps, fps > 0,
            let window = Self.keyWindow
        else { return }
        // The criteria API takes a format description; only the frame rate and the colour
        // transfer function in it influence the display mode, so build a minimal one.
        let height = Int32(plan.height ?? videoSize?.height ?? 1080)
        let width = Int32(videoSize?.width ?? Int(height) * 16 / 9)
        var extensions: [CFString: Any] = [:]
        if plan.isHDR {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_TransferFunction] =
                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: plan.isHDR ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: width, height: height, extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard status == noErr, let description else { return }
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(fps), formatDescription: description)
    }

    private func resetDisplayCriteria() {
        Self.keyWindow?.avDisplayManager.preferredDisplayCriteria = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    // MARK: - SponsorBlock

    private func checkSponsorSkip(at time: TimeInterval) {
        let decision = SponsorBlockDecisionEngine.decide(
            at: time,
            segments: sponsorSegments,
            settings: settings,
            isSkipInProgress: isSkipInFlight,
            duration: duration
        )
        switch decision {
        case .clearToast:
            toastSegment = nil
        case .showToast(let segment):
            if toastSegment?.id != segment.id {
                mpvPlayerLog.notice("[sponsorBlock] offering skip of \(segment.category.rawValue) at \(Int(time))s")
            }
            toastSegment = segment
        case .skip(let target, let segment):
            mpvPlayerLog.notice(
                "[sponsorBlock] auto-skip \(segment.category.rawValue) \(Int(time))s → \(Int(target))s")
            toastSegment = nil
            isSkipInFlight = true
            currentTime = target
            engine?.seek(to: target)
        case .skipToPlaybackEnd:
            toastSegment = nil
            handlePlaybackEnd()
        case .none:
            break
        }
    }

    /// Skips the segment currently offered by the skip button.
    func skipToastSegment() {
        guard let segment = toastSegment else { return }
        mpvPlayerLog.notice("[sponsorBlock] manual skip of \(segment.category.rawValue) → \(Int(segment.end))s")
        toastSegment = nil
        if duration > 0, segment.end >= duration - 2 {
            handlePlaybackEnd()
        } else {
            seek(to: segment.end)
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let engine, errorMessage == nil else { return }
        if videoEnded {
            // Replay. `seek` resumes by itself when leaving the ended state.
            seek(to: 0)
        } else {
            engine.setPaused(isPlaying)
            isPlaying.toggle()
        }
        if controlsVisible || !isPlaying {
            showControls()
        } else {
            flashProgress()
        }
    }

    /// Seeks to `time`. Leaving the ended state (or `resume`) also restarts playback —
    /// the core sits paused at the end of the file, so the engine unpauses after the seek.
    func seek(to time: TimeInterval, resume: Bool = false) {
        let upperBound = duration > 0 ? max(duration - 0.5, 0) : time
        let target = min(max(0, time), upperBound)
        let resumePlayback = resume || videoEnded
        if resumePlayback {
            videoEnded = false
            isPlaying = true
        }
        if duration > 0, settings.historyState == .enabled {
            let from = currentTime
            let duration = self.duration
            Task { await tracker.recordSeek(to: target, from: from, duration: duration) }
        }
        currentTime = target
        engine?.seek(to: target, resume: resumePlayback)
    }

    /// Jumps by `seconds`. With the controls hidden only the progress bar is flashed.
    func seekRelative(seconds: TimeInterval) {
        guard hasStartedPlayback, errorMessage == nil else { return }
        seek(to: currentTime + seconds)
        if controlsVisible {
            showControls()
        } else {
            flashProgress()
        }
    }

    private func flashProgress() {
        progressFlashVisible = true
        progressFlashTask?.cancel()
        progressFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.progressFlashVisible = false
        }
    }

    /// Moves the scrub position by `delta` seconds without seeking; the seek is committed
    /// after a short pause in input (or immediately via `commitScrub()`), so holding a
    /// direction on the remote costs one seek, not one per repeat.
    func scrub(by delta: TimeInterval) {
        guard duration > 0 else { return }
        if !isScrubbing {
            isScrubbing = true
            scrubTime = currentTime
        }
        scrubTime = min(max(0, scrubTime + delta), duration)
        showControls(autoHide: false)
        scrubCommitTask?.cancel()
        scrubCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.commitScrub()
        }
    }

    func commitScrub() {
        guard isScrubbing else { return }
        scrubCommitTask?.cancel()
        isScrubbing = false
        seek(to: scrubTime)
        showControls()
    }

    func setSpeed(_ speed: Double) {
        playbackSpeed = speed
        engine?.setSpeed(speed)
        showControls()
    }

    // MARK: - Quality

    /// Switches to another stream of the current video, keeping the playhead.
    func select(plan: MPVStreamPlan) {
        guard let engine, plan != activePlan else { return }
        activePlan = plan
        hardwareDecoder = nil
        decoderVerified = false
        // If this one fails, continue with the plans ranked below it.
        if let index = plans.firstIndex(of: plan) {
            untriedPlans = Array(plans[(index + 1)...])
        }
        isLoading = true
        mpvPlayerLog.notice("quality → \(plan.label) at \(Int(self.currentTime))s")
        engine.load(plan, startAt: currentTime, userAgent: activeClient?.userAgent, audioOverride: effectiveAudio?.url)
        engine.setSpeed(playbackSpeed)
        if !isPlaying { engine.setPaused(true) }
    }

    // MARK: - Captions

    func selectCaption(_ track: CaptionTrack?) {
        selectedCaption = track
        applyCaption(track)
        showControls()
    }

    private func applyCaption(_ track: CaptionTrack?) {
        engine?.setSubtitle(url: track?.baseURL, title: track?.name, language: track?.languageCode)
    }

    // MARK: - Controls visibility

    /// `--uitesting-keep-controls`: never auto-hide, so a test can inspect the overlay at leisure.
    private static let keepControlsForTesting = ProcessInfo.processInfo.arguments.contains("--uitesting-keep-controls")

    func showControls(autoHide: Bool = true) {
        controlsVisible = true
        controlsHideTask?.cancel()
        guard autoHide, isPlaying, !Self.keepControlsForTesting else { return }
        let timeout = max(settings.controlsHideTimeout, 2)
        controlsHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.isPlaying, !self.isScrubbing else { return }
            if self.holdControls {
                self.showControls()
            } else {
                self.controlsVisible = false
            }
        }
    }

    func hideControls() {
        controlsHideTask?.cancel()
        controlsVisible = false
    }

    // MARK: - Lifecycle

    func handleBackground() {
        guard let engine, hasStartedPlayback else { return }
        engine.setPaused(true)
        isPlaying = false
        engine.setVideoEnabled(false)
        saveProgress()
    }

    func handleForeground() {
        guard let engine, hasStartedPlayback else { return }
        engine.setVideoEnabled(true)
        showControls(autoHide: false)
    }

    /// Saves the resume position and reports watch time for the account history.
    private func saveProgress() {
        guard settings.historyState == .enabled, duration > 0, hasStartedPlayback else { return }
        let position = currentTime
        let duration = self.duration
        let tracker = self.tracker
        Task { await tracker.checkpoint(position: position, duration: duration) }
    }

    /// Ends the session: persists progress, then tears the mpv core down.
    func stop() {
        saveProgress()
        loadTask?.cancel()
        controlsHideTask?.cancel()
        progressFlashTask?.cancel()
        scrubCommitTask?.cancel()
        eventTask?.cancel()
        eventTask = nil
        isPlaying = false
        UIApplication.shared.isIdleTimerDisabled = false
        resetDisplayCriteria()
        engine?.shutdown()
    }
}

// MARK: - MPVClientProfile

/// The client profiles the mpv engine asks for streams, in order.
///
/// Far shorter than the AVPlayer cascade because mpv is not limited to HLS or
/// MP4-in-`AVMutableComposition`: any profile that returns direct adaptive URLs or an HLS
/// manifest is playable as-is.
enum MPVClientProfile: String, Sendable {
    /// visionOS client. Its fetch first seeds an anonymous youtube.com session (cookies +
    /// visitor data), which is what keeps a cold, signed-out request from being answered
    /// with a bot check — and the later profiles reuse that session.
    case visionOS
    /// Adaptive streams up to 4K whose URLs the CDN serves without a PoToken.
    case androidVR
    /// iOS client — HLS manifest, plus adaptive streams when a PoToken was minted.
    case ios
    /// Signed-in TV client — needed for age-restricted and members-only videos.
    case tvAuthenticated
    /// Embedded player — HLS for embeddable videos.
    case tvEmbedded

    static func order(isSignedIn: Bool) -> [MPVClientProfile] {
        isSignedIn
            ? [.visionOS, .androidVR, .ios, .tvAuthenticated, .tvEmbedded]
            : [.visionOS, .androidVR, .ios, .tvEmbedded]
    }

    func fetch(videoId: String, api: InnerTubeAPI) async throws -> PlayerInfo {
        switch self {
        case .visionOS: return try await api.fetchPlayerInfoVisionOS(videoId: videoId)
        case .androidVR: return try await api.fetchPlayerInfoAndroidVR(videoId: videoId)
        case .ios: return try await api.fetchPlayerInfo(videoId: videoId)
        case .tvAuthenticated: return try await api.fetchPlayerInfoAuthenticated(videoId: videoId)
        case .tvEmbedded: return try await api.fetchPlayerInfoTVEmbedded(videoId: videoId)
        }
    }

    /// User-Agent for media requests, matching the client that signed the stream URLs.
    var userAgent: String? {
        switch self {
        case .visionOS: return InnerTubeClients.VisionOS.userAgent
        case .androidVR: return InnerTubeClients.AndroidVR.userAgent
        case .ios: return InnerTubeClients.iOS.userAgent
        case .tvAuthenticated: return InnerTubeClients.TV.userAgent
        case .tvEmbedded: return InnerTubeClients.Web.userAgent
        }
    }
}
#endif
