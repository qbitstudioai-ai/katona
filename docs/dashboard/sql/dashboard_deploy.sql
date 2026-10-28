-- DASH-D1-02A — внедрение read-only API дашборда Катоны.
--
-- Среда: Supabase PostgreSQL 17.6; исполнитель — postgres без прав суперпользователя,
-- владелец схемы katona и её таблиц. Описание и обоснование — docs/dashboard/05_SQL_API_DESIGN.md.
--
-- Выполнять файл целиком одной командой (SQL Editor) или `psql -v ON_ERROR_STOP=1 -f`.
-- Всё выполняется в одной транзакции. Любая ошибка, включая встроенные проверки в конце,
-- прерывает транзакцию: не остаётся ни ролей, ни функций, ни прав. Если клиент после
-- ошибки оставил сессию открытой, выполнить ROLLBACK.
--
-- Пароля в файле нет: его задают отдельно (`\password katona_dashboard_api_login` в psql).
-- Существующие роли и права (katona_dashboard_read, katona_dashboard_admin, n8n, kb_v2_*)
-- скрипт не изменяет.

BEGIN;

-- 0. Предусловия -------------------------------------------------------------

DO $$
DECLARE
    v_missing text;
BEGIN
    IF current_setting('server_version_num')::int < 170000 THEN
        RAISE EXCEPTION 'dashboard_pre_version: нужен PostgreSQL 17, сейчас %', current_setting('server_version');
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles
                WHERE rolname IN ('katona_dashboard_owner', 'katona_dashboard_api_exec',
                                  'katona_dashboard_api_login')) THEN
        RAISE EXCEPTION 'dashboard_pre_roles_exist: роли дашборда уже существуют';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc
                WHERE pronamespace = 'katona'::regnamespace AND proname LIKE 'dashboard\_%') THEN
        RAISE EXCEPTION 'dashboard_pre_functions_exist: функции katona.dashboard_* уже существуют';
    END IF;

    -- Используемые столбцы и их типы (NULL — тип не проверяется, SQL приводит к text).
    SELECT string_agg(e.tbl || '.' || e.col, ', ') INTO v_missing
      FROM (VALUES ('dialogi', 'id', 'uuid'),
                   ('dialogi', 'polzovatel_id', 'uuid'),
                   ('dialogi', 'identifikator_kanala_id', 'uuid'),
                   ('dialogi', 'etap', 'text'),
                   ('dialogi', 'status', 'text'),
                   ('dialogi', 'rezultat', NULL),
                   ('dialogi', 'vremya_nachala', 'timestamp with time zone'),
                   ('identifikatory_kanalov', 'id', 'uuid'),
                   ('identifikatory_kanalov', 'kanal', 'text'),
                   ('celevye_sobytiya', 'dialog_id', 'uuid'),
                   ('celevye_sobytiya', 'kod_celi', NULL),
                   ('celevye_sobytiya', 'podtverzhdeno', 'boolean'),
                   ('polzovateli', 'id', 'uuid'),
                   ('polzovateli', 'testovyy', 'boolean'),
                   ('polzovateli', 'sluzhebnyy', 'boolean')) AS e(tbl, col, typ)
     WHERE NOT EXISTS (
             SELECT 1
               FROM pg_attribute a
               JOIN pg_class c ON c.oid = a.attrelid
              WHERE c.relnamespace = 'katona'::regnamespace
                AND c.relname = e.tbl
                AND a.attname = e.col
                AND a.attnum > 0 AND NOT a.attisdropped
                AND (e.typ IS NULL OR format_type(a.atttypid, a.atttypmod) = e.typ));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'dashboard_pre_columns: нет столбцов или другой тип: %', v_missing;
    END IF;

    -- Исполнитель должен владеть схемой и четырьмя таблицами (так в Supabase у postgres)
    -- либо иметь на них GRANT OPTION; для создания функций нужен CREATE на схеме.
    IF NOT (pg_has_role(current_user, (SELECT nspowner FROM pg_namespace WHERE nspname = 'katona'), 'USAGE')
            OR has_schema_privilege(current_user, 'katona', 'USAGE WITH GRANT OPTION'))
       OR NOT has_schema_privilege(current_user, 'katona', 'CREATE') THEN
        RAISE EXCEPTION 'dashboard_pre_ownership: % не владеет схемой katona или не имеет CREATE', current_user;
    END IF;

    SELECT string_agg(c.relname, ', ') INTO v_missing
      FROM pg_class c
     WHERE c.relnamespace = 'katona'::regnamespace
       AND c.relname IN ('dialogi', 'identifikatory_kanalov', 'celevye_sobytiya', 'polzovateli')
       AND NOT (pg_has_role(current_user, c.relowner, 'USAGE')
                OR has_table_privilege(current_user, c.oid, 'SELECT WITH GRANT OPTION'));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'dashboard_pre_ownership: нет права выдавать SELECT на таблицы: %', v_missing;
    END IF;
