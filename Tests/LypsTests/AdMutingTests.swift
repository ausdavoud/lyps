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
        var calls: [String] = []
        AdMuteMode.app.mute(spotifyOnly: { calls.append("spotify"); return true }, everything: { calls.append("all") })
        #expect(calls == ["spotify"])

        calls = []
        AdMuteMode.app.mute(spotifyOnly: { calls.append("spotify"); return false }, everything: { calls.append("all") })
        #expect(calls == ["spotify", "all"])

        calls = []
        AdMuteMode.system.mute(spotifyOnly: { calls.append("spotify"); return true }, everything: { calls.append("all") })
        #expect(calls == ["all"])

        calls = []
        AdMuteMode.off.mute(spotifyOnly: { calls.append("spotify"); return true }, everything: { calls.append("all") })
        #expect(calls.isEmpty)
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
