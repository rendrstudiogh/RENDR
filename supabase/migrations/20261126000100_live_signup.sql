-- Stage 1 (live sign up): tighten the sign up trigger now that the website calls Supabase Auth directly.
-- Paste this into the SQL Editor once. It is safe to run more than once.
--
-- 1. Gender and full name are required in the database, not only in the form. Without the gender check,
--    someone calling the Auth API directly could create a profile with no gender, and bed_free_for()
--    treats a missing gender as "fits any room", which would break the single gender room rule.
-- 2. A malformed date of birth gives the clear "under age" refusal instead of a raw Postgres error.
-- 3. check_eligibility() is no longer callable from the browser. The sign up trigger already runs it and
--    Supabase Auth returns its RR_ code, and Auth rate limits sign ups per IP. A browser-callable copy
--    had no rate limit, so it could be used to guess a student's date of birth from their ID and name.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'); k student_kind; v text; d date; chk text;
begin
  if coalesce(m ->> 'kind', '') not in ('new', 'returning') then return new; end if;
  k := (m ->> 'kind')::student_kind;
  begin d := (m ->> 'dob')::date; exception when others then d := null; end;
  if coalesce(m ->> 'gender', '') not in ('F', 'M') then perform fail('RR_SIGNUP_GENDER', 'Choose female or male.'); end if;
  if length(trim(coalesce(m ->> 'full_name', ''))) < 3 then perform fail('RR_SIGNUP_NAME', 'Enter your full name.'); end if;
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

revoke execute on function public.check_eligibility(public.student_kind, text, text, date) from public, anon, authenticated;
