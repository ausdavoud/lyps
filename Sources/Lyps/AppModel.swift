import AppKit
import CoreImage
import os
import SwiftUI

/// Read with: log stream --predicate 'subsystem == "app.lyps.Lyps"'. Song names are hashed.
private let log = Logger(subsystem: "app.lyps.Lyps", category: "playback")

@Observable
@MainActor
final class AppModel {
    enum LyricsStatus { case loading, found, unavailable }

    let settings: Settings
    let bridge = NowPlayingBridge()
    private let spotifyMute = SpotifyMute()
    @ObservationIgnored private lazy var lastAdMute = settings.adMute
    @ObservationIgnored private lazy var adMuter = AdMuter(
        mute: { [weak self] in
            guard let self else { return }
            self.settings.adMute.mute(spotifyOnly: { self.spotifyMute.mute() }, everything: SystemMute.mute)
        },
        unmute: { [weak self] in
            self?.spotifyMute.unmute()
            SystemMute.unmute()
        })

    private(set) var track: Track?
    private(set) var status = LyricsStatus.loading
    private(set) var lines: [LyricLine] = []
    /// Line being sung; -1 before the first line.
    private(set) var lineIndex = -1
    private(set) var artwork: NSImage?
    private(set) var tint = Color.clear
    private(set) var isVisible = false
    private(set) var bridgeHealthy = true
    private(set) var timingOffset: TimeInterval = 0
    /// Brief confirmation shown on the island after a nudge.
    private(set) var nudgeLabel: String?

    @ObservationIgnored var onVisibilityChange: (Bool) -> Void = { _ in }

    /// nil follows the automatic rules; true or false is the user's own choice via the shortcut.
    private var manual: Bool?
    private var idleHidden = false
    private var noLyricsExpired = false
    /// What the bridge reported. `state` is what Lyps acts on: the same, unless Telegram resumed a song silently.
    private var reported = PlaybackState()
    private var silentState: PlaybackState?
    private var state: PlaybackState { silentState ?? reported }
    private var silentResume: SilentResume?
    private var audioWatch: Timer?
    /// When Telegram's audio was first seen after the voice, so a brief blip doesn't count.
    private var audioOnSince: Date?
    private var artworkSource: String?
    private var telegramSong: Track?
    private var telegramArtwork: String?
    private var telegramPosition: TimeInterval = 0
    private var telegramRate: Double = 1
    private var spotifyAd = SpotifyAdClock()
    private var adEndCheck: DispatchWorkItem?
    private var spotifyPoll: Timer?
    private var lookup: Task<Void, Never>?
    private var lineTimer: DispatchWorkItem?
    private var hideTimer: DispatchWorkItem?
    private var nudgeLabelTimer: DispatchWorkItem?
    private var knownMisses: Set<Track> = []
    private let lrclib = LRCLIB()
    private let cache = LyricsCache.standard

    private static let pauseLinger: TimeInterval = 6
    private static let noLyricsLinger: TimeInterval = 4

    init(settings: Settings) {
        self.settings = settings
        bridge.onMessage = { [weak self] message in
            guard let self else { return }
            self.reported.apply(message)
            self.followTelegramAfterVoice()
            self.spotifyAd.observe(self.reported)
            self.updateAdMute()
            self.refresh()
        }
        bridge.onHealthChange = { [weak self] healthy in self?.bridgeHealthy = healthy }
        if settings.enabled { bridge.start() }
        updateSpotifyPoll()
    }

    // MARK: Commands

    func toggleShown() {
        if isVisible {
            manual = false
        } else {
            manual = settings.autoShow ? nil : true
            idleHidden = false
            noLyricsExpired = false
        }
        updateVisibility()
    }

    func togglePower() {
        settings.enabled.toggle()
    }

    /// Ignored unless the lyrics are on screen, so a stray keypress can't shift timing unseen.
    var canNudge: Bool { isVisible && status == .found }

