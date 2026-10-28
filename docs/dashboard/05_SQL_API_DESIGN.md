# DASH-D1-01 — проект SQL и API дашборда

**Статус: проект на проверку руководителя проекта. Ничего не выполнено в Supabase.** Роли, функции и права ниже не существуют, пока пользователь отдельно не разрешит их создание (D1-02). Рабочая версия 1.0, без пилота и урезанного MVP.

Основание: [`DATA_AUDIT.md`](DATA_AUDIT.md) (источники, права, проверки), [`01_METRICS_AND_DATA.md`](01_METRICS_AND_DATA.md) (определения), [`02_UX_AND_FILTERS.md`](02_UX_AND_FILTERS.md) (экран), [`03_IMPLEMENTATION_PLAN.md`](03_IMPLEMENTATION_PLAN.md) (архитектура подключения).

## 1. Идентификаторы и что ещё нужно подтвердить

| Идентификатор | Статус |
|---|---|
| `katona.dialogi`: `id`, `vremya_nachala timestamptz NOT NULL`, `status`, `rezultat` | ✅ |
| `katona.celevye_sobytiya`: `dialog_id`, `kod_celi`, `podtverzhdeno` | ✅ |
| `katona.polzovateli`: `id`, `testovyy`, `sluzhebnyy` | ✅ |
| FK основных таблиц на `dialogi.id` | ✅ |
| `dialogi.etap` — текущий этап | ❓ **имя столбца** (этап хранится и согласован с историей, имя в аудите не названо) |
| `dialogi.kanal` — канал | ❓ **имя столбца** |
| `dialogi.polzovatel_id` — ссылка на `polzovateli.id` | ❓ **имя столбца** |
| Типы: `dialogi.id uuid`; `status`, `rezultat`, этап, канал — `text`; `testovyy`, `sluzhebnyy` — `boolean NOT NULL` | 🟡 uuid по Workflow; остальное ❓ |

В SQL ниже такие места помечены комментарием `-- ❓`. До ревью SQL их нужно сверить по SQL-D0-4; при другом имени или типе меняется только helper `dashboard_kogorta`.

## 2. Состав объектов

| Объект | Тип | Кто вызывает | Назначение |
|---|---|---|---|
| `katona_dashboard_owner` | NOLOGIN-роль | — | Владелец функций дашборда, только `SELECT` по нужным столбцам |
| `katona_dashboard_api_login` | LOGIN-роль | сервер дашборда | Входит только в `katona_dashboard_read` |
| `katona.dashboard_granicy(date, date)` | helper, INVOKER | функции дашборда | Проверка периода, границы суток в `Europe/Moscow` |
| `katona.dashboard_kogorta(timestamptz, timestamptz)` | helper, INVOKER | функции дашборда | **Единственное** определение когорты, цели, потери и исключения тестовых |
| `katona.dashboard_obzor(date, date)` | DEFINER | `katona_dashboard_read` | 4 KPI, аномалия, число исключённых |
| `katona.dashboard_dinamika(date, date)` | DEFINER | `katona_dashboard_read` | Новые обращения и цели по дням MSK |
| `katona.dashboard_etapy(date, date)` | DEFINER | `katona_dashboard_read` | Распределение когорты по текущим этапам |
| `katona.dashboard_poslednie(date, date, int, text, timestamptz, uuid)` | DEFINER | `katona_dashboard_read` | Страница последних обращений, keyset-курсор |

Все KPI и виджеты берут данные из `dashboard_kogorta`, поэтому карточки, график и распределение не могут разойтись в определениях. Воронки (`sobytiya_etapov`) в контракте нет: полнота маршрутов истории не доказана (`DATA_AUDIT.md` §7).

## 3. Проект SQL (не выполнять до ревью и разрешения пользователя)

Скрипт рассчитан на одну транзакцию: при любой ошибке не остаётся ни роли, ни функции. Пароль LOGIN-роли в скрипте отсутствует и задаётся пользователем отдельно (§3.6).

