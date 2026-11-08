import AppKit
import CoreAudio
import os

/// The players Lyps follows. Anything else macOS reports is ignored.
enum Source: String, CaseIterable {
    case spotify, telegram

    init?(bundleID: String) {
        switch bundleID {
        case "com.spotify.client": self = .spotify
        case "com.tdesktop.Telegram", "ru.keepcoder.Telegram": self = .telegram
        default: return nil
        }
    }
}

/// A Telegram song paused for a voice message. When the voice ends, Telegram resumes the song but
/// may tell Now Playing nothing (voice closed) or keep reporting the finished voice (voice played
/// out). Telegram's audio output is then the only sign the song is playing, so its position is
/// kept here from the pause point.
struct SilentResume {
    let song: Track
    let artwork: String?
    let rate: Double
    private(set) var position: TimeInterval
    /// When playback last started; nil while paused.
    private(set) var startedAt: Date?

    init(song: Track, artwork: String?, rate: Double, pausedAt: TimeInterval) {
        (self.song, self.artwork, self.rate, position) = (song, artwork, rate, pausedAt)
    }

    var isPlaying: Bool { startedAt != nil }

    func position(at now: Date) -> TimeInterval {
        position + (startedAt.map { now.timeIntervalSince($0) * rate } ?? 0)
    }

    mutating func play(since start: Date) {
        guard startedAt == nil else { return }
        startedAt = start
    }

    /// After a voice plays out, Telegram may report the song's exact position; better than the estimate.
    mutating func correct(pausedAt exact: TimeInterval) {
        guard startedAt == nil else { return }
        position = exact
    }

    mutating func pause(at now: Date) {
        position = position(at: now)
        startedAt = nil
    }

    /// Past the end, Telegram has moved on to another track or stopped.
    func isFinished(at now: Date) -> Bool { song.duration > 0 && position(at: now) > song.duration + 2 }

    /// What Now Playing would have reported, so the rest of Lyps needs no special case.
    var reported: PlaybackState {
        var payload: [String: Any] = [
            "bundleIdentifier": "com.tdesktop.Telegram", "title": song.title, "artist": song.artist,
            "album": song.album, "durationMicros": song.duration * 1_000_000,
            "elapsedTimeMicros": position * 1_000_000, "playing": isPlaying, "playbackRate": isPlaying ? rate : 0,
        ]
        if let startedAt { payload["timestampEpochMicros"] = startedAt.timeIntervalSince1970 * 1_000_000 }
        if let artwork { payload["artworkData"] = artwork }
        var state = PlaybackState()
        state.apply(["type": "data", "diff": false, "payload": payload])
        return state
    }
}

enum TelegramAudio {
    private static let bundleIDs = ["com.tdesktop.Telegram", "ru.keepcoder.Telegram"]

    static var isRunning: Bool {
        bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Bundle IDs of processes macOS knows as audio clients, such as an app's helper processes.
    static func bundleIDs(withPrefix prefix: String) -> [String] {
        audioProcesses().compactMap { process in
            var query = address(kAudioProcessPropertyBundleID)
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &query, 0, nil, &size, &value) == noErr,
                  let id = value?.takeRetainedValue() as String?, id.hasPrefix(prefix) else { return nil }
            return id
        }
    }

