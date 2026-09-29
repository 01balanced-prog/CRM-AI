-- ============================================================================
-- 22_owner_last_touch.sql · Ответственный — тот, кто записал касание последним
--
--   Раньше касание забирало себе только ничейный лид, а чужой переназначал
--   один админ. Теперь лид закрепляется за тем, кто с ним работает:
--
--   1. activities_owner: после записи касания автор становится ответственным.
--      Любой профиль, админ тоже. Касание считается так же, как в отчёте и плане:
--      не system и не заметка (other/other). Заметка «поправка: администратора
--      зовут Таиса» или «Отложен» лид не переписывает, смена этапа и отметка
--      оплаты тоже (они пишутся каналом system).
--      Лид, который уже на этапе «Клиент» (won), не переписывается: поступления
--      по этапам оплаты в плане (v_kpi_month) считаются по ответственному,
--      и звонок клиенту перенёс бы на звонящего всю выручку по нему, включая
--      прошлые месяцы. Клиента переназначает админ, как раньше. Касание,
--      которым лид стал клиентом, переписывает: сделку закрыл его автор.
--   2. leads_guard: менеджер по-прежнему не может переназначить чужой лид
--      руками. Разрешено одно: стать ответственным самому, если в этой же
--      транзакции он записал касание по этому лиду. Остальные правила
--      функции перенесены из 09_plans.sql без изменений.
--
--   owner_since при смене ответственного ставится заново: для метрики «взял»
--   лид, перехваченный касанием, считается взятым новым ответственным.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Правила лида: чужой лид можно забрать только своим касанием
create or replace function leads_guard() returns trigger
language plpgsql as $$
declare
  me uuid := current_profile_id();
begin
  if new.status not in ('new','won','lost') and new.next_action_at is null then
    raise exception 'Для статуса «%» нужна дата следующего шага', new.status
      using errcode = 'check_violation';
  end if;
  if new.status = 'lost' and new.lost_reason is null then
    raise exception 'Отказ не сохраняется без причины' using errcode = 'check_violation';
  end if;
  if new.status <> 'lost' then new.lost_reason := null; end if;
  if new.status in ('new','won','lost') then
    new.next_action_at := null; new.next_action := null;
  end if;

  -- Менеджер может взять ничейный лид себе или забрать чужой своим касанием.
  -- Касание ищем в текущей транзакции: created_at = now() у всех её записей.
  if tg_op = 'UPDATE' and new.owner_id is distinct from old.owner_id
     and not is_admin() then
    if new.owner_id is distinct from me
       or (old.owner_id is not null and not exists (
             select 1 from activities a
              where a.lead_id = new.id and a.author_id = me and a.created_at = now()
                and a.channel <> 'system'
                and not (a.channel = 'other' and a.outcome = 'other'))) then
      raise exception 'Переназначить ответственного может только администратор'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  if tg_op = 'INSERT' and new.owner_id is not null and new.owner_id <> me
     and not is_admin() then
    raise exception 'Ответственным можно назначить только себя'
      using errcode = 'insufficient_privilege';
  end if;

  -- Дата, когда лид взяли в работу: для метрики «взял»
  if new.owner_id is null then
    new.owner_since := null;
  elsif tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id then
    new.owner_since := now();
  end if;

  new.updated_at := now();
  return new;
end $$;

-- 2. Касание закрепляет лид за автором
create or replace function activities_owner() returns trigger
language plpgsql as $$
begin
  if new.author_id is null or new.channel = 'system'
     or (new.channel = 'other' and new.outcome = 'other') then
    return null;
  end if;
  -- Клиент остаётся за прежним ответственным. Исключение: касание, которым
  -- лид стал клиентом, — сделку закрыл его автор. Смену этапа log_touch
  -- записывает раньше касания, так что строка system уже есть.
  update leads l set owner_id = new.author_id
   where l.id = new.lead_id
     and l.owner_id is distinct from new.author_id
     and (l.status <> 'won' or exists (
           select 1 from activities s
            where s.lead_id = l.id and s.channel = 'system' and s.created_at = now()
              and s.status_to = 'won' and s.status_from is distinct from 'won'));
  return null;
end $$;

drop trigger if exists activities_owner on activities;
create trigger activities_owner after insert on activities
  for each row execute function activities_owner();

-- Контроль: ожидается owner_trigger_1 = 1, guard_updated = true
select
  (select count(*) from pg_trigger
    where tgname = 'activities_owner' and tgrelid = 'activities'::regclass) as owner_trigger_1,
  (select prosrc like '%a.author_id = me%' from pg_proc
    where proname = 'leads_guard' and pronamespace = 'public'::regnamespace) as guard_updated;