END
$$;

-- 1. Роли ---------------------------------------------------------------------

-- Владелец функций: читает только перечисленные ниже столбцы, войти не может.
CREATE ROLE katona_dashboard_owner NOLOGIN NOINHERIT;

-- Группа вызова API: USAGE на схему и EXECUTE только на 4 функции API.
CREATE ROLE katona_dashboard_api_exec NOLOGIN NOINHERIT;

-- Подключение сервера дашборда: наследует только katona_dashboard_api_exec.
CREATE ROLE katona_dashboard_api_login LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5
    IN ROLE katona_dashboard_api_exec;
ALTER ROLE katona_dashboard_api_login SET default_transaction_read_only = on;
ALTER ROLE katona_dashboard_api_login SET statement_timeout = '5s';
ALTER ROLE katona_dashboard_api_login SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE katona_dashboard_api_login SET search_path = pg_catalog;

-- Если в базе задан createrole_self_grant, PostgreSQL 17 выдаёт создателю членство с SET/INHERIT
-- в новых ролях. Снять его; служебный ADMIN OPTION создателя (без SET/INHERIT) остаётся.
REVOKE katona_dashboard_owner, katona_dashboard_api_exec, katona_dashboard_api_login FROM CURRENT_USER;

GRANT USAGE ON SCHEMA katona TO katona_dashboard_owner, katona_dashboard_api_exec;

-- Только столбцы без ПД: внешние идентификаторы каналов, имена, телефоны и тексты недоступны.
GRANT SELECT (id, polzovatel_id, identifikator_kanala_id, etap, status, rezultat, vremya_nachala)
   ON katona.dialogi TO katona_dashboard_owner;
GRANT SELECT (id, kanal)
   ON katona.identifikatory_kanalov TO katona_dashboard_owner;
GRANT SELECT (dialog_id, kod_celi, podtverzhdeno)
   ON katona.celevye_sobytiya TO katona_dashboard_owner;
GRANT SELECT (id, testovyy, sluzhebnyy)
   ON katona.polzovateli TO katona_dashboard_owner;

-- 2. Helper: период в Europe/Moscow --------------------------------------------

CREATE FUNCTION katona.dashboard_granicy(p_s date, p_po date)
RETURNS TABLE (nachalo timestamptz, konec timestamptz)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $fn$
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
$fn$;

-- 3. Helper: единая когорта ----------------------------------------------------

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
AS $fn$
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
$fn$;

-- 4. Функции API ---------------------------------------------------------------

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
AS $fn$
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
$fn$;

