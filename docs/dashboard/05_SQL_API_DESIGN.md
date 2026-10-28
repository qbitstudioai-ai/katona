# DASH-D1-02A — SQL и API дашборда

**Статус: окончательный SQL внедрения подготовлен (D1-02A) и передан руководителю проекта на утверждение. В Supabase ничего не выполнено.** Роли и функции не существуют, пока пользователь отдельно не разрешит внедрение. Рабочая версия 1.0, без пилота и урезанного MVP. Результаты проверки во временном локальном PostgreSQL 17.6 — §7.

Исполняемые файлы — единственный источник SQL:

- [`sql/dashboard_deploy.sql`](sql/dashboard_deploy.sql) — внедрение одной транзакцией со встроенными проверками;
- [`sql/dashboard_rollback.sql`](sql/dashboard_rollback.sql) — откат только новых объектов.

Основание: [`DATA_AUDIT.md`](DATA_AUDIT.md) (источники, права, проверки), [`01_METRICS_AND_DATA.md`](01_METRICS_AND_DATA.md) (определения), [`02_UX_AND_FILTERS.md`](02_UX_AND_FILTERS.md) (экран), [`03_IMPLEMENTATION_PLAN.md`](03_IMPLEMENTATION_PLAN.md) (архитектура подключения).

## 1. Подтверждённая среда и структура

**Среда Supabase** (read-only запрос пользователя, 28.10.2026): PostgreSQL **17.6**; исполнитель `postgres` **не суперпользователь**; `katona_dashboard_read` уже имеет `USAGE` на `katona`; в `pg_default_acl` две записи для функций, их содержимое не раскрыто (§3.5); ролей `katona_dashboard_owner` и `katona_dashboard_api_login` нет.

| Таблица | Столбцы, которые читает дашборд |
|---|---|
| `katona.dialogi` | `id uuid`, `polzovatel_id uuid`, `identifikator_kanala_id uuid`, `etap text`, `status text`, `rezultat`, `vremya_nachala timestamptz NOT NULL` |
| `katona.identifikatory_kanalov` | `id uuid`, `kanal text` |
| `katona.celevye_sobytiya` | `dialog_id uuid`, `kod_celi`, `podtverzhdeno boolean` |
| `katona.polzovateli` | `id uuid`, `testovyy boolean`, `sluzhebnyy boolean` |

- Канал диалога: `dialogi.identifikator_kanala_id → identifikatory_kanalov.id`, значение `identifikatory_kanalov.kanal`.
- Допустимые `dialogi.status` по CHECK: `aktivnyy`, `ozhidaet_otveta`, `peredan_cheloveku`, `zavershen`.
- Тип `rezultat` и `kod_celi` в SQL приводится к `text`. Остальные имена и типы `dashboard_deploy.sql` проверяет **до** создания объектов (`dashboard_pre_columns`).
- Никакие другие столбцы дашборду не выдаются: внешние идентификаторы каналов (Telegram ID и т.п.), имена, телефоны и тексты недоступны даже роли-владельцу функций.

## 2. Состав объектов и изоляция

| Объект | Тип | Права |
|---|---|---|
| `katona_dashboard_owner` | NOLOGIN | Владелец 6 функций; `USAGE` на `katona`; `SELECT` только на 15 столбцов из §1 |
| `katona_dashboard_api_exec` | NOLOGIN | `USAGE` на `katona`; `EXECUTE` только на 4 функции API |
| `katona_dashboard_api_login` | LOGIN | Состоит **только** в `katona_dashboard_api_exec`; read-only транзакции по умолчанию, таймауты, `CONNECTION LIMIT 5` |
| `katona.dashboard_granicy(date, date)` | helper, INVOKER | Никому не выдан |
| `katona.dashboard_kogorta(timestamptz, timestamptz)` | helper, INVOKER | Никому не выдан |
| `katona.dashboard_obzor(date, date)` | API, DEFINER | `katona_dashboard_api_exec` |
| `katona.dashboard_dinamika(date, date)` | API, DEFINER | `katona_dashboard_api_exec` |
| `katona.dashboard_etapy(date, date)` | API, DEFINER | `katona_dashboard_api_exec` |
| `katona.dashboard_poslednie(date, date, int, text, timestamptz, uuid)` | API, DEFINER | `katona_dashboard_api_exec` |

