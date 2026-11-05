import AppKit
import Testing
@testable import Lyps

@Suite struct LRCParsing {
    @Test func parsesTimesAndText() {
        let lines = LRC.parse("[00:13.13] Yeah\n[01:02.5]Second\nnot a lyric\n")
        #expect(lines.count == 2)
        #expect(abs(lines[0].time - 13.13) < 0.001)
        #expect(lines[0].text == "Yeah")
        #expect(abs(lines[1].time - 62.5) < 0.001)
    }

    @Test func expandsRepeatedTimestampsInOrder() {
        let lines = LRC.parse("[00:30.00][00:10.00]Chorus\n[00:20.00]Verse")
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
        #expect(lines.map(\.time) == [10, 20, 30])
    }

    @Test func keepsBlankAndMusicLines() {
        #expect(LRC.parse("[00:01.00]\n[00:02.00] ♪").map(\.text) == ["", "♪"])
    }

    @Test func findsCurrentLine() {
        let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b"), LyricLine(time: 30, text: "c")]
        #expect(LRC.index(in: lines, at: 5) == nil)
        #expect(LRC.index(in: lines, at: 10) == 0)
        #expect(LRC.index(in: lines, at: 19.99) == 0)
        #expect(LRC.index(in: lines, at: 20) == 1)
        #expect(LRC.index(in: lines, at: 999) == 2)
        #expect(LRC.index(in: [], at: 5) == nil)
    }
}

@Suite struct TitleCleaning {
    @Test func youtubeTitle() {
        let result = TitleCleaner.clean(title: "The Weeknd - Blinding Lights (Official Music Video)", artist: "TheWeekndVEVO")
        #expect(result.title == "Blinding Lights")
        #expect(result.artist == "The Weeknd")
    }

    @Test func topicChannel() {
        let result = TitleCleaner.clean(title: "Blinding Lights", artist: "The Weeknd - Topic")
        #expect(result.title == "Blinding Lights")
        #expect(result.artist == "The Weeknd")
    }

    @Test func untaggedTelegramFile() {
        let result = TitleCleaner.clean(title: "Daft_Punk - One_More_Time.mp3", artist: "")
        #expect(result.title == "One More Time")
        #expect(result.artist == "Daft Punk")
    }

    @Test func leavesMeaningfulBracketsAlone() {
        #expect(TitleCleaner.clean(title: "Song (Acoustic)", artist: "A").title == "Song (Acoustic)")
    }

    @Test func nonLatinTitles() {
        let result = TitleCleaner.clean(title: "شجریان - مرغ سحر [Official Audio]", artist: "")
        #expect(result.title == "مرغ سحر")
        #expect(result.artist == "شجریان")
    }
}

@Suite struct TelegramPrivacy {
    @Test(arguments: [
        ("today at 14:02", "Sara"),
        ("yesterday at 2:02 PM", "You"),
        ("12 March 2026 at 10:00", "Ali"),
        ("امروز، ساعت ۱۴:۰۲", "سارا"),
    ])
    func refusesVoiceMessages(title: String, artist: String) {
        #expect(!Privacy.isSafeTelegramLookup(title: title, artist: artist))
    }

    @Test(arguments: ["Voice message", "Video message", "Audio"])
    func refusesGenericLabels(title: String) {
        #expect(!Privacy.isSafeTelegramLookup(title: title, artist: ""))
    }

    @Test func allowsSongs() {
        #expect(Privacy.isSafeTelegramLookup(title: "Blinding Lights", artist: "The Weeknd"))
        #expect(Privacy.isSafeTelegramLookup(title: "track01.mp3", artist: ""))
        #expect(Privacy.isSafeTelegramLookup(title: "Daft Punk - One More Time", artist: ""))
    }
}

@Suite struct Direction {
    @Test func detectsScript() {
        #expect(isRightToLeft("مرغ سحر"))
        #expect(isRightToLeft("♪ שלום"))
        #expect(!isRightToLeft("Hello"))
        #expect(!isRightToLeft("♪"))
    }
}

