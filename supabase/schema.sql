-- =====================================================================
--  Construction tracker system — Supabase schema
--  How to use: Supabase Dashboard → SQL Editor → New query → paste the whole file → Run
--  Safe to run again (it doesn't delete existing data)
-- =====================================================================

-- ---------- 1) User profiles + roles ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique,
  name       text not null default '',
  role       text not null default 'exec' check (role in ('admin','clerk','field','exec')),
  created_at timestamptz not null default now()
);

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

-- Roles that can edit data: admin, clerk, field
create or replace function public.can_write() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin','clerk','field'), false)
$$;

-- Create a profile automatically when a new user is added
--   * The very first user in the system becomes admin (create it yourself in the Dashboard right after running this file)
--   * Everyone after that starts as exec (view only); an admin then sets the role in the app
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  uname text;
  is_first boolean;
begin
  uname := lower(coalesce(nullif(new.raw_user_meta_data->>'username',''), split_part(new.email,'@',1)));
  select not exists (select 1 from public.profiles) into is_first;
  insert into public.profiles (id, username, name, role)
  values (new.id, uname,
          coalesce(nullif(new.raw_user_meta_data->>'name',''), uname),
          case when is_first then 'admin' else 'exec' end)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Users created before this file was run (e.g. admin@hw5.local added first) → create their profiles now
-- If there are no profiles yet, the earliest-created user becomes admin
insert into public.profiles (id, username, name, role)
select u.id,
       lower(coalesce(nullif(u.raw_user_meta_data->>'username',''), split_part(u.email,'@',1))),
       coalesce(nullif(u.raw_user_meta_data->>'name',''), split_part(u.email,'@',1)),
       case when row_number() over (order by u.created_at) = 1
                 and not exists (select 1 from public.profiles) then 'admin' else 'exec' end
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict do nothing;

alter table public.profiles enable row level security;
drop policy if exists "profiles: read self or admin" on public.profiles;
create policy "profiles: read self or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles: admin update" on public.profiles;
create policy "profiles: admin update" on public.profiles
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- 2) Projects (1 row = 1 project, data stored as JSON) ----------
create table if not exists public.projects (
  id         text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create or replace function public.touch_project() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
drop trigger if exists projects_touch on public.projects;
create trigger projects_touch before insert or update on public.projects
  for each row execute function public.touch_project();

alter table public.projects enable row level security;
-- Guests (not signed in) can view, as the user chose
drop policy if exists "projects: public read" on public.projects;
create policy "projects: public read" on public.projects
  for select to anon, authenticated using (true);
drop policy if exists "projects: staff insert" on public.projects;
create policy "projects: staff insert" on public.projects
  for insert to authenticated with check (public.can_write());
drop policy if exists "projects: staff update" on public.projects;
create policy "projects: staff update" on public.projects
  for update to authenticated using (public.can_write()) with check (public.can_write());
drop policy if exists "projects: staff delete" on public.projects;
create policy "projects: staff delete" on public.projects
  for delete to authenticated using (public.can_write());

-- ---------- 3) General settings (e.g. office director list for the cover sheet) ----------
create table if not exists public.app_kv (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_kv enable row level security;
drop policy if exists "kv: signed-in read" on public.app_kv;
create policy "kv: signed-in read" on public.app_kv
  for select to authenticated using (true);
drop policy if exists "kv: staff write" on public.app_kv;
create policy "kv: staff write" on public.app_kv
  for all to authenticated using (public.can_write()) with check (public.can_write());

-- ---------- 4) Edit history ----------
create table if not exists public.edit_log (
  id      bigint generated always as identity primary key,
  t       timestamptz not null default now(),
  who     text not null default '',
  what    text not null default '',
  user_id uuid not null default auth.uid()
);
alter table public.edit_log enable row level security;
drop policy if exists "log: signed-in read" on public.edit_log;
create policy "log: signed-in read" on public.edit_log
  for select to authenticated using (true);
drop policy if exists "log: staff insert" on public.edit_log;
create policy "log: staff insert" on public.edit_log
  for insert to authenticated with check (public.can_write() and user_id = auth.uid());

