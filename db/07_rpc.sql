-- ============================================================================
-- 07_rpc.sql · Нулевой этап концепции 2.0: фундамент
--
-- Что делает:
--   1. activities.client_id — клиентский идентификатор касания. Повтор
--      «Сохранить» после обрыва связи не создаёт дубль.
--   2. activities.author_id по умолчанию = current_profile_id(): автора
--      ставит база, а не клиент.
--   3. today_msk() и пересборка представлений: день считается по
--      Europe/Moscow, а не по UTC. Касание в 23:30 остаётся в сегодня.
--   4. log_touch(...) — касание, контакт и смена статуса одной транзакцией.
--   5. create_lead(...) — компания, контакты и лид одной транзакцией.
--
-- Файл идемпотентен, выполняется в SQL Editor одной транзакцией: при ошибке
-- не применится ничего. Перед index.html версии 9: клиент вызывает
-- rest/v1/rpc/log_touch и rest/v1/rpc/create_lead, без этого файла лист
-- касания и добавление лида вернут ошибку 404.
--
-- Представления пересобираются по восстановленным определениям
-- (db/00_baseline.sql). Набор колонок — тот, что читает index.html.
-- ============================================================================

-- 1. Идентификатор касания от дублей
alter table activities add column if not exists client_id uuid;
create unique index if not exists activities_client_id on activities (client_id)
  where client_id is not null;

-- 2. Автора касания ставит база
alter table activities alter column author_id set default current_profile_id();

-- 3. День компании по московскому времени
create or replace function today_msk() returns date
language sql stable as $$
  select (now() at time zone 'Europe/Moscow')::date;
$$;
grant execute on function today_msk() to authenticated;

drop view if exists v_stats;
drop view if exists v_today;
drop view if exists v_leads;

create view v_leads with (security_invoker = true) as
with c_primary as (
  select company_id, phone_e164 from contacts where is_primary
),
c_dm as (
  select company_id, name, position, phone_e164 from contacts where is_decision_maker
),
touches as (
  select lead_id, count(*) as touch_count, max(created_at) as last_touch_at
    from activities where channel <> 'system' group by lead_id
)
select
  l.id, l.company_id, co.name as company_name, co.kind, co.segment, co.address,
  co.instagram_url, co.gis_url, co.site_url, co.outlets_count, co.avg_check,
  co.has_online_order, co.has_own_app, co.note, co.todo,
  l.status, l.owner_id, p.name as owner_name,
  (l.owner_id is not null and l.owner_id = current_profile_id()) as is_mine,
  l.tariff, l.setup_amount, l.mrr_amount,
  l.next_action_at, l.next_action, l.lost_reason,
  ( (cp.phone_e164 is not null)::int * 2
  + (dm.company_id is not null)::int * 2
  + (dm.phone_e164 is not null)::int
  + (co.instagram_url is not null)::int
  + (coalesce(co.outlets_count,0) >= 2)::int * 2
  + (coalesce(co.outlets_count,0) >= 5)::int
  + co.has_online_order::int * 2
  + (coalesce(co.avg_check,0) >= 800)::int
  + (not co.has_own_app)::int
  ) as score,
  coalesce(t.touch_count, 0) as touch_count, t.last_touch_at,
  cp.phone_e164 as primary_phone,
  dm.name as dm_name, dm.position as dm_position, dm.phone_e164 as dm_phone,
  round(l.setup_amount * 0.3) as stage1_amount,
  round(l.setup_amount * 0.3) as stage2_amount,
  l.setup_amount - 2 * round(l.setup_amount * 0.3) as stage3_amount,
  l.paid_1_at, l.paid_2_at, l.paid_3_at,
  coalesce(case when l.paid_1_at is not null then round(l.setup_amount * 0.3) end, 0)
  + coalesce(case when l.paid_2_at is not null then round(l.setup_amount * 0.3) end, 0)
  + coalesce(case when l.paid_3_at is not null
                  then l.setup_amount - 2 * round(l.setup_amount * 0.3) end, 0) as paid_total,
  l.created_at, l.updated_at
from leads l
join companies co on co.id = l.company_id
left join profiles p on p.id = l.owner_id
left join c_primary cp on cp.company_id = l.company_id
left join c_dm dm on dm.company_id = l.company_id
left join touches t on t.lead_id = l.id;

