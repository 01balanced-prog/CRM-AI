# Схема базы

Здесь должны лежать SQL-файлы по порядку номеров. Сейчас их нет: схема, политики RLS,
триггеры и представления существуют только внутри Supabase. Пока это так, ни одну новую
миграцию нельзя проверить, а раздел README «Если база потеряна» не выполним.

## Как выгрузить схему один раз

Нужен `pg_dump` версии 15 или новее (есть в установке PostgreSQL, на Mac: `brew install libpq`).
Строка подключения: Supabase → Project Settings → Database → Connection string,
режим **Session**, подставить пароль базы.

```bash
pg_dump "postgresql://postgres.[ref]:[пароль]@aws-0-eu-central-1.pooler.supabase.com:5432/postgres" \
  --schema-only --no-owner \
  --schema=public \
  --file=db/00_baseline.sql
```

Что должно оказаться в файле: таблицы `profiles`, `companies`, `contacts`, `leads`,
`activities`, `tariffs`, `custom_pricing`; представления `v_leads`, `v_today`, `v_stats`;
функции `is_staff()`, `current_profile_id()` и триггерные функции; все политики RLS
и `grant`. Если чего-то нет, значит, выгрузка неполная.

Если `pg_dump` недоступен, второй вариант: те же шесть файлов, которые вставлялись
в SQL Editor при создании проекта. Положить их как `01_schema.sql` … `06_*.sql`,
не редактируя.

## Правила

- `00_baseline.sql` (или `01`–`06`) отражают то, что уже выполнено. Повторно не запускаются.
- Любое изменение схемы: новый файл `NN_описание.sql`, только дописывающий.
- Колонки добавлять только через `alter table ... add column if not exists`.
- Представления пересоздавать цепочкой `v_stats` → `v_today` → `v_leads`,
  каждое `with (security_invoker = true)`, после чего повторить `grant select`.
- Папку `supabase/` не создавать.
