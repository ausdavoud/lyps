import Carbon.HIToolbox
import Foundation

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let toggleLyrics = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey), display: "⌥L")
    static let togglePower = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | cmdKey | shiftKey), display: "⌃⇧⌘L")
    static let lyricsEarlier = Shortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: UInt32(optionKey), display: "⌥[")
    static let lyricsLater = Shortcut(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: UInt32(optionKey), display: "⌥]")
}

@Observable
final class Settings {
    private static let store = UserDefaults.standard
    @ObservationIgnored var onChange: () -> Void = {}

    var enabled = bool("enabled", true) { didSet { save(enabled, "enabled") } }
    var autoShow = bool("autoShow", true) { didSet { save(autoShow, "autoShow") } }
    var alwaysOnTop = bool("alwaysOnTop", true) { didSet { save(alwaysOnTop, "alwaysOnTop") } }
    var showArtwork = bool("showArtwork", true) { didSet { save(showArtwork, "showArtwork") } }
    var showNextLine = bool("showNextLine", true) { didSet { save(showNextLine, "showNextLine") } }
    var spotify = bool("spotify", true) { didSet { save(spotify, "spotify") } }
    var telegram = bool("telegram", true) { didSet { save(telegram, "telegram") } }
    // Off by default: on, the title of every video that plays is sent to LRCLIB.
    var browsers = bool("browsers", false) { didSet { save(browsers, "browsers") } }
    var adMute = AdMuteMode(rawValue: store.string(forKey: "adMute") ?? "") ?? .off {
        didSet { save(adMute.rawValue, "adMute") }
    }

    var toggleLyricsShortcut = shortcut("toggleLyricsShortcut", .toggleLyrics) {
        didSet { save(try? JSONEncoder().encode(toggleLyricsShortcut), "toggleLyricsShortcut") }
    }
    var togglePowerShortcut = shortcut("togglePowerShortcut", .togglePower) {
        didSet { save(try? JSONEncoder().encode(togglePowerShortcut), "togglePowerShortcut") }
    }

    var lyricsEarlierShortcut = shortcut("lyricsEarlierShortcut", .lyricsEarlier) {
        didSet { save(try? JSONEncoder().encode(lyricsEarlierShortcut), "lyricsEarlierShortcut") }
    }
    var lyricsLaterShortcut = shortcut("lyricsLaterShortcut", .lyricsLater) {
        didSet { save(try? JSONEncoder().encode(lyricsLaterShortcut), "lyricsLaterShortcut") }
    }

    private static let timingKey = "timingOffsets"

    func timingOffset(for track: Track) -> TimeInterval {
        (Self.store.dictionary(forKey: Self.timingKey) as? [String: Double])?[TimingNudge.key(for: track)] ?? 0
    }

    func setTimingOffset(_ offset: TimeInterval, for track: Track) {
        var offsets = Self.store.dictionary(forKey: Self.timingKey) as? [String: Double] ?? [:]
        offsets[TimingNudge.key(for: track)] = offset == 0 ? nil : offset
        Self.store.set(offsets, forKey: Self.timingKey)
    }

    func allows(_ source: Source) -> Bool {
        switch source {
        case .spotify: spotify
        case .telegram: telegram
        case .browser: browsers
        }
    }

    private func save(_ value: Any?, _ key: String) {
        Self.store.set(value, forKey: key)
        onChange()
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? fallback
    }

    private static func shortcut(_ key: String, _ fallback: Shortcut) -> Shortcut {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? fallback
    }
}
