-- ============================================================================
-- Partner Codes Verification Script
-- ============================================================================
-- Run this against your Supabase database to verify the schema, functions,
-- and partner code flow are working correctly.
--
-- Usage:
--   psql -h db.your-project.supabase.co -U postgres -d postgres -f verify_partner_codes.sql
--   Or run sections in the Supabase SQL Editor.
-- ============================================================================

-- ============================================================================
-- STEP 1: Verify Schema Exists
-- ============================================================================
DO $$
DECLARE
    table_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO table_count
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name IN ('user_profiles', 'partner_codes', 'linked_accounts', 'premium_sharing_log');

    IF table_count = 4 THEN
        RAISE NOTICE '✓ All 4 tables exist (user_profiles, partner_codes, linked_accounts, premium_sharing_log)';
    ELSE
        RAISE EXCEPTION '✗ Expected 4 tables, found %', table_count;
    END IF;
END $$;

-- ============================================================================
-- STEP 2: Verify Functions Exist
-- ============================================================================
DO $$
DECLARE
    func_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO func_count
    FROM information_schema.routines
    WHERE routine_schema = 'public'
      AND routine_name IN (
        'generate_unique_code',
        'create_partner_code',
        'redeem_partner_code',
        'sync_premium_between_partners',
        'unlink_partner',
        'get_partner_status',
        'handle_new_user',
        'update_updated_at',
        'ensure_user_profile_exists'
      );

    IF func_count >= 7 THEN
        RAISE NOTICE '✓ All database functions exist (% found)', func_count;
    ELSE
        RAISE EXCEPTION '✗ Expected at least 7 functions, found %. Did you apply migration 002?', func_count;
    END IF;
END $$;

-- ============================================================================
-- STEP 3: Verify RLS Policies Exist
-- ============================================================================
DO $$
DECLARE
    policy_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('user_profiles', 'partner_codes', 'linked_accounts', 'premium_sharing_log');

    IF policy_count >= 6 THEN
        RAISE NOTICE '✓ RLS policies configured (% policies found)', policy_count;
    ELSE
        RAISE WARNING '⚠ Expected at least 6 RLS policies, found %. Check security.', policy_count;
    END IF;
END $$;

-- ============================================================================
-- STEP 4: Verify Indexes Exist
-- ============================================================================
DO $$
DECLARE
    index_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO index_count
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename IN ('partner_codes', 'linked_accounts', 'premium_sharing_log');

    IF index_count >= 7 THEN
        RAISE NOTICE '✓ Performance indexes configured (% indexes found)', index_count;
    ELSE
        RAISE WARNING '⚠ Expected at least 7 indexes, found %. Performance may be impacted.', index_count;
    END IF;
END $$;

-- ============================================================================
-- STEP 5: Verify Unique Constraints
-- ============================================================================
DO $$
DECLARE
    constraint_exists BOOLEAN;
BEGIN
    -- Check unique active link constraint for user_id_1
    SELECT EXISTS(
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'idx_unique_active_link_user1'
    ) INTO constraint_exists;

    IF constraint_exists THEN
        RAISE NOTICE '✓ Unique active link constraint exists for user_id_1';
    ELSE
        RAISE WARNING '✗ Missing unique active link constraint for user_id_1';
    END IF;

    -- Check unique active link constraint for user_id_2
    SELECT EXISTS(
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'idx_unique_active_link_user2'
    ) INTO constraint_exists;

    IF constraint_exists THEN
        RAISE NOTICE '✓ Unique active link constraint exists for user_id_2';
    ELSE
        RAISE WARNING '✗ Missing unique active link constraint for user_id_2';
    END IF;
END $$;

-- ============================================================================
-- STEP 6: Verify ensure_user_profile_exists (Migration 002)
-- ============================================================================
DO $$
DECLARE
    func_exists BOOLEAN;
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = 'public'
          AND routine_name = 'ensure_user_profile_exists'
    ) INTO func_exists;

    IF func_exists THEN
        RAISE NOTICE '✓ ensure_user_profile_exists function exists (migration 002 applied)';
    ELSE
        RAISE EXCEPTION '✗ ensure_user_profile_exists function NOT found. Apply migration 002_fix_auto_create_profiles.sql';
    END IF;
