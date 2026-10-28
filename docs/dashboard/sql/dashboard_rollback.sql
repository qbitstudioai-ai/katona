-- DASH-D1-02A — откат read-only API дашборда Катоны.
--
-- Удаляет только объекты из dashboard_deploy.sql: 6 функций katona.dashboard_* и роли
-- katona_dashboard_api_login, katona_dashboard_api_exec, katona_dashboard_owner.
-- Ранее существовавшие роли и права (katona_dashboard_read, katona_dashboard_admin, n8n,
-- kb_v2_*, USAGE katona_dashboard_read на схему) не изменяет.
--
-- Можно запускать повторно и когда внедрения не было. Выполнять целиком одной командой
-- (SQL Editor) или `psql -v ON_ERROR_STOP=1 -f`; при ошибке не меняется ничего.

BEGIN;

-- Удалить функции может их владелец или владелец схемы katona. Если исполнитель не владеет
-- схемой, ему временно нужны права роли-владельца; членство исчезает вместе с ролью.
DO $$
BEGIN
    IF to_regrole('katona_dashboard_owner') IS NOT NULL THEN
        GRANT katona_dashboard_owner TO CURRENT_USER WITH INHERIT TRUE, SET TRUE;
    END IF;
END
$$;

DROP FUNCTION IF EXISTS
    katona.dashboard_poslednie(date, date, integer, text, timestamptz, uuid),
    katona.dashboard_etapy(date, date),
    katona.dashboard_dinamika(date, date),
    katona.dashboard_obzor(date, date),
    katona.dashboard_kogorta(timestamptz, timestamptz),
    katona.dashboard_granicy(date, date);

DROP ROLE IF EXISTS katona_dashboard_api_login;

DO $$
BEGIN
    IF to_regrole('katona_dashboard_api_exec') IS NOT NULL THEN
        REVOKE ALL ON SCHEMA katona FROM katona_dashboard_api_exec;
    END IF;
    IF to_regrole('katona_dashboard_owner') IS NOT NULL THEN
        -- Снимаются ровно права по столбцам из dashboard_deploy.sql. REVOKE ALL на таблицу не
        -- используется: он превратил бы неявный ACL таблицы (NULL) в явный.
        REVOKE SELECT (id, polzovatel_id, identifikator_kanala_id, etap, status, rezultat, vremya_nachala)
            ON katona.dialogi FROM katona_dashboard_owner;
        REVOKE SELECT (id, kanal)
            ON katona.identifikatory_kanalov FROM katona_dashboard_owner;
        REVOKE SELECT (dialog_id, kod_celi, podtverzhdeno)
            ON katona.celevye_sobytiya FROM katona_dashboard_owner;
        REVOKE SELECT (id, testovyy, sluzhebnyy)
            ON katona.polzovateli FROM katona_dashboard_owner;
        REVOKE ALL ON SCHEMA katona FROM katona_dashboard_owner;
    END IF;
END
$$;

DROP ROLE IF EXISTS katona_dashboard_api_exec;
DROP ROLE IF EXISTS katona_dashboard_owner;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles
                WHERE rolname IN ('katona_dashboard_owner', 'katona_dashboard_api_exec',
                                  'katona_dashboard_api_login'))
       OR EXISTS (SELECT 1 FROM pg_proc
                   WHERE pronamespace = 'katona'::regnamespace AND proname LIKE 'dashboard\_%') THEN
        RAISE EXCEPTION 'dashboard_rollback_incomplete';
    END IF;
END
$$;

COMMIT;
