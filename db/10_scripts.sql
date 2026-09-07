-- ============================================================================
-- 10_scripts.sql · Этап 3: скрипты и режим звонка
--
--   1. scripts: скрипт этапа или возражение. Правится админом с телефона,
--      публикация файла не нужна. Подстановки в тексте: {компания}, {лпр},
--      {тариф}, {внедрение}, {подписка}. Форматирование: пустая строка делит
--      абзацы, «- » пункт, **жирный**.
--   2. activities.script_id / objection_id: какой скрипт был открыт и какое
--      возражение выбрано в этом касании.
--   3. log_touch принимает script_id и objection_id. Старая сигнатура
--      удаляется: две функции с одним именем PostgREST не различит.
--   4. Стартовый набор скриптов и возражений. Черновики: править в «Команде».
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Скрипты и возражения
create table if not exists scripts (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'script' check (kind in ('script','objection')),
  stage       text check (stage is null or stage in
                ('first_call','gatekeeper','brief','after_proposal','closing','callback')),
  segment     text,
  title       text not null,
  body        text not null default '',
  sort_order  int not null default 0,
  active      boolean not null default true,
  updated_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table scripts enable row level security;
drop policy if exists scripts_select on scripts;
create policy scripts_select on scripts for select to authenticated
  using (is_staff() and (active or is_admin()));
drop policy if exists scripts_admin on scripts;
create policy scripts_admin on scripts for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on scripts to authenticated;

create or replace function scripts_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := current_profile_id();
  return new;
end $$;
drop trigger if exists scripts_touch on scripts;
create trigger scripts_touch before insert or update on scripts
  for each row execute function scripts_touch();

-- 2. Связь касания со скриптом
alter table activities add column if not exists script_id    uuid references scripts(id) on delete set null;
alter table activities add column if not exists objection_id uuid references scripts(id) on delete set null;

-- 3. log_touch с script_id и objection_id
drop function if exists log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb);

create or replace function log_touch(
  client_id       uuid,
  lead_id         uuid,
  channel         text,
  outcome         text,
  status          text,
  with_dm         boolean default false,
  comment         text    default null,
  next_action_at  date    default null,
  next_action     text    default null,
  lost_reason     text    default null,
  tariff          text    default null,
  contact         jsonb   default null,
  script_id       uuid    default null,
  objection_id    uuid    default null
) returns jsonb
language plpgsql security invoker set search_path = public as $$
#variable_conflict use_variable
declare
  me          uuid := current_profile_id();
  v_company   uuid;
  v_before    text;
  v_after     text;
  c_name      text := nullif(trim(coalesce(contact->>'name','')), '');
  c_position  text := nullif(trim(coalesce(contact->>'position','')), '');
  c_phone     text := nullif(trim(coalesce(contact->>'phone','')), '');
  c_raw       text := nullif(trim(coalesce(contact->>'phone_raw','')), '');
  c_dm        boolean := coalesce((contact->>'dm')::boolean, false);
  c_target    uuid;
