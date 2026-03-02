// Edge Function: Sync Premium Status
// POST /functions/v1/sync-premium
// Auth: Required (Bearer token)
// Body: {
//   "revenuecat_app_user_id": "user123",
//   "is_premium": true,
//   "premium_expires_at": "2026-04-01T00:00:00Z"
// }
//
// Called when a user's premium status changes (via RevenueCat webhook or
// client-side check). Syncs premium to the linked partner if applicable.
//
// This endpoint can also be called by a RevenueCat webhook (server-to-server)
// using the service role key for authentication.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createServiceClient } from "../_shared/supabase-client.ts";

interface SyncPremiumRequest {
  revenuecat_app_user_id?: string;
  is_premium: boolean;
  premium_expires_at?: string;
}

// Webhook payload from RevenueCat
interface RevenueCatWebhookPayload {
  event: {
    type: string;
    app_user_id: string;
    expiration_at_ms?: number;
    product_id?: string;
  };
}

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
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

    const body = await req.json();

    // Detect if this is a RevenueCat webhook call
    const isWebhook = body.event?.type && body.event?.app_user_id;

    if (isWebhook) {
      return await handleRevenueCatWebhook(body as RevenueCatWebhookPayload);
    }

    return await handleClientSync(authHeader, body as SyncPremiumRequest);
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

// Handle direct client sync (user reports their own premium status)
async function handleClientSync(authHeader: string, body: SyncPremiumRequest) {
  const supabase = createUserClient(authHeader);

  // Get the current user
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    return new Response(
      JSON.stringify({ error: "Invalid authentication" }),
      {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Use service client for admin operations
  const serviceClient = createServiceClient();

  // Upsert the user's profile + premium status (creates profile if it doesn't exist)
  const { error: updateError } = await serviceClient
    .from("user_profiles")
    .upsert({
      id: user.id,
      email: user.email ?? null,
      display_name: user.email ? user.email.split("@")[0] : null,
      is_premium: body.is_premium,
      premium_source: body.is_premium ? "direct_purchase" : null,
      premium_expires_at: body.premium_expires_at || null,
    }, { onConflict: "id", ignoreDuplicates: false });

  if (updateError) {
    console.error("Error updating premium status:", updateError);
    return new Response(
      JSON.stringify({ error: "Failed to update premium status" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Sync premium to linked partner
  const syncResult = await syncPremiumToPartner(serviceClient, user.id, body.is_premium, body.premium_expires_at);

  return new Response(
    JSON.stringify({
      success: true,
      premium_synced_to_partner: syncResult.synced,
      message: syncResult.message,
    }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
}

// Handle RevenueCat webhook events
async function handleRevenueCatWebhook(payload: RevenueCatWebhookPayload) {
  const serviceClient = createServiceClient();
  const event = payload.event;

  console.log(`Processing RevenueCat webhook: ${event.type} for user ${event.app_user_id}`);

  // Determine premium status from event type
  const premiumEvents = [
    "INITIAL_PURCHASE",
    "RENEWAL",
    "PRODUCT_CHANGE",
    "UNCANCELLATION",
  ];
  const nonPremiumEvents = [
    "CANCELLATION",
    "EXPIRATION",
    "BILLING_ISSUE",
  ];

  let isPremium: boolean;
  if (premiumEvents.includes(event.type)) {
    isPremium = true;
  } else if (nonPremiumEvents.includes(event.type)) {
    isPremium = false;
  } else {
    // Other event types we don't need to handle
    return new Response(
      JSON.stringify({ success: true, message: "Event type not relevant for premium sync" }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  const premiumExpiresAt = event.expiration_at_ms
    ? new Date(event.expiration_at_ms).toISOString()
    : null;

  // Find the user by RevenueCat app_user_id
  const { data: userProfile, error: lookupError } = await serviceClient
    .from("user_profiles")
    .select("id")
    .eq("revenuecat_app_user_id", event.app_user_id)
    .single();

  if (lookupError || !userProfile) {
    console.error("User not found for RevenueCat ID:", event.app_user_id);
    return new Response(
      JSON.stringify({ error: "User not found" }),
      {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Update user's premium status
  const { error: updateError } = await serviceClient
    .from("user_profiles")
    .update({
      is_premium: isPremium,
      premium_source: isPremium ? "direct_purchase" : null,
      premium_expires_at: premiumExpiresAt,
    })
    .eq("id", userProfile.id);

  if (updateError) {
    console.error("Error updating premium status:", updateError);
    return new Response(
      JSON.stringify({ error: "Failed to update premium status" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }

  // Sync premium to linked partner
  const syncResult = await syncPremiumToPartner(
    serviceClient,
    userProfile.id,
    isPremium,
    premiumExpiresAt
  );

  return new Response(
    JSON.stringify({
      success: true,
      event_type: event.type,
      premium_synced_to_partner: syncResult.synced,
      message: syncResult.message,
    }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
}

// Sync premium status to the linked partner
async function syncPremiumToPartner(
  serviceClient: ReturnType<typeof createServiceClient>,
  userId: string,
  isPremium: boolean,
  premiumExpiresAt?: string | null
): Promise<{ synced: boolean; message: string }> {
  // Find active linked account
  const { data: links, error: linkError } = await serviceClient
    .from("linked_accounts")
    .select("*")
    .or(`user_id_1.eq.${userId},user_id_2.eq.${userId}`)
    .eq("is_active", true)
    .limit(1);

  if (linkError || !links || links.length === 0) {
    return { synced: false, message: "No linked partner found" };
  }

  const link = links[0];
  const partnerId = link.user_id_1 === userId ? link.user_id_2 : link.user_id_1;

  if (isPremium) {
    // Share premium to partner
    const { error: shareError } = await serviceClient
      .from("user_profiles")
      .update({
        is_premium: true,
        premium_source: "partner_shared",
        premium_expires_at: premiumExpiresAt || null,
      })
      .eq("id", partnerId)
      .neq("premium_source", "direct_purchase"); // Don't overwrite direct purchase

    if (shareError) {
      console.error("Error sharing premium to partner:", shareError);
      return { synced: false, message: "Failed to sync premium to partner" };
    }

    // Log the sharing
    await serviceClient.from("premium_sharing_log").insert({
      linked_account_id: link.id,
      source_user_id: userId,
      target_user_id: partnerId,
      action: "premium_shared",
      premium_expires_at: premiumExpiresAt || null,
    });

    return { synced: true, message: "Premium shared with partner" };
  } else {
    // Revoke shared premium from partner (only if they got it from sharing)
    const { error: revokeError } = await serviceClient
      .from("user_profiles")
      .update({
        is_premium: false,
        premium_source: null,
        premium_expires_at: null,
      })
      .eq("id", partnerId)
      .eq("premium_source", "partner_shared");

    if (revokeError) {
      console.error("Error revoking partner premium:", revokeError);
      return { synced: false, message: "Failed to revoke partner premium" };
    }

    // Log the revocation
    await serviceClient.from("premium_sharing_log").insert({
      linked_account_id: link.id,
      source_user_id: userId,
      target_user_id: partnerId,
      action: "premium_revoked",
    });

    // Check if the partner has their own direct premium
    // (in case both purchased, the other partner keeps theirs)
    return { synced: true, message: "Partner premium status updated" };
  }
}
