import { createClient } from "jsr:@supabase/supabase-js@2";

export const cors = {
  "Access-Control-Allow-Origin": Deno.env.get("SITE_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Service role client: bypasses RLS. Only ever used inside edge functions.
export const admin = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

// The signed-in user making the request, or null. Checked with Supabase Auth itself, so it works with both the
// legacy JWT secret and the newer signing keys (the gateway's verify_jwt is off for these functions, see config.toml).
export async function caller(req: Request) {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token || token.startsWith("sb_")) return null;   // an API key, not a user's sign in
  const { data, error } = await admin().auth.getUser(token);
  return error || !data.user ? null : { user: data.user };
}

// "RR_TERMS: Accept the hostel policy..." -> the readable part, for messages shown to students
export const readable = (msg: string) => msg.replace(/^RR_[A-Z_]+:\s*/, "");

export const PAYSTACK = "https://api.paystack.co";
export const paystackKey = () => Deno.env.get("PAYSTACK_SECRET_KEY") ?? "";
// Until the Paystack secret is stored in Supabase, say so instead of failing with a bare 500
export const notConfigured = () => (paystackKey() ? null : json({ error: "Online payment is not set up yet. Try again later." }, 503));
