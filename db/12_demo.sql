-- ============================================================================
-- 12_demo.sql · Этап 6: воронка через демо и база знаний
--
--   Разбор журнала за август показал: до брифа и КП почти никто не доходит,
--   ЛПР говорит «покажите», администратор «передаст». Воронка перестраивается:
--   контакт → демо получил → цена названа → согласование → клиент.
--   Коды статусов в базе не меняются, меняются только подписи в клиенте.
--
--   1. activities.demo: какое демо отправлено в этом касании, общее или
--      индивидуальное. Без этого через месяц не узнать, окупает ли
--      индивидуальное демо свои полчаса.
--   2. log_touch с параметром demo. Старая сигнатура удаляется: две функции
--      с одним именем PostgREST не различит. Клиент версии 11 продолжает
--      работать, у нового параметра есть значение по умолчанию.
--   3. segments: справочник сегментов вместо свободного текста. «Суши, доставка»,
--      «Суши-бар» и «Суши и пицца» были тремя сегментами; скрипт по сегменту
--      так не сработает. Существующие значения приводятся к справочнику.
--   4. scripts.kind = 'message': шаблоны сообщений в WhatsApp с подстановками.
--      Открываются из карточки в один тап с уже вписанным текстом.
--   5. Скрипт «Звонок после демо» вместо «Снятия брифа», два возражения
--      из журнала: «уже был бот» и «позвоните, когда будет кейс».
--
-- Представления не пересобираются: набор колонок не меняется.
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Демо в касании
alter table activities add column if not exists demo text
  check (demo is null or demo in ('general','custom'));

-- 2. log_touch с demo
drop function if exists log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid);

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
  objection_id    uuid    default null,
  demo            text    default null
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
                          script_id, objection_id, demo)
    values (client_id, lead_id, channel, outcome, coalesce(with_dm, false),
            nullif(trim(coalesce(comment,'')), ''), script_id, objection_id, demo);

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

revoke all on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid,text)
  from public;
grant execute on function log_touch(uuid,uuid,text,text,text,boolean,text,date,text,text,text,jsonb,uuid,uuid,text)
  to authenticated;

-- 3. Сегменты
create table if not exists segments (
  name        text primary key,
  sort_order  int not null default 0,
  active      boolean not null default true
);

alter table segments enable row level security;
drop policy if exists segments_select on segments;
create policy segments_select on segments for select to authenticated using (is_staff());
drop policy if exists segments_admin on segments;
create policy segments_admin on segments for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on segments to authenticated;

insert into segments (name, sort_order) values
  ('Суши', 10), ('Пицца', 20), ('Бургеры и фастфуд', 30), ('Шаурма', 40),
  ('Кафе и рестораны', 50), ('Пекарня и кофейня', 60), ('Доставка еды', 70),
  ('Курьерская служба', 80), ('Розница', 90), ('Услуги', 100), ('Другое', 110)
on conflict (name) do nothing;

-- Существующие значения приводим к справочнику. Что не распозналось, остаётся
-- как есть: клиент покажет такое значение в списке, админ поправит руками.
update companies set segment = case
  when lower(segment) like '%суш%'                                          then 'Суши'
  when lower(segment) like '%пицц%'                                         then 'Пицца'
  when lower(segment) like '%бургер%' or lower(segment) like '%фастфуд%'
    or lower(segment) like '%быстрого питания%'                             then 'Бургеры и фастфуд'
  when lower(segment) like '%шаурм%' or lower(segment) like '%донер%'       then 'Шаурма'
  when lower(segment) like '%пекарн%' or lower(segment) like '%кофейн%'     then 'Пекарня и кофейня'
  when lower(segment) like '%курьер%'                                       then 'Курьерская служба'
  when lower(segment) like '%доставка еды%'                                 then 'Доставка еды'
  when lower(segment) like '%шашлы%' or lower(segment) like '%ресторан%'
    or lower(segment) like '%кафе%' or lower(segment) = 'общепит'           then 'Кафе и рестораны'
  when lower(segment) = 'розница'                                           then 'Розница'
  when lower(segment) = 'услуги'                                            then 'Услуги'
  else segment end
where segment is not null
  and segment not in (select name from segments);

-- 4. Шаблоны сообщений
alter table scripts drop constraint if exists scripts_kind_check;
alter table scripts add constraint scripts_kind_check
  check (kind in ('script','objection','message'));

