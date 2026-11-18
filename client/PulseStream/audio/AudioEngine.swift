import Foundation
import AVFoundation
import MediaPlayer
import Combine
import Observation

@Observable
final class AudioEngine {

    // MARK: - State
    var currentTrack: Track?
    var isPlaying: Bool = false
    var isLoadingStream: Bool = false
    var playbackProgress: Double = 0.0 // 0.0 to 1.0
    var duration: Double = 0.0
    // Raw elapsed playback time in seconds, updated on the same tick as
    // playbackProgress. Lyrics sync reads this directly instead of
    // back-deriving elapsed time via `playbackProgress * duration`.
    var elapsedSeconds: Double = 0.0

    // S3 cache state for the current track. READY means it's fully cached and
    // streaming from our own S3-backed HLS endpoint rather than YouTube's CDN.
    var cacheStatus: S3Status? = nil

    // The Logical Queue. Unlike a consume-as-you-go queue, this is the whole
    // session timeline: everything before `currentIndex` has already played and
    // stays around so the user can step back through it.
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0
    var isLoopingCurrentTrack: Bool = false

    var currentLyricsBrowseId: String? = nil
    // True from the moment a track loads until the lookup that carries its
    // lyrics browse ID has either landed or definitively failed, so the UI can
    // tell "no lyrics for this song" apart from "not fetched yet".
    var isResolvingLyrics: Bool = false

