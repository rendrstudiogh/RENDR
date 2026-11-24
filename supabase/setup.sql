-- RoomRight for Lancaster University Ghana: complete backend setup in one paste.
-- Supabase dashboard > SQL Editor > New query > paste this whole file > Run.
-- It runs as one transaction: if anything fails, nothing is changed and you can run it again.
-- Generated from supabase/migrations/*.sql and supabase/seed.sql. Edit those, not this file.
begin;

-- ===== migrations/20261124000100_schema.sql =====
-- RoomRight for Lancaster University Ghana: core schema
-- Maria and Camille on-campus hostels, 2026/27 academic year.

create type public.user_role    as enum ('student', 'manager', 'admin');
create type public.student_kind as enum ('new', 'returning');
create type public.sex          as enum ('F', 'M');
create type public.app_status   as enum ('applied', 'reserved', 'paid', 'checked_in', 'cancelled');
create type public.pay_status   as enum ('pending', 'success', 'failed', 'needs_refund');

-- Settings the housing office can change without a code release
create table public.settings (
  key   text primary key,
  value jsonb not null
);
insert into public.settings values
  ('academic_year',  '"2026/27"'),
  ('reserve_days',   '15'),
  ('min_age',        '18'),
  ('applications_open', 'true');

-- ---------- Places, rooms and beds ----------
create table public.hostels (
  id          text primary key,
  name        text not null,
  description text not null default 'On the Lancaster University Ghana campus',
  lat         double precision,
  lng         double precision
);

create table public.lecture_buildings (
  id   bigint generated always as identity primary key,
  name text not null,
  lat  double precision not null,
  lng  double precision not null
);

create table public.room_types (
  id        text primary key,
  name      text not null,
  beds      int  not null check (beds between 1 and 4),
  price_ghs numeric(10,2) not null check (price_ghs > 0),
  premium   boolean not null default false,
  -- [{"item": "Single bed", "qty": 2}, ...]
  inventory jsonb not null default '[]'
);

create table public.rooms (
  room_no   int  primary key,
  hostel_id text not null references public.hostels,
  floor     int  not null,
  type_id   text not null references public.room_types
);

create table public.beds (
  id      text primary key,               -- "14-3" = room 14, bed index 3
  room_no int  not null references public.rooms,
  idx     int  not null,
  unique (room_no, idx)
);

create table public.room_photos (
  id           bigint generated always as identity primary key,
  type_id      text not null references public.room_types on delete cascade,
  storage_path text not null,              -- object in the public "room-photos" bucket
  sort         int  not null default 0
);

-- ---------- People ----------
-- Records from the Admission Department's spreadsheet. Admin only.
create table public.admissions (
  id          text primary key,            -- TAGL ID (new) or student ID (returning), upper case
  kind        public.student_kind not null,
  full_name   text not null,
  dob         date not null,
  programme   text,
  year_of_study text,
  gender      public.sex,
  email       text,
  phone       text,
  source      text,
  updated_at  timestamptz not null default now()
);

create table public.profiles (
  id            uuid primary key references auth.users on delete cascade,
  role          public.user_role not null default 'student',
  kind          public.student_kind,
  full_name     text not null,
  gender        public.sex,
  email         text,
  phone         text,
  tagl_id       text unique,
  student_id    text unique check (student_id ~ '^\d{8}$'),
  dob           date,
  programme     text,
  year_of_study text,
  hostel_id     text references public.hostels,       -- managers only
  adm_check     text not null default 'unchecked',    -- ok | unchecked | mismatch
  created_at    timestamptz not null default now(),
  check (role <> 'student' or tagl_id is not null or student_id is not null),
  check (role <> 'manager' or hostel_id is not null)
);

-- ---------- Applications and the double booking guard ----------
create sequence public.app_seq;
create sequence public.inv_seq;

create table public.applications (
  id               text primary key default 'LUG2026' || lpad(nextval('public.app_seq')::text, 3, '0'),
  student          uuid not null references public.profiles on delete restrict,
  academic_year    text not null default '2026/27',
  first_choice     text not null references public.room_types,
  second_choice    text not null references public.room_types,
  waitlist_type    text references public.room_types,
  wl_notified_at   timestamptz,
  type_id          text references public.room_types,
  bed_id           text references public.beds,
  status           public.app_status not null default 'applied',
  reserved_until   timestamptz,
  expired_at       timestamptz,
  guardian_name    text not null,
  guardian_phone   text not null,
  guardian_email   text not null,
  kin_name         text not null,
  kin_phone        text not null,
  kin_relationship text not null,
  terms_accepted_at timestamptz,
  token            text unique,
  created_at       timestamptz not null default now(),
  unique (student, academic_year),                               -- one application per student per year
  check (first_choice <> second_choice),
  check (status in ('applied', 'cancelled') or bed_id is not null),
  check (status <> 'reserved' or reserved_until is not null)
);

-- THE guard: a bed can belong to one live application only. Even if application code
-- has a bug, Postgres refuses a second reservation of the same bed.
create unique index one_live_booking_per_bed on public.applications (bed_id)
  where status in ('reserved', 'paid', 'checked_in');
create index applications_wait on public.applications (waitlist_type) where status = 'applied';
create index applications_exp  on public.applications (reserved_until) where status = 'reserved';

create table public.payments (
  id             uuid primary key default gen_random_uuid(),
  application_id text not null references public.applications,
  purpose        text not null default 'booking' check (purpose in ('booking', 'upgrade')),
  bed_id         text not null references public.beds,     -- the bed this payment is for
  amount_ghs     numeric(10,2) not null check (amount_ghs > 0),
  reference      text not null unique,                     -- Paystack transaction reference
  access_code    text,
  status         public.pay_status not null default 'pending',
  channel        text,
  paid_at        timestamptz,
  raw            jsonb,
  created_at     timestamptz not null default now()
);

create table public.invoices (
  no             text primary key default 'INV-2026-' || lpad(nextval('public.inv_seq')::text, 4, '0'),
  application_id text not null references public.applications,
  payment_id     uuid not null unique references public.payments,
  label          text not null,
  amount_ghs     numeric(10,2) not null,
  created_at     timestamptz not null default now()
);

create table public.upgrades (
  id             bigint generated always as identity primary key,
  application_id text not null references public.applications,
  to_type        text not null references public.room_types,
  status         text not null default 'requested' check (status in ('requested', 'approved', 'declined', 'paid', 'expired')),
  bed_id         text references public.beds,
  reserved_until timestamptz,
  created_at     timestamptz not null default now()
);
create unique index one_held_upgrade_bed on public.upgrades (bed_id) where status = 'approved';

-- ---------- Problems, notifications, staff access, audit ----------
create table public.reports (
  id             bigint generated always as identity primary key,
  application_id text not null references public.applications,
  hostel_id      text not null references public.hostels,
  room_no        int  not null references public.rooms,
  category       text not null,
  details        text not null check (length(details) between 5 and 2000),
  status         text not null default 'open' check (status in ('open', 'in_progress', 'resolved')),
  created_at     timestamptz not null default now()
);

create table public.report_messages (
  id         bigint generated always as identity primary key,
  report_id  bigint not null references public.reports on delete cascade,
  author     uuid not null references public.profiles,
  body       text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create table public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles on delete cascade,
  title      text not null,
  body       text not null,
  read_at    timestamptz,
  emailed_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user on public.notifications (user_id, created_at desc);

create table public.access_requests (
  id         bigint generated always as identity primary key,
  hostel_id  text not null references public.hostels,
  full_name  text not null,
  contact    text not null,
  status     text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at timestamptz not null default now()
);

create table public.audit_log (
  id     bigint generated always as identity primary key,
  at     timestamptz not null default now(),
  actor  uuid,
  action text not null,
  detail jsonb
);

-- ===== migrations/20261124000200_logic.sql =====
-- RoomRight business rules. Every write a student or staff member makes goes through
-- one of these functions; tables have no direct write access (see the RLS migration).
--
-- Concurrency rule: any function that gives someone a bed first locks that bed's ROOM row
-- (select ... for update). That serialises everything happening in one room, so the
-- gender-by-room rule cannot be broken by two people booking at the same moment, and the
-- unique index one_live_booking_per_bed backs it up.

-- ---------- Helpers ----------
create function public.setting_text(k text) returns text
language sql stable set search_path = public as $$ select value #>> '{}' from settings where key = k $$;

create function public.age_years(d date) returns int
language sql stable as $$ select extract(year from age(current_date, d))::int $$;

create function public.my_profile() returns public.profiles
language sql stable security definer set search_path = public as $$ select * from profiles where id = auth.uid() $$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$ select coalesce((select role = 'admin' from profiles where id = auth.uid()), false) $$;

create function public.my_hostel() returns text
language sql stable security definer set search_path = public as $$ select hostel_id from profiles where id = auth.uid() and role = 'manager' $$;

create function public.audit(p_action text, p_detail jsonb) returns void
language sql security definer set search_path = public as $$ insert into audit_log (actor, action, detail) values (auth.uid(), p_action, p_detail) $$;

create function public.fail(code text, msg text) returns void
language plpgsql as $$ begin raise exception '%: %', code, msg using errcode = 'P0001'; end $$;

-- Who holds which bed right now: live bookings plus beds held for an approved upgrade
create view public.live_holds as
  select a.bed_id, p.gender, a.id as application_id
    from public.applications a join public.profiles p on p.id = a.student
   where a.status in ('reserved', 'paid', 'checked_in')
  union all
  select u.bed_id, p.gender, u.application_id
    from public.upgrades u join public.applications a on a.id = u.application_id join public.profiles p on p.id = a.student
   where u.status = 'approved';

-- Free for this gender: nobody holds the bed and nobody of the other gender is in the room
create function public.bed_free_for(p_bed text, p_gender public.sex) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from live_holds where bed_id = p_bed)
     and not exists (select 1 from live_holds h join beds b2 on b2.id = h.bed_id
                      where b2.room_no = (select room_no from beds where id = p_bed) and h.gender <> p_gender)
$$;

create function public.free_beds(p_type text, p_gender public.sex) returns setof text
language sql stable security definer set search_path = public as $$
  select b.id from beds b join rooms r on r.room_no = b.room_no
   where r.type_id = p_type and public.bed_free_for(b.id, p_gender)
   order by r.room_no, b.idx
$$;

-- Locks the room a bed is in and returns it
create function public.lock_room_of(p_bed text) returns public.rooms
language plpgsql security definer set search_path = public as $$
declare r rooms;
begin
  select r2.* into r from rooms r2 join beds b on b.room_no = r2.room_no where b.id = p_bed for update of r2;
  if r.room_no is null then perform fail('RR_NO_SUCH_BED', 'That bed does not exist.'); end if;
  return r;
end $$;

-- ---------- Live availability (public, no personal data) ----------
-- One row per bed, kept up to date by triggers and published over Realtime.
create table public.bed_state (
  bed_id        text primary key references public.beds,
  room_no       int  not null references public.rooms,
  taken         boolean not null default false,
  holder_gender public.sex,
  updated_at    timestamptz not null default now()
);

create function public.refresh_bed(p_bed text) returns void
language plpgsql security definer set search_path = public as $$
declare g sex; t boolean;
begin
  select gender into g from live_holds where bed_id = p_bed limit 1;
  t := found;
  update bed_state set taken = t, holder_gender = g, updated_at = now() where bed_id = p_bed;
end $$;

create function public.sync_bed_state() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.bed_id is not null then perform refresh_bed(old.bed_id); end if;
  if tg_op in ('INSERT', 'UPDATE') and new.bed_id is not null then perform refresh_bed(new.bed_id); end if;
  return null;
end $$;
create trigger applications_bed_state after insert or update or delete on public.applications for each row execute function public.sync_bed_state();
create trigger upgrades_bed_state     after insert or update or delete on public.upgrades     for each row execute function public.sync_bed_state();

-- ---------- Admission records and sign up ----------
-- 'ok', 'unchecked' (no records uploaded yet) or 'mismatch'. Name must share two words with the record.
create function public.admission_match(p_id text, p_name text, p_dob date) returns text
language plpgsql stable security definer set search_path = public as $$
declare r admissions; theirs text[]; common int;
begin
  if not exists (select 1 from admissions) then return 'unchecked'; end if;
  select * into r from admissions where id = upper(trim(p_id));
  if r.id is null or r.dob <> p_dob then return 'mismatch'; end if;
  theirs := array(select w from unnest(regexp_split_to_array(lower(regexp_replace(r.full_name, '[^a-zA-Z]+', ' ', 'g')), ' ')) w where w <> '');
  select count(*) into common from (
    select w from unnest(regexp_split_to_array(lower(regexp_replace(p_name, '[^a-zA-Z]+', ' ', 'g')), ' ')) w where w <> ''
    intersect select unnest(theirs)) x;
  return case when common >= least(2, coalesce(array_length(theirs, 1), 0)) then 'ok' else 'mismatch' end;
end $$;

-- Called by the sign up form before creating the account, so the student gets a clear message.
-- Deliberately vague on failure: it never says which of ID, name or date of birth was wrong.
create function public.check_eligibility(p_kind public.student_kind, p_id text, p_name text, p_dob date) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text := upper(trim(p_id)); m text;
begin
  if p_dob is null or age_years(p_dob) < setting_text('min_age')::int then return 'under_age'; end if;
  if (p_kind = 'new' and v !~ '^[A-Z][A-Z0-9-]{3,19}$') or (p_kind = 'returning' and v !~ '^\d{8}$') then return 'bad_id'; end if;
  m := admission_match(v, p_name, p_dob);
  if m = 'mismatch' then return 'mismatch'; end if;
  if exists (select 1 from profiles where tagl_id = v or student_id = v) then return 'taken'; end if;
  return m;
end $$;

-- Creates the profile when Supabase Auth creates a user. Students sign up with metadata
-- {kind, full_name, gender, tagl_id | student_id, dob, programme, year_of_study, phone}.
-- Anyone else (staff invited by email) gets no profile until an admin calls set_staff.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'); k student_kind; v text; d date; chk text;
begin
  if coalesce(m ->> 'kind', '') not in ('new', 'returning') then return new; end if;
  k := (m ->> 'kind')::student_kind;
  d := (m ->> 'dob')::date;
  v := upper(trim(case when k = 'new' then m ->> 'tagl_id' else m ->> 'student_id' end));
  chk := check_eligibility(k, v, m ->> 'full_name', d);
  if chk not in ('ok', 'unchecked') then perform fail('RR_SIGNUP_' || upper(chk), 'These details cannot be used to create an account.'); end if;
  if k = 'returning' and coalesce(m ->> 'stayed_last_year', 'yes') <> 'yes' then
    perform fail('RR_NOT_ELIGIBLE', 'Hostel places are for freshers and students who stayed in a hostel last year.');
  end if;
  insert into profiles (id, role, kind, full_name, gender, email, phone, tagl_id, student_id, dob, programme, year_of_study, adm_check)
  values (new.id, 'student', k, trim(m ->> 'full_name'), (m ->> 'gender')::sex, lower(new.email), m ->> 'phone',
          case when k = 'new' then v end, case when k = 'returning' then v end, d, m ->> 'programme', m ->> 'year_of_study', chk);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- Admin bulk upload of the Admission Department's records (also used by the admissions-sync function).
-- p_rows: [{id, full_name, dob (YYYY-MM-DD), programme, year_of_study, gender, email, phone}]
create function public.import_admissions(p_rows jsonb, p_source text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare added int := 0; updated int := 0; skipped jsonb := '[]'; r jsonb; v text; d date; ins boolean; i int := 0;
begin
  if not (is_admin() or auth.role() = 'service_role') then perform fail('RR_FORBIDDEN', 'Administrators only.'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    v := upper(trim(r ->> 'id'));
    begin d := (r ->> 'dob')::date; exception when others then d := null; end;
    if v is null or v !~ '^[A-Z0-9-]{4,20}$' or length(trim(coalesce(r ->> 'full_name', ''))) < 3 or d is null then
      skipped := skipped || jsonb_build_object('row', i, 'id', v); continue;
    end if;
    insert into admissions (id, kind, full_name, dob, programme, year_of_study, gender, email, phone, source, updated_at)
    values (v, case when v ~ '^\d+$' then 'returning' else 'new' end::student_kind, trim(r ->> 'full_name'), d,
            nullif(r ->> 'programme', ''), nullif(r ->> 'year_of_study', ''), nullif(upper(left(r ->> 'gender', 1)), '')::sex,
            nullif(lower(r ->> 'email'), ''), nullif(r ->> 'phone', ''), p_source, now())
    on conflict (id) do update set full_name = excluded.full_name, dob = excluded.dob, programme = excluded.programme,
      year_of_study = excluded.year_of_study, gender = excluded.gender, email = excluded.email, phone = excluded.phone,
      source = excluded.source, updated_at = now()
    returning (xmax = 0) into ins;
    if ins then added := added + 1; else updated := updated + 1; end if;
  end loop;
  -- Re-check every student account, so changed records show up as mismatches for the admin
  update profiles set adm_check = admission_match(coalesce(tagl_id, student_id), full_name, dob) where role = 'student';
  perform audit('admissions.import', jsonb_build_object('source', p_source, 'added', added, 'updated', updated, 'skipped', jsonb_array_length(skipped)));
  return jsonb_build_object('added', added, 'updated', updated, 'skipped', skipped);
end $$;

-- New students add their student ID once the university issues it
create function public.add_student_id(p_sid text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_sid !~ '^\d{8}$' then perform fail('RR_BAD_ID', 'A student ID has 8 digits.'); end if;
  update profiles set student_id = p_sid where id = auth.uid() and role = 'student' and student_id is null;
  if not found then perform fail('RR_NOT_ALLOWED', 'You already have a student ID on your account.'); end if;
exception when unique_violation then perform fail('RR_ID_TAKEN', 'Another account already uses this student ID.');
end $$;

-- Admin turns an invited user into a manager or administrator
create function public.set_staff(p_email text, p_role public.user_role, p_hostel text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if not is_admin() then perform fail('RR_FORBIDDEN', 'Administrators only.'); end if;
  if p_role = 'student' then perform fail('RR_BAD_ROLE', 'Use manager or admin.'); end if;
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if u is null then perform fail('RR_NO_USER', 'Invite this email from Supabase Authentication first.'); end if;
  insert into profiles (id, role, full_name, email, hostel_id) values (u, p_role, split_part(p_email, '@', 1), lower(p_email), case when p_role = 'manager' then p_hostel end)
  on conflict (id) do update set role = excluded.role, hostel_id = excluded.hostel_id;
  perform audit('staff.set', jsonb_build_object('email', p_email, 'role', p_role, 'hostel', p_hostel));
end $$;

-- ---------- Applications ----------
create function public.current_app(lock boolean default false) returns public.applications
language plpgsql security definer set search_path = public as $$
declare a applications;
begin
  if lock then select * into a from applications where student = auth.uid() and academic_year = setting_text('academic_year') for update;
  else select * into a from applications where student = auth.uid() and academic_year = setting_text('academic_year'); end if;
  if a.id is null then perform fail('RR_NO_APPLICATION', 'Submit your hostel application first.'); end if;
  return a;
end $$;

create function public.submit_application(p_first text, p_second text, p_guardian jsonb, p_kin jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare p profiles := my_profile(); v text;
  phone_ok text := '^(0\d{9}|\+\d{10,15})$';
begin
  if p.id is null or p.role <> 'student' then perform fail('RR_NOT_STUDENT', 'Only students can apply.'); end if;
  if setting_text('applications_open') <> 'true' then perform fail('RR_CLOSED', 'Applications are closed.'); end if;
  if p.dob is null or age_years(p.dob) < setting_text('min_age')::int then perform fail('RR_UNDER_AGE', 'You must be 18 or older to apply.'); end if;
  if p.adm_check = 'mismatch' then perform fail('RR_RECORDS', 'Your details do not match the admission records. Contact the Admissions office.'); end if;
  if length(trim(coalesce(p_guardian ->> 'name', ''))) < 3 or regexp_replace(coalesce(p_guardian ->> 'phone', ''), '\s', '', 'g') !~ phone_ok
     or coalesce(p_guardian ->> 'email', '') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then perform fail('RR_GUARDIAN', 'Enter your parent or guardian''s name, phone and email.'); end if;
  if length(trim(coalesce(p_kin ->> 'name', ''))) < 3 or regexp_replace(coalesce(p_kin ->> 'phone', ''), '\s', '', 'g') !~ phone_ok
     or length(trim(coalesce(p_kin ->> 'relationship', ''))) < 3 then perform fail('RR_KIN', 'Enter your next of kin''s name, phone and relationship.'); end if;
  insert into applications (student, academic_year, first_choice, second_choice, guardian_name, guardian_phone, guardian_email, kin_name, kin_phone, kin_relationship)
  values (p.id, setting_text('academic_year'), p_first, p_second, trim(p_guardian ->> 'name'), regexp_replace(p_guardian ->> 'phone', '\s', '', 'g'), lower(trim(p_guardian ->> 'email')),
          trim(p_kin ->> 'name'), regexp_replace(p_kin ->> 'phone', '\s', '', 'g'), trim(p_kin ->> 'relationship'))
  returning id into v;
  perform audit('application.submitted', jsonb_build_object('id', v));
  return v;
exception when unique_violation then perform fail('RR_ALREADY_APPLIED', 'You already have an application for this academic year.'); return null;
end $$;

create function public.reserve_bed(p_bed text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare a applications := current_app(true); p profiles := my_profile(); r rooms; v_until timestamptz;
begin
  if a.status <> 'applied' then perform fail('RR_HAS_BED', 'You already have a bed. Ask the housing office if you need to change it.'); end if;
  r := lock_room_of(p_bed);
  if r.type_id not in (a.first_choice, a.second_choice) then perform fail('RR_NOT_YOUR_CHOICE', 'Choose a bed in your first or second choice of room.'); end if;
  if not bed_free_for(p_bed, p.gender) then perform fail('RR_BED_TAKEN', 'Someone else just took this bed, or the room is for the other gender. Choose another bed.'); end if;
  v_until := now() + make_interval(days => setting_text('reserve_days')::int);
  update applications set status = 'reserved', bed_id = p_bed, type_id = r.type_id, reserved_until = v_until,
         waitlist_type = null, wl_notified_at = null, expired_at = null where id = a.id;
  perform audit('bed.reserved', jsonb_build_object('app', a.id, 'bed', p_bed, 'until', v_until));
  return v_until;
exception when unique_violation then perform fail('RR_BED_TAKEN', 'Someone else just took this bed. Choose another bed.'); return null;
end $$;

create function public.release_my_reservation() returns void
language plpgsql security definer set search_path = public as $$
declare a applications := current_app(true);
begin
  if a.status <> 'reserved' then perform fail('RR_NOT_RESERVED', 'You have no reservation to cancel.'); end if;
  update applications set status = 'applied', bed_id = null, type_id = null, reserved_until = null where id = a.id;
  perform audit('bed.released', jsonb_build_object('app', a.id, 'bed', a.bed_id));
  perform notify_waitlist();
end $$;

create function public.join_waitlist(p_type text) returns void
language plpgsql security definer set search_path = public as $$
declare a applications := current_app(true);
begin
  if a.status <> 'applied' then perform fail('RR_HAS_BED', 'You already have a bed.'); end if;
  if p_type not in (a.first_choice, a.second_choice) then perform fail('RR_NOT_YOUR_CHOICE', 'You can wait for your first or second choice only.'); end if;
  update applications set waitlist_type = p_type, wl_notified_at = null where id = a.id;
end $$;

create function public.leave_waitlist() returns void
language sql security definer set search_path = public as $$
  update applications set waitlist_type = null, wl_notified_at = null where student = auth.uid() and status = 'applied';
$$;

create function public.accept_terms() returns void
language sql security definer set search_path = public as $$
  update applications set terms_accepted_at = coalesce(terms_accepted_at, now()) where student = auth.uid() and academic_year = setting_text('academic_year');
$$;

-- ---------- Waiting list notifications ----------
-- Tells each waiting student once when a bed of their type opens for their gender,
-- and again later if beds fill up and free up once more.
create function public.notify_waitlist() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with w as (
    select a.id, a.student, a.waitlist_type, a.wl_notified_at, exists (select 1 from free_beds(a.waitlist_type, p.gender)) as has_free
      from applications a join profiles p on p.id = a.student
     where a.status = 'applied' and a.waitlist_type is not null),
  cleared as (update applications a set wl_notified_at = null from w where a.id = w.id and not w.has_free and w.wl_notified_at is not null returning a.id),
  newly as (update applications a set wl_notified_at = now() from w where a.id = w.id and w.has_free and w.wl_notified_at is null returning a.id, a.student, a.waitlist_type)
  insert into notifications (user_id, title, body)
  select n.student, 'A bed is free in ' || t.name, 'You are on the waiting list for application ' || n.id || '. Reserve it now before someone else does.'
    from newly n join room_types t on t.id = n.waitlist_type;
  get diagnostics n = row_count;
  return n;
end $$;

-- Runs every few minutes (pg_cron). A reservation with a payment started in the last
-- 30 minutes is left alone, so a slow mobile money approval does not lose the bed.
create function public.release_expired() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with x as (
    update applications a set status = 'applied', bed_id = null, type_id = null, reserved_until = null, expired_at = now()
     where a.status = 'reserved' and a.reserved_until < now()
       -- grace for a payment already in progress, capped at 30 minutes past the deadline so it cannot be used to hold a bed forever
       and not (a.reserved_until > now() - interval '30 minutes'
                and exists (select 1 from payments p where p.application_id = a.id and p.status = 'pending' and p.created_at > now() - interval '30 minutes'))
    returning a.id, a.student)
  insert into notifications (user_id, title, body)
  select student, 'Your reservation ended', 'You did not pay within ' || setting_text('reserve_days') || ' days, so the bed went back on offer. You can choose another bed.' from x;
  get diagnostics n = row_count;
  update upgrades set status = 'expired', bed_id = null where status = 'approved' and reserved_until < now();
  perform notify_waitlist();
  return n;
end $$;

-- ---------- Payments (called only by the Paystack edge functions with the service role) ----------
create function public.start_payment(p_student uuid, p_reference text, p_purpose text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a applications; u upgrades; amt numeric; bed text; email text;
begin
  select * into a from applications where student = p_student and academic_year = setting_text('academic_year') for update;
  if a.id is null then perform fail('RR_NO_APPLICATION', 'Submit your hostel application first.'); end if;
  if p_purpose = 'booking' then
    if a.status <> 'reserved' or a.reserved_until < now() then perform fail('RR_NOT_RESERVED', 'Reserve a bed before you pay.'); end if;
    if a.terms_accepted_at is null then perform fail('RR_TERMS', 'Accept the hostel policy and terms first.'); end if;
    select price_ghs into amt from room_types where id = a.type_id; bed := a.bed_id;
  else
    select * into u from upgrades where application_id = a.id and status = 'approved' and reserved_until > now() order by id desc limit 1;
    if u.id is null then perform fail('RR_NO_UPGRADE', 'There is no approved upgrade to pay for.'); end if;
    select n.price_ghs - o.price_ghs into amt from room_types n, room_types o where n.id = u.to_type and o.id = a.type_id; bed := u.bed_id;
  end if;
  if amt is null or amt <= 0 then perform fail('RR_NOTHING_TO_PAY', 'There is nothing to pay.'); end if;
  insert into payments (application_id, purpose, bed_id, amount_ghs, reference) values (a.id, p_purpose, bed, amt, p_reference);
  select p.email into email from profiles p where p.id = p_student;
  return jsonb_build_object('application', a.id, 'amount_pesewas', (amt * 100)::bigint, 'email', email, 'bed', bed);
end $$;

create function public.set_access_code(p_reference text, p_code text) returns void
language sql security definer set search_path = public as $$ update payments set access_code = p_code where reference = p_reference $$;

-- Idempotent: Paystack may send the same webhook more than once.
create function public.confirm_payment(p_reference text, p_amount_pesewas bigint, p_channel text, p_paid_at timestamptz, p_raw jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare pay payments; a applications; r rooms; g sex; u upgrades; v_inv text; label text;
begin
  select * into pay from payments where reference = p_reference for update;
  if pay.id is null then perform fail('RR_UNKNOWN_REFERENCE', p_reference); end if;
  if pay.status = 'success' then return 'already_confirmed'; end if;
  update payments set channel = p_channel, paid_at = p_paid_at, raw = p_raw where id = pay.id;
  if p_amount_pesewas <> (pay.amount_ghs * 100)::bigint then
    update payments set status = 'needs_refund' where id = pay.id;
    perform audit('payment.amount_mismatch', jsonb_build_object('ref', p_reference, 'got', p_amount_pesewas)); return 'needs_refund';
  end if;
  r := lock_room_of(pay.bed_id);
  select * into a from applications where id = pay.application_id for update;
  select gender into g from profiles where id = a.student;
  if pay.purpose = 'booking' then
    -- Normal case: still reserved on this bed. Late payment: reservation expired but the bed is still free.
    if not ((a.status = 'reserved' and a.bed_id = pay.bed_id) or (a.status = 'applied' and bed_free_for(pay.bed_id, g))) then
      update payments set status = 'needs_refund' where id = pay.id;
      insert into notifications (user_id, title, body) values (a.student, 'We received your payment',
        'Your reservation had ended and the bed was taken before the payment arrived. The housing office will contact you to give you another bed or a refund.');
      perform audit('payment.bed_lost', jsonb_build_object('ref', p_reference, 'app', a.id)); return 'needs_refund';
    end if;
    update applications set status = 'paid', bed_id = pay.bed_id, type_id = r.type_id, reserved_until = null,
           token = coalesce(token, 'RR-' || upper(substr(md5(gen_random_uuid()::text), 1, 8))) where id = a.id;
    label := 'Hostel fee 2026/27, ' || (select name from room_types where id = r.type_id);
  else
    select * into u from upgrades where application_id = a.id and bed_id = pay.bed_id and status = 'approved' for update;
    if u.id is null then
      update payments set status = 'needs_refund' where id = pay.id;
      perform audit('payment.upgrade_lost', jsonb_build_object('ref', p_reference)); return 'needs_refund';
    end if;
    update upgrades set status = 'paid' where id = u.id;   -- releases the hold first, then the booking moves onto the bed
    update applications set bed_id = pay.bed_id, type_id = r.type_id where id = a.id;
    label := 'Room upgrade to ' || (select name from room_types where id = r.type_id);
  end if;
  update payments set status = 'success' where id = pay.id;
  insert into invoices (application_id, payment_id, label, amount_ghs) values (a.id, pay.id, label, pay.amount_ghs) returning no into v_inv;
  insert into notifications (user_id, title, body) values (a.student, 'Your bed is ready',
    'Payment received. Invoice ' || v_inv || ' and your booking token are in My application. Show the token at check-in.');
  perform audit('payment.confirmed', jsonb_build_object('ref', p_reference, 'invoice', v_inv));
  if pay.purpose = 'upgrade' then perform notify_waitlist(); end if;
  return v_inv;
end $$;

-- ---------- Upgrades ----------
create function public.request_upgrade(p_type text) returns void
language plpgsql security definer set search_path = public as $$
declare a applications := current_app(true);
begin
  if a.status not in ('paid', 'checked_in') then perform fail('RR_NOT_PAID', 'You can ask for an upgrade after you have paid for your bed.'); end if;
  if (select price_ghs from room_types where id = p_type) <= (select price_ghs from room_types where id = a.type_id) then
    perform fail('RR_NOT_UPGRADE', 'Choose a room type that costs more than your current one.'); end if;
  if exists (select 1 from upgrades where application_id = a.id and status in ('requested', 'approved')) then perform fail('RR_PENDING', 'You already have an upgrade request.'); end if;
  insert into upgrades (application_id, to_type) values (a.id, p_type);
end $$;

create function public.decide_upgrade(p_id bigint, p_approve boolean, p_bed text) returns void
language plpgsql security definer set search_path = public as $$
declare u upgrades; r rooms; g sex;
begin
  if not is_admin() then perform fail('RR_FORBIDDEN', 'Administrators only.'); end if;
  select * into u from upgrades where id = p_id and status = 'requested' for update;
  if u.id is null then perform fail('RR_NOT_FOUND', 'That request is no longer waiting.'); end if;
  if not p_approve then update upgrades set status = 'declined' where id = u.id; return; end if;
  r := lock_room_of(p_bed);
  select p.gender into g from applications a join profiles p on p.id = a.student where a.id = u.application_id;
  if r.type_id <> u.to_type or not bed_free_for(p_bed, g) then perform fail('RR_BED_TAKEN', 'Choose a free bed of the requested room type.'); end if;
  update upgrades set status = 'approved', bed_id = p_bed, reserved_until = now() + make_interval(days => setting_text('reserve_days')::int) where id = u.id;
  insert into notifications (user_id, title, body) select student, 'Your upgrade was approved', 'Pay the difference within ' || setting_text('reserve_days') || ' days to move.' from applications where id = u.application_id;
end $$;

-- ---------- Staff actions ----------
create function public.admin_move(p_app text, p_bed text) returns void
language plpgsql security definer set search_path = public as $$
declare a applications; g sex; old_room int; new_room int;
begin
  if not is_admin() then perform fail('RR_FORBIDDEN', 'Administrators only.'); end if;
  select * into a from applications where id = p_app for update;
  if a.status not in ('reserved', 'paid', 'checked_in') then perform fail('RR_NO_BED', 'This application has no bed to move.'); end if;
  select room_no into old_room from beds where id = a.bed_id;
  select room_no into new_room from beds where id = p_bed;
  if new_room is null then perform fail('RR_NO_SUCH_BED', 'That bed does not exist.'); end if;
  -- lock both rooms in a fixed order so two moves can never deadlock
  perform 1 from rooms where room_no in (old_room, new_room) order by room_no for update;
  update applications set bed_id = null, status = 'applied' where id = a.id;   -- step off the old bed so the checks below ignore it
  select gender into g from profiles where id = a.student;
  if not bed_free_for(p_bed, g) then perform fail('RR_BED_TAKEN', 'That bed is taken, or the room is for the other gender.'); end if;
  update applications set bed_id = p_bed, status = a.status, type_id = (select type_id from rooms where room_no = new_room) where id = a.id;
  insert into notifications (user_id, title, body) values (a.student, 'Your room was changed', 'The housing office moved you to bed ' || p_bed || '. See My application for details.');
  perform audit('admin.move', jsonb_build_object('app', p_app, 'from', a.bed_id, 'to', p_bed));
  perform notify_waitlist();
end $$;

create function public.check_in(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare a applications;
begin
  select ap.* into a from applications ap join beds b on b.id = ap.bed_id join rooms r on r.room_no = b.room_no
   where ap.token = upper(trim(p_token)) and (is_admin() or r.hostel_id = my_hostel()) for update of ap;
  if a.id is null then perform fail('RR_BAD_TOKEN', 'No paid booking in your hostel has this token.'); end if;
  if a.status = 'checked_in' then return 'already'; end if;
  if a.status <> 'paid' then perform fail('RR_NOT_PAID', 'This booking is not paid.'); end if;
  update applications set status = 'checked_in' where id = a.id;
  perform audit('check_in', jsonb_build_object('app', a.id));
  return a.id;
end $$;

-- ---------- Problem reports and notifications ----------
create function public.report_problem(p_category text, p_details text) returns bigint
language plpgsql security definer set search_path = public as $$
declare a applications := current_app(false); r rooms; v bigint;
begin
  if a.status not in ('paid', 'checked_in') then perform fail('RR_NO_ROOM', 'You can report problems once you have a paid bed.'); end if;
  select r2.* into r from rooms r2 join beds b on b.room_no = r2.room_no where b.id = a.bed_id;
  insert into reports (application_id, hostel_id, room_no, category, details) values (a.id, r.hostel_id, r.room_no, p_category, trim(p_details)) returning id into v;
  return v;
end $$;

create function public.set_report_status(p_id bigint, p_status text, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
declare rp reports;
begin
  select * into rp from reports where id = p_id for update;
  if rp.id is null or not (is_admin() or rp.hostel_id = my_hostel()) then perform fail('RR_FORBIDDEN', 'Not your hostel.'); end if;
  update reports set status = p_status where id = p_id;
  if coalesce(trim(p_reply), '') <> '' then insert into report_messages (report_id, author, body) values (p_id, auth.uid(), trim(p_reply)); end if;
  insert into notifications (user_id, title, body) select student, 'Update on your problem report', 'Status: ' || replace(p_status, '_', ' ') || coalesce('. ' || nullif(trim(p_reply), ''), '') from applications where id = rp.application_id;
end $$;

create function public.mark_notifications_read() returns void
language sql security definer set search_path = public as $$ update notifications set read_at = now() where user_id = auth.uid() and read_at is null $$;

create function public.request_access(p_hostel text, p_name text, p_contact text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from access_requests where status = 'pending' and created_at > now() - interval '1 day') > 50 then perform fail('RR_BUSY', 'Too many requests today. Try again tomorrow.'); end if;
  insert into access_requests (hostel_id, full_name, contact) values (p_hostel, left(trim(p_name), 120), left(trim(p_contact), 120));
end $$;

-- ===== migrations/20261124000300_security.sql =====
-- Row level security. Reads are filtered per role; ALL writes go through the functions
-- in the logic migration, so no table has an insert, update or delete policy for users.

do $$ declare t text; begin
  foreach t in array array['settings','hostels','lecture_buildings','room_types','rooms','beds','room_photos','bed_state',
    'admissions','profiles','applications','payments','invoices','upgrades','reports','report_messages','notifications',
    'access_requests','audit_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- The holds view bypasses RLS, so only the functions may read it
revoke all on public.live_holds from anon, authenticated;

-- Public catalogue: anyone can see hostels, rooms, prices, photos, the map and live bed availability
create policy "public read" on public.settings          for select using (key in ('academic_year', 'reserve_days', 'min_age', 'applications_open'));
create policy "public read" on public.hostels           for select using (true);
create policy "public read" on public.lecture_buildings for select using (true);
create policy "public read" on public.room_types        for select using (true);
create policy "public read" on public.rooms             for select using (true);
create policy "public read" on public.beds              for select using (true);
create policy "public read" on public.room_photos       for select using (true);
create policy "public read" on public.bed_state         for select using (true);

-- Admission records: administrators only
create policy "admin read" on public.admissions for select using (public.is_admin());

-- Profiles: yourself; administrators everyone; managers the students in their hostel
create policy "own profile"   on public.profiles for select using (id = auth.uid());
create policy "admin read"    on public.profiles for select using (public.is_admin());
create policy "manager read"  on public.profiles for select using (exists (
  select 1 from public.applications a join public.beds b on b.id = a.bed_id join public.rooms r on r.room_no = b.room_no
   where a.student = profiles.id and r.hostel_id = public.my_hostel()));

-- Applications, payments, invoices, upgrades: owner, administrators, and the manager of the hostel the bed is in
create function public.can_see_app(p_app text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from applications a where a.id = p_app and (
      a.student = auth.uid() or is_admin()
      or exists (select 1 from beds b join rooms r on r.room_no = b.room_no where b.id = a.bed_id and r.hostel_id = my_hostel())))
$$;
create policy "can see" on public.applications for select using (public.can_see_app(id));
create policy "can see" on public.payments     for select using (public.can_see_app(application_id));
create policy "can see" on public.invoices     for select using (public.can_see_app(application_id));
create policy "can see" on public.upgrades     for select using (public.can_see_app(application_id));

-- Problem reports: the student who sent it, that hostel's manager, administrators
create policy "can see" on public.reports for select using (public.can_see_app(application_id) or hostel_id = public.my_hostel());
create policy "can see" on public.report_messages for select using (exists (
  select 1 from public.reports r where r.id = report_id and (public.can_see_app(r.application_id) or r.hostel_id = public.my_hostel())));

create policy "own" on public.notifications for select using (user_id = auth.uid());
create policy "admin read" on public.access_requests for select using (public.is_admin());
create policy "admin read" on public.audit_log for select using (public.is_admin());

-- Functions: nobody but the service role (edge functions) may move money or touch payments
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.check_eligibility(public.student_kind, text, text, date), public.request_access(text, text, text) to anon, authenticated;
grant execute on function
  public.submit_application(text, text, jsonb, jsonb), public.reserve_bed(text), public.release_my_reservation(), public.join_waitlist(text),
  public.leave_waitlist(), public.accept_terms(), public.add_student_id(text), public.request_upgrade(text), public.report_problem(text, text),
  public.mark_notifications_read(), public.decide_upgrade(bigint, boolean, text), public.admin_move(text, text), public.check_in(text),
  public.set_report_status(bigint, text, text), public.import_admissions(jsonb, text), public.set_staff(text, public.user_role, text),
  public.free_beds(text, public.sex)
  to authenticated;
-- Helpers that RLS policies call must stay executable by the roles the policies run as
grant execute on function public.is_admin(), public.my_hostel(), public.can_see_app(text) to anon, authenticated;
-- start_payment, set_access_code, confirm_payment, release_expired, notify_waitlist: service role only (Supabase grants it everything)

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- Realtime: the live bed board
alter publication supabase_realtime add table public.bed_state;

-- Room photos bucket: public to read, administrators upload
insert into storage.buckets (id, name, public) values ('room-photos', 'room-photos', true) on conflict do nothing;
create policy "admin upload room photos" on storage.objects for insert to authenticated with check (bucket_id = 'room-photos' and public.is_admin());
create policy "admin delete room photos" on storage.objects for delete to authenticated using (bucket_id = 'room-photos' and public.is_admin());

-- ===== migrations/20261124000400_cron.sql =====
-- Expire unpaid reservations (15 days) and send waiting list notices every 5 minutes
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('roomright-release-expired', '*/5 * * * *', $$select public.release_expired()$$);

