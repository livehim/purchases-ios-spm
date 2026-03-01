import XCTest
@testable import Foundation

// MARK: - Unit Tests for Partner Code Models and Configuration

/// Tests for the partner code system's iOS client components.
/// These tests verify model encoding/decoding and configuration validation
/// without requiring a live Supabase backend.
final class PartnerCodeManagerTests: XCTestCase {

    // MARK: - Configuration Tests

    func testConfigurationSetup() {
        let config = PartnerCodeConfiguration(
            supabaseURL: URL(string: "https://test-project.supabase.co")!,
            supabaseAnonKey: "test-anon-key-12345"
        )

        XCTAssertEqual(config.supabaseURL.absoluteString, "https://test-project.supabase.co")
        XCTAssertEqual(config.supabaseAnonKey, "test-anon-key-12345")
        XCTAssertEqual(
            config.functionsBaseURL.absoluteString,
            "https://test-project.supabase.co/functions/v1"
        )
    }

    func testConfigurationSingleton() {
        PartnerCodeConfiguration.shared = PartnerCodeConfiguration(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseAnonKey: "test-key"
        )

        XCTAssertNotNil(PartnerCodeConfiguration.shared)
        XCTAssertEqual(PartnerCodeConfiguration.shared?.supabaseAnonKey, "test-key")

        // Clean up
        PartnerCodeConfiguration.shared = nil
    }

    // MARK: - Model Encoding Tests

    func testGenerateCodeRequestEncoding() throws {
        let request = GenerateCodeRequest(expiryHours: 48)
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["expiry_hours"] as? Int, 48)
    }

    func testGenerateCodeRequestClampsValues() {
        // Too low
        let low = GenerateCodeRequest(expiryHours: 0)
        XCTAssertEqual(low.expiryHours, 1)

        // Too high
        let high = GenerateCodeRequest(expiryHours: 500)
        XCTAssertEqual(high.expiryHours, 168)

        // Normal
        let normal = GenerateCodeRequest(expiryHours: 72)
        XCTAssertEqual(normal.expiryHours, 72)
    }

    func testRedeemCodeRequestNormalizesInput() {
        let request = RedeemCodeRequest(code: "  abc12345  ")
        XCTAssertEqual(request.code, "ABC12345")
    }

    func testSyncPremiumRequestEncoding() throws {
        let date = ISO8601DateFormatter().date(from: "2026-04-01T00:00:00Z")!
        let request = SyncPremiumRequest(isPremium: true, premiumExpiresAt: date)
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["is_premium"] as? Bool, true)
        XCTAssertEqual(json["premium_expires_at"] as? String, "2026-04-01T00:00:00Z")
    }

    func testSyncPremiumRequestWithoutExpiry() throws {
        let request = SyncPremiumRequest(isPremium: false)
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["is_premium"] as? Bool, false)
        XCTAssertNil(json["premium_expires_at"])
    }

    // MARK: - Model Decoding Tests

    func testGenerateCodeResponseDecoding() throws {
        let json = """
        {
            "success": true,
            "code": "ABC12345",
            "expires_at": "2026-03-04T00:00:00Z",
            "message": "Share this code with your partner"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GenerateCodeResponse.self, from: json)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.code, "ABC12345")
        XCTAssertEqual(response.expiresAt, "2026-03-04T00:00:00Z")
        XCTAssertEqual(response.message, "Share this code with your partner")
        XCTAssertNil(response.error)
    }

    func testRedeemCodeResponseDecoding() throws {
        let json = """
        {
            "success": true,
            "message": "Accounts linked successfully!",
            "partner_name": "Alice",
            "linked_account_id": "550e8400-e29b-41d4-a716-446655440000"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RedeemCodeResponse.self, from: json)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.partnerName, "Alice")
        XCTAssertNotNil(response.linkedAccountId)
    }

    func testRedeemCodeErrorResponseDecoding() throws {
        let json = """
        {
            "success": false,
            "error": "This code has expired"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RedeemCodeResponse.self, from: json)
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.error, "This code has expired")
    }

    func testLinkStatusResponseDecoding() throws {
        let json = """
        {
            "is_linked": true,
            "partner": {
                "display_name": "Bob",
                "is_premium": true
            },
            "linked_at": "2026-03-01T10:00:00Z",
            "premium_sharing": {
                "sharing_to_partner": true,
                "receiving_from_partner": false
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(LinkStatusResponse.self, from: json)
        XCTAssertTrue(response.isLinked)
        XCTAssertEqual(response.partner?.displayName, "Bob")
        XCTAssertEqual(response.partner?.isPremium, true)
        XCTAssertTrue(response.premiumSharing?.sharingToPartner ?? false)
        XCTAssertFalse(response.premiumSharing?.receivingFromPartner ?? true)
    }

    func testLinkStatusUnlinkedResponseDecoding() throws {
        let json = """
        {
            "is_linked": false,
            "partner": null,
            "linked_at": null,
            "premium_sharing": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(LinkStatusResponse.self, from: json)
        XCTAssertFalse(response.isLinked)
        XCTAssertNil(response.partner)
        XCTAssertNil(response.premiumSharing)
    }

    func testSyncPremiumResponseDecoding() throws {
        let json = """
        {
            "success": true,
            "premium_synced_to_partner": true,
            "message": "Premium shared with partner"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SyncPremiumResponse.self, from: json)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.premiumSyncedToPartner, true)
        XCTAssertEqual(response.message, "Premium shared with partner")
    }

    // MARK: - Error Tests

    func testPartnerCodeErrors() {
        let notConfigured = PartnerCodeError.notConfigured()
        XCTAssertEqual(notConfigured.kind, .notConfigured)
        XCTAssertTrue(notConfigured.message.contains("PartnerCodeConfiguration"))

        let notAuthenticated = PartnerCodeError.notAuthenticated()
        XCTAssertEqual(notAuthenticated.kind, .notAuthenticated)

        let networkError = PartnerCodeError.networkError(
            NSError(domain: "test", code: -1, userInfo: nil)
        )
        XCTAssertEqual(networkError.kind, .networkError)

        let serverError = PartnerCodeError.serverError("test error")
        XCTAssertEqual(serverError.kind, .serverError)
        XCTAssertEqual(serverError.message, "test error")
    }

    func testPartnerCodeErrorDescription() {
        let error = PartnerCodeError.serverError("Something went wrong")
        XCTAssertTrue(error.description.contains("serverError"))
        XCTAssertTrue(error.description.contains("Something went wrong"))
        XCTAssertEqual(error.errorDescription, "Something went wrong")
    }

    // MARK: - Manager Auth Token Tests

    func testManagerRequiresAuthToken() async {
        PartnerCodeConfiguration.shared = PartnerCodeConfiguration(
            supabaseURL: URL(string: "https://test.supabase.co")!,
            supabaseAnonKey: "key"
        )
        PartnerCodeManager.shared.authToken = nil

        do {
            _ = try await PartnerCodeManager.shared.checkLinkStatus()
            XCTFail("Should throw not authenticated error")
        } catch let error as PartnerCodeError {
            XCTAssertEqual(error.kind, .notAuthenticated)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }

        // Clean up
        PartnerCodeConfiguration.shared = nil
    }

    func testManagerRequiresConfiguration() async {
        PartnerCodeConfiguration.shared = nil

        do {
            _ = try await PartnerCodeManager.shared.checkLinkStatus()
            XCTFail("Should throw not configured error")
        } catch let error as PartnerCodeError {
            XCTAssertEqual(error.kind, .notConfigured)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
