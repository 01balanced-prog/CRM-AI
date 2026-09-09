-- ============================================================================
-- Balance CRM · базовая схема (00_baseline.sql)
--
-- ВНИМАНИЕ. Этот файл НЕ выгружен из Supabase, а ВОССТАНОВЛЕН по коду клиента
-- (index.html), README и AGENTS.md: какие таблицы, колонки, представления и
-- правила приложение ожидает от базы. Живая база уже содержит всё это (её
-- создавали файлы 01–06, которых в репозитории нет). Поэтому:
--
--   • В ЖИВУЮ БАЗУ ЭТОТ ФАЙЛ НЕ ЗАПУСКАТЬ. Он нужен, чтобы поднять копию на
--     локальном Postgres и проверять на ней следующие миграции (07 и дальше).
--   • Как сверить его с живой базой и когда заменить настоящей выгрузкой —
--     в db/README.md.
--
-- Файл идемпотентен: его можно выполнять повторно на пустой или уже
-- собранной по нему базе. Предполагает окружение Supabase: схема auth
-- с таблицей auth.users и функцией auth.uid(), роль authenticated.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Таблицы
-- ---------------------------------------------------------------------------

-- Сотрудник. Доступ к CRM даёт наличие строки здесь, а не сама авторизация.
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  role        text not null default 'manager' check (role in ('admin','manager')),
  created_at  timestamptz not null default now()
);

-- Тарифы: единственный источник сумм внедрения и подписки.
create table if not exists tariffs (
  code          text primary key,
  title         text not null,
  setup_amount  numeric(12,0) not null check (setup_amount >= 0),
  mrr_amount    numeric(12,0) not null check (mrr_amount >= 0),
  sort_order    int not null default 0
);

-- Компания (заведение). Лид ссылается на компанию, контакты тоже.
create table if not exists companies (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  kind              text not null default 'lead' check (kind in ('lead','channel')),
  segment           text,
  address           text,
  instagram_url     text,
  gis_url           text,
  site_url          text,
  outlets_count     int check (outlets_count is null or outlets_count >= 0),
  avg_check         numeric(12,0) check (avg_check is null or avg_check >= 0),
  has_online_order  boolean not null default false,
  has_own_app       boolean not null default false,
  note              text,
  todo              text,
  created_by        uuid references profiles(id) on delete set null,
  created_at        timestamptz not null default now()
);
-- Дубли по названию: клиент сверяет импорт по lower(trim(name)).
create unique index if not exists companies_name_key on companies (lower(trim(name)));

-- Контакты компании. Основной номер (is_primary) и ЛПР (is_decision_maker).
create table if not exists contacts (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references companies(id) on delete cascade,
  name               text,
  position           text,
  phone_e164         text check (phone_e164 is null or phone_e164 ~ '^\+7\d{10}$'),
  phone_raw          text,
  is_primary         boolean not null default false,
  is_decision_maker  boolean not null default false,
  created_at         timestamptz not null default now()
);
-- Один ЛПР на компанию, один основной номер на компанию.
create unique index if not exists contacts_one_dm on contacts (company_id) where is_decision_maker;
create unique index if not exists contacts_one_primary on contacts (company_id) where is_primary;
create index if not exists contacts_company on contacts (company_id);

