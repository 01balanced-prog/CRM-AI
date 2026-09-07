-- ============================================================================
-- Balance CRM · 13_key_check.sql — разбор и проверка ключей
--
-- Три функции, чтобы не гадать, почему база не приняла ключ:
--   jwt_header(токен)          — заголовок: алгоритм подписи
--   jwt_payload(токен)         — полезная часть: роль, срок, издатель
--   jwt_check(токен, секрет)   — сходится ли подпись с этим секретом
--
-- Секрет никуда не сохраняется: передаётся аргументом и живёт только внутри
-- вызова. Функции доступны только владельцу проекта: у public и authenticated
-- прав на них нет, из PostgREST не вызвать.
--
-- Заголовок и полезная часть — не тайна, они читаются из любого токена без
-- секрета. Тайна только подпись.
--
-- Файл ничего не меняет в данных, правах и политиках. Идемпотентен.
-- ============================================================================

-- Разложить base64url обратно: вернуть '+' и '/', добить '=' до кратности 4.
create or replace function jwt_part(token text, n int) returns jsonb
language sql immutable
set search_path = public, extensions
as $$
  select convert_from(decode(
           translate(split_part(token, '.', n), '-_', '+/') ||
           repeat('=', (4 - length(split_part(token, '.', n)) % 4) % 4),
         'base64'), 'utf8')::jsonb;
$$;

create or replace function jwt_header(token text) returns jsonb
language sql immutable set search_path = public as $$ select jwt_part(token, 1) $$;

create or replace function jwt_payload(token text) returns jsonb
language sql immutable set search_path = public as $$ select jwt_part(token, 2) $$;

-- Сходится ли подпись токена с этим секретом. Работает только для HS256.
create or replace function jwt_check(token text, jwt_secret text) returns boolean
language sql immutable
set search_path = public, extensions
as $$
  select translate(encode(hmac(
           split_part(token, '.', 1) || '.' || split_part(token, '.', 2),
           jwt_secret, 'sha256'), 'base64'), E'+/=\n', '-_')
         = split_part(token, '.', 3);
$$;

revoke all on function jwt_part(text, int)    from public;
revoke all on function jwt_header(text)       from public;
revoke all on function jwt_payload(text)      from public;
revoke all on function jwt_check(text, text)  from public;

-- ---------------------------------------------------------------------------
-- Контроль: на заведомо верной паре подпись сходится, на подменённом
-- секрете — нет, разбор возвращает роль.
-- ---------------------------------------------------------------------------
do $$
declare
  s   text := 'секрет-для-самопроверки-этого-файла';
  tok text;
begin
  tok := crm_readonly_token(s, 1, 'test');
  if not jwt_check(tok, s)           then raise exception 'jwt_check не признал верную подпись'; end if;
  if     jwt_check(tok, s || 'x')    then raise exception 'jwt_check признал неверную подпись';  end if;
  if jwt_payload(tok) ->> 'role' is distinct from 'crm_readonly' then
    raise exception 'jwt_payload разобрал токен неверно';
  end if;
  raise notice 'jwt_check и jwt_payload работают: % ', jwt_payload(tok) ->> 'role';
end $$;

select jwt_header(crm_readonly_token('x', 1)) as заголовок,
       jwt_payload(crm_readonly_token('x', 1)) ->> 'role' as роль;