begin
  if client_id is null then
    raise exception 'Нет идентификатора касания' using errcode = 'check_violation';
  end if;

  if exists (select 1 from activities a where a.client_id = client_id) then
    select l.status into v_after from leads l where l.id = lead_id;
    return jsonb_build_object('lead_id', lead_id, 'status', v_after,
                              'auto_closed', false, 'already', true);
  end if;

  select l.company_id, l.status into v_company, v_before
    from leads l where l.id = lead_id for update;
  if v_company is null then
    raise exception 'Лид не найден' using errcode = 'no_data_found';
  end if;

  if c_name is not null or c_position is not null or c_phone is not null then
    if c_phone is not null then
      select c.id into c_target from contacts c
       where c.company_id = v_company and c.phone_e164 = c_phone limit 1;
    end if;
    if c_dm then
      update contacts c set is_decision_maker = false
       where c.company_id = v_company and c.is_decision_maker
         and c.id is distinct from c_target;
    end if;
    if c_target is not null then
      update contacts c set
        name = c_name, position = c_position, is_decision_maker = c_dm,
        phone_e164 = coalesce(c_phone, c.phone_e164),
        phone_raw  = case when c_phone is null then c.phone_raw else c_raw end
       where c.id = c_target;
    else
      insert into contacts (company_id, name, position, is_decision_maker, phone_e164, phone_raw)
        values (v_company, c_name, c_position, c_dm, c_phone, c_raw);
    end if;
  end if;

  update leads l set
    status         = status,
    tariff         = tariff,
    next_action_at = next_action_at,
    next_action    = next_action,
    lost_reason    = lost_reason,
    owner_id       = case when l.owner_id is null and not is_admin() then me
                          else l.owner_id end
   where l.id = lead_id;

  insert into activities (client_id, lead_id, channel, outcome, with_dm, comment,
                          script_id, objection_id)
    values (client_id, lead_id, channel, outcome, coalesce(with_dm, false),
            nullif(trim(coalesce(comment,'')), ''), script_id, objection_id);

  select l.status into v_after from leads l where l.id = lead_id;
  return jsonb_build_object('lead_id', lead_id, 'status', v_after,
    'auto_closed', (v_after = 'lost' and status <> 'lost'), 'already', false);
exception
  when unique_violation then
    if exists (select 1 from activities a where a.client_id = client_id) then
      select l.status into v_after from leads l where l.id = lead_id;
      return jsonb_build_object('lead_id', lead_id, 'status', v_after,
                                'auto_closed', false, 'already', true);
    end if;
    raise;
end $$;

revoke all on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid)
  from public;
grant execute on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid)
  to authenticated;

-- 4. Стартовый набор. Фиксированные id: повторный запуск ничего не дублирует
--    и не перетирает правки админа.
insert into scripts (id, kind, stage, title, body, sort_order) values
('00000000-0000-0000-0000-000000000101', 'script', 'first_call', 'Первый звонок',
$t$Здравствуйте, это {лпр}? Меня зовут … , компания Balance, Грозный.

Звоню коротко, по делу. Мы ставим в заведения Агента, который сам принимает заказы в WhatsApp: отвечает гостям, собирает заказ, передаёт на кухню. Администратор не отвлекается на телефон.

- Скажите, у вас заказы в WhatsApp сейчас принимает человек?
- Сколько примерно заказов в день приходит через мессенджер?

Если интерес есть: предлагаю 15 минут созвона, покажу, как Агент работает у похожего заведения. Когда удобнее, сегодня после обеда или завтра утром?$t$, 10),

('00000000-0000-0000-0000-000000000102', 'script', 'gatekeeper', 'Обход администратора',
$t$Здравствуйте, компания Balance. Подскажите, кто у вас решает вопросы по приёму заказов и WhatsApp: собственник или управляющий?

Если не соединяют:
- Как его зовут и когда он обычно на месте?
- Могу написать ему в WhatsApp напрямую, оставите номер?

Не спорить и не продавать администратору. Задача звонка: имя ЛПР, его номер, время.$t$, 20),

('00000000-0000-0000-0000-000000000103', 'script', 'callback', 'Возврат после недозвона',
$t${лпр}, здравствуйте, это … из Balance. Я звонил вам на днях по поводу приёма заказов в WhatsApp, не дозвонился.

Уделите две минуты? Мы ставим Агента, который принимает заказы в мессенджере без участия администратора.

- Удобно поговорить сейчас или назначим время?$t$, 30),

('00000000-0000-0000-0000-000000000104', 'script', 'brief', 'Снятие брифа',
$t$Задача: понять, как заведение принимает заказы сегодня. Спрашивать, не продавать.

- Через что приходят заказы: WhatsApp, звонки, Instagram, агрегаторы? Что чаще?
- Кто отвечает гостям и сколько времени это занимает в день?
- Сколько заказов теряется, когда не успевают ответить?
- Есть ли меню в электронном виде? Как часто меняется?
- Сколько точек, есть ли своя доставка?
- Кто принимает решение и как: сам, с партнёром, с бухгалтером?

В конце: «Я подготовлю предложение под ваш объём. Отправлю в WhatsApp завтра до обеда, потом созвонимся на 10 минут. Договорились?»$t$, 40),

