# DASH-D0 — аудит источников данных Supabase для дашборда

**Статус: ✅ D0 закрыт как основание для проектирования D1; два условия перенесены в условия рабочего запуска.** Выполнены DASH-D0-01 (аудит репозитория), DASH-D0-02 (контракт метрик), DASH-D0-03 (аудит прав) и итоговые проверки данных — все 28.10.2026. Ключи, FK и уникальность целевых данных проверены, формулы 4 KPI утверждены, текущие этапы согласованы с историей. **Не доказаны:** полнота истории этапов по всем маршрутам (воронка не показывается) и достоверная классификация тестовых обращений — **обязательное условие рабочего запуска** (§7). Проект SQL/API — [`05_SQL_API_DESIGN.md`](05_SQL_API_DESIGN.md) (D1-01); D1 не завершён.

Документ не содержит паролей, Telegram ID, телефонов, имён, текстов сообщений, идентификаторов диалогов и полных определений SQL-функций. Логика функций описана своими словами.

## 1. Источники и уровни подтверждения

| Источник | Что дал |
|---|---|
| Репозиторий: `PLAN.md`, `DB_AUDIT.md`, `DB_WORKFLOW_CONTRACT.md`, `docs/*.md`, `workflows/current/*.json` | Роли и права по SQL №6–№8, вызовы функций из n8n, конфигурация этапов, цели и таймеров (DASH-D0-01) |
| Read-only аудит живой Supabase, выполненный руководителем проекта | Имена таблиц, поведение функций входа, цели, заявки, этапов и потери, содержание `audit_dashboard_summary`, признак тестовых пользователей (DASH-D0-02); права ролей и владельцы функций (DASH-D0-03) |

У исполнителя VSCode прямого доступа к Supabase по-прежнему нет; факты уровня ✅Б приняты из отчёта руководителя и исполнителем не перепроверялись.

- ✅А — подтверждено отчётами SQL пользователя, записанными в репозитории;
- ✅Б — подтверждено read-only аудитом руководителя проекта (DASH-D0-02/03);
- 🟡 — видно только по коду n8n Workflow;
- ❓ — не подтверждено.

## 2. Подтверждённая структура

| Объект | Факт | Уровень |
|---|---|---|
| Схема `katona` | **36 таблиц**: 35 из SQL №3 и `kb_popytki_v2`, созданная для загрузки знаний (`docs/11_KB_B3_DATABASE_DESIGN.md`); дашборду не нужна | ✅Б / ✅А |
| `dialogi` | Логический диалог; столбцы `vremya_nachala`, `status`, `rezultat` | ✅Б |
| `celevye_sobytiya` | Целевые события; столбцы `dialog_id`, `kod_celi`, `podtverzhdeno` | ✅Б |
| `zayavki` | Заявки, создаются из целевого события `ostavit_zayavku` при выполнении условий | ✅Б |
| `sobytiya_etapov` | Смены этапов при подтверждённых исходящих действиях | ✅Б |
| `sobytiya_dialogov` | Существует; роль для метрик не описана | ✅Б, ❓ назначение |
| Прочие известные таблицы | `soobshcheniya` (уникальность `(dialog_id, vneshnee_soobshchenie_id)`), `ishodyashchie_deystviya`, `operator_telegram_temy`, `sobytiya_integraciy`, `audit_uvedomleniya`, таблицы базы знаний | ✅А |
| Признак теста | `polzovateli.testovyy`; у текущих тестировщиков он `false` | ✅Б |

**По предоставленной выгрузке структуры:** `dialogi.id` — ключ диалога; `celevye_sobytiya.dialog_id`, `zayavki.dialog_id`, `sobytiya_etapov.dialog_id` — ссылки на диалог; `dialogi.vremya_nachala` — `timestamptz NOT NULL`. FK основных таблиц подтверждены SQL-аудитом руководителя. У `polzovateli` есть признаки `testovyy` и `sluzhebnyy`; для уже созданных тестовых обращений оба ненадёжны (§7). Подтверждены также `dialogi.etap text`, `dialogi.status text` (CHECK: `aktivnyy`, `ozhidaet_otveta`, `peredan_cheloveku`, `zavershen`), `dialogi.polzovatel_id uuid` и `dialogi.identifikator_kanala_id uuid` → `identifikatory_kanalov.id`, канал — `identifikatory_kanalov.kanal text`. Столбца `dialogi.kanal` нет.

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
- Тестовые обращения в рабочей версии должны исключаться по достоверной классификации, без произвольного порога даты. Отдельного пилотного этапа нет. Правило пока не реализовано, см. `01_METRICS_AND_DATA.md`.

