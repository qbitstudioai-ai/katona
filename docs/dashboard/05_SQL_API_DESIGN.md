# DASH-D1-01R — проект SQL и API дашборда

**Статус: исправленный проект (D1-01R) на проверку руководителя проекта. В Supabase ничего не выполнено.** Роли, функции и права ниже не существуют, пока пользователь отдельно не разрешит их создание (D1-02). Рабочая версия 1.0, без пилота и урезанного MVP. Результаты проверки во временном локальном PostgreSQL — §7.

Основание: [`DATA_AUDIT.md`](DATA_AUDIT.md) (источники, права, проверки), [`01_METRICS_AND_DATA.md`](01_METRICS_AND_DATA.md) (определения), [`02_UX_AND_FILTERS.md`](02_UX_AND_FILTERS.md) (экран), [`03_IMPLEMENTATION_PLAN.md`](03_IMPLEMENTATION_PLAN.md) (архитектура подключения).

## 1. Используемая структура (подтверждена аудитом руководителя)

| Таблица | Столбцы, которые читает дашборд |
|---|---|
| `katona.dialogi` | `id uuid`, `polzovatel_id uuid`, `identifikator_kanala_id uuid`, `etap text`, `status text`, `rezultat`, `vremya_nachala timestamptz NOT NULL` |
| `katona.identifikatory_kanalov` | `id uuid`, `kanal text` |
| `katona.celevye_sobytiya` | `dialog_id`, `kod_celi`, `podtverzhdeno boolean` |
| `katona.polzovateli` | `id uuid`, `testovyy boolean`, `sluzhebnyy boolean` |

- Канал диалога: `dialogi.identifikator_kanala_id → identifikatory_kanalov.id`, значение `identifikatory_kanalov.kanal`. Столбца `dialogi.kanal` нет.
- Допустимые `dialogi.status` по CHECK: `aktivnyy`, `ozhidaet_otveta`, `peredan_cheloveku`, `zavershen`.
- Тип `rezultat` и `kod_celi` в SQL приводится к `text`, поэтому проект от него не зависит.
- Никакие другие столбцы этих таблиц дашборду не выдаются: внешние идентификаторы каналов (Telegram ID и т.п.), имена, телефоны и тексты недоступны даже роли-владельцу функций.

## 2. Состав объектов

| Объект | Тип | Кто вызывает | Назначение |
|---|---|---|---|
| `katona_dashboard_owner` | NOLOGIN-роль | — | Владелец функций дашборда; только `SELECT` по столбцам из §1 |
| `katona_dashboard_api_login` | LOGIN-роль | сервер дашборда | Входит только в `katona_dashboard_read` |
| `katona.dashboard_granicy(date, date)` | helper, INVOKER | функции дашборда | Проверка периода, границы суток в `Europe/Moscow` |
| `katona.dashboard_kogorta(timestamptz, timestamptz)` | helper, INVOKER | функции дашборда | **Единственное** определение когорты, канала, цели, потери и исключения тестовых |
| `katona.dashboard_obzor(date, date)` | DEFINER | `katona_dashboard_read` | 4 KPI, аномалия, число исключённых |
| `katona.dashboard_dinamika(date, date)` | DEFINER | `katona_dashboard_read` | Новые обращения и цели по дням MSK |
| `katona.dashboard_etapy(date, date)` | DEFINER | `katona_dashboard_read` | Распределение когорты по текущим этапам |
| `katona.dashboard_poslednie(date, date, int, text, timestamptz, uuid)` | DEFINER | `katona_dashboard_read` | Страница последних обращений, keyset |

Helpers объявлены `SECURITY INVOKER` и вызываются только из DEFINER-функций, то есть выполняются с правами `katona_dashboard_owner`. `katona_dashboard_read` и LOGIN-роль вызвать их напрямую не могут. Воронки (`sobytiya_etapov`) в контракте нет: полнота маршрутов истории не доказана (`DATA_AUDIT.md` §7).

## 3. Проект SQL (не выполнять до ревью и разрешения пользователя)