### 3.1. Роль-владелец и минимальные права чтения

```sql
BEGIN;

CREATE ROLE katona_dashboard_owner NOLOGIN NOINHERIT;

GRANT USAGE ON SCHEMA katona TO katona_dashboard_owner;
GRANT SELECT (id, vremya_nachala, status, rezultat,
              etap,           -- ❓ имя столбца текущего этапа
              kanal,          -- ❓ имя столбца канала
              polzovatel_id)  -- ❓ имя ссылки на polzovateli
   ON katona.dialogi TO katona_dashboard_owner;
GRANT SELECT (dialog_id, kod_celi, podtverzhdeno)
   ON katona.celevye_sobytiya TO katona_dashboard_owner;
GRANT SELECT (id, testovyy, sluzhebnyy)
   ON katona.polzovateli TO katona_dashboard_owner;
```

Права выдаются по столбцам: ни сырой текст, ни имена, ни телефоны, ни Telegram ID владельцу недоступны даже при ошибке в функции.

### 3.2. Helper: период в `Europe/Moscow`

```sql
CREATE FUNCTION katona.dashboard_granicy(p_s date, p_po date)
RETURNS TABLE (nachalo timestamptz, konec timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_segodnya date := (now() AT TIME ZONE 'Europe/Moscow')::date;
BEGIN
    IF p_s IS NULL OR p_po IS NULL OR p_s > p_po THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'dashboard_period_invalid';
    END IF;
    IF p_po - p_s > 365 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'dashboard_period_too_long';
    END IF;
    IF p_s > v_segodnya THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'dashboard_period_in_future';
    END IF;
    nachalo := p_s::timestamp AT TIME ZONE 'Europe/Moscow';
    konec   := (p_po + 1)::timestamp AT TIME ZONE 'Europe/Moscow';
    RETURN NEXT;
END
$$;
```

Даты включительные в MSK → полуинтервал `[p_s 00:00 MSK, (p_po + 1) 00:00 MSK)`. Максимум 366 дней.

### 3.3. Helper: единая когорта

```sql
CREATE FUNCTION katona.dashboard_kogorta(p_nachalo timestamptz, p_konec timestamptz)
RETURNS TABLE (dialog_id      uuid,          -- 🟡 тип dialogi.id
               vremya_nachala timestamptz,
               status         text,
               rezultat       text,
               etap           text,
               kanal          text,
               cel            boolean,
               poterya        boolean,
               isklyuchen     boolean)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT d.id,
           d.vremya_nachala,
           d.status::text,
           d.rezultat::text,
           d.etap::text,                       -- ❓
           d.kanal::text,                      -- ❓
           EXISTS (SELECT 1
                     FROM katona.celevye_sobytiya ce
                    WHERE ce.dialog_id = d.id
                      AND ce.kod_celi = 'ostavit_zayavku'
                      AND ce.podtverzhdeno = true),
           (d.status = 'zavershen' AND d.rezultat = 'net_otveta'),
           (COALESCE(p.testovyy, false) OR COALESCE(p.sluzhebnyy, false))
      FROM katona.dialogi d
      LEFT JOIN katona.polzovateli p ON p.id = d.polzovatel_id   -- ❓
     WHERE d.vremya_nachala >= p_nachalo
       AND d.vremya_nachala <  p_konec
$$;
```

- Одна строка на `dialogi.id`. Цель проверяется через `EXISTS`, поэтому несколько событий одного диалога строк не размножают. Во всех агрегатах дополнительно `count(DISTINCT dialog_id)`.
- Цель — только `ostavit_zayavku` и `podtverzhdeno=true`. Потеря — `zavershen` и `net_otveta`. Диалог с целью и потерей учитывается в обоих KPI и в счётчике аномалии.
- Исключаются диалоги пользователей с `testovyy=true` или `sluzhebnyy=true`. Достоверность этих флагов — отдельное условие запуска (§5).

