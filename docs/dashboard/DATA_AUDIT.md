# DASH-D0-01 — аудит источников данных Supabase для дашборда

**Статус: 🔄 D0 не завершён.** Аудит репозитория выполнен 28.10.2026; живая БД не опрашивалась, потому что у исполнителя VSCode нет read-only доступа к Supabase (нет `psql`, Supabase CLI-подключения, MCP-коннектора БД или Credential для дашборда). Подключения через чужие Credentials не делались. Ниже — только то, что подтверждается файлами репозитория, плюс SELECT-only SQL для запуска пользователем.

Документ не содержит паролей, Telegram ID, телефонов, имён, текстов сообщений и идентификаторов конкретных диалогов.

## 1. Что проверено и как

| Источник | Что взято |
|---|---|
| `PLAN.md`, `DB_AUDIT.md`, `DB_WORKFLOW_CONTRACT.md` | Отчёты SQL №1Б, №3, №5–№8: число объектов, роли, распределение прав |
| `docs/01_BOT_REQUIREMENTS.md`, `docs/10…12_*.md` | Упоминания реальных таблиц и ограничений из прошлых read-only выгрузок |
| `docs/dashboard/*.md` | Целевые определения KPI и правила точности |
| `workflows/current/*.json` (клиентский — 160 узлов, служебный — 108) | Все SQL-запросы PostgreSQL-узлов, конфигурация этапов/цели/напоминаний, поля, которые возвращают функции |

Уровни подтверждения в таблицах ниже:

- ✅ **факт** — подтверждено отчётом SQL пользователя, записанным в репозитории;
- 🟡 **из Workflow** — видно по коду/параметрам n8n (что передаётся в функцию и что из неё читается), но не по определению функции или таблицы;
- ❓ **не подтверждено** — в репозитории нет данных; нужен SQL из раздела 6.

## 2. Подтверждённые объекты схемы `katona`

| Объект | Факт | Уровень |
|---|---|---|
| Схема | `katona` в той же БД, что и Qbit | ✅ |
| Таблицы | 35 (копия структуры Qbit), RLS выключен в исходнике | ✅ число; ❓ полный список имён |
| Известные по прошлым выгрузкам таблицы | `soobshcheniya` (есть `dialog_id`, `vneshnee_soobshchenie_id`, уникальный индекс `soobshcheniya_dialog_id_vneshnee_soobshchenie_id_idx`), `ishodyashchie_deystviya`, `operator_telegram_temy` (`status`, `message_thread_id`, `popytki`, `kod_oshibki`), `sobytiya_integraciy` (`payload_ishodnyy jsonb`), `audit_uvedomleniya`, `zagruzki_znaniy`, `zadaniya_znaniy`, `dokumenty_znaniy`, `versii_dokumentov_znaniy`, `fragmenty_znaniy`, `profili_indeksa` | ✅ |
| **Таблица диалогов** (носитель `dialog_id`, этапа, статуса, владельца) | Имя и столбцы в репозитории **не зафиксированы** | ❓ |
| Таблица истории этапов/статусов | Не упоминается нигде | ❓ |
| Функции | 65 `SECURITY DEFINER` (SQL №5); Workflow вызывают 27 (клиентский) и 17 (служебный) из них, только через `katona.<функция>(jsonb)`; прямых SELECT к таблицам в Workflow нет | ✅ / 🟡 |
| Роли | `katona_bot` (30 функций), `katona_service` (28), `katona_dashboard_read` (1), `katona_dashboard_admin` (3); все NOLOGIN; 0 прямых прав на таблицы; 0 PUBLIC EXECUTE; 0 ссылок на Qbit | ✅ SQL №6–№7 |
| LOGIN-роли | Только `katona_n8n_bot_login` и `katona_n8n_service_login` (SQL №8). LOGIN-роли для дашборда нет | ✅ |
| Каналы | В клиентском Workflow вход принимается только при `kanal_vhoda='telegram'`, иначе ошибка | 🟡 |

