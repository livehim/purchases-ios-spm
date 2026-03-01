-- ============================================================================
-- Partner Codes Schema for Couples/Married Account Linking
-- ============================================================================
-- This migration creates the database schema for a partner code system that
-- allows two users (couples/married people) to link their accounts and share
-- premium subscription status.
-- ============================================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- 1. Users Profile Table
-- ============================================================================
-- Extends Supabase auth.users with app-specific profile data.
-- Each user gets a profile row automatically via trigger.

CREATE TABLE IF NOT EXISTS public.user_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name TEXT,
    email TEXT,
    is_premium BOOLEAN NOT NULL DEFAULT FALSE,
    premium_source TEXT, -- 'direct_purchase', 'partner_shared', NULL
    premium_expires_at TIMESTAMPTZ,
    revenuecat_app_user_id TEXT UNIQUE, -- Links to RevenueCat customer
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

-- Users can read their own profile
CREATE POLICY "Users can view own profile"
    ON public.user_profiles FOR SELECT
    USING (auth.uid() = id);

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
    ON public.user_profiles FOR UPDATE
    USING (auth.uid() = id);

-- Users can insert their own profile
CREATE POLICY "Users can insert own profile"
    ON public.user_profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

-- ============================================================================
-- 2. Partner Codes Table
-- ============================================================================
-- Stores generated partner codes that users can share with their partner.
-- Each code is a unique 8-character alphanumeric string.

CREATE TABLE IF NOT EXISTS public.partner_codes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT NOT NULL UNIQUE,
    owner_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    is_redeemed BOOLEAN NOT NULL DEFAULT FALSE,
    redeemed_by_user_id UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
    redeemed_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Each user can only have one active (non-redeemed, non-expired) code at a time
    CONSTRAINT valid_expiry CHECK (expires_at > created_at)
);

CREATE INDEX idx_partner_codes_code ON public.partner_codes(code);
CREATE INDEX idx_partner_codes_owner ON public.partner_codes(owner_user_id);
CREATE INDEX idx_partner_codes_redeemed_by ON public.partner_codes(redeemed_by_user_id);

ALTER TABLE public.partner_codes ENABLE ROW LEVEL SECURITY;

-- Users can view their own codes (ones they created)
CREATE POLICY "Users can view own codes"
    ON public.partner_codes FOR SELECT
    USING (auth.uid() = owner_user_id);

-- Users can view codes they redeemed
CREATE POLICY "Users can view redeemed codes"
    ON public.partner_codes FOR SELECT
    USING (auth.uid() = redeemed_by_user_id);

-- ============================================================================
-- 3. Linked Accounts Table
-- ============================================================================
-- Stores the active link between two partner accounts.
-- Only one link per user is allowed (monogamous pairing).

CREATE TABLE IF NOT EXISTS public.linked_accounts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id_1 UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    user_id_2 UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    partner_code_id UUID NOT NULL REFERENCES public.partner_codes(id) ON DELETE CASCADE,
    linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    unlinked_at TIMESTAMPTZ, -- NULL means currently linked
    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    -- Prevent duplicate links
    CONSTRAINT different_users CHECK (user_id_1 != user_id_2)
);

CREATE INDEX idx_linked_accounts_user1 ON public.linked_accounts(user_id_1);
CREATE INDEX idx_linked_accounts_user2 ON public.linked_accounts(user_id_2);
CREATE INDEX idx_linked_accounts_active ON public.linked_accounts(is_active) WHERE is_active = TRUE;

-- Ensure each user can only be in one active link
CREATE UNIQUE INDEX idx_unique_active_link_user1
    ON public.linked_accounts(user_id_1) WHERE is_active = TRUE;
CREATE UNIQUE INDEX idx_unique_active_link_user2
    ON public.linked_accounts(user_id_2) WHERE is_active = TRUE;

ALTER TABLE public.linked_accounts ENABLE ROW LEVEL SECURITY;

-- Users can view links they are part of
CREATE POLICY "Users can view own links"
    ON public.linked_accounts FOR SELECT
    USING (auth.uid() = user_id_1 OR auth.uid() = user_id_2);

-- ============================================================================
-- 4. Premium Sharing Log Table
-- ============================================================================
-- Audit log for premium status transfers between linked partners.

CREATE TABLE IF NOT EXISTS public.premium_sharing_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    linked_account_id UUID NOT NULL REFERENCES public.linked_accounts(id) ON DELETE CASCADE,
    source_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    target_user_id UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
    action TEXT NOT NULL, -- 'premium_shared', 'premium_revoked', 'premium_expired'
    premium_expires_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_premium_sharing_log_linked ON public.premium_sharing_log(linked_account_id);