create view v_today with (security_invoker = true) as
select * from v_leads
 where status not in ('new','won','lost')
   and owner_id = current_profile_id()
   and next_action_at <= today_msk()
 order by next_action_at asc, score desc;

create view v_stats with (security_invoker = true) as
select
  count(*) filter (where next_action_at < today_msk())  as overdue,
  count(*) filter (where next_action_at = today_msk())  as due_today,
  (select count(*) from v_leads where status = 'new' and owner_id is null) as cold_pool,
  (select coalesce(sum(mrr_amount), 0) from v_leads
    where owner_id = current_profile_id()
      and status in ('proposal_sent','negotiation'))     as pipeline_mrr
from v_today;

grant select on v_leads, v_today, v_stats to authenticated;

-- ---------------------------------------------------------------------------
-- 4. log_touch: касание одной транзакцией.
--    Порядок: контакт → лид (статус, тариф, следующий шаг, ответственный) →
--    запись в журнал. Если пятый недозвон подряд закрыл лид триггером,
--    в ответе auto_closed = true. Повторный вызов с тем же client_id
--    ничего не делает и возвращает already = true.
--    security invoker: работают все политики RLS и триггеры.
-- ---------------------------------------------------------------------------
create or replace function log_touch(
  client_id       uuid,
  lead_id         uuid,
  channel         text,
  outcome         text,
  status          text,
  with_dm         boolean default false,
  comment         text    default null,
  next_action_at  date    default null,
  next_action     text    default null,
  lost_reason     text    default null,
  tariff          text    default null,
  contact         jsonb   default null
) returns jsonb
language plpgsql security invoker set search_path = public as $$
#variable_conflict use_variable
declare
  me          uuid := current_profile_id();
  v_company   uuid;
  v_before    text;
  v_after     text;
  c_name      text := nullif(trim(coalesce(contact->>'name','')), '');
  c_position  text := nullif(trim(coalesce(contact->>'position','')), '');
  c_phone     text := nullif(trim(coalesce(contact->>'phone','')), '');
  c_raw       text := nullif(trim(coalesce(contact->>'phone_raw','')), '');
  c_dm        boolean := coalesce((contact->>'dm')::boolean, false);
  c_target    uuid;
begin
  if client_id is null then
    raise exception 'Нет идентификатора касания' using errcode = 'check_violation';
  end if;

  -- Повтор после обрыва связи: касание уже записано
  if exists (select 1 from activities a where a.client_id = client_id) then
    select l.status into v_after from leads l where l.id = lead_id;
    return jsonb_build_object('lead_id', lead_id, 'status', v_after,
                              'auto_closed', false, 'already', true);
  end if;

  select l.company_id, l.status into v_company, v_before
    from leads l where l.id = lead_id for update;
  if v_company is null then
    raise exception 'Лид не найден' using errcode = 'no_data_found';
  end if;

  -- Контакт, узнанный на этом звонке. Совпадение ищем по номеру.
  if c_name is not null or c_position is not null or c_phone is not null then
    if c_phone is not null then
      select c.id into c_target from contacts c
       where c.company_id = v_company and c.phone_e164 = c_phone limit 1;
    end if;
    if c_dm then
      update contacts c set is_decision_maker = false
       where c.company_id = v_company and c.is_decision_maker
         and c.id is distinct from c_target;
    end if;
    if c_target is not null then
      update contacts c set
        name = c_name, position = c_position, is_decision_maker = c_dm,
        phone_e164 = coalesce(c_phone, c.phone_e164),
        phone_raw  = case when c_phone is null then c.phone_raw else c_raw end
       where c.id = c_target;
    else
      insert into contacts (company_id, name, position, is_decision_maker, phone_e164, phone_raw)
        values (v_company, c_name, c_position, c_dm, c_phone, c_raw);
    end if;
  end if;

  -- Лид. Взял ничейный лид в работу — он твой. Остальное проверят триггеры.
  update leads l set
    status         = status,
    tariff         = tariff,
    next_action_at = next_action_at,
    next_action    = next_action,
    lost_reason    = lost_reason,
    owner_id       = case when l.owner_id is null and not is_admin() then me
                          else l.owner_id end
   where l.id = lead_id;

  insert into activities (client_id, lead_id, channel, outcome, with_dm, comment)
    values (client_id, lead_id, channel, outcome, coalesce(with_dm, false),
            nullif(trim(coalesce(comment,'')), ''));

  select l.status into v_after from leads l where l.id = lead_id;
  return jsonb_build_object('lead_id', lead_id, 'status', v_after,
    'auto_closed', (v_after = 'lost' and status <> 'lost'), 'already', false);