- **Существующая `katona_dashboard_read` не используется и не меняется.** LOGIN дашборда в неё не входит и поэтому не может выполнить техническую `audit_dashboard_summary()`; новые функции ей не выдаются. `katona_dashboard_admin`, роли n8n и разрешения `kb_v2_*` скрипт тоже не трогает.
- Helpers объявлены `SECURITY INVOKER` и вызываются только из DEFINER-функций, то есть с правами `katona_dashboard_owner`.
- Все KPI и виджеты берут данные из `dashboard_kogorta`, поэтому карточки, график и распределение не могут разойтись в определениях. Воронки (`sobytiya_etapov`) в контракте нет: полнота маршрутов истории не доказана (`DATA_AUDIT.md` §7).

## 3. SQL

### 3.1. Логика функций

- **Период** (`dashboard_granicy`): даты включительные в `Europe/Moscow` → полуинтервал `[p_s 00:00 MSK, (p_po + 1) 00:00 MSK)`; максимум 366 дней; начало не в будущем. Ошибки — SQLSTATE `22023` с кодами `dashboard_period_invalid`, `dashboard_period_too_long`, `dashboard_period_in_future`. Результат не зависит от `TimeZone` сессии.
- **Когорта** (`dashboard_kogorta`): одна строка на `dialogi.id`; `LEFT JOIN` к `identifikatory_kanalov` и `polzovateli` по первичным ключам, поэтому диалог без канала или пользователя не теряется.
  - **Цель:** `EXISTS` по `celevye_sobytiya` с `kod_celi = 'ostavit_zayavku'` и `podtverzhdeno = true`; дубли событий не размножают строки.
  - **Потеря:** `status = 'zavershen'` и `rezultat = 'net_otveta'`.
  - **Исключение:** `testovyy` или `sluzhebnyy` у пользователя.
- **`dashboard_obzor`:** все счётчики — `count(DISTINCT dialog_id)`. Конверсия `round(100 × цели / обращения, 1)`, при 0 обращений — `NULL`. Аномалия «цель + потеря» — отдельный счётчик; такие диалоги остаются в обоих KPI.
- **`dashboard_dinamika`:** все дни периода по MSK, дни без обращений — 0.
- **`dashboard_etapy`:** распределение когорты по `dialogi.etap`, не воронка.
- **`dashboard_poslednie`:**
  - сортировка `vremya_nachala DESC, id DESC`, keyset-курсор (`p_posle_vremya` и `p_posle_id` вместе);
  - `LIMIT` в SQL ограничен 1–21: сервер запрашивает `limit + 1`, чтобы узнать о следующей странице;
  - неизвестный `p_status` даёт пустую выборку, проверка списка — на сервере;
  - `dialog_id` возвращается только серверу для курсора.
- Все 6 функций — `STABLE`, `SET search_path = pg_catalog, pg_temp`, все объекты с префиксом `katona.`.

### 3.2. `dashboard_deploy.sql` — порядок шагов

Одна транзакция `BEGIN … COMMIT`:

1. **Предусловия** (иначе — исключение до создания чего-либо):
   - PostgreSQL ≥ 17;
   - трёх новых ролей и функций `katona.dashboard_*` ещё нет;
   - 15 столбцов из §1 существуют с ожидаемыми типами;
   - исполнитель владеет схемой `katona` и четырьмя таблицами (или имеет на них GRANT OPTION) и имеет `CREATE` на схеме — `dashboard_pre_ownership`. В Supabase это `postgres`, создавший схему SQL №3.