Внедрение — **одна транзакция** (§3.1–§3.6): при любой ошибке, включая встроенные проверки в конце, не остаётся ни роли, ни функции, ни права. Пароль LOGIN-роли в скрипте отсутствует и задаётся отдельно (§3.6).

### 3.0. Перед внедрением (только SELECT)

```sql
SELECT current_user                                                  AS ispolnitel,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)  AS superuser,
       current_setting('server_version')                             AS versiya,
       has_schema_privilege('katona_dashboard_read', 'katona', 'USAGE') AS read_usage_do,
       (SELECT count(*) FROM pg_default_acl d
         WHERE d.defaclobjtype = 'f'
           AND (d.defaclnamespace = 0
                OR d.defaclnamespace = 'katona'::regnamespace))       AS default_acl_funkciy,
       (SELECT count(*) FROM pg_roles
         WHERE rolname IN ('katona_dashboard_owner', 'katona_dashboard_api_login')) AS uzhe_est;
```

Ожидаем `uzhe_est = 0`. Значение `read_usage_do` записать: от него зависит откат (§3.8). `default_acl_funkciy > 0` не запрещает внедрение — лишние права всё равно отзываются и проверяются в §3.5–§3.6, — но стоит учесть.

### 3.1. Роль-владелец и минимальные права чтения

```sql
BEGIN;

CREATE ROLE katona_dashboard_owner NOLOGIN NOINHERIT;

GRANT USAGE ON SCHEMA katona TO katona_dashboard_owner;
GRANT SELECT (id, polzovatel_id, identifikator_kanala_id, etap, status, rezultat, vremya_nachala)
   ON katona.dialogi TO katona_dashboard_owner;
GRANT SELECT (id, kanal)
   ON katona.identifikatory_kanalov TO katona_dashboard_owner;
GRANT SELECT (dialog_id, kod_celi, podtverzhdeno)
   ON katona.celevye_sobytiya TO katona_dashboard_owner;
GRANT SELECT (id, testovyy, sluzhebnyy)
   ON katona.polzovateli TO katona_dashboard_owner;
```

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
RETURNS TABLE (dialog_id      uuid,
               vremya_nachala timestamptz,
               kanal          text,
               etap           text,
               status         text,
               rezultat       text,
               cel            boolean,
               poterya        boolean,
               isklyuchen     boolean)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT d.id,
           d.vremya_nachala,
           ik.kanal,
           d.etap,
           d.status,
           d.rezultat::text,
           EXISTS (SELECT 1
                     FROM katona.celevye_sobytiya ce
                    WHERE ce.dialog_id = d.id
                      AND ce.kod_celi::text = 'ostavit_zayavku'
                      AND ce.podtverzhdeno = true),
           (d.status = 'zavershen' AND d.rezultat::text = 'net_otveta'),
           (COALESCE(p.testovyy, false) OR COALESCE(p.sluzhebnyy, false))
      FROM katona.dialogi d
      LEFT JOIN katona.identifikatory_kanalov ik ON ik.id = d.identifikator_kanala_id
      LEFT JOIN katona.polzovateli p           ON p.id  = d.polzovatel_id
     WHERE d.vremya_nachala >= p_nachalo
       AND d.vremya_nachala <  p_konec
$$;
```

- Одна строка на `dialogi.id`: оба `LEFT JOIN` идут по первичным ключам, цель — через `EXISTS`, поэтому несколько целевых событий строк не размножают. Во всех агрегатах дополнительно `count(DISTINCT dialog_id)`.
- `LEFT JOIN`: диалог без канала или пользователя не теряется из когорты (канал `NULL`, не исключён).
- Цель — только `ostavit_zayavku` и `podtverzhdeno=true`. Потеря — `zavershen` и `net_otveta`. Диалог с целью и потерей учитывается в обоих KPI и в счётчике аномалии.
- Исключаются диалоги пользователей с `testovyy=true` или `sluzhebnyy=true`. Ограничения этого правила — §5.

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

CREATE FUNCTION katona.dashboard_poslednie(p_s            date,
                                           p_po           date,
                                           p_limit        integer     DEFAULT 11,
                                           p_status       text        DEFAULT NULL,
                                           p_posle_vremya timestamptz DEFAULT NULL,
                                           p_posle_id     uuid        DEFAULT NULL)
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
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 11), 1), 21)
$$;
```

