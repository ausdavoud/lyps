import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Foundation only, so this file can carry over to Linux/Windows.

struct LyricLine: Codable, Equatable {
    let time: TimeInterval
    let text: String
}

/// A song's lyrics: timed lines to follow the song, and the plain text, which LRCLIB sometimes
/// has on its own.
struct Lyrics: Codable, Equatable {
    var synced: [LyricLine] = []
    var plain: [String] = []

    /// One entry per sung line; blank lines only separate verses.
    static func plainLines(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Lyrics as editable text: one line per lyric, each with its time in LRC form when synced.
enum LyricsText {
    private static let leadingStamp = /^\s*\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]\s*/

    static func stamp(_ time: TimeInterval) -> String {
        let hundredths = Int((max(time, 0) * 100).rounded())
        return String(format: "[%02d:%02d.%02d]", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    static func lrc(_ lines: [LyricLine]) -> String {
        lines.map { $0.text.isEmpty ? stamp($0.time) : "\(stamp($0.time)) \($0.text)" }.joined(separator: "\n")
    }

    static func editable(_ lyrics: Lyrics) -> String {
        lyrics.synced.isEmpty ? lyrics.plain.joined(separator: "\n") : lrc(lyrics.synced)
    }

    /// Reads edited text. With no times at all, the lyrics are plain, ready to time by tapping.
    /// Otherwise a line without a time, like one just broken off another, gets an estimate spread
    /// evenly between its timed neighbors; `estimated` says how many, so the user can check them.
    static func parse(_ text: String) -> (lyrics: Lyrics, estimated: Int) {
        var entries: [(time: TimeInterval?, text: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let match = line.firstMatch(of: leadingStamp) {
                let fraction = match.3.map { Double("0.\($0)") ?? 0 } ?? 0
                let time = Double(match.1)! * 60 + Double(match.2)! + fraction
                entries.append((time, line[match.range.upperBound...].trimmingCharacters(in: .whitespaces)))
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { entries.append((nil, trimmed)) }
            }
        }
        let plain = entries.map(\.text).filter { !$0.isEmpty }
        let timed = entries.indices.filter { entries[$0].time != nil }
        guard let first = timed.first, let last = timed.last else { return (Lyrics(plain: plain), 0) }

        var times = entries.map(\.time)
        let start = times[first]!
        for i in 0..<first { times[i] = start * Double(i) / Double(first) }
        for (a, b) in zip(timed, timed.dropFirst()) where b - a > 1 {
            let (ta, tb) = (times[a]!, times[b]!)
            for i in (a + 1)..<b { times[i] = ta + (tb - ta) * Double(i - a) / Double(b - a) }
        }
        for i in (last + 1)..<entries.count { times[i] = times[last]! + 3 * Double(i - last) }

        let synced = zip(times, entries).map { LyricLine(time: $0!, text: $1.text) }
        return (Lyrics(synced: synced.sorted { $0.time < $1.time }, plain: plain), entries.count - timed.count)
    }
}

/// Times plain lyrics by hand: the user taps as each line starts.
struct TimingSession {
    let track: Track
    let lines: [String]
    private(set) var times: [TimeInterval] = []

    /// The line the next tap times.
    var next: Int { times.count }
    var isComplete: Bool { times.count == lines.count }

    /// False when the tap was ignored: every line is timed already, or the position isn't past the
    /// previous tap, because the song is paused or was rewound.
    @discardableResult
    mutating func tap(at position: TimeInterval) -> Bool {
        guard !isComplete, position > (times.last ?? -1) else { return false }
        times.append(max(position, 0))
        return true
    }

    mutating func undo() {
        if !times.isEmpty { times.removeLast() }
    }

    var result: [LyricLine] { zip(times, lines).map { LyricLine(time: $0, text: $1) } }
}

struct Track: Equatable, Hashable {
    var title: String
    var artist: String
    var album: String = ""
    var duration: TimeInterval = 0
}

// MARK: - LRC

enum LRC {
    private static let stamp = /\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/

    /// One line can carry several timestamps when a chorus repeats.
    static func parse(_ source: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let stamps = raw.matches(of: stamp)
            guard let last = stamps.last else { continue }
            let text = raw[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in stamps {
                let fraction = match.3.map { Double("0.\($0)") ?? 0 } ?? 0
                let time = Double(match.1)! * 60 + Double(match.2)! + fraction
                lines.append(LyricLine(time: time, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    static func index(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}

// MARK: - Timing nudge

/// How far to shift a song's lyrics, for ones that run early or late. Positive means later.
enum TimingNudge {
    static let step: TimeInterval = 0.25
    private static let limit: TimeInterval = 30

    static func adjusted(_ offset: TimeInterval, by change: TimeInterval) -> TimeInterval {
        min(max(offset + change, -limit), limit)
    }

    /// The song, not the file: the same title and artist share a nudge across apps.
    static func key(for track: Track) -> String {
        "\(track.title)|\(track.artist)".lowercased()
    }

    static func label(_ offset: TimeInterval) -> String {
        if offset == 0 { return "Lyrics timing reset" }
        let amount = String(format: "%.2fs", abs(offset))
        return offset > 0 ? "Lyrics \(amount) later" : "Lyrics \(amount) earlier"
    }
}

// MARK: - Cleaning messy titles

enum TitleCleaner {
    private static let audioExtension = /(?i)\.(mp3|m4a|flac|ogg|opus|wav|aac|wma)$/
    private static let noiseBrackets = /(?i)\s*[\(\[][^\)\]]*(official|video|lyric|audio|visuali[sz]er|\bhd\b|\b4k\b|\bmv\b|feat\.?|ft\.?)[^\)\]]*[\)\]]/

    /// What to search for, given what a player reports. Telegram music files often carry
    /// "Artist - Song (Official Audio)" or a file name as their title.
    static func clean(title: String, artist: String) -> (title: String, artist: String) {
        var cleanTitle = title.replacing(audioExtension, with: "")
        let isFile = cleanTitle != title
        if isFile { cleanTitle = cleanTitle.replacingOccurrences(of: "_", with: " ") }
        cleanTitle = cleanTitle.replacing(noiseBrackets, with: "").trimmingCharacters(in: .whitespaces)

        var cleanArtist = artist.trimmingCharacters(in: .whitespaces)
        for separator in [" - ", " – ", " — "] {
            let parts = cleanTitle.components(separatedBy: separator)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                // shortcut: assumes "Artist - Song" order, the common form; reversed names just won't match.
                cleanArtist = parts[0].trimmingCharacters(in: .whitespaces)
                cleanTitle = parts[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return (cleanTitle, cleanArtist)
    }
}

// MARK: - Privacy

enum Privacy {
    private static let clockTime = /\p{Nd}{1,2}[:.٫]\p{Nd}{2}/

    /// Telegram Desktop reports voice messages to Now Playing, with the date and time as the
    /// title and the sender's name as the artist. They have no flag, and their labels are
    /// translated, so this refuses anything shaped like one. A song really named "12:51"
    /// loses lyrics, which is the right way for this to fail.
    static func isSafeTelegramLookup(title: String, artist: String) -> Bool {
        if title.contains(clockTime) { return false }
        if !artist.isEmpty { return true }
        // Untitled voice and video notes have only a generic label; untagged songs have a file name.
        return title.contains(/\.\w{2,4}$/) || title.contains(" - ")
    }
}

// MARK: - Text direction

/// True when the first letter is from a right-to-left script.
func isRightToLeft(_ text: String) -> Bool {
    for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }
    return false
}

// MARK: - LRCLIB

struct LRCLIBRecord: Decodable {
    let trackName: String
    let artistName: String
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
    var plainLyrics: String? = nil
}

enum Matching {
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func overlaps(_ a: String, _ b: String) -> Bool {
        let (a, b) = (normalized(a), normalized(b))
        return !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a))
    }

    /// Search results can be for a different song, and wrong lyrics are worse than none.
    /// The title must match, and so must the duration, or the artist when duration is unknown.
    /// With `synced` false, it looks for plain lyrics instead.
    static func best(_ records: [LRCLIBRecord], track: Track, synced: Bool = true) -> LRCLIBRecord? {
        let usable = records.filter { record in
            let text = synced ? record.syncedLyrics : record.plainLyrics
            guard record.instrumental != true, text?.isEmpty == false,
                  overlaps(record.trackName, track.title) else { return false }
            if track.duration > 0, let duration = record.duration {
                return abs(duration - track.duration) <= 5
            }
            return overlaps(record.artistName, track.artist)
        }
        return usable.min { gap($0, track) < gap($1, track) }
    }

    private static func gap(_ record: LRCLIBRecord, _ track: Track) -> Double {
        abs((record.duration ?? track.duration) - track.duration)
    }
}

struct LRCLIB {
    enum Failure: Error { case badStatus(Int) }

    private static let base = "https://lrclib.net/api"
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// Synced lyrics when any version has them, otherwise plain lyrics, otherwise nothing. Throws on
    /// network failure so a bad connection is never remembered as "no lyrics".
    func lyrics(for track: Track) async throws -> Lyrics {
        var plain: [String] = []
        if !track.artist.isEmpty, !track.album.isEmpty, track.duration > 0,
           let record: LRCLIBRecord = try await get("get", [
               "track_name": track.title, "artist_name": track.artist,
               "album_name": track.album, "duration": String(Int(track.duration.rounded())),
           ]), record.instrumental != true {
            plain = Lyrics.plainLines(record.plainLyrics)
            if let synced = record.syncedLyrics, !synced.isEmpty {
                return Lyrics(synced: LRC.parse(synced), plain: plain)
            }
        }

        // Another version of the song may be synced even when the exact one isn't.
        let cleaned = TitleCleaner.clean(title: track.title, artist: track.artist)
        let query = cleaned.artist.isEmpty
            ? ["q": cleaned.title]
            : ["track_name": cleaned.title, "artist_name": cleaned.artist]
        let results: [LRCLIBRecord] = try await get("search", query) ?? []
        var target = track
        (target.title, target.artist) = cleaned
        if let best = Matching.best(results, track: target), let synced = best.syncedLyrics {
            return Lyrics(synced: LRC.parse(synced), plain: Lyrics.plainLines(best.plainLyrics))
        }
        if plain.isEmpty {
            plain = Lyrics.plainLines(Matching.best(results, track: target, synced: false)?.plainLyrics)
        }
        return Lyrics(plain: plain)
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T? {
        var components = URLComponents(string: "\(Self.base)/\(path)")!
        components.queryItems = query.map(URLQueryItem.init)
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Lyps/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw Failure.badStatus(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Disk cache

struct LyricsCache {
    let directory: URL

    static let standard = LyricsCache(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lyps", isDirectory: true))

    /// Lyrics the user timed by hand. Kept out of Caches, which macOS may clear, losing the work.
    static let timedByUser = LyricsCache(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lyps/Timed", isDirectory: true))

    private func file(for track: Track) -> URL {
        // FNV-1a: String.hashValue changes every launch, so it can't name a file.
        // shortcut: a 64-bit collision would show another song's lyrics, too rare to matter here.
        let key = "\(track.title)|\(track.artist)|\(Int(track.duration.rounded()))".lowercased()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return directory.appendingPathComponent("\(String(hash, radix: 16)).json")
    }

    func load(_ track: Track) -> Lyrics? {
        guard let data = try? Data(contentsOf: file(for: track)) else { return nil }
        if let lyrics = try? JSONDecoder().decode(Lyrics.self, from: data) { return lyrics }
        // Earlier versions stored only the synced lines.
        return (try? JSONDecoder().decode([LyricLine].self, from: data)).map { Lyrics(synced: $0) }
    }

    func remove(_ track: Track) throws {
        let url = file(for: track)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func save(_ lyrics: Lyrics, for track: Track) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(lyrics).write(to: file(for: track), options: .atomic)
    }
}
