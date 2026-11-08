import Foundation

/// Asks GitHub for Lyps's latest release. Lyps can't install it itself: an unsigned app has to be
/// approved in Privacy & Security after each download anyway, so it opens the release page.
enum Updates {
    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url" }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    static let latestURL = URL(string: "https://api.github.com/repos/ausdavoud/lyps/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares version numbers part by part, so 0.10.0 is newer than 0.9.1.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (v: String) in v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (a, b) = (parts(candidate), parts(current))
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }

    static func latest(session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("Lyps/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Release.self, from: data)
    }
}
