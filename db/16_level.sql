-- ============================================================================
-- 16_level.sql · С кем говорили: уровень контакта как отдельное измерение воронки
--
--   «Демо получил» и «На согласовании» ничего не говорят о том, кто на той стороне:
--   администратор, управляющий или собственник. Этап описывает сделку, а уровень
--   описывает человека. Два измерения хранятся раздельно и не смешиваются.
--
--   1. activities.spoke_with: с кем говорили в этом касании
--      ('admin', 'manager', 'owner'). Пусто, если не разговаривали.
--   2. log_touch с параметром spoke_with. with_dm выводится из него: управляющий
--      и собственник считаются ЛПР для метрики плана. Старая сигнатура удаляется.
--   3. v_leads получает колонку level: самый высокий уровень, до которого дошли
--      по этому лиду. Цепочка v_stats → v_today → v_leads пересобирается,
--      права выдаются заново, включая crm_readonly из 12_readonly.sql.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. С кем говорили
alter table activities add column if not exists spoke_with text
  check (spoke_with is null or spoke_with in ('admin','manager','owner'));

-- 2. log_touch со spoke_with
drop function if exists log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid,text);

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
  contact         jsonb   default null,
  script_id       uuid    default null,
  objection_id    uuid    default null,
  demo            text    default null,
  spoke_with      text    default null
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

  update leads l set
    status         = status,
    tariff         = tariff,
    next_action_at = next_action_at,
    next_action    = next_action,
    lost_reason    = lost_reason,
    owner_id       = case when l.owner_id is null and not is_admin() then me
                          else l.owner_id end
   where l.id = lead_id;

  -- Управляющий и собственник считаются ЛПР для метрики плана
  insert into activities (client_id, lead_id, channel, outcome, with_dm, comment,
                          script_id, objection_id, demo, spoke_with)
    values (client_id, lead_id, channel, outcome,
            coalesce(with_dm, false) or coalesce(spoke_with in ('manager','owner'), false),
            nullif(trim(coalesce(comment,'')), ''), script_id, objection_id, demo, spoke_with);

  select l.status into v_after from leads l where l.id = lead_id;
  return jsonb_build_object('lead_id', lead_id, 'status', v_after,
    'auto_closed', (v_after = 'lost' and status <> 'lost'), 'already', false);
exception
  when unique_violation then
    if exists (select 1 from activities a where a.client_id = client_id) then
      select l.status into v_after from leads l where l.id = lead_id;
      return jsonb_build_object('lead_id', lead_id, 'status', v_after,
                                'auto_closed', false, 'already', true);
    end if;
    raise;
end $$;

revoke all on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid,text,text)
  from public;
grant execute on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid,text,text)
  to authenticated;

-- 3. Представления: цепочка сносится в порядке зависимости и создаётся обратно.
--    Определение v_leads из 07_rpc.sql плюс колонка level.
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
),
-- До кого дошли: собственник выше управляющего, управляющий выше администратора
reach as (
  select lead_id, max(case spoke_with when 'owner' then 3 when 'manager' then 2 when 'admin' then 1 end) as lv
    from activities where spoke_with is not null group by lead_id
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
  case r.lv when 3 then 'owner' when 2 then 'manager' when 1 then 'admin' end as level,
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
left join touches t on t.lead_id = l.id
left join reach r on r.lead_id = l.id;

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

-- Права теряются вместе со старыми объектами: выдаём заново
grant select on v_leads, v_today, v_stats to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'crm_readonly') then
    grant select on v_leads to crm_readonly;
  end if;
end $$;

-- Контроль: колонка spoke_with, log_touch с 16 параметрами, level в v_leads,
-- три представления, грант crm_readonly на v_leads (1, если роль есть).
select
  (select count(*) from information_schema.columns
    where table_name = 'activities' and column_name = 'spoke_with') as spoke_with_1,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'log_touch' and p.pronargs = 16) as log_touch_1,
  (select count(*) from information_schema.columns
    where table_name = 'v_leads' and column_name = 'level') as level_1,
  (select count(*) from information_schema.views
    where table_schema = 'public' and table_name in ('v_leads','v_today','v_stats')) as views_3,
  (select count(*) from information_schema.role_table_grants
    where grantee = 'crm_readonly' and table_name = 'v_leads' and privilege_type = 'SELECT') as readonly_1;