2. **Роли:** `owner`, `api_exec`, `api_login` (`IN ROLE katona_dashboard_api_exec`), параметры `api_login`. Снимается членство с SET/INHERIT, которое PostgreSQL 17 выдаёт создателю при `createrole_self_grant`. `USAGE` на схему — `owner` и `api_exec`; `SELECT` по 15 столбцам — `owner`.
3. **6 функций.**
4. **ACL функций, пока владелец — исполнитель:** `REVOKE ALL … FROM PUBLIC`, `GRANT EXECUTE` на 4 функции API роли `api_exec`, затем цикл снимает права, выданные через default privileges (`anon`, `authenticated`, `service_role` и любые другие роли).
5. **Смена владельца.** PostgreSQL 17 требует от исполнителя права `SET ROLE` на нового владельца, а от владельца — `CREATE` на схеме. Скрипт выдаёт `GRANT katona_dashboard_owner TO CURRENT_USER WITH INHERIT FALSE, SET TRUE` и `CREATE` на схему, выполняет `ALTER FUNCTION … OWNER TO`, затем снимает оба права. ACL переносится на нового владельца.
6. **Встроенные проверки** (транзакция прерывается при любом нарушении):
   - ровно 6 функций: владелец, `STABLE`, `search_path`, явный ACL; `SECURITY DEFINER` только у 4 API;
   - ACL функций содержит только владельца и `api_exec` (EXECUTE без GRANT OPTION на 4 API);
   - `api_login` может выполнить в `katona` **ровно 4** функции; отдельно проверено, что не может выполнить `audit_dashboard_summary()`;
   - у `api_login` и `api_exec` нет прав ни на одну таблицу или столбец `katona` и нет `CREATE` на схеме;
   - у владельца нет прав на уровне таблиц, `SELECT` ровно на 15 столбцов, нет прав на запись и `CREATE`;
   - членство:
     - `owner` и `api_exec` ни в чём не состоят;
     - `api_login` состоит только в `api_exec` (с INHERIT, без ADMIN);
     - кроме этого, в новых ролях допустим только исполнитель с автоматическим ADMIN OPTION PostgreSQL 17 без SET/INHERIT;
   - атрибуты: `owner` и `api_exec` — NOLOGIN без привилегий; `api_login` — LOGIN, INHERIT, `CONNECTION LIMIT 5`, без SUPERUSER/CREATEROLE/CREATEDB/REPLICATION/BYPASSRLS; четыре параметра сессии заданы.

Существующие роли и права в скрипте не встречаются, кроме чтения каталога для проверок.

### 3.3. `dashboard_rollback.sql`

Временно выдаёт исполнителю права роли-владельца — нужно, если исполнитель не владеет схемой. Затем удаляет 6 функций (`DROP FUNCTION IF EXISTS` по точным сигнатурам) и `api_login`, снимает права `api_exec` и `owner` на схему и таблицы, удаляет обе роли и проверяет, что ничего не осталось. Скрипт можно запускать повторно и когда внедрения не было. `USAGE` у `katona_dashboard_read`, `audit_dashboard_summary` и все прочие права не затрагиваются.

### 3.4. Проверка после внедрения (только SELECT)

