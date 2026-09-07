-- ============================================================================
-- 11_lessons.sql · Этап 4: обучение и наставник
--
--   1. lessons: урок от админа с вопросами. questions — jsonb:
--      [{"q": "...", "options": ["...","..."], "correct": 0, "hint": "абзац из урока"}]
--      due_week: пройти до конца N-й недели с выхода (сшивка с разгоном).
--   2. lesson_progress: кто и когда прошёл урок, результат. Уникальная пара.
--   3. coaching_notes: замечание наставника к касанию. Журнал остаётся
--      неизменяемым: замечания лежат отдельно. Менеджер может только
--      отметить «прочитано».
--   4. Стартовые уроки. Фиксированные id, правки админа не перетираются.
--
-- Файл идемпотентен, выполняется одной транзакцией.
-- ============================================================================

-- 1. Уроки
create table if not exists lessons (
  id          uuid primary key default gen_random_uuid(),
  module      text not null check (module in ('product','sales','crm')),
  title       text not null,
  body        text not null default '',
  questions   jsonb not null default '[]'::jsonb,
  sort_order  int not null default 0,
  due_week    int check (due_week is null or due_week >= 1),
  active      boolean not null default true,
  updated_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table lessons enable row level security;
drop policy if exists lessons_select on lessons;
create policy lessons_select on lessons for select to authenticated
  using (is_staff() and (active or is_admin()));
drop policy if exists lessons_admin on lessons;
create policy lessons_admin on lessons for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update, delete on lessons to authenticated;

create or replace function lessons_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := current_profile_id();
  return new;
end $$;
drop trigger if exists lessons_touch on lessons;
create trigger lessons_touch before insert or update on lessons
  for each row execute function lessons_touch();

-- 2. Прогресс
create table if not exists lesson_progress (
  profile_id  uuid not null references profiles(id) on delete cascade,
  lesson_id   uuid not null references lessons(id) on delete cascade,
  passed_at   timestamptz not null default now(),
  score       int not null default 0 check (score >= 0),
  total       int not null default 0 check (total >= 0),
  primary key (profile_id, lesson_id)
);

alter table lesson_progress enable row level security;
drop policy if exists lesson_progress_select on lesson_progress;
create policy lesson_progress_select on lesson_progress for select to authenticated
  using (is_staff() and (profile_id = current_profile_id() or is_admin()));
drop policy if exists lesson_progress_own on lesson_progress;
create policy lesson_progress_own on lesson_progress for insert to authenticated
  with check (profile_id = current_profile_id());
drop policy if exists lesson_progress_own_upd on lesson_progress;
create policy lesson_progress_own_upd on lesson_progress for update to authenticated
  using (profile_id = current_profile_id()) with check (profile_id = current_profile_id());
grant select, insert, update on lesson_progress to authenticated;

-- 3. Замечания наставника
create table if not exists coaching_notes (
  id           uuid primary key default gen_random_uuid(),
  from_id      uuid references profiles(id) on delete set null,
  to_id        uuid not null references profiles(id) on delete cascade,
  activity_id  uuid references activities(id) on delete cascade,
  lead_id      uuid references leads(id) on delete cascade,
  text         text not null check (length(trim(text)) > 0),
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);
create index if not exists coaching_notes_to on coaching_notes (to_id, read_at);

alter table coaching_notes enable row level security;
drop policy if exists coaching_notes_select on coaching_notes;
create policy coaching_notes_select on coaching_notes for select to authenticated
  using (is_staff() and (to_id = current_profile_id() or is_admin()));
drop policy if exists coaching_notes_admin_ins on coaching_notes;
create policy coaching_notes_admin_ins on coaching_notes for insert to authenticated
  with check (is_admin());
drop policy if exists coaching_notes_update on coaching_notes;
create policy coaching_notes_update on coaching_notes for update to authenticated
  using (is_staff() and (to_id = current_profile_id() or is_admin()))
  with check (is_staff() and (to_id = current_profile_id() or is_admin()));
drop policy if exists coaching_notes_admin_del on coaching_notes;
create policy coaching_notes_admin_del on coaching_notes for delete to authenticated
  using (is_admin());
grant select, insert, update, delete on coaching_notes to authenticated;

-- Автор замечания — тот, кто пишет. Менеджер меняет только read_at.
create or replace function coaching_notes_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.from_id := current_profile_id();
    if new.lead_id is null and new.activity_id is not null then
      select lead_id into new.lead_id from activities where id = new.activity_id;
    end if;
    return new;
  end if;
  if not is_admin() and (new.text is distinct from old.text
      or new.to_id is distinct from old.to_id or new.from_id is distinct from old.from_id
      or new.activity_id is distinct from old.activity_id) then
    raise exception 'Замечание может править только наставник' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
drop trigger if exists coaching_notes_guard on coaching_notes;
create trigger coaching_notes_guard before insert or update on coaching_notes
  for each row execute function coaching_notes_guard();

-- 4. Стартовые уроки
insert into lessons (id, module, title, body, questions, sort_order, due_week) values
('00000000-0000-0000-0000-000000000301', 'product', 'Что мы продаём',
$t$Balance внедряет Агента для приёма заказов в WhatsApp. Гость пишет в мессенджер заведения, Агент отвечает, уточняет заказ, адрес и время, передаёт заказ на кухню или в кассу. Администратор больше не сидит на телефоне.

В разговоре с клиентом это всегда «Агент». Слово «бот» не используем: у клиентов оно связано с глупыми автоответчиками.

Сколько стоит. Внедрение оплачивается тремя этапами: 30% за прототип, 30% за бета-тест, 40% за полную интеграцию. Дальше подписка в месяц. Суммы зависят от тарифа, их считает CRM, скидок нет.

Что Агент делает:
- принимает заказ и уточняет детали
- знает меню и стоп-лист
- отвечает круглосуточно
- передаёт заказ туда, куда скажет клиент

Чего Агент не делает: не звонит гостям сам, не заменяет доставку, не работает без меню в электронном виде.$t$,
'[{"q":"Как называем продукт в разговоре с клиентом?","options":["Бот","Агент","Робот"],"correct":1,"hint":"В разговоре с клиентом это всегда «Агент». Слово «бот» не используем."},
  {"q":"Как оплачивается внедрение?","options":["Сразу 100%","30% / 30% / 40% по этапам","Только подпиской"],"correct":1,"hint":"Внедрение оплачивается тремя этапами: 30% за прототип, 30% за бета-тест, 40% за полную интеграцию."},
  {"q":"Можно ли дать скидку, если клиент сомневается?","options":["Да, до 10%","Нет, суммы считает CRM из тарифа","Только на подписку"],"correct":1,"hint":"Суммы зависят от тарифа, их считает CRM, скидок нет."}]'::jsonb,
10, 1),

