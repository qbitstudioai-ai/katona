-- KAT-KB-RETRY-01B2 / Проверка 3: статистика хранимых исходников, без чтения их содержимого.
-- Запускать после проверки 1, если там подтверждены поля:
-- katona.zagruzki_znaniy.status и katona.zagruzki_znaniy.ishodnyy_fayl (bytea).
-- Не выводит имена файлов, UUID, содержимое Markdown или персональные данные.
SELECT
    status::text AS upload_status,
    count(*) AS upload_count,
    count(*) FILTER (WHERE ishodnyy_fayl IS NOT NULL) AS uploads_with_original_bytes,
    coalesce(sum(octet_length(ishodnyy_fayl)), 0) AS total_original_bytes
FROM katona.zagruzki_znaniy
GROUP BY status
ORDER BY upload_status;
