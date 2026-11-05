import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Foundation only, so this file can carry over to Linux/Windows.

struct LyricLine: Codable, Equatable {
    let time: TimeInterval
    let text: String
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
    private static let channelSuffix = /(?i)(\s*-\s*topic|vevo)$/

    /// What to search for, given what a player reports. YouTube and Telegram often put
    /// "Artist - Song (Official Video)" or a file name in the title.
    static func clean(title: String, artist: String) -> (title: String, artist: String) {
        var cleanTitle = title.replacing(audioExtension, with: "")
        let isFile = cleanTitle != title
        if isFile { cleanTitle = cleanTitle.replacingOccurrences(of: "_", with: " ") }
        cleanTitle = cleanTitle.replacing(noiseBrackets, with: "").trimmingCharacters(in: .whitespaces)

        var cleanArtist = artist.replacing(channelSuffix, with: "").trimmingCharacters(in: .whitespaces)
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
    static func best(_ records: [LRCLIBRecord], track: Track) -> LRCLIBRecord? {
        let usable = records.filter { record in
            guard record.instrumental != true, record.syncedLyrics?.isEmpty == false,
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

    /// Synced lines, or an empty array when the track has none. Throws on network failure so
    /// a bad connection is never remembered as "no lyrics".
    func lyrics(for track: Track) async throws -> [LyricLine] {
        if !track.artist.isEmpty, !track.album.isEmpty, track.duration > 0,
           let record: LRCLIBRecord = try await get("get", [
               "track_name": track.title, "artist_name": track.artist,
               "album_name": track.album, "duration": String(Int(track.duration.rounded())),
           ]), let synced = record.syncedLyrics, !synced.isEmpty {
            return LRC.parse(synced)
        }

        let cleaned = TitleCleaner.clean(title: track.title, artist: track.artist)
        let query = cleaned.artist.isEmpty
            ? ["q": cleaned.title]
            : ["track_name": cleaned.title, "artist_name": cleaned.artist]
        let results: [LRCLIBRecord] = try await get("search", query) ?? []
        var target = track
        (target.title, target.artist) = cleaned
        return Matching.best(results, track: target)?.syncedLyrics.map(LRC.parse) ?? []
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

    private func file(for track: Track) -> URL {
        // FNV-1a: String.hashValue changes every launch, so it can't name a file.
        // shortcut: a 64-bit collision would show another song's lyrics, too rare to matter here.
        let key = "\(track.title)|\(track.artist)|\(Int(track.duration.rounded()))".lowercased()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return directory.appendingPathComponent("\(String(hash, radix: 16)).json")
    }

    func load(_ track: Track) -> [LyricLine]? {
        guard let data = try? Data(contentsOf: file(for: track)) else { return nil }
        return try? JSONDecoder().decode([LyricLine].self, from: data)
    }

    func save(_ lines: [LyricLine], for track: Track) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(lines).write(to: file(for: track), options: .atomic)
    }
}
