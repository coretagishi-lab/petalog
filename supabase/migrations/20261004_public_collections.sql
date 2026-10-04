-- ぺたろぐ: みんなのコレクション（ランキング・公開トレカ・公開スタンプ帳）
-- 公開設定は user_meta の key='privacy'（{public, place, date, event, photo, memo}）。行が無い人は既定値（公開・場所/日付/イベント見せる・写真/メモ見せない）。
create or replace function public.pv_of(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('public', true, 'place', true, 'date', true, 'event', true, 'photo', false, 'memo', false)
    || coalesce((select m.data - 'kind' from public.user_meta m where m.user_id = p_user and m.key = 'privacy'), '{}'::jsonb)
$$;

create or replace function public.public_ranking()
returns table(user_id uuid, nick text, n int, thumbs text[])
language sql stable security definer set search_path = '' as $$
  with st as (
    select s.user_id, s.cut_path, coalesce(s.data->>'date', '') as d, s.updated_at
    from public.stamps s
    where (select auth.uid()) is not null
      and coalesce((public.pv_of(s.user_id)->>'public')::boolean, true)
      and coalesce((s.data->>'priv')::boolean, false) = false
  )
  select st.user_id,
         coalesce(nullif(p.data->>'nick', ''), '')::text,
         count(*)::int,
         (array_agg(st.cut_path order by st.d desc, st.updated_at desc) filter (where st.cut_path is not null))[1:4]
  from st left join public.user_meta p on p.user_id = st.user_id and p.key = 'profile'
  group by st.user_id, p.data
  order by 3 desc, max(st.updated_at) desc
  limit 200
$$;

create or replace function public.public_collection(p_user uuid)
returns table(id text, cut_path text, data jsonb)
language sql stable security definer set search_path = '' as $$
  with v as (select public.pv_of(p_user) as v)
  select s.id, s.cut_path, jsonb_strip_nulls(
      jsonb_build_object('name', s.data->'name', 'cat', s.data->'cat', 'medium', s.data->'medium', 'type', s.data->'type',
        'overlap', s.data->'overlap', 'multi', s.data->'multi', 'colors', s.data->'colors', 'shape', s.data->'shape',
        'cw', s.data->'cw', 'ch', s.data->'ch', 'corner', s.data->'corner', 'sizeMm', s.data->'sizeMm', 'created', s.data->'created',
        'nv', to_jsonb(coalesce(jsonb_array_length(case when jsonb_typeof(s.data->'visits') = 'array' then s.data->'visits' end), 0)))
      || case when (v.v->>'date')::boolean then jsonb_build_object('date', s.data->'date') else '{}'::jsonb end
      || case when (v.v->>'place')::boolean then jsonb_build_object('place', s.data->'place', 'pref', s.data->'pref', 'lat', s.data->'lat', 'lng', s.data->'lng') else '{}'::jsonb end
      || case when (v.v->>'event')::boolean then jsonb_build_object('event', s.data->'event', 'line', s.data->'line', 'rally', s.data->'rally') else '{}'::jsonb end
      || case when (v.v->>'memo')::boolean then jsonb_build_object('memo', s.data->'memo') else '{}'::jsonb end
      || case when (v.v->>'photo')::boolean then jsonb_build_object('hasPhoto', s.data->'hasPhoto', 'scenes', s.data->'scenes') else '{}'::jsonb end)
  from public.stamps s, v
  where (select auth.uid()) is not null and s.user_id = p_user
    and (v.v->>'public')::boolean
    and coalesce((s.data->>'priv')::boolean, false) = false
$$;

create or replace function public.public_books(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select m.data from public.user_meta m
  where (select auth.uid()) is not null and m.user_id = p_user and m.key = 'books'
    and (public.pv_of(p_user)->>'public')::boolean
$$;

-- files of public collections: cut images of public cards; page backgrounds; stamp photos only when "写真" is shown
create or replace function public.can_see_file(p_bucket text, p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare owner uuid; k text; v jsonb;
begin
  if (select auth.uid()) is null then return false; end if;
  begin owner := (storage.foldername(p_name))[1]::uuid; exception when others then return false; end;
  v := public.pv_of(owner);
  if not (v->>'public')::boolean then return false; end if;
  if p_bucket = 'cuts' then
    return exists (select 1 from public.stamps s where s.user_id = owner and s.cut_path = p_name and coalesce((s.data->>'priv')::boolean, false) = false);
  end if;
  if p_bucket = 'photos' then
    k := split_part(p_name, '/', 2);
    if k like 'bg\_%' then return true; end if;
    if not (v->>'photo')::boolean then return false; end if;
    return exists (select 1 from public.stamps s where s.user_id = owner and coalesce((s.data->>'priv')::boolean, false) = false
      and (k = ('ph_' || s.id) or k like ('sc\_' || s.id || '\_%')));
  end if;
  return false;
end $$;

create policy "petalog files: public collections" on storage.objects for select to authenticated
  using (bucket_id in ('cuts', 'photos') and public.can_see_file(bucket_id, name));

revoke all on function public.pv_of(uuid), public.can_see_file(text, text) from public, anon;
revoke all on function public.public_ranking(), public.public_collection(uuid), public.public_books(uuid) from public, anon;
grant execute on function public.public_ranking(), public.public_collection(uuid), public.public_books(uuid), public.can_see_file(text, text) to authenticated;