@Suite struct SearchRanking {
    private func record(_ name: String, _ artist: String = "The Weeknd", _ duration: Double? = 200, synced: String? = "[00:01.00]x", instrumental: Bool = false) -> LRCLIBRecord {
        LRCLIBRecord(trackName: name, artistName: artist, duration: duration, instrumental: instrumental, syncedLyrics: synced)
    }
    private let track = Track(title: "Blinding Lights", artist: "The Weeknd", duration: 200)

    @Test func picksClosestDuration() {
        let best = Matching.best([record("Blinding Lights", "A", 204), record("Blinding Lights", "B", 201)], track: track)
        #expect(best?.artistName == "B")
    }

    @Test func rejectsWrongSongsAndUnsynced() {
        #expect(Matching.best([record("Save Your Tears")], track: track) == nil)
        #expect(Matching.best([record("Blinding Lights", synced: nil)], track: track) == nil)
        #expect(Matching.best([record("Blinding Lights", synced: "")], track: track) == nil)
        #expect(Matching.best([record("Blinding Lights", instrumental: true)], track: track) == nil)
        #expect(Matching.best([record("Blinding Lights", "X", 263)], track: track) == nil)
    }

    @Test func unknownDurationRequiresArtist() {
        let unknown = Track(title: "Blinding Lights", artist: "The Weeknd")
        #expect(Matching.best([record("Blinding Lights", "Someone Else")], track: unknown) == nil)
        #expect(Matching.best([record("Blinding Lights")], track: unknown) != nil)
    }

    @Test func nonLatinTitleMatches() {
        let persian = Track(title: "مرغ سحر", artist: "شجریان", duration: 200)
        #expect(Matching.best([record("مرغ سحر", "شجریان")], track: persian) != nil)
    }
}

@Suite struct Playback {
    private func message(_ payload: [String: Any], diff: Bool = false) -> [String: Any] {
        ["type": "data", "diff": diff, "payload": payload]
    }

    @Test func diffsMergeAndNullRemoves() {
        var state = PlaybackState()
        state.apply(message(["title": "A", "artist": "B", "playing": true]))
        state.apply(message(["title": "C", "artist": NSNull()], diff: true))
        #expect(state.title == "C")
        #expect(state.artist == "")
        #expect(state.isPlaying)
    }

    @Test func fullUpdateReplacesEverything() {
        var state = PlaybackState()
        state.apply(message(["title": "A", "artist": "B"]))
        state.apply(message(["title": "C"]))
        #expect(state.artist == "")
    }

    @Test func positionProjectsForwardOnlyWhilePlaying() {
        let now = Date()
        let stamp = (now.timeIntervalSince1970 - 10) * 1_000_000
        var state = PlaybackState()
        state.apply(message(["playing": true, "elapsedTimeMicros": 5_000_000.0, "timestampEpochMicros": stamp, "playbackRate": 1.0]))
        #expect(abs(state.position(at: now) - 15) < 0.01)

        state.apply(message(["playing": false], diff: true))
        #expect(abs(state.position(at: now) - 5) < 0.01)
    }

    @Test func browsersAreIdentifiedByParentApp() {
        var state = PlaybackState()
        state.apply(message(["bundleIdentifier": "com.apple.WebKit.GPU", "parentApplicationBundleIdentifier": "com.apple.Safari"]))
        #expect(Source(bundleID: state.bundleID) == .browser)
        #expect(Source(bundleID: "com.example.Other") == nil)
    }
}

@Suite struct TelegramResuming {
    private let song = Track(title: "Jojo", artist: "Winona Oak", duration: 204)

    @Test func noTitleMeansTheSameSongIsStillPlaying() {
        #expect(TelegramResume.song(title: "", position: 16, remembered: song) == song)
    }

    @Test func aRealTitleOrNothingRememberedDoesNotResume() {
        #expect(TelegramResume.song(title: "Other", position: 16, remembered: song) == nil)
        #expect(TelegramResume.song(title: "", position: 16, remembered: nil) == nil)
    }

