import Foundation
import Testing
@testable import Lyps

/// Corner cases found while building ad muting, each from real use on a Mac.
@Suite struct AdMutingCornerCases {
    @Test func permissionPromptsOnlyWhenTheUserPicksAMode() {
        // Picking a mode asks; muting only Spotify also needs the audio permission.
        #expect(AdMuteMode.prompts(from: .off, to: .app) == (true, true))
        #expect(AdMuteMode.prompts(from: .off, to: .system) == (true, false))
        #expect(AdMuteMode.prompts(from: .system, to: .app) == (true, true))
        // Launching with a mode already chosen, or changing another setting, never asks.
        #expect(AdMuteMode.prompts(from: .app, to: .app) == (false, false))
        #expect(AdMuteMode.prompts(from: .system, to: .system) == (false, false))
        // Turning muting off never asks.
        #expect(AdMuteMode.prompts(from: .app, to: .off) == (false, false))
    }

    @Test func muteOnlySpotifyFallsBackToMutingEverything() {
        final class Calls { var list: [String] = [] }
        let calls = Calls()
        let works: (@escaping () -> Void) -> Void = { _ in calls.list.append("spotify") }
        let refused: (@escaping () -> Void) -> Void = { fallback in calls.list.append("spotify"); fallback() }

        AdMuteMode.app.mute(spotifyOnly: works, everything: { calls.list.append("all") })
        #expect(calls.list == ["spotify"])

        calls.list = []
        AdMuteMode.app.mute(spotifyOnly: refused, everything: { calls.list.append("all") })
        #expect(calls.list == ["spotify", "all"])

        calls.list = []
        AdMuteMode.system.mute(spotifyOnly: works, everything: { calls.list.append("all") })
        #expect(calls.list == ["all"])

        calls.list = []
        AdMuteMode.off.mute(spotifyOnly: works, everything: { calls.list.append("all") })
        #expect(calls.list.isEmpty)
    }

    @Test func aRefusalIsRememberedSoLypsStopsAsking() {
        #expect(SpotifyScript.allowed(answered: true, errorCode: nil, before: false))
        #expect(!SpotifyScript.allowed(answered: false, errorCode: -1743, before: true))
        // Spotify being busy or slow isn't a refusal.
        #expect(SpotifyScript.allowed(answered: false, errorCode: -1712, before: true))
        #expect(!SpotifyScript.allowed(answered: false, errorCode: nil, before: false))
    }

