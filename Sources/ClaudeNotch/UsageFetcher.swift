import Foundation

/// Response shape of `GET https://api.anthropic.com/api/oauth/usage`.
/// Source of truth: `reference/claude-code-source/src/services/api/usage.ts`.
struct Utilization: Decodable, Hashable {
    struct Limit: Decodable, Hashable {
        /// Percentage 0-100 of the window used (already multiplied by 100
        /// by the server, despite the comment in the TS source).
        let utilization: Double
        /// ISO 8601 timestamp when the window resets, or nil if not active.
        let resets_at: String?
    }

    struct ExtraUsage: Decodable, Hashable {
        let is_enabled: Bool
        let monthly_limit: Double?
        let used_credits: Double?
        let utilization: Double?
    }

    let five_hour: Limit?
    let seven_day: Limit?
    let seven_day_opus: Limit?
    let seven_day_sonnet: Limit?
    let extra_usage: ExtraUsage?
}

/// Fetches Claude subscription usage from Anthropic's private API using
/// the OAuth token stored by the Claude Code CLI. Polls every few minutes
/// and publishes the result for the notch header to display.
@MainActor
final class UsageFetcher: ObservableObject {
    @Published private(set) var utilization: Utilization?
    @Published private(set) var lastFetched: Date?
    @Published private(set) var lastError: String?

    private var timer: Timer?
    /// Background refresh cadence. Tight enough to stay within a few
    /// percent of the live Anthropic counters without sharing the
    /// endpoint's rate limit with other menubar tools (Vibe Island etc.).
    private let pollInterval: TimeInterval = 10 * 60  // 10 min — StatusLine file is primary now

    /// Minimum gap between any two attempts, regardless of trigger
    /// (hover, hook, background timer). Prevents a burst at launch when
    /// several triggers fire at once.
    private let minAttemptInterval: TimeInterval = 45

    /// Cooldown applied after a 429. Anthropic's usage endpoint is shared
    /// across clients so we back off aggressively when throttled.
    private let rateLimitedCooldown: TimeInterval = 5 * 60

    private var inFlight = false
    private var lastAttempt: Date?
    private var rateLimitedUntil: Date?

    /// File watcher for rate_limits captured by StatusLine hook.
    private var fileTimer: Timer?
    private var lastFileModDate: Date?

    func start() {
        // Try the local file first (instant, no API call).
        readRateLimitsFile()
        // Fall back to API if file doesn't exist yet.
        if utilization == nil {
            Task { await self.fetch() }
        }
        // Poll the rate_limits file every 5 seconds (free, no API).
        fileTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readRateLimitsFile() }
        }
        // API fallback: poll every 5 min (only if file hasn't updated).
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetch() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fileTimer?.invalidate()
        fileTimer = nil
    }

    // MARK: - StatusLine file reader

    /// Read rate_limits from /tmp/claudenotch-rl.json (written by StatusLine hook).
    /// Format: {"primary_used_percent":40,"primary_resets_at":"ISO8601",
    ///          "secondary_used_percent":41,"secondary_resets_at":"ISO8601"}
    private func readRateLimitsFile() {
        let url = URL(fileURLWithPath: HookInstaller.rateLimitsFile)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else { return }

        // Skip if file hasn't changed since last read.
        if let last = lastFileModDate, modDate <= last { return }
        lastFileModDate = modDate

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Map StatusLine rate_limits format → our Utilization struct.
        // Format: {"five_hour":{"used_percentage":2,"resets_at":1775574000},
        //          "seven_day":{"used_percentage":43,"resets_at":1775858400}}
        let fiveHour: Utilization.Limit?
        if let fh = json["five_hour"] as? [String: Any],
           let pct = fh["used_percentage"] as? Double {
            let resetsAt = Self.timestampToISO(fh["resets_at"])
            fiveHour = Utilization.Limit(utilization: pct, resets_at: resetsAt)
        } else {
            fiveHour = nil
        }

        let sevenDay: Utilization.Limit?
        if let sd = json["seven_day"] as? [String: Any],
           let pct = sd["used_percentage"] as? Double {
            let resetsAt = Self.timestampToISO(sd["resets_at"])
            sevenDay = Utilization.Limit(utilization: pct, resets_at: resetsAt)
        } else {
            sevenDay = nil
        }

        if fiveHour != nil || sevenDay != nil {
            self.utilization = Utilization(
                five_hour: fiveHour,
                seven_day: sevenDay,
                seven_day_opus: nil,
                seven_day_sonnet: nil,
                extra_usage: nil
            )
            lastFetched = Date()
            lastError = nil
            NSLog("ClaudeNotch: rate_limits from StatusLine file: 5h=\(fiveHour?.utilization ?? -1)% 7d=\(sevenDay?.utilization ?? -1)%")
        }
    }

    /// Convert a Unix timestamp (or ISO string) to ISO 8601 string.
    private static func timestampToISO(_ value: Any?) -> String? {
        if let ts = value as? Double {
            let date = Date(timeIntervalSince1970: ts)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: date)
        }
        if let ts = value as? Int {
            return timestampToISO(Double(ts))
        }
        return value as? String
    }

    /// Manually trigger a fetch — used on app launch and by any UI retry.
    func refresh() {
        Task { await fetch() }
    }

    /// Re-fetch only if the cached value is older than `maxAge` seconds
    /// AND the attempt-level cooldown / rate-limit window allows it.
    /// Used by opportunistic triggers (hover expand, PostToolUse hook)
    /// so the UI is fresh without ever hammering the API.
    func refreshIfStale(maxAge: TimeInterval) {
        if let lastFetched, Date().timeIntervalSince(lastFetched) < maxAge {
            return
        }
        Task { await fetch() }
    }

    // MARK: - HTTP

    private static let endpointURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Beta header required to accept OAuth tokens on this endpoint.
    /// Verified from `OAUTH_BETA_HEADER` in the Claude Code source.
    private static let oauthBetaHeader = "oauth-2025-04-20"

    private func fetch() async {
        guard !inFlight else { return }

        let now = Date()

        // Honour the 429 back-off window.
        if let until = rateLimitedUntil, now < until {
            return
        }

        // Rate-limit ourselves between any two attempts, successful or not.
        if let last = lastAttempt, now.timeIntervalSince(last) < minAttemptInterval {
            return
        }

        inFlight = true
        lastAttempt = now
        defer { inFlight = false }

        guard let tokens = KeychainReader.claudeCodeOAuthTokens() else {
            lastError = "No Claude Code OAuth token in keychain"
            return
        }
        guard tokens.isValid else {
            lastError = "OAuth token expired"
            return
        }

        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-cli/2.0 (external, cli)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid HTTP response"
                return
            }

            if http.statusCode == 429 {
                // Throttled by the shared usage endpoint. Stand down for
                // a while so we don't make it worse. Keep any previous
                // `utilization` value in place so the UI shows stale
                // numbers rather than dashes.
                rateLimitedUntil = Date().addingTimeInterval(rateLimitedCooldown)
                lastError = "Rate limited (429) — backing off 5 min"
                NSLog("ClaudeNotch: usage endpoint 429 — cooling down until \(rateLimitedUntil!)")
                return
            }

            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }

            let decoded = try JSONDecoder().decode(Utilization.self, from: data)
            utilization = decoded
            lastFetched = Date()
            lastError = nil
            rateLimitedUntil = nil   // clear any lingering back-off
        } catch {
            lastError = "\(error.localizedDescription)"
        }
    }
}
