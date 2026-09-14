-- ============================================================================
-- 18_fill_contacts.sql · Дозаполнение связи: номер, Instagram и 2ГИС
--
-- Зачем: у части лидов пустые номер, Instagram и 2ГИС, хотя данные в базе есть.
-- Их туда не положил разбор таблицы при загрузке:
--   • номер из ячейки вида «8 928 … доб. 5» или «два номера через пробел»
--     не распознавался и уходил в заметку, а не в контакт;
--   • Instagram вида «@ник» или «instagram.com/x» без протокола уходил в заметку;
--   • колонки, не разложенные по полям, целиком дописывались в заметку
--     строками «Заголовок: значение».
-- Плюс контакт, созданный из листа касания, мог получить phone_raw без
-- phone_e164: тогда номер в базе есть, но карточка показывает «телефона нет».
--
-- Что делает файл: достаёт из заметки (`companies.note`, `companies.todo`)
-- и из `contacts.phone_raw` то, что похоже на номер, ссылку Instagram и
-- ссылку 2ГИС, и заполняет ими ПУСТЫЕ поля. Заполненное не трогает,
-- заметки не чистит, ничего не удаляет.
--
-- Схему не меняет: ни таблиц, ни колонок, ни представлений, ни прав.
-- Идемпотентен: всё под `where ... is null`, второй прогон заполняет ноль строк.
-- Выполняется в SQL Editor одной транзакцией: при ошибке не применится ничего.
--
-- Номера берём только мобильные (9xx): в заметке рядом лежат средний чек,
-- число точек и год, и по ним легко собрать «номер», которого не существует.
-- Городской номер мобильным шаблоном не ловится — так и задумано,
-- звонить и писать в WhatsApp менеджер будет на мобильный.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Разбор текста. Функции временные: нужны только этому файлу, в конце
--    удаляются. Публичной поверхности базы не добавляют.
-- ---------------------------------------------------------------------------

-- Подстрока, похожая на мобильный номер: 9xx и группы 3-3-2-2, между группами
-- только пробел, дефис, скобка, точка или слэш. Цифра перед номером и сразу
-- после него запрещена: иначе шаблон выхватит середину id карточки 2ГИС.
create or replace function fill18_phone_src(txt text) returns text
language sql immutable as $$
  select substring($1 from
    '(?:^|[^0-9])((?:\+?7|8)?[ ()./-]*9[0-9]{2}[ ()./-]*[0-9]{3}[ ()./-]*[0-9]{2}[ ()./-]*[0-9]{2})(?![0-9])');
$$;

-- Тот же номер в формате базы: +7 и десять цифр (check на contacts.phone_e164).
create or replace function fill18_phone(txt text) returns text
language sql immutable as $$
  select case when s is null then null
              else '+7' || right(regexp_replace(s, '[^0-9]', '', 'g'), 10) end
    from (select fill18_phone_src($1) as s) q;
$$;

-- Ссылка на профиль Instagram: из ссылки (с протоколом и без) или из
-- «Instagram: @ник», как его записал разбор таблицы. Регистр не трогаем:
-- в коде поста он значащий, instagram.com/p/Cabc123 и /cabc123 — разные ссылки.
-- Служебные пути (/p/, /reel/) не ник: такую ссылку оставляем как есть.
create or replace function fill18_ig(txt text) returns text
language sql immutable as $fn$
  with link as (
    select (regexp_match(coalesce($1, ''),
      '((?:https?://)?(?:[a-z0-9_-]+\.)*(?:instagram\.com|instagr\.am)/([^[:space:],;|)"''?#]+))',
      'i'))[1] as u,
           (regexp_match(coalesce($1, ''),
      '(?:https?://)?(?:[a-z0-9_-]+\.)*(?:instagram\.com|instagr\.am)/([^[:space:],;|)"''?#]+)',
      'i'))[1] as path
  ),
  nick as (
    select (regexp_match(coalesce($1, ''),
      '(?:instagram|инстаграм|инста)[^a-z0-9_@]{0,4}@?([a-z0-9_.]{3,30})', 'i'))[1] as h
  )
  select case
    when (select path from link) is not null then
      case
        when split_part((select path from link), '/', 1)
             ~* '^(p|reel|reels|stories|explore|tv|s|direct|accounts)$'
          then case when (select u from link) ~* '^https?://' then (select u from link)
                    else 'https://' || (select u from link) end
        else 'https://www.instagram.com/' || split_part((select path from link), '/', 1)
      end
    when (select h from nick) is not null
         and lower((select h from nick)) not in
             ('net','no','none','nan','null','yes','www','http','https','com','ru')
      then 'https://www.instagram.com/' || (select h from nick)
  end;
$fn$;

