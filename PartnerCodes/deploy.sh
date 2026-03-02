#!/bin/bash
# ============================================================================
# Partner Codes - Supabase Deployment Script
# ============================================================================
# Run this script from the PartnerCodes/ directory on your local machine.
#
# Prerequisites:
#   1. Supabase CLI installed: brew install supabase/tap/supabase
#   2. Supabase access token: supabase login
#   3. Your project reference ID
#
# Usage:
#   cd PartnerCodes
#   chmod +x deploy.sh
#   ./deploy.sh
# ============================================================================

set -euo pipefail

# Configuration
PROJECT_REF="${SUPABASE_PROJECT_REF:-oubaqzyohtqyiyfscmgi}"
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"

echo ""
echo "============================================"
echo "  Partner Codes - Supabase Deployment"
echo "============================================"
echo ""
echo "Project: ${PROJECT_REF}"
echo "URL:     ${SUPABASE_URL}"
echo ""

# ----------------------------------------
# Step 1: Link to Supabase project
# ----------------------------------------
echo "--- Step 1: Linking to Supabase project ---"
cd supabase
supabase link --project-ref "${PROJECT_REF}"
echo "✓ Linked to project"
echo ""

# ----------------------------------------
# Step 2: Push database migration
# ----------------------------------------
echo "--- Step 2: Applying database migration ---"
supabase db push
echo "✓ Database schema applied"
echo ""

# ----------------------------------------
# Step 3: Deploy Edge Functions
# ----------------------------------------
echo "--- Step 3: Deploying Edge Functions ---"

FUNCTIONS=("generate-partner-code" "redeem-partner-code" "check-link-status" "sync-premium")

for func in "${FUNCTIONS[@]}"; do
    echo "  Deploying ${func}..."
    supabase functions deploy "${func}" --no-verify-jwt
    echo "  ✓ ${func} deployed"
done
echo ""

# ----------------------------------------
# Step 4: Verify deployment
# ----------------------------------------
echo "--- Step 4: Verification ---"
echo ""
echo "Checking Edge Function endpoints..."
for func in "${FUNCTIONS[@]}"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${SUPABASE_URL}/functions/v1/${func}" \
        -H "Authorization: Bearer ${SUPABASE_ANON_KEY:-your-anon-key}")
    if [ "$STATUS" = "401" ] || [ "$STATUS" = "200" ]; then
        echo "  ✓ ${func} is reachable (HTTP ${STATUS})"
    else
        echo "  ⚠ ${func} returned HTTP ${STATUS}"
    fi
done

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Go to your Supabase Dashboard → SQL Editor"
echo "     Run: SELECT * FROM information_schema.tables WHERE table_schema = 'public';"
echo "     (Should show: user_profiles, partner_codes, linked_accounts, premium_sharing_log)"
echo ""
echo "  2. Configure RevenueCat webhook:"
echo "     URL: ${SUPABASE_URL}/functions/v1/sync-premium"
echo "     Events: INITIAL_PURCHASE, RENEWAL, CANCELLATION, EXPIRATION"
echo ""
echo "  3. In your iOS app, set PartnerCodeConfiguration:"
echo "     PartnerCodeConfiguration.shared.configure("
echo "         supabaseURL: \"${SUPABASE_URL}\","
echo "         supabaseAnonKey: \"your-anon-key-here\""
echo "     )"
echo ""