exception
  when unique_violation then
    -- Два одинаковых запроса пришли одновременно: второй проиграл гонку
    if exists (select 1 from activities a where a.client_id = client_id) then
      select l.status into v_after from leads l where l.id = lead_id;
      return jsonb_build_object('lead_id', lead_id, 'status', v_after,
                                'auto_closed', false, 'already', true);
    end if;
    raise;
end $$;

-- ---------------------------------------------------------------------------
-- 5. create_lead: компания, основной номер, ЛПР и лид одной транзакцией.
--    company: name, kind, segment, address, instagram_url, gis_url, site_url,
--             outlets_count, avg_check, has_online_order, has_own_app, note, todo
--    dm: name, position, phone, phone_raw. Если номер ЛПР совпадает с основным,
--        второй контакт не создаётся: ЛПР помечается основной.
--    take = false: лид в общий пул без ответственного (импорт).
--    Дубль названия вернёт unique_violation, как и раньше.
-- ---------------------------------------------------------------------------
create or replace function create_lead(
  company    jsonb,
  phone      text    default null,
  phone_raw  text    default null,
  dm         jsonb   default null,
  take       boolean default true
) returns uuid
language plpgsql security invoker set search_path = public as $$
#variable_conflict use_variable
declare
  me         uuid := current_profile_id();
  v_company  uuid;
  v_lead     uuid;
  v_primary  uuid;
  d_name     text := nullif(trim(coalesce(dm->>'name','')), '');
  d_position text := nullif(trim(coalesce(dm->>'position','')), '');
  d_phone    text := nullif(trim(coalesce(dm->>'phone','')), '');
  d_raw      text := nullif(trim(coalesce(dm->>'phone_raw','')), '');
begin
  if nullif(trim(coalesce(company->>'name','')), '') is null then
    raise exception 'Впиши название' using errcode = 'check_violation';
  end if;

  insert into companies (name, kind, segment, address, instagram_url, gis_url, site_url,
    outlets_count, avg_check, has_online_order, has_own_app, note, todo, created_by)
  values (
    trim(company->>'name'),
    coalesce(nullif(company->>'kind',''), 'lead'),
    nullif(company->>'segment',''), nullif(company->>'address',''),
    nullif(company->>'instagram_url',''), nullif(company->>'gis_url',''),
    nullif(company->>'site_url',''),
    (nullif(company->>'outlets_count',''))::int,
    (nullif(company->>'avg_check',''))::numeric,
    coalesce((company->>'has_online_order')::boolean, false),
    coalesce((company->>'has_own_app')::boolean, false),
    nullif(company->>'note',''), nullif(company->>'todo',''), me)
  returning id into v_company;

  if phone is not null then
    insert into contacts (company_id, phone_e164, phone_raw, is_primary)
      values (v_company, phone, phone_raw, true) returning id into v_primary;
  end if;

  if d_name is not null or d_position is not null or d_phone is not null then
    if d_phone is not null and d_phone = phone then
      update contacts c set name = d_name, position = d_position, is_decision_maker = true
       where c.id = v_primary;
    else
      insert into contacts (company_id, name, position, phone_e164, phone_raw, is_decision_maker)
        values (v_company, d_name, d_position, d_phone, d_raw, true);
    end if;
  end if;

  insert into leads (company_id, status, owner_id)
    values (v_company, 'new', case when take then me end)
  returning id into v_lead;
  return v_lead;
end $$;

revoke all on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb)
  from public;
revoke all on function create_lead(jsonb,text,text,jsonb,boolean) from public;
grant execute on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb)
  to authenticated;
grant execute on function create_lead(jsonb,text,text,jsonb,boolean) to authenticated;

-- Контроль: колонка client_id есть, обе функции на месте, три представления,
-- у представлений security_invoker.
select
  (select count(*) from information_schema.columns
    where table_name = 'activities' and column_name = 'client_id') as client_id_1,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('log_touch','create_lead')) as functions_2,
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and c.relname in ('v_leads','v_today','v_stats')
      and 'security_invoker=true' = any (c.reloptions)) as invoker_views_3;
