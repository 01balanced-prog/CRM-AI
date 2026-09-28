-- ============================================================================
-- 20_confirm_invited.sql · Приглашённый не может войти: «Подтверди почту»
--
--   Если в Supabase включено подтверждение почты (Authentication → Sign In /
--   Providers → Email → Confirm email), «Первый вход по приглашению» создаёт
--   аккаунт, но не пускает в него до перехода по ссылке из письма. Письмо
--   отправляет встроенная почта Supabase, а она шлёт пару писем в час и
--   только адресам участников организации Supabase. До сотрудника оно не
--   доходит, и он застревает.
--
--   Файл разблокирует тех, кто уже застрял:
--   1. Открытые приглашения применяются к уже созданным аккаунтам — то же,
--      что apply_invites(), но без проверки на админа: SQL Editor работает
--      от владельца базы, auth.uid() там пустой.
--   2. Подтверждается почта только у тех, у кого есть действующий профиль,
--      то есть у приглашённых. Чужая регистрация остаётся неподтверждённой
--      и войти не сможет.
--
--   Чтобы это не повторялось, подтверждение почты в Supabase надо выключить
--   (README, раздел «Доступы»). Файл можно выполнять снова каждый раз, когда
--   кто-то застрял, пока настройка не выключена.
--
-- Схему не меняет. Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Приглашения для аккаунтов, созданных до приглашения или мимо триггера
with hit as (
  select distinct on (i.id) i.id as invite_id, u.id as user_id, i.name, i.role
    from invites i join auth.users u on lower(u.email) = lower(i.email)
   where i.used_at is null
   order by i.id, u.created_at desc
), ins as (
  insert into profiles (id, name, role)
  select user_id, name, role from hit
  on conflict (id) do update set active = true
  returning id
)
update invites i set used_at = now(), profile_id = h.user_id
  from hit h where i.id = h.invite_id;

-- 2. Подтвердить почту приглашённым
update auth.users u set email_confirmed_at = now()
 where u.email_confirmed_at is null
   and exists (select 1 from profiles p where p.id = u.id and p.active);

-- Контроль: у каждого сотрудника почта подтверждена, открытых приглашений
-- на уже созданные аккаунты нет. Ожидается unconfirmed_staff = 0, stuck_invites = 0.
select
  (select count(*) from auth.users u join profiles p on p.id = u.id
    where p.active and u.email_confirmed_at is null)                        as unconfirmed_staff,
  (select count(*) from invites i join auth.users u on lower(u.email) = lower(i.email)
    where i.used_at is null)                                                 as stuck_invites;
