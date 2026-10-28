# DASH-D0 — аудит источников данных Supabase для дашборда

**Статус: 🔄 D0 не завершён.** DASH-D0-01 (аудит репозитория, 28.10.2026) и DASH-D0-02 (закрепление контракта метрик по read-only аудиту руководителя проекта, 28.10.2026) выполнены. Структура и SQL-логика четырёх KPI подтверждены; **права доступа, полнота истории этапов и фактическая полнота данных не подтверждены**. D1 не начат.

Документ не содержит паролей, Telegram ID, телефонов, имён, текстов сообщений, идентификаторов диалогов и полных определений SQL-функций. Логика функций описана своими словами.

## 1. Источники и уровни подтверждения

| Источник | Что дал |
|---|---|
| Репозиторий: `PLAN.md`, `DB_AUDIT.md`, `DB_WORKFLOW_CONTRACT.md`, `docs/*.md`, `workflows/current/*.json` | Роли и права по SQL №6–№8, вызовы функций из n8n, конфигурация этапов, цели и таймеров (DASH-D0-01) |
| Read-only аудит живой Supabase, выполненный руководителем проекта | Имена таблиц, поведение функций входа, цели, заявки, этапов и потери, содержание `audit_dashboard_summary`, признак тестовых пользователей (DASH-D0-02) |

У исполнителя VSCode прямого доступа к Supabase по-прежнему нет; факты уровня ✅Б приняты из отчёта руководителя и исполнителем не перепроверялись.

- ✅А — подтверждено отчётами SQL пользователя, записанными в репозитории;
- ✅Б — подтверждено read-only аудитом руководителя проекта (DASH-D0-02);
- 🟡 — видно только по коду n8n Workflow;
- ❓ — не подтверждено.

## 2. Подтверждённая структура

| Объект | Факт | Уровень |
|---|---|---|
| Схема `katona` | **36 таблиц** (SQL №3 создавал 35 — какая таблица добавлена позже, не зафиксировано) | ✅Б, ❓ 36-я |
| `dialogi` | Логический диалог; столбцы `vremya_nachala`, `status`, `rezultat` | ✅Б |
| `celevye_sobytiya` | Подтверждённые целевые события; столбец `kod_celi` | ✅Б |
| `zayavki` | Заявки, создаются из целевого события `ostavit_zayavku` при выполнении условий | ✅Б |
| `sobytiya_etapov` | Смены этапов при подтверждённых исходящих действиях | ✅Б |
| `sobytiya_dialogov` | Существует; роль для метрик не описана | ✅Б, ❓ назначение |
| Прочие известные таблицы | `soobshcheniya` (уникальность `(dialog_id, vneshnee_soobshchenie_id)`), `ishodyashchie_deystviya`, `operator_telegram_temy`, `sobytiya_integraciy`, `audit_uvedomleniya`, таблицы базы знаний | ✅А |
| Признак теста | У пользователей есть `testovyy`; у текущих пилотных тестировщиков он `false` | ✅Б |

**Не подтверждены точные имена:** первичного ключа `dialogi` и ссылок на него из `celevye_sobytiya` / `zayavki` / `sobytiya_etapov`, столбцов канала, текущего этапа и владельца в `dialogi`, таблицы с `testovyy`, тип `dialogi.vremya_nachala` (ожидается `timestamptz NOT NULL`). Ниже ключ диалога обозначен как `dialog_id`.

## 3. Подтверждённая SQL-логика (✅Б)

