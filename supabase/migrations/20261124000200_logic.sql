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
