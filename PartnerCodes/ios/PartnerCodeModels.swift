import Foundation

// MARK: - Request Models

/// Request to generate a new partner code.
public struct GenerateCodeRequest: Encodable {
    /// How many hours until the code expires (1-168, default 72).
    public let expiryHours: Int

    public init(expiryHours: Int = 72) {
        self.expiryHours = min(max(expiryHours, 1), 168)
    }

    enum CodingKeys: String, CodingKey {
        case expiryHours = "expiry_hours"
    }
}

/// Request to redeem a partner code.
public struct RedeemCodeRequest: Encodable {
    /// The partner code to redeem (8-character alphanumeric).
    public let code: String

    public init(code: String) {
        self.code = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Request to sync premium status from the client.
public struct SyncPremiumRequest: Encodable {
    /// Whether the user currently has an active premium subscription.
    public let isPremium: Bool

    /// When the premium subscription expires (ISO 8601).
    public let premiumExpiresAt: String?

    public init(isPremium: Bool, premiumExpiresAt: Date? = nil) {
        self.isPremium = isPremium
        if let date = premiumExpiresAt {
            let formatter = ISO8601DateFormatter()
            self.premiumExpiresAt = formatter.string(from: date)
        } else {
            self.premiumExpiresAt = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case isPremium = "is_premium"
        case premiumExpiresAt = "premium_expires_at"
    }
}

// MARK: - Response Models

/// Response from generating a partner code.
public struct GenerateCodeResponse: Decodable {
    /// Whether the operation succeeded.
    public let success: Bool

    /// The generated partner code (8 characters).
    public let code: String?

    /// When the code expires (ISO 8601).
    public let expiresAt: String?

    /// Human-readable message.
    public let message: String?

    /// Error message if the operation failed.
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case code
        case expiresAt = "expires_at"
        case message
        case error
    }
}

/// Response from redeeming a partner code.
public struct RedeemCodeResponse: Decodable {
    /// Whether the operation succeeded.
    public let success: Bool

    /// Human-readable message.
    public let message: String?

    /// Display name of the linked partner.
    public let partnerName: String?

    /// ID of the newly created linked account record.
    public let linkedAccountId: String?

    /// Error message if the operation failed.
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case partnerName = "partner_name"
        case linkedAccountId = "linked_account_id"
        case error
    }
}

/// Partner details within a link status response.
public struct PartnerInfo: Decodable {
    /// Partner's display name.
    public let displayName: String?

    /// Whether the partner currently has premium.
    public let isPremium: Bool?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case isPremium = "is_premium"
    }
}

/// Premium sharing details within a link status response.
public struct PremiumSharingInfo: Decodable {
    /// Whether this user is sharing their premium to their partner.
    public let sharingToPartner: Bool

    /// Whether this user is receiving premium from their partner.
    public let receivingFromPartner: Bool

    enum CodingKeys: String, CodingKey {
        case sharingToPartner = "sharing_to_partner"
        case receivingFromPartner = "receiving_from_partner"
    }
}

/// Response from checking link status.
public struct LinkStatusResponse: Decodable {
    /// Whether the user currently has a linked partner.
    public let isLinked: Bool

    /// Partner details (nil if not linked).
    public let partner: PartnerInfo?

    /// When the accounts were linked (ISO 8601).
    public let linkedAt: String?

    /// Premium sharing status between partners.
    public let premiumSharing: PremiumSharingInfo?

    /// Error message if the request failed.
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case isLinked = "is_linked"
        case partner
        case linkedAt = "linked_at"
        case premiumSharing = "premium_sharing"
        case error
    }
}

/// Response from syncing premium status.
public struct SyncPremiumResponse: Decodable {
    /// Whether the operation succeeded.
    public let success: Bool

    /// Whether premium was synced to the partner.
    public let premiumSyncedToPartner: Bool?

    /// Human-readable message.
    public let message: String?

    /// Error message if the operation failed.
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case premiumSyncedToPartner = "premium_synced_to_partner"
        case message
        case error
    }
}

// MARK: - Verify Setup Response