    // The menu froze when a permission check ran on the main thread. Asking must only queue work.
    @MainActor @Test func askingSpotifyNeverBlocksTheCaller() {
        let start = Date()
        for _ in 0..<50 { SpotifyScript.ask { _ in } }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    /// Edge cases found by reading the code, each a way the app could break.
    private func spotify(_ payload: [String: Any]) -> PlaybackState {
        var state = PlaybackState()
        state.apply(["type": "data", "diff": false, "payload": ["bundleIdentifier": "com.spotify.client"].merging(payload) { $1 }])
        return state
    }
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    @Test func spotifysPlaceholderIsCaughtInAnyLanguage() {
        // Spotify's placeholder has no track number at all; only English says "Advertisement".
        #expect(AdDetector.isSpotifyAd(spotify(["title": "Spotify – Werbung", "album": "", "durationMicros": 30_060_000.0])))
        #expect(AdDetector.isSpotifyAd(spotify(["title": "Spotify – Anuncio", "album": "", "durationMicros": 30_060_000.0])))
        // A song always has an album, track number or not.
        #expect(!AdDetector.isSpotifyAd(spotify(["title": "Interlude", "album": "Some Album", "durationMicros": 40_000_000.0])))
    }

    @Test func aPausedAdNeedsNoMute() {
        // Otherwise "Mute all sound" stayed on for as long as Spotify sat paused on an ad.
        var clock = SpotifyAdClock()
        let ad: [String: Any] = ["title": "Ad", "album": "", "trackNumber": 0, "durationMicros": 30_000_000.0,
                                 "elapsedTimeMicros": 5_000_000.0, "timestampEpochMicros": t0.timeIntervalSince1970 * 1_000_000]
        clock.observe(spotify(ad.merging(["playing": true, "playbackRate": 1.0]) { $1 }), at: t0)
        #expect(clock.adPlaying(at: t0.addingTimeInterval(1)))
        clock.observe(spotify(ad.merging(["playing": false]) { $1 }), at: t0.addingTimeInterval(2))
        #expect(!clock.adPlaying(at: t0.addingTimeInterval(3)))
        clock.observe(spotify(ad.merging(["playing": true, "playbackRate": 1.0]) { $1 }), at: t0.addingTimeInterval(60))
        #expect(clock.adPlaying(at: t0.addingTimeInterval(61)))
    }

    @Test func spotifyQuittingEndsTheAd() {
        var clock = SpotifyAdClock()
        clock.observe(spotify(["title": "Ad", "album": "", "trackNumber": 0, "durationMicros": 30_000_000.0, "playing": true]), at: t0)
        clock.reset()
        #expect(!clock.adPlaying(at: t0.addingTimeInterval(1)))
    }

    @Test func askingSpotifyNeverOpensItOrWaitsLong() {
        // Addressing a closed app opens it, so the running check must come first.
        #expect(SpotifyScript.source.hasPrefix("if application id \"com.spotify.client\" is not running"))
        #expect(SpotifyScript.source.contains("with timeout of 3 seconds"))
    }

    @Test func systemMuteRemembersEveryDeviceItMuted() {
        // Older versions stored one device; muting follows output changes, so now it's a list.
        #expect(SystemMute.uids(from: "BuiltInSpeakerDevice") == ["BuiltInSpeakerDevice"])
        #expect(SystemMute.uids(from: ["BuiltInSpeakerDevice", "AirPods"]) == ["BuiltInSpeakerDevice", "AirPods"])
        #expect(SystemMute.uids(from: nil).isEmpty)
    }

    @MainActor @Test func theMuterReportsWhetherItIsMuted() async throws {
        let muter = AdMuter(settle: 0.05, mute: {}, unmute: {})
        #expect(!muter.isMuted)
        muter.update(adPlaying: true)
        #expect(muter.isMuted)
        muter.update(adPlaying: false)
        #expect(muter.isMuted) // still muted until the ad has really ended
        try await Task.sleep(for: .milliseconds(150))
        #expect(!muter.isMuted)
    }

    @Test func adLengthLimitKeepsLongUntaggedTracksPlaying() {
        func spotify(duration: Double) -> PlaybackState {
            var state = PlaybackState()
            state.apply(["type": "data", "diff": false, "payload": [
                "bundleIdentifier": "com.spotify.client", "title": "x", "album": "", "trackNumber": 0,
                "durationMicros": duration * 1_000_000,
            ] as [String: Any]])
            return state
        }
        #expect(AdDetector.isSpotifyAd(spotify(duration: 65)))
        #expect(!AdDetector.isSpotifyAd(spotify(duration: 66)))
        #expect(!AdDetector.isSpotifyAd(spotify(duration: 0)))
    }
}

/// Replays a real Spotify Free session recorded on a Mac, with song names replaced: 9 ads (video,
/// audio-only and Spotify's own "Advertisement" labels), about 80 songs, a mid-ad glitch, back-to-back
/// ads, a stale ad position, and Telegram taking over Now Playing in the middle of an ad.
@Suite struct RecordedSpotifySession {
    private struct Event {
        let time: Date
        let message: [String: Any]
        let isAd: Bool?
        var payload: [String: Any] { message["payload"] as? [String: Any] ?? [:] }
    }

    private func events() throws -> [Event] {
        let url = try #require(Bundle.module.url(forResource: "spotify-session", withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return Event(time: Date(timeIntervalSince1970: json["t"] as? Double ?? 0),
                         message: ["type": "data", "diff": !(json["full"] as? Bool ?? true), "payload": json["payload"] ?? [:]],
                         isAd: json["ad"] as? Bool)
        }
    }

    @Test func everyAdIsCaughtAndNoSongIs() throws {
        var state = PlaybackState()
        var ads = 0, songs = 0
        for event in try events() {
            state.apply(event.message)
            guard let isAd = event.isAd else { continue }
            #expect(AdDetector.isSpotifyAd(state) == isAd, "\(state.title) at \(event.time.timeIntervalSince1970)s")
            if isAd { ads += 1 } else { songs += 1 }
        }
        #expect(ads == 14)
        #expect(songs == 83)
    }

    @Test func spotifyStaysMutedForEveryAdAndUnmutesForEverySong() throws {
        var state = PlaybackState()
        var clock = SpotifyAdClock()
        for event in try events() {
            state.apply(event.message)
            clock.observe(state, at: event.time)
            guard let isAd = event.isAd else { continue }
            #expect(clock.adPlaying(at: event.time) == isAd, "\(state.title) at \(event.time.timeIntervalSince1970)s")
        }
    }

    @Test func telegramTakingOverMidAdKeepsSpotifyMuted() throws {
        let all = try events()
        let lastAd = try #require(all.last { $0.isAd == true })
        let telegram = try #require(all.first {
            $0.time > lastAd.time && ($0.payload["bundleIdentifier"] as? String) == "com.tdesktop.Telegram"
        })
        var state = PlaybackState()
        var clock = SpotifyAdClock()
        for event in all where event.time <= telegram.time {
            state.apply(event.message)
            clock.observe(state, at: event.time)
        }
        // The 19-second ad started at lastAd; Telegram arrived 5 seconds in and must not end it.
        #expect(clock.adPlaying(at: telegram.time.addingTimeInterval(2)))
        #expect(!clock.adPlaying(at: lastAd.time.addingTimeInterval(25)))
    }
}