('00000000-0000-0000-0000-000000000105', 'script', 'after_proposal', 'Звонок после КП',
$t${лпр}, здравствуйте. Отправлял вам предложение по Агенту для {компания}. Посмотрели?

Коротко напомню суть: внедрение {внедрение}, дальше {подписка} в месяц. Агент принимает заказы в WhatsApp круглосуточно, администратор освобождается.

- Что в предложении понятно, что вызывает вопросы?
- Если по цене всё подходит, когда удобно запускать?

Если тянет: «Давайте определимся с датой старта, а детали закроем на первом созвоне с внедренцем».$t$, 50),

('00000000-0000-0000-0000-000000000106', 'script', 'closing', 'Дожим',
$t${лпр}, добрый день. Мы с вами остановились на согласовании. Хочу понять, что мешает принять решение: цена, сроки или сомнения, что Агент справится?

- По цене: первый этап 30% от внедрения, платите по факту прототипа.
- По срокам: прототип за неделю, вы его видите до полной оплаты.
- По сомнениям: покажу, как работает у действующего клиента, прямо в WhatsApp.

Что из этого снимает вопрос?$t$, 60),

('00000000-0000-0000-0000-000000000201', 'objection', null, 'Дорого',
$t$Понимаю. Давайте посчитаем на ваших цифрах: сколько заказов в день приходит в WhatsApp и сколько из них теряется, пока администратор занят? Один потерянный заказ в день за месяц обычно дороже подписки.

Плюс внедрение платится по этапам: 30% сейчас, остальное когда Агент уже работает.$t$, 10),

('00000000-0000-0000-0000-000000000202', 'objection', null, 'Нет потребности, справляемся',
$t$Хорошо, что справляетесь. Вопрос не в том, справляетесь ли, а сколько это стоит: время администратора и заказы в час пик, когда трубку не берут.

Предлагаю просто замерить: неделю Агент работает параллельно, вы видите, сколько заказов он принял. Решаете по цифрам.$t$, 20),

('00000000-0000-0000-0000-000000000203', 'objection', null, 'Есть своё решение / приложение',
$t$Отлично, значит вы уже цените автоматизацию. Агент не заменяет приложение, а закрывает канал, где гости пишут сами: WhatsApp. Большинство гостей не ставит приложение ради одного заказа, а в мессенджер пишут все.

Можно подключить Агента к вашей текущей системе, заказы будут попадать туда же.$t$, 30),

('00000000-0000-0000-0000-000000000204', 'objection', null, 'Надо подумать / посоветоваться',
$t$Конечно. Чтобы разговор с партнёром был предметным, отправлю короткое предложение с цифрами под {компания}. С кем советуетесь, чтобы я учёл его вопросы?

Когда вам удобно созвониться после разговора: четверг или пятница?$t$, 40),

('00000000-0000-0000-0000-000000000205', 'objection', null, 'Отправьте на WhatsApp, посмотрю',
$t$Отправлю, конечно. Только чтобы предложение было по делу, а не общая презентация, задам два вопроса: сколько заказов в день приходит через WhatsApp и кто их сейчас принимает?

Отправлю сегодня, а созвонимся завтра в это же время, договорились?$t$, 50)
on conflict (id) do nothing;

-- Контроль: таблица scripts, две колонки в activities, одна функция log_touch,
-- стартовые скрипты и возражения.
select
  (select count(*) from information_schema.columns
    where table_name = 'activities' and column_name in ('script_id','objection_id')) as columns_2,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'log_touch') as log_touch_1,
  (select count(*) from scripts where kind = 'script') as scripts_6,
  (select count(*) from scripts where kind = 'objection') as objections_5;
