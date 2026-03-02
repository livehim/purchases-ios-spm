// Edge Function: Redeem Partner Code
// POST /functions/v1/redeem-partner-code
// Auth: Required (Bearer token)
// Body: { "code": "ABC12345" }
//
// Redeems a partner code to link two accounts together.
// If either partner has premium, it's automatically shared.

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

    // Parse the code from body
    let code: string;
    try {
      const body = await req.json();
      code = body.code;
    } catch {
      return new Response(
        JSON.stringify({ error: "Invalid request body. Expected: { \"code\": \"ABC12345\" }" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    if (!code || typeof code !== "string" || code.trim().length === 0) {
      return new Response(
        JSON.stringify({ error: "Partner code is required" }),
        {
          status: 400,
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
    await serviceClient.from("user_profiles").upsert(
      {
        id: user.id,
        email: user.email ?? null,
        display_name: user.email ? user.email.split("@")[0] : null,
      },
      { onConflict: "id", ignoreDuplicates: true }
    );

    // Call the database function to redeem the code
    const { data, error } = await supabase.rpc("redeem_partner_code", {
      p_code: code.trim().toUpperCase(),
    });

    if (error) {
      console.error("Error redeeming partner code:", error);
      return new Response(
        JSON.stringify({
          error: error.message || "Failed to redeem partner code",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    if (!data || data.length === 0) {
      return new Response(
        JSON.stringify({ error: "Failed to process partner code" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const result = data[0];

    if (!result.success) {
      return new Response(
        JSON.stringify({
          success: false,
          error: result.message,
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: result.message,
        partner_name: result.partner_display_name,
        linked_account_id: result.linked_account_id,
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
