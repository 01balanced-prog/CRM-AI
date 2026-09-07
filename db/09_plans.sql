-- ============================================================================
-- 09_plans.sql · Этап 2: план и разгон новичка
--
--   1. plan_defaults: нормы по умолчанию, одна строка.
--   2. ramp_steps: разгон, процент по номеру недели с profiles.started_at.
--   3. plans: личный план сотрудника на месяц. Если задан, нормы и разгон
--      не участвуют.
--   4. effective_plan(profile, day): план сотрудника на дату с учётом трёх
--      слоёв. Все экраны спрашивают только её.
--   5. leads.owner_since: когда появился ответственный (метрика «взял в работу»).
--   6. v_kpi_day / v_kpi_week / v_kpi_month: факт по сотруднику и периоду,
--      день по Europe/Moscow. v_plan_today: план и факт текущего пользователя
--      одной строкой. v_team_today: то же по всем активным сотрудникам.
--   7. plan_streak(profile): сколько дней подряд до вчера закрыта норма звонков.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Нормы по умолчанию
create table if not exists plan_defaults (
  id              boolean primary key default true check (id),
  calls_day       int not null default 30 check (calls_day >= 0),
  talks_day       int not null default 10 check (talks_day >= 0),
  dm_talks_day    int not null default 3  check (dm_talks_day >= 0),
  briefs_week     int not null default 5  check (briefs_week >= 0),
  proposals_week  int not null default 3  check (proposals_week >= 0),
  won_month       int not null default 2  check (won_month >= 0),
  cash_month      numeric(12,0) not null default 100000 check (cash_month >= 0),
  updated_by      uuid references profiles(id) on delete set null,
  updated_at      timestamptz not null default now()
);
insert into plan_defaults (id) values (true) on conflict (id) do nothing;

-- 2. Разгон
create table if not exists ramp_steps (
  week  int primary key check (week >= 1),
  pct   int not null check (pct between 0 and 100)
);
insert into ramp_steps (week, pct) values (1,40),(2,60),(3,80),(4,100)
  on conflict (week) do nothing;

-- 3. Личный план на месяц
create table if not exists plans (
  id              uuid primary key default gen_random_uuid(),
  profile_id      uuid not null references profiles(id) on delete cascade,
  month           date not null check (month = date_trunc('month', month)::date),
  calls_day       int not null check (calls_day >= 0),
  talks_day       int not null check (talks_day >= 0),
  dm_talks_day    int not null check (dm_talks_day >= 0),
  briefs_week     int not null check (briefs_week >= 0),
  proposals_week  int not null check (proposals_week >= 0),
  won_month       int not null check (won_month >= 0),
  cash_month      numeric(12,0) not null check (cash_month >= 0),
  set_by          uuid references profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  unique (profile_id, month)
);

alter table plan_defaults enable row level security;
alter table ramp_steps    enable row level security;
alter table plans         enable row level security;

drop policy if exists plan_defaults_select on plan_defaults;
create policy plan_defaults_select on plan_defaults for select to authenticated using (is_staff());
drop policy if exists plan_defaults_admin on plan_defaults;
create policy plan_defaults_admin on plan_defaults for all to authenticated
  using (is_admin()) with check (is_admin());
drop policy if exists ramp_steps_select on ramp_steps;
create policy ramp_steps_select on ramp_steps for select to authenticated using (is_staff());
drop policy if exists ramp_steps_admin on ramp_steps;
create policy ramp_steps_admin on ramp_steps for all to authenticated
  using (is_admin()) with check (is_admin());
drop policy if exists plans_select on plans;
create policy plans_select on plans for select to authenticated using (is_staff());
drop policy if exists plans_admin on plans;
create policy plans_admin on plans for all to authenticated
  using (is_admin()) with check (is_admin());

grant select, insert, update, delete on plan_defaults, ramp_steps, plans to authenticated;