## 3. `audit_dashboard_summary` и `katona_dashboard_read`

**Что известно:**

- Обе сущности перенесены из шаблона Qbit (SQL №5/№6). `katona_dashboard_read` — NOLOGIN, имеет EXECUTE ровно на **одну** функцию, прямых прав на таблицы нет (SQL №7).
- В `DB_WORKFLOW_CONTRACT.md` для «dashboard ролей» указаны две функции: `audit_dashboard_summary` и `otozvat_dokument_znaniy`. Вторая — операция записи (отзыв документа знаний), поэтому **гипотеза**: единственная функция read-роли — `audit_dashboard_summary`, а `otozvat_dokument_znaniy` входит в 3 функции admin-роли. В репозитории это не зафиксировано.
- Ни один Workflow не вызывает `audit_dashboard_summary`.

**Чего нет в репозитории:** сигнатуры, возвращаемых столбцов, тела функции, `search_path`/владельца. Название (`audit_…`) и соседство с функциями очереди уведомлений (`audit_claim_notice`, `audit_operational_notices`) допускают, что это **техническая** сводка (очереди, ошибки), а не продажные KPI — это предположение, проверяется SQL-D0-3.

**Вывод:** роль `katona_dashboard_read` сейчас **не является** готовым способом подключения дашборда: к ней нет LOGIN-участника, а единственная доступная функция может не возвращать нужных KPI. Как выдать backend-подключение, решается в D1 отдельным SQL с разрешения пользователя.

## 4. Модель диалога по коду Workflow (🟡, требует подтверждения БД)

- **Единица учёта.** Функции работают с `dialog_id` (uuid) и оптимистической версией `versiya_dialoga`. Вход клиента регистрирует `zaregistrirovat_vhod_klienta(jsonb)` с параметрами `kanal`, `nachalnyy_etap='novoe_obrashchenie'`, `prioritet=0`. Создаёт ли повторное обращение того же человека новый `dialog_id` или переоткрывает старый — **неизвестно** (нужно тело функции).
- **Этапы.** Конфигурация `prodazhi.etapy` в клиентском Workflow: `novoe_obrashchenie`, `privetstvie`, `vyyavlenie_potrebnosti`, `podbor_resheniya`, `rabota_s_vozrazheniyami`, `predlozhenie_celevogo_deystviya`, `celevoe_deystvie`, `peredacha_cheloveku`, `zaversheno`. Текущий этап читается как `ai_kontekst.dialog.etap`.
- **⚠️ Кто меняет этап.** Новый этап выбирает **LLM-планировщик** (`reshenie.sleduyushchiy_etap`); Workflow только проверяет, что значение входит в список, и передаёт его как `effects.novyy_etap` в `sozdat_ishodyashchee_deystvie`. Проверяет ли SQL допустимость перехода — неизвестно. Значит, этап `celevoe_deystvie` — это **решение модели**, а не подтверждённый бизнес-факт. По правилу `01_METRICS_AND_DATA.md` его нельзя без решения руководителя считать «достигли цели».
- **Цель компании.** `cel.kod='ostavit_zayavku'` («оставить заявку на замер / получить расчёт»), `obyazatelnye_polya: imya, telefon`. Модель также возвращает `celevoe_deystvie` и `polya_lida`; где и как они сохраняются — ❓.
- **Потеря.** После ответа, ждущего клиента, Workflow передаёт таймеры: напоминание 1 через 180 мин, напоминание 2 через 1440 мин, `poterya_posle_sekund` = 1440 мин после второго (для отложенного контакта — 7 дней). Потерю фиксирует `obrabotat_sleduyushchee_napominanie(jsonb)` («loss-check» после второго напоминания). Какой статус/этап и какая отметка времени при этом пишутся — ❓.
- **Передача менеджеру.** `zaprosit_cheloveka(jsonb)` по заметке узла «переводит этап в `peredacha_cheloveku`… owner остаётся bot до Take»; захват — `zabrat_dialog_operatorom(jsonb)` (служебный Workflow). `poluchit_sostoyanie_operatora(jsonb)` возвращает `vladelec`, `status_dialoga`, `tekushchiy_menedzher_id`. То есть «ожидает менеджера» ≈ `etap='peredacha_cheloveku'` при `vladelec` = бот (значения ❓). Функция возврата `vernut_dialog_botu` есть в контракте, но в текущих JSON не вызывается.
- **Запрет общения.** `ustanovit_zapret_iniciativy(jsonb)` — отдельный признак; это не обязательно «потерян».
- **Часовой пояс.** `prodazhi.chasovoy_poyas='Europe/Moscow'` — совпадает с правилом дашборда.
- **Тестовые данные.** Идёт закрытый пилот: вход разрешён только allowlist тестировщиков, в двух функциях жёстко `sreda='test'`. Все текущие диалоги — тестовые. Как отличать тестовые диалоги от боевых в БД — ❓ (возможен столбец `sreda`).

