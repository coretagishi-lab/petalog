-- プチ情報を持ち主の訂正（ヒント）で書き直したときの記録
alter table public.trivia add column if not exists hint text not null default '';
alter table public.trivia add column if not exists fixed_by uuid references auth.users(id) on delete set null;
create index if not exists trivia_fixed_by_idx on public.trivia (fixed_by);