```sql
SELECT p.proname::text AS funkciya,
       pg_get_userbyid(p.proowner)::text AS owner,
       p.prosecdef AS security_definer,
       array_to_string(p.proconfig, '; ') AS config,
       has_function_privilege('katona_dashboard_api_login', p.oid, 'EXECUTE') AS api_login,
       has_function_privilege('katona_dashboard_read', p.oid, 'EXECUTE') AS dashboard_read,
       (SELECT count(*) FROM pg_roles r
         WHERE r.rolname IN ('anon', 'authenticated', 'service_role', 'katona_bot', 'katona_service',
                             'katona_dashboard_admin', 'katona_n8n_bot_login', 'katona_n8n_service_login')
           AND has_function_privilege(r.oid, p.oid, 'EXECUTE')) AS lishnie_prava
  FROM pg_proc p
 WHERE p.pronamespace = 'katona'::regnamespace AND p.proname LIKE 'dashboard\_%'
UNION ALL
SELECT 'audit_dashboard_summary', NULL, NULL, NULL,
       has_function_privilege('katona_dashboard_api_login', 'katona.audit_dashboard_summary()', 'EXECUTE'),
       has_function_privilege('katona_dashboard_read', 'katona.audit_dashboard_summary()', 'EXECUTE'),
       NULL
 ORDER BY 1;
```

Ожидаем:

| Функции | `api_login` | `dashboard_read` | Прочее |
|---|---|---|---|
| 4 функции API | `true` | `false` | `security_definer=true` |
| 2 helpers | `false` | `false` | `security_definer=false` |
| `audit_dashboard_summary` | `false` | `true` — как до внедрения | — |

У всех шести функций `owner = katona_dashboard_owner`, `config = search_path=pg_catalog, pg_temp`, `lishnie_prava = 0`. Затем — сверить KPI из `dashboard_obzor` с ручным агрегатным SELECT руководителя за тот же период.

### 3.5. Дополнительный read-only запрос: содержимое default privileges

Число `default_acl_funkciy = 2` не говорит, **кому** и **что** выдают эти записи. Внедрение от них не зависит: скрипт снимает с новых функций любые лишние права и проверяет ACL. Но для ревью их можно раскрыть запросом ниже — **только по решению руководителя проекта**:

```sql
SELECT pg_get_userbyid(d.defaclrole)::text AS dlya_obektov_roli,
       CASE WHEN d.defaclnamespace = 0 THEN '<все схемы>'
            ELSE d.defaclnamespace::regnamespace::text END AS shema,
       CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END AS komu,
       a.privilege_type,
       a.is_grantable
  FROM pg_default_acl d
 CROSS JOIN LATERAL aclexplode(d.defaclacl) a
 WHERE d.defaclobjtype = 'f'
 ORDER BY 1, 2, 3;
```

У записи «<все схемы>» список **заменяет** встроенные права по умолчанию: если в нём нет `PUBLIC`, значит у `PUBLIC` EXECUTE отобран. У записи для конкретной схемы права **добавляются** к встроенным.

### 3.6. Пароль LOGIN-роли

После внедрения пользователь задаёт пароль через `psql` командой `\password katona_dashboard_api_login`: пароль хэшируется на клиенте и не попадает в журнал запросов. `ALTER ROLE … PASSWORD '…'` в SQL Editor использовать не рекомендуется — открытый текст может оказаться в логах. Пароль хранится только в секретах сервера дашборда; в GitHub, n8n и браузер он не попадает.

**Граница безопасности — права, а не `default_transaction_read_only`.** Сессия может сама выключить этот параметр, поэтому он лишь страхует от случайной записи. Писать роль не может потому, что у неё нет прав ни на одну таблицу, а DEFINER-функции только читают.

## 4. Контракт серверного API

Сервер дашборда (Next.js route handlers или аналог) — единственный клиент БД. Браузер обращается только к API ниже; никаких SQL, ролей и ключей на клиенте.

### Общие правила

