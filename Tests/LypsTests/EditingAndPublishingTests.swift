import Foundation
import Testing
@testable import Lyps

/// The line editor's text: placeholder lyrics only.
@Suite struct EditingLines {
    @Test func noTimesMeansPlainLyricsReadyToTime() {
        let (lyrics, estimated) = LyricsText.parse("First line\n\nSecond line\n  Third line  ")
        #expect(lyrics == Lyrics(plain: ["First line", "Second line", "Third line"]))
        #expect(estimated == 0)
    }

    @Test func timedLinesKeepTheirTimes() {
        let (lyrics, estimated) = LyricsText.parse("[00:12.50] First line\n[01:02.25]Second line\n[1:30] Third")
        #expect(lyrics.synced == [LyricLine(time: 12.5, text: "First line"), LyricLine(time: 62.25, text: "Second line"),
                                  LyricLine(time: 90, text: "Third")])
        #expect(estimated == 0)
    }

    @Test func breakingALineEstimatesTheNewHalfBetweenItsNeighbors() {
        // "First line" was broken in two with Return; the new half has no time yet.
        let (lyrics, estimated) = LyricsText.parse("[00:10.00] First\nline\n[00:20.00] Second line")
        #expect(lyrics.synced == [LyricLine(time: 10, text: "First"), LyricLine(time: 15, text: "line"),
                                  LyricLine(time: 20, text: "Second line")])
        #expect(estimated == 1)
    }

    @Test func linesAddedBeforeOrAfterGetTimesThatStayInOrder() {
        let (lyrics, estimated) = LyricsText.parse("Intro A\nIntro B\n[00:30.00] Timed\nOutro")
        #expect(lyrics.synced.map(\.time) == [0, 15, 30, 33])
        #expect(estimated == 3)
    }

    @Test func linesTypedOutOfOrderAreSortedByTime() {
        let (lyrics, _) = LyricsText.parse("[00:20.00] Later\n[00:05.00] Earlier")
        #expect(lyrics.synced.map(\.text) == ["Earlier", "Later"])
    }

    @Test func aTimedBlankLineKeepsTheInstrumentalGap() {
        let (lyrics, _) = LyricsText.parse("[00:10.00] Line\n[00:20.00]\n[00:30.00] Next")
        #expect(lyrics.synced.map(\.text) == ["Line", "", "Next"])
        #expect(lyrics.plain == ["Line", "Next"])
    }

    @Test func editingTextRoundTripsAndMatchesLRC() {
        let lines = [LyricLine(time: 12.34, text: "First line"), LyricLine(time: 65, text: ""), LyricLine(time: 3599.99, text: "Last")]
        let text = LyricsText.editable(Lyrics(synced: lines))
        #expect(text == "[00:12.34] First line\n[01:05.00]\n[59:59.99] Last")
        #expect(LyricsText.parse(text).lyrics.synced == lines)
        #expect(LRC.parse(text) == lines) // also what LRCLIB and other players read
        #expect(LyricsText.editable(Lyrics(plain: ["A", "B"])) == "A\nB")
    }
}

@Suite struct PublishingToLRCLIB {
    // Reference answer from a separate implementation (Python's hashlib) of LRCLIB's server check.
    private let prefix = "LypsTestPrefix0123456789abcdefgh"
    private let target = "0000FF" + String(repeating: "00", count: 29)

    @Test func solvesTheAntiSpamCheckLikeTheServer() throws {
        let nonce = try #require(LRCLIBPublisher.solve(.init(prefix: prefix, target: target)))
        #expect(nonce == "99291")
        let bytes = try #require(LRCLIBPublisher.bytes(fromHex: target))
        #expect(LRCLIBPublisher.isSolved(prefix: prefix, target: bytes, nonce: "99291"))
        #expect(!LRCLIBPublisher.isSolved(prefix: prefix, target: bytes, nonce: "99290"))
    }

    @Test func rejectsMalformedTargets() {
        #expect(LRCLIBPublisher.solve(.init(prefix: prefix, target: "XYZ")) == nil)
        #expect(LRCLIBPublisher.bytes(fromHex: "0") == nil)
        #expect(LRCLIBPublisher.bytes(fromHex: "00ff") == [0, 255])
    }

    @Test func sendsTheSongAsThePlayerReportsItWithBothKindsOfLyrics() {
        let track = Track(title: "Song", artist: "Artist", album: "Album", duration: 234.58)
        let synced = LRCLIBPublisher.body(track: track, lyrics: Lyrics(
            synced: [LyricLine(time: 1, text: "First"), LyricLine(time: 2, text: "")], plain: ["First"]))
        #expect(synced["trackName"] as? String == "Song")
        #expect(synced["albumName"] as? String == "Album")
        #expect(synced["duration"] as? Double == 234.58)
        #expect(synced["plainLyrics"] as? String == "First")
        #expect(synced["syncedLyrics"] as? String == "[00:01.00] First\n[00:02.00]")

        // Plain-only lyrics go up without a synced field, so LRCLIB doesn't mark them synced.
        let plain = LRCLIBPublisher.body(track: track, lyrics: Lyrics(plain: ["One", "Two"]))
        #expect(plain["plainLyrics"] as? String == "One\nTwo")
        #expect(plain["syncedLyrics"] == nil)
    }
}