-- Лид (сделка). Суммы считаются триггером из тарифа, руками не вводятся.
create table if not exists leads (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references companies(id) on delete cascade,
  status          text not null default 'new' check (status in
                    ('new','no_answer','contacted','brief_done','proposal_sent',
                     'negotiation','won','lost')),
  owner_id        uuid references profiles(id) on delete set null,
  tariff          text references tariffs(code),
  setup_amount    numeric(12,0),
  mrr_amount      numeric(12,0),
  next_action_at  date,
  next_action     text,
  lost_reason     text check (lost_reason is null or lost_reason in
                    ('price','no_need','has_solution','unreachable','not_target','other')),
  paid_1_at       timestamptz,
  paid_2_at       timestamptz,
  paid_3_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
-- Одна открытая сделка на компанию.
create unique index if not exists leads_one_open on leads (company_id)
  where status not in ('won','lost');
create index if not exists leads_owner on leads (owner_id);
create index if not exists leads_next on leads (next_action_at);

-- Ручной прайс. Только админ. Перекрывает тариф для конкретного лида.
-- В живой базе этой таблицы нет: она описана в AGENTS.md как способ дать
-- ручную цену, но так и не была заведена, и клиент к ней не обращается
-- ни разу. Здесь оставлена как часть задуманной схемы — при подъёме копии
-- на локальном Postgres мешать не будет. Миграции, которые её касаются,
-- обязаны проверять наличие: db/17_readonly_full.sql так и делает.
create table if not exists custom_pricing (
  lead_id       uuid primary key references leads(id) on delete cascade,
  setup_amount  numeric(12,0) not null check (setup_amount >= 0),
  mrr_amount    numeric(12,0) not null check (mrr_amount >= 0),
  set_by        uuid references profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);

-- Журнал касаний. Неизменяем: ни update, ни delete (политик нет + триггер).
-- Смена статуса и отметка оплаты пишутся сюда триггером с каналом system.
create table if not exists activities (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references leads(id) on delete cascade,
  author_id    uuid references profiles(id) on delete set null,
  channel      text not null check (channel in
                 ('call','whatsapp','instagram','meeting','other','system')),
  outcome      text check (outcome is null or outcome in
                 ('answered','no_answer','callback','refused','sent','other')),
  with_dm      boolean not null default false,
  comment      text,
  status_from  text,
  status_to    text,
  created_at   timestamptz not null default now()
);
create index if not exists activities_lead on activities (lead_id, created_at desc);
create index if not exists activities_created on activities (created_at);

-- ---------------------------------------------------------------------------
-- 2. Функции доступа. security definer: читают profiles в обход RLS,
--    чтобы политики могли на них опираться без рекурсии.
-- ---------------------------------------------------------------------------

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid());
$$;

create or replace function current_profile_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from profiles where id = auth.uid();
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- Календарный день компании. Грозный живёт по московскому времени.
create or replace function today_msk() returns date
language sql stable as $$
  select (now() at time zone 'Europe/Moscow')::date;
$$;

-- ---------------------------------------------------------------------------
-- 3. Триггеры с бизнес-правилами
-- ---------------------------------------------------------------------------

-- Суммы лида: из custom_pricing, иначе из тарифа. Руками менять нельзя.
create or replace function leads_pricing() returns trigger
language plpgsql as $$
declare
  v_setup numeric; v_mrr numeric;
begin
  if tg_op = 'INSERT' then
    if new.setup_amount is not null or new.mrr_amount is not null then
      raise exception 'Суммы считаются из тарифа, руками не вводятся'
        using errcode = 'check_violation';
    end if;
  elsif new.setup_amount is distinct from old.setup_amount
     or new.mrr_amount   is distinct from old.mrr_amount then
    raise exception 'Суммы считаются из тарифа, руками не вводятся'
      using errcode = 'check_violation';
  end if;

  select cp.setup_amount, cp.mrr_amount into v_setup, v_mrr
    from custom_pricing cp where cp.lead_id = new.id;
  if not found and new.tariff is not null then
    select t.setup_amount, t.mrr_amount into v_setup, v_mrr
      from tariffs t where t.code = new.tariff;
  end if;
  new.setup_amount := v_setup;
  new.mrr_amount   := v_mrr;
  return new;
end $$;

drop trigger if exists leads_pricing on leads;
create trigger leads_pricing before insert or update on leads
  for each row execute function leads_pricing();

-- Правила статуса и ответственного.
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

  new.updated_at := now();
  return new;
end $$;

drop trigger if exists leads_guard on leads;
create trigger leads_guard before insert or update on leads
  for each row execute function leads_guard();

-- Смена статуса и отметки оплаты сами пишутся в журнал.
create or replace function leads_log() returns trigger
language plpgsql as $$
declare
  n int; note text;