    /// Whether macOS reports Telegram producing sound. Reading this needs no permission.
    static func isPlaying() -> Bool {
        #if DEBUG
        if let flag = ProcessInfo.processInfo.environment["LYPS_FAKE_TELEGRAM_AUDIO"] {
            return FileManager.default.fileExists(atPath: flag)
        }
        #endif
        let telegram = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.map(\.processIdentifier)
        guard !telegram.isEmpty else { return false }
        return audioProcesses().contains { process in
            telegram.contains(property(process, kAudioProcessPropertyPID, pid_t(0)))
                && property(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioProcesses() -> [AudioObjectID] {
        var query = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &query, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &query, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var query = address(selector)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &query, 0, nil, &size, &value) == noErr ? value : fallback
    }
}

enum TelegramResume {
    /// Telegram can resume music after a voice message with the title wiped. It also publishes no
    /// title when an item is replayed or between tracks, voice messages included. Only a resume
    /// carries on from where the remembered song paused; anything else starts near zero, so a song
    /// paused in its first seconds can't be told apart and isn't continued.
    static func song(title: String, position: TimeInterval, remembered: Track?, pausedAt: TimeInterval) -> Track? {
        guard title.isEmpty, let remembered, pausedAt > 2.5, abs(position - pausedAt) <= 2.5 else { return nil }
        return remembered
    }

    /// Another player started, so a Telegram song continuing silently isn't what's playing anymore.
    static func anotherPlayerTookOver(_ reported: PlaybackState) -> Bool {
        guard let source = Source(bundleID: reported.bundleID) else { return false }
        return source != .telegram && reported.isPlaying
    }

    /// With no Telegram sound for this long after a voice message, the song isn't coming back.
    static let giveUpAfter: TimeInterval = 600
}

enum PlayerChoice {
    /// macOS reports one app, and can keep reporting one that's paused (a Telegram song, say) while
    /// Spotify plays on. Spotify's own answer is used then, so its lyrics and ads aren't missed.
    static func current(reported: PlaybackState, spotify: PlaybackState?) -> PlaybackState {
        guard !reported.isPlaying, let spotify, spotify.isPlaying else { return reported }
        return spotify
    }
}

/// What the bridge has reported so far. Updates are diffs: a null value removes a key.
struct PlaybackState {
    private var fields: [String: Any] = [:]

    mutating func apply(_ message: [String: Any]) {
        guard let payload = message["payload"] as? [String: Any] else { return }
        if message["diff"] as? Bool != true { fields = [:] }
        for (key, value) in payload {
            fields[key] = value is NSNull ? nil : value
        }
    }

    var title: String { fields["title"] as? String ?? "" }
    var artist: String { fields["artist"] as? String ?? "" }
    var album: String { fields["album"] as? String ?? "" }
    var isPlaying: Bool { fields["playing"] as? Bool ?? false }
    var artworkBase64: String? { fields["artworkData"] as? String }
    var mediaType: String { fields["mediaType"] as? String ?? "" }
    var trackNumber: Int? { (fields["trackNumber"] as? NSNumber)?.intValue }
    var isAdvertisement: Bool { fields["isAdvertisement"] as? Bool ?? false }
    var duration: TimeInterval { (fields["durationMicros"] as? Double ?? 0) / 1_000_000 }
    var bundleID: String { fields["bundleIdentifier"] as? String ?? "" }

    var rate: Double {
        let reported = fields["playbackRate"] as? Double ?? 1
        return reported > 0 ? reported : 1
    }

    /// Players report position only when it changes unexpectedly, so it's projected forward from then.
    func position(at now: Date = Date()) -> TimeInterval {
        let elapsed = (fields["elapsedTimeMicros"] as? Double ?? 0) / 1_000_000
        guard isPlaying, let stamp = fields["timestampEpochMicros"] as? Double else { return elapsed }
        return elapsed + (now.timeIntervalSince1970 - stamp / 1_000_000) * rate
    }
}

/// Runs the bridge as a child process and delivers its JSON lines on the main thread.
final class NowPlayingBridge {
    var onMessage: (([String: Any]) -> Void)?
    /// True once the bridge keeps dying, which most likely means a macOS update closed the loophole.
    var onHealthChange: ((Bool) -> Void)?

    private var process: Process?
    private var failures = 0
    private var wanted = false

    private var command: (executable: String, arguments: [String])? {
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["LYPS_BRIDGE"] { return ("/bin/sh", ["-c", fake]) }
        #endif
        let main = Bundle.main
        guard let script = main.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let framework = main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework").path,
              FileManager.default.fileExists(atPath: framework) else { return nil }
        return ("/usr/bin/perl", [script, framework, "stream", "--micros", "--debounce=150", "--allow-missing-title"])
    }

    var isAvailable: Bool { command != nil }

    /// macOS moves a downloaded app to a read-only location if it's opened without being moved first.
    static var needsMovingToApplications: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    func start() {
        wanted = true
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { Self.clearQuarantine(in: bundle) }
        Self.stopLeftoverBridges()
        launch()
    }

    nonisolated(unsafe) private static var leftoversChecked = false

    /// A bridge outlives Lyps when Lyps is force-quit or crashes, and keeps running until its next
    /// write fails. Those have no parent left, which tells them apart from another copy's bridge.
    private static func stopLeftoverBridges() {
        guard !leftoversChecked, let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl") else { return }
        leftoversChecked = true
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", leftoverPattern(script: script)]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    static func leftoverPattern(script: String) -> String {
        "^/usr/bin/perl " + NSRegularExpression.escapedPattern(for: script) + " "
    }

    /// perl refuses to load the bridge from an app bundle still flagged as downloaded. Running at all
    /// means the user already approved this app in Privacy & Security, so the flag has done its job.
    static func clearQuarantine(in folder: URL) {
        let contents = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        for case let url as URL in contents?.allObjects ?? [] {
            removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
        removexattr(folder.path, "com.apple.quarantine", XATTR_NOFOLLOW)
    }

    func stop() {
        wanted = false
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard wanted, process == nil else { return }
        guard let command else { onHealthChange?(false); return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let message else { continue }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.failures > 0 { self.failures = 0; self.onHealthChange?(true) }
                    self.onMessage?(message)
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            Logger(subsystem: "app.lyps.Lyps", category: "bridge").error("bridge exited with status \(finished.terminationStatus, privacy: .public)")
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                guard self.wanted else { return }
                self.failures += 1
                if self.failures >= 3 { self.onHealthChange?(false) }
                let delay = min(pow(2, Double(self.failures)), 60)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.launch() }
            }
        }

        do {
            try process.run()
            Logger(subsystem: "app.lyps.Lyps", category: "bridge").info("bridge started")
            self.process = process
        } catch {
            onHealthChange?(false)
        }
    }
}