- **Авторизация:** все запросы требуют сессии руководителя; cookie `HttpOnly`, `Secure`, `SameSite=Strict`. Без сессии — `401`, без роли руководителя — `403`. Механизм входа — открытый вопрос (§6).
- **Период:** `from`, `to` — даты `YYYY-MM-DD` в `Europe/Moscow`, включительно; по умолчанию последние 7 дней вместе с сегодняшним; предел — 366 дней. Границы суток считает только SQL (`dashboard_granicy`).
- **Согласованность:** все вызовы одного запроса выполняются в одной транзакции `REPEATABLE READ READ ONLY`: карточки, график и распределение видят один снимок и одно `data_as_of`.
- **ПД:** в ответах нет ID диалогов и пользователей, внешних идентификаторов каналов, телефонов, имён и текстов. Этапы, статусы и каналы — служебные коды.
- **Кэш:** `Cache-Control: no-store`. Ограничение частоты — 60 запросов в минуту на сессию.
- **Журналы:** request id, endpoint, код ответа, длительность; без курсоров, cookie и ПД.
- **Пул БД:** не больше 3 соединений (лимит роли — 5); учётные данные только в серверных секретах, никогда не в переменных, доступных браузеру.

### `GET /api/dashboard/overview?from=YYYY-MM-DD&to=YYYY-MM-DD`

Вызывает `dashboard_obzor`, `dashboard_dinamika`, `dashboard_etapy`.

```ts
interface OverviewResponse {
  period: { from: string; to: string; timezone: 'Europe/Moscow' };
  data_as_of: string;                         // ISO 8601, время снимка БД
  data_quality: DataQuality;
  kpi: {
    new_dialogues: number;
    target_reached: number;
    conversion_pct: number | null;            // null → UI показывает «—»
    lost_dialogues: number;
  };
  trend: {
    granularity: 'day';
    points: { date: string; new_dialogues: number; target_reached: number }[];  // все дни периода, нули включены
  };
  stages: {
    kind: 'current_stage_distribution';       // не воронка
    items: { stage: string | null; label: string; dialogues: number }[];       // ≤ 6, хвост — «Прочие»
  };
}

interface DataQuality {
  test_classification: 'attested' | 'not_attested';
  reliable: boolean;                          // true только при attested и нулевой аномалии
  excluded_test_or_service: number;
  anomalies: { goal_and_loss: number };
  warnings: ('test_classification_not_attested' | 'goal_and_loss_anomaly')[];
}
```

Порядок и русские названия этапов сервер берёт из того же списка, что и бот (`prodazhi.etapy`); этапы вне списка идут в конец, `stage: null` подписывается «Этап не указан».

### `GET /api/dashboard/dialogs?from&to&status&limit&cursor`

Вызывает `dashboard_poslednie`.

| Параметр | Правило |
|---|---|
| `from`, `to` | Как в `overview` |
| `status` | Необязателен; только `aktivnyy`, `ozhidaet_otveta`, `peredan_cheloveku`, `zavershen`, иначе `400 status_invalid`. Фильтр действует **только** на таблицу, KPI не меняет |
| `limit` | 1–20, по умолчанию 10; сервер запрашивает у SQL `limit + 1` |
| `cursor` | Непрозрачная строка из предыдущего ответа (см. ниже) |

```ts
interface DialogsResponse {
  period: { from: string; to: string; timezone: 'Europe/Moscow' };
  data_as_of: string;
  data_quality: Pick<DataQuality, 'test_classification' | 'reliable' | 'warnings'>;
  items: {
    started_at: string;                       // ISO 8601
    channel: string | null;                   // identifikatory_kanalov.kanal, например 'telegram'
    stage: string | null;
    stage_label: string;
    status: 'aktivnyy' | 'ozhidaet_otveta' | 'peredan_cheloveku' | 'zavershen';
    result: string | null;
    target_reached: boolean;
    anomaly: boolean;
  }[];
  next_cursor: string | null;                 // null — страниц больше нет
}
```

### Курсор пагинации

Подпись HMAC обеспечивает только целостность: содержимое base64url+HMAC читается кем угодно. Поэтому курсор **шифруется с аутентификацией (AEAD)**:

- **Алгоритм:** AES-256-GCM (или XChaCha20-Poly1305) с ключом 256 бит из серверных секретов; nonce — 96 бит случайных на каждый курсор, без повторов.
- **Открытый текст:** `{ v: 1, t: vremya_nachala, id: dialog_id, exp: <выдан + 15 мин> }`.
- **Привязка (AAD):** `"dashboard.dialogs.v1" | from | to | status | limit | sha256(session_id)`. Курсор, выданный для других фильтров или другой сессии, не расшифруется.
- **Формат:** `base64url(key_id ‖ nonce ‖ ciphertext ‖ tag)`; `key_id` позволяет ротацию ключа без обрыва действующих сессий (старый ключ принимается не дольше срока курсора).
- **Отказ:** неверный формат, ошибка расшифровки или чужие фильтры — `400 cursor_invalid`; истёк срок — `400 cursor_expired`. Причину ошибки клиенту не раскрывать сверх кода.
- Курсор не пишется в журналы. Если `limit + 1`-я строка есть, `next_cursor` строится по последней **отданной** строке.

### Ошибки

Тело ошибки: `{ "error": { "code": string, "message": string } }`, `message` — по-русски, без технических деталей. Частичных ответов и нулей вместо ошибки нет.

| HTTP | `code` | Когда |
|---|---|---|
| 400 | `period_invalid`, `period_too_long`, `period_in_future` | Неверные даты; соответствует `22023` из `dashboard_granicy` |
| 400 | `limit_invalid`, `status_invalid`, `cursor_invalid`, `cursor_expired` | Параметры таблицы |
| 401 | `unauthenticated` | Нет сессии |
| 403 | `forbidden` | Нет роли руководителя |
| 429 | `rate_limited` | Превышена частота |
| 503 | `source_timeout` | `57014` (statement_timeout) |
| 503 | `source_unavailable` | БД или туннель недоступны |
| 500 | `internal` | Прочее; детали только в журнале сервера |

## 5. Исключение тестовых и служебных обращений

### Правило версии 1.0

- Из всех KPI и виджетов исключаются диалоги пользователей с `polzovateli.testovyy=true` или `sluzhebnyy=true`. Число исключённых возвращается отдельно (`excluded_test_or_service`). Отсечения по дате нет.
- **Факт аудита:** у всех 3 пользователей оба флага `false`, хотя все 3 текущих диалога тестовые. Правило есть, но классификация **не обеспечена**: сегодня статистика полностью состоит из тестовых обращений.
- Сервер хранит в конфигурации признак `test_classification = attested | not_attested` с датой и ссылкой на одобренное задание. Пока `not_attested`, API отдаёт цифры с `reliable=false` и предупреждением, UI показывает их как неподтверждённые. Рабочая приёмка D3 при `not_attested` невозможна.

### Риск классификации на уровне пользователя

Флаг на `polzovateli` исключает **все** диалоги человека, в обе стороны:

- **Недоучёт.** Если сотрудник или тестировщик однажды обращается как настоящий клиент (или тестовый аккаунт потом используется для реальной заявки), его реальные обращения пропадают из статистики.
- **Переучёт.** Тестовый диалог с аккаунта без флага (например, проверка с личного телефона) попадает в KPI как реальный.
- **Ретроспектива.** Флаг, выставленный сегодня, меняет и прошлые периоды: исторические цифры «прыгают» без изменений в самих диалогах.

### Предлагаемое решение для рабочей эксплуатации (последующий этап, сейчас не внедряется)

