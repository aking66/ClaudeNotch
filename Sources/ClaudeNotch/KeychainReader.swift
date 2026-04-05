import Foundation
import Security

/// Reads the OAuth credentials that the Claude Code CLI stores in the
/// macOS login keychain. The entry lives under the generic-password
/// service name "Claude Code-credentials" and carries a JSON blob like:
///
///     {"claudeAiOauth":{"accessToken":"sk-ant-oat01-...",
///                       "refreshToken":"sk-ant-ort01-...",
///                       "expiresAt":1775399088269,
///                       "scopes":[...],
///                       "subscriptionType":"max",
///                       "rateLimitTier":"default_claude_max_5x"}}
///
/// First access will trigger a macOS keychain permission prompt asking the
/// user to allow ClaudeNotch to read the item. Once approved, subsequent
/// reads are silent for the life of the app.
enum KeychainReader {

    /// The service identifier Claude Code uses for its generic-password entry.
    /// Verified from the source (src/services/secureStorage) and via
    /// `security find-generic-password -s "Claude Code-credentials"`.
    static let serviceName = "Claude Code-credentials"

    struct OAuthTokens: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Int64    // milliseconds since Unix epoch
        let scopes: [String]?
        let subscriptionType: String?

        /// True if the stored expiration is still in the future (with a
        /// 60-second safety margin to avoid racing the server clock).
        var isValid: Bool {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            return expiresAt > nowMs + 60_000
        }
    }

    private struct Envelope: Decodable {
        let claudeAiOauth: OAuthTokens
    }

    /// Fetch the current OAuth tokens from the keychain. Returns nil on any
    /// error (missing entry, denied access, malformed JSON).
    static func claudeCodeOAuthTokens() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        return envelope.claudeAiOauth
    }
}
