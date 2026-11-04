-- Run this if the app can't find the tables (API error PGRST205) even though schema.sql succeeded
grant usage on schema public to anon, authenticated;
grant select on public.projects to anon, authenticated;
grant insert, update, delete on public.projects to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.app_kv to authenticated;
grant select, insert on public.edit_log to authenticated;
grant execute on function public.my_role(), public.is_admin(), public.can_write() to anon, authenticated;
notify pgrst, 'reload schema';

-- Check: should show 1 sample project and the profiles of the users you created
select 'projects' as tbl, count(*) as n from public.projects
union all
select 'profiles (' || role || ')', count(*) from public.profiles group by role;
