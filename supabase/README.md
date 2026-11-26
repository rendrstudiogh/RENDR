# RoomRight backend (Supabase + Paystack)

The site in `roomright/` now runs on this backend for students (stage 1, see below). Staff pages and
payment still use the demo until their stages land. This folder is the backend. It is tested: the migrations, seed and a
suite of functional, security and two-session race tests run clean on PostgreSQL 16.

## Live project

| | |
| --- | --- |
| Project URL | `https://ewvvpliiescxoesijyap.supabase.co` |
| Publishable key (public, goes in the website) | `sb_publishable_GfoezSarhuYqoanY2-ShZg_U-w8COeS` |

`setup.sql` has been run on this project. Secret keys never go in this repository or the website.

## Stage 1: what is live

| Part | Live | Notes |
| --- | --- | --- |
| Student sign up | Yes | Supabase Auth. The database trigger checks the ID, age, gender and admission records and its `RR_` code is shown on the right field |
| Email confirmation | Yes | A link, not a code. Sign in is by email and password |
| Live bed board | Yes | Read from `bed_state`, updated over Realtime, re-read every 30 seconds if Realtime drops |
| Apply, choose a bed, reserve | Yes | `submit_application` and `reserve_bed`. The database refuses a bed someone else just took, or a room of the other gender |
| Release a bed, waiting list, add student ID | Yes | `release_my_reservation`, `join_waitlist`, `leave_waitlist`, `add_student_id` |
| Notifications | Yes | Read from `notifications`, marked read with `mark_notifications_read` |
| Payment, invoices, booking token | No | Stage 2 (Paystack). A reserved bed shows its deadline and nothing pretends to take money |
| Problem reports, upgrades | No | Show "not connected yet" |
| Manager and administrator pages | No | The staff page links to the demo |

**Demo mode.** Add `?demo=1` to the address for the demo with sample students. If the live system cannot be reached,
the site opens the demo by itself with a red banner saying nothing there is a real booking.

### Before real students use it

1. **Run `migrations/20261126000100_live_signup.sql`** in the SQL Editor (paste, Run). It makes gender and name required
   in the sign up trigger and stops the browser calling `check_eligibility` directly. `setup.sql` already includes it for new projects.
2. **Authentication, URL Configuration.** Set the Site URL to the GitHub Pages address of `roomright/`, and add the same
   address to Redirect URLs, or the confirmation link will send students to the wrong place.
3. **Custom SMTP (Authentication, Emails, SMTP settings).** Supabase's built-in email is meant for testing: it is heavily
   rate limited and may only deliver to your own team's addresses. Check the limits shown on that page. Without your own
   SMTP (for example Resend, Brevo or Postmark), students will not get their confirmation links.
4. **Upload the admission records first.** While the `admissions` table is empty every account is marked `unchecked`
   and accepted, so anyone can sign up with an invented TAGL ID and reserve a bed.
5. **Do not open applications before stage 2.** A student can reserve but not pay yet, so every reservation would expire
   after 15 days. Keep `applications_open` set to `false` in `settings` until payment is live.

## What is here

| Path | What it does |
| --- | --- |
| `migrations/..._schema.sql` | Tables: hostels, room types (price + inventory), rooms, beds, admission records, profiles, applications, payments, invoices, upgrades, problem reports, notifications, staff access requests, audit log |
| `migrations/..._logic.sql` | Every rule: sign up checks (TAGL ID or student ID, date of birth, 18+, admission records), apply, reserve for 15 days, waiting list notices, payment confirmation, upgrades, admin room change, check in, problem reports |
| `migrations/..._security.sql` | Row level security, function permissions, Realtime bed board, room photo bucket |
| `migrations/20261126..._live_signup.sql` | Stage 1 hardening of the sign up trigger |
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

- **Sign in by TAGL ID or student ID** is demo only. Supabase signs in by email. Looking up the email from an ID in the
  browser would let anyone find a student's email from their ID, so doing it safely needs a small edge function.
- **Unconfirmed accounts hold their ID.** Someone who signs up with another student's TAGL ID and never confirms blocks
  that ID. The housing office can delete the unconfirmed user in Authentication, Users. An automatic clean up is a later step.

- **Waiting list fairness.** Everyone waiting for a room type is told at the same time and the first to reserve wins. If the university wants strict queue order, the next step is holding the freed bed for the first person in the queue for a few hours.
- **Records removed from the admissions sheet** are not deleted here. Withdrawn admissions need a status column in the sheet.
- **Refunds** are flagged (`needs_refund`) but paid out by the finance office in Paystack, not automatically.