    /// Tracks queued after the current one. Empty once the queue is exhausted.
    var upcoming: [Track] {
        guard currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    /// Whether the forward control does anything — looping always does.
    var hasNextTrack: Bool {
        isLoopingCurrentTrack || currentIndex + 1 < queue.count
    }

    /// The back control is always live while a track is loaded: with nothing
    /// behind it, it restarts the current song rather than going nowhere.
    var hasPreviousTrack: Bool {
        currentTrack != nil
    }

    // MARK: - Private Properties
    // Not read by any View, so Observation's access-tracking is both unneeded
    // overhead and (per the historySession crash) an actual exclusivity-check
    // risk for internal engine bookkeeping — ignore it for all of these.
    @ObservationIgnored private var player: AVPlayer = AVPlayer()
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    // How many already-played tracks to keep behind `currentIndex`. Deep enough
    // to step back through a listening session, bounded so a long session
    // doesn't grow the queue without limit.
    @ObservationIgnored private let maxPlayedHistory = 50

    // Refill the queue from the server once fewer than this many tracks are
    // left ahead, so autoplay never runs out mid-session.
    @ObservationIgnored private static let autoplayRefillThreshold = 5

    // Tracks engagement for the currently-loaded track so we only record a
    // play once it's a genuine listen, not on every tap/skip.
    private struct HistorySession {
        let track: Track
        var recorded: Bool = false
    }
    @ObservationIgnored private var historySession: HistorySession?

    // Guards against advancing to the next track twice for the same item —
    // both the "reached known duration" check below and AVPlayerItemDidPlayToEndTime
    // can fire for the same completion (see addPlayerObservers).
    @ObservationIgnored private var hasAdvancedForCurrentTrack = false

    // MARK: - Initialization
    init() {
        configureAudioSession()
        setupRemoteCommandCenter()
        addPlayerObservers()
    }

    deinit {
        removeTimeObserver()
        // Block-based observers aren't covered by removeObserver(self) — they're
        // keyed on the returned token, not on the observer object.
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Audio Session Configuration
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback allows audio to play when screen is locked/off
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    // MARK: - Playback Controls

    /// Starts `track` now. Anything queued ahead of the current track is
    /// dropped (the user picked something else), but everything already played
    /// is kept so the back control still walks the full session.
    func playTrack(_ track: Track) {
        if queue.isEmpty {
            queue = [track]
            currentIndex = 0
        } else {
            queue = Array(queue.prefix(currentIndex + 1)) + [track]
            currentIndex = queue.count - 1
            trimPlayedHistory()
        }
        loadAndPlay(track: track)
    }

    func play() {
        player.play()
        isPlaying = true
        updateNowPlayingInfo(isPlaying: true)
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo(isPlaying: false)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func toggleLoopCurrentTrack() {
        isLoopingCurrentTrack.toggle()
    }

    func seek(to percentage: Double) {
        guard player.currentItem != nil, duration > 0 else { return }
        // Update immediately so the scrubber reflects the new position without waiting
        // for the next periodic observer tick (up to 0.5 s later).
        let clamped = min(max(percentage, 0), 1)
        playbackProgress = clamped
        elapsedSeconds = clamped * duration
        // Seeking backwards out of the end of a track re-arms end-of-track
        // handling; without this a looped or rewound track would play out and
        // then sit there, since advanceToNextTrack only fires once per load.
        if clamped < 1 { hasAdvancedForCurrentTrack = false }
        let targetTime = CMTime(seconds: clamped * duration, preferredTimescale: 600)
        player.seek(to: targetTime)
    }

    func skipToNext() {
        if isLoopingCurrentTrack {
            // Each time round the loop is a fresh listen as far as history is
            // concerned, so the play gets logged again rather than once ever.
            restartCurrentTrack(asNewListen: true)
            return
        }

        guard currentIndex + 1 < queue.count else {
            // Reached end of queue
            pause()
            return
        }

        currentIndex += 1
        loadAndPlay(track: queue[currentIndex])
        trimPlayedHistory()
    }

    /// Mirrors the platform convention: part-way into a song, "previous"
    /// restarts it; near the start, it steps back to the song before.
    func skipToPrevious() {
        guard currentIndex > 0, elapsedSeconds <= 3 else {
            restartCurrentTrack()
            return
        }
        currentIndex -= 1
        loadAndPlay(track: queue[currentIndex])
    }

    private func restartCurrentTrack(asNewListen: Bool = false) {
        guard let track = currentTrack else { return }
        if asNewListen { historySession = HistorySession(track: track) }
        hasAdvancedForCurrentTrack = false
        playbackProgress = 0
        elapsedSeconds = 0
        player.seek(to: .zero)
        play()
    }

    func addTracksToQueue(_ tracks: [Track]) {
        queue.append(contentsOf: tracks)
    }

    /// Jumps to an absolute position in `queue` — forwards or backwards.
    func skipToQueueIndex(_ index: Int) {
        guard index >= 0, index < queue.count, index != currentIndex else { return }
        currentIndex = index
        loadAndPlay(track: queue[index])
        trimPlayedHistory()
    }

    private func trimPlayedHistory() {
        let excess = currentIndex - maxPlayedHistory
        guard excess > 0 else { return }
        queue.removeFirst(excess)
        currentIndex -= excess
    }

    // MARK: - Private Loading Logic

    private func loadAndPlay(track: Track) {
        historySession = HistorySession(track: track)

        currentTrack = track
        duration = Double(track.durationSeconds)
        playbackProgress = 0.0
        elapsedSeconds = 0.0
        hasAdvancedForCurrentTrack = false
        cacheStatus = nil
        currentLyricsBrowseId = nil
        isResolvingLyrics = true
        isLoadingStream = true

        setupNowPlayingInfo(for: track)

        Task {
            await resolveWithRetry(track: track)
            // Only populate queue if this track is still active (retries may have skipped it)
            if currentTrack?.videoId == track.videoId {
                await populateQueueFromServer(videoId: track.videoId)
            }
        }
    }

    private func resolveWithRetry(track: Track, attempt: Int = 0) async {
        let maxAttempts = 4
        do {
            let response = try await APIClient.shared.resolveStream(for: track)

            guard let streamURL = URL(string: response.streamUrl) else {
                await MainActor.run { self.isLoadingStream = false }
                return
            }

            let playerItem = AVPlayerItem(url: streamURL)
            await MainActor.run {
                self.cacheStatus = response.s3Status
                self.player.replaceCurrentItem(with: playerItem)
                self.isLoadingStream = false
                self.play()
            }
        } catch {
            if attempt < maxAttempts - 1 {
                // Exponential backoff: 1s, 2s, 4s
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                // Abort retry if the user already switched tracks
                if currentTrack?.videoId == track.videoId {
                    await resolveWithRetry(track: track, attempt: attempt + 1)
                }
            } else {
                await MainActor.run {
                    self.isLoadingStream = false
                    // Move past the track rather than going through skipToNext,
                    // which with repeat enabled would restart a stream that has
                    // just proven it can't load and leave playback stuck.
                    guard self.currentIndex + 1 < self.queue.count else {
                        self.pause()
                        return
                    }
                    self.currentIndex += 1
                    self.loadAndPlay(track: self.queue[self.currentIndex])
                }
            }
        }
    }

    /// Fetches the watch-playlist continuation for `videoId`. This is also the
    /// only source of the lyrics browse ID, so a failure here costs the user
    /// lyrics as well as autoplay — hence the retries.
    private func populateQueueFromServer(videoId: String, attempt: Int = 0) async {
        let maxAttempts = 3
        do {
            let playlist = try await APIClient.shared.getNextSongs(videoId: videoId)
            await MainActor.run {
                guard self.currentTrack?.videoId == videoId else { return }
                self.currentLyricsBrowseId = playlist.lyrics
                self.isResolvingLyrics = false

                // Top the queue up whenever it's running dry, so autoplay keeps
                // going for as long as the user listens. A queue the user has
                // already stacked several tracks deep is left alone.
                let remaining = self.queue.count - 1 - self.currentIndex
                guard remaining < Self.autoplayRefillThreshold else { return }

                let alreadyQueued = Set(self.queue[self.currentIndex...].map(\.videoId))
                self.queue.append(contentsOf: playlist.tracks.compactMap { next -> Track? in
                    guard next.videoId != videoId, !alreadyQueued.contains(next.videoId) else { return nil }
                    return next.toTrack()
                })
            }
        } catch {
            guard attempt + 1 < maxAttempts, currentTrack?.videoId == videoId else {
                print("[AudioEngine] Queue population failed for \(videoId): \(error)")
                await MainActor.run {
                    if self.currentTrack?.videoId == videoId { self.isResolvingLyrics = false }
                }
                return
            }
            print("[AudioEngine] Queue population failed, retrying: \(error)")
            try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
            await populateQueueFromServer(videoId: videoId, attempt: attempt + 1)
        }
    }

    // MARK: - Observers
    private func addPlayerObservers() {
        // Sync our play/pause state when the system interrupts us (e.g.
        // another app starts playing audio/video). iOS pauses playback for
        // us automatically, but without this our own `isPlaying` goes stale
        // and the play/pause button keeps showing "pause" even though
        // nothing is actually playing.
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                  type == .began,
                  self.isPlaying
            else { return }
            self.pause()
        })

        // Observe playback progress
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isLoadingStream else { return }
            // Elapsed time is tracked even when the duration is still unknown —
            // lyrics sync and the engagement threshold both depend on it.
            self.elapsedSeconds = time.seconds
            if self.duration > 0 {
                self.playbackProgress = min(1, time.seconds / self.duration)
            }
            self.updateNowPlayingPlaybackTime()
            self.updateHistorySessionProgress(elapsedSeconds: time.seconds)

            // The HLS-cached stream can run longer than the track's known
            // duration (trailing silence left over from transcoding), so
            // AVPlayerItemDidPlayToEndTime below can fire much later than
            // expected — or effectively never advance in a reasonable time.
            // Don't wait on it exclusively: advance as soon as we've reached
            // the track's real, known duration.
            if self.duration > 0, !self.hasAdvancedForCurrentTrack, time.seconds >= self.duration {
                self.advanceToNextTrack()
            }
        }

        // Observe when a song ends
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Scoped to our own item: the notification carries no object filter
            // at registration time because the item is swapped on every track.
            guard let self,
                  let item = notification.object as? AVPlayerItem,
                  item === self.player.currentItem
            else { return }
            self.advanceToNextTrack()
        })

        // Observe item status changes for both successful loads and failures
        let itemStatusPublisher = player.publisher(for: \.currentItem)
            .map { item -> AnyPublisher<AVPlayerItem.Status, Never> in
                guard let item else { return Just(.unknown).eraseToAnyPublisher() }
                return item.publisher(for: \.status).eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .share()

        // Fill in a duration the track metadata didn't carry. Search results,
        // watch-playlist entries and Home rows can all arrive without one, and
        // a zero duration used to freeze the scrubber, stop the track ever
        // advancing, and keep the play from being recorded in history.
        // Metadata still wins when present — the HLS-proxied stream's reported
        // duration doesn't always match the true song length.
        itemStatusPublisher
            .filter { $0 == .readyToPlay }
            .sink { [weak self] _ in
                guard let self, self.duration <= 0 else { return }
                let itemDuration = self.player.currentItem?.duration.seconds ?? .nan
                guard itemDuration.isFinite, itemDuration > 0 else { return }
                self.duration = itemDuration
                // The lock screen was handed the metadata duration (0) when the
                // track loaded; correct it so scrubbing there works too.
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    info[MPMediaItemPropertyPlaybackDuration] = itemDuration
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
            .store(in: &cancellables)

        // Surface load failures
        itemStatusPublisher
            .filter { $0 == .failed }
            .sink { [weak self] _ in
                guard let self else { return }
                let error = player.currentItem?.error
                print("[AudioEngine] ❌ Item failed: \(error?.localizedDescription ?? "unknown error")")
                print("[AudioEngine] ❌ Underlying: \((error as NSError?)?.userInfo[NSUnderlyingErrorKey] ?? "none")")
                isPlaying = false
                isLoadingStream = false
            }
            .store(in: &cancellables)

        // Surface buffering stalls so we know if the player is waiting vs truly broken
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, status == .waitingToPlayAtSpecifiedRate else { return }
                print("[AudioEngine] ⏳ Stalled — reason: \(player.reasonForWaitingToPlay?.rawValue ?? "unknown")")
            }
            .store(in: &cancellables)
    }

    /// Ends the current track and moves on. Guarded so it only runs once per
    /// load, since both the "reached known duration" tick check and
    /// AVPlayerItemDidPlayToEndTime can trigger this.
    private func advanceToNextTrack() {
        guard !hasAdvancedForCurrentTrack else { return }
        hasAdvancedForCurrentTrack = true

        // A track that reached its end is unambiguously a real listen, even if
        // it was too short to cross the engagement threshold.
        recordPlayIfNeeded(playedSeconds: duration > 0 ? duration : elapsedSeconds)
        skipToNext()
    }

    // MARK: - Play History

    // Require at least 30s of listening, or half the track for anything
    // shorter, before a play counts — filters out accidental taps/skips.
    // A duration of 0 means we never learned the track's length, so fall back
    // to the flat 30s rather than a threshold of zero that logs every tap.
    private func engagementThreshold(for duration: Double) -> Double {
        duration > 0 ? min(30, duration * 0.5) : 30
    }

    private func updateHistorySessionProgress(elapsedSeconds: Double) {
        guard elapsedSeconds >= engagementThreshold(for: duration) else { return }
        recordPlayIfNeeded(playedSeconds: elapsedSeconds)
    }

    /// Logs the play as soon as it qualifies, rather than waiting for the track
    /// to end or be skipped — a play used to be lost entirely if the app was
    /// backgrounded or killed part-way through a song.
    private func recordPlayIfNeeded(playedSeconds: Double) {
        // Read into a local copy and write back once — reading and writing
        // `historySession` within the same statement (e.g. via `?.` chaining
        // on both sides) is an exclusivity violation under Observation's
        // access-tracked accessors and crashes at runtime.
        guard var session = historySession, !session.recorded else { return }
        session.recorded = true
        historySession = session

        let track = session.track
        let trackDuration = duration > 0 ? duration : Double(track.durationSeconds)
        let completionRate = trackDuration > 0 ? min(1.0, playedSeconds / trackDuration) : 0

        Task {
            // A failed write used to vanish with nothing but a log line, which
            // is one of the ways plays went missing from History — the server
            // can briefly refuse the first request after an idle period while
            // its connection pool wakes up.
            for attempt in 0..<3 {
                do {
                    try await APIClient.shared.recordPlay(
                        videoId: track.videoId,
                        playedDurationSeconds: Int(playedSeconds.rounded()),
                        completionRate: completionRate,
                        wasSkipped: false
                    )
                    return
                } catch APIError.requestFailed(404) {
                    // The track isn't in the server's catalogue, so no amount of
                    // retrying will help — /stream/resolve registers it, and
                    // that must have failed for this track.
                    print("[AudioEngine] Play not recorded — \(track.videoId) unknown to the server")
                    return
                } catch {
                    print("[AudioEngine] Record play attempt \(attempt + 1) failed for \(track.videoId): \(error)")
                    try? await Task.sleep(for: .seconds(2 << attempt))
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
}

// MARK: - Lock Screen & Control Center Integration (MPRemoteCommandCenter)
extension AudioEngine {

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        // Pause
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        // Next
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipToNext()
            return .success
        }

        // Previous
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.skipToPrevious()
            return .success
        }

        // Scrubbing from lock screen
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                  self.duration > 0 else {
                return .commandFailed
            }

            self.seek(to: positionEvent.positionTime / self.duration)
            return .success
        }
    }

    private func setupNowPlayingInfo(for track: Track) {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artists.first?.name ?? "Unknown Artist"
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = track.durationSeconds

        // Fetch artwork asynchronously for the lock screen
        if let url = track.primaryThumbnailURL {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                        await MainActor.run {
                            // Merge into whatever is current rather than
                            // restoring the snapshot taken above — the user may
                            // have changed track while this download was in
                            // flight, and we'd otherwise resurrect stale info.
                            guard self.currentTrack?.videoId == track.videoId,
                                  var info = MPNowPlayingInfoCenter.default().nowPlayingInfo
                            else { return }
                            info[MPMediaItemPropertyArtwork] = artwork
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                        }
                    }
                } catch {
                    print("Failed to fetch lock screen artwork")
                }
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlayingInfo(isPlaying: Bool) {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }

        // This tells the lock screen to show the 'pause' button if playing, and 'play' if paused
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlayingPlaybackTime() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