1. **Новый диалог.** `zaregistrirovat_vhod_klienta` создаёт строку `dialogi`, только если у идентификатора канала нет незавершённого диалога; иначе вход добавляется в существующий. Повторные входные события проверяются на дубликаты. Следствие: после закрытия диалога (в т.ч. потерей) новое сообщение того же клиента создаёт **новый** диалог и считается новым обращением.
2. **Готовность цели.** `audit_goal_ready` требует подтверждённых имени и телефона.
3. **Согласие клиента.** `sozdat_ishodyashchee_deystvie` при попытке установить целевой этап или код цели дополнительно требует текстового признака согласия клиента. Предложение этапа LLM-планировщиком (см. DASH-D0-01) само по себе цель не фиксирует.
4. **Фиксация цели.** `zafiksirovat_rezultat_ishodyashchego` применяет целевые эффекты только после подтверждённой отправки сообщения и проверки, что состояние диалога не устарело. Тогда пишется строка в `celevye_sobytiya`; при `kod_celi='ostavit_zayavku'` и выполнении условий создаётся строка `zayavki`.
5. **Этапы.** Изменения этапа при подтверждённых исходящих действиях пишутся в `sobytiya_etapov`. Полнота истории для **остальных маршрутов не доказана**.
6. **Потеря.** `zafiksirovat_poteryu_bez_otveta` закрывает диалог: `status='zavershen'`, `rezultat='net_otveta'` — после подтверждённого второго напоминания, при отсутствии нового ответа клиента и выполнении остальных защитных условий.
7. **`audit_dashboard_summary`** возвращает общие и технические счётчики **без фильтра по периоду**. Это не продажный API: для KPI, динамики и таблицы дашборда в D1 нужен отдельный read-only контракт. Функцию можно рассматривать позже как источник технического индикатора, не KPI.

## 4. Контракт четырёх KPI (проект для утверждения в D1)

### Единая когорта

- Когорта периода `C` = диалоги `dialogi` с `vremya_nachala` в полуинтервале `[from, to)`.
- Пользователь выбирает даты в `Europe/Moscow` включительно; backend переводит их в `[from 00:00 MSK, (to + 1 день) 00:00 MSK)` и сравнивает с `timestamptz` без ручного сдвига часов.
- Все четыре KPI считаются **по одной когорте**; цель и потеря оцениваются на момент запроса (`data_as_of`). Цифры прошлых периодов могут меняться, если диалог дошёл до цели или был закрыт позже, — UI это поясняет.
- Пилотные данные исключаются правилом из `01_METRICS_AND_DATA.md` (пока не реализовано, см. §6).

### Формулы

Псевдо-SQL для фиксации смысла, **не для запуска**: имена ключей уточняются (§2).

```text
C               = SELECT dialog_id FROM dialogi
                  WHERE vremya_nachala >= :from_ts AND vremya_nachala < :to_ts
                    AND <правило исключения пилотных данных>

new_dialogues   = COUNT(DISTINCT dialog_id) FROM C

target_reached  = COUNT(DISTINCT c.dialog_id) FROM C c
                  WHERE EXISTS (SELECT 1 FROM celevye_sobytiya ce
                                WHERE ce.dialog_id = c.dialog_id
                                  AND ce.kod_celi = 'ostavit_zayavku')

conversion_pct  = ROUND(100.0 * target_reached / new_dialogues, 1);  при new_dialogues = 0 → «—»

lost_dialogues  = COUNT(DISTINCT c.dialog_id) FROM C c JOIN dialogi d USING (dialog_id)
                  WHERE d.status = 'zavershen' AND d.rezultat = 'net_otveta'
                    AND NOT EXISTS (целевое событие ostavit_zayavku у этого диалога)
```

- **Достигли цели** = наличие подтверждённого события в `celevye_sobytiya` с кодом цели компании `ostavit_zayavku` (из конфигурации `cel.kod`). Не этап из ответа LLM, не упоминание контакта и не строка `zayavki`.
- **Потерянные** = только `rezultat='net_otveta'`. Другие итоговые значения (`zapret_iniciativy`, отказ и т.п.) потерей не считаются, пока руководитель не решит иначе. Исключение диалогов с целью — защитное: пересечение «цель и потеря» должно быть 0 и проверяется (§7).
- **Динамика:** `new_dialogues` по локальной дате `vremya_nachala` (MSK), дни без обращений — 0. Вторая серия — `target_reached` той же дневной когорты.

### Остальные элементы