### 3.4. Функции API

```sql
CREATE FUNCTION katona.dashboard_obzor(p_s date, p_po date)
RETURNS TABLE (novye_obrashcheniya     bigint,
               dostigli_celi           bigint,
               konversiya_pct          numeric,
               poteryany               bigint,
               anomaliya_cel_i_poterya bigint,
               isklyucheno_testovyh    bigint,
               data_as_of              timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT count(DISTINCT k.dialog_id) FILTER (WHERE NOT k.isklyuchen),
           count(DISTINCT k.dialog_id) FILTER (WHERE NOT k.isklyuchen AND k.cel),
           CASE WHEN count(DISTINCT k.dialog_id) FILTER (WHERE NOT k.isklyuchen) = 0 THEN NULL
                ELSE round(100.0 * count(DISTINCT k.dialog_id) FILTER (WHERE NOT k.isklyuchen AND k.cel)
                                 / count(DISTINCT k.dialog_id) FILTER (WHERE NOT k.isklyuchen), 1)
           END,
           count(DISTINCT k.dialog_id) FILTER (WHERE NOT k.isklyuchen AND k.poterya),
           count(DISTINCT k.dialog_id) FILTER (WHERE NOT k.isklyuchen AND k.cel AND k.poterya),
           count(DISTINCT k.dialog_id) FILTER (WHERE k.isklyuchen),
           now()
      FROM katona.dashboard_granicy(p_s, p_po) g
     CROSS JOIN LATERAL katona.dashboard_kogorta(g.nachalo, g.konec) k
$$;

CREATE FUNCTION katona.dashboard_dinamika(p_s date, p_po date)
RETURNS TABLE (den date, novye_obrashcheniya bigint, dostigli_celi bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH g AS (
        SELECT * FROM katona.dashboard_granicy(p_s, p_po)
    ), k AS (
        SELECT (kk.vremya_nachala AT TIME ZONE 'Europe/Moscow')::date AS den,
               kk.dialog_id,
               kk.cel
          FROM g
         CROSS JOIN LATERAL katona.dashboard_kogorta(g.nachalo, g.konec) kk
         WHERE NOT kk.isklyuchen
    )
    SELECT dni.d::date,
           count(DISTINCT k.dialog_id),
           count(DISTINCT k.dialog_id) FILTER (WHERE k.cel)
      FROM g
     CROSS JOIN generate_series(p_s::timestamp, p_po::timestamp, interval '1 day') AS dni(d)
      LEFT JOIN k ON k.den = dni.d::date
     GROUP BY dni.d
     ORDER BY dni.d
$$;

CREATE FUNCTION katona.dashboard_etapy(p_s date, p_po date)
RETURNS TABLE (etap text, dialogov bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT k.etap, count(DISTINCT k.dialog_id)
      FROM katona.dashboard_granicy(p_s, p_po) g
     CROSS JOIN LATERAL katona.dashboard_kogorta(g.nachalo, g.konec) k
     WHERE NOT k.isklyuchen
     GROUP BY k.etap
     ORDER BY 2 DESC, 1
$$;

CREATE FUNCTION katona.dashboard_poslednie(p_s           date,
                                           p_po          date,
                                           p_limit       integer     DEFAULT 10,
                                           p_status      text        DEFAULT NULL,
                                           p_posle_vremya timestamptz DEFAULT NULL,
                                           p_posle_id    uuid        DEFAULT NULL)
RETURNS TABLE (dialog_id      uuid,
               vremya_nachala timestamptz,
               kanal          text,
               etap           text,
               status         text,
               rezultat       text,
               cel_dostignuta boolean,
               anomaliya      boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT k.dialog_id, k.vremya_nachala, k.kanal, k.etap, k.status, k.rezultat,
           k.cel, (k.cel AND k.poterya)
      FROM katona.dashboard_granicy(p_s, p_po) g
     CROSS JOIN LATERAL katona.dashboard_kogorta(g.nachalo, g.konec) k
     WHERE NOT k.isklyuchen
       AND (p_status IS NULL OR k.status = p_status)
       AND (p_posle_vremya IS NULL
            OR (k.vremya_nachala, k.dialog_id) < (p_posle_vremya, p_posle_id))
     ORDER BY k.vremya_nachala DESC, k.dialog_id DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 20)
$$;
```

