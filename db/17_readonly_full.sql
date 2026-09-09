-- ============================================================================
-- Balance CRM · 17_readonly_full.sql — внешнее чтение видит всю базу
--
-- Зачем. Файл 12 отдавал наружу только лидов: компании, контакты, касания,
-- тарифы. Скрипты, уроки, планы и замечания наставника оставались закрыты,
-- и разбор упирался в это. Видно, что в касании применён скрипт, но не видно
-- его текста; видно 92 лида, но не видно нормы по звонкам, с которой их
-- сравнивать. Владелец решил открыть остальное: анализ ведётся по всей базе.
--
-- Что меняется. Роль crm_readonly получает select на девять оставшихся таблиц
-- и семь представлений плюс execute на функции, которые эти представления
-- вызывают. Прав на запись по-прежнему нет ни одного: граница проходит там же,
-- где и раньше, сдвигается только объём чтения.
--
-- Работу CRM файл не меняет. Роль authenticated, её политики, триггеры
-- и представления не трогаются, ни одно представление не пересоздаётся,
-- поэтому гранты authenticated не теряются.
--
-- Файл идемпотентен: выполняется повторно без последствий.
-- ============================================================================

-- Без роли из 12_readonly.sql файлу нечего делать. Падаем внятно, а не
-- двадцатью подряд «role crm_readonly does not exist».
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'crm_readonly') then
    raise exception 'Нет роли crm_readonly. Сначала выполнить db/12_readonly.sql.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Таблицы. Девять оставшихся: всё, что 12_readonly.sql держал закрытым.
--
--    Внутри lesson_progress, coaching_notes, plans и invites — персональные
--    данные сотрудников: кто какой урок сдал, что сказал наставник, чья норма
--    и чья почта. Наружу они уходят вместе с ключом, и это осознанный выбор
--    владельца, а не недосмотр. Ключ хранить как пароль.
--    Отозвать разом:  revoke crm_readonly from authenticator;
-- ---------------------------------------------------------------------------

grant select on
  custom_pricing,     -- ручные цены: единственный способ обойти прайс
  invites,            -- приглашения: почта и роль будущего сотрудника
  plan_defaults,      -- норма по умолчанию
  ramp_steps,         -- разгон новичка по неделям
  plans,              -- персональная норма на месяц
  scripts,            -- скрипты звонков, ответы на возражения, шаблоны сообщений
  lessons,            -- уроки и вопросы к ним
  lesson_progress,    -- кто какой урок сдал и с каким счётом
  coaching_notes      -- замечания наставника к касаниям
  to crm_readonly;

-- RLS включён у всех девяти, поэтому одного granta мало: без политики
-- select вернёт ноль строк и это будет выглядеть как пустая база.
-- Только for select. Политик insert/update/delete для этой роли нет
-- намеренно: даже если кому-то позже выдадут grant insert, вставку отобьёт RLS.
do $$
declare
  t text;
