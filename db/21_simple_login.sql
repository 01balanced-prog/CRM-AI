-- ============================================================================
-- 21_simple_login.sql · Вход без писем: одна кнопка и пароль от админа
--
--   Письма Supabase до сотрудников не доходят, поэтому ни подтверждение
--   почты, ни «забыли пароль» по ссылке не работают. Вход устроен без них:
--
--   1. invite_open(почта): есть ли открытое приглашение на эту почту.
--      Экран входа спрашивает это, когда пароль не подошёл: если приглашение
--      есть, человек входит впервые, и тот же «Войти» создаёт ему аккаунт
--      с введённым паролем. Отдельной кнопки «Первый вход» больше нет.
--      Функция доступна без входа (роль anon) и отвечает только да/нет.
--      Узнать через неё можно одно: приглашён ли конкретный адрес.
--   2. set_staff_password(сотрудник, пароль): админ выдаёт новый пароль
--      из карточки сотрудника. Заодно подтверждает почту, чтобы включённая
--      в Supabase проверка почты не мешала войти. Только для админа и только
--      для тех, у кого есть строка в profiles: чужой аккаунт так не открыть.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Открытое приглашение на почту
create or replace function invite_open(p_email text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from invites
                  where lower(email) = lower(trim(p_email)) and used_at is null);
$$;
revoke all on function invite_open(text) from public;
grant execute on function invite_open(text) to anon, authenticated;

-- 2. Новый пароль сотруднику. Возвращает почту: админу её нужно отправить
--    вместе с паролем, а в profiles почты нет.
--    crypt() из pgcrypto: в Supabase он в схеме extensions, локально в public,
--    поэтому обе схемы в search_path. Хеш bcrypt, как у самого Supabase Auth.
create or replace function set_staff_password(p_id uuid, p_password text) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  em text;
begin
  if not is_admin() then
    raise exception 'Только для администратора' using errcode = 'insufficient_privilege';
  end if;
  if length(coalesce(p_password, '')) < 6 then
    raise exception 'Пароль не короче 6 символов' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from profiles where id = p_id) then
    raise exception 'Это не сотрудник CRM' using errcode = 'no_data_found';
  end if;
  update auth.users
     set encrypted_password = crypt(p_password, gen_salt('bf')),
         email_confirmed_at = coalesce(email_confirmed_at, now())
   where id = p_id
  returning email into em;
  if em is null then
    raise exception 'Аккаунт сотрудника не найден' using errcode = 'no_data_found';
  end if;
  return em;
end $$;
revoke all on function set_staff_password(uuid, text) from public, anon;
grant execute on function set_staff_password(uuid, text) to authenticated;

-- Контроль: обе функции на месте, у владельца функций есть право менять
-- пароли в auth.users. Ожидается functions_2 = 2, can_update_auth = true.
select
  (select count(*) from pg_proc
    where proname in ('invite_open', 'set_staff_password')
      and pronamespace = 'public'::regnamespace)                   as functions_2,
  has_table_privilege('auth.users', 'UPDATE')                      as can_update_auth;
