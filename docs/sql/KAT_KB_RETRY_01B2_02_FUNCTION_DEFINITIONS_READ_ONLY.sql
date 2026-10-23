-- KAT-KB-RETRY-01B2 / Проверка 2: ТОЛЬКО ЧТЕНИЕ тел 10 функций katona.
-- Запускать ПОСЛЕ проверки 1. pg_get_functiondef не исполняет функции.
-- НЕ копируйте реальные логины/токены/UUID/персональные данные в публичный GitHub.
-- Перед передачей отчёта в чат проверьте, нет ли секретов внутри определения.
SELECT
    p.proname AS function_name,
    pg_catalog.pg_get_function_identity_arguments(p.oid) AS arguments,
    pg_catalog.pg_get_functiondef(p.oid) AS function_definition
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
ORDER BY p.proname, arguments;