- Последние обращения сортируются по `vremya_nachala DESC, id DESC` — порядок стабилен.
- Сервер запрашивает `limit + 1` строк (до 21), чтобы узнать, есть ли следующая страница; клиенту отдаёт не больше 20. SQL ограничивает `LIMIT` диапазоном 1–21 даже при ошибке сервера.
- Значение `p_status` проверяет сервер по списку из §1; неизвестный статус в SQL просто даёт пустую выборку.
- Курсор: `p_posle_vremya` и `p_posle_id` передаются только вместе.
- `dialog_id` возвращается только серверу для курсора; в ответ API он не попадает (§4).

### 3.5. Владелец, отзыв лишних прав, выдача EXECUTE

```sql
-- ALTER ... OWNER требует: у исполнителя — права SET ROLE на новую роль-владельца,
-- у роли-владельца — CREATE на схеме. Оба права временные и отзываются ниже в этой же транзакции.
GRANT katona_dashboard_owner TO CURRENT_USER;
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

-- Отозвать EXECUTE, выданный конкретным ролям через default privileges
-- (в Supabase это бывают anon, authenticated, service_role).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS fn, a.grantee
          FROM pg_proc p
         CROSS JOIN LATERAL aclexplode(p.proacl) a
         WHERE p.pronamespace = 'katona'::regnamespace
           AND p.proname LIKE 'dashboard\_%'
           AND a.grantee <> 0
           AND a.grantee NOT IN ('katona_dashboard_owner'::regrole, 'katona_dashboard_read'::regrole)
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', r.fn, pg_get_userbyid(r.grantee));
    END LOOP;
END
$$;

REVOKE katona_dashboard_owner FROM CURRENT_USER;
```

`REVOKE … FROM PUBLIC` не отзывает права, выданные конкретным ролям через default privileges, поэтому их снимает цикл выше. Затем §3.6 заканчивается проверкой ACL: если у новой функции всё-таки есть EXECUTE у кого-то, кроме владельца и `katona_dashboard_read`, транзакция прерывается целиком.

`audit_dashboard_summary` остаётся у `katona_dashboard_read` и дашбордом не используется.

### 3.6. LOGIN-роль сервера дашборда и встроенная проверка