/// Tables existence check from the verify-setup endpoint.
public struct TablesExist: Decodable {
    public let userProfiles: Bool
    public let partnerCodes: Bool
    public let linkedAccounts: Bool
    public let premiumSharingLog: Bool

    enum CodingKeys: String, CodingKey {
        case userProfiles = "user_profiles"
        case partnerCodes = "partner_codes"
        case linkedAccounts = "linked_accounts"
        case premiumSharingLog = "premium_sharing_log"
    }
}

/// Functions accessibility check from the verify-setup endpoint.
public struct FunctionsAccessible: Decodable {
    public let getPartnerStatus: Bool
    public let createPartnerCode: Bool
    public let redeemPartnerCode: Bool

    enum CodingKeys: String, CodingKey {
        case getPartnerStatus = "get_partner_status"
        case createPartnerCode = "create_partner_code"
        case redeemPartnerCode = "redeem_partner_code"
    }
}

/// Active code info from the verify-setup endpoint.
public struct ActiveCodeInfo: Decodable {
    public let code: String
    public let expiresAt: String
    public let isRedeemed: Bool

    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
        case isRedeemed = "is_redeemed"
    }
}

/// Link status info from the verify-setup endpoint.
public struct VerifyLinkStatus: Decodable {
    public let isLinked: Bool
    public let partnerDisplayName: String?
    public let linkedAt: String?

    enum CodingKeys: String, CodingKey {
        case isLinked = "is_linked"
        case partnerDisplayName = "partner_display_name"
        case linkedAt = "linked_at"
    }
}

/// Comprehensive diagnostic response from the verify-setup endpoint.
/// Use this to check whether the partner code backend is correctly configured.
public struct VerifySetupResponse: Decodable {
    /// Whether the auth token is valid.
    public let authValid: Bool

    /// The authenticated user's ID.
    public let userId: String?

    /// The authenticated user's email.
    public let email: String?

    /// Whether the user profile exists in the database.
    public let profileExists: Bool

    /// Which database tables exist.
    public let tablesExist: TablesExist

    /// Which database functions are accessible.
    public let functionsAccessible: FunctionsAccessible

    /// Recent partner codes generated by this user.
    public let activeCodes: [ActiveCodeInfo]

    /// Current partner link status.
    public let linkStatus: VerifyLinkStatus?

    /// Any errors or warnings found during verification.
    public let errors: [String]

    enum CodingKeys: String, CodingKey {
        case authValid = "auth_valid"
        case userId = "user_id"
        case email
        case profileExists = "profile_exists"
        case tablesExist = "tables_exist"
        case functionsAccessible = "functions_accessible"
        case activeCodes = "active_codes"
        case linkStatus = "link_status"
        case errors
    }
}

// MARK: - Error Types

/// Errors that can occur when using the partner code system.
public struct PartnerCodeError: LocalizedError, CustomStringConvertible {

    /// The underlying error category.
    public let kind: Kind

    /// A human-readable message describing the error.
    public let message: String

    public var errorDescription: String? { message }
    public var description: String { "PartnerCodeError(\(kind)): \(message)" }

    public enum Kind {
        case notConfigured
        case notAuthenticated
        case networkError
        case invalidCode
        case codeExpired
        case codeAlreadyUsed
        case alreadyLinked
        case notLinked
        case cannotRedeemOwnCode
        case serverError
        case decodingError
    }

    public static func notConfigured() -> PartnerCodeError {
        PartnerCodeError(kind: .notConfigured, message: "PartnerCodeConfiguration.shared must be set before use")
    }

    public static func notAuthenticated() -> PartnerCodeError {
        PartnerCodeError(kind: .notAuthenticated, message: "User must be authenticated to use partner codes")
    }

    public static func networkError(_ underlying: Error) -> PartnerCodeError {
        PartnerCodeError(kind: .networkError, message: "Network error: \(underlying.localizedDescription)")
    }

    public static func serverError(_ message: String) -> PartnerCodeError {
        PartnerCodeError(kind: .serverError, message: message)
    }
}
