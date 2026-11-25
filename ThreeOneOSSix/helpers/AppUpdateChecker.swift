import Foundation

enum AppUpdateChecker {
    static let dismissedVersionKey = "update.dismissedVersion"
    static let lastForegroundCheckKey = "update.lastForegroundCheck"
    /// Foreground checks are throttled so every app-switch does not hit the
    /// unauthenticated API (60 req/h per IP); 30 minutes matches the typical
    /// session-cadence a user needs to learn about a fresh release.
    static let foregroundThrottleInterval: TimeInterval = 5 * 60
    // Distribution lives on Gitee; every update endpoint points at the
    // tangzhanyuan/3106 repository. A missing repository simply disables
    // update prompts instead of failing loudly.
    static let apiURL = URL(string: "https://gitee.com/api/v5/repos/tangzhanyuan/3106/releases/latest")!
    static let fallbackURL = URL(string: "https://gitee.com/tangzhanyuan/3106/releases/latest")!
    /// Gitee's release payload carries no `html_url`, so the human-facing page
    /// is composed from the tag name.
    static let releasePageBase = "https://gitee.com/tangzhanyuan/3106/releases/tag/"

    /// Static manifests first. Gitee's release API is unauthenticated and rate
    /// limited per IP; the repository's raw file is authoritative for the
    /// newest published version, so the normal path makes no API call at all.
    static let manifestURLs = [
        URL(string: "https://gitee.com/tangzhanyuan/3106/raw/3106/update.json")!,
    ]

    struct Offer: Identifiable {
        let id = UUID()
        let version: String
        /// Release page — the human-facing fallback link.
        let url: URL
        /// IPA asset from the manifest, when present.
        var downloadURL: URL?
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    static func dismiss(version: String) {
        UserDefaults.standard.set(version, forKey: dismissedVersionKey)
    }

    /// Manual-check variant: same probe, but a version the user previously
    /// dismissed still surfaces (they asked, so tell them).
    static func checkIgnoringDismissal() async -> Offer? {
        guard let offer = await rawOffer() else { return nil }
        return isNewer(offer.version, than: currentVersion) ? offer : nil
    }

    // MARK: - Outcomes with reasons (3.2.4)

    /// What a manual check found, INCLUDING why it found nothing. The
    /// settings page renders each case distinctly — "already latest" and
    /// "the probe itself failed" must not collapse into one line.
    enum CheckOutcome {
        case upToDate
        case updateAvailable(Offer)
        /// Network/API failure with a human-readable reason (already
        /// localized by the caller via these keys).
        case failure(FailureReason)
    }

    enum FailureReason: Equatable {
        /// No reachable network interface (URLError, not an HTTP status).
        case offline
        /// API answered with a non-2xx status (rate limit, server error).
        case httpStatus(Int)
        /// Response arrived but could not be parsed.
        case badResponse
        /// Something else; carries a diagnostic string for the log.
        case other(String)

        var localizationKey: String {
            switch self {
            case .offline: return "update.failure.offline"
            case .httpStatus: return "update.failure.http"
            case .badResponse: return "update.failure.bad_response"
            case .other: return "update.failure.other"
            }
        }
    }

    /// Manual check with explicit outcome — the settings page uses this so
    /// a blocked probe shows WHY instead of a false "you are up to date".
    /// The static manifest answers first; the GitHub API is only a fallback.
    static func checkWithOutcome() async -> CheckOutcome {
        if let manifest = await fetchManifest() {
            return isNewer(manifest.version, than: currentVersion)
                ? .updateAvailable(manifest)
                : .upToDate
        }
        return await apiOutcome()
    }

