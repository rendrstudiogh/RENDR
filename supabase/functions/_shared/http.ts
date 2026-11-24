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

// The signed-in user making the request, or null
export async function caller(req: Request) {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return null;
  const c = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data, error } = await c.auth.getUser();
  return error || !data.user ? null : { user: data.user, client: c };
}

// "RR_TERMS: Accept the hostel policy..." -> the readable part, for messages shown to students
export const readable = (msg: string) => msg.replace(/^RR_[A-Z_]+:\s*/, "");

export const PAYSTACK = "https://api.paystack.co";
export const paystackKey = () => Deno.env.get("PAYSTACK_SECRET_KEY")!;
