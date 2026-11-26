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

-- Explicit access, so this works when the project does NOT grant API access to new tables
-- automatically (the safer setting). Users only ever get SELECT; RLS below decides which rows.
grant usage on schema public to anon, authenticated, service_role;
grant select on public.settings, public.hostels, public.lecture_buildings, public.room_types, public.rooms, public.beds,
  public.room_photos, public.bed_state to anon, authenticated;
grant select on public.admissions, public.profiles, public.applications, public.payments, public.invoices, public.upgrades,
  public.reports, public.report_messages, public.notifications, public.access_requests, public.audit_log to authenticated;
-- The edge functions use the service role
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

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
-- start_payment, set_access_code, confirm_payment, release_expired, notify_waitlist: service role only
grant execute on all functions in schema public to service_role;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- Realtime: the live bed board
alter publication supabase_realtime add table public.bed_state;

-- Room photos bucket: public to read, administrators upload
insert into storage.buckets (id, name, public) values ('room-photos', 'room-photos', true) on conflict do nothing;
create policy "admin upload room photos" on storage.objects for insert to authenticated with check (bucket_id = 'room-photos' and public.is_admin());
create policy "admin delete room photos" on storage.objects for delete to authenticated using (bucket_id = 'room-photos' and public.is_admin());