## 5. Матрица «метрика → источник → доступность»

| Метрика | Кандидат источника | Фильтр / формула (проект) | Доступность | Что нужно подтвердить |
|---|---|---|---|---|
| `new_dialogues` | Таблица диалогов: время создания / первого клиентского входа; альтернатива — первое входящее в `soobshcheniya` | `COUNT(DISTINCT dialog_id)` с первым входом в `[from,to)` MSK, без тестовых/системных | ❓ | Имя таблицы, столбец времени (`timestamptz`?), направление сообщения в `soobshcheniya`, правило переоткрытия, признак `sreda` — SQL-D0-3, -4 |
| `target_reached` | (а) этап `celevoe_deystvie` (решение LLM); (б) сохранённые обязательные поля лида `imya`+`telefon`; (в) подтверждение менеджером | Диалоги когорты с подтверждённым целевым событием | ❓ + **решение руководителя** | Где хранится достижение цели и его время; есть ли история этапов — SQL-D0-3, -4, -7 |
| `conversion_pct` | Производная | `100 * target_reached / new_dialogues`, при 0 — «—» | Зависит от двух выше | — |
| `lost_dialogues` | Результат `obrabotat_sleduyushchee_napominanie` (таймер после 2-го напоминания) | Текущий статус «потерян» у диалогов когорты | ❓ | Значение статуса/этапа и CHECK — SQL-D0-3, -5, -7 |
| Динамика по дням | Как `new_dialogues` | Группировка по локальной дате первого входа | ❓ | Как `new_dialogues` |
| Воронка | История переходов этапов | Достигавшие каждого этапа | ❓ таблица истории не известна | Если истории нет — **fallback: «Распределение по текущим этапам»** по 9 этапам из конфигурации (с группировкой до 5–6 полос) |
| Ожидают менеджера | Таблица диалогов: `etap`/`status_dialoga`/`vladelec` | `etap='peredacha_cheloveku'` и владелец ещё бот (снимок «сейчас») | 🟡 логика видна, ❓ столбцы и значения | SQL-D0-4, -5, -7; тела `zaprosit_cheloveka`, `zabrat_dialog_operatorom` |
| Последние диалоги | Таблица диалогов | Безопасные поля: время, канал, этап, статус, цель | ❓ | SQL-D0-4 |
| Фильтр «Канал» | `kanal` | — | 🟡 активен только Telegram → **фильтр в v1 не показывать** | Распределение `kanal` — SQL-D0-7 |

**Итог:** ни один из 4 KPI сейчас не подтверждён до уровня «таблица → столбец → значение». Есть подтверждённые бизнес-правила в Workflow (этапы, цель, таймер потери, передача менеджеру), но не их хранение в БД.

## 6. SELECT-only SQL для пользователя (Supabase SQL Editor)

Правила запуска:

