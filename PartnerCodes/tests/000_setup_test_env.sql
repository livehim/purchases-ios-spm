-- ============================================================================
-- Test Environment Setup
-- ============================================================================
-- Creates mock Supabase auth schema and functions for local PostgreSQL testing.
-- This simulates the parts of Supabase that the partner code schema depends on.
-- ============================================================================

-- Create the auth schema (Supabase provides this)
CREATE SCHEMA IF NOT EXISTS auth;

-- Create mock auth.users table
CREATE TABLE IF NOT EXISTS auth.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT,
    raw_user_meta_data JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Mock auth.uid() function — for testing, we'll set it via a session variable
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID AS $$
BEGIN
    RETURN current_setting('app.current_user_id', true)::UUID;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql;
