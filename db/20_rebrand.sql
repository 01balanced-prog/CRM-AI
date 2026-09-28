-- ============================================================================
-- 20_rebrand.sql · Ребрендинг: Balance теперь Даима
--
--   Стартовые скрипты звонков, шаблоны сообщений и урок о продукте называли
--   компанию Balance. Меняем название в текстах:
--     «из Balance»  → «из компании Даима» (так не нужно склонять название);
--     остальное     → «Даима» («компания Даима, Грозный», «Даима внедряет Агента»).
--
--   Правки админа не трогаем: обновляются только строки, которые никто не
--   редактировал (updated_by пуст). Если админ правил текст сам, а «Balance» там
--   осталось, контрольная строка это покажет, поправить в «Скриптах» / «Обучении».
--
-- Схема, права и представления не меняются. Файл идемпотентен: после первого
-- запуска искать уже нечего.
-- ============================================================================

update scripts
   set body = replace(replace(body, 'из Balance', 'из компании Даима'), 'Balance', 'Даима')
 where updated_by is null and body like '%Balance%';

update lessons
   set body = replace(replace(body, 'из Balance', 'из компании Даима'), 'Balance', 'Даима')
 where updated_by is null and body like '%Balance%';

-- Контроль: stale_0 — в нетронутых текстах «Balance» не осталось.
-- admin_edited — сколько текстов, правленных админом, ещё говорят «Balance»
-- (их файл не трогает, поправить руками; 0 — править нечего).
select
  (select count(*) from scripts where updated_by is null and body like '%Balance%')
  + (select count(*) from lessons where updated_by is null and body like '%Balance%') as stale_0,
  (select count(*) from scripts where updated_by is not null and (body like '%Balance%' or title like '%Balance%'))
  + (select count(*) from lessons where updated_by is not null and (body like '%Balance%' or title like '%Balance%')) as admin_edited;