CREATE FUNCTION katona.dashboard_dinamika(p_s date, p_po date)
RETURNS TABLE (den date, novye_obrashcheniya bigint, dostigli_celi bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
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
$fn$;

CREATE FUNCTION katona.dashboard_etapy(p_s date, p_po date)
RETURNS TABLE (etap text, dialogov bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
    SELECT k.etap, count(DISTINCT k.dialog_id)
      FROM katona.dashboard_granicy(p_s, p_po) g
     CROSS JOIN LATERAL katona.dashboard_kogorta(g.nachalo, g.konec) k
     WHERE NOT k.isklyuchen
     GROUP BY k.etap
     ORDER BY 2 DESC, 1
$fn$;

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
AS $fn$
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
$fn$;

-- 5. Права на функции ----------------------------------------------------------
-- Выставляются, пока владелец — исполнитель скрипта; ALTER ... OWNER переносит ACL на нового владельца.

REVOKE ALL ON FUNCTION
    katona.dashboard_granicy(date, date),
    katona.dashboard_kogorta(timestamptz, timestamptz),
    katona.dashboard_obzor(date, date),
    katona.dashboard_dinamika(date, date),
    katona.dashboard_etapy(date, date),
    katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    katona.dashboard_obzor(date, date),
    katona.dashboard_dinamika(date, date),
    katona.dashboard_etapy(date, date),
    katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid)
  TO katona_dashboard_api_exec;

-- Снять EXECUTE, выданный ролям через default privileges (anon, authenticated, service_role и др.).
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
           AND a.grantee NOT IN (p.proowner, 'katona_dashboard_api_exec'::regrole)
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', r.fn, pg_get_userbyid(r.grantee));
    END LOOP;
END
$$;

-- 6. Смена владельца -----------------------------------------------------------
-- PostgreSQL 17: исполнителю нужно право SET ROLE на нового владельца, владельцу — CREATE на схеме.
-- Оба права временные и снимаются здесь же.

GRANT katona_dashboard_owner TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
GRANT CREATE ON SCHEMA katona TO katona_dashboard_owner;

ALTER FUNCTION katona.dashboard_granicy(date, date)               OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_kogorta(timestamptz, timestamptz) OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_obzor(date, date)                 OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_dinamika(date, date)              OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_etapy(date, date)                 OWNER TO katona_dashboard_owner;
ALTER FUNCTION katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid)
                                                                   OWNER TO katona_dashboard_owner;

REVOKE CREATE ON SCHEMA katona FROM katona_dashboard_owner;
REVOKE katona_dashboard_owner FROM CURRENT_USER;

-- 7. Встроенные проверки: любое нарушение откатывает всю транзакцию -----------------

DO $$
DECLARE
    v_owner oid    := 'katona_dashboard_owner'::regrole;
    v_exec  oid    := 'katona_dashboard_api_exec'::regrole;
    v_login oid    := 'katona_dashboard_api_login'::regrole;
    v_me    oid    := (SELECT oid FROM pg_roles WHERE rolname = current_user);
    v_api   name[] := ARRAY['dashboard_obzor', 'dashboard_dinamika',
                            'dashboard_etapy', 'dashboard_poslednie']::name[];
    v_n     bigint;
