-- ============================================================================
-- 18_settings.sql · Настройки админа: воронка, причины отказа, тарифы, форма касания
--
--   Раньше этапы, причины отказа и форма касания были зашиты в код и в
--   ограничения таблиц: чтобы переименовать этап или добавить причину,
--   нужно было править index.html и SQL. Теперь это справочники, админ
--   правит их с телефона в «Настройках».
--
--   1. stages: этапы воронки. Название, порядок, видимость, «в работе» для
--      суммы MRR, какой скрипт открывать на этом этапе. Свои этапы можно
--      добавлять. Коды восьми старых этапов неизменны: на них завязаны
--      триггеры и план (демо, цена). Переименовать можно, удалить нельзя.
--      new, no_answer, won, lost нельзя и выключить.
--   2. lost_reasons: причины отказа, так же. unreachable ставит сама база
--      после пяти недозвонов, поэтому она системная.
--   3. Ограничения check на leads.status и leads.lost_reason заменяются
--      внешними ключами на справочники. Имена check в живой базе неизвестны
--      (00_baseline восстановлен по клиенту), поэтому ищем их по тексту.
--   4. tariffs.active: старый тариф можно выключить, не ломая сделки.
--   5. app_settings: настройки формы касания (какие блоки показывать,
--      подписи, порядок, чипы дат). Пусто — клиент берёт значения по умолчанию.
--   6. v_stats: MRR в работе считается по флагу этапа, а не по двум кодам.
--      Меняется только v_stats — от неё ничего не зависит, v_today и v_leads
--      не пересоздаются. Права выдаются заново.
--
-- Правила leads_guard не меняются: свой этап, как и любой открытый,
-- не сохраняется без даты следующего шага.
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Этапы воронки
create table if not exists stages (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]{1,31}$'),
  title         text not null check (length(trim(title)) > 0),
  sort_order    int not null default 0,
  active        boolean not null default true,
  system        boolean not null default false,
  in_pipeline   boolean not null default false,
  script_stage  text check (script_stage is null or script_stage in
                  ('first_call','gatekeeper','brief','after_proposal','closing','callback'))
);

alter table stages enable row level security;
drop policy if exists stages_select on stages;
create policy stages_select on stages for select to authenticated using (is_staff());
drop policy if exists stages_admin on stages;
create policy stages_admin on stages for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on stages to authenticated;

insert into stages (code, title, sort_order, system, in_pipeline, script_stage) values
  ('new',           'Новый',              10, true, false, 'first_call'),
  ('no_answer',     'Не дозвонился',      20, true, false, 'callback'),
  ('contacted',     'Контакт установлен', 30, true, false, 'first_call'),
  ('brief_done',    'Демо получил',       40, true, false, 'brief'),
  ('proposal_sent', 'Цена названа',       50, true, true,  'after_proposal'),
  ('negotiation',   'На согласовании',    60, true, true,  'closing'),
  ('won',           'Клиент',             70, true, false, 'closing'),
  ('lost',          'Отказ',              80, true, false, null)
on conflict (code) do nothing;

-- 2. Причины отказа
create table if not exists lost_reasons (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{1,31}$'),
  title       text not null check (length(trim(title)) > 0),
  sort_order  int not null default 0,
  active      boolean not null default true,
  system      boolean not null default false
);

alter table lost_reasons enable row level security;
drop policy if exists lost_reasons_select on lost_reasons;
create policy lost_reasons_select on lost_reasons for select to authenticated using (is_staff());
drop policy if exists lost_reasons_admin on lost_reasons;
create policy lost_reasons_admin on lost_reasons for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on lost_reasons to authenticated;

insert into lost_reasons (code, title, sort_order, system) values
  ('price',        'Дорого',             10, true),
  ('no_need',      'Нет потребности',    20, true),
  ('has_solution', 'Есть своё решение',  30, true),
  ('unreachable',  'Не дозвонились',     40, true),
  ('not_target',   'Не наш сегмент',     50, true),
  ('other',        'Другое',             60, true)
on conflict (code) do nothing;