    @Test func aPositionPastTheEndIsSomethingElse() {
        #expect(TelegramResume.song(title: "", position: 300, remembered: song) == nil)
    }

    @Test func aVoiceMessageNeverGetsRemembered() {
        #expect(TelegramResume.song(title: "today at 14:02", position: 3, remembered: song) == nil)
        #expect(!Privacy.isSafeTelegramLookup(title: "", artist: ""))
    }
}

@Suite struct Nudge {
    @Test func stepsAndStopsAtTheLimit() {
        #expect(TimingNudge.adjusted(0, by: TimingNudge.step) == 0.25)
        #expect(TimingNudge.adjusted(0.25, by: -TimingNudge.step) == 0)
        #expect(TimingNudge.adjusted(30, by: TimingNudge.step) == 30)
        #expect(TimingNudge.adjusted(-30, by: -TimingNudge.step) == -30)
    }

    @Test func laterMeansLinesChangeLater() {
        let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b")]
        #expect(LRC.index(in: lines, at: 20) == 1)
        #expect(LRC.index(in: lines, at: 20 - 0.5) == 0)
        #expect(LRC.index(in: lines, at: 19.75 - (-0.5)) == 1)
    }

    @Test func sameSongSharesAKey() {
        let spotify = Track(title: "Jojo", artist: "Winona Oak", album: "A", duration: 204)
        let telegram = Track(title: "JOJO", artist: "winona oak", duration: 203)
        #expect(TimingNudge.key(for: spotify) == TimingNudge.key(for: telegram))
        #expect(TimingNudge.key(for: spotify) != TimingNudge.key(for: Track(title: "Jojo", artist: "Other")))
    }

    @Test func remembersPerSongAndForgetsAtZero() {
        let settings = Settings()
        let track = Track(title: "Lyps test \(UUID())", artist: "Nobody")
        #expect(settings.timingOffset(for: track) == 0)
        settings.setTimingOffset(0.75, for: track)
        #expect(settings.timingOffset(for: track) == 0.75)
        #expect(settings.timingOffset(for: Track(title: "Other", artist: "Nobody")) == 0)
        settings.setTimingOffset(0, for: track)
        #expect(settings.timingOffset(for: track) == 0)
    }

    @Test func labelsSayWhichWay() {
        #expect(TimingNudge.label(0.5) == "Lyrics 0.50s later")
        #expect(TimingNudge.label(-0.25) == "Lyrics 0.25s earlier")
        #expect(TimingNudge.label(0) == "Lyrics timing reset")
    }
}

@Suite struct Shortcuts {
    @Test func nudgeDefaults() {
        #expect(Shortcut.lyricsEarlier.menuKey == "[")
        #expect(Shortcut.lyricsLater.menuKey == "]")
        #expect(Shortcut.lyricsLater.menuModifiers == [.option])
    }

    @Test func defaultsShowInTheMenuColumn() {
        #expect(Shortcut.toggleLyrics.display == "⌥L")
        #expect(Shortcut.toggleLyrics.menuKey == "l")
        #expect(Shortcut.toggleLyrics.menuModifiers == [.option])
        #expect(Shortcut.togglePower.menuKey == "l")
        #expect(Shortcut.togglePower.menuModifiers == [.control, .shift, .command])
    }

    @Test func namedKeys() {
        #expect(Shortcut(keyCode: 49, modifiers: 0, display: "⌘Space").menuKey == " ")
        #expect(Shortcut(keyCode: 126, modifiers: 0, display: "⌃↑").menuKey == String(UnicodeScalar(NSUpArrowFunctionKey)!))
    }
}

@Suite struct Cache {
    @Test func roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LyricsCache(directory: dir)
        let track = Track(title: "A", artist: "B", duration: 10)
        #expect(cache.load(track) == nil)
        cache.save([LyricLine(time: 1, text: "x")], for: track)
        #expect(cache.load(track) == [LyricLine(time: 1, text: "x")])
        #expect(cache.load(Track(title: "A", artist: "C", duration: 10)) == nil)
    }
}