-- 4. План сотрудника на дату
create or replace function effective_plan(p_profile uuid, p_day date default today_msk())
returns table (
  calls_day int, talks_day int, dm_talks_day int, briefs_week int, proposals_week int,
  won_month int, cash_month numeric, week int, pct int, source text
)
language sql stable security invoker set search_path = public as $$
  with pr as (
    select started_at, ramp_enabled from profiles where id = p_profile
  ),
  w as (
    select case when pr.started_at is null or not pr.ramp_enabled then null
                else greatest(1, (p_day - pr.started_at) / 7 + 1) end as week
      from pr
  ),
  r as (
    select w.week,
           case when w.week is null then 100
                else coalesce((select rs.pct from ramp_steps rs
                                where rs.week <= w.week order by rs.week desc limit 1), 100) end as pct
      from w
  ),
  p as (
    select * from plans where profile_id = p_profile and month = date_trunc('month', p_day)::date
  ),
  d as (select * from plan_defaults)
  select
    coalesce(p.calls_day,      ceil(d.calls_day      * r.pct / 100.0)::int),
    coalesce(p.talks_day,      ceil(d.talks_day      * r.pct / 100.0)::int),
    coalesce(p.dm_talks_day,   ceil(d.dm_talks_day   * r.pct / 100.0)::int),
    coalesce(p.briefs_week,    ceil(d.briefs_week    * r.pct / 100.0)::int),
    coalesce(p.proposals_week, ceil(d.proposals_week * r.pct / 100.0)::int),
    coalesce(p.won_month,      ceil(d.won_month      * r.pct / 100.0)::int),
    coalesce(p.cash_month,     ceil(d.cash_month     * r.pct / 100.0)),
    r.week,
    case when p.id is not null then 100 else r.pct end,
    case when p.id is not null then 'personal'
         when r.week is not null and r.pct < 100 then 'ramp' else 'default' end
  from d cross join r left join p on true;
$$;
grant execute on function effective_plan(uuid, date) to authenticated;

-- 5. Когда у лида появился ответственный
alter table leads add column if not exists owner_since timestamptz;
update leads set owner_since = created_at where owner_id is not null and owner_since is null;

create or replace function leads_guard() returns trigger
language plpgsql as $$
declare
  me uuid := current_profile_id();
begin
  if new.status not in ('new','won','lost') and new.next_action_at is null then
    raise exception 'Для статуса «%» нужна дата следующего шага', new.status
      using errcode = 'check_violation';
  end if;
  if new.status = 'lost' and new.lost_reason is null then
    raise exception 'Отказ не сохраняется без причины' using errcode = 'check_violation';
  end if;
  if new.status <> 'lost' then new.lost_reason := null; end if;
  if new.status in ('new','won','lost') then
    new.next_action_at := null; new.next_action := null;
  end if;

  -- Менеджер может только взять ничейный лид себе. Переназначает админ.
  if tg_op = 'UPDATE' and new.owner_id is distinct from old.owner_id
     and not is_admin() then
    if old.owner_id is not null or new.owner_id is distinct from me then
      raise exception 'Переназначить ответственного может только администратор'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  if tg_op = 'INSERT' and new.owner_id is not null and new.owner_id <> me
     and not is_admin() then
    raise exception 'Ответственным можно назначить только себя'
      using errcode = 'insufficient_privilege';
  end if;

  -- Дата, когда лид взяли в работу: для метрики «взял»
  if new.owner_id is null then
    new.owner_since := null;
  elsif tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id then
    new.owner_since := now();
  end if;

  new.updated_at := now();
  return new;
end $$;

-- 6. Факт по сотруднику и периоду. День по Москве.
create or replace function msk_day(ts timestamptz) returns date
language sql immutable as $$ select (ts at time zone 'Europe/Moscow')::date $$;
grant execute on function msk_day(timestamptz) to authenticated;

drop view if exists v_plan_today;
drop view if exists v_team_today;
drop view if exists v_kpi_month;
drop view if exists v_kpi_week;
drop view if exists v_kpi_day;

create view v_kpi_day with (security_invoker = true) as
with t as (
  select author_id as profile_id, msk_day(created_at) as day,
    count(*) filter (where channel = 'call' and outcome in ('answered','no_answer')) as calls,
    count(*) filter (where channel <> 'system' and outcome = 'answered')            as talks,
    count(*) filter (where channel <> 'system' and with_dm)                         as dm_talks
  from activities where author_id is not null group by 1, 2
),
k as (
  select owner_id as profile_id, msk_day(owner_since) as day, count(*) as taken
  from leads where owner_id is not null and owner_since is not null group by 1, 2
)
select profile_id, day,
  coalesce(t.calls, 0)::int as calls, coalesce(t.talks, 0)::int as talks,
  coalesce(t.dm_talks, 0)::int as dm_talks, coalesce(k.taken, 0)::int as taken