-- ---------- 5) Functions only an admin can call ----------
create or replace function public.admin_set_password(target uuid, new_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_admin() then raise exception 'ไม่มีสิทธิ์'; end if;
  if length(coalesce(new_password,'')) < 6 then raise exception 'รหัสผ่านต้องยาวอย่างน้อย 6 ตัวอักษร'; end if;
  update auth.users
     set encrypted_password = crypt(new_password, gen_salt('bf')), updated_at = now()
   where id = target;
end $$;

create or replace function public.admin_delete_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'ไม่มีสิทธิ์'; end if;
  if target = auth.uid() then raise exception 'ลบบัญชีที่กำลังใช้งานไม่ได้'; end if;
  if (select role from public.profiles where id = target) = 'admin'
     and (select count(*) from public.profiles where role = 'admin') <= 1 then
    raise exception 'ต้องมีผู้ดูแลระบบอย่างน้อย 1 บัญชี';
  end if;
  delete from auth.users where id = target;
end $$;

revoke all on function public.admin_set_password(uuid, text) from public, anon;
revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_set_password(uuid, text) to authenticated;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- ---------- 5.1) Grant the Data API access to the tables (new Supabase projects don't grant this automatically) ----------
grant usage on schema public to anon, authenticated;
grant select on public.projects to anon, authenticated;
grant insert, update, delete on public.projects to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.app_kv to authenticated;
grant select, insert on public.edit_log to authenticated;
grant execute on function public.my_role(), public.is_admin(), public.can_write() to anon, authenticated;

-- ---------- 6) Realtime: every device sees edits immediately ----------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'projects') then
    alter publication supabase_realtime add table public.projects;
  end if;
end $$;