BEGIN
    -- Функции: ровно 6, владелец, STABLE, search_path, явный ACL; SECURITY DEFINER только у 4 API.
    SELECT count(*) INTO v_n
      FROM pg_proc p
     WHERE p.pronamespace = 'katona'::regnamespace
       AND p.proname LIKE 'dashboard\_%';
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'dashboard_check_function_count: %', v_n;
    END IF;

    SELECT count(*) INTO v_n
      FROM pg_proc p
     WHERE p.pronamespace = 'katona'::regnamespace
       AND p.proname LIKE 'dashboard\_%'
       AND p.proowner = v_owner
       AND p.provolatile = 's'
       AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']
       AND p.proacl IS NOT NULL
       AND p.prosecdef = (p.proname = ANY (v_api));
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'dashboard_check_functions: % of 6', v_n;
    END IF;

    -- ACL функций: только владелец и katona_dashboard_api_exec (EXECUTE на 4 API, без GRANT OPTION).
    SELECT count(*) INTO v_n
      FROM pg_proc p
     CROSS JOIN LATERAL aclexplode(p.proacl) a
     WHERE p.pronamespace = 'katona'::regnamespace
       AND p.proname LIKE 'dashboard\_%'
       AND NOT (a.grantee = v_owner
                OR (a.grantee = v_exec AND p.proname = ANY (v_api)
                    AND a.privilege_type = 'EXECUTE' AND NOT a.is_grantable));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'dashboard_check_function_acl: % лишних записей', v_n;
    END IF;

    -- LOGIN-роль вызывает в katona ровно 4 функции API — не audit_dashboard_summary и не helpers.
    SELECT count(*) INTO v_n
      FROM pg_proc p
     WHERE p.pronamespace = 'katona'::regnamespace
       AND has_function_privilege(v_login, p.oid, 'EXECUTE');
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'dashboard_check_login_functions: % вместо 4', v_n;
    END IF;
    IF to_regprocedure('katona.audit_dashboard_summary()') IS NOT NULL
       AND has_function_privilege(v_login, 'katona.audit_dashboard_summary()', 'EXECUTE') THEN
        RAISE EXCEPTION 'dashboard_check_login_audit_summary';
    END IF;

    -- LOGIN-роль и группа API: никаких прав на таблицы и столбцы katona, нет CREATE на схеме.
    SELECT count(*) INTO v_n
      FROM pg_class c
     CROSS JOIN (VALUES (v_login), (v_exec)) AS r(rid)
     WHERE c.relnamespace = 'katona'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND (has_table_privilege(r.rid, c.oid,
                'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
            OR has_any_column_privilege(r.rid, c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'dashboard_check_login_tables: %', v_n;
    END IF;

    -- Владелец: никаких прав на уровне таблиц; SELECT ровно на 15 столбцов; ничего на запись.
    SELECT count(*) INTO v_n
      FROM pg_class c
     WHERE c.relnamespace = 'katona'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND (has_table_privilege(v_owner, c.oid,
                'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN')
            OR has_any_column_privilege(v_owner, c.oid, 'INSERT, UPDATE, REFERENCES'));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'dashboard_check_owner_tables: %', v_n;
    END IF;

    SELECT count(*) INTO v_n
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relnamespace = 'katona'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND a.attnum > 0 AND NOT a.attisdropped
       AND has_column_privilege(v_owner, c.oid, a.attnum, 'SELECT');
    IF v_n <> 15 THEN
        RAISE EXCEPTION 'dashboard_check_owner_columns: % of 15', v_n;
    END IF;

    IF has_schema_privilege(v_owner, 'katona', 'CREATE')
       OR has_schema_privilege(v_exec, 'katona', 'CREATE')
       OR has_schema_privilege(v_login, 'katona', 'CREATE')
       OR NOT has_schema_privilege(v_exec, 'katona', 'USAGE') THEN
        RAISE EXCEPTION 'dashboard_check_schema_privileges';
    END IF;

    -- Членство: owner и api_exec ни в чём не состоят; LOGIN входит только в api_exec;
    -- в три новые роли, кроме LOGIN в api_exec, допустим только исполнитель с ADMIN OPTION
    -- без SET/INHERIT (PostgreSQL 17 сам выдаёт его создателю роли).
    IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member IN (v_owner, v_exec)) THEN
        RAISE EXCEPTION 'dashboard_check_membership_nested';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_auth_members m
                WHERE m.member = v_login AND m.roleid <> v_exec)
       OR NOT EXISTS (SELECT 1 FROM pg_auth_members m
                       WHERE m.member = v_login AND m.roleid = v_exec
                         AND m.inherit_option AND NOT m.admin_option) THEN
        RAISE EXCEPTION 'dashboard_check_membership_login';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_auth_members m
                WHERE m.roleid IN (v_owner, v_exec, v_login)
                  AND NOT (m.roleid = v_exec AND m.member = v_login)
                  AND NOT (m.member = v_me AND NOT m.inherit_option AND NOT m.set_option)) THEN
        RAISE EXCEPTION 'dashboard_check_membership_members';
    END IF;

    -- Атрибуты ролей.
    IF EXISTS (SELECT 1 FROM pg_roles r
                WHERE r.oid IN (v_owner, v_exec)
                  AND (r.rolcanlogin OR r.rolsuper OR r.rolcreaterole OR r.rolcreatedb
                       OR r.rolreplication OR r.rolbypassrls))
       OR NOT EXISTS (SELECT 1 FROM pg_roles r
                       WHERE r.oid = v_login
                         AND r.rolcanlogin AND r.rolinherit AND r.rolconnlimit = 5
                         AND NOT (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb
                                  OR r.rolreplication OR r.rolbypassrls)) THEN
        RAISE EXCEPTION 'dashboard_check_role_attributes';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_db_role_setting s
                    WHERE s.setrole = v_login AND s.setdatabase = 0
                      AND s.setconfig @> ARRAY['default_transaction_read_only=on',
                                               'statement_timeout=5s',
                                               'idle_in_transaction_session_timeout=15s',
                                               'search_path=pg_catalog']) THEN
        RAISE EXCEPTION 'dashboard_check_login_settings';
    END IF;
END
$$;

COMMIT;