-- 5. Стартовый набор. Фиксированные id: повторный запуск ничего не дублирует
--    и не перетирает правки админа.
insert into scripts (id, kind, stage, title, body, sort_order) values
('00000000-0000-0000-0000-000000000107', 'script', 'brief', 'Звонок после демо',
$t${лпр}, здравствуйте, это … из Balance. Присылал вам Агента для {компания}. Написали ему?

Если да, спрашивать, не продавать:
- Что заказали, как ответил?
- Что смутило или чего не хватило?
- Сколько заказов в день сейчас приходит в WhatsApp и кто их принимает?

Если нет: «Это две минуты, напишите ему прямо сейчас, я на связи». Подождать.

Дальше цена, она одна для всех: внедрение {внедрение}, подписка {подписка} в месяц. Платится по этапам: 30% за прототип, 30% после бета-теста, 40% после полной интеграции. Прототип видите до второй оплаты.

- Если по цене подходит, когда удобно запускать?$t$, 39),

('00000000-0000-0000-0000-000000000206', 'objection', null, 'Уже был бот, путал заказы',
$t$Понимаю, такие боты были у многих: кнопки, меню по номерам, путаница в чате. Агент не бот. Он читает, что написал гость, уточняет, если непонятно, и передаёт заказ человеку, если не уверен.

Проверить проще, чем поверить: напишите ему как гость, это две минуты. Пришлю номер прямо сейчас.$t$, 60),

('00000000-0000-0000-0000-000000000207', 'objection', null, 'Позвоните, когда будет кейс',
$t$Кейс покажу с удовольствием. Но проверить на своём меню быстрее, чем на чужом: сделаю Агента на ваших позициях, вы напишете ему как гость и сами всё увидите. Ничего не платите и не подписываете.

Когда прислать: сегодня вечером или завтра утром?$t$, 70),

('00000000-0000-0000-0000-000000000401', 'message', null, 'Демо после звонка',
$t${лпр}, здравствуйте! Это … из Balance, только что говорили.

Как обещал, Агент, который принимает заказы в WhatsApp. Напишите ему как гость и закажите что-нибудь: [номер демо]. Отвечает сразу, в любое время.

Завтра наберу, спрошу, как впечатление.$t$, 10),

('00000000-0000-0000-0000-000000000402', 'message', null, 'Цена и этапы',
$t$Цена одна для всех, без скидок и без сюрпризов: внедрение {внедрение}, дальше {подписка} в месяц.

Платится по этапам: 30% за прототип, 30% после бета-теста, 40% после полной интеграции. Прототип видите до второй оплаты.$t$, 20),

('00000000-0000-0000-0000-000000000403', 'message', null, 'Напоминание через день',
$t${лпр}, добрый день. Написали Агенту? Если да, что заказали и как прошло?

Если не успели, вот номер ещё раз: [номер демо]. Две минуты, и всё станет понятно.$t$, 30)
on conflict (id) do nothing;

-- «Снятие брифа» выключаем, если админ его не правил: в новой воронке брифа нет.
update scripts set active = false
 where id = '00000000-0000-0000-0000-000000000104' and updated_by is null and active;

-- «Звонок после КП» из стартового набора переписываем под фиксированную цену,
-- тоже только если админ его не трогал.
update scripts set title = 'Звонок после цены', body =
$t${лпр}, здравствуйте. Присылал вам цену по Агенту для {компания}. Посмотрели?

Коротко напомню: внедрение {внедрение}, дальше {подписка} в месяц. Цена одна для всех, скидок нет, зато платится по этапам: 30% за прототип, остальное когда Агент уже работает.

- Что понятно, что вызывает вопросы?
- Если по цене всё подходит, когда удобно запускать?

Если тянет: «Давайте определимся с датой старта, а детали закроем на первом созвоне с внедренцем».$t$
 where id = '00000000-0000-0000-0000-000000000105' and updated_by is null
   and title = 'Звонок после КП';

-- Контроль: колонка demo, одна функция log_touch с 15 параметрами, 11 сегментов,
-- скрипт «Звонок после демо», 7 возражений, 3 сообщения.
select
  (select count(*) from information_schema.columns
    where table_name = 'activities' and column_name = 'demo') as demo_column_1,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'log_touch' and p.pronargs = 15) as log_touch_1,
  (select count(*) from segments) as segments_11,
  (select count(*) from scripts where kind = 'script' and stage = 'brief' and active) as brief_scripts_1,
  (select count(*) from scripts where kind = 'objection') as objections_7,
  (select count(*) from scripts where kind = 'message') as messages_3;