```sql
CREATE ROLE katona_dashboard_api_login LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5
    IN ROLE katona_dashboard_read;
ALTER ROLE katona_dashboard_api_login SET default_transaction_read_only = on;
ALTER ROLE katona_dashboard_api_login SET statement_timeout = '5s';
ALTER ROLE katona_dashboard_api_login SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE katona_dashboard_api_login SET search_path = pg_catalog;

DO $$
DECLARE
    v_owner oid := 'katona_dashboard_owner'::regrole;
    v_read  oid := 'katona_dashboard_read'::regrole;
    v_api   oid := 'katona_dashboard_api_login'::regrole;
    v_bad   bigint;
BEGIN
    -- 6 функций, владелец — katona_dashboard_owner, search_path зафиксирован
    SELECT count(*) INTO v_bad
      FROM pg_proc p
     WHERE p.pronamespace = 'katona'::regnamespace
       AND p.proname LIKE 'dashboard\_%'
       AND p.proowner = v_owner
       AND p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp'];
    IF v_bad <> 6 THEN
        RAISE EXCEPTION 'dashboard_check_functions: % of 6', v_bad;
    END IF;

    -- SECURITY DEFINER ровно у 4 функций API
    SELECT count(*) INTO v_bad
      FROM pg_proc p
     WHERE p.pronamespace = 'katona'::regnamespace
       AND p.proname LIKE 'dashboard\_%'
       AND p.prosecdef <> (p.proname IN ('dashboard_obzor', 'dashboard_dinamika',
                                         'dashboard_etapy', 'dashboard_poslednie'));
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'dashboard_check_secdef: %', v_bad;
    END IF;

    -- EXECUTE только у владельца и katona_dashboard_read (и не у PUBLIC)
    SELECT count(*) INTO v_bad
      FROM pg_proc p
     CROSS JOIN LATERAL aclexplode(p.proacl) a
     WHERE p.pronamespace = 'katona'::regnamespace
       AND p.proname LIKE 'dashboard\_%'
       AND a.grantee NOT IN (v_owner, v_read);
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'dashboard_check_execute: % extra grants', v_bad;
    END IF;

    -- helpers недоступны katona_dashboard_read
    IF has_function_privilege(v_read, 'katona.dashboard_kogorta(timestamptz, timestamptz)', 'EXECUTE')
       OR has_function_privilege(v_read, 'katona.dashboard_granicy(date, date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'dashboard_check_helpers';
    END IF;

    -- LOGIN-роль: ни одного права SELECT на объекты katona, ни прав на таблицы владельцу сверх §3.1
    SELECT count(*) INTO v_bad
      FROM pg_class c
     WHERE c.relnamespace = 'katona'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND has_table_privilege(v_api, c.oid, 'SELECT');
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'dashboard_check_api_tables: %', v_bad;
    END IF;

    SELECT count(*) INTO v_bad
      FROM pg_class c
     WHERE c.relnamespace = 'katona'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND has_table_privilege(v_owner, c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE');
    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'dashboard_check_owner_tables: %', v_bad;
    END IF;

    -- владелец читает ровно 15 столбцов из §3.1 и ни одного другого
    SELECT count(*) INTO v_bad
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relnamespace = 'katona'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND a.attnum > 0 AND NOT a.attisdropped
       AND has_column_privilege(v_owner, c.oid, a.attnum, 'SELECT');
    IF v_bad <> 15 THEN
        RAISE EXCEPTION 'dashboard_check_owner_columns: % of 15', v_bad;
    END IF;

    IF has_schema_privilege(v_owner, 'katona', 'CREATE') THEN
        RAISE EXCEPTION 'dashboard_check_owner_create';
    END IF;

    -- в роль-владельца не входит никто, кроме исполнителя скрипта
    -- (PostgreSQL 16 сам оставляет создателю роли ADMIN OPTION без SET/INHERIT)
    IF EXISTS (SELECT 1 FROM pg_auth_members m
                WHERE m.roleid = v_owner
                  AND m.member <> (SELECT oid FROM pg_roles WHERE rolname = current_user)) THEN
        RAISE EXCEPTION 'dashboard_check_owner_members';
    END IF;

    -- LOGIN-роль входит только в katona_dashboard_read
    IF (SELECT array_agg(m.roleid) FROM pg_auth_members m WHERE m.member = v_api) <> ARRAY[v_read] THEN
        RAISE EXCEPTION 'dashboard_check_api_membership';
    END IF;
END
$$;

COMMIT;
```

- **Пароль** пользователь задаёт после внедрения через `psql` командой `\password katona_dashboard_api_login`: пароль хэшируется на клиенте и не попадает в журнал запросов. `ALTER ROLE … PASSWORD '…'` в SQL Editor использовать не рекомендуется — открытый текст может оказаться в логах. Пароль хранится только в секретах сервера дашборда; в GitHub, n8n и браузер он не попадает.
- **Граница безопасности — права, а не `default_transaction_read_only`.** Сессия может сама выключить этот параметр, поэтому он лишь страхует от случайной записи. Писать роль не может потому, что у неё нет прав ни на одну таблицу, а DEFINER-функции только читают.
- `katona_n8n_*`, `katona_dashboard_admin`, `postgres`, `service_role`, `anon`/`authenticated` и PostgREST дашборд не использует.

### 3.7. Проверка после внедрения (только SELECT)

