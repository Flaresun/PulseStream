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

    // The Logical Queue
    var queue: [Track] = []
    var isLoopingCurrentTrack: Bool = false
    var currentLyricsBrowseId: String? = nil
     
    // MARK: - Private Properties
    private var player: AVPlayer = AVPlayer()
    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()
    
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
        guard let currentItem = player.currentItem, duration > 0 else { return }
        let timeInSeconds = percentage * duration
        let targetTime = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
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
    
    // MARK: - Private Loading Logic

    private func loadAndPlay(track: Track) {
        currentTrack = track
        duration = Double(track.durationSeconds)
        playbackProgress = 0.0
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

    private func populateQueueFromServer(videoId: String) async {
        do {
            let playlist = try await APIClient.shared.getNextSongs(videoId: videoId)
            let tracks = playlist.tracks.compactMap { next -> Track? in
                // Skip the current track if it appears first in the watch playlist
                guard next.videoId != videoId else { return nil }
                return next.toTrack()
            }
            await MainActor.run {
                self.currentLyricsBrowseId = playlist.lyrics
                guard let current = self.queue.first else { return }
                // Only populate server queue if the user hasn't manually added tracks yet
                if self.queue.count == 1 {
                    self.queue = [current] + tracks
                }
            }
        } catch {
            // Non-fatal: queue stays with the current track only
        }
    }
    
    // MARK: - Observers
    private func addPlayerObservers() {
        // Observe playback progress
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, self.duration > 0 else { return }
            self.playbackProgress = time.seconds / self.duration
            self.updateNowPlayingPlaybackTime()
        }

        // Observe when a song ends
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.skipToNext()
        }

        // Surface item-level load failures (e.g. rejected CDN URL, unsupported format)
        player.publisher(for: \.currentItem)
            .map { item -> AnyPublisher<AVPlayerItem.Status, Never> in
                guard let item else { return Just(.unknown).eraseToAnyPublisher() }
                return item.publisher(for: \.status).eraseToAnyPublisher()
            }
            .switchToLatest()
            .filter { $0 == .failed }
            .receive(on: DispatchQueue.main)
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
