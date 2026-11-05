import AppKit
import CoreImage
import SwiftUI

@Observable
@MainActor
final class AppModel {
    enum LyricsStatus { case loading, found, unavailable }

    let settings: Settings
    let bridge = NowPlayingBridge()

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
    private var state = PlaybackState()
    private var artworkSource: String?
    private var telegramSong: Track?
    private var telegramArtwork: String?
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
            self.state.apply(message)
            self.refresh()
        }
        bridge.onHealthChange = { [weak self] healthy in self?.bridgeHealthy = healthy }
        if settings.enabled { bridge.start() }
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

    /// Settings changed: sources, the master switch, and so on.
    func settingsChanged() {
        if settings.enabled {
            bridge.start()
        } else {
            bridge.stop()
            state = PlaybackState()
        }
        refresh()
    }

    // MARK: Playback

    private func refresh() {
        guard settings.enabled, let source = Source(bundleID: state.bundleID), settings.allows(source) else {
            clearTrack()
            return
        }

        var song = Track(title: state.title, artist: state.artist, album: state.album, duration: state.duration)
        var artworkData = state.artworkBase64
        if source == .telegram {
            if let resumed = TelegramResume.song(title: state.title, position: state.position(), remembered: telegramSong) {
                song = resumed
                // What's reported now may still be the voice sender's picture.
                artworkData = telegramArtwork
            } else if Privacy.isSafeTelegramLookup(title: state.title, artist: state.artist) {
                telegramSong = song
                telegramArtwork = artworkData
            } else {
                clearTrack()
                return
            }
        }
        guard !song.title.isEmpty else {
            clearTrack()
            return
        }

        if track?.title != song.title || track?.artist != song.artist {
            begin(song)
        } else if song.duration > 0 {
            track?.duration = song.duration
        }

        updateArtwork(artworkData)
        syncLine()
        updateIdleTimer()
        updateVisibility()
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
