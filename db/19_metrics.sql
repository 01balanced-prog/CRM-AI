-- ============================================================================
-- 19_metrics.sql · Каналы справочником, шаги воронки для отчёта, честный план
--
--   Отчёт показывал каналы, которых в форме касания не видно: канал сидел в
--   свёрнутом «Подробнее» и по умолчанию был «Звонок». Воронка и конверсия в
--   отчёте были зашиты кодами, свои этапы из «Настроек» туда не попадали.
--   Теперь отчёт строится из того же, что настроено.
--
--   1. channels: каналы связи справочником. Название, порядок, видимость и
--      вид: звонок, переписка, встреча. От вида зависят исходы в касании:
--      у переписки «Без ответа» вместо «Не взял», у встречи недозвона нет.
--      Звонок один, системный: по нему считается норма «Звонки». Свои каналы
--      бывают только перепиской или встречей (Telegram, почта, выезд).
--      other (заметка) и system (журнал) — служебные, в выборе их нет.
--   2. Ограничение check на activities.channel заменяется внешним ключом на
--      справочник. Имя check в живой базе неизвестно, ищем по тексту, как в 18.
--      Журнал не меняется: внешний ключ только проверяет новые записи.
--   3. stages.in_funnel: этап — шаг воронки, отчёт считает на нём конверсию.
--      Свой этап вроде «Вернуться в сезон» админ из конверсии убирает.
--      new, no_answer, lost шагами воронки не бывают.
--   4. v_kpi_day: «Звонки» — все звонки, а не только «Ответил» и «Не взял».
--      Раньше звонок, где попросили перезвонить или отказали, в норму не шёл.
--      «Разговоры» — «Ответил» и «Отказ»: отказ тоже разговор. Набор колонок
--      прежний, поэтому create or replace: зависимые v_team_today и
--      v_plan_today не пересоздаются, права остаются.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Каналы связи
create table if not exists channels (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{1,31}$'),
  title       text not null check (length(trim(title)) > 0),
  sort_order  int not null default 0,
  active      boolean not null default true,
  system      boolean not null default false,
  kind        text not null default 'message'
                check (kind in ('call','message','meeting','service'))
);

alter table channels enable row level security;
drop policy if exists channels_select on channels;
create policy channels_select on channels for select to authenticated using (is_staff());
drop policy if exists channels_admin on channels;
create policy channels_admin on channels for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on channels to authenticated;

-- Вставляем только недостающие: при повторном запуске строк нет, и защитный
-- триггер ниже не срабатывает на системных видах
insert into channels (code, title, sort_order, system, kind)
select v.* from (values
  ('call',      'Звонок',    10, true, 'call'),
  ('whatsapp',  'WhatsApp',  20, true, 'message'),
  ('instagram', 'Instagram', 30, true, 'message'),
  ('meeting',   'Встреча',   40, true, 'meeting'),
  ('other',     'Заметка',   90, true, 'service'),
  ('system',    'Система',   99, true, 'service')
) v(code, title, sort_order, system, kind)
where not exists (select 1 from channels c where c.code = v.code);

-- Системный канал нельзя удалить и сменить ему вид. Свой канал бывает только
-- перепиской или встречей: звонок один, по нему норма. Код не меняется никогда:
-- на него ссылается неизменяемый журнал.
create or replace function channels_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.system := false;
    if new.kind not in ('message','meeting') then
      raise exception 'Свой канал бывает перепиской или встречей' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.system then
      raise exception 'Стандартный канал нельзя удалить, только выключить'
        using errcode = 'check_violation';
    end if;
    if exists (select 1 from activities a where a.channel = old.code) then
      raise exception 'Канал уже есть в журнале касаний. Его можно выключить, но не удалить'
        using errcode = 'check_violation';
    end if;
    return old;
  end if;
  new.system := old.system;
  if new.code <> old.code then
    raise exception 'Код канала менять нельзя' using errcode = 'check_violation';
  end if;
  if old.system and new.kind <> old.kind then
    raise exception 'Вид стандартного канала менять нельзя' using errcode = 'check_violation';
  end if;
  if not old.system and new.kind not in ('message','meeting') then
    raise exception 'Свой канал бывает перепиской или встречей' using errcode = 'check_violation';
  end if;
  if old.kind = 'service' and not new.active then
    raise exception 'Служебный канал нужен базе' using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists channels_guard on channels;
create trigger channels_guard before insert or update or delete on channels
  for each row execute function channels_guard();

-- 2. Check на канал касания заменяем внешним ключом
do $$
declare r record;
begin
  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.conrelid = 'activities'::regclass and c.contype = 'c'
  loop
    if r.def ~ '\mchannel\M' and r.def ~ 'whatsapp' then
      execute format('alter table activities drop constraint %I', r.conname);
      raise notice 'снято ограничение %', r.conname;
    end if;
  end loop;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'activities'::regclass and conname = 'activities_channel_fk') then
    alter table activities add constraint activities_channel_fk
      foreign key (channel) references channels(code);
  end if;
end $$;

-- 3. Шаг воронки
alter table stages add column if not exists in_funnel boolean not null default true;
update stages set in_funnel = false
 where code in ('new','no_answer','lost') and in_funnel;

-- 4. Норма: звонок — любой исход звонка, разговор — «Ответил» или «Отказ»
create or replace view v_kpi_day with (security_invoker = true) as
with t as (
  select author_id as profile_id, msk_day(created_at) as day,
    count(*) filter (where channel = 'call'
                       and outcome in ('answered','no_answer','callback','refused'))  as calls,
    count(*) filter (where channel <> 'system' and outcome in ('answered','refused'))  as talks,
    count(*) filter (where channel <> 'system' and with_dm)                            as dm_talks
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

grant select on v_kpi_day to authenticated;

-- Внешнее чтение (12, 17): каналы видны, писать нельзя
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'crm_readonly') then
    grant select on channels, v_kpi_day to crm_readonly;
    drop policy if exists channels_ext_read on channels;
    create policy channels_ext_read on channels for select to crm_readonly using (true);
  end if;
end $$;

-- Контроль: 6 системных каналов, внешний ключ 1, check на канал снят,
-- колонка in_funnel, вне воронки ровно три системных этапа.
select
  (select count(*) from channels where system) as system_channels_6,
  (select count(*) from pg_constraint where conrelid = 'activities'::regclass
     and conname = 'activities_channel_fk') as channel_fk_1,
  (select count(*) from pg_constraint where conrelid = 'activities'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ~ 'whatsapp') as channel_check_0,
  (select count(*) from information_schema.columns
    where table_name = 'stages' and column_name = 'in_funnel') as in_funnel_1,
  (select count(*) from stages where code in ('new','no_answer','lost') and not in_funnel) as off_funnel_3;