begin
  if new.status is distinct from old.status then
    insert into activities (lead_id, author_id, channel, status_from, status_to)
      values (new.id, current_profile_id(), 'system', old.status, new.status);
  end if;
  foreach n in array array[1,2,3] loop
    if (case n when 1 then new.paid_1_at when 2 then new.paid_2_at else new.paid_3_at end)
       is distinct from
       (case n when 1 then old.paid_1_at when 2 then old.paid_2_at else old.paid_3_at end) then
      note := case when (case n when 1 then new.paid_1_at when 2 then new.paid_2_at
                              else new.paid_3_at end) is null
                   then format('Отметка об оплате этапа %s снята', n)
                   else format('Оплата этапа %s отмечена', n) end;
      insert into activities (lead_id, author_id, channel, status_from, status_to, comment)
        values (new.id, current_profile_id(), 'system', new.status, new.status, note);
    end if;
  end loop;
  return null;
end $$;

drop trigger if exists leads_log on leads;
create trigger leads_log after update on leads
  for each row execute function leads_log();

-- Ручной прайс изменился — пересчитать суммы лида (триггер leads_pricing).
create or replace function custom_pricing_apply() returns trigger
language plpgsql as $$
begin
  update leads set tariff = tariff where id = coalesce(new.lead_id, old.lead_id);
  return null;
end $$;

drop trigger if exists custom_pricing_apply on custom_pricing;
create trigger custom_pricing_apply after insert or update or delete on custom_pricing
  for each row execute function custom_pricing_apply();

-- Журнал неизменяем. Прямой update/delete запрещён. Каскадное удаление вместе
-- с компанией приходит из триггера внешнего ключа, глубина тогда 2 — его пропускаем.
create or replace function activities_immutable() returns trigger
language plpgsql as $$
begin
  if pg_trigger_depth() <= 1 then
    raise exception 'Журнал касаний неизменяем' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists activities_immutable on activities;
create trigger activities_immutable before update or delete on activities
  for each row execute function activities_immutable();

-- Пять недозвонов подряд закрывают лид с причиной unreachable.
create or replace function activities_streak() returns trigger
language plpgsql as $$
declare
  streak int;
begin
  if new.channel = 'system' or new.outcome <> 'no_answer' then return null; end if;
  select count(*) into streak from (
    select outcome from activities
     where lead_id = new.lead_id and channel <> 'system'
     order by created_at desc, id desc limit 5
  ) last5 where outcome = 'no_answer';
  if streak >= 5 then
    update leads set status = 'lost', lost_reason = 'unreachable'
     where id = new.lead_id and status not in ('won','lost');
  end if;
  return null;
end $$;

drop trigger if exists activities_streak on activities;
create trigger activities_streak after insert on activities
  for each row execute function activities_streak();

-- ---------------------------------------------------------------------------
-- 4. RLS. Читает и пишет только сотрудник (is_staff()). Удаляет только админ.
-- ---------------------------------------------------------------------------

alter table profiles       enable row level security;
alter table tariffs        enable row level security;
alter table companies      enable row level security;
alter table contacts       enable row level security;
alter table leads          enable row level security;
alter table custom_pricing enable row level security;
alter table activities     enable row level security;

drop policy if exists profiles_select on profiles;
create policy profiles_select on profiles for select to authenticated using (is_staff());
drop policy if exists profiles_admin on profiles;
create policy profiles_admin on profiles for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists tariffs_select on tariffs;
create policy tariffs_select on tariffs for select to authenticated using (is_staff());
drop policy if exists tariffs_admin on tariffs;
create policy tariffs_admin on tariffs for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists companies_select on companies;
create policy companies_select on companies for select to authenticated using (is_staff());
drop policy if exists companies_insert on companies;
create policy companies_insert on companies for insert to authenticated with check (is_staff());
drop policy if exists companies_update on companies;
create policy companies_update on companies for update to authenticated
  using (is_staff()) with check (is_staff());
drop policy if exists companies_delete on companies;
create policy companies_delete on companies for delete to authenticated using (is_admin());