-- ===== seed.sql =====
-- Maria and Camille, from the university's room details sheet (2026/27).
-- Hostel coordinates are left empty on purpose: the housing office sets the real pins in the admin page.
insert into public.hostels (id, name) values ('maria', 'Maria'), ('camille', 'Camille');
insert into public.room_types (id, name, beds, price_ghs, premium, inventory) values
  ('t1', 'One in a room', 1, 30000, false, '[{"item": "Single bed", "qty": 1}, {"item": "Mattress", "qty": 1}, {"item": "Study desk", "qty": 1}, {"item": "Air conditioner", "qty": 1}, {"item": "Ceiling fan", "qty": 1}, {"item": "Table-top fridge", "qty": 1}, {"item": "Prepaid electricity meter", "qty": 1}]'),
  ('t1b', 'One in a room with balcony', 1, 32000, true, '[{"item": "Single bed", "qty": 1}, {"item": "Mattress", "qty": 1}, {"item": "Study desk", "qty": 1}, {"item": "Air conditioner", "qty": 1}, {"item": "Ceiling fan", "qty": 1}, {"item": "Table-top fridge", "qty": 1}, {"item": "Prepaid electricity meter", "qty": 1}, {"item": "Balcony and private hallway", "qty": 1}]'),
  ('t2', 'Two in a room', 2, 20000, false, '[{"item": "Single bed", "qty": 2}, {"item": "Mattress", "qty": 2}, {"item": "Study desk", "qty": 2}, {"item": "Air conditioner", "qty": 1}, {"item": "Ceiling fan", "qty": 1}, {"item": "Table-top fridge", "qty": 1}, {"item": "Prepaid electricity meter", "qty": 1}]'),
  ('t3', 'Three in a room', 3, 17000, false, '[{"item": "Single bed", "qty": 3}, {"item": "Mattress", "qty": 3}, {"item": "Study desk", "qty": 3}, {"item": "Air conditioner", "qty": 1}, {"item": "Ceiling fan", "qty": 1}, {"item": "Table-top fridge", "qty": 1}, {"item": "Prepaid electricity meter", "qty": 1}]'),
  ('t3p', 'Three in a room premium', 3, 19000, true, '[{"item": "Single bed", "qty": 3}, {"item": "Mattress", "qty": 3}, {"item": "Study desk", "qty": 3}, {"item": "Air conditioner", "qty": 1}, {"item": "Ceiling fan", "qty": 1}, {"item": "Table-top fridge", "qty": 1}, {"item": "Prepaid electricity meter", "qty": 1}]'),
  ('t4', 'Four in a room', 4, 14000, false, '[{"item": "Single bed", "qty": 4}, {"item": "Mattress", "qty": 4}, {"item": "Study desk", "qty": 4}, {"item": "Air conditioner", "qty": 1}, {"item": "Ceiling fan", "qty": 1}, {"item": "Table-top fridge", "qty": 1}, {"item": "Prepaid electricity meter", "qty": 1}]');
