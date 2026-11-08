import Foundation
import Testing
@testable import Lyps

/// Serves canned LRCLIB answers, keyed by endpoint, so lookups run without the network.
final class FakeLRCLIB: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: Any] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let endpoint = request.url?.lastPathComponent ?? ""
        let body = Self.answers[endpoint]
        let status = body == nil ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeLRCLIB.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct PlainLyrics {
    // Mirrors a real LRCLIB entry that has plain lyrics only, with placeholder text.
    private let song = Track(title: "Hale Man Khoob Nist", artist: "Dayan", album: "Hale Man Khoob Nist", duration: 234.58)
    private func record(synced: String?, plain: String?, duration: Double = 234) -> [String: Any] {
        ["trackName": "Hale Man Khoob Nist", "artistName": "Dayan", "albumName": "Hale Man Khoob Nist",
         "duration": duration, "instrumental": false, "syncedLyrics": synced ?? NSNull(), "plainLyrics": plain ?? NSNull()]
    }

    @Test func plainOnlyLyricsAreKeptInsteadOfDropped() async throws {
        FakeLRCLIB.answers = ["get": record(synced: nil, plain: "First line\n\nSecond line\n"), "search": []]
        let found = try await LRCLIB(session: FakeLRCLIB.session()).lyrics(for: song)
        #expect(found.synced.isEmpty)
        #expect(found.plain == ["First line", "Second line"])
    }

    @Test func aSyncedVersionFoundBySearchStillWins() async throws {
        FakeLRCLIB.answers = [
            "get": record(synced: nil, plain: "First line"),
            "search": [record(synced: "[00:10.00]First line", plain: "First line", duration: 235)],
        ]
        let found = try await LRCLIB(session: FakeLRCLIB.session()).lyrics(for: song)
        #expect(found.synced == [LyricLine(time: 10, text: "First line")])
    }

    @Test func plainLyricsFromSearchWhenTheExactEntryIsMissing() async throws {
        FakeLRCLIB.answers = ["search": [record(synced: nil, plain: "Only line", duration: 235)]]
        let found = try await LRCLIB(session: FakeLRCLIB.session()).lyrics(for: song)
        #expect(found == Lyrics(plain: ["Only line"]))
    }

    @Test func plainLinesDropBlanksAndTrim() {
        #expect(Lyrics.plainLines("  One \n\n\r\nTwo\n   \n") == ["One", "Two"])
        #expect(Lyrics.plainLines(nil).isEmpty)
    }
}

@Suite struct TapToTime {
    private let session = TimingSession(track: Track(title: "Song", artist: "Artist", duration: 200), lines: ["One", "Two", "Three"])

    @Test func tapsTimeEachLineInOrder() {
        var timing = session
        let tap1 = timing.tap(at: 12.4); #expect(tap1)
        let tap2 = timing.tap(at: 15.0); #expect(tap2)
        #expect(timing.next == 2)
        #expect(!timing.isComplete)
        let tap3 = timing.tap(at: 19.2); #expect(tap3)
        #expect(timing.isComplete)
        #expect(timing.result == [LyricLine(time: 12.4, text: "One"), LyricLine(time: 15, text: "Two"), LyricLine(time: 19.2, text: "Three")])
    }

    @Test func tapsThatDontMoveForwardAreIgnored() {
        var timing = session
        timing.tap(at: 12)
        // Paused (same position) or rewound (earlier position): neither can time the next line.
        let tap4 = timing.tap(at: 12); #expect(!tap4)
        let tap5 = timing.tap(at: 8); #expect(!tap5)
        #expect(timing.times == [12])
    }

    @Test func undoAndExtraTaps() {
        var timing = session
        timing.tap(at: 1); timing.tap(at: 2); timing.tap(at: 3)
        let tap6 = timing.tap(at: 4); #expect(!tap6) // every line is timed
        timing.undo()
        #expect(timing.next == 2)
        let tap7 = timing.tap(at: 3.5); #expect(tap7)
        timing.undo(); timing.undo(); timing.undo(); timing.undo()
        #expect(timing.times.isEmpty)
    }

    @Test func clockFormat() {
        #expect(LyricsWindowView.clock(0) == "0:00.0")
        #expect(LyricsWindowView.clock(83.46) == "1:23.5")
    }

    @Test func timedLyricsKeepTheirPlainTextAndOldCacheFilesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LyricsCache(directory: dir)
        let track = session.track
        var timing = session
        timing.tap(at: 1); timing.tap(at: 2); timing.tap(at: 3)
        try store.save(Lyrics(synced: timing.result, plain: timing.lines), for: track)
        #expect(store.load(track)?.plain == ["One", "Two", "Three"])

        // A file written by an earlier version: just the synced lines. Its own folder makes it the only file.
        let legacyDir = dir.appendingPathComponent("legacy")
        let legacyStore = LyricsCache(directory: legacyDir)
        let legacy = Track(title: "Old", artist: "Artist", duration: 100)
        try legacyStore.save(Lyrics(), for: legacy)
        let file = try #require(FileManager.default.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil).first)
        try JSONEncoder().encode([LyricLine(time: 5, text: "x")]).write(to: file)
        #expect(legacyStore.load(legacy) == Lyrics(synced: [LyricLine(time: 5, text: "x")]))
    }

    @Test func timedLyricsLiveOutsideCaches() {
        // macOS may clear Caches; hand-timed lyrics are work that mustn't vanish.
        #expect(LyricsCache.timedByUser.directory.path.contains("/Application Support/"))
        #expect(!LyricsCache.timedByUser.directory.path.contains("/Caches/"))
    }
}

@Suite struct CheckingForUpdates {
    @Test func versionsCompareNumerically() {
        #expect(Updates.isNewer("0.2.1", than: "0.2.0"))
        #expect(Updates.isNewer("0.10.0", than: "0.9.1"))
        #expect(Updates.isNewer("1.0", than: "0.9.9"))
        #expect(!Updates.isNewer("0.2.0", than: "0.2.0"))
        #expect(!Updates.isNewer("0.2", than: "0.2.0"))
        #expect(!Updates.isNewer("0.1.9", than: "0.2.0"))
    }

    @Test func readsGitHubsLatestRelease() throws {
        let json = #"{"tag_name": "v0.3.0", "html_url": "https://github.com/ausdavoud/lyps/releases/tag/v0.3.0", "name": "Lyps 0.3.0"}"#
        let release = try JSONDecoder().decode(Updates.Release.self, from: Data(json.utf8))
        #expect(release.version == "0.3.0")
        #expect(release.htmlURL.absoluteString.hasSuffix("/v0.3.0"))
    }
}