### Формулы

Псевдо-SQL для фиксации смысла, **не для запуска**: имена ключей подтверждены ранее выданной структурой, FK/уникальность и права ещё предстоит проверить.

```text
C               = SELECT id AS dialog_id FROM dialogi
                  WHERE vremya_nachala >= :from_ts AND vremya_nachala < :to_ts
                    AND <достоверное исключение тестовых/служебных обращений>

new_dialogues   = COUNT(DISTINCT dialog_id) FROM C

target_reached  = COUNT(DISTINCT c.dialog_id) FROM C c
                  WHERE EXISTS (SELECT 1 FROM celevye_sobytiya ce
                                WHERE ce.dialog_id = c.dialog_id
                                  AND ce.kod_celi = 'ostavit_zayavku'
                                  AND ce.podtverzhdeno = true)

conversion_pct  = ROUND(100.0 * target_reached / new_dialogues, 1);  при new_dialogues = 0 → «—»

lost_dialogues  = COUNT(DISTINCT d.id) FROM C c JOIN dialogi d ON d.id=c.dialog_id
                  WHERE d.status = 'zavershen' AND d.rezultat = 'net_otveta'

anomaly_both    = число диалогов C, удовлетворяющих и lost_dialogues, и target_reached
                  (контроль качества; не скрывать эти записи из KPI)
```

- **Достигли цели** = наличие события в `celevye_sobytiya` с кодом цели компании `ostavit_zayavku` (из конфигурации `cel.kod`) **и `podtverzhdeno=true`**; события без подтверждения не считаются. Не этап из ответа LLM, не упоминание контакта и не строка `zayavki`.
- **Потерянные** = текущие `status='zavershen'` и `rezultat='net_otveta'`. Отказ и другие причины не считаются потерей.
- **Аномалия «цель и потеря»:** такой диалог остаётся **в обоих** KPI (`target_reached` и `lost_dialogues`). API возвращает число `anomaly_both` отдельно, UI показывает предупреждение о несогласованности данных. Поэтому `target_reached + lost_dialogues` может превышать число завершённых диалогов — это ожидаемо и поясняется в подсказке.
- **Динамика:** `new_dialogues` по локальной дате `vremya_nachala` (MSK), дни без обращений — 0. Вторая серия — `target_reached` той же дневной когорты.

### Остальные элементы

| Элемент | Решение на сейчас |
|---|---|
| Воронка | **Не показывать как воронку**, пока не доказана полнота всех маршрутов записи этапов (§7, условие 1). До этого — «Распределение по текущим этапам» из `dialogi.etap` |
| Ожидают менеджера | Скрыто, пока не подтверждены столбцы и значения «запрошено, не взято» в `dialogi` |
| Последние обращения | Безопасные поля `dialogi`: время начала, канал, этап, `status`, `rezultat`, признак цели; без ПД |
| Фильтр канала | Не показывать: активен только Telegram (🟡) |

## 5. Сводная таблица

| Метрика | Источник | Структура и логика | Права | Полнота данных |
|---|---|---|---|---|
| Новые обращения | `dialogi.vremya_nachala` | ✅Б | ⛔ → D1 | ⚠️ тестовые обращения не классифицированы |
| Достигли цели | `celevye_sobytiya`: `kod_celi='ostavit_zayavku'`, `podtverzhdeno=true` | ✅Б | ⛔ → D1 | ✅ дублей 0 |
| Конверсия | Производная | ✅Б | ⛔ → D1 | ⚠️ как обращения |
| Потерянные | `dialogi.status='zavershen'` + `rezultat='net_otveta'` | ✅Б | ⛔ → D1 | ✅ пересечение с целью 0 |
| Динамика | `dialogi.vremya_nachala` по дням MSK | ✅Б | ⛔ → D1 | ⚠️ как обращения |
| Воронка | `sobytiya_etapov` | 🟡 записи есть у всех диалогов, полнота маршрутов не доказана | — | ❌ в v1.0 не показывается |
| Распределение по этапам | `dialogi.etap` | ✅ согласован с историей | ⛔ → D1 | ✅ |
| Ожидают менеджера | `dialogi` (этап/владелец) | ❓ | — | ❓ скрыт |

⛔ → D1 — у дашборда сейчас **нет** доступа к этим данным; он появится через read-only API из [`05_SQL_API_DESIGN.md`](05_SQL_API_DESIGN.md). ⚠️ — данные есть, но достоверность зависит от классификации тестовых обращений.

## 6. Права доступа (✅Б, DASH-D0-03)