1. **Классификация на уровне диалога, а не человека.** Отдельная таблица `katona.dialogi_klassifikaciya (dialog_id PK → dialogi.id, tip ∈ {test, sluzhebnyy}, istochnik, ustanovil, vremya, prichina)`. Записи создаёт и снимает только защищённая функция с журналом, доступная служебной роли или `katona_dashboard_admin`, но не LOGIN-роли дашборда.
2. **Пользовательский флаг — только как источник по умолчанию с моментом действия.** Для тестировщиков и сотрудников хранить момент установки флага; автоматически классифицируются только диалоги, начатые **после** этого момента. Прошлые обращения не переписываются.
3. **Ручное исправление.** Руководитель может снять классификацию с конкретного диалога (например, реальный заказ сотрудника); действие журналируется.
4. **Будущие тестировщики.** Список внутренних аккаунтов ведётся в служебном контуре; при первом входе такого аккаунта его диалог классифицируется автоматически. Требует изменения SQL-функции входа или служебного Workflow — отдельное задание с разрешения пользователя.
5. **Правило в `dashboard_kogorta`** тогда меняется только в одном месте: «исключён = есть запись в `dialogi_klassifikaciya`». Остальные функции и API не меняются.

Для уже существующих 3 тестовых диалогов в любом варианте нужна адресная правка данных — только по отдельному разрешению пользователя.


## 6. Оставшиеся риски и вопросы до внедрения

1. **Ограничения самой Supabase, которых нет в локальной проверке:** расширение `supautils` (может запрещать операции с ролями), event triggers и фактическое содержимое двух записей default privileges. Скрипт от них не зависит: лишние EXECUTE снимаются и проверяются, при любом запрете транзакция откатится целиком. Но успешность внедрения в Supabase подтверждается только самим внедрением. Содержимое default privileges можно раскрыть запросом §3.5 по решению руководителя.
2. **Владение схемой:** внедрение требует, чтобы `postgres` владел `katona` и четырьмя таблицами. Это ожидается по SQL №3, но фактически не проверялось; при ином владельце скрипт остановится на `dashboard_pre_ownership` без изменений.
3. **Сетевой путь** сервера дашборда к PostgreSQL (SSH-туннель или приватная сеть) и ограничение входа роли в `pg_hba` по адресу сервера.
4. **Авторизация руководителя** (механизм входа, сессии, кто руководитель) — обязательна до рабочего запуска, в этом задании не внедряется.
5. **Классификация тестовых и служебных обращений** (§5) — обязательна до рабочего запуска, в этом задании не внедряется.
6. **Производительность:** `EXPLAIN` на реальном объёме для `dialogi(vremya_nachala)` и `celevye_sobytiya(dialog_id)`; новые индексы — только по результатам и с согласия пользователя.
7. Индикатор «Ожидают менеджера» в контракт не включён: `peredan_cheloveku` не отличает «запрошено» от «взято менеджером»; по `02_UX_AND_FILTERS.md` индикатор скрывается.

## 7. Проверка во временном локальном PostgreSQL 17.6

**Среда.** PostgreSQL **17.6** — та же версия, что в Supabase. Временный кластер на `127.0.0.1` во временной папке исполнителя, удаляется после проверки; к Supabase не подключался.

- **Суперпользователь кластера** — отдельная роль `supabase_admin`. `postgres` — **NOSUPERUSER** с `CREATEROLE`, владелец базы, схемы `katona` и таблиц, как в Supabase.
- **Файлы** `sql/dashboard_deploy.sql` и `sql/dashboard_rollback.sql` выполнялись **как есть**: одной командой, как в SQL Editor, и через `psql -v ON_ERROR_STOP=1 -f`.
- **Заглушка** содержит подтверждённые столбцы и CHECK статусов, столбцы-«приманки» ПД (`imya`, `telefon`, `vneshniy_id`, `rezyume`, `dannye`, `zayavki.telefon`), а также существующие объекты:
  - роли `katona_dashboard_read` (с `USAGE` и `audit_dashboard_summary()`), `katona_dashboard_admin` (3 функции), `katona_bot`/`katona_service` и n8n-логины;
  - прямое разрешение `kb_v2_*` у служебного логина;
  - `anon`, `authenticated`, `service_role`, созданные суперпользователем;
  - две записи default privileges для функций.
- **Снимок** всех существовавших ACL функций, таблиц, столбцов и схемы, членств, атрибутов и параметров ролей и default privileges сравнивался до внедрения, после него и после отката.