- Каждый блок — **один** `SELECT`; запускать по одному, по порядку, результат экспортировать в CSV и передать руководителю проекта.
- Ни один запрос не делает `CREATE/ALTER/GRANT/UPDATE/DELETE` и не читает тексты сообщений, имена, телефоны или ID. SQL-D0-6 и SQL-D0-7 читают данные только в виде **агрегатов**; в SQL-D0-7 любое значение, не похожее на код (`[a-z][a-z0-9_]*`, в т.ч. чисто числовые ID), заменяется на `[скрыто]`.
- Результат SQL-D0-3 (тексты функций) **не коммитить** в публичный репозиторий; в `DATA_AUDIT.md` переносится только вывод.
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

Ожидаем: у `katona_dashboard_read` `rolcanlogin=false`, `qbit_usage=0`, `katona_tables_select=0`, `katona_functions_execute=1`, список `members` покажет, есть ли LOGIN-участник. Строки `anon`/`authenticated` покажут, открыта ли схема для Supabase API.

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

Отвечает на вопросы: что возвращает `audit_dashboard_summary`; в какую таблицу пишется вход и создаётся ли новый `dialog_id` при повторном обращении; где сохраняются этап, цель, поля лида, потеря, передача и захват менеджером; пишется ли история переходов.

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

CHECK-ограничения дают допустимые значения статусов/этапов **без чтения данных**.

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

`NULL` в `value` означает пустое значение столбца. Запрос показывает реальные статусы/этапы/каналы и долю тестовой среды.

### Отложено до результатов SQL-D0-3…7

Запросы «первый вход по дням», «распределение текущих этапов в когорте», «ожидают менеджера сейчас» и проверка дубликатов `dialog_id` будут написаны только по подтверждённым именам таблиц и столбцов (следующее задание D0-02), чтобы не угадывать структуру.

## 7. Проверки, которые обязательны до D1

1. `DISTINCT dialog_id`, а не сообщения: подтвердить, что вход клиента не создаёт отдельный диалог на каждое сообщение и как обрабатываются повторные webhook (`soobshcheniya` уже имеет уникальность `(dialog_id, vneshnee_soobshchenie_id)`).
2. Время когорты = время первого клиентского входа (`timestamptz`), а не время задания обработки или исходящего ответа.
3. Цель: руководитель выбирает подтверждённый признак — этап `celevoe_deystvie` (решение LLM), полученные `imya`+`telefon`, или подтверждение менеджером. Без решения KPI «Достигли цели» и «Конверсия» показываются как «источник не подтверждён».
4. Потеря: значение статуса, которое ставит `obrabotat_sleduyushchee_napominanie`, и отличие от `zapret_iniciativy` / отказа.
5. История этапов: есть ли таблица/лог переходов. Если нет — воронку заменить на «Распределение по текущим этапам» и не считать историческую конверсию по текущему этапу.
6. «Ожидают менеджера»: точные значения `etap`/`status_dialoga`/`vladelec` для «запрошено, не взято»; возвращение боту.
7. Тестовые диалоги: как исключать (или явно помечать) пилотные данные.
8. Доступ: `katona_dashboard_read` без LOGIN и с одной функцией; способ подключения backend (новая LOGIN-роль или RPC) — только в D1, отдельным SQL с разрешения пользователя.

## 8. Готовность D0

- ✅ Документы и Workflow изучены, известные факты сведены, гипотезы отделены.
- ✅ Подготовлены SELECT-only запросы SQL-D0-1…7.
- ⬜ Результаты SQL от пользователя не получены → связь «метрика → поле» не подтверждена ни для одного KPI.
- ⬜ Решение руководителя по признаку цели (пункт 7.3).

**Один следующий шаг:** пользователь запускает SQL-D0-1…SQL-D0-7 в Supabase SQL Editor и возвращает CSV/ошибки руководителю проекта; затем отдельное задание D0-02 дополняет этот документ подтверждёнными источниками.