-- ---------- 7) Sample project: contract อต.1/47/2569 ----------
insert into public.projects (id, data) values ('seed-at1-47-2569', $json${"id":"seed-at1-47-2569","dept":"แขวงทางหลวงอุตรดิตถ์ที่ 1  สำนักงานทางหลวงที่ 5 ( พิษณุโลก)","contractNo":"สัญญาเลขที่ อต.1/ 47 / 2569 ลงวันที่ 10 สิงหาคม 2569","program1":"โครงการพัฒนาโครงข่ายการคมนาคมขนส่งและโลจิสติกส์ในพื้นที่ เชื่อมโยงเส้นทางคมนาคมที่สำคัญของประเทศ","program2":"และเชื่อมโยงการค้าการลงทุนชายแดน กิจกรรมหลักพัฒนาโครงข่ายคมนาคมทางหลวง ก่อสร้างเพิ่มประสิทธิภาพทางหลวง","projectName":"ทางหลวงหมายเลข 1244  ตอนควบคุม 0100 ตอน น้ำอ่าง – น้ำพี้ กม.0+000 - กม.3+781.50","location":"ตำบลป่าคาย  อำเภอทองแสนขัน จังหวัดอุตรดิตถ์ ปริมาณงาน 1 แห่ง (3.7815 กม.)","startDate":"2026-08-11","endDate":"2027-01-07","duration":150,"contractValue":34679000,"finePerDay":86697.5,"contractor":"บริษัท จ.จักรวาล 42 จำกัด","fiscalYear":"2569","budgetType":"งบกรม","workType":"งานก่อสร้าง","supervisor":"นายเฉลิมพล ศรีใจวงศ์","lat":"17.62480","lng":"100.25960","committee":[{"name":"นายสุเทพ วงศ์อนันต์","role":"ประธานกรรมการ","pos":"ผส.ทล.5"},{"name":"นางสาวจุฑามาศ เรืองศรี","role":"กรรมการ","pos":"วิศวกรโยธาชำนาญการ"},{"name":"นายกิตติ ใจดี","role":"กรรมการ","pos":"นายช่างโยธาอาวุโส"}],"appointments":[],"materialInspector":"","contractorRep":"","assistants":[],"note":"-","items":[{"no":"1","name":"งาน CLEARING AND GRUBBING","qty":45240,"unit":"ตร.ม.","price":4.78},{"no":"2","name":"งาน EARTH EXCAVATION","qty":3460,"unit":"ลบ.ม.","price":59.77},{"no":"3","name":"งาน UNSUITABLE MATERIAL EXCAVATION","qty":125,"unit":"ลบ.ม.","price":65.74},{"no":"4","name":"งาน EARTH EMBANKMENT","qty":9435,"unit":"ลบ.ม.","price":163.75},{"no":"5","name":"งาน SELECTED MATERIAL “A”","qty":4723,"unit":"ลบ.ม.","price":467.67},{"no":"6","name":"งาน SOIL AGGREGATE SUBBASE","qty":3146,"unit":"ลบ.ม.","price":513.96},{"no":"7","name":"งาน CRUSHED ROCK SOIL AGGREGATE TYPE BASE","qty":2807,"unit":"ลบ.ม.","price":587.27},{"no":"8","name":"งาน SOFT SPOT EXCAVATION AND REPLACEMENT","qty":0,"unit":"","price":0},{"no":"8.1","name":"8.1 งาน SOFT MATERIAL EXCAVATION (EXCAVATION ONLY)","qty":53,"unit":"ลบ.ม.","price":65.74},{"no":"8.2","name":"8.2 งาน SELECTED MATERIAL \"A\"","qty":19,"unit":"ลบ.ม.","price":467.67},{"no":"8.3","name":"8.3 งาน SOIL AGGREGATE SUBBASE","qty":14,"unit":"ลบ.ม.","price":513.96},{"no":"8.4","name":"8.4 งาน CRUSHED ROCK SOIL AGGREGATE TYPE BASE","qty":14,"unit":"ลบ.ม.","price":587.27},{"no":"9","name":"งาน PRIME COAT","qty":17678,"unit":"ตร.ม.","price":50.58},{"no":"10","name":"งาน TACK COAT (บนผิวจราจรใหม่)","qty":17204,"unit":"ตร.ม.","price":13.81},{"no":"11","name":"งาน TACK COAT (บนผิวจราจรเดิม)","qty":28419,"unit":"ตร.ม.","price":17.84},{"no":"12","name":"งาน ASPHALT CONCRETE LEVELLING COURSE","qty":95,"unit":"ตัน","price":3159.53},{"no":"13","name":"งาน ASPHALT CONCRETE BINDER COURSE (AC 60-70) 5 CM. THICK (ON PRIME COAT)","qty":17204,"unit":"ตร.ม.","price":378.85},{"no":"14","name":"งาน ASPHALT CONCRETE WEARING COURSE (AC 60-70) 5 CM. THICK (ON TACK COAT)","qty":45246,"unit":"ตร.ม.","price":379.13},{"no":"15","name":"งาน R.C. PIPE CULVERTS DIA 0.80 M. CLASS II","qty":16,"unit":"ม.","price":3411.68},{"no":"16","name":"งาน R.C. PIPE CULVERTS DIA 1.00 M. CLASS II","qty":156,"unit":"ม.","price":4734.4},{"no":"17","name":"งาน PLAIN CONCRETE HEADWALL FOR R.C. PIPE CULVERT (END WALL)","qty":11,"unit":"ลบ.ม.","price":3056.44},{"no":"18","name":"งาน REINFORCED CONCRETE FOR R.C. PIPE CULVERT (END WALL)","qty":18,"unit":"ลบ.ม.","price":3918.91},{"no":"19","name":"งาน THERMOPLASTIC PAINT (YELLOW & WHITE)","qty":1767,"unit":"ตร.ม.","price":362.19},{"no":"20","name":"งาน TRAFFIC MANAGEMENT DURING CONSTRUCTION","qty":1,"unit":"LS.","price":52725.82}],"weeks":{"2026-08-17":{"plan":0.477,"planW":0.477,"actual":{"20":100}},"2026-08-24":{"plan":0.955,"planW":0.478,"actual":{"20":100}},"2026-08-31":{"plan":1.432,"planW":0.477,"actual":{"20":100}},"2026-09-07":{"plan":1.909,"planW":0.477,"actual":{"1":5,"20":100}},"2026-09-14":{"plan":4.672,"planW":2.763,"actual":{}},"2026-09-21":{"plan":7.435,"planW":2.763,"actual":{}},"2026-09-28":{"plan":10.198,"planW":2.763,"actual":{}},"2026-10-05":{"plan":12.961,"planW":2.763,"actual":{}},"2026-10-12":{"plan":16.887,"planW":3.926,"actual":{}},"2026-10-19":{"plan":20.813,"planW":3.926,"actual":{}},"2026-10-26":{"plan":24.739,"planW":3.926,"actual":{}},"2026-11-02":{"plan":28.665,"planW":3.926,"actual":{}},"2026-11-09":{"plan":36.171,"planW":7.506,"actual":{}},"2026-11-16":{"plan":43.678,"planW":7.507,"actual":{}},"2026-11-23":{"plan":51.184,"planW":7.506,"actual":{}},"2026-11-30":{"plan":58.691,"planW":7.507,"actual":{}},"2026-12-07":{"plan":66.197,"planW":7.506,"actual":{}},"2026-12-14":{"plan":74.155,"planW":7.958,"actual":{}},"2026-12-21":{"plan":82.114,"planW":7.959,"actual":{}},"2026-12-28":{"plan":90.072,"planW":7.958,"actual":{}},"2027-01-04":{"plan":98.03,"planW":7.958,"actual":{}},"2027-01-07":{"plan":100,"planW":1.97,"actual":{}}}}$json$::jsonb)
on conflict (id) do nothing;

-- Tell the Data API to reload the table structure
notify pgrst, 'reload schema';
