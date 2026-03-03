// Edge Function: Check Link Status
// GET /functions/v1/check-link-status
// Auth: Required (Bearer token)
//
// Returns the current partner link status for the authenticated user,
// including partner info and premium sharing details.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createServiceClient } from "../_shared/supabase-client.ts";

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Verify authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing authorization header" }),
        {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Create Supabase client with user's auth
    const supabase = createUserClient(authHeader);

    // Ensure user profile exists before calling RPC
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid authentication" }),
        {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const serviceClient = createServiceClient();
    const { error: upsertError } = await serviceClient
      .from("user_profiles")
      .upsert(
        {
          id: user.id,
          email: user.email ?? null,
          display_name: user.email ? user.email.split("@")[0] : null,
        },
        { onConflict: "id", ignoreDuplicates: true }
      );

    if (upsertError) {
      console.error("Error ensuring user profile exists:", upsertError);
      return new Response(
        JSON.stringify({
          error: "Failed to create user profile: " + upsertError.message,
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Call the database function to get partner status
    const { data, error } = await supabase.rpc("get_partner_status");

    if (error) {
      console.error("Error checking link status:", error);
      return new Response(
        JSON.stringify({
          error: error.message || "Failed to check link status",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    if (!data || data.length === 0) {
      return new Response(
        JSON.stringify({
          is_linked: false,
          partner: null,
          premium_sharing: null,
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const status = data[0];

    return new Response(
      JSON.stringify({
        is_linked: status.is_linked,
        partner: status.is_linked
          ? {
              display_name: status.partner_display_name,
              is_premium: status.partner_is_premium,
            }
          : null,
        linked_at: status.linked_at,
        premium_sharing: {
          sharing_to_partner: status.premium_shared_to_partner,
          receiving_from_partner: status.premium_received_from_partner,
        },
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    console.error("Unexpected error:", err);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
