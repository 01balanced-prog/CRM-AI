-- ============================================================================
-- 23_access_delete.sql · Понятный «Доступ не выдан» и удаление сотрудника
--
--   1. my_access(): кто вошёл и почему нет доступа. Экран «Доступ не выдан»
--      не мог отличить отключённого сотрудника от чужого аккаунта: отключённый
--      не видит даже свою строку в profiles (is_staff() требует active).
--      Функция отдаёт только своё: почту входа, состояние ('active',
--      'inactive', 'none') и имя. Про других людей не говорит ничего.
--   2. delete_staff(сотрудник): админ удаляет сотрудника совсем — аккаунт
--      входа, профиль, личный план, прогресс уроков, замечания ему, открытое
--      приглашение на его почту. Что остаётся:
--        • лиды — становятся ничьими (ответственного снимаем явно, через
--          leads_guard от имени админа);
--        • журнал касаний — записи остаются без автора (author_id = null):
--          журнал неизменяем, стирать из него нельзя;
--        • компании, настройки, скрипты — без отметки «кто правил».
--      Удалить можно только уже отключённого сотрудника (два шага от
--      случайного нажатия), не себя и не последнего админа.
--      Удалять из SQL Editor руками не нужно: leads_guard не даст снять
--      ответственного без админа, и удаление упадёт.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Кто я и есть ли доступ
create or replace function my_access() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'email', (select email from auth.users where id = auth.uid()),
    'state', case when p.id is null then 'none' when p.active then 'active' else 'inactive' end,
    'name',  p.name)
  from (select 1) x
  left join profiles p on p.id = auth.uid();
$$;
revoke all on function my_access() from public;
grant execute on function my_access() to authenticated;

-- 2. Удалить сотрудника совсем. Возвращает почту удалённого.
create or replace function delete_staff(p_id uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  em   text;
  prof profiles%rowtype;
begin
  if not is_admin() then
    raise exception 'Только для администратора' using errcode = 'insufficient_privilege';
  end if;
  if p_id = current_profile_id() then
    raise exception 'Себя удалить нельзя' using errcode = 'check_violation';
  end if;
  select * into prof from profiles where id = p_id;
  if prof.id is null then
    raise exception 'Сотрудник не найден' using errcode = 'no_data_found';
  end if;
  if prof.active then
    raise exception 'Сначала отключи доступ, потом удаляй' using errcode = 'check_violation';
  end if;
  if prof.role = 'admin' and not exists (
       select 1 from profiles where role = 'admin' and active and id <> p_id) then
    raise exception 'Это последний администратор' using errcode = 'check_violation';
  end if;

  select email into em from auth.users where id = p_id;

  -- Лиды — в общий пул. Явно и от имени админа: leads_guard это пропускает
  update leads set owner_id = null where owner_id = p_id;
  -- Открытое приглашение на ту же почту вернуло бы человека кнопкой «Войти»
  if em is not null then
    delete from invites where lower(email) = lower(em) and used_at is null;
  end if;
  -- Аккаунт входа. Профиль уходит каскадом, ссылки на него обнуляются
  -- или удаляются по своим внешним ключам. Аккаунта нет — удаляем профиль
  delete from auth.users where id = p_id;
  delete from profiles where id = p_id;
  return coalesce(em, prof.name);
end $$;
revoke all on function delete_staff(uuid) from public;
grant execute on function delete_staff(uuid) to authenticated;

-- Контроль: ожидается functions_2 = 2
select count(*) as functions_2 from pg_proc
 where proname in ('my_access','delete_staff') and pronamespace = 'public'::regnamespace;
