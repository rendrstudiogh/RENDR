// Starts a Paystack payment for the signed-in student's reserved bed (or approved upgrade).
// The amount comes from the database, never from the browser.
import { admin, caller, cors, json, PAYSTACK, paystackKey, readable } from "../_shared/http.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const who = await caller(req);
  if (!who) return json({ error: "Sign in again to pay." }, 401);
  const { purpose = "booking" } = await req.json().catch(() => ({}));
  if (purpose !== "booking" && purpose !== "upgrade") return json({ error: "Unknown payment." }, 400);

  const db = admin();
  const reference = "RR" + crypto.randomUUID().replace(/-/g, "").slice(0, 18).toUpperCase();
  const { data: p, error } = await db.rpc("start_payment", { p_student: who.user.id, p_reference: reference, p_purpose: purpose });
  if (error) return json({ error: readable(error.message) }, 400);

  const r = await fetch(`${PAYSTACK}/transaction/initialize`, {
    method: "POST",
    headers: { Authorization: `Bearer ${paystackKey()}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      email: p.email, amount: p.amount_pesewas, currency: "GHS", reference,
      channels: ["mobile_money", "card"],
      metadata: { application: p.application, bed: p.bed, purpose },
      callback_url: Deno.env.get("SITE_URL"),
    }),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok || !body.status) {
    await db.from("payments").update({ status: "failed" }).eq("reference", reference);
    return json({ error: "Paystack could not start the payment. Try again in a minute." }, 502);
  }
  await db.rpc("set_access_code", { p_reference: reference, p_code: body.data.access_code });
  // The browser opens the Paystack popup with this access code (PaystackPop resumeTransaction)
  return json({ reference, access_code: body.data.access_code, amount_pesewas: p.amount_pesewas });
});
