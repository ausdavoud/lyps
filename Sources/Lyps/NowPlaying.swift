import Foundation

enum Source: String, CaseIterable {
    case spotify, telegram, browser

    init?(bundleID: String) {
        switch bundleID {
        case "com.spotify.client": self = .spotify
        case "com.tdesktop.Telegram", "ru.keepcoder.Telegram": self = .telegram
        case "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.brave.Browser",
             "company.thebrowser.Browser", "com.microsoft.edgemac", "org.chromium.Chromium",
             "app.zen-browser.zen", "com.operasoftware.Opera", "com.vivaldi.Vivaldi":
            self = .browser
        default: return nil
        }
    }
}

enum TelegramResume {
    /// Telegram pauses music for a voice message, then resumes it with the title wiped, and only
    /// sets a title again when the track changes. So no title means the last song is still playing.
    /// A position past that song's end means it's something else.
    static func song(title: String, position: TimeInterval, remembered: Track?) -> Track? {
        guard title.isEmpty, let remembered, position <= remembered.duration + 5 || remembered.duration == 0
        else { return nil }
        return remembered
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
    var duration: TimeInterval { (fields["durationMicros"] as? Double ?? 0) / 1_000_000 }
    /// Browsers report through helper processes, so the parent app is the one that identifies them.
    var bundleID: String {
        fields["parentApplicationBundleIdentifier"] as? String ?? fields["bundleIdentifier"] as? String ?? ""
    }

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

    func start() {
        wanted = true
        launch()
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
            self.process = process
        } catch {
            onHealthChange?(false)
        }
    }
}