| Элемент | Решение на сейчас |
|---|---|
| Воронка | **Не показывать как воронку**, пока не проверены все маршруты записи этапов (§7.5). До этого — «Распределение по текущим этапам» из текущего этапа `dialogi` (столбец уточнить) |
| Ожидают менеджера | Скрыто, пока не подтверждены столбцы и значения «запрошено, не взято» в `dialogi` |
| Последние обращения | Безопасные поля `dialogi`: время начала, канал, этап, `status`, `rezultat`, признак цели; без ПД |
| Фильтр канала | Не показывать: активен только Telegram (🟡) |

## 5. Сводная таблица

| Метрика | Источник | Структура и логика | Права | Полнота данных |
|---|---|---|---|---|
| Новые обращения | `dialogi.vremya_nachala` | ✅Б | ❓ | ❓ пилотные данные не исключаются |
| Достигли цели | `celevye_sobytiya.kod_celi='ostavit_zayavku'` | ✅Б | ❓ | ❓ |
| Конверсия | Производная | ✅Б | ❓ | ❓ |
| Потерянные | `dialogi.status='zavershen'` + `rezultat='net_otveta'` | ✅Б | ❓ | ❓ |
| Динамика | `dialogi.vremya_nachala` по дням MSK | ✅Б | ❓ | ❓ |
| Воронка | `sobytiya_etapov` | 🟡 частично (только подтверждённые исходящие) | ❓ | ❓ |
| Распределение по этапам | Текущий этап `dialogi` | ❓ столбец | ❓ | ❓ |
| Ожидают менеджера | `dialogi` (этап/владелец) | ❓ | ❓ | ❓ |

## 6. Права доступа — не подтверждены

Из репозитория (✅А): `katona_dashboard_read` — NOLOGIN, EXECUTE на одну функцию, прямых прав на таблицы нет; LOGIN-ролей для дашборда нет. Какая это функция, есть ли у роли участники, открыта ли схема `katona` для `anon`/`authenticated`, владелец и `search_path` функций — **не проверено**. Это закрывают SQL-D0-1 и SQL-D0-2 (§8). Способ подключения backend проектируется в D1 и создаётся только отдельным SQL с разрешения пользователя.

## 7. Оставшиеся проверки перед проектированием backend

1. **Права:** результаты SQL-D0-1 и SQL-D0-2 — участники и LOGIN у `katona_dashboard_read`, доступ `anon`/`authenticated` к `katona`, владелец и `search_path` функций.
2. **Ключи и типы:** имена PK `dialogi` и ссылок из `celevye_sobytiya`, `zayavki`, `sobytiya_etapov`; `vremya_nachala` — `timestamptz NOT NULL`; столбцы канала, текущего этапа и владельца (SQL-D0-4 по этим таблицам).
3. **Уникальность цели:** допускает ли `celevye_sobytiya` несколько событий одного кода на диалог; одна ли заявка на диалог; связана ли `zayavki` с `celevye_sobytiya` (SQL-D0-5).
4. **Статусы:** все допустимые значения `dialogi.status` и `rezultat` (CHECK, SQL-D0-5); агрегатом проверить, что пересечение «цель и `net_otveta`» = 0.
5. **Маршруты этапов:** пишет ли `sobytiya_etapov` начальный этап при создании диалога, `zaprosit_cheloveka` (`peredacha_cheloveku`), захват/возврат оператором, ручные сообщения менеджера, предупреждения/блокировку и закрытие потерей. Пока хоть один маршрут меняет этап без записи — только «Распределение по текущим этапам».
6. **Согласие клиента:** откуда берётся текстовый признак согласия (сообщение клиента или поле ответа модели) и может ли модель выставить его сама.
7. **Пилотные данные:** решение руководителя по правилу исключения (`01_METRICS_AND_DATA.md`).
8. **Ожидают менеджера:** точные значения этапа и владельца для «запрошено, не взято».
9. **36-я таблица:** какая таблица добавлена после SQL №3 и нужна ли она дашборду.

## 8. SELECT-only SQL (DASH-D0-01)

Запросы ниже не меняют БД и не читают ПД. Если руководитель уже выполнил какие-то из них в своём аудите, повторять не нужно; для §7.1–7.4 достаточно SQL-D0-1, -2, -4, -5 и одного агрегата пересечения, который будет подготовлен по подтверждённым именам ключей.

