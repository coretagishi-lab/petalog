-- ぺたろぐ: applied to Supabase project "petalog" on 2026-09-29 (reference copy)
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create table public.stamps (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null check (char_length(id) between 1 and 64),
  data jsonb not null default '{}'::jsonb check (octet_length(data::text) < 400000),
  cut_path text check (cut_path is null or char_length(cut_path) < 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
create trigger stamps_touch before update on public.stamps for each row execute function public.touch_updated_at();

create table public.user_meta (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  key text not null check (key ~ '^[a-z_]{1,32}$'),
  data jsonb not null default '{}'::jsonb check (octet_length(data::text) < 1000000),
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);
create trigger user_meta_touch before update on public.user_meta for each row execute function public.touch_updated_at();

create table public.shares (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  stamp_id text check (stamp_id is null or char_length(stamp_id) <= 64),
  kind text not null default 'record' check (kind in ('record','miss')),
  nick text not null default '' check (char_length(nick) <= 20),
  name text not null default '' check (char_length(name) <= 120),
  place text not null default '' check (char_length(place) <= 120),
  pref text not null default '' check (char_length(pref) <= 10),
  cat text not null default '' check (char_length(cat) <= 20),
  type text not null default 'stamp' check (char_length(type) <= 20),
  date text not null default '' check (char_length(date) <= 10),
  lat double precision check (lat is null or lat between -90 and 90),
  lng double precision check (lng is null or lng between -180 and 180),
  size_mm real check (size_mm is null or size_mm between 0 and 2000),
  rk text not null default '' check (char_length(rk) <= 120),
  spot text not null default '' check (char_length(spot) <= 120),
  spot_tags text[] not null default '{}' check (cardinality(spot_tags) <= 12),
  reason text not null default '' check (char_length(reason) <= 40),
  thumb text not null default '' check (octet_length(thumb) <= 120000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, stamp_id)
);
create index shares_updated_idx on public.shares (updated_at desc);
create index shares_rk_idx on public.shares (rk) where rk <> '';
create trigger shares_touch before update on public.shares for each row execute function public.touch_updated_at();

create table public.ai_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  count int not null default 0,
  primary key (user_id, day)
);
create table public.ai_global (day date primary key, count int not null default 0);

alter table public.stamps    enable row level security;
alter table public.user_meta enable row level security;
alter table public.shares    enable row level security;
alter table public.ai_usage  enable row level security;
alter table public.ai_global enable row level security;

revoke all on public.stamps, public.user_meta, public.shares, public.ai_usage, public.ai_global from anon, authenticated;
grant select, insert, update, delete on public.stamps, public.user_meta, public.shares to authenticated;
grant select on public.ai_usage to authenticated;

create policy "stamps: owner reads"   on public.stamps for select to authenticated using (user_id = (select auth.uid()));
create policy "stamps: owner inserts" on public.stamps for insert to authenticated with check (user_id = (select auth.uid()));
create policy "stamps: owner updates" on public.stamps for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "stamps: owner deletes" on public.stamps for delete to authenticated using (user_id = (select auth.uid()));
create policy "meta: owner reads"   on public.user_meta for select to authenticated using (user_id = (select auth.uid()));
create policy "meta: owner inserts" on public.user_meta for insert to authenticated with check (user_id = (select auth.uid()));
create policy "meta: owner updates" on public.user_meta for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "meta: owner deletes" on public.user_meta for delete to authenticated using (user_id = (select auth.uid()));
create policy "shares: signed-in users read" on public.shares for select to authenticated using (true);
create policy "shares: author inserts" on public.shares for insert to authenticated with check (user_id = (select auth.uid()));
create policy "shares: author updates" on public.shares for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "shares: author deletes" on public.shares for delete to authenticated using (user_id = (select auth.uid()));
create policy "ai_usage: owner reads" on public.ai_usage for select to authenticated using (user_id = (select auth.uid()));

create or replace function public.ai_take(p_user uuid, p_limit int, p_global int) returns int
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date; g int; u int;
begin
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
create or replace function public.ai_refund(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date;
begin
  update public.ai_usage set count = greatest(count - 1, 0) where user_id = p_user and day = d;
  update public.ai_global set count = greatest(count - 1, 0) where day = d;
end $$;
revoke all on function public.ai_take(uuid, int, int) from public, anon, authenticated;
revoke all on function public.ai_refund(uuid) from public, anon, authenticated;
grant execute on function public.ai_take(uuid, int, int) to service_role;
grant execute on function public.ai_refund(uuid) to service_role;
revoke all on function public.touch_updated_at() from public, anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('cuts',   'cuts',   false, 2097152, array['image/png','image/webp','image/jpeg']),
  ('photos', 'photos', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "petalog files: owner reads" on storage.objects for select to authenticated
  using (bucket_id in ('cuts','photos') and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "petalog files: owner uploads" on storage.objects for insert to authenticated
  with check (bucket_id in ('cuts','photos') and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "petalog files: owner updates" on storage.objects for update to authenticated
  using (bucket_id in ('cuts','photos') and (storage.foldername(name))[1] = (select auth.uid()::text))
  with check (bucket_id in ('cuts','photos') and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "petalog files: owner deletes" on storage.objects for delete to authenticated
  using (bucket_id in ('cuts','photos') and (storage.foldername(name))[1] = (select auth.uid()::text));
