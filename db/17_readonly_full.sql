-- ============================================================================
-- Balance CRM · 17_readonly_full.sql — внешнее чтение видит всю базу
--
-- Зачем. Файл 12 отдавал наружу только лидов: компании, контакты, касания,
-- тарифы. Скрипты, уроки, планы и замечания наставника оставались закрыты,
-- и разбор упирался в это. Видно, что в касании применён скрипт, но не видно
-- его текста; видно 92 лида, но не видно нормы по звонкам, с которой их
-- сравнивать. Владелец решил открыть остальное: анализ ведётся по всей базе.
--
-- Что меняется. Роль crm_readonly получает select на оставшиеся таблицы
-- и представления плюс execute на функции, которые эти представления
-- вызывают. Прав на запись по-прежнему нет ни одного: граница проходит там же,
-- где и раньше, сдвигается только объём чтения.
--
-- Работу CRM файл не меняет. Роль authenticated, её политики, триггеры
-- и представления не трогаются, ни одно представление не пересоздаётся,
-- поэтому гранты authenticated не теряются.
--
-- Чего в базе нет, то пропускается. 00_baseline.sql — схема, восстановленная
-- по коду клиента, а не выгрузка: в нём есть объекты, которых в живой базе
-- никогда не было (custom_pricing клиент не использует вовсе). Жёсткий список
-- уронил бы файл целиком на первом же таком имени, поэтому каждый объект
-- проверяется перед выдачей прав, а пропущенные перечисляются в конце.
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
-- 1. Таблицы. Всё, что 12_readonly.sql держал закрытым.
--
--    Внутри lesson_progress, coaching_notes, plans и invites — персональные
--    данные сотрудников: кто какой урок сдал, что сказал наставник, чья норма
--    и чья почта. Наружу они уходят вместе с ключом, и это осознанный выбор
--    владельца, а не недосмотр. Ключ хранить как пароль.
--    Отозвать разом:  revoke crm_readonly from authenticator;
--
--    RLS включён у всех, поэтому одного granta мало: без политики select
--    вернёт ноль строк и это будет выглядеть как пустая база. Политика
--    только for select. Политик insert/update/delete для этой роли нет
--    намеренно: даже если кому-то позже выдадут grant insert, вставку
--    отобьёт RLS.
-- ---------------------------------------------------------------------------

do $$
declare
  t       text;
  missing text[] := '{}';
begin
  foreach t in array array[
    'custom_pricing',   -- ручные цены: единственный способ обойти прайс
    'invites',          -- приглашения: почта и роль будущего сотрудника
    'plan_defaults',    -- норма по умолчанию
    'ramp_steps',       -- разгон новичка по неделям
    'plans',            -- персональная норма на месяц
    'scripts',          -- скрипты звонков, ответы на возражения, шаблоны сообщений
    'lessons',          -- уроки и вопросы к ним
    'lesson_progress',  -- кто какой урок сдал и с каким счётом
    'coaching_notes'    -- замечания наставника к касаниям
  ] loop
    if to_regclass('public.' || quote_ident(t)) is null then
      missing := missing || t;
      continue;
    end if;
    execute format('grant select on public.%I to crm_readonly', t);
    execute format('drop policy if exists %I on public.%I', t || '_ext_read', t);
    execute format(
      'create policy %I on public.%I for select to crm_readonly using (true)',
      t || '_ext_read', t);
  end loop;

  if cardinality(missing) > 0 then
    raise notice 'Пропущены таблицы, которых в базе нет: %', array_to_string(missing, ', ');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Представления. Все security_invoker, поэтому select на базовые таблицы
--    выше обязателен — он и выдан. Политики представлениям не нужны: права
--    и политики берутся с таблиц, на которых они построены.
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

do $$
declare
  v       text;
  missing text[] := '{}';
begin
  foreach v in array array[
    'v_today',        -- дела на сегодня: внешнему ключу пустой список
    'v_stats',        -- счётчики пользователя: внешнему ключу строка с нулями
    'v_plan_today',   -- план пользователя: внешнему ключу пустой список
    'v_kpi_day',      -- звонки, разговоры, разговоры с ЛПР и взятые лиды по дням
    'v_kpi_week',     -- брифы и КП по неделям
    'v_kpi_month',    -- сделки и деньги по месяцам
    'v_team_today'    -- план и факт по всем активным сотрудникам
  ] loop
    if to_regclass('public.' || quote_ident(v)) is null then
      missing := missing || v;
      continue;
    end if;
    execute format('grant select on public.%I to crm_readonly', v);
  end loop;

  if cardinality(missing) > 0 then
    raise notice 'Пропущены представления, которых в базе нет: %', array_to_string(missing, ', ');
  end if;
end $$;