- Сортировка последних обращений — по `vremya_nachala DESC, id DESC`: оба столбца подтверждены, порядок стабилен. Время последнего события в аудите не подтверждено.
- `dialog_id` возвращается только серверу для курсора; в ответ API он не попадает (§4).
- `LIMIT` дополнительно ограничен в SQL (1–20), даже если сервер ошибётся.

### 3.5. Владелец, отзыв PUBLIC, выдача EXECUTE

```sql
-- Смена владельца требует CREATE на схеме у новой роли: выдаётся только на время ALTER.
-- Если исполнитель скрипта не суперпользователь, ему временно нужно членство в katona_dashboard_owner.
GRANT CREATE ON SCHEMA katona TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_granicy(date, date)                 OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_kogorta(timestamptz, timestamptz)   OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_obzor(date, date)                   OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_dinamika(date, date)                OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_etapy(date, date)                   OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid)
                                                                     OWNER TO katona_dashboard_owner;
REVOKE CREATE ON SCHEMA katona FROM katona_dashboard_owner;

REVOKE ALL ON FUNCTION
    katona.dashboard_granicy(date, date),
    katona.dashboard_kogorta(timestamptz, timestamptz),
    katona.dashboard_obzor(date, date),
    katona.dashboard_dinamika(date, date),
    katona.dashboard_etapy(date, date),
    katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid)
  FROM PUBLIC;

GRANT USAGE ON SCHEMA katona TO katona_dashboard_read;
GRANT EXECUTE ON FUNCTION
    katona.dashboard_obzor(date, date),
    katona.dashboard_dinamika(date, date),
    katona.dashboard_etapy(date, date),
    katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid)
  TO katona_dashboard_read;
```

Helpers `dashboard_granicy` и `dashboard_kogorta` никому не выдаются: их вызывает владелец внутри DEFINER-функций. `audit_dashboard_summary` остаётся у `katona_dashboard_read` и дашбордом не используется.

### 3.6. LOGIN-роль сервера дашборда

```sql
CREATE ROLE katona_dashboard_api_login LOGIN INHERIT CONNECTION LIMIT 5
    IN ROLE katona_dashboard_read;
ALTER ROLE katona_dashboard_api_login SET default_transaction_read_only = on;
ALTER ROLE katona_dashboard_api_login SET statement_timeout = '5s';
ALTER ROLE katona_dashboard_api_login SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE katona_dashboard_api_login SET search_path = pg_catalog;

COMMIT;
```

- Пароль пользователь задаёт отдельно (`ALTER ROLE … PASSWORD` в SQL Editor, вручную), сохраняет только в секретах сервера дашборда. В GitHub, n8n и браузер он не попадает.
- `default_transaction_read_only = on` — вторая защита: даже при ошибке в будущих функциях транзакция этого подключения не может писать.
- `katona_n8n_*`, `katona_dashboard_admin`, `postgres`, `service_role`, `anon`/`authenticated` и PostgREST дашборд не использует.

### 3.7. Проверка после внедрения (только SELECT)

```sql
SELECT p.proname,
       pg_get_userbyid(p.proowner) AS owner,
       p.prosecdef AS security_definer,
       array_to_string(p.proconfig, '; ') AS config,
       has_function_privilege('katona_dashboard_api_login', p.oid, 'EXECUTE') AS api_login,
       (SELECT count(*) FROM pg_roles r
         WHERE r.rolname IN ('anon', 'authenticated', 'katona_bot', 'katona_service')
           AND has_function_privilege(r.oid, p.oid, 'EXECUTE')) AS lishnie_prava,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'katona' AND c.relkind IN ('r', 'p', 'v', 'm')
           AND has_table_privilege('katona_dashboard_api_login', c.oid, 'SELECT')) AS api_login_tablic
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'katona' AND p.proname LIKE 'dashboard\_%'
 ORDER BY p.proname;
```

