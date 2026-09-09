-- ============================================================================
-- Balance CRM · 12_readonly.sql — внешний доступ к базе только на чтение
--
-- Зачем. Внешние сервисы (Composio и всё, что через него) должны читать лиды,
-- но не должны иметь возможности что-либо изменить. Отдельная роль базы
-- crm_readonly получает только select и только на нужные таблицы. Ключ для
-- внешнего доступа — JWT с claim role = crm_readonly, подписанный секретом
-- проекта. Запись таким ключом отбивается не приложением, а самим Postgres:
-- у роли нет ни одного права insert/update/delete.
--
-- Работу CRM файл не меняет: роль authenticated, её политики, представления
-- и триггеры остаются как были. Ни одно представление не пересоздаётся,
-- поэтому гранты authenticated не теряются.
--
-- Файл идемпотентен: выполняется повторно без последствий.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Роль. noinherit: даже если её кому-то выдадут, права не подтянутся сами.
--    nologin: прямого подключения к базе под ней нет, только через PostgREST.
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'crm_readonly') then
    create role crm_readonly nologin noinherit;
  end if;
end $$;

-- PostgREST переключается в роль из claim role. Без членства не переключится.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    grant crm_readonly to authenticator;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Права. Только select и только там, где он нужен, чтобы прочитать лида
--    целиком. custom_pricing (ручные цены), invites, plans, scripts, lessons,
--    lesson_progress, coaching_notes наружу не отдаются: к лидам отношения
--    не имеют, а внутри персональные данные сотрудников.
-- ---------------------------------------------------------------------------

grant usage on schema public to crm_readonly;

grant select on profiles, tariffs, companies, contacts, leads, activities
  to crm_readonly;

-- v_leads — лид карточкой: компания, ЛПР, статус, суммы, этапы оплаты, касания.
-- Представление security_invoker, поэтому select на таблицы выше обязателен.
grant select on v_leads to crm_readonly;

-- v_leads вызывает current_profile_id(); для внешнего ключа она вернёт null
-- (в токене нет sub), поле is_mine будет false. Это верно: внешний ключ ничей.
grant execute on function current_profile_id() to crm_readonly;

-- Права на запись не выдаются нигде и никогда. Строки ниже — не «на всякий
-- случай», а защита от повторного применения старых файлов поверх.
revoke insert, update, delete, truncate on all tables in schema public
  from crm_readonly;

-- Функции, которые пишут в базу, доступны только сотруднику. По умолчанию
-- Postgres раздаёт execute роли public, то есть и crm_readonly тоже.
-- Отбираем у public, оставляем явный грант authenticated — для CRM ничего
-- не меняется. (log_touch и create_lead работают с правами вызывающего,
-- то есть и без этого запись отбилась бы; здесь второй рубеж.)
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('log_touch', 'create_lead', 'apply_invites')
  loop
    execute format('revoke execute on function %s from public', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Политики RLS для crm_readonly. Только for select.
--    Политик insert/update/delete для этой роли нет намеренно: даже если
--    кто-то по ошибке выдаст роли grant insert, вставка упрётся в RLS.
--    Условие using (true): границу проводит сам ключ, а не строка в profiles.
--    Роль видит те же данные, что видит менеджер, и ничего сверх них.
-- ---------------------------------------------------------------------------

drop policy if exists profiles_ext_read on profiles;
create policy profiles_ext_read on profiles for select to crm_readonly using (true);

drop policy if exists tariffs_ext_read on tariffs;
create policy tariffs_ext_read on tariffs for select to crm_readonly using (true);

drop policy if exists companies_ext_read on companies;
create policy companies_ext_read on companies for select to crm_readonly using (true);

drop policy if exists contacts_ext_read on contacts;
create policy contacts_ext_read on contacts for select to crm_readonly using (true);

drop policy if exists leads_ext_read on leads;
create policy leads_ext_read on leads for select to crm_readonly using (true);

drop policy if exists activities_ext_read on activities;
create policy activities_ext_read on activities for select to crm_readonly using (true);

-- ---------------------------------------------------------------------------
-- 4. Выпуск ключа. Ключ — JWT, подписанный секретом проекта
--    (Supabase → Project Settings → API Keys → JWT Keys → Legacy JWT Secret).
--    Секрет нигде не сохраняется: он передаётся аргументом и живёт только
--    внутри вызова. Функция доступна только владельцу проекта: у public
--    и у authenticated прав на неё нет, из PostgREST её не вызвать.
--
--    Выпустить ключ на год:
--      select crm_readonly_token('<JWT Secret>', 365, 'wiokdxswbcmjdpalyrat');
--
--    Отозвать все выпущенные ключи разом:
--      revoke crm_readonly from authenticator;
--    Вернуть доступ:
--      grant crm_readonly to authenticator;
-- ---------------------------------------------------------------------------

create or replace function crm_readonly_token(
  jwt_secret  text,
  valid_days  int  default 365,
  project_ref text default null
) returns text
language sql volatile
set search_path = public, extensions
as $$
  with parts as (
    select
      translate(encode(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'), 'base64'),
                E'+/=\n', '-_') as h,
      translate(encode(convert_to((
        json_strip_nulls(json_build_object(
          'iss',  'supabase',
          'ref',  project_ref,
          'role', 'crm_readonly',
          'iat',  extract(epoch from now())::bigint,
          'exp',  extract(epoch from now() + make_interval(days => valid_days))::bigint
        ))
      )::text, 'utf8'), 'base64'), E'+/=\n', '-_') as p
  )
  select h || '.' || p || '.' ||
         translate(encode(hmac(h || '.' || p, jwt_secret, 'sha256'), 'base64'),
                   E'+/=\n', '-_')
    from parts;
$$;

revoke all on function crm_readonly_token(text, int, text) from public;

-- ---------------------------------------------------------------------------
-- 5. Контроль. Читает под ролью crm_readonly и пробует записать.
--    Если запись прошла — файл падает целиком и в базе не остаётся ничего.
-- ---------------------------------------------------------------------------

do $$
declare
  n_leads int;
  n_view  int;
  wrote   text := 'отклонена';
begin
  set local role crm_readonly;

  select count(*) into n_leads from leads;
  select count(*) into n_view  from v_leads;

  begin
    insert into companies (name) values ('__проверка записи внешним ключом__');
    wrote := 'ПРОШЛА';
  exception when others then
    wrote := 'отклонена: ' || sqlerrm;
  end;

  reset role;

  raise notice 'crm_readonly: leads % строк, v_leads % строк', n_leads, n_view;
  raise notice 'crm_readonly: попытка записи — %', wrote;

  if wrote = 'ПРОШЛА' then
    raise exception 'Внешний ключ смог записать. Проверить гранты, файл не применён.';
  end if;
end $$;

-- Итог: роль, 6 политик на чтение, 7 прав select, 0 прав на запись.
select
  (select count(*) from pg_roles where rolname = 'crm_readonly') as role_1,
  (select count(*) from pg_policies
    where schemaname = 'public' and policyname like '%\_ext\_read') as policies_6,
  (select count(*) from information_schema.role_table_grants
    where grantee = 'crm_readonly' and privilege_type = 'SELECT') as selects_7,
  (select count(*) from information_schema.role_table_grants
    where grantee = 'crm_readonly'
      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')) as writes_0;
