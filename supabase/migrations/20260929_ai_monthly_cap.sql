-- ぺたろぐ: whole-app monthly AI cap (applied 2026-09-29, reference copy)
drop function if exists public.ai_take(uuid, int, int);
create or replace function public.ai_take(p_user uuid, p_limit int, p_global int, p_month int) returns int
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date; m int; g int; u int;
begin
  select coalesce(sum(count), 0) into m from public.ai_global where day >= date_trunc('month', d)::date and day <= d;
  if m >= p_month then return -3; end if;
  insert into public.ai_global(day, count) values (d, 1)
    on conflict (day) do update set count = public.ai_global.count + 1 returning count into g;
  if g > p_global then update public.ai_global set count = count - 1 where day = d; return -2; end if;
  insert into public.ai_usage(user_id, day, count) values (p_user, d, 1)
    on conflict (user_id, day) do update set count = public.ai_usage.count + 1 returning count into u;
  if u > p_limit then
    update public.ai_usage set count = count - 1 where user_id = p_user and day = d;
    update public.ai_global set count = count - 1 where day = d;
    return -1;
  end if;
  return p_limit - u;
end $$;
revoke all on function public.ai_take(uuid, int, int, int) from public, anon, authenticated;
grant execute on function public.ai_take(uuid, int, int, int) to service_role;
create or replace function public.ai_month_used() returns int
language sql security definer set search_path = '' stable as $$
  select coalesce(sum(count), 0)::int from public.ai_global
  where day >= date_trunc('month', (now() at time zone 'Asia/Tokyo')::date)::date;
$$;
revoke all on function public.ai_month_used() from public, anon, authenticated;
grant execute on function public.ai_month_used() to service_role;