| Роль | LOGIN | Доступные функции | Прямые права на таблицы | Для дашборда |
|---|---|---|---|---|
| `katona_dashboard_read` | NOLOGIN | только `audit_dashboard_summary()` | нет | KPI не даёт; как есть не подходит |
| `katona_dashboard_admin` | NOLOGIN | `audit_dashboard_summary`, `otozvat_dokument_znaniy`, `razblokirovat_polzovatelya` | — | **Запрещено**: две функции изменяют данные |
| `katona_bot` / `katona_n8n_bot_login` | NOLOGIN / LOGIN | 30 функций клиентского бота (SQL №7–№8) | нет | **Запрещено**: рабочий контур n8n |
| `katona_service` / `katona_n8n_service_login` | NOLOGIN / LOGIN | 28 функций группы и 9 прямых разрешений на `kb_v2_*` | нет | **Запрещено**. Дополнительные разрешения не менять: это рабочий контур загрузки знаний |

- Все 12 функций проверенной выборки (3 функции dashboard-ролей и 9 `kb_v2_*`) принадлежат `postgres` и объявлены `SECURITY DEFINER`.
- `audit_dashboard_summary` — техническая сводка без периода, для четырёх KPI продаж не подходит.

**Вывод.** Существующих прав недостаточно, а действующие подключения использовать нельзя. Backend требует отдельного ограниченного серверного подключения и нового read-only API. Их SQL готовится в D1 и выполняется только с разрешения пользователя. Архитектура — `03_IMPLEMENTATION_PLAN.md`, раздел «Подключение backend к Supabase».

## 7. Проверки D0

### Закрыты

| Вопрос | Итог |
|---|---|
| Права дашборда и ролей n8n | ✅ матрица §6: LOGIN для дашборда нет, прямых прав на таблицы нет |
| `audit_dashboard_summary` | ✅ техническая сводка, не продажный API |
| Ключи и типы | ✅ `dialogi.id`; `dialog_id` в `celevye_sobytiya`, `zayavki`, `sobytiya_etapov`; `vremya_nachala timestamptz NOT NULL` |
| Формулы 4 KPI и когорта | ✅ §4: цель с `podtverzhdeno=true`, потеря `zavershen` + `net_otveta`, пересечение — видимая аномалия |
| 36-я таблица | ✅ `kb_popytki_v2`, к дашборду не относится |
| FK и уникальность целевых данных | ✅ FK основных таблиц подтверждены; дубликатов подтверждённых целей и заявок 0; пересечений «подтверждённая цель + потеря» 0 |
| Текущий этап и история | ✅ у всех 3 диалогов есть история этапов; текущий этап совпадает с последним переходом у 3 из 3, расхождений 0 |
| Флаги пользователей | ✅ измерено: `testovyy=true` — 0, `testovyy=false` — 3, `sluzhebnyy=true` — 0 |

Выборка — 3 диалога, все тестовые. Отсутствие дублей и расхождений на ней **не доказывает** поведение на реальном объёме; проверки SQL-D0-8 повторяются на приёмке D3.

### Условия рабочего запуска (не доказаны)

1. **Полнота истории этапов по всем маршрутам.** Согласованность на 3 диалогах не покрывает все маршруты смены этапа: создание диалога, подтверждённые исходящие, запрос и захват менеджером, возврат боту, ручные сообщения, предупреждения и блокировка, разблокировка, закрытие потерей. Проверка: SQL-D0-9 и ручное чтение найденных функций. **До доказательства историческая воронка не показывается**; в v1.0 — «Распределение по текущим этапам».
2. **Достоверная классификация тестовых и служебных обращений — обязательное условие рабочего запуска.** Все 3 существующих диалога тестовые, но флаги пользователей `false`. Правило исключения по `testovyy`/`sluzhebnyy` заложено в SQL-проект, но пока флаги не исправлены и нет механизма для будущих тестировщиков, статистика помечается как неподтверждённая (`05_SQL_API_DESIGN.md` §5). Отсечение по дате запрещено; правка флагов — изменение данных, только с разрешения пользователя.

### Закрыть до приёмки D3

- Источник признака согласия клиента: сообщение клиента или поле ответа модели.
- Значения этапа и владельца для «запрошено, не взято менеджером»; до подтверждения индикатор скрыт.
- Схема `katona` закрыта для `anon`/`authenticated`/PostgREST; `search_path` у новых функций дашборда задан явно (входит в SQL-проект D1).
- ~~Имена столбцов текущего этапа, канала и ссылки на пользователя~~ — закрыто (D1-01R), см. §2.
- Риск классификации тестовых обращений на уровне пользователя и предлагаемая классификация на уровне диалога — `05_SQL_API_DESIGN.md` §5.

