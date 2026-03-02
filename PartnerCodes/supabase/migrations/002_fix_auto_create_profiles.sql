-- ============================================================================
-- Fix: Auto-create user profiles on first interaction
-- ============================================================================
-- The trigger on auth.users doesn't reliably fire on hosted Supabase.
-- This migration adds an ensure_user_profile_exists() function that
-- auto-creates a profile row if one doesn't exist, and updates the
-- RPC functions to call it before doing anything else.
-- ============================================================================

-- Function: Ensure the current user has a profile row
-- Called at the start of every RPC function to guarantee the profile exists.
CREATE OR REPLACE FUNCTION public.ensure_user_profile_exists()
RETURNS UUID AS $$
DECLARE
    v_user_id UUID;
    v_email TEXT;
    v_display_name TEXT;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Check if profile already exists (fast path)
    IF EXISTS (SELECT 1 FROM public.user_profiles WHERE id = v_user_id) THEN
        RETURN v_user_id;
    END IF;

    -- Get user info from auth.users
    SELECT
        au.email,
        COALESCE(au.raw_user_meta_data->>'display_name', split_part(au.email, '@', 1))
    INTO v_email, v_display_name
    FROM auth.users au
    WHERE au.id = v_user_id;

    -- Create the profile
    INSERT INTO public.user_profiles (id, email, display_name)
    VALUES (v_user_id, v_email, v_display_name)
    ON CONFLICT (id) DO NOTHING;

    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- Update: create_partner_code - ensure profile exists first
-- ============================================================================
CREATE OR REPLACE FUNCTION public.create_partner_code(
    p_expiry_hours INTEGER DEFAULT 72
)
RETURNS TABLE(code TEXT, expires_at TIMESTAMPTZ) AS $$
DECLARE
    v_user_id UUID;
    v_code TEXT;
    v_expires_at TIMESTAMPTZ;
    v_existing_link BOOLEAN;
    v_active_code BOOLEAN;
BEGIN
    -- Ensure profile exists (auto-creates if needed)
    v_user_id := public.ensure_user_profile_exists();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    -- Check if user already has an active link
    SELECT EXISTS(
        SELECT 1 FROM public.linked_accounts
        WHERE (user_id_1 = v_user_id OR user_id_2 = v_user_id)
        AND is_active = TRUE
    ) INTO v_existing_link;

    IF v_existing_link THEN
        RAISE EXCEPTION 'Cannot create partner code: account is already linked to a partner';
    END IF;

    -- Invalidate any existing active codes for this user
    UPDATE public.partner_codes
    SET expires_at = NOW()
    WHERE owner_user_id = v_user_id
      AND is_redeemed = FALSE
      AND expires_at > NOW();

    -- Generate new code
    v_code := public.generate_unique_code();
    v_expires_at := NOW() + (p_expiry_hours || ' hours')::INTERVAL;

    -- Insert the new code
    INSERT INTO public.partner_codes (code, owner_user_id, expires_at)
    VALUES (v_code, v_user_id, v_expires_at);

    RETURN QUERY SELECT v_code, v_expires_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- Update: redeem_partner_code - ensure profile exists first
-- ============================================================================
CREATE OR REPLACE FUNCTION public.redeem_partner_code(p_code TEXT)
RETURNS TABLE(
    success BOOLEAN,
    message TEXT,
    partner_display_name TEXT,
    linked_account_id UUID
) AS $$
DECLARE
    v_user_id UUID;
    v_code_record RECORD;
    v_existing_link BOOLEAN;
    v_new_link_id UUID;
    v_partner_name TEXT;
