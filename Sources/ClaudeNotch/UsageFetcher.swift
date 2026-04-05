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
    /// Anthropic refreshes these numbers slowly; 5 minutes is plenty
    /// often for a notch indicator and easy on the server.
    private let pollInterval: TimeInterval = 5 * 60
    private var inFlight = false

    func start() {
        Task { await self.fetch() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetch() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manually trigger a fetch — used on app launch and by any UI retry.
    func refresh() {
        Task { await fetch() }
    }

    // MARK: - HTTP

    private static let endpointURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Beta header required to accept OAuth tokens on this endpoint.
    /// Verified from `OAUTH_BETA_HEADER` in the Claude Code source.
    private static let oauthBetaHeader = "oauth-2025-04-20"

    private func fetch() async {
        guard !inFlight else { return }
        inFlight = true
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
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let decoded = try JSONDecoder().decode(Utilization.self, from: data)
            utilization = decoded
            lastFetched = Date()
            lastError = nil
        } catch {
            lastError = "\(error.localizedDescription)"
        }
    }
}