CREATE INDEX idx_premium_sharing_log_source ON public.premium_sharing_log(source_user_id);
CREATE INDEX idx_premium_sharing_log_target ON public.premium_sharing_log(target_user_id);

ALTER TABLE public.premium_sharing_log ENABLE ROW LEVEL SECURITY;

-- Users can view their own sharing logs
CREATE POLICY "Users can view own sharing logs"
    ON public.premium_sharing_log FOR SELECT
    USING (auth.uid() = source_user_id OR auth.uid() = target_user_id);

-- ============================================================================
-- 5. Database Functions
-- ============================================================================

-- Function: Generate a unique partner code (8-char alphanumeric)
CREATE OR REPLACE FUNCTION public.generate_unique_code()
RETURNS TEXT AS $$
DECLARE
    new_code TEXT;
    code_exists BOOLEAN;
BEGIN
    LOOP
        -- Generate 8-character alphanumeric code (uppercase)
        new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
        -- Check if code already exists
        SELECT EXISTS(SELECT 1 FROM public.partner_codes WHERE code = new_code) INTO code_exists;
        EXIT WHEN NOT code_exists;
    END LOOP;
    RETURN new_code;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Create a partner code for the current user
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
    v_user_id := auth.uid();

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

-- Function: Redeem a partner code and link accounts
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
    v_user_id := auth.uid();

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

-- Function: Sync premium status between linked partners
CREATE OR REPLACE FUNCTION public.sync_premium_between_partners(p_link_id UUID)
RETURNS VOID AS $$
DECLARE
    v_link RECORD;
    v_user1 RECORD;
    v_user2 RECORD;
    v_premium_user_id UUID;
    v_non_premium_user_id UUID;
BEGIN
    -- Get the linked account record
    SELECT * INTO v_link FROM public.linked_accounts WHERE id = p_link_id AND is_active = TRUE;
    IF v_link IS NULL THEN
        RETURN;
    END IF;

    -- Get both users' profiles
    SELECT * INTO v_user1 FROM public.user_profiles WHERE id = v_link.user_id_1;
    SELECT * INTO v_user2 FROM public.user_profiles WHERE id = v_link.user_id_2;

    -- Determine who has premium via direct purchase
    IF v_user1.is_premium AND v_user1.premium_source = 'direct_purchase' THEN
        v_premium_user_id := v_user1.id;
        v_non_premium_user_id := v_user2.id;

        -- Share premium to partner
        UPDATE public.user_profiles
        SET is_premium = TRUE,
            premium_source = 'partner_shared',
            premium_expires_at = v_user1.premium_expires_at,
            updated_at = NOW()
        WHERE id = v_non_premium_user_id
          AND (is_premium = FALSE OR premium_source != 'direct_purchase');

        -- Log the sharing
        INSERT INTO public.premium_sharing_log
            (linked_account_id, source_user_id, target_user_id, action, premium_expires_at)
        VALUES
            (p_link_id, v_premium_user_id, v_non_premium_user_id, 'premium_shared', v_user1.premium_expires_at);

    ELSIF v_user2.is_premium AND v_user2.premium_source = 'direct_purchase' THEN
        v_premium_user_id := v_user2.id;
        v_non_premium_user_id := v_user1.id;

        -- Share premium to partner
        UPDATE public.user_profiles
        SET is_premium = TRUE,
            premium_source = 'partner_shared',
            premium_expires_at = v_user2.premium_expires_at,
            updated_at = NOW()
        WHERE id = v_non_premium_user_id
          AND (is_premium = FALSE OR premium_source != 'direct_purchase');

        -- Log the sharing
        INSERT INTO public.premium_sharing_log
            (linked_account_id, source_user_id, target_user_id, action, premium_expires_at)
        VALUES
            (p_link_id, v_premium_user_id, v_non_premium_user_id, 'premium_shared', v_user2.premium_expires_at);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: Unlink partner accounts
CREATE OR REPLACE FUNCTION public.unlink_partner()
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
DECLARE
    v_user_id UUID;
    v_link RECORD;
    v_partner_id UUID;
BEGIN
    v_user_id := auth.uid();

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

-- Function: Get partner link status for current user
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
    v_user_id := auth.uid();

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
-- 6. Triggers
-- ============================================================================

-- Auto-create user profile on sign-up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.user_profiles (id, email, display_name)
    VALUES (NEW.id, NEW.email, COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1)));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_profiles_updated_at
    BEFORE UPDATE ON public.user_profiles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