begin
  foreach t in array array[
    'custom_pricing', 'invites', 'plan_defaults', 'ramp_steps', 'plans',
    'scripts', 'lessons', 'lesson_progress', 'coaching_notes'
  ] loop
    execute format('drop policy if exists %I on %I', t || '_ext_read', t);
    execute format(
      'create policy %I on %I for select to crm_readonly using (true)',
      t || '_ext_read', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Представления. Все security_invoker, поэтому select на базовые таблицы
--    выше обязателен — он и выдан.
--
--    Три из семи внешнему ключу данных не дадут, и это правильно, а не
--    поломка: v_today и v_stats фильтруют по owner_id = current_profile_id(),
--    v_plan_today — по profile_id = current_profile_id(). У внешнего ключа
--    в токене нет sub, current_profile_id() возвращает null. Это «дела
--    текущего пользователя», а внешний ключ ничей. v_today и v_plan_today
--    вернут пустой список, v_stats — одну строку с нулями: это агрегат
--    без group by, строка есть всегда.
--
--    Те же числа за отдел целиком дают v_team_today и v_kpi_*, они наполнены.
--    Гранты на v_today и v_stats всё равно выдаются: чтобы отказ выглядел
--    пустым списком, а не 42501, который читается как ошибка настройки.
-- ---------------------------------------------------------------------------

grant select on
  v_today,        -- дела на сегодня: внешнему ключу пустой список
  v_stats,        -- счётчики пользователя: внешнему ключу строка с нулями
  v_plan_today,   -- план пользователя: внешнему ключу пустой список
  v_kpi_day,      -- звонки, разговоры, разговоры с ЛПР и взятые лиды по дням
  v_kpi_week,     -- брифы и КП по неделям
  v_kpi_month,    -- сделки и деньги по месяцам
  v_team_today    -- план и факт по всем активным сотрудникам
  to crm_readonly;

-- Функции, которые эти представления вызывают. Без execute select упадёт
-- на первой же строке. current_profile_id() выдана ещё в 12_readonly.sql.
grant execute on function today_msk()                     to crm_readonly;
grant execute on function msk_day(timestamptz)            to crm_readonly;
grant execute on function effective_plan(uuid, date)      to crm_readonly;
grant execute on function plan_streak(uuid)               to crm_readonly;

-- ---------------------------------------------------------------------------
-- 3. Запись. Строки ниже ничего не отбирают сверх того, чего и так нет:
--    это защита от повторного применения старых файлов поверх и от случайного
--    grant all кем-то в будущем.
-- ---------------------------------------------------------------------------

revoke insert, update, delete, truncate on all tables in schema public
  from crm_readonly;

-- ---------------------------------------------------------------------------
-- 4. Контроль. Читает под ролью crm_readonly каждый вновь открытый объект
--    и пробует записать в два из них. Если запись прошла — файл падает
--    целиком и в базе не остаётся ничего.
-- ---------------------------------------------------------------------------

do $$
declare
  t          text;
  n          int;
  wrote      text;
  n_scripts  int;
  n_lessons  int;
  n_team     int;
begin
  set local role crm_readonly;

  -- Каждый объект должен читаться. Ошибка прав здесь уронит весь файл.
  foreach t in array array[
    'custom_pricing', 'invites', 'plan_defaults', 'ramp_steps', 'plans',
    'scripts', 'lessons', 'lesson_progress', 'coaching_notes',
    'v_today', 'v_stats', 'v_plan_today',
    'v_kpi_day', 'v_kpi_week', 'v_kpi_month', 'v_team_today'
  ] loop
    execute format('select count(*) from %I', t) into n;
  end loop;

  select count(*) into n_scripts from scripts;
  select count(*) into n_lessons from lessons;
  select count(*) into n_team    from v_team_today;

  begin
    insert into scripts (title, body) values ('__проверка записи__', '');
    wrote := 'ПРОШЛА в scripts';
  exception when others then
    begin
      update plan_defaults set calls_day = calls_day;
      wrote := 'ПРОШЛА в plan_defaults';
    exception when others then
      wrote := 'отклонена: ' || sqlerrm;
    end;
  end;

  reset role;

  raise notice 'crm_readonly: скриптов %, уроков %, сотрудников в v_team_today %',
    n_scripts, n_lessons, n_team;
  raise notice 'crm_readonly: попытка записи — %', wrote;

  if wrote like 'ПРОШЛА%' then
    raise exception 'Внешний ключ смог записать (%). Файл не применён.', wrote;
  end if;
end $$;

-- Итог: 16 политик на чтение (6 из файла 12, segments из 14, 9 новых),
-- 24 права select (7 из файла 12, segments из 14, 9 таблиц и 7 представлений
-- отсюда), 0 прав на запись.
select
  (select count(*) from pg_policies
    where schemaname = 'public' and policyname like '%\_ext\_read') as policies_16,
  (select count(*) from information_schema.role_table_grants
    where grantee = 'crm_readonly' and privilege_type = 'SELECT') as selects_24,
  (select count(*) from information_schema.role_table_grants
    where grantee = 'crm_readonly'
      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')) as writes_0;