-- Системные строки: код неизменен, удалить нельзя. Своё значение нельзя
-- удалить, если оно уже встречалось в журнале: история потеряла бы подпись.
create or replace function dict_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.system := false;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.system then
      raise exception 'Системное значение нельзя удалить, только переименовать'
        using errcode = 'check_violation';
    end if;
    if tg_table_name = 'stages' and exists (select 1 from activities a
         where a.status_to = old.code or a.status_from = old.code) then
      raise exception 'Этап уже есть в журнале касаний. Его можно выключить, но не удалить'
        using errcode = 'check_violation';
    end if;
    return old;
  end if;
  new.system := old.system;
  if old.system and new.code <> old.code then
    raise exception 'Код системного значения менять нельзя' using errcode = 'check_violation';
  end if;
  if tg_table_name = 'stages' and not new.active
     and old.code in ('new','no_answer','won','lost') then
    raise exception 'Этап «%» нужен базе, его нельзя выключить', old.title
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists stages_guard on stages;
create trigger stages_guard before insert or update or delete on stages
  for each row execute function dict_guard();
drop trigger if exists lost_reasons_guard on lost_reasons;
create trigger lost_reasons_guard before insert or update or delete on lost_reasons
  for each row execute function dict_guard();

-- 3. Check на статус и причину отказа заменяем внешними ключами
do $$
declare r record;
begin
  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.conrelid = 'leads'::regclass and c.contype = 'c'
  loop
    if (r.def ~ '\mstatus\M' and r.def ~ 'brief_done')
       or (r.def ~ 'lost_reason' and r.def ~ 'has_solution') then
      execute format('alter table leads drop constraint %I', r.conname);
      raise notice 'снято ограничение %', r.conname;
    end if;
  end loop;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'leads'::regclass and conname = 'leads_status_fk') then
    alter table leads add constraint leads_status_fk
      foreign key (status) references stages(code) on update cascade;
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'leads'::regclass and conname = 'leads_lost_reason_fk') then
    alter table leads add constraint leads_lost_reason_fk
      foreign key (lost_reason) references lost_reasons(code) on update cascade;
  end if;
end $$;

-- 4. Тариф можно выключить: он пропадает из выбора, сделки на нём остаются
alter table tariffs add column if not exists active boolean not null default true;

-- 5. Настройки клиента
create table if not exists app_settings (
  key         text primary key,
  value       jsonb not null,
  updated_by  uuid references profiles(id) on delete set null,
  updated_at  timestamptz not null default now()
);

alter table app_settings enable row level security;
drop policy if exists app_settings_select on app_settings;
create policy app_settings_select on app_settings for select to authenticated using (is_staff());
drop policy if exists app_settings_admin on app_settings;
create policy app_settings_admin on app_settings for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on app_settings to authenticated;

create or replace function app_settings_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := current_profile_id();
  return new;
end $$;
drop trigger if exists app_settings_touch on app_settings;
create trigger app_settings_touch before insert or update on app_settings
  for each row execute function app_settings_touch();

-- 6. v_stats: MRR в работе по флагу этапа. Зависимых объектов у v_stats нет.
drop view if exists v_stats;
create view v_stats with (security_invoker = true) as
select
  count(*) filter (where next_action_at < today_msk())  as overdue,
  count(*) filter (where next_action_at = today_msk())  as due_today,
  (select count(*) from v_leads where status = 'new' and owner_id is null) as cold_pool,
  (select coalesce(sum(v.mrr_amount), 0) from v_leads v
     join stages s on s.code = v.status
    where v.owner_id = current_profile_id() and s.in_pipeline) as pipeline_mrr
from v_today;

grant select on v_leads, v_today, v_stats to authenticated;

-- Внешнее чтение (12, 17): справочники и v_stats видны, писать нельзя
do $$
declare t text;
begin
  if exists (select 1 from pg_roles where rolname = 'crm_readonly') then
    grant select on v_stats to crm_readonly;
    foreach t in array array['stages','lost_reasons','app_settings'] loop
      execute format('grant select on %I to crm_readonly', t);
      execute format('drop policy if exists %I on %I', t||'_ext_read', t);
      execute format('create policy %I on %I for select to crm_readonly using (true)', t||'_ext_read', t);
    end loop;
  end if;
end $$;

-- Контроль: 8 системных этапов, 6 причин, внешние ключи 2, колонка active
-- у тарифов, таблица настроек, check на статус снят.
select
  (select count(*) from stages where system) as system_stages_8,
  (select count(*) from lost_reasons where system) as system_reasons_6,
  (select count(*) from pg_constraint where conrelid = 'leads'::regclass
     and conname in ('leads_status_fk','leads_lost_reason_fk')) as fks_2,
  (select count(*) from information_schema.columns
    where table_name = 'tariffs' and column_name = 'active') as tariff_active_1,
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_name = 'app_settings') as settings_1,
  (select count(*) from pg_constraint where conrelid = 'leads'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ~ 'brief_done') as status_check_0;