from t full join k using (profile_id, day);

create view v_kpi_week with (security_invoker = true) as
select author_id as profile_id, date_trunc('week', msk_day(created_at))::date as week_start,
  count(*) filter (where status_to = 'brief_done')    ::int as briefs,
  count(*) filter (where status_to = 'proposal_sent') ::int as proposals
from activities
where channel = 'system' and author_id is not null
  and status_from is distinct from status_to   -- отметки оплаты статус не меняют
group by 1, 2;

create view v_kpi_month with (security_invoker = true) as
with w as (
  select author_id as profile_id, date_trunc('month', msk_day(created_at))::date as month,
         count(*)::int as won
  from activities
  where channel = 'system' and status_to = 'won' and author_id is not null
    and status_from is distinct from status_to
  group by 1, 2
),
c as (
  select l.owner_id as profile_id, date_trunc('month', msk_day(s.paid_at))::date as month,
         sum(s.amount) as cash
  from leads l
  cross join lateral (values
    (l.paid_1_at, round(l.setup_amount * 0.3)),
    (l.paid_2_at, round(l.setup_amount * 0.3)),
    (l.paid_3_at, l.setup_amount - 2 * round(l.setup_amount * 0.3))
  ) as s(paid_at, amount)
  where l.owner_id is not null and s.paid_at is not null and s.amount is not null
  group by 1, 2
)
select profile_id, month, coalesce(w.won, 0)::int as won, coalesce(c.cash, 0) as cash
from w full join c using (profile_id, month);

-- План и факт по всем активным сотрудникам на сегодня
create view v_team_today with (security_invoker = true) as
select p.id as profile_id, p.name, p.role, p.started_at, p.ramp_enabled,
  ep.calls_day, ep.talks_day, ep.dm_talks_day, ep.briefs_week, ep.proposals_week,
  ep.won_month, ep.cash_month, ep.week, ep.pct, ep.source,
  coalesce(d.calls, 0) as calls, coalesce(d.talks, 0) as talks,
  coalesce(d.dm_talks, 0) as dm_talks, coalesce(d.taken, 0) as taken,
  coalesce(w.briefs, 0) as briefs, coalesce(w.proposals, 0) as proposals,
  coalesce(m.won, 0) as won, coalesce(m.cash, 0) as cash
from profiles p
cross join lateral effective_plan(p.id, today_msk()) ep
left join v_kpi_day   d on d.profile_id = p.id and d.day = today_msk()
left join v_kpi_week  w on w.profile_id = p.id and w.week_start = date_trunc('week', today_msk())::date
left join v_kpi_month m on m.profile_id = p.id and m.month = date_trunc('month', today_msk())::date
where p.active;

-- План и факт текущего пользователя одной строкой
create view v_plan_today with (security_invoker = true) as
select * from v_team_today where profile_id = current_profile_id();

grant select on v_kpi_day, v_kpi_week, v_kpi_month, v_team_today, v_plan_today to authenticated;

-- 7. Серия: сколько дней подряд до вчера закрыта норма звонков (до 60)
create or replace function plan_streak(p_profile uuid default current_profile_id())
returns int
language plpgsql stable security invoker set search_path = public as $$
declare
  n int := 0;
  d date := today_msk() - 1;
  need int; have int;
begin
  loop
    exit when n >= 60;
    select calls_day into need from effective_plan(p_profile, d);
    if need is null or need = 0 then exit; end if;
    select coalesce(calls, 0) into have from v_kpi_day where profile_id = p_profile and day = d;
    exit when coalesce(have, 0) < need;
    n := n + 1; d := d - 1;
  end loop;
  return n;
end $$;
grant execute on function plan_streak(uuid) to authenticated;

-- Контроль: три таблицы, пять представлений, нормы по умолчанию есть.
select
  (select count(*) from information_schema.tables
    where table_schema = 'public'
      and table_name in ('plan_defaults','ramp_steps','plans')) as tables_3,
  (select count(*) from information_schema.views
    where table_schema = 'public'
      and table_name in ('v_kpi_day','v_kpi_week','v_kpi_month','v_team_today','v_plan_today')) as views_5,
  (select count(*) from plan_defaults) as defaults_1;
