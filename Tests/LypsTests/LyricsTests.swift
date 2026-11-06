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

@Suite struct Quarantine {
    @Test func clearsTheFlagThroughoutTheFolderOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let library = inside.appendingPathComponent("Library")
        let outside = root.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: library)
        try Data().write(to: outside)

        let flag = "0083;00000000;Safari;"
        func isFlagged(_ url: URL) -> Bool { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 }
        for url in [root, library, outside] { setxattr(url.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) }
        #expect(isFlagged(library))

        NowPlayingBridge.clearQuarantine(in: root)
        #expect(!isFlagged(root))
        #expect(!isFlagged(library))
        #expect(isFlagged(outside))
    }
}

@Suite struct TelegramResuming {
    private let song = Track(title: "Potk", artist: "A", duration: 168)

    // Positions below are from a real recording: the song paused at 5.4s for a voice message.
    @Test func resumingFromThePausePointContinuesTheSong() {
        #expect(TelegramResume.song(title: "", position: 5.6, remembered: song, pausedAt: 5.4) == song)
    }

    @Test func aReplayedVoiceMessageStartsNearZeroAndIsNotTheSong() {
        #expect(TelegramResume.song(title: "", position: 0.3, remembered: song, pausedAt: 5.4) == nil)
    }

    @Test func theGapBetweenTracksIsNotTheSong() {
        #expect(TelegramResume.song(title: "", position: 0.1, remembered: song, pausedAt: 4.1) == nil)
    }

    @Test func aRealTitleOrNothingRememberedDoesNotResume() {
        #expect(TelegramResume.song(title: "Other", position: 5.4, remembered: song, pausedAt: 5.4) == nil)
        #expect(TelegramResume.song(title: "", position: 5.4, remembered: nil, pausedAt: 5.4) == nil)
    }

    @Test func aVoiceMessageNeverGetsRemembered() {
        #expect(TelegramResume.song(title: "today at 14:02", position: 3, remembered: song, pausedAt: 3) == nil)
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

@Suite struct SilentResuming {
    // From a real recording: "Jojo" paused at 33.8s for a voice message, which was then closed.
    private let jojo = Track(title: "Jojo", artist: "Winona Oak", duration: 204)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func startsPausedAtThePausePoint() {
        let resume = SilentResume(song: jojo, artwork: nil, rate: 1, pausedAt: 33.8)
        #expect(!resume.isPlaying)
        #expect(resume.position(at: start.addingTimeInterval(60)) == 33.8)
        #expect(!resume.reported.isPlaying)
    }

    @Test func playsOnFromThePausePointAndPausesWhereItIs() {
        var resume = SilentResume(song: jojo, artwork: nil, rate: 1, pausedAt: 33.8)
        resume.play(since: start)
        #expect(abs(resume.position(at: start.addingTimeInterval(10)) - 43.8) < 0.001)
        resume.pause(at: start.addingTimeInterval(10))
        #expect(abs(resume.position(at: start.addingTimeInterval(99)) - 43.8) < 0.001)
        resume.play(since: start.addingTimeInterval(20))
        #expect(abs(resume.position(at: start.addingTimeInterval(25)) - 48.8) < 0.001)
    }

    @Test func honorsTelegramsPlaybackSpeed() {
        var resume = SilentResume(song: jojo, artwork: nil, rate: 2, pausedAt: 10)
        resume.play(since: start)
        #expect(abs(resume.position(at: start.addingTimeInterval(5)) - 20) < 0.001)
    }

    @Test func reportsLikeTelegramWould() {
        var resume = SilentResume(song: jojo, artwork: "art", rate: 1, pausedAt: 33.8)
        resume.play(since: start)
        let state = resume.reported
        #expect(state.title == "Jojo")
        #expect(state.artist == "Winona Oak")
        #expect(Source(bundleID: state.bundleID) == .telegram)
        #expect(state.isPlaying)
        #expect(state.artworkBase64 == "art")
        #expect(abs(state.position(at: start.addingTimeInterval(2)) - 35.8) < 0.001)
    }

    @Test func takesTelegramsExactPositionOnlyWhilePaused() {
        // From a real recording: Lyps estimated 57.87s, Telegram then reported 58.69s.
        var resume = SilentResume(song: jojo, artwork: nil, rate: 1, pausedAt: 57.87)
        resume.correct(pausedAt: 58.69)
        #expect(resume.position(at: start) == 58.69)
        resume.play(since: start)
        resume.correct(pausedAt: 10)
        #expect(abs(resume.position(at: start.addingTimeInterval(1)) - 59.69) < 0.001)
    }

    @Test func endsPastTheSongsEnd() {
        var resume = SilentResume(song: jojo, artwork: nil, rate: 1, pausedAt: 200)
        resume.play(since: start)
        #expect(!resume.isFinished(at: start.addingTimeInterval(5)))
        #expect(resume.isFinished(at: start.addingTimeInterval(7)))
    }
}