-- Функции, которые эти представления вызывают. Без execute select упадёт
-- на первой же строке. current_profile_id() выдана ещё в 12_readonly.sql.
do $$
declare
  f       text;
  missing text[] := '{}';
begin
  foreach f in array array[
    'today_msk()',
    'msk_day(timestamptz)',
    'effective_plan(uuid, date)',
    'plan_streak(uuid)'
  ] loop
    if to_regprocedure('public.' || f) is null then
      missing := missing || f;
      continue;
    end if;
    execute format('grant execute on function public.%s to crm_readonly', f);
  end loop;

  if cardinality(missing) > 0 then
    raise notice 'Пропущены функции, которых в базе нет: %', array_to_string(missing, ', ');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Запись. Строки ниже ничего не отбирают сверх того, чего и так нет:
--    это защита от повторного применения старых файлов поверх и от случайного
--    grant all кем-то в будущем.
-- ---------------------------------------------------------------------------

revoke insert, update, delete, truncate on all tables in schema public
  from crm_readonly;

-- ---------------------------------------------------------------------------
-- 4. Контроль. Три проверки подряд:
--    а) каждый открытый объект действительно читается под ролью crm_readonly;
--    б) прав на запись у роли нет ни на один объект схемы — спрашиваем
--       у самого Postgres, а не по попытке: попытка может упасть на not null
--       и соврать, что дело в правах;
--    в) настоящая вставка отбивается кодом 42501.
--    Если запись прошла — файл падает целиком и в базе не остаётся ничего.
-- ---------------------------------------------------------------------------

do $$
declare
  t           text;
  n           int;
  read_ok     text[] := '{}';
  can_write   text[] := '{}';
  first_table text;
  wrote       text := 'проверить было нечего';
  code        text;
begin
  -- б) права на запись. has_table_privilege отвечает за роль, не за сессию,
  --    поэтому переключаться на неё не нужно и результат не зависит от RLS.
  for t in
    select c.relname
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace
     where ns.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p')
  loop
    if has_table_privilege('crm_readonly', format('public.%I', t), 'INSERT')
    or has_table_privilege('crm_readonly', format('public.%I', t), 'UPDATE')
    or has_table_privilege('crm_readonly', format('public.%I', t), 'DELETE')
    then
      can_write := can_write || t;
    end if;
  end loop;

  if cardinality(can_write) > 0 then
    raise exception 'У crm_readonly есть права на запись: %. Файл не применён.',
      array_to_string(can_write, ', ');
  end if;

  set local role crm_readonly;

  -- а) чтение. Отсутствие прав уронит файл прямо здесь.
  foreach t in array array[
    'custom_pricing', 'invites', 'plan_defaults', 'ramp_steps', 'plans',
    'scripts', 'lessons', 'lesson_progress', 'coaching_notes',
    'v_today', 'v_stats', 'v_plan_today',
    'v_kpi_day', 'v_kpi_week', 'v_kpi_month', 'v_team_today'
  ] loop
    if to_regclass('public.' || quote_ident(t)) is null then continue; end if;
    execute format('select count(*) from public.%I', t) into n;
    read_ok := read_ok || t;
    if first_table is null and t not like 'v\_%' then first_table := t; end if;
  end loop;

  -- в) настоящая вставка. Отказ обязан прийти по правам (42501), а не по
  --    ограничению таблицы: иначе проверка ничего не доказывает.
  if first_table is not null then
    begin
      execute format('insert into public.%I default values', first_table);
      wrote := 'ПРОШЛА в ' || first_table;
    exception when others then
      get stacked diagnostics code = returned_sqlstate;
      wrote := case when code = '42501'
                 then 'отклонена по правам (42501) в ' || first_table
                 else 'отклонена в ' || first_table || ', код ' || code || ': ' || sqlerrm
               end;
    end;
  end if;

  reset role;

  raise notice 'crm_readonly читает % объектов: %',
    cardinality(read_ok), array_to_string(read_ok, ', ');
  raise notice 'crm_readonly: прав на запись нет ни на один объект схемы public';
  raise notice 'crm_readonly: попытка вставки — %', wrote;

  if wrote like 'ПРОШЛА%' then
    raise exception 'Внешний ключ смог записать (%). Файл не применён.', wrote;
  end if;
end $$;

-- Итог. Чисел ждать фиксированных не нужно: в живой базе может не быть части
-- объектов из 00_baseline.sql, и тогда прав будет меньше. Важна последняя
-- колонка — прав на запись у внешней роли должно быть ноль.
select
  (select count(*) from pg_policies
    where schemaname = 'public' and policyname like '%\_ext\_read') as политик_на_чтение,
  (select count(*) from information_schema.role_table_grants
    where grantee = 'crm_readonly' and privilege_type = 'SELECT') as прав_на_чтение,
  (select count(*) from information_schema.role_table_grants
    where grantee = 'crm_readonly'
      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')) as прав_на_запись_ноль;