BEGIN
    -- Ensure profile exists (auto-creates if needed)
    v_user_id := public.ensure_user_profile_exists();

    IF v_user_id IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Authentication required'::TEXT, NULL::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Find the code
    SELECT pc.* INTO v_code_record
    FROM public.partner_codes pc
    WHERE pc.code = upper(trim(p_code));

    -- Validate code exists
    IF v_code_record IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Invalid partner code'::TEXT, NULL::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Check if already redeemed
    IF v_code_record.is_redeemed THEN
        RETURN QUERY SELECT FALSE, 'This code has already been used'::TEXT, NULL::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Check if expired
    IF v_code_record.expires_at < NOW() THEN
        RETURN QUERY SELECT FALSE, 'This code has expired'::TEXT, NULL::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Cannot redeem own code
    IF v_code_record.owner_user_id = v_user_id THEN
        RETURN QUERY SELECT FALSE, 'You cannot redeem your own code'::TEXT, NULL::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Check if the redeemer already has an active link
    SELECT EXISTS(
        SELECT 1 FROM public.linked_accounts
        WHERE (user_id_1 = v_user_id OR user_id_2 = v_user_id)
        AND is_active = TRUE
    ) INTO v_existing_link;

    IF v_existing_link THEN
        RETURN QUERY SELECT FALSE, 'Your account is already linked to a partner'::TEXT, NULL::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Check if the code owner already has an active link (race condition guard)
    SELECT EXISTS(
        SELECT 1 FROM public.linked_accounts
        WHERE (user_id_1 = v_code_record.owner_user_id OR user_id_2 = v_code_record.owner_user_id)
        AND is_active = TRUE
    ) INTO v_existing_link;

    IF v_existing_link THEN
        RETURN QUERY SELECT FALSE, 'The code owner is already linked to another partner'::TEXT, NULL::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Mark code as redeemed
    UPDATE public.partner_codes
    SET is_redeemed = TRUE,
        redeemed_by_user_id = v_user_id,
        redeemed_at = NOW()
    WHERE id = v_code_record.id;

    -- Create the linked account pair
    v_new_link_id := uuid_generate_v4();
    INSERT INTO public.linked_accounts (id, user_id_1, user_id_2, partner_code_id)
    VALUES (v_new_link_id, v_code_record.owner_user_id, v_user_id, v_code_record.id);

    -- Get partner display name
    SELECT up.display_name INTO v_partner_name
    FROM public.user_profiles up
    WHERE up.id = v_code_record.owner_user_id;

    -- Sync premium status between the newly linked accounts
    PERFORM public.sync_premium_between_partners(v_new_link_id);

    RETURN QUERY SELECT TRUE, 'Accounts linked successfully!'::TEXT, v_partner_name, v_new_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- Update: get_partner_status - ensure profile exists first
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_partner_status()
RETURNS TABLE(
    is_linked BOOLEAN,
    partner_display_name TEXT,
    partner_is_premium BOOLEAN,
    linked_at TIMESTAMPTZ,
    premium_shared_to_partner BOOLEAN,
    premium_received_from_partner BOOLEAN
) AS $$
DECLARE
    v_user_id UUID;
    v_link RECORD;
    v_partner_id UUID;
    v_partner RECORD;
    v_user RECORD;
BEGIN
    -- Ensure profile exists (auto-creates if needed)
    v_user_id := public.ensure_user_profile_exists();

    IF v_user_id IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::TEXT, NULL::BOOLEAN, NULL::TIMESTAMPTZ, NULL::BOOLEAN, NULL::BOOLEAN;
        RETURN;
    END IF;

    -- Find active link
    SELECT * INTO v_link
    FROM public.linked_accounts
    WHERE (user_id_1 = v_user_id OR user_id_2 = v_user_id)
    AND is_active = TRUE;

    IF v_link IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::TEXT, NULL::BOOLEAN, NULL::TIMESTAMPTZ, FALSE, FALSE;
        RETURN;
    END IF;

    -- Determine partner
    IF v_link.user_id_1 = v_user_id THEN
        v_partner_id := v_link.user_id_2;
    ELSE
        v_partner_id := v_link.user_id_1;
    END IF;

    -- Get partner and user profiles
    SELECT * INTO v_partner FROM public.user_profiles WHERE id = v_partner_id;
    SELECT * INTO v_user FROM public.user_profiles WHERE id = v_user_id;

    RETURN QUERY SELECT
        TRUE,
        v_partner.display_name,
        v_partner.is_premium,
        v_link.linked_at,
        (v_user.is_premium AND v_user.premium_source = 'direct_purchase' AND v_partner.premium_source = 'partner_shared'),
        (v_user.premium_source = 'partner_shared');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- Update: unlink_partner - ensure profile exists first
-- ============================================================================
CREATE OR REPLACE FUNCTION public.unlink_partner()
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
DECLARE
    v_user_id UUID;
    v_link RECORD;
    v_partner_id UUID;
BEGIN
    -- Ensure profile exists (auto-creates if needed)
    v_user_id := public.ensure_user_profile_exists();

    IF v_user_id IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Authentication required'::TEXT;
        RETURN;
    END IF;

    -- Find active link
    SELECT * INTO v_link
    FROM public.linked_accounts
    WHERE (user_id_1 = v_user_id OR user_id_2 = v_user_id)
    AND is_active = TRUE;

    IF v_link IS NULL THEN
        RETURN QUERY SELECT FALSE, 'No active partner link found'::TEXT;
        RETURN;
    END IF;

    -- Determine partner
    IF v_link.user_id_1 = v_user_id THEN
        v_partner_id := v_link.user_id_2;
    ELSE
        v_partner_id := v_link.user_id_1;
    END IF;

    -- Deactivate the link
    UPDATE public.linked_accounts
    SET is_active = FALSE, unlinked_at = NOW()
    WHERE id = v_link.id;

    -- Revoke shared premium from both users (only if source is 'partner_shared')
    UPDATE public.user_profiles
    SET is_premium = FALSE,
        premium_source = NULL,
        premium_expires_at = NULL,
        updated_at = NOW()
    WHERE id IN (v_user_id, v_partner_id)
      AND premium_source = 'partner_shared';

    -- Log the revocation
    INSERT INTO public.premium_sharing_log
        (linked_account_id, source_user_id, target_user_id, action)
    VALUES
        (v_link.id, v_user_id, v_partner_id, 'premium_revoked');

    RETURN QUERY SELECT TRUE, 'Partner link removed successfully'::TEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