-- Which rooms carry the balcony or premium price is an assumption until hostel management confirms it
insert into public.rooms (room_no, hostel_id, floor, type_id) values
  (1, 'maria', 0, 't2'),
  (2, 'maria', 0, 't2'),
  (3, 'maria', 0, 't2'),
  (4, 'maria', 0, 't3'),
  (5, 'maria', 0, 't4'),
  (6, 'maria', 0, 't2'),
  (7, 'maria', 0, 't2'),
  (8, 'maria', 0, 't4'),
  (9, 'maria', 0, 't2'),
  (10, 'maria', 1, 't3p'),
  (11, 'maria', 1, 't4'),
  (12, 'maria', 1, 't2'),
  (13, 'maria', 1, 't2'),
  (14, 'maria', 1, 't4'),
  (15, 'maria', 1, 't2'),
  (16, 'maria', 1, 't2'),
  (17, 'maria', 1, 't1'),
  (18, 'maria', 1, 't3'),
  (19, 'maria', 1, 't2'),
  (20, 'camille', 0, 't2'),
  (21, 'camille', 0, 't1'),
  (22, 'camille', 0, 't2'),
  (23, 'camille', 0, 't1'),
  (24, 'camille', 0, 't2'),
  (25, 'camille', 0, 't1'),
  (26, 'camille', 0, 't2'),
  (27, 'camille', 1, 't1b'),
  (28, 'camille', 1, 't1'),
  (29, 'camille', 1, 't1b'),
  (30, 'camille', 1, 't2'),
  (31, 'camille', 1, 't2'),
  (32, 'camille', 1, 't3'),
  (33, 'camille', 1, 't3p'),
  (34, 'camille', 1, 't2'),
  (35, 'camille', 2, 't1b'),
  (36, 'camille', 2, 't1'),
  (37, 'camille', 2, 't1b'),
  (38, 'camille', 2, 't2'),
  (39, 'camille', 2, 't2'),
  (40, 'camille', 2, 't3'),
  (41, 'camille', 2, 't2'),
  (42, 'camille', 2, 't1');