```sql
SELECT p.proname,
       pg_get_userbyid(p.proowner) AS owner,
       p.prosecdef AS security_definer,
       array_to_string(p.proconfig, '; ') AS config,
       has_function_privilege('katona_dashboard_api_login', p.oid, 'EXECUTE') AS api_login,
       (SELECT count(*) FROM pg_roles r
         WHERE r.rolname IN ('anon', 'authenticated', 'service_role', 'katona_bot', 'katona_service')
           AND has_function_privilege(r.oid, p.oid, 'EXECUTE')) AS lishnie_prava,
       (SELECT count(*) FROM pg_class c
         WHERE c.relnamespace = 'katona'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
           AND has_table_privilege('katona_dashboard_api_login', c.oid, 'SELECT')) AS api_login_tablic
  FROM pg_proc p
 WHERE p.pronamespace = 'katona'::regnamespace AND p.proname LIKE 'dashboard\_%'
 ORDER BY p.proname;
```

Ожидаем: владелец `katona_dashboard_owner`; `security_definer=true` у 4 функций API и `false` у двух helpers; `config = search_path=pg_catalog, pg_temp`; `api_login=true` только у 4 функций API; `lishnie_prava=0`; `api_login_tablic=0`. Затем сверить KPI из `dashboard_obzor` с ручным агрегатным SELECT руководителя за тот же период.

### 3.8. Откат

```sql
BEGIN;
-- Удалить функции может их владелец или владелец схемы katona. Если исполнитель не владеет
-- схемой и не суперпользователь, ему нужны права роли-владельца; для остальных строка безвредна.
-- Членство пропадает вместе с ролью при DROP ROLE.
GRANT katona_dashboard_owner TO CURRENT_USER;
DROP FUNCTION IF EXISTS
    katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid),
    katona.dashboard_etapy(date, date),
    katona.dashboard_dinamika(date, date),
    katona.dashboard_obzor(date, date),
    katona.dashboard_kogorta(timestamptz, timestamptz),
    katona.dashboard_granicy(date, date);
DROP ROLE IF EXISTS katona_dashboard_api_login;
REVOKE ALL ON katona.dialogi, katona.identifikatory_kanalov,
              katona.celevye_sobytiya, katona.polzovateli
  FROM katona_dashboard_owner;
REVOKE ALL ON SCHEMA katona FROM katona_dashboard_owner;
DROP ROLE IF EXISTS katona_dashboard_owner;
-- Только если в §3.0 было read_usage_do = false:
-- REVOKE USAGE ON SCHEMA katona FROM katona_dashboard_read;
COMMIT;
```

`REVOKE ALL ON <таблица>` снимает и права по столбцам. Откат не затрагивает n8n, `katona_bot`, `katona_service`, 9 разрешений `kb_v2_*` и `audit_dashboard_summary`.

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

## 6. Открытые вопросы до внедрения (D1-02)

1. Роль, от имени которой пользователь выполнит SQL, и версия PostgreSQL Supabase (§3.0). Локальная проверка шла на PostgreSQL 16 под суперпользователем (§7).
2. Сетевой путь сервера дашборда к PostgreSQL (SSH-туннель или приватная сеть) и ограничение входа роли в `pg_hba` по адресу сервера.
3. Механизм входа руководителя и хранение сессий (кто руководитель, сколько пользователей).
4. Механизм классификации тестовых и служебных обращений (§5): решение руководителя и разрешение пользователя.
5. Индексы: после внедрения на реальном объёме — `EXPLAIN` для `dialogi(vremya_nachala)` и `celevye_sobytiya(dialog_id)`. Новые индексы — только по результатам и с согласия пользователя.
6. Индикатор «Ожидают менеджера» в контракт не включён. Статус `peredan_cheloveku` есть, но он не отличает «запрошено» от «взято менеджером»; по `02_UX_AND_FILTERS.md` индикатор скрывается.

## 7. Проверка во временном локальном PostgreSQL

**Среда.** PostgreSQL 16.2 — временный кластер на `127.0.0.1` во временной папке исполнителя, удаляется после проверки; к Supabase не подключался. SQL взят **дословно** из §3.0–§3.8 этого документа.