('00000000-0000-0000-0000-000000000302', 'sales', 'Первый звонок: цель и структура',
$t$Цель первого звонка не продать, а выйти на ЛПР и договориться о 15-минутном созвоне. Продажа происходит на втором разговоре, когда есть цифры заведения.

Структура:
- Кто вы и откуда, одно предложение.
- Зачем звоните: Агент принимает заказы в WhatsApp без администратора.
- Два вопроса: кто принимает заказы сейчас и сколько их в день.
- Предложение созвона с двумя вариантами времени.

Если трубку взял администратор, задача другая: узнать имя ЛПР, его номер и когда он на месте. Администратору не продаём.

После каждого звонка сразу записываем касание в CRM: исход, дата следующего шага, что сказали. Пять недозвонов подряд закрывают лид автоматически, поэтому между попытками меняйте время суток.$t$,
'[{"q":"Что является целью первого звонка?","options":["Продать внедрение","Выйти на ЛПР и назначить созвон","Отправить прайс"],"correct":1,"hint":"Цель первого звонка не продать, а выйти на ЛПР и договориться о 15-минутном созвоне."},
  {"q":"Трубку взял администратор. Что делаем?","options":["Рассказываем про Агента","Узнаём имя и номер ЛПР","Просим перезвонить"],"correct":1,"hint":"Если трубку взял администратор, задача другая: узнать имя ЛПР, его номер и когда он на месте."},
  {"q":"Что происходит после пяти недозвонов подряд?","options":["Ничего","Лид закрывается автоматически","Лид уходит админу"],"correct":1,"hint":"Пять недозвонов подряд закрывают лид автоматически, поэтому между попытками меняйте время суток."}]'::jsonb,
10, 1),

('00000000-0000-0000-0000-000000000303', 'crm', 'Как вести лид в CRM',
$t$Один лид — одно заведение. Компания, контакты и сделка живут вместе в карточке.

Касание записывается сразу после звонка кнопкой внизу карточки. Сверху листа только исход и дата следующего шага. Остальное под «Подробнее»: канал, разговор с ЛПР, новый контакт, комментарий, статус, тариф.

Статусы идут по порядку: Новый → Контакт установлен → Бриф снят → КП отправлено → На согласовании → Клиент. Отказ требует причины. Любой статус кроме первого и последних требует даты следующего шага: без неё лид выпадет из очереди на сегодня.

Журнал касаний нельзя редактировать и удалять. Ошиблись — запишите новое касание с пояснением.

План на сегодня показывает звонки, разговоры и выходы на ЛПР. Он считается из журнала: что не записано, того не было.$t$,
'[{"q":"Зачем нужна дата следующего шага?","options":["Для отчёта","Без неё лид выпадет из очереди на сегодня","Не нужна"],"correct":1,"hint":"Любой статус кроме первого и последних требует даты следующего шага: без неё лид выпадет из очереди на сегодня."},
  {"q":"Ошиблись в записи касания. Что делать?","options":["Удалить запись","Отредактировать","Записать новое касание с пояснением"],"correct":2,"hint":"Журнал касаний нельзя редактировать и удалять. Ошиблись — запишите новое касание с пояснением."},
  {"q":"Откуда считается план на сегодня?","options":["Из журнала касаний","Вводится руками","Из отчёта"],"correct":0,"hint":"План на сегодня считается из журнала: что не записано, того не было."}]'::jsonb,
10, 2)
on conflict (id) do nothing;

-- Контроль: три таблицы, три стартовых урока.
select
  (select count(*) from information_schema.tables
    where table_schema = 'public'
      and table_name in ('lessons','lesson_progress','coaching_notes')) as tables_3,
  (select count(*) from lessons) as lessons_3;