insert into public.beds (id, room_no, idx) values
  ('1-0', 1, 0),
  ('1-1', 1, 1),
  ('2-0', 2, 0),
  ('2-1', 2, 1),
  ('3-0', 3, 0),
  ('3-1', 3, 1),
  ('4-0', 4, 0),
  ('4-1', 4, 1),
  ('4-2', 4, 2),
  ('5-0', 5, 0),
  ('5-1', 5, 1),
  ('5-2', 5, 2),
  ('5-3', 5, 3),
  ('6-0', 6, 0),
  ('6-1', 6, 1),
  ('7-0', 7, 0),
  ('7-1', 7, 1),
  ('8-0', 8, 0),
  ('8-1', 8, 1),
  ('8-2', 8, 2),
  ('8-3', 8, 3),
  ('9-0', 9, 0),
  ('9-1', 9, 1),
  ('10-0', 10, 0),
  ('10-1', 10, 1),
  ('10-2', 10, 2),
  ('11-0', 11, 0),
  ('11-1', 11, 1),
  ('11-2', 11, 2),
  ('11-3', 11, 3),
  ('12-0', 12, 0),
  ('12-1', 12, 1),
  ('13-0', 13, 0),
  ('13-1', 13, 1),
  ('14-0', 14, 0),
  ('14-1', 14, 1),
  ('14-2', 14, 2),
  ('14-3', 14, 3),
  ('15-0', 15, 0),
  ('15-1', 15, 1),
  ('16-0', 16, 0),
  ('16-1', 16, 1),
  ('17-0', 17, 0),
  ('18-0', 18, 0),
  ('18-1', 18, 1),
  ('18-2', 18, 2),
  ('19-0', 19, 0),
  ('19-1', 19, 1),
  ('20-0', 20, 0),
  ('20-1', 20, 1),
  ('21-0', 21, 0),
  ('22-0', 22, 0),
  ('22-1', 22, 1),
  ('23-0', 23, 0),
  ('24-0', 24, 0),
  ('24-1', 24, 1),
  ('25-0', 25, 0),
  ('26-0', 26, 0),
  ('26-1', 26, 1),
  ('27-0', 27, 0),
  ('28-0', 28, 0),
  ('29-0', 29, 0),
  ('30-0', 30, 0),
  ('30-1', 30, 1),
  ('31-0', 31, 0),
  ('31-1', 31, 1),
  ('32-0', 32, 0),
  ('32-1', 32, 1),
  ('32-2', 32, 2),
  ('33-0', 33, 0),
  ('33-1', 33, 1),
  ('33-2', 33, 2),
  ('34-0', 34, 0),
  ('34-1', 34, 1),
  ('35-0', 35, 0),
  ('36-0', 36, 0),
  ('37-0', 37, 0),
  ('38-0', 38, 0),
  ('38-1', 38, 1),
  ('39-0', 39, 0),
  ('39-1', 39, 1),
  ('40-0', 40, 0),
  ('40-1', 40, 1),
  ('40-2', 40, 2),
  ('41-0', 41, 0),
  ('41-1', 41, 1),
  ('42-0', 42, 0);
insert into public.bed_state (bed_id, room_no) select id, room_no from public.beds;

commit;
