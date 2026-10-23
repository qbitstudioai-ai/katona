# KAT-KB-RETRY-01B2 — read-only проверка Supabase и n8n

**Начато:** 23.10.2026. **Статус:** 🔄 в работе; ожидаем фактические результаты из рабочего Supabase и n8n.
**Задача:** проверить реальные ограничения базы знаний, SQL-функции, прошлые зависания и фактическое хранение документов. **Никаких изменений** в n8n, Supabase, сервере, расписаниях и файлах.
**Основа:** [дизайн B1](09_KB_ONE_ATTEMPT_PLAN.md), [PLAN](../PLAN.md), [handoff](08_SESSION_HANDOFF.md), обезличенный служебный Workflow из `workflows/current/`.

## 1. Что удалось проверить из GitHub

- Текущий репозиторный снимок содержит 108 узлов, включая загрузку Telegram, вызов регистрации с передачей bytes и worker.
- Прямых вызовов функций `katona` в KB-ветках — 10 разных имён (перечислены в SQL №2).
- Три KB-узла имеют `retryOnFail=true`: embeddings фрагментов, embeddings вопросов и публикация.
- Много веток вызывают `zavershit_zadanie_znaniy` со статусом `povtor`.
- Встроенный `KB-01A Запустить обработку знаний?` запускает worker после новой регистрации, не зависит от расписания.
- В настройках JSON есть `binaryMode: separate`. Это **не** доказательство того, где н8n реально хранит execution/binary и сколько времени.
- SQL-контракт из GitHub и предыдущий отчёт пользователя говорят о `zagruzki_znaniy.ishodnyy_fayl bytea NOT NULL`, но актуальные живые функции/ограничения в этом этапе пока не получены.
- Остановка первого worker и точная причина `dokument_zanyat` по живым SQL-функциям **не установлены**; отменённые TEST-файлы ранее не удалялись.

## 2. SQL — выполнить в Supabase SQL Editor только для чтения

Все три файла содержат **только SELECT** по системным каталогам или агрегированным данным. Не вводите пароль, не меняйте функции и не применяйте миграции.

1. **Сначала** [01_SCHEMA_METADATA_READ_ONLY.sql](sql/KAT_KB_RETRY_01B2_01_SCHEMA_METADATA_READ_ONLY.sql) — структура связанных таблиц, поля, NOT NULL, ограничения, FK, индексы, триггеры, список 10 функций и права служебного логина.
2. [02_FUNCTION_DEFINITIONS_READ_ONLY.sql](sql/KAT_KB_RETRY_01B2_02_FUNCTION_DEFINITIONS_READ_ONLY.sql) — тела 10 актуальных функций для доказательства блокировки/аренды, переходов job и гарантий публикации. `pg_get_functiondef` **только отображает** текст и ничего не исполняет. Перед отправкой результата проверьте, нет ли реальных секретов/персональных данных; не публикуйте сырой результат в публичный GitHub.
3. [03_ORIGINAL_BYTES_COUNTS_READ_ONLY.sql](sql/KAT_KB_RETRY_01B2_03_ORIGINAL_BYTES_COUNTS_READ_ONLY.sql) — число загрузок со старым исходником и общий размер bytes по статусам, **без исходных данных**. Запускать только после подтверждения названий полей в №1.

**Передать отчёты:** результат 01 файлом CSV/JSON, результат 02 файлом после проверки на секреты, результат 03 как таблицу. Если SQL возвращает ошибку, прислать **только текст ошибки**; не пытаться исправлять таблицу/функции самостоятельно.

## 3. n8n — только посмотреть, ничего не переключать

В рабочем служебном Workflow открыть меню **⋯ → Settings**. Записать текущие значения:
- Save successful production executions;
- Save failed production executions;
- Save manual executions;
- Save execution progress;
- Timeout Workflow;
- Error Workflow;
- если доступны — Redact production/manual execution data.

В интерфейсе **Executions** для последних проблемных KB-выполнений (если сохранены) проверить только дату, состояние, длительность, название последнего узла/узла ошибки, наличие `Running`/`Waiting`. **Не присылать содержимое файла, полные outputs, токены, Telegram ID и webhook.** Также **посмотреть**, что узел «Проверять очередь знаний каждые 5 минут» действительно выключен в опубликованной версии, **не нажимать Toggle/Publish**.

Если доступны только для чтения действующие настройки хостинга (переменные среды), записать без паролей:
- `EXECUTIONS_MODE`, `EXECUTIONS_TIMEOUT`, `EXECUTIONS_TIMEOUT_MAX`;
- `EXECUTIONS_DATA_SAVE_ON_SUCCESS`, `EXECUTIONS_DATA_SAVE_ON_ERROR`, `EXECUTIONS_DATA_SAVE_ON_PROGRESS`, `EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS`;
- `EXECUTIONS_DATA_PRUNE`, `EXECUTIONS_DATA_MAX_AGE`, `EXECUTIONS_DATA_PRUNE_MAX_COUNT`, `EXECUTIONS_DATA_HARD_DELETE_BUFFER`;
- `N8N_EXECUTION_DATA_STORAGE_MODE`, `N8N_DEFAULT_BINARY_DATA_MODE`, `N8N_AVAILABLE_BINARY_DATA_MODES`;
- доступность `N8N_BINARY_DATA_STORAGE_PATH` — достаточно «задан/не задан», **без самого пути**.

Также сообщить версию n8n, есть ли workers в queue mode, известный срок хранения backup и логов, и доступен ли технический путь очистки временных binary **без запуска очистки**. Если настройки недоступны — отметить `неизвестно`, сервер не трогать.

**Документация n8n для сверки (актуальный интерфейс может зависеть от версии):**
- [Workflow settings](https://docs.n8n.io/build/manage-workflows/configure-workflow-settings.md)
- [Execution settings](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/executions.md)
- [Binary data settings](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/binary-data.md)
- [Data pruning](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/manage-execution-data.md)

**Причина отдельной проверки:** типовое удаление н8n работает с завершёнными executions и не обязано очищать running/waiting; хранение бинарных данных зависит от активного режима. Ни один переключатель в UI не является доказательством отсутствия копий у провайдеров и в резервных копиях.

## 4. Критерии завершения B2

- [ ] Отчёт 01 получен, разобраны NOT NULL, связи, индексы и триггеры всех задействованных таблиц.
- [ ] Отчёт 02 получен, проверены тела 10 функций и при необходимости их дополнительные вызовы: дедупликация, `dokument_zanyat`, истечение аренды, `povtor`, проверка owner/token и активной версии.
- [ ] Отчёт 03 получен, известно, остались ли bytes неудачных TEST-загрузок (агрегатные данные; без удаления).
- [ ] Реальные настройки n8n/retention/timeout/backup и статус расписания просмотрены, отмечено, что проверено, а что пока неизвестно.
- [ ] Подготовлено точное сопоставление «старая таблица/функция → безопасная замена», порядок миграции и условия rollback для B3 (только проект).
- [ ] Никаких изменений живых компонентов не выполнялось.

**Следующий шаг после отчётов:** дополнить этот документ доказанными фактами и закрыть B2. Перейти к B3 **только после отдельного разрешения**.

