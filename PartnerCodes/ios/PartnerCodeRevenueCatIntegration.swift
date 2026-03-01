import Foundation

/// Integration helper that bridges RevenueCat subscription events with the
/// partner code system to automatically sync premium status between linked accounts.
///
/// ## Setup
///
/// Add this as a delegate in your app initialization:
///
/// ```swift
/// // In your AppDelegate or App init:
/// Purchases.shared.delegate = PartnerCodeRevenueCatDelegate.shared
///
/// // Or if you already have a delegate, call from your existing delegate:
/// func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
///     Task {
///         await PartnerCodeRevenueCatDelegate.shared.syncPremiumFromCustomerInfo(customerInfo)
///     }
///     // ... your other delegate logic
/// }
/// ```
public final class PartnerCodeRevenueCatDelegate: NSObject {

    /// Shared singleton instance.
    public static let shared = PartnerCodeRevenueCatDelegate()

    /// The entitlement identifier to check for premium status.
    /// Defaults to "premium". Change this to match your RevenueCat entitlement.
    public var premiumEntitlementIdentifier: String = "premium"

    /// Called when RevenueCat customer info is updated.
    /// Extracts premium status and syncs it with the partner code backend.
    ///
    /// - Parameter customerInfo: A dictionary representation of the customer info.
    ///   Expected keys: "entitlements" containing entitlement data.
    public func syncPremiumFromCustomerInfo(_ customerInfo: [String: Any]) async {
        // Extract premium status from customer info dictionary
        guard let entitlements = customerInfo["entitlements"] as? [String: Any],
              let premiumEntitlement = entitlements[premiumEntitlementIdentifier] as? [String: Any] else {
            // No premium entitlement found - sync as non-premium
            do {
                _ = try await PartnerCodeManager.shared.syncPremiumStatus(isPremium: false)
            } catch {
                print("[PartnerCodes] Failed to sync non-premium status: \(error)")
            }
            return
        }

        let isActive = premiumEntitlement["isActive"] as? Bool ?? false

        var expirationDate: Date?
        if let expirationString = premiumEntitlement["expirationDate"] as? String {
            let formatter = ISO8601DateFormatter()
            expirationDate = formatter.date(from: expirationString)
        }

        do {
            let result = try await PartnerCodeManager.shared.syncPremiumStatus(
                isPremium: isActive,
                premiumExpiresAt: expirationDate
            )
            if result.premiumSyncedToPartner == true {
                print("[PartnerCodes] Premium status synced to partner successfully")
            }
        } catch {
            print("[PartnerCodes] Failed to sync premium status: \(error)")
        }
    }
}