## 8. SELECT-only SQL (DASH-D0-01, -03)

Запросы ниже не меняют БД и не читают ПД. SQL-D0-1…4 закрыты аудитом руководителя, повторять их не нужно. SQL-D0-8 выполнен руководителем (итоговые проверки §7). Для условия запуска 1 остаётся **SQL-D0-9**; SQL-D0-8 повторяется на приёмке D3.

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

### SQL-D0-8 — целостность целей и заявок, пересечение с потерей (только числа)

```sql
SELECT
  (SELECT count(*) FROM katona.dialogi) AS dialogi_vsego,
  (SELECT count(*) FROM (SELECT ce.dialog_id FROM katona.celevye_sobytiya ce
                          WHERE ce.kod_celi = 'ostavit_zayavku' AND ce.podtverzhdeno = true
                          GROUP BY ce.dialog_id HAVING count(*) > 1) x) AS dialogi_s_neskolkimi_celyami,
  (SELECT count(*) FROM katona.celevye_sobytiya ce
    WHERE NOT EXISTS (SELECT 1 FROM katona.dialogi d WHERE d.id = ce.dialog_id)) AS celi_bez_dialoga,
  (SELECT count(*) FROM (SELECT z.dialog_id FROM katona.zayavki z
                          GROUP BY z.dialog_id HAVING count(*) > 1) x) AS dialogi_s_neskolkimi_zayavkami,
  (SELECT count(*) FROM katona.zayavki z
    WHERE NOT EXISTS (SELECT 1 FROM katona.celevye_sobytiya ce
                       WHERE ce.dialog_id = z.dialog_id AND ce.kod_celi = 'ostavit_zayavku'
                         AND ce.podtverzhdeno = true)) AS zayavki_bez_podtverzhdennoy_celi,
  (SELECT count(*) FROM katona.dialogi d
    WHERE d.status = 'zavershen' AND d.rezultat = 'net_otveta'
      AND EXISTS (SELECT 1 FROM katona.celevye_sobytiya ce
                   WHERE ce.dialog_id = d.id AND ce.kod_celi = 'ostavit_zayavku'
                     AND ce.podtverzhdeno = true)) AS anomaliya_cel_i_poterya,
  (SELECT count(*) FROM katona.dialogi d
    WHERE NOT EXISTS (SELECT 1 FROM katona.sobytiya_etapov se
                       WHERE se.dialog_id = d.id)) AS dialogi_bez_istorii_etapov;
```

Все значения, кроме `dialogi_vsego`, в норме равны 0. Ненулевое значение — не ошибка запроса, а вопрос для решения руководителя.

### SQL-D0-9 — какие функции меняют `dialogi` и пишут ли `sobytiya_etapov` (без текстов функций)

```sql
SELECT p.proname,
       p.prosrc ~* 'update\s+(katona\.)?dialogi\M' AS menyaet_dialogi,
       p.prosrc ~* '\metap' AS upominaet_etap,
       p.prosrc ~* 'sobytiya_etapov' AS pishet_sobytiya_etapov,
       EXISTS (SELECT 1 FROM pg_trigger t
                WHERE t.tgfoid = p.oid AND NOT t.tgisinternal) AS triggernaya
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'katona' AND p.prokind = 'f'
   AND (p.prosrc ~* 'update\s+(katona\.)?dialogi\M' OR p.prosrc ~* 'sobytiya_etapov')
 ORDER BY p.proname;
```

Это эвристика по тексту функций. Строки с `menyaet_dialogi=true`, `upominaet_etap=true` и `pishet_sobytiya_etapov=false` — кандидаты в маршруты без истории, их нужно прочитать вручную. Если на `dialogi` есть триггер, который пишет `sobytiya_etapov`, он закрывает все маршруты сразу.

## 9. Готовность D0

- ✅ DASH-D0-01: репозиторий и Workflow изучены, SELECT-only SQL подготовлен.
- ✅ DASH-D0-02: структура и SQL-логика 4 KPI закреплены, единая когорта по `dialogi.vremya_nachala`.
- ✅ DASH-D0-03: права подтверждены (§6); формулы сверены — цель с `podtverzhdeno=true`, потеря `zavershen` + `net_otveta`, аномалия видна.
- ✅ Итоговые проверки данных: ключи и ограничения, дубли, пересечение, согласованность текущих этапов с историей, флаги пользователей.
- ⚠️ Условия рабочего запуска (§7): полнота маршрутов истории этапов, достоверная классификация тестовых обращений.

D0 закрыт как основание для D1. D1-01 (проект SQL/API) подготовлен; D1 не завершён, внедрение — только после ревью и разрешения пользователя.
