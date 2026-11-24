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
