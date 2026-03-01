import Foundation

/// Manages partner code operations for linking couples/married people's accounts.
///
/// This class communicates with the Supabase backend to:
/// - Generate partner codes
/// - Redeem partner codes to link accounts
/// - Check link status between partners
/// - Sync premium subscription status to linked partners
///
/// ## Setup
///
/// 1. Configure Supabase connection:
/// ```swift
/// PartnerCodeConfiguration.shared = PartnerCodeConfiguration(
///     supabaseURL: URL(string: "https://your-project.supabase.co")!,
///     supabaseAnonKey: "your-anon-key"
/// )
/// ```
///
/// 2. Set the user's auth token after login:
/// ```swift
/// PartnerCodeManager.shared.authToken = supabaseSession.accessToken
/// ```
///
/// 3. Use the manager:
/// ```swift
/// let result = try await PartnerCodeManager.shared.generateCode()
/// print("Share this code: \(result.code!)")
/// ```
public final class PartnerCodeManager {

    /// Shared singleton instance.
    public static let shared = PartnerCodeManager()

    /// The current user's Supabase auth token. Must be set after login.
    public var authToken: String?

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    // MARK: - Partner Code Operations

    /// Generates a new partner code for the current user.
    ///
    /// The code is an 8-character alphanumeric string that the user can share
    /// with their partner. Only one active code is allowed per user at a time;
    /// generating a new code invalidates any previous active codes.
    ///
    /// - Parameter expiryHours: Hours until the code expires (1-168, default 72).
    /// - Returns: A response containing the generated code and its expiry time.
    /// - Throws: `PartnerCodeError` if the operation fails.
    public func generateCode(expiryHours: Int = 72) async throws -> GenerateCodeResponse {
        let request = GenerateCodeRequest(expiryHours: expiryHours)
        return try await performRequest(
            endpoint: "generate-partner-code",
            method: "POST",
            body: request
        )
    }

    /// Redeems a partner code to link two accounts together.
    ///
    /// When a code is successfully redeemed:
    /// - The two accounts become linked as partners
    /// - If either partner has premium, it's automatically shared
    /// - Both users can see each other's link status
    ///
    /// - Parameter code: The 8-character partner code to redeem.
    /// - Returns: A response indicating success and the partner's name.
    /// - Throws: `PartnerCodeError` if the code is invalid, expired, or already used.
    public func redeemCode(_ code: String) async throws -> RedeemCodeResponse {
        let request = RedeemCodeRequest(code: code)
        return try await performRequest(
            endpoint: "redeem-partner-code",
            method: "POST",
            body: request
        )
    }

    /// Checks the current partner link status for the authenticated user.
    ///
    /// Returns information about:
    /// - Whether the user has a linked partner
    /// - The partner's display name and premium status
    /// - Premium sharing direction (who is sharing to whom)
    ///
    /// - Returns: A response containing the link status details.
    /// - Throws: `PartnerCodeError` if the request fails.
    public func checkLinkStatus() async throws -> LinkStatusResponse {
        return try await performRequest(
            endpoint: "check-link-status",
            method: "GET"
        )
    }

    /// Syncs the current user's premium subscription status to the backend.
    ///
    /// Call this after a purchase is made or subscription status changes.
    /// If the user has a linked partner, the premium status is automatically
    /// shared with them.
    ///
    /// Typical usage with RevenueCat:
    /// ```swift
    /// // After checking customer info
    /// let customerInfo = try await Purchases.shared.customerInfo()
    /// let isPremium = customerInfo.entitlements["premium"]?.isActive == true
    /// let expiresAt = customerInfo.entitlements["premium"]?.expirationDate
    ///
    /// try await PartnerCodeManager.shared.syncPremiumStatus(
    ///     isPremium: isPremium,
    ///     premiumExpiresAt: expiresAt
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - isPremium: Whether the user currently has an active premium subscription.
    ///   - premiumExpiresAt: When the premium subscription expires.
    /// - Returns: A response indicating whether premium was synced to the partner.
    /// - Throws: `PartnerCodeError` if the sync fails.
    public func syncPremiumStatus(
        isPremium: Bool,
        premiumExpiresAt: Date? = nil
    ) async throws -> SyncPremiumResponse {
        let request = SyncPremiumRequest(
            isPremium: isPremium,
            premiumExpiresAt: premiumExpiresAt
        )
        return try await performRequest(
            endpoint: "sync-premium",
            method: "POST",
            body: request
        )
    }

    /// Unlinks the current user from their partner.
    ///
    /// After unlinking:
    /// - The partner link is deactivated
    /// - Any shared premium is revoked (users keep their own direct purchases)
    /// - Both users can generate/redeem new partner codes
    ///
    /// This calls the Supabase database function directly via RPC.
    ///
    /// - Returns: A tuple of (success, message).
    /// - Throws: `PartnerCodeError` if the unlink fails.
    public func unlinkPartner() async throws -> (success: Bool, message: String) {
        let config = try getConfiguration()
        let token = try getAuthToken()

        let url = config.supabaseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("rpc")
            .appendingPathComponent("unlink_partner")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PartnerCodeError.networkError(
                NSError(domain: "PartnerCode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PartnerCodeError.serverError("Server returned \(httpResponse.statusCode): \(errorMessage)")
        }

        struct UnlinkResult: Decodable {
            let success: Bool
            let message: String
        }

        let results = try decoder.decode([UnlinkResult].self, from: data)
        guard let result = results.first else {
            throw PartnerCodeError.serverError("Empty response from server")
        }

        return (result.success, result.message)
    }

    // MARK: - Private Helpers

    private func getConfiguration() throws -> PartnerCodeConfiguration {
        guard let config = PartnerCodeConfiguration.shared else {
            throw PartnerCodeError.notConfigured()
        }
        return config
    }

    private func getAuthToken() throws -> String {
        guard let token = authToken, !token.isEmpty else {
            throw PartnerCodeError.notAuthenticated()
        }
        return token
    }

    private func performRequest<T: Decodable>(
        endpoint: String,
        method: String,
        body: (some Encodable)? = nil as String?
    ) async throws -> T {
        let config = try getConfiguration()
        let token = try getAuthToken()

        let url = config.functionsBaseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PartnerCodeError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PartnerCodeError.networkError(
                NSError(domain: "PartnerCode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to decode error message from response
            if let errorResponse = try? decoder.decode([String: String].self, from: data),
               let errorMessage = errorResponse["error"] {
                throw PartnerCodeError.serverError(errorMessage)
            }
            throw PartnerCodeError.serverError("Server returned status \(httpResponse.statusCode)")
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PartnerCodeError(kind: .decodingError, message: "Failed to decode response: \(error.localizedDescription)")
        }
    }
}
