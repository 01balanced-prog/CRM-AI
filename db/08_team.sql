-- ============================================================================
-- 08_team.sql · Этап 1: команда и приглашения
--
--   1. profiles: started_at (дата выхода, от неё считается разгон),
--      active (доступ; выключенный сотрудник не видит ничего, история остаётся),
--      ramp_enabled (участвует ли в разгоне новичка).
--   2. is_staff() / current_profile_id() / is_admin() учитывают active.
--   3. invites: админ приглашает по почте. Триггер на auth.users создаёт
--      профиль только тому, чья почта есть в приглашениях.
--   4. apply_invites(): если человек уже заведён в Authentication руками,
--      приглашение применяется без регистрации.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Колонки сотрудника
alter table profiles add column if not exists started_at   date;
alter table profiles add column if not exists active       boolean not null default true;
alter table profiles add column if not exists ramp_enabled boolean not null default true;

-- 2. Доступ даёт строка в profiles с active = true
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active);
$$;

create or replace function current_profile_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from profiles where id = auth.uid() and active;
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and active);
$$;

-- Админ не может отключить сам себя: иначе некому включить обратно
create or replace function profiles_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.active and not new.active and new.id = auth.uid() then
    raise exception 'Нельзя отключить доступ самому себе' using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on profiles;
create trigger profiles_guard before update on profiles
  for each row execute function profiles_guard();

-- 3. Приглашения
create table if not exists invites (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  name        text not null,
  role        text not null default 'manager' check (role in ('admin','manager')),
  invited_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  used_at     timestamptz,
  profile_id  uuid references profiles(id) on delete set null
);
-- Одно открытое приглашение на почту
create unique index if not exists invites_email_open on invites (lower(email)) where used_at is null;

alter table invites enable row level security;
drop policy if exists invites_admin on invites;
create policy invites_admin on invites for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on invites to authenticated;

-- Регистрация: профиль создаётся только приглашённому.
-- security definer: триггер на auth.users пишет в public.profiles от имени владельца.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  inv invites%rowtype;
begin
  select * into inv from invites
   where lower(email) = lower(new.email) and used_at is null
   order by created_at desc limit 1;
  if found then
    insert into profiles (id, name, role) values (new.id, inv.name, inv.role)
      on conflict (id) do nothing;
    update invites set used_at = now(), profile_id = new.id where id = inv.id;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- 4. Приглашение для уже заведённого аккаунта. Только админ.
create or replace function apply_invites() returns int
language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  r record;
begin
  if not is_admin() then
    raise exception 'Только для администратора' using errcode = 'insufficient_privilege';
  end if;
  for r in
    select i.id as invite_id, u.id as user_id, i.name, i.role
      from invites i join auth.users u on lower(u.email) = lower(i.email)
     where i.used_at is null
  loop
    insert into profiles (id, name, role) values (r.user_id, r.name, r.role)
      on conflict (id) do update set active = true;
    update invites set used_at = now(), profile_id = r.user_id where id = r.invite_id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function apply_invites() from public;
grant execute on function apply_invites() to authenticated;

-- Контроль: три новые колонки, таблица invites, триггер регистрации.
select
  (select count(*) from information_schema.columns
    where table_name = 'profiles'
      and column_name in ('started_at','active','ramp_enabled')) as columns_3,
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_name = 'invites') as invites_1,
  (select count(*) from pg_trigger where tgname = 'on_auth_user_created') as trigger_1;
