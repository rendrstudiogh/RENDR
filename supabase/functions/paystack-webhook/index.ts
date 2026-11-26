// Two ways in, one outcome:
//  1. Paystack's webhook (signed with HMAC SHA512 of the raw body using the secret key)
//  2. The site, right after the popup closes, posting {reference} so the student is not kept waiting
// Either way the transaction is re-checked with Paystack's verify API before anything is recorded,
// and confirm_payment is idempotent, so duplicates are harmless.
import { admin, cors, json, notConfigured, PAYSTACK, paystackKey } from "../_shared/http.ts";

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function settle(reference: string) {
  const v = await fetch(`${PAYSTACK}/transaction/verify/${encodeURIComponent(reference)}`, { headers: { Authorization: `Bearer ${paystackKey()}` } })
    .then((r) => r.json()).catch(() => null);
  if (!v?.status || v.data?.status !== "success" || v.data?.currency !== "GHS") return { state: "not_paid" };
  const { data, error } = await admin().rpc("confirm_payment", {
    p_reference: reference, p_amount_pesewas: v.data.amount, p_channel: v.data.channel, p_paid_at: v.data.paid_at, p_raw: v.data,
  });
  if (error) return { state: error.message.startsWith("RR_UNKNOWN_REFERENCE") ? "unknown" : "error", error: error.message };
  return { state: data === "needs_refund" ? "needs_refund" : "paid", invoice: data };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const off = notConfigured(); if (off) return off;
  const raw = await req.text();
  const sig = req.headers.get("x-paystack-signature");

  if (sig) {
    const key = await crypto.subtle.importKey("raw", enc.encode(paystackKey()), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
    if (!sameText(hex(await crypto.subtle.sign("HMAC", key, enc.encode(raw))), sig)) return new Response("bad signature", { status: 401 });
    const evt = JSON.parse(raw);
    if (evt.event !== "charge.success") return new Response("ignored");
    const out = await settle(evt.data.reference);
    if (out.state === "error") { console.error(out.error); return new Response("retry later", { status: 500 }); } // Paystack retries
    return new Response("ok");
  }

  const { reference } = JSON.parse(raw || "{}");
  if (typeof reference !== "string" || !/^RR[A-Z0-9]{18}$/.test(reference)) return json({ error: "Unknown payment." }, 400);
  const out = await settle(reference);
  return json(out, out.state === "error" ? 500 : 200);
});
