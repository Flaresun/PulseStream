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

    // The Logical Queue
    var queue: [Track] = []
    var isLoopingCurrentTrack: Bool = false
    var currentLyricsBrowseId: String? = nil
     
    // MARK: - Private Properties
    // Not read by any View, so Observation's access-tracking is both unneeded
    // overhead and (per the historySession crash) an actual exclusivity-check
    // risk for internal engine bookkeeping — ignore it for all of these.
    @ObservationIgnored private var player: AVPlayer = AVPlayer()
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    // Tracks engagement for the currently-loaded track so we only record a
    // play once it's a genuine listen, not on every tap/skip.
    private struct HistorySession {
        let track: Track
        var maxElapsedSeconds: Double = 0
        var metThreshold: Bool = false
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
        NotificationCenter.default.removeObserver(self)
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
    func playTrack(_ track: Track) {
        // If we are selecting a new track from the UI, clear the queue and start fresh
        queue = [track]
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
    
    func seek(to percentage: Double) {
        guard player.currentItem != nil, duration > 0 else { return }
        // Update immediately so the scrubber reflects the new position without waiting
        // for the next periodic observer tick (up to 0.5 s later).
        playbackProgress = percentage
        elapsedSeconds = percentage * duration
        let targetTime = CMTime(seconds: percentage * duration, preferredTimescale: 600)
        player.seek(to: targetTime)
    }
    
    func skipToNext() {
        if isLoopingCurrentTrack {
            // Seek to beginning and play
            seek(to: 0)
            play()
            return
        }
        
        guard queue.count > 1 else {
            // Reached end of queue
            pause()
            return
        }
        
        // Remove current track, load next
        queue.removeFirst()
        if let nextTrack = queue.first {
            loadAndPlay(track: nextTrack)
        }
    }
    
    func addTracksToQueue(_ tracks: [Track]) {
        queue.append(contentsOf: tracks)
    }
    func skipToQueueIndex(_ index: Int) {
        guard index > 0, index < queue.count else { return }
        queue.removeFirst(index)
        if let track = queue.first {
            loadAndPlay(track: track)
        }
    }
    
    // MARK: - Private Loading Logic

    private func loadAndPlay(track: Track) {
        // Finalize whatever was playing before this call as a skip (a no-op if
        // it never crossed the engagement threshold, or nothing was playing).
        finalizeHistorySession(wasSkipped: true)
        historySession = HistorySession(track: track)

        currentTrack = track
        duration = Double(track.durationSeconds)
        playbackProgress = 0.0
        elapsedSeconds = 0.0
        hasAdvancedForCurrentTrack = false
        cacheStatus = nil
        currentLyricsBrowseId = nil
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
                    self.skipToNext()
                }
            }
        }
    }

    private func populateQueueFromServer(videoId: String, attempt: Int = 0) async {
        do {
            let playlist = try await APIClient.shared.getNextSongs(videoId: videoId)
            let tracks = playlist.tracks.compactMap { next -> Track? in
                guard next.videoId != videoId else { return nil }
                return next.toTrack()
            }
            await MainActor.run {
                self.currentLyricsBrowseId = playlist.lyrics
                guard let current = self.queue.first else { return }
                if self.queue.count == 1 {
                    self.queue = [current] + tracks
                }
            }
        } catch {
            guard attempt == 0, currentTrack?.videoId == videoId else {
                print("[AudioEngine] Queue population failed for \(videoId): \(error)")
                return
            }
            print("[AudioEngine] Queue population failed, retrying in 2s: \(error)")
            try? await Task.sleep(for: .seconds(2))
            await populateQueueFromServer(videoId: videoId, attempt: 1)
        }
    }
    
    // MARK: - Observers
    private func addPlayerObservers() {
        // Sync our play/pause state when the system interrupts us (e.g.
        // another app starts playing audio/video). iOS pauses playback for
        // us automatically, but without this our own `isPlaying` goes stale
        // and the play/pause button keeps showing "pause" even though
        // nothing is actually playing.
        NotificationCenter.default.addObserver(
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
        }

        // Observe playback progress
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, self.duration > 0, !self.isLoadingStream else { return }
            self.playbackProgress = time.seconds / self.duration
            self.elapsedSeconds = time.seconds
            self.updateNowPlayingPlaybackTime()
            self.updateHistorySessionProgress(elapsedSeconds: time.seconds)

            // The HLS-cached stream can run longer than the track's known
            // duration (trailing silence left over from transcoding), so
            // AVPlayerItemDidPlayToEndTime below can fire much later than
            // expected — or effectively never advance in a reasonable time.
            // Don't wait on it exclusively: advance as soon as we've reached
            // the track's real, known duration.
            if !self.hasAdvancedForCurrentTrack, time.seconds >= self.duration {
                self.advanceToNextTrack()
            }
        }

        // Observe when a song ends
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.advanceToNextTrack()
        }

        // Observe item status changes for both successful loads and failures
        // Note: duration is intentionally left as the static track metadata value
        // (set in loadAndPlay) and never overwritten from the player item — the
        // HLS-proxied stream's reported duration doesn't always match the true
        // song length, which was causing playback to appear padded with silence.
        let itemStatusPublisher = player.publisher(for: \.currentItem)
            .map { item -> AnyPublisher<AVPlayerItem.Status, Never> in
                guard let item else { return Just(.unknown).eraseToAnyPublisher() }
                return item.publisher(for: \.status).eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .share()

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

    /// Ends the current track's session and moves to the next one. Guarded so
    /// it only runs once per track, since both the "reached known duration"
    /// tick check and AVPlayerItemDidPlayToEndTime can trigger this.
    private func advanceToNextTrack() {
        guard !hasAdvancedForCurrentTrack else { return }
        hasAdvancedForCurrentTrack = true

        // A track that reached its end is unambiguously a real listen,
        // regardless of whether the periodic tick happened to cross the
        // engagement threshold in time (very short tracks).
        if historySession != nil {
            historySession?.maxElapsedSeconds = duration
            historySession?.metThreshold = true
        }
        finalizeHistorySession(wasSkipped: false)
        skipToNext()
    }

    // MARK: - Play History

    // Require at least 30s of listening, or half the track for anything
    // shorter, before a play counts — filters out accidental taps/skips.
    private func engagementThreshold(for duration: Double) -> Double {
        min(30, duration * 0.5)
    }

    private func updateHistorySessionProgress(elapsedSeconds: Double) {
        // Read into a local copy and write back once — reading and writing
        // `historySession` within the same statement (e.g. via `?.` chaining
        // on both sides) is an exclusivity violation under Observation's
        // access-tracked accessors and crashes at runtime.
        guard var session = historySession else { return }
        session.maxElapsedSeconds = max(session.maxElapsedSeconds, elapsedSeconds)
        if !session.metThreshold, elapsedSeconds >= engagementThreshold(for: duration) {
            session.metThreshold = true
        }
        historySession = session
    }

    private func finalizeHistorySession(wasSkipped: Bool) {
        guard let session = historySession, session.metThreshold else {
            historySession = nil
            return
        }
        historySession = nil

        let track = session.track
        let trackDuration = Double(track.durationSeconds)
        let completionRate = trackDuration > 0 ? min(1.0, session.maxElapsedSeconds / trackDuration) : 0
        let playedSeconds = Int(session.maxElapsedSeconds.rounded())

        Task {
            do {
                try await APIClient.shared.recordPlay(
                    videoId: track.videoId,
                    playedDurationSeconds: playedSeconds,
                    completionRate: completionRate,
                    wasSkipped: wasSkipped
                )
            } catch {
                print("[AudioEngine] Failed to record play history for \(track.videoId): \(error)")
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
        
        // Scrubbing from lock screen
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            
            let percentage = positionEvent.positionTime / self.duration
            self.seek(to: percentage)
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
                        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                        
                        await MainActor.run {
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
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
