// Edge Function: Generate Partner Code
// POST /functions/v1/generate-partner-code
// Auth: Required (Bearer token)
// Body: { "expiry_hours": 72 } (optional, defaults to 72)
//
// Generates a unique 8-character partner code for the authenticated user.
// The code can be shared with their partner to link accounts.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient } from "../_shared/supabase-client.ts";

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

    // Parse optional expiry hours from body
    let expiryHours = 72;
    try {
      const body = await req.json();
      if (body.expiry_hours && typeof body.expiry_hours === "number") {
        expiryHours = Math.min(Math.max(body.expiry_hours, 1), 168); // 1-168 hours (1 week max)
      }
    } catch {
      // No body or invalid JSON, use default
    }

    // Create Supabase client with user's auth
    const supabase = createUserClient(authHeader);

    // Call the database function to create the partner code
    const { data, error } = await supabase.rpc("create_partner_code", {
      p_expiry_hours: expiryHours,
    });

    if (error) {
      console.error("Error creating partner code:", error);
      return new Response(
        JSON.stringify({
          error: error.message || "Failed to generate partner code",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    if (!data || data.length === 0) {
      return new Response(
        JSON.stringify({ error: "Failed to generate partner code" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        code: data[0].code,
        expires_at: data[0].expires_at,
        message: "Share this code with your partner to link your accounts",
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
