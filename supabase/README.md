# RoomRight backend (Supabase + Paystack)

The live site in `roomright/` still runs as a self-contained demo (data stays in the browser).
This folder is the real backend it will be wired to. It is tested: the migrations, seed and a
suite of functional, security and two-session race tests run clean on PostgreSQL 16.

## What is here

| Path | What it does |
| --- | --- |
| `migrations/..._schema.sql` | Tables: hostels, room types (price + inventory), rooms, beds, admission records, profiles, applications, payments, invoices, upgrades, problem reports, notifications, staff access requests, audit log |
| `migrations/..._logic.sql` | Every rule: sign up checks (TAGL ID or student ID, date of birth, 18+, admission records), apply, reserve for 15 days, waiting list notices, payment confirmation, upgrades, admin room change, check in, problem reports |
| `migrations/..._security.sql` | Row level security, function permissions, Realtime bed board, room photo bucket |
| `migrations/..._cron.sql` | Releases unpaid reservations and sends waiting list notices every 5 minutes |
| `seed.sql` | Maria (rooms 1 to 19, 48 beds) and Camille (rooms 20 to 42, 39 beds) with 2026/27 prices |
| `functions/paystack-init` | Starts a Paystack payment. The amount comes from the database, never the browser |
| `functions/paystack-webhook` | Paystack webhook (HMAC SHA512 checked) and the post-popup check. Re-verifies every payment with Paystack before recording it |
| `functions/admissions-sync` | Reads the Admission Department's Excel file on OneDrive or SharePoint with Microsoft Graph and updates the records |

## How double booking is prevented

1. Every function that gives someone a bed first locks that bed's room row, so everything in one room happens one at a time. This also enforces the gender-by-room rule.
2. A unique index (`one_live_booking_per_bed`) makes it impossible for two live bookings to share a bed, even if a future code change has a bug.
3. Students cannot write to any table directly. They can only call the functions above.
4. A payment is only recorded after Paystack's own verify API says it succeeded, in Ghana cedis, for the exact amount the database expects. If a reservation ran out and someone else took the bed before a late payment arrived, the payment is marked `needs_refund` and the housing office is told, instead of the bed being given twice.

## Set up (about 30 minutes)

1. **Create the project.** In Supabase, create a project in the region closest to Ghana (Europe West is usually closest).
   **Easiest way:** open SQL Editor, New query, paste the whole of `supabase/setup.sql`, press Run. It builds everything in one transaction, so a failure changes nothing.
   Or, with the Supabase CLI, from this repository run:
   ```
   supabase link --project-ref <your-project-ref>
   supabase db push
   psql "<your database connection string>" -f supabase/seed.sql
   ```
   If `db push` complains about `pg_cron`, enable pg_cron under Database, Extensions, then run it again.
2. **Turn on email confirmation** (Authentication, Sign in providers, Email: Confirm email) and set the Site URL to the GitHub Pages address.
3. **Make yourself the first administrator.** Sign up on the site, then in the SQL editor:
   ```sql
   insert into public.profiles (id, role, full_name, email)
   select id, 'admin', 'Housing office', email from auth.users where email = 'your-email@example.com'
   on conflict (id) do update set role = 'admin';
   ```
   After that, invite managers from Authentication, Users, Invite, and give them their hostel from the admin page (`set_staff`).
4. **Paystack.** In the Paystack dashboard (test mode first), copy the test secret key. Store it as a Supabase secret, never in the site:
   ```
   supabase secrets set PAYSTACK_SECRET_KEY=<test secret key> SITE_URL=<site address> SITE_ORIGIN=<site origin>
   supabase functions deploy paystack-init paystack-webhook
   ```
   Set the webhook URL in Paystack to `https://<project-ref>.supabase.co/functions/v1/paystack-webhook`.
   The site only ever needs the Paystack **public** key.
5. **Admission records.** Until IT approves the live link, the administrator uploads the spreadsheet on the admin page. For the live link, the university IT team registers an app in Microsoft Entra with the Graph application permission `Sites.Selected` (or `Files.Read.All`), grants admin consent, and gives you the tenant ID, client ID, client secret, and the drive and item IDs of the workbook. Then:
   ```
   supabase secrets set MS_TENANT_ID=... MS_CLIENT_ID=... MS_CLIENT_SECRET=... ADMISSIONS_DRIVE_ID=... ADMISSIONS_ITEM_ID=... SYNC_SECRET=<long random text>
   supabase functions deploy admissions-sync
   ```
   Schedule it hourly with pg_cron and pg_net, keeping the secret in Supabase Vault rather than in the SQL.
6. **Keep it awake.** Free Supabase projects pause after a week without activity. Upgrade before launch, or add a scheduled ping.

## Keys: what goes where

| Key | Where it lives |
| --- | --- |
| Supabase project URL and anon (publishable) key | The website. Safe to be public because row level security protects the data |
| Supabase service role key | Edge functions only (Supabase provides it automatically). Never in the website or the repository |
| Paystack public key | The website |
| Paystack secret key, Microsoft client secret, sync secret | Supabase secrets only |

## Known limits to decide on

- **Waiting list fairness.** Everyone waiting for a room type is told at the same time and the first to reserve wins. If the university wants strict queue order, the next step is holding the freed bed for the first person in the queue for a few hours.
- **Records removed from the admissions sheet** are not deleted here. Withdrawn admissions need a status column in the sheet.
- **Refunds** are flagged (`needs_refund`) but paid out by the finance office in Paystack, not automatically.