- Каждый блок — **один** `SELECT`; запускать по одному, результат экспортировать в CSV.
- SQL-D0-6 и SQL-D0-7 читают данные только как **агрегаты**; в SQL-D0-7 любое значение, не похожее на код (`[a-z][a-z0-9_]*`, в т.ч. чисто числовые ID), заменяется на `[скрыто]`.
- Результат SQL-D0-3 (тексты функций) **не коммитить** в публичный репозиторий.
- Если запрос падает — прислать текст ошибки, не исправлять SQL самостоятельно.

### SQL-D0-1 — роли, членство и изоляция

```sql
SELECT r.rolname,
       r.rolcanlogin,
       r.rolinherit,
       r.rolsuper,
       r.rolbypassrls,
       COALESCE((SELECT string_agg(g.rolname, ', ' ORDER BY g.rolname)
                   FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
                  WHERE m.member = r.oid), '') AS member_of,
       COALESCE((SELECT string_agg(u.rolname, ', ' ORDER BY u.rolname)
                   FROM pg_auth_members m JOIN pg_roles u ON u.oid = m.member
                  WHERE m.roleid = r.oid), '') AS members,
       has_schema_privilege(r.oid, 'katona', 'USAGE') AS katona_usage,
       (SELECT count(*) FROM pg_namespace n
         WHERE n.nspname = 'qbit_bot_pervichnogo_obrascheniya'
           AND has_schema_privilege(r.oid, n.oid, 'USAGE')) AS qbit_usage,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'katona' AND c.relkind IN ('r', 'p', 'v', 'm')
           AND has_table_privilege(r.oid, c.oid, 'SELECT')) AS katona_tables_select,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'katona'
           AND has_function_privilege(r.oid, p.oid, 'EXECUTE')) AS katona_functions_execute
  FROM pg_roles r
 WHERE r.rolname LIKE 'katona%'
    OR r.rolname IN ('anon', 'authenticated', 'authenticator', 'service_role')
 ORDER BY r.rolname;
```

Ожидаем: у `katona_dashboard_read` `rolcanlogin=false`, `qbit_usage=0`, `katona_tables_select=0`, `katona_functions_execute=1`; `members` показывает, есть ли LOGIN-участник. Строки `anon`/`authenticated` показывают, открыта ли схема для Supabase API.

### SQL-D0-2 — функции схемы и права вызова

```sql
SELECT p.proname,
       pg_get_function_identity_arguments(p.oid) AS args,
       pg_get_function_result(p.oid) AS returns,
       p.prosecdef AS security_definer,
       p.provolatile,
       pg_get_userbyid(p.proowner) AS owner,
       COALESCE(array_to_string(p.proconfig, '; '), '') AS config,
       has_function_privilege('katona_dashboard_read', p.oid, 'EXECUTE') AS dash_read,
       has_function_privilege('katona_dashboard_admin', p.oid, 'EXECUTE') AS dash_admin,
       has_function_privilege('katona_bot', p.oid, 'EXECUTE') AS bot,
       has_function_privilege('katona_service', p.oid, 'EXECUTE') AS service
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'katona' AND p.prokind = 'f'
 ORDER BY p.proname;
```

### SQL-D0-3 — тексты функций, определяющих метрики

```sql
SELECT p.oid::regprocedure::text AS signature,
       length(pg_get_functiondef(p.oid)) AS def_length,
       md5(pg_get_functiondef(p.oid)) AS def_md5,
       pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'katona'
   AND p.prokind = 'f'
   AND (p.proname LIKE '%dashboard%'
        OR p.proname IN ('zaregistrirovat_vhod_klienta',
                         'sozdat_ishodyashchee_deystvie',
                         'zaprosit_cheloveka',
                         'zabrat_dialog_operatorom',
                         'vernut_dialog_botu',
                         'obrabotat_sleduyushchee_napominanie',
                         'ustanovit_zapret_iniciativy',
                         'poluchit_sostoyanie_operatora',
                         'sohranit_fakty_i_pamyat',
                         'zavershit_zadanie_obrabotki'))
 ORDER BY p.proname;
```