Ожидаем: владелец `katona_dashboard_owner`; `security_definer=true` у 4 функций API и `false` у двух helpers; `config` содержит `search_path`; `api_login=true` только у 4 функций API; `lishnie_prava=0`; `api_login_tablic=0`. Затем — контрольная сверка: KPI из `dashboard_obzor` против ручного агрегатного SELECT руководителя за тот же период.

### 3.8. Откат

```sql
BEGIN;
DROP FUNCTION IF EXISTS
    katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid),
    katona.dashboard_etapy(date, date),
    katona.dashboard_dinamika(date, date),
    katona.dashboard_obzor(date, date),
    katona.dashboard_kogorta(timestamptz, timestamptz),
    katona.dashboard_granicy(date, date);
DROP ROLE IF EXISTS katona_dashboard_api_login;
REVOKE ALL ON katona.dialogi, katona.celevye_sobytiya, katona.polzovateli FROM katona_dashboard_owner;
REVOKE USAGE ON SCHEMA katona FROM katona_dashboard_owner;
DROP ROLE IF EXISTS katona_dashboard_owner;
COMMIT;
```

`REVOKE USAGE ON SCHEMA katona FROM katona_dashboard_read` в откат **не входит**, если право было до внедрения: перед внедрением зафиксировать `has_schema_privilege('katona_dashboard_read', 'katona', 'USAGE')`. Откат не затрагивает n8n, `katona_bot`, `katona_service` и 9 разрешений `kb_v2_*`.

## 4. Контракт серверного API

Сервер дашборда (Next.js route handlers или аналог) — единственный клиент БД. Браузер обращается только к API ниже, никаких SQL, ролей и ключей на клиенте.

### Общие правила

- **Авторизация:** все запросы требуют сессии руководителя; cookie `HttpOnly`, `Secure`, `SameSite=Strict`. Без сессии — `401`, без роли руководителя — `403`. Механизм входа — открытый вопрос (§6).
- **Период:** `from`, `to` — даты `YYYY-MM-DD` в `Europe/Moscow`, включительно. По умолчанию последние 7 дней с сегодняшним. Предел — 366 дней. Границы суток считает только SQL (`dashboard_granicy`).
- **Согласованность:** все вызовы одного запроса выполняются в одной транзакции `REPEATABLE READ READ ONLY`, поэтому карточки, график и распределение видят один снимок и одно `data_as_of`.
- **ПД:** в ответах нет ID диалогов и пользователей, телефонов, имён, Telegram ID и текстов. Коды этапов и статусов — служебные значения.
- **Кэш:** `Cache-Control: no-store`. Ограничение частоты — 60 запросов в минуту на сессию.
- **Журналы:** request id, endpoint, код ответа, длительность. Без параметров сессии и ПД.
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

Порядок и русские названия этапов сервер берёт из того же списка этапов, что и бот (`prodazhi.etapy`), этапы вне списка идут в конец. `stage: null` подписывается «Этап не указан».

### `GET /api/dashboard/dialogs?from&to&status&limit&cursor`

Вызывает `dashboard_poslednie`. `limit` — 1–20, по умолчанию 10. `status` — значение из разрешённого списка статусов (CHECK `dialogi.status`), фильтр действует **только** на таблицу. `cursor` — непрозрачная base64url-строка из предыдущего ответа.

```ts
interface DialogsResponse {
  period: { from: string; to: string; timezone: 'Europe/Moscow' };
  data_as_of: string;
  data_quality: Pick<DataQuality, 'test_classification' | 'reliable' | 'warnings'>;
  items: {
    started_at: string;                       // ISO 8601
    channel: string | null;
    stage: string | null;
    stage_label: string;
    status: string;
    result: string | null;
    target_reached: boolean;
    anomaly: boolean;
  }[];
  next_cursor: string | null;                 // null — страниц больше нет
}
```