END $$;

-- ============================================================================
-- STEP 7: Verify Code Generation Works
-- ============================================================================
DO $$
DECLARE
    test_code TEXT;
BEGIN
    test_code := public.generate_unique_code();

    IF length(test_code) = 8 AND test_code ~ '^[A-Z0-9]+$' THEN
        RAISE NOTICE '✓ Code generation works: %', test_code;
    ELSE
        RAISE EXCEPTION '✗ Code generation produced invalid code: %', test_code;
    END IF;
END $$;

-- ============================================================================
-- STEP 8: Verify Table Columns
-- ============================================================================
DO $$
DECLARE
    col_count INTEGER;
BEGIN
    -- Check user_profiles columns
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_profiles'
      AND column_name IN ('id', 'display_name', 'email', 'is_premium', 'premium_source',
                          'premium_expires_at', 'revenuecat_app_user_id', 'created_at', 'updated_at');

    IF col_count = 9 THEN
        RAISE NOTICE '✓ user_profiles table has all 9 required columns';
    ELSE
        RAISE WARNING '⚠ user_profiles expected 9 columns, found %', col_count;
    END IF;

    -- Check partner_codes columns
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'partner_codes'
      AND column_name IN ('id', 'code', 'owner_user_id', 'is_redeemed',
                          'redeemed_by_user_id', 'redeemed_at', 'expires_at', 'created_at');

    IF col_count = 8 THEN
        RAISE NOTICE '✓ partner_codes table has all 8 required columns';
    ELSE
        RAISE WARNING '⚠ partner_codes expected 8 columns, found %', col_count;
    END IF;

    -- Check linked_accounts columns
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'linked_accounts'
      AND column_name IN ('id', 'user_id_1', 'user_id_2', 'partner_code_id',
                          'linked_at', 'unlinked_at', 'is_active');

    IF col_count = 7 THEN
        RAISE NOTICE '✓ linked_accounts table has all 7 required columns';
    ELSE
        RAISE WARNING '⚠ linked_accounts expected 7 columns, found %', col_count;
    END IF;

    -- Check premium_sharing_log columns
    SELECT COUNT(*) INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'premium_sharing_log'
      AND column_name IN ('id', 'linked_account_id', 'source_user_id', 'target_user_id',
                          'action', 'premium_expires_at', 'metadata', 'created_at');

    IF col_count = 8 THEN
        RAISE NOTICE '✓ premium_sharing_log table has all 8 required columns';
    ELSE
        RAISE WARNING '⚠ premium_sharing_log expected 8 columns, found %', col_count;
    END IF;
END $$;

-- ============================================================================
-- STEP 9: Verify Triggers
-- ============================================================================
DO $$
DECLARE
    trigger_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO trigger_count
    FROM information_schema.triggers
    WHERE trigger_schema = 'public'
      AND trigger_name IN ('update_user_profiles_updated_at');

    -- Also check auth trigger (may be in a different schema)
    IF trigger_count >= 1 THEN
        RAISE NOTICE '✓ Database triggers are configured (% found)', trigger_count;
    ELSE
        RAISE WARNING '⚠ Expected at least 1 trigger, found %', trigger_count;
    END IF;
END $$;

-- ============================================================================
-- SUMMARY
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================';
    RAISE NOTICE '  Partner Codes Verification Complete';
    RAISE NOTICE '============================================';
    RAISE NOTICE '';
    RAISE NOTICE 'If all checks passed (✓), the backend is ready.';
    RAISE NOTICE 'Next steps:';
    RAISE NOTICE '  1. Deploy Edge Functions: supabase functions deploy';
    RAISE NOTICE '  2. Configure RevenueCat webhook to POST to sync-premium';
    RAISE NOTICE '  3. Set PartnerCodeConfiguration in your iOS app';
    RAISE NOTICE '';
END $$;