### SQL-D0-4 — таблицы и столбцы (только метаданные)

```sql
SELECT c.table_name,
       c.ordinal_position,
       c.column_name,
       c.data_type,
       c.udt_name,
       c.is_nullable,
       left(COALESCE(c.column_default, ''), 80) AS column_default
  FROM information_schema.columns c
 WHERE c.table_schema = 'katona'
 ORDER BY c.table_name, c.ordinal_position;
```

### SQL-D0-5 — ограничения, уникальные индексы и триггеры

```sql
SELECT cl.relname AS table_name,
       con.conname AS object_name,
       con.contype::text AS kind,
       pg_get_constraintdef(con.oid) AS definition
  FROM pg_constraint con
  JOIN pg_class cl ON cl.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = cl.relnamespace
 WHERE n.nspname = 'katona' AND con.contype IN ('p', 'u', 'c', 'f')
UNION ALL
SELECT i.tablename, i.indexname, 'unique_index', i.indexdef
  FROM pg_indexes i
 WHERE i.schemaname = 'katona' AND i.indexdef ILIKE 'CREATE UNIQUE INDEX%'
UNION ALL
SELECT c.relname, t.tgname, 'trigger:' || t.tgenabled::text, pg_get_triggerdef(t.oid)
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'katona' AND NOT t.tgisinternal
 ORDER BY 1, 3, 2;
```

### SQL-D0-6 — объём таблиц (только количество строк)

```sql
SELECT c.relname AS table_name,
       c.reltuples::bigint AS estimate,
       (xpath('/row/cnt/text()',
              query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', n.nspname, c.relname),
                           false, true, '')))[1]::text::bigint AS exact_rows
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'katona' AND c.relkind IN ('r', 'p')
 ORDER BY c.relname;
```

### SQL-D0-7 — фактические значения кодовых столбцов (агрегаты, без ПД)

```sql
WITH cols AS (
    SELECT c.table_name, c.column_name
      FROM information_schema.columns c
     WHERE c.table_schema = 'katona'
       AND c.data_type IN ('text', 'character varying')
       AND c.column_name ~ '^(status[a-z_]*|etap[a-z_]*|tekushchiy_etap|vladelec[a-z_]*|kanal|kanal_vhoda|sreda|istochnik|tip[a-z_]*|vid_deystviya|napravlenie|rezultat[a-z_]*|itog[a-z_]*)$'
), agg AS (
    SELECT cols.table_name, cols.column_name,
           query_to_xml(format(
               'SELECT CASE WHEN %1$I ~ ''^[a-z][a-z0-9_]{0,39}$'' THEN %1$I ELSE ''[скрыто]'' END AS v, '
               'count(*) AS cnt FROM %2$I.%3$I GROUP BY 1 ORDER BY 2 DESC LIMIT 30',
               cols.column_name, 'katona', cols.table_name), false, false, '') AS x
      FROM cols
)
SELECT a.table_name,
       a.column_name,
       (xpath('/row/v/text()', r))[1]::text AS value,
       (xpath('/row/cnt/text()', r))[1]::text::bigint AS cnt
  FROM agg a, unnest(xpath('/table/row', a.x)) AS r
 ORDER BY 1, 2, 4 DESC;
```

`NULL` в `value` означает пустое значение столбца.

## 9. Готовность D0

- ✅ DASH-D0-01: репозиторий и Workflow изучены, SELECT-only SQL подготовлен.
- ✅ DASH-D0-02: структура и SQL-логика 4 KPI закреплены; формулы и правило единой когорты по `dialogi.vremya_nachala` записаны как проект для утверждения.
- ⬜ Проверки §7 — прежде всего права (7.1), ключи (7.2), уникальность цели (7.3) и правило пилотных данных (7.7).
- ⬜ Воронка не подтверждена; до проверки маршрутов (7.5) — только распределение по текущим этапам.

D1 не начат и не объявлен готовым.
