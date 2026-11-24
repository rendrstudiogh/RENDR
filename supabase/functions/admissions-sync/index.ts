// Reads the Admission Department's Excel workbook on OneDrive or SharePoint with Microsoft Graph
// (app-only access, approved by the university IT team) and upserts it into public.admissions.
// Runs hourly from pg_cron (header x-sync-secret) or when an administrator presses "Sync now".
import { admin, caller, cors, json } from "../_shared/http.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const COLS: Record<string, string[]> = {
  id: ["taglid", "studentid", "id", "idnumber", "admissionid", "admissionnumber", "tagl"],
  full_name: ["name", "fullname", "studentname", "fullnames"],
  dob: ["dob", "dateofbirth", "birthdate", "birthday"],
  programme: ["programme", "program", "programmeofstudy", "course", "degree"],
  year_of_study: ["year", "yearofstudy", "currentyear", "currentyearofstudy", "level"],
  gender: ["gender", "sex"], email: ["email", "emailaddress"], phone: ["phone", "phonenumber", "contact", "mobile", "contactnumber"],
};
const pad = (n: number) => String(n).padStart(2, "0");
function isoDate(v: unknown): string {
  if (typeof v === "number" && v > 1000) { const d = new Date(Math.round((v - 25569) * 864e5)); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`; }
  const s = String(v ?? "").trim(); let m;
  if ((m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/))) return `${m[1]}-${pad(+m[2])}-${pad(+m[3])}`;
  if ((m = s.match(/^(\d{1,2})[\/.-](\d{1,2})[\/.-](\d{4})$/))) return `${m[3]}-${pad(+m[2])}-${pad(+m[1])}`; // day first, as written in Ghana
  return "";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const bySchedule = env("SYNC_SECRET") !== "" && req.headers.get("x-sync-secret") === env("SYNC_SECRET");
  if (!bySchedule) {
    const who = await caller(req);
    const { data: ok } = who ? await who.client.rpc("is_admin") : { data: false };
    if (!ok) return json({ error: "Administrators only." }, 403);
  }

  const tok = await fetch(`https://login.microsoftonline.com/${env("MS_TENANT_ID")}/oauth2/v2.0/token`, {
    method: "POST",
    body: new URLSearchParams({ client_id: env("MS_CLIENT_ID"), client_secret: env("MS_CLIENT_SECRET"), scope: "https://graph.microsoft.com/.default", grant_type: "client_credentials" }),
  }).then((r) => r.json());
  if (!tok.access_token) return json({ error: "Microsoft sign in failed. Check the app registration." }, 502);

  const base = `https://graph.microsoft.com/v1.0/drives/${env("ADMISSIONS_DRIVE_ID")}/items/${env("ADMISSIONS_ITEM_ID")}/workbook/worksheets`;
  const sheet = env("ADMISSIONS_SHEET");
  const url = sheet ? `${base}/${encodeURIComponent(sheet)}/usedRange(valuesOnly=true)` : `${base}?$top=1`;
  const h = { Authorization: `Bearer ${tok.access_token}` };
  let res = await fetch(url, { headers: h }).then((r) => r.json());
  if (!sheet && res.value?.[0]) res = await fetch(`${base}/${encodeURIComponent(res.value[0].name)}/usedRange(valuesOnly=true)`, { headers: h }).then((r) => r.json());
  const values: unknown[][] = res.values;
  if (!Array.isArray(values) || values.length < 2) return json({ error: "The workbook could not be read, or it is empty." }, 502);

  const head = values[0].map((x) => String(x).toLowerCase().replace(/[^a-z]/g, ""));
  const col: Record<string, number> = {};
  for (const k in COLS) col[k] = head.findIndex((x) => COLS[k].includes(x));
  if (col.id < 0 || col.full_name < 0 || col.dob < 0) return json({ error: "The sheet needs ID, full name and date of birth columns.", found: values[0] }, 422);

  const rows = values.slice(1).map((r) => {
    const o: Record<string, string> = {};
    for (const k in COLS) if (col[k] > -1) o[k] = k === "dob" ? isoDate(r[col[k]]) : String(r[col[k]] ?? "").trim();
    return o;
  }).filter((o) => o.id || o.full_name);

  const { data, error } = await admin().rpc("import_admissions", { p_rows: rows, p_source: "SharePoint sync" });
  if (error) return json({ error: error.message }, 500);
  return json(data);
});