    private static func apiOutcome() async -> CheckOutcome {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("3106", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            // URLError codes that mean "no usable path to the host".
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return .failure(.offline)
            default:
                return .failure(.other(error.localizedDescription))
            }
        } catch {
            return .failure(.other(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.badResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.httpStatus(http.statusCode))
        }
        guard let decoded = try? JSONDecoder().decode(ReleasePayload.self, from: data) else {
            return .failure(.badResponse)
        }
        let remote = normalize(decoded.tagName)
        guard !remote.isEmpty else {
            return .failure(.badResponse)
        }
        if isNewer(remote, than: currentVersion) {
            let url = decoded.pageURL ?? fallbackURL
            return .updateAvailable(Offer(version: remote, url: url))
        }
        return .upToDate
    }

    /// Foreground-switch check with a 30-minute throttle, persisted in
    /// UserDefaults so app relaunches within the window also stay quiet
    /// (the onAppear cold-start check remains unconditional). Offers fire
    /// the same alert as the cold-start path; failures are silent here.
    static func throttledForegroundCheck() async -> Offer? {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastForegroundCheckKey)
        guard now - last >= foregroundThrottleInterval else { return nil }
        UserDefaults.standard.set(now, forKey: lastForegroundCheckKey)
        return await check()
    }

    static func check() async -> Offer? {
        // No per-version suppression: the alert's second button is a plain
        // Cancel, so a release keeps prompting on the next launch or
        // foreground until it is installed.
        guard let offer = await rawOffer(),
              isNewer(offer.version, than: currentVersion) else { return nil }
        return offer
    }

    /// Manifest first, GitHub API second. Returns the newest published offer
    /// without comparing versions, so the silent and manual paths share it.
    private static func rawOffer() async -> Offer? {
        if let offer = await fetchManifest() { return offer }
        return await apiOffer()
    }

    /// API-only variant; nil on any network or HTTP failure (silent path).
    private static func apiOffer() async -> Offer? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("3106", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let remote = normalize(decoded.tagName)
            guard !remote.isEmpty else { return nil }
            let url = decoded.pageURL ?? fallbackURL
            return Offer(version: remote, url: url)
        } catch {
            return nil
        }
    }

    private struct UpdateManifest: Decodable {
        let version: String
        let build: Int?
        let page: String?
        let ipa: String?
    }

    /// Static manifest probe. A parsed manifest is authoritative for "newest
    /// published version": no API call, therefore no 403.
    private static func fetchManifest() async -> Offer? {
        // Minute-resolution cache buster: Gitee's raw endpoint caches for a
        // few minutes, and a stale answer right after a release is the one
        // case users notice.
        let stamp = String(Int(Date().timeIntervalSince1970 / 60))
        for base in manifestURLs {
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "t", value: stamp)]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("3106", forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            guard
                let (data, response) = try? await URLSession.shared.data(for: request),
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data)
            else { continue }
            let remote = normalize(manifest.version)
            guard !remote.isEmpty else { continue }
            let page = manifest.page.flatMap(URL.init(string:)) ?? fallbackURL
            // Only accept the asset when it really is an IPA; a manifest typo
            // should not turn "update" into a broken Safari download.
            let download = manifest.ipa
                .flatMap(URL.init(string:))
                .flatMap { $0.pathExtension.lowercased() == "ipa" ? $0 : nil }
            return Offer(version: remote, url: page, downloadURL: download)
        }
        return nil
    }

    /// Gitee release payload. `html_url` is optional because Gitee omits it;
    /// when it is missing the page address is rebuilt from the tag name.
    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        var pageURL: URL? {
            if let htmlURL, !htmlURL.isEmpty, let url = URL(string: htmlURL) {
                return url
            }
            let name = AppUpdateChecker.normalize(tagName)
            guard !name.isEmpty else { return nil }
            return URL(string: AppUpdateChecker.releasePageBase + "v" + name)
        }
    }

    static func normalize(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = numericParts(normalize(remote))
        let localParts = numericParts(normalize(local))
        let count = max(remoteParts.count, localParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r != l { return r > l }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int] {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        return core.split(separator: ".").compactMap { Int($0.filter(\.isNumber)) }
    }
}