**Результат: 137 проверок из 137 пройдены.**

| Сценарий | Что проверено |
|---|---|
| T1. `postgres` без суперпользователя; default privileges: EXECUTE для `anon`/`authenticated`/`service_role` на схему + глобальный отзыв у `PUBLIC`; запуск одной командой | **Внедрение:** создаются 3 роли и 6 функций; существующие права, членства и параметры **не изменились**; запросы §3.4 и §3.5 дают ожидаемое. **KPI:** 6 / 2 / 33,3 % / 2, аномалия 1, исключено 2; не зависят от `TimeZone` сессии. **Виджеты:** динамика по дням MSK с нулевыми днями и секундными границами, распределение этапов, постраничный вывод, канал через `identifikatory_kanalov`, фильтр статуса, `LIMIT` 1–21, пустой период, ошибки периода `22023`. **Изоляция** — следующая строка. **Откат:** состояние каталога **идентично** исходному; повторный откат ничего не меняет; повторное внедрение и откат проходят |
| T1. Изоляция LOGIN (не суперпользователь) | Выполняет **ровно 4** функции в `katona`. **Отказ:** `audit_dashboard_summary()`, оба helper, функции admin (`otozvat_dokument_znaniy`, `razblokirovat_polzovatelya`), n8n (`zaregistrirovat_vhod_klienta`), `kb_v2_*`, все 5 таблиц, `INSERT` (в том числе после `SET default_transaction_read_only = off`), `CREATE` в схеме, `SET ROLE` в owner и в `katona_dashboard_read`. **Прочие роли:** NOLOGIN owner и api_exec войти не могут; owner не читает ни одного столбца ПД. У `PUBLIC`, `anon`, `authenticated`, `service_role`, `katona_dashboard_read`, `katona_dashboard_admin`, `katona_bot`, `katona_service`, обоих n8n-логинов и самого `postgres` нет EXECUTE на функции дашборда. У `postgres` остаётся только автоматический ADMIN OPTION на новые роли, без SET/INHERIT |
| T2. Default privileges с глобальной выдачей EXECUTE в том числе существующей `katona_dashboard_read`; `createrole_self_grant = 'set, inherit'`; запуск через `psql -f` | Все проверки T1 повторены и пройдены: лишние EXECUTE (включая `katona_dashboard_read`) сняты только с новых функций, самовыдача членства снята, откат восстанавливает исходное состояние |
| T3. Испорченное внедрение (лишний `GRANT SELECT (imya)`) | Прервано `dashboard_check_owner_columns`; ничего не осталось, состояние не изменилось |
| T4. Роль `katona_dashboard_api_exec` уже существует | Остановлено `dashboard_pre_roles_exist`; существующая роль не тронута |
| T5. Нет столбца `polzovateli.sluzhebnyy` | Остановлено `dashboard_pre_columns` с именем столбца; ничего не создано |
| T6. Откат без внедрения | Проходит, ничего не меняет |
| T7. `postgres` не владеет схемой и таблицами | Остановлено `dashboard_pre_ownership`; ничего не создано |

**Найдено и исправлено проверкой:** первая версия отката снимала права владельца через `REVOKE ALL ON <таблица>`. Права при этом не менялись, но неявный ACL таблиц (`NULL`) превращался в явный, то есть каталог отличался от исходного. Теперь откат снимает ровно выданные права по столбцам, и все сравниваемые данные каталога (ACL, членства, атрибуты и параметры ролей, default privileges) после отката совпадают с исходными.

**Готовность.** SQL проверен на той же версии PostgreSQL и с той же моделью прав исполнителя, что в Supabase. Не проверены только особенности самой платформы Supabase (§6, п. 1–2): при любом отказе скрипт откатывается целиком. Выполнение в рабочей Supabase — только после утверждения руководителем и разрешения пользователя (D1-02B).
