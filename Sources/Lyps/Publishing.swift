import CryptoKit
import Foundation

/// Publishes the user's own lyrics to LRCLIB, a public database. LRCLIB guards against spam with a
/// puzzle: find a number that, written after the challenge's prefix, hashes (SHA-256) to at most
/// its target, comparing byte by byte. This mirrors LRCLIB's server code.
enum LRCLIBPublisher {
    struct Challenge: Decodable {
        let prefix: String
        let target: String
    }

    enum Failure: LocalizedError {
        case missingDetails, rejected(String)

        var errorDescription: String? {
            switch self {
            case .missingDetails: "The player didn't report the song's length, which LRCLIB needs."
            case .rejected(let reason): "LRCLIB didn't accept the lyrics: \(reason)"
            }
        }
    }

    private static let base = "https://lrclib.net/api"

    static func isSolved(prefix: String, target: [UInt8], nonce: String) -> Bool {
        let hash = Array(SHA256.hash(data: Data((prefix + nonce).utf8)))
        guard hash.count == target.count else { return false }
        for (h, t) in zip(hash, target) where h != t { return h < t }
        return true
    }

    /// Tries numbers from 0 upward. At LRCLIB's usual difficulty that's millions of hashes, so it
    /// belongs off the main thread; it stops early if the task is cancelled.
    static func solve(_ challenge: Challenge) -> String? {
        guard let target = bytes(fromHex: challenge.target), target.count == 32 else { return nil }
        var nonce = 0
        while true {
            if nonce % 50_000 == 0, Task.isCancelled { return nil }
            let candidate = String(nonce)
            if isSolved(prefix: challenge.prefix, target: target, nonce: candidate) { return candidate }
            nonce += 1
        }
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    /// What LRCLIB stores: the song as the player reports it, the plain text, and the timed lines.
    static func body(track: Track, lyrics: Lyrics) -> [String: Any] {
        var body: [String: Any] = [
            "trackName": track.title, "artistName": track.artist, "albumName": track.album,
            "duration": track.duration,
            "plainLyrics": (lyrics.plain.isEmpty ? lyrics.synced.map(\.text).filter { !$0.isEmpty } : lyrics.plain)
                .joined(separator: "\n"),
        ]
        if !lyrics.synced.isEmpty { body["syncedLyrics"] = LyricsText.lrc(lyrics.synced) }
        return body
    }

    static func publish(_ lyrics: Lyrics, for track: Track, session: URLSession = .shared) async throws {
        guard track.duration > 0, !track.title.isEmpty else { throw Failure.missingDetails }
        let challenge: Challenge = try await send("request-challenge", body: nil, session: session)
        let solved = await Task.detached(priority: .userInitiated) { solve(challenge) }.value
        guard let nonce = solved else { throw CancellationError() }
        let _: Empty = try await send("publish", body: body(track: track, lyrics: lyrics),
                                      token: "\(challenge.prefix):\(nonce)", session: session)
    }

    private struct Empty: Decodable {}

    private static func send<T: Decodable>(_ path: String, body: [String: Any]?, token: String? = nil,
                                           session: URLSession) async throws -> T {
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Lyps/\(Updates.currentVersion) (https://github.com/ausdavoud/lyps)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Publish-Token") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw Failure.rejected(message ?? "error \(status)")
        }
        if T.self == Empty.self { return Empty() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