Курсор содержит `vremya_nachala` и `id` последней строки. Сервер проверяет его структуру и подписывает HMAC-ключом из серверных секретов, чтобы браузер не мог подставить произвольные значения. ID наружу не раскрывается в открытом виде.

### Ошибки

Тело ошибки: `{ "error": { "code": string, "message": string } }`, `message` — по-русски, без технических деталей. Частичных ответов и нулей вместо ошибки нет.

| HTTP | `code` | Когда |
|---|---|---|
| 400 | `period_invalid`, `period_too_long`, `period_in_future` | Неверные даты; соответствует `22023` из `dashboard_granicy` |
| 400 | `limit_invalid`, `status_invalid`, `cursor_invalid` | Параметры таблицы |
| 401 | `unauthenticated` | Нет сессии |
| 403 | `forbidden` | Нет роли руководителя |
| 429 | `rate_limited` | Превышена частота |
| 503 | `source_timeout` | `57014` (statement_timeout) |
| 503 | `source_unavailable` | БД или туннель недоступны |
| 500 | `internal` | Прочее; детали только в журнале сервера |

## 5. Исключение тестовых и служебных обращений

- **Правило в БД:** из всех KPI и виджетов исключаются диалоги пользователей с `polzovateli.testovyy=true` или `sluzhebnyy=true`. Число исключённых возвращается отдельно (`excluded_test_or_service`). Отсечения по дате нет.
- **Факт аудита:** у всех 3 пользователей оба флага `false`, хотя все 3 текущих диалога — тестовые. Правило есть, но классификация **не обеспечена**: сегодня статистика полностью состоит из тестовых обращений.
- **Аттестация классификации:** сервер дашборда хранит в конфигурации признак `test_classification = attested | not_attested` с датой и ссылкой на одобренное задание. `attested` выставляется только после двух шагов, оба с разрешения пользователя:
  1. адресная правка флагов существующих тестовых и служебных пользователей (изменение данных Supabase, отдельное задание);
  2. согласованный механизм, который ставит флаг будущим тестировщикам и сотрудникам при регистрации (требует решения по Workflow/SQL, отдельное задание).
- **Пока `not_attested`:** API отдаёт цифры с `reliable=false` и предупреждением `test_classification_not_attested`. UI показывает их как неподтверждённые («статистика может включать тестовые обращения»), а не как достоверные. Рабочая приёмка D3 при `not_attested` невозможна.

## 6. Открытые вопросы до внедрения (D1-02)

1. Имена и типы столбцов с пометкой `❓` (§1): текущий этап, канал, ссылка на пользователя, типы `id` и кодов.
2. Роль, от имени которой пользователь выполняет SQL (суперпользователь или нет), — от этого зависит порядок `ALTER … OWNER` (§3.5).
3. Есть ли уже у `katona_dashboard_read` `USAGE` на `katona` — нужно для корректного отката.
4. Сетевой путь сервера дашборда к PostgreSQL (SSH-туннель или приватная сеть) и ограничение входа роли в `pg_hba` по адресу сервера.
5. Механизм входа руководителя и хранение сессий (кто руководитель, сколько пользователей).
6. Список допустимых значений `dialogi.status` для фильтра таблицы (CHECK из SQL-D0-5).
7. Механизм классификации тестовых и служебных пользователей (§5): решение руководителя и разрешение пользователя.
8. Индексы: после внедрения на реальном объёме — `EXPLAIN` для `dialogi(vremya_nachala)` и `celevye_sobytiya(dialog_id)`. Новые индексы — только по результатам и с согласия пользователя.
9. Индикатор «Ожидают менеджера» в контракт не включён: значения этапа и владельца не подтверждены, по `02_UX_AND_FILTERS.md` он скрывается.