drop policy if exists contacts_select on contacts;
create policy contacts_select on contacts for select to authenticated using (is_staff());
drop policy if exists contacts_insert on contacts;
create policy contacts_insert on contacts for insert to authenticated with check (is_staff());
drop policy if exists contacts_update on contacts;
create policy contacts_update on contacts for update to authenticated
  using (is_staff()) with check (is_staff());
drop policy if exists contacts_delete on contacts;
create policy contacts_delete on contacts for delete to authenticated using (is_admin());

drop policy if exists leads_select on leads;
create policy leads_select on leads for select to authenticated using (is_staff());
drop policy if exists leads_insert on leads;
create policy leads_insert on leads for insert to authenticated with check (is_staff());
drop policy if exists leads_update on leads;
create policy leads_update on leads for update to authenticated
  using (is_staff()) with check (is_staff());
drop policy if exists leads_delete on leads;
create policy leads_delete on leads for delete to authenticated using (is_admin());

drop policy if exists custom_pricing_select on custom_pricing;
create policy custom_pricing_select on custom_pricing for select to authenticated using (is_staff());
drop policy if exists custom_pricing_admin on custom_pricing;
create policy custom_pricing_admin on custom_pricing for all to authenticated
  using (is_admin()) with check (is_admin());

-- Журнал: только чтение и вставка. Политик update/delete нет намеренно.
drop policy if exists activities_select on activities;
create policy activities_select on activities for select to authenticated using (is_staff());
drop policy if exists activities_insert on activities;
create policy activities_insert on activities for insert to authenticated with check (is_staff());

-- ---------------------------------------------------------------------------
-- 5. Представления. Цепочка зависимостей: v_stats → v_today → v_leads.
--    Сносим в этом порядке, создаём в обратном. Только security_invoker.
-- ---------------------------------------------------------------------------

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
  -- Приоритет от 0 до 13: чем полнее карточка и крупнее заведение, тем выше
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
  -- Этапы 30/30/40 от суммы внедрения; третий — вычитанием, чтобы сумма сходилась до рубля
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

-- Очередь на сегодня: мои открытые лиды, у которых шаг назначен на сегодня или просрочен.
create view v_today with (security_invoker = true) as
select * from v_leads
 where status not in ('new','won','lost')
   and owner_id = current_profile_id()
   and next_action_at <= today_msk()
 order by next_action_at asc, score desc;

-- Сводка для экрана «Сегодня» текущего пользователя, одна строка.
create view v_stats with (security_invoker = true) as
select
  count(*) filter (where next_action_at < today_msk())  as overdue,
  count(*) filter (where next_action_at = today_msk())  as due_today,
  (select count(*) from v_leads where status = 'new' and owner_id is null) as cold_pool,
  (select coalesce(sum(mrr_amount), 0) from v_leads
    where owner_id = current_profile_id()
      and status in ('proposal_sent','negotiation'))     as pipeline_mrr
from v_today;

-- ---------------------------------------------------------------------------
-- 6. Права. Автоэкспорт новых таблиц в проекте выключен: без grant PostgREST
--    вернёт permission denied. После пересоздания представлений повторять.
-- ---------------------------------------------------------------------------

grant usage on schema public to authenticated;
grant select, insert, update, delete on profiles, tariffs, companies, contacts,
  leads, custom_pricing to authenticated;
grant select, insert on activities to authenticated;
grant select on v_leads, v_today, v_stats to authenticated;
grant execute on function is_staff(), current_profile_id(), is_admin(), today_msk()
  to authenticated;

-- ---------------------------------------------------------------------------
-- Контроль: 7 таблиц, 3 представления, 7 таблиц с RLS.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE'
      and table_name in ('profiles','tariffs','companies','contacts','leads',
                         'custom_pricing','activities')) as tables_7,
  (select count(*) from information_schema.views
    where table_schema = 'public'
      and table_name in ('v_leads','v_today','v_stats')) as views_3,
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity) as rls_7;
