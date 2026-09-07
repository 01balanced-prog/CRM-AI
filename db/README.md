# Схема базы

Здесь лежат SQL-файлы по порядку номеров. Живая база в Supabase собрана файлами
`01`–`06`, которых в репозитории нет и никогда не было: они вставлялись в SQL Editor
при создании проекта. Вместо них в репозитории `00_baseline.sql`.

## `00_baseline.sql` — восстановленная схема, не выгрузка

Файл **восстановлен** по коду `index.html`, README и AGENTS.md: таблицы, колонки,
представления и правила, которые приложение ожидает от базы. Он нужен, чтобы поднять
копию базы на локальном Postgres и проверять на ней миграции `07` и дальше.

**В живую базу его не запускать.** Там всё это уже есть.

Что в нём наверняка совпадает с живой базой: имена таблиц и колонок, которые клиент
читает и пишет напрямую, набор колонок представлений, правила из AGENTS.md.
Что могло отличаться: имена триггеров, политик и индексов, формула приоритета `score`,
точный текст ошибок. Для миграций это не важно: они не ссылаются на имена триггеров
и политик.

### Как сверить с живой базой

Выполнить в SQL Editor и сравнить с `00_baseline.sql`:

```sql
select table_name, column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
 order by table_name, ordinal_position;
```

Если колонка есть в живой базе, но нет в `00_baseline.sql`, дописать её в baseline
новым коммитом. Если наоборот, значит, клиент использует колонку, которой нет,
и это ошибка в клиенте.

### Когда заменить настоящей выгрузкой

Как только появится доступ к `pg_dump` (нужен пароль базы: Supabase → Project Settings →
Database → Connection string, режим **Session**):

```bash
pg_dump "postgresql://postgres.[ref]:[пароль]@aws-0-eu-central-1.pooler.supabase.com:5432/postgres" \
  --schema-only --no-owner --schema=public --file=db/00_baseline.sql
```

Выгрузка кладётся на место восстановленного файла тем же именем. Миграции `07+`
при этом не меняются.

## `07_rpc.sql` — нулевой этап концепции 2.0

- `activities.client_id` — клиентский идентификатор касания, повтор не создаёт дубль.
- `activities.author_id` по умолчанию `current_profile_id()`.
- `today_msk()`: день считается по Europe/Moscow. Представления пересобраны.
- `log_touch(...)`: контакт, статус лида и запись в журнал одной транзакцией.
- `create_lead(...)`: компания, контакты и лид одной транзакцией.

Применять **до** публикации `index.html` версии 9: клиент вызывает `rpc/log_touch`
и `rpc/create_lead`. SQL Editor выполняет файл одной транзакцией: при ошибке не
применится ничего, база останется прежней.

## `08_team.sql` — этап 1: команда и приглашения

- `profiles.started_at`, `active`, `ramp_enabled`. Функции доступа учитывают `active`.
- `invites` и триггер на `auth.users`: профиль создаётся только приглашённому.
- `apply_invites()`: приглашение для уже заведённого аккаунта.

После применения в Supabase включить регистрацию по почте (README, раздел «Доступы»).

## `09_plans.sql` — этап 2: план и разгон

- `plan_defaults`, `ramp_steps`, `plans`; `effective_plan(profile, day)`.
- `leads.owner_since` и обновлённый `leads_guard`.
- `v_kpi_day`, `v_kpi_week`, `v_kpi_month`, `v_team_today`, `v_plan_today`, `plan_streak()`.

## `10_scripts.sql` — этап 3: скрипты

- `scripts`, колонки `activities.script_id` и `objection_id`.
- `log_touch` пересоздан с двумя новыми параметрами. Старая сигнатура удалена:
  PostgREST не различает перегрузки. Клиент версии 9 продолжает работать,
  у новых параметров есть значения по умолчанию.
- Стартовые скрипты и возражения с фиксированными id.

## `11_lessons.sql` — этап 4: обучение и наставник

- `lessons`, `lesson_progress`, `coaching_notes`. Журнал касаний не тронут.
- Стартовые уроки с фиксированными id.

## `12_readonly.sql` — внешний доступ только на чтение

- Роль `crm_readonly`: только `select` на `profiles`, `tariffs`, `companies`,
  `contacts`, `leads`, `activities` и представление `v_leads`. Прав на запись нет.
- Политики `*_ext_read` — только `for select`. Второй рубеж на случай,
  если роли когда-нибудь по ошибке выдадут `grant insert`.
- `log_touch`, `create_lead`, `apply_invites` отобраны у роли `public`,
  явный грант `authenticated` остаётся: для CRM ничего не меняется.
- `crm_readonly_token(секрет, дней, ref)` выпускает ключ — JWT с claim
  `role = crm_readonly`. Секрет передаётся аргументом и нигде не сохраняется.
- Файл сам себя проверяет: читает под новой ролью и пробует записать.
  Если запись прошла — падает, и в базе не остаётся ничего.

Роль authenticated, её политики, представления и триггеры файл не трогает.
Ни одно представление не пересоздаётся, гранты не теряются.

Настройка коннектора и проверка — `docs/composio-readonly.md`.

## `13_key_check.sql` — разбор и проверка ключей

- `jwt_header(токен)`, `jwt_payload(токен)` — заголовок и полезная часть,
  читаются без секрета: роль, срок, алгоритм.
- `jwt_check(токен, секрет)` — сходится ли подпись. Проверять секрет по
  открытому `anon`-ключу проекта: он подписан тем же секретом.
- Данные, права и политики файл не трогает.

Нужен потому, что при неверном секрете база отвечает `PGRST301` без указания
причины, и отличить «не тот секрет» от «не тот алгоритм» по ответу нельзя.

Файлы `08`–`13` выполняются подряд, каждый заканчивается контрольной строкой.

## Правила

- `00_baseline.sql` отражает то, что уже выполнено. В живую базу не запускается.
- Любое изменение схемы: новый файл `NN_описание.sql`, только дописывающий.
  Существующие файлы не редактируются.
- Колонки добавлять только через `alter table ... add column if not exists`.
- Представления пересоздавать цепочкой `v_stats` → `v_today` → `v_leads`,
  каждое `with (security_invoker = true)`, после чего повторить `grant select`.
- Каждая новая таблица: RLS плюс явный `grant` для `authenticated`.
- Папку `supabase/` не создавать.

## Как проверять локально

Postgres 16. Роль `authenticated` и схема `auth` с `auth.users` и `auth.uid()` нужны
**до** `00_baseline.sql`, иначе гранты не применятся и тест соврёт:

```sql
create role authenticated nologin;
create schema auth;
create table auth.users (id uuid primary key, email text unique);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
```

Затем всю цепочку `db/*.sql` с нуля, каждый файл дважды. Роли проверять так:

```sql
set role authenticated;
set request.jwt.claim.sub = '<uuid из auth.users>';   -- админ, менеджер или посторонний
```

Посторонний (аккаунт без строки в `profiles`) должен видеть нули во всех таблицах
и представлениях, а вставка должна отбиваться политикой.