    func nudge(by change: TimeInterval) {
        guard canNudge else { return }
        applyTimingOffset(TimingNudge.adjusted(timingOffset, by: change))
    }

    func resetTiming() {
        guard canNudge else { return }
        applyTimingOffset(0)
    }

    private func applyTimingOffset(_ offset: TimeInterval) {
        guard let track else { return }
        timingOffset = offset
        settings.setTimingOffset(offset, for: track)
        syncLine()

        nudgeLabel = TimingNudge.label(offset)
        nudgeLabelTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.nudgeLabel = nil }
        nudgeLabelTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timer)
    }

    private func updateSpotifyPoll() {
        let wanted = settings.enabled && settings.adMute != .off
        if wanted, spotifyPoll == nil {
            spotifyPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollSpotify() }
            }
        } else if !wanted {
            spotifyPoll?.invalidate()
            spotifyPoll = nil
        }
    }

    private func pollSpotify() {
        SpotifyScript.ask { [weak self] spotify in
            guard let self, self.settings.adMute != .off else { return }
            self.spotifyAd.observe(spotify)
            self.updateAdMute()
        }
    }

    private func updateAdMute() {
        adMuter.update(adPlaying: settings.adMute != .off && spotifyAd.adPlaying())
        adEndCheck?.cancel()
        guard let endsAt = spotifyAd.endsAt, endsAt > Date() else { return }
        // Wakes when the ad should end, in case Spotify isn't the app macOS reports by then.
        let check = DispatchWorkItem { [weak self] in self?.updateAdMute() }
        adEndCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + endsAt.timeIntervalSinceNow + 0.1, execute: check)
    }

    /// Gives sound back now: on quit, and when ad muting is turned off.
    func releaseAdMute() {
        adMuter.release()
    }

    /// Settings changed: sources, the master switch, and so on.
    func settingsChanged() {
        if settings.adMute == .off || !settings.enabled { adMuter.release() }
        let prompts = AdMuteMode.prompts(from: lastAdMute, to: settings.adMute)
        if prompts.audioCapture { spotifyMute.requestPermission() }
        if prompts.automation { SpotifyScript.requestPermission() }
        lastAdMute = settings.adMute
        updateSpotifyPoll()
        if settings.enabled {
            bridge.start()
        } else {
            bridge.stop()
            reported = PlaybackState()
            endSilentResume()
        }
        refresh()
    }

    // MARK: Playback

    private func refresh() {
        log.debug("update app=\(self.state.bundleID, privacy: .public) title=\(self.state.title, privacy: .private(mask: .hash)) titleEmpty=\(self.state.title.isEmpty, privacy: .public) playing=\(self.state.isPlaying, privacy: .public) position=\(self.state.position(), privacy: .public) duration=\(self.state.duration, privacy: .public)")
        if AdDetector.isSpotifyAd(state) {
            log.debug("ignored: Spotify ad")
            return clearTrack()
        }
        guard settings.enabled, let source = Source(bundleID: state.bundleID), settings.allows(source) else {
            log.debug("ignored: off, unknown app or source disabled")
            clearTrack()
            return
        }

        var song = Track(title: state.title, artist: state.artist, album: state.album, duration: state.duration)
        var artworkData = state.artworkBase64
        if source == .telegram {
            if let resumed = TelegramResume.song(title: state.title, position: state.position(), remembered: telegramSong, pausedAt: telegramPosition) {
                song = resumed
                log.info("telegram: no title, continuing remembered song \(resumed.title, privacy: .private(mask: .hash))")
                // What's reported now may still be the voice sender's picture.
                artworkData = telegramArtwork
            } else if Privacy.isSafeTelegramLookup(title: state.title, artist: state.artist) {
                telegramSong = song
                telegramArtwork = artworkData
                telegramPosition = state.position()
                if state.isPlaying { telegramRate = state.rate }
            } else {
                if state.isPlaying, silentResume == nil, let telegramSong {
                    // A voice message just paused this song. Telegram may resume it without saying so.
                    silentResume = SilentResume(song: telegramSong, artwork: telegramArtwork, rate: telegramRate, pausedAt: telegramPosition)
                    log.info("telegram: voice paused the song at \(self.telegramPosition, privacy: .public)s; watching for it to resume")
                }
                log.info("telegram: refused (voice message, or no title that isn't a resume) remembered=\(self.telegramSong != nil, privacy: .public) pausedAt=\(self.telegramPosition, privacy: .public)")
                clearTrack()
                return
            }
        }
        guard !song.title.isEmpty else {
            log.debug("ignored: no title")
            clearTrack()
            return
        }

        if track?.title != song.title || track?.artist != song.artist {
            // macOS reports the last player, paused, whenever another stops, so wait until it plays.
            guard state.isPlaying else {
                log.debug("ignored: new song isn't playing")
                clearTrack()
                return
            }
            log.info("new song \(song.title, privacy: .private(mask: .hash)) from \(source.rawValue, privacy: .public)")
            begin(song)
        } else if song.duration > 0 {
            track?.duration = song.duration
        }

        updateArtwork(artworkData)
        syncLine()
        updateIdleTimer()
        updateVisibility()
    }

    // MARK: Telegram resuming silently after a voice message

    /// Decides, on each bridge update, whether Telegram's audio is the only sign of the song.
    private func followTelegramAfterVoice() {
        guard var resume = silentResume, settings.enabled else { return endSilentResume() }
        let telegram = Source(bundleID: reported.bundleID) == .telegram
        let realSong = telegram && !reported.title.isEmpty
            && Privacy.isSafeTelegramLookup(title: reported.title, artist: reported.artist)
        let resumedWithoutTitle = telegram && TelegramResume.song(
            title: reported.title, position: reported.position(), remembered: telegramSong, pausedAt: telegramPosition) != nil
        if (realSong && reported.isPlaying) || resumedWithoutTitle {
            log.info("telegram: reporting a song again; silent resume no longer needed")
            return endSilentResume()
        }
        if telegram, reported.isPlaying {
            // A voice message is playing, which is Telegram audio too. The song stays paused.
            if resume.isPlaying {
                resume.pause(at: Date())
                silentResume = resume
                silentState = nil
                telegramPosition = resume.position
            }
            stopAudioWatch()
            return
        }
        // A finished voice reported with a position longer than itself is showing the song's position.
        if telegram, !resume.isPlaying, reported.duration > 0, reported.position() > reported.duration + 1 {
            resume.correct(pausedAt: reported.position())
            silentResume = resume
            telegramPosition = resume.position
            log.info("telegram: song will resume at \(resume.position, privacy: .public)s, as reported")
        }
        startAudioWatch()
    }

    private func startAudioWatch() {
        guard audioWatch == nil else { return }
        audioOnSince = nil
        audioWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTelegramAudio() }
        }
    }

    private func stopAudioWatch() {
        audioWatch?.invalidate()
        audioWatch = nil
        audioOnSince = nil
    }

    private func endSilentResume() {
        stopAudioWatch()
        guard silentResume != nil else { return }
        silentResume = nil
        silentState = nil
    }

    private func checkTelegramAudio() {
        guard var resume = silentResume else { return stopAudioWatch() }
        let now = Date()
        let wasPlaying = resume.isPlaying
        if TelegramAudio.isPlaying() {
            let since = audioOnSince ?? now
            audioOnSince = since
            // Needs a full second of sound, so a voice message's tail isn't taken for the song.
            if !resume.isPlaying, now.timeIntervalSince(since) >= 1 {
                resume.play(since: since)
                log.info("telegram: song resumed silently at \(resume.position, privacy: .public)s")
            }
        } else {
            audioOnSince = nil
            if resume.isPlaying {
                resume.pause(at: now)
                log.info("telegram: silent song paused at \(resume.position, privacy: .public)s")
            }
        }

        if resume.isFinished(at: now) {
            log.info("telegram: silent song reached its end")
            endSilentResume()
            refresh()
        } else if resume.isPlaying != wasPlaying {
            silentResume = resume
            silentState = resume.reported
            telegramPosition = resume.position(at: now)
            refresh()
        }
    }

    private func clearTrack() {
        lookup?.cancel()
        lineTimer?.cancel()
        hideTimer?.cancel()
        track = nil
        lines = []
        lineIndex = -1
        updateVisibility()
    }

    private func begin(_ newTrack: Track) {
        track = newTrack
        lines = []
        lineIndex = -1
        status = .loading
        timingOffset = settings.timingOffset(for: newTrack)
        nudgeLabelTimer?.cancel()
        nudgeLabel = nil
        noLyricsExpired = false
        idleHidden = !state.isPlaying

        lookup?.cancel()
        lookup = Task { [weak self] in
            guard let self else { return }
            let found = await self.lyrics(for: newTrack)
            guard !Task.isCancelled, self.track?.title == newTrack.title, self.track?.artist == newTrack.artist else { return }
            self.lines = found
            self.status = found.isEmpty ? .unavailable : .found
            log.info("lyrics: \(found.count, privacy: .public) lines for \(newTrack.title, privacy: .private(mask: .hash))")
            self.syncLine()
            self.updateIdleTimer()
            self.updateVisibility()
        }
    }

    private func lyrics(for track: Track) async -> [LyricLine] {
        if let cached = cache.load(track) { return cached }
        if knownMisses.contains(track) { return [] }
        do {
            let found = try await lrclib.lyrics(for: track)
            if found.isEmpty {
                knownMisses.insert(track)
            } else {
                cache.save(found, for: track)
            }
            return found
        } catch {
            // Not remembered as a miss, so the song is tried again next time.
            return []
        }
    }

    /// Sets the current line and wakes exactly when the next one is due, so nothing polls.
    private func syncLine() {
        lineTimer?.cancel()
        guard !lines.isEmpty else { return }
        let position = state.position() - timingOffset
        let index = LRC.index(in: lines, at: position) ?? -1
        if index != lineIndex { lineIndex = index }

        guard state.isPlaying, index + 1 < lines.count else { return }
        let delay = max((lines[index + 1].time - position) / state.rate, 0.01)
        let timer = DispatchWorkItem { [weak self] in self?.syncLine() }
        lineTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    /// Hides after a pause, or shortly after learning a song has no synced lyrics.
    private func updateIdleTimer() {
        hideTimer?.cancel()
        if state.isPlaying { idleHidden = false }

        let paused = !state.isPlaying
        let noLyrics = status == .unavailable
        guard paused || noLyrics, !idleHidden, !noLyricsExpired else { return }

        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if noLyrics { self.noLyricsExpired = true }
            if paused { self.idleHidden = true }
            self.updateVisibility()
        }
        hideTimer = timer
        let delay = noLyrics ? Self.noLyricsLinger : Self.pauseLinger
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func updateVisibility() {
        let automatic = settings.autoShow && !idleHidden && !noLyricsExpired
        let wanted = settings.enabled && track != nil && (manual ?? automatic)
        guard wanted != isVisible else { return }
        isVisible = wanted
        log.info("island \(wanted ? "shown" : "hidden", privacy: .public) track=\(self.track != nil, privacy: .public) manual=\(String(describing: self.manual), privacy: .public) idle=\(self.idleHidden, privacy: .public) noLyricsExpired=\(self.noLyricsExpired, privacy: .public)")
        onVisibilityChange(wanted)
    }

    // MARK: Artwork

    private func updateArtwork(_ source: String?) {
        guard source != artworkSource else { return }
        artworkSource = source
        artwork = source.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        tint = artwork.flatMap(Self.averageColor) ?? .clear
    }

    private static func averageColor(of image: NSImage) -> Color? {
        guard let data = image.tiffRepresentation, let input = CIImage(data: data),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent),
              ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}
