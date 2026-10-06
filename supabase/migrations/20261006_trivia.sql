-- ぺたろぐ: 裏面のプチ情報（AI）。同じ場所・同じデザインのスタンプなら、みんなで同じ文章を使い回す
create table if not exists public.trivia (
  id bigint generated always as identity primary key,
  pkey text not null,                 -- 場所名（正規化）|都道府県
  dh text not null default '',        -- スタンプ画像の指紋（64ビットの差分ハッシュ、16進16桁）。近ければ同じデザイン
  lat double precision, lng double precision,
  name text not null default '', place text not null default '', pref text not null default '',
  text text not null check (char_length(text) between 1 and 600),
  motif text not null default '',
  model text not null default '',
  uses int not null default 1,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists trivia_pkey_idx on public.trivia (pkey);
create index if not exists trivia_ll_idx on public.trivia (lat, lng);
create index if not exists trivia_created_by_idx on public.trivia (created_by);
alter table public.trivia enable row level security;   -- 読み書きはサーバー（AI関数）だけ

-- プチ情報づくりの回数（AI推定とは別にかぞえる。アプリ全体の1日・1か月の上限はAI推定と共通）
create table if not exists public.trivia_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  count int not null default 0,
  primary key (user_id, day)
);
alter table public.trivia_usage enable row level security;

create or replace function public.trivia_take(p_user uuid, p_limit int, p_global int, p_month int) returns int
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date; m int; g int; u int;
begin
  select coalesce(sum(count), 0) into m from public.ai_global where day >= date_trunc('month', d)::date and day <= d;
  if m >= p_month then return -3; end if;
  insert into public.ai_global(day, count) values (d, 1)
    on conflict (day) do update set count = public.ai_global.count + 1 returning count into g;
  if g > p_global then update public.ai_global set count = count - 1 where day = d; return -2; end if;
  insert into public.trivia_usage(user_id, day, count) values (p_user, d, 1)
    on conflict (user_id, day) do update set count = public.trivia_usage.count + 1 returning count into u;
  if u > p_limit then
    update public.trivia_usage set count = count - 1 where user_id = p_user and day = d;
    update public.ai_global set count = count - 1 where day = d;
    return -1;
  end if;
  return p_limit - u;
end $$;

create or replace function public.trivia_refund(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date;
begin
  update public.trivia_usage set count = greatest(count - 1, 0) where user_id = p_user and day = d;
  update public.ai_global set count = greatest(count - 1, 0) where day = d;
end $$;

create or replace function public.trivia_used(p_id bigint) returns void
language sql security definer set search_path = '' as $$
  update public.trivia set uses = uses + 1, updated_at = now() where id = p_id;
$$;

revoke all on function public.trivia_take(uuid, int, int, int), public.trivia_refund(uuid), public.trivia_used(bigint) from public, anon, authenticated;
-- 公開設定を読むだけの内部用関数は、アプリから直接は呼ばせない（公開トレカの関数の中で使う）
revoke execute on function public.pv_of(uuid) from authenticated;
