# Partner Codes — Account Linking for Couples

A complete Supabase-backed system for linking two user accounts (couples/married people) and sharing premium subscription status between them.

## Architecture

```
┌─────────────────┐     ┌──────────────────────┐     ┌──────────────┐
│   iOS App        │     │   Supabase Backend    │     │  RevenueCat  │
│                  │     │                       │     │              │
│ PartnerCode      │────▶│ Edge Functions         │     │  Webhook ───▶│
│ Manager.swift    │     │  ├ generate-code       │     │              │
│                  │     │  ├ redeem-code          │     └──────────────┘
│ RevenueCat       │     │  ├ check-link-status   │            │
│ Integration      │     │  └ sync-premium ◀──────│────────────┘
│                  │     │                        │
└─────────────────┘     │ PostgreSQL Database     │
                        │  ├ user_profiles        │
                        │  ├ partner_codes        │
                        │  ├ linked_accounts      │
                        │  └ premium_sharing_log  │
                        └─────────────────────────┘
```

## How It Works

### Flow: Linking Accounts

1. **User A** generates a partner code (8-character alphanumeric, valid 72 hours)
2. **User A** shares the code with their partner (text, email, in person)
3. **User B** enters the code in the app to redeem it
4. Accounts are linked — if either has premium, it's shared automatically

### Flow: Premium Sharing

1. **User A** purchases premium via RevenueCat
2. RevenueCat fires a webhook → `sync-premium` Edge Function
3. The function updates User A's `is_premium = true, premium_source = 'direct_purchase'`
4. It finds the linked partner (User B) and sets `is_premium = true, premium_source = 'partner_shared'`
5. User B now has premium access

### Flow: Unlinking

1. Either user initiates an unlink
2. The link is deactivated (`is_active = false`)
3. Shared premium is revoked (only `partner_shared`, not `direct_purchase`)
4. Both users can now link with someone else

## Database Schema

| Table | Purpose |
|-------|---------|
| `user_profiles` | User data, premium status, RevenueCat ID |
| `partner_codes` | Generated codes with expiry and redemption tracking |
| `linked_accounts` | Active partner links (one per user) |
| `premium_sharing_log` | Audit trail of all premium share/revoke events |

### Key Constraints

- **One active link per user** — enforced by unique partial indexes
- **Different users** — cannot link to yourself
- **Code expiry** — codes expire after a configurable period (default 72 hours)
- **Row-Level Security** — users can only read their own data

## Setup

### 1. Deploy Database Schema

```bash
# Using Supabase CLI
cd PartnerCodes/supabase
supabase db push

# Or run manually in the SQL Editor:
# Copy contents of migrations/001_create_partner_codes_schema.sql
```

### 2. Deploy Edge Functions

```bash
cd PartnerCodes/supabase
supabase functions deploy generate-partner-code
supabase functions deploy redeem-partner-code
supabase functions deploy check-link-status
supabase functions deploy sync-premium
```

### 3. Configure RevenueCat Webhook

In [RevenueCat Dashboard](https://app.revenuecat.com) → Your App → Integrations → Webhooks:

- **URL**: `https://your-project.supabase.co/functions/v1/sync-premium`
- **Authorization Header**: Your Supabase service role key
- **Events**: `INITIAL_PURCHASE`, `RENEWAL`, `CANCELLATION`, `EXPIRATION`, `BILLING_ISSUE`, `PRODUCT_CHANGE`, `UNCANCELLATION`

### 4. Configure iOS App

```swift
import Foundation

// In your app initialization:
PartnerCodeConfiguration.shared = PartnerCodeConfiguration(
    supabaseURL: URL(string: "https://your-project.supabase.co")!,
    supabaseAnonKey: "your-anon-key"
)

// After user login (set the Supabase auth token):
PartnerCodeManager.shared.authToken = session.accessToken
```

### 5. Usage in Your App

```swift
// Generate a code to share with partner
let result = try await PartnerCodeManager.shared.generateCode()
print("Share this code: \(result.code!)")
// Display result.code to the user, they share it with their partner

// Partner redeems the code
let redeemResult = try await PartnerCodeManager.shared.redeemCode("ABC12345")
if redeemResult.success {
    print("Linked with \(redeemResult.partnerName!)!")
}

// Check link status
let status = try await PartnerCodeManager.shared.checkLinkStatus()
if status.isLinked {
    print("Linked to: \(status.partner?.displayName ?? "Partner")")
    print("Sharing premium: \(status.premiumSharing?.sharingToPartner ?? false)")
}

// Sync premium after RevenueCat update
try await PartnerCodeManager.shared.syncPremiumStatus(
    isPremium: true,
    premiumExpiresAt: expirationDate
)

// Unlink from partner
let (success, message) = try await PartnerCodeManager.shared.unlinkPartner()
```

## Verification

### Verify Database Schema

```bash
psql -h db.your-project.supabase.co -U postgres -f tests/verify_partner_codes.sql
```

### Run End-to-End Flow Test

```bash
psql -h db.your-project.supabase.co -U postgres -f tests/test_partner_flow.sql
```

### Test Edge Functions

```bash
# Generate a code (replace with your auth token)
curl -X POST https://your-project.supabase.co/functions/v1/generate-partner-code \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"expiry_hours": 72}'

# Redeem a code
curl -X POST https://your-project.supabase.co/functions/v1/redeem-partner-code \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"code": "ABC12345"}'

# Check link status
curl -X GET https://your-project.supabase.co/functions/v1/check-link-status \
  -H "Authorization: Bearer YOUR_TOKEN"
```

## Security

- **Row-Level Security (RLS)** is enabled on all tables — users can only access their own data
- **Database functions** use `SECURITY DEFINER` to perform operations as the database owner while validating the caller's identity via `auth.uid()`
- **JWT verification** is enabled on all edge functions except `sync-premium` (to allow RevenueCat server-to-server webhooks)
- **Partner codes** expire automatically and are single-use
- **Unique constraints** prevent a user from being linked to multiple partners simultaneously
