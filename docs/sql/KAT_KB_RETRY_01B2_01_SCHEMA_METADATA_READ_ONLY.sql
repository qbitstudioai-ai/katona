-- KAT-KB-RETRY-01B2 / Проверка 1: ТОЛЬКО ЧТЕНИЕ метаданных katona.
-- Supabase SQL Editor: выполните весь запрос целиком; результат НЕ публиковать в открытом GitHub.
-- Нет вызовов пользовательских функций, нет INSERT/UPDATE/DELETE/DDL, нет чтения содержимого файлов.
-- Используются только системные каталоги PostgreSQL и безопасные функции описания.
WITH target_tables AS (
    SELECT c.oid, c.relname, c.relkind, c.relrowsecurity
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'katona'
      AND c.relkind IN ('r','p')
      AND c.relname LIKE ANY (
        ARRAY['%znani%', '%fragment%', '%vopros%', '%proverk%',
              '%profil%', '%zagruzk%', '%zadani%']
      )
),
report AS (
    SELECT
        '01_table'::text AS section,
        t.relname::text AS object_name,
        jsonb_build_object(
            'kind', t.relkind::text,
            'rls', t.relrowsecurity,
            'size_bytes', pg_catalog.pg_total_relation_size(t.oid)
        ) AS details
    FROM target_tables AS t

    UNION ALL

    SELECT
        '02_column',
        (t.relname || '.' || a.attname)::text,
        jsonb_build_object(
            'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
            'not_null', a.attnotnull,
            'identity', a.attidentity::text,
            'generated', a.attgenerated::text,
            'default', pg_catalog.pg_get_expr(ad.adbin, a.attrelid)
        )
    FROM target_tables AS t
    JOIN pg_catalog.pg_attribute AS a
      ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_catalog.pg_attrdef AS ad
      ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum

    UNION ALL

    SELECT
        '03_constraint',
        (s.relname || '.' || con.conname)::text,
        jsonb_build_object(
            'kind', con.contype::text,
            'references_table', r.relname,
            'definition', pg_catalog.pg_get_constraintdef(con.oid)
        )
    FROM pg_catalog.pg_constraint AS con
    JOIN pg_catalog.pg_class AS s ON s.oid = con.conrelid
    JOIN pg_catalog.pg_namespace AS ns ON ns.oid = s.relnamespace
    LEFT JOIN pg_catalog.pg_class AS r ON r.oid = con.confrelid
    WHERE ns.nspname = 'katona'
      AND (
        con.conrelid IN (SELECT oid FROM target_tables)
        OR con.confrelid IN (SELECT oid FROM target_tables)
      )

    UNION ALL

    SELECT
        '04_index',
        (t.relname || '.' || ix.relname)::text,
        jsonb_build_object(
            'unique', i.indisunique,
            'valid', i.indisvalid,
            'definition', pg_catalog.pg_get_indexdef(i.indexrelid)
        )
    FROM target_tables AS t
    JOIN pg_catalog.pg_index AS i ON i.indrelid = t.oid
    JOIN pg_catalog.pg_class AS ix ON ix.oid = i.indexrelid

    UNION ALL

    SELECT
        '05_trigger',
        (t.relname || '.' || tr.tgname)::text,
        jsonb_build_object(
            'enabled', tr.tgenabled::text,
            'definition', pg_catalog.pg_get_triggerdef(tr.oid, true)
        )
    FROM target_tables AS t
    JOIN pg_catalog.pg_trigger AS tr
      ON tr.tgrelid = t.oid AND NOT tr.tgisinternal

    UNION ALL

    SELECT
        '06_function_signature',
        (p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')')::text,
        jsonb_build_object(
            'result', pg_catalog.pg_get_function_result(p.oid),
            'security_definer', p.prosecdef,
            'owner', pg_catalog.pg_get_userbyid(p.proowner),
            'service_role_can_execute',
              pg_catalog.has_function_privilege('katona_n8n_service_login', p.oid, 'EXECUTE'),
            'body_length', length(pg_catalog.pg_get_functiondef(p.oid))
        )
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'katona'
      AND p.proname IN (
          'zaregistrirovat_zagruzku_znaniy',
          'zabrat_zadanie_znaniy',
          'zavershit_zadanie_znaniy',
          'podgotovit_versiyu_znaniy',
          'sohranit_fragmenty_znaniy',
          'sohranit_kontrolnye_voprosy',
          'poluchit_kontrolnye_voprosy_znaniy',
          'poisk_chernovika_znaniy',
          'sohranit_proverki_znaniy',
          'opublikovat_versiyu_znaniy'
      )
)
SELECT section, object_name, details
FROM report
ORDER BY section, object_name;