**Заглушка схемы.** Таблицы `katona.dialogi`, `identifikatory_kanalov`, `celevye_sobytiya`, `polzovateli` с подтверждёнными столбцами и CHECK статусов. Добавлены «приманки» ПД, которые должны оставаться недоступными: `polzovateli.imya`/`telefon`, `identifikatory_kanalov.vneshniy_id`, `dialogi.rezyume`, `celevye_sobytiya.dannye`, `zayavki.telefon`. Также созданы роли `anon`, `authenticated`, `service_role` с `USAGE` на схему и default privileges `EXECUTE` на функции, как бывает в Supabase. Тестовые данные: границы суток MSK с точностью до секунды, дубли целевого события, неподтверждённая цель, другой код цели, аномалия «цель + потеря», тестовый и служебный пользователи, диалог без пользователя и канала, два канала, 25 диалогов для проверки `LIMIT`.

**Результат: 55 проверок из 55 пройдены.**

| Сценарий | Что проверено |
|---|---|
| S1. Внедрение суперпользователем при default privileges для `anon`/`authenticated`/`service_role` | Транзакция проходит; запрос §3.7 даёт ожидаемые 6 строк. KPI: 6 обращений, 2 цели, 33,3 %, 2 потерянных, аномалия 1, исключено 2 — совпадают с ручным расчётом. Те же цифры при `TimeZone` сессии `Pacific/Kiritimati` и `America/Los_Angeles`. Динамика по дням MSK с нулевыми днями и секундными границами; сумма равна KPI. Распределение этапов. Постраничный вывод без пропусков и повторов; канал через `identifikatory_kanalov` (`telegram`, `sayt`, `NULL`). Фильтр статуса; `LIMIT` 1–21, по умолчанию 11. Пустой период → нули и конверсия `NULL`. Ошибки периода с SQLSTATE `22023`, период 366 дней принимается |
| S1. Права | LOGIN-роль: helpers, все 4 таблицы, `INSERT` (и после `SET default_transaction_read_only = off`) и `CREATE` в схеме — отказ. NOLOGIN-роли `katona_dashboard_owner` и `katona_dashboard_read` войти не могут. Владелец не читает ни один столбец-приманку ПД, но читает `identifikatory_kanalov.kanal`. `anon`, `authenticated`, `service_role`, `katona_bot`, `katona_service` не могут вызвать функции дашборда, несмотря на default privileges |
| S1. Откат и повторное внедрение | §3.8 удаляет обе роли и все 6 функций; право на `audit_dashboard_summary` сохраняется; повторное внедрение после отката проходит |
| S2. Испорченное внедрение | Лишний `GRANT SELECT (imya)` перед проверкой → встроенная проверка `dashboard_check_owner_columns` прерывает транзакцию; не остаётся ни ролей, ни функций |
| S3. Внедрение ролью без суперпользователя (`CREATEROLE`, владелец схемы и таблиц — как `postgres` в Supabase) | Внедрение, §3.7, KPI и откат проходят. После внедрения у исполнителя остаётся только автоматический ADMIN OPTION PostgreSQL 16 на созданные роли, без `SET`/`INHERIT`; других участников у роли-владельца нет |

**Не проверено — не считать подтверждённым до внедрения:**

1. **Версия PostgreSQL Supabase.** Если это PostgreSQL 15, правила членства в ролях другие (нет опций `SET`/`INHERIT` у членства, иначе работает `CREATEROLE`). Скрипт написан без синтаксиса, специфичного для 16, но выполнение на 15 не проверялось.
2. **Ограничения самой Supabase:** расширение `supautils` (запрет операций с «зарезервированными» ролями), event triggers, фактические default privileges и то, суперпользователь ли `postgres`. Это покажет §3.0.
3. **Исполнитель, который не владеет схемой `katona` и не суперпользователь** — не моделировался.
4. **Реальные типы `rezultat` и `kod_celi`** (в заглушке `text`); приведение `::text` покрывает `text`, `varchar` и enum, но на живой схеме не запускалось.
5. **Производительность и `EXPLAIN`** на реальном объёме, сетевой путь, `pg_hba`, установка пароля через `\password`.
6. **Серверный API** (§4), включая AEAD-курсор и авторизацию, не реализован и не тестировался — только контракт.