-- Ссылка 2ГИС: с протоколом и без, включая короткую go.2gis.com.
create or replace function fill18_gis(txt text) returns text
language sql immutable as $fn$
  select case when u is null then null
              when u ~* '^https?://' then u
              else 'https://' || u end
    from (select (regexp_match(coalesce($1, ''),
            '((?:https?://)?(?:[a-z0-9_-]+\.)*2gis\.[a-z]{2,6}/[^[:space:],;|)"''?#]+)',
            'i'))[1] as u) q;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Дозаполнение. Отчёт собираем во временную таблицу: в SQL Editor виден
--    результат последнего запроса, а заполняющих запросов четыре.
-- ---------------------------------------------------------------------------
drop table if exists pg_temp.fill18_report;
create temp table fill18_report (step text, n int);

do $$
declare k int;
begin
  -- 2.1. Номер лежит в phone_raw, а phone_e164 пуст: контакт есть,
  --      но карточка показывает «телефона нет», и позвонить нельзя.
  update contacts c set phone_e164 = fill18_phone(c.phone_raw)
   where c.phone_e164 is null
     and fill18_phone(c.phone_raw) is not null
     and not exists (select 1 from contacts o
                      where o.company_id = c.company_id
                        and o.phone_e164 = fill18_phone(c.phone_raw));
  get diagnostics k = row_count;
  insert into fill18_report values ('1. номер из phone_raw', k);

  -- 2.2. У компании нет ни одного номера, но номер есть в заметке.
  --      Создаём основной контакт. Компании, где основной контакт уже есть,
  --      пропускаем: основной на компанию один (contacts_one_primary).
  insert into contacts (company_id, phone_e164, phone_raw, is_primary)
  select co.id, fill18_phone(t.txt), fill18_phone_src(t.txt), true
    from companies co
    join lateral (select concat_ws(E'\n', co.note, co.todo) as txt) t on true
   where fill18_phone(t.txt) is not null
     and not exists (select 1 from contacts c
                      where c.company_id = co.id
                        and (c.phone_e164 is not null or c.is_primary));
  get diagnostics k = row_count;
  insert into fill18_report values ('2. основной номер из заметки', k);

  -- 2.5. Номер у компании есть, но ни один контакт не основной: карточка
  --      берёт номер для кнопки «Позвонить» и WhatsApp только из основного,
  --      поэтому такой лид выглядит как лид без номера. Помечаем основным
  --      первый контакт с номером — так же, как это делает create_lead,
  --      когда номер ЛПР совпадает с общим.
  update contacts c set is_primary = true
   where c.id in (
     select distinct on (x.company_id) x.id
       from contacts x
      where x.phone_e164 is not null
        and not exists (select 1 from contacts o
                         where o.company_id = x.company_id and o.is_primary)
      order by x.company_id, x.is_decision_maker desc, x.created_at, x.id);
  get diagnostics k = row_count;
  insert into fill18_report values ('2.5. основным помечен контакт с номером', k);

  -- 2.3. Instagram пуст, а в заметке ссылка или ник.
  update companies co set instagram_url = fill18_ig(concat_ws(E'\n', co.note, co.todo))
   where co.instagram_url is null
     and fill18_ig(concat_ws(E'\n', co.note, co.todo)) is not null;
  get diagnostics k = row_count;
  insert into fill18_report values ('3. Instagram из заметки', k);

  -- 2.4. 2ГИС пуст, а в заметке ссылка. Ссылка на поиск тоже годится:
  --      карточка подписывает такую кнопку «поиск».
  update companies co set gis_url = fill18_gis(concat_ws(E'\n', co.note, co.todo))
   where co.gis_url is null
     and fill18_gis(concat_ws(E'\n', co.note, co.todo)) is not null;
  get diagnostics k = row_count;
  insert into fill18_report values ('4. 2ГИС из заметки', k);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Уборка: временные функции базе не нужны.
-- ---------------------------------------------------------------------------
drop function if exists fill18_gis(text);
drop function if exists fill18_ig(text);
drop function if exists fill18_phone(text);
drop function if exists fill18_phone_src(text);

-- Контроль: что заполнено этим прогоном и сколько пустых полей осталось.
-- Осталось — это те лиды, где данных в базе нет совсем: их даёт только
-- повторная загрузка таблицы или поиск руками (кнопки «поиск» в карточке).
select
  (select string_agg(step || ': ' || n, ' · ' order by step) from fill18_report) as filled,
  (select count(*) from companies co
    where not exists (select 1 from contacts c
                       where c.company_id = co.id and c.phone_e164 is not null)) as left_no_phone,
  (select count(*) from companies where instagram_url is null) as left_no_instagram,
  (select count(*) from companies where gis_url is null) as left_no_gis;
