# KAT-KB-RETRY-01B2 — read-only проверка Supabase и n8n

**Начато:** 23.10.2026. **Статус:** 🔄 в работе; ✅ SQL №1, №2, №3 получены и проверены; ожидаем фактические настройки n8n и завершающую оценку рисков.
**Задача:** проверить реальные ограничения базы знаний, SQL-функции, прошлые зависания и фактическое хранение документов. **Никаких изменений** в n8n, Supabase, сервере, расписаниях и файлах.
**Основа:** [дизайн B1](09_KB_ONE_ATTEMPT_PLAN.md), [PLAN](../PLAN.md), [handoff](08_SESSION_HANDOFF.md), обезличенный служебный Workflow из `workflows/current/`.

## 1. Что удалось проверить из GitHub

- Текущий репозиторный снимок содержит 108 узлов, включая загрузку Telegram, вызов регистрации с передачей bytes и worker.
- Прямых вызовов функций `katona` в KB-ветках — 10 разных имён (перечислены в SQL №2).
- Три KB-узла имеют `retryOnFail=true`: embeddings фрагментов, embeddings вопросов и публикация.
- Много веток вызывают `zavershit_zadanie_znaniy` со статусом `povtor`.
- Встроенный `KB-01A Запустить обработку знаний?` запускает worker после новой регистрации, не зависит от расписания.
- В настройках JSON есть `binaryMode: separate`. Это **не** доказательство того, где н8n реально хранит execution/binary и сколько времени.
- **SQL №1 и №2 подтверждены ответами пользователя:** `zagruzki_znaniy.ishodnyy_fayl bytea NOT NULL`, `zabrat_zadanie_znaniy` возвращает `ishodnyy_fayl bytea`. Получены полные определения 10 KB-функций. Реальные данные/настройки хранения пока не получены.
- Установлен точный механизм `dokument_zanyat` в `podgotovit_versiyu_znaniy`: наличие другого job `v_rabote` без учёта истечения аренды; автоматически ставится `povtor` через 30 секунд. Но **причина первой остановки n8n-worker по-прежнему не установлена**; отменённые TEST-файлы ранее не удалялись.

## 1A. Полученный отчёт SQL №1 — результат анализа 23.10.2026

Источник: ответ Supabase SQL Editor, переданный пользователем файлом в чат; проверен JSON из **245 строк**: 9 таблиц, 117 столбцов, 71 ограничение, 35 индексов, 3 триггера, 10 сигнатур функций. Это **метаданные**, не доказательство физического наличия/удаления байтов. SQL №2 и №3 также получены позже.

**Подтверждено:**
- `katona.zagruzki_znaniy.ishodnyy_fayl` имеет тип `bytea NOT NULL` без значения по умолчанию. При текущей структуре `UPDATE ... SET ishodnyy_fayl=NULL` невозможен; такое действие **не предлагается выполнять**. Регистрация вызывает `zaregistrirovat_zagruzku_znaniy(p_dannye jsonb, p_fayl bytea)`, выдача worker — `zabrat_zadanie_znaniy(p_dannye jsonb)`, в результатах которой есть `ishodnyy_fayl bytea`.
- `katona.zadaniya_znaniy`: статусы `ozhidaet`, `v_rabote`, `povtor`, `zaversheno`, `otmeneno`, `oshibka`. Уникальный частичный индекс `zadaniya_znaniy_dokument_id_idx` защищает `dokument_id` при `status='v_rabote'`, но **не проверяет `arenda_do`**. Поэтому истёкшая аренда сама по себе не снимает блокировку активного состояния; точный `dokument_zanyat` в теле функции проверить SQL №2.
- `katona.zagruzki_znaniy`: статусы `poluchena`, `proverka`, `obrabotka`, `ozhidaet_proverki`, `zavershena`, `dublikat`, `oshibka`; отдельного статуса `otmeneno` нет. Уникальный индекс по `sobytie_integracii_id` защищает от части дублей, но фактическую логику дедупликации выяснить в SQL №2.
- `katona.dokumenty_znaniy.aktivnaya_versiya_id` связан с `versii_dokumentov_znaniy` откладываемым FK; на активную версию есть отложенный ограничивающий триггер `ct_dokumenty_aktivnaya_versiya`. Нужно сохранить защиту публикации.
- `fragmenty_znaniy` содержит `tekst_fragmenta text NOT NULL` и `vektor vector(1024) NOT NULL`; зависимость по `versiya_id` имеет `ON DELETE CASCADE`. Вопросы и проверки также связаны с версиями; удаление неопубликованного черновика потенциально удаляет их, но **прямых удалений пока не планировать**.
- Записи об исходной загрузке связаны с другими объектами: `zadaniya_znaniy`, `versii_dokumentov_znaniy`, `ishodyashchie_deystviya` (FK на `zagruzki_znaniy`). Простое удаление загрузки может нарушить связи/аудит; для нового пути предпочтительна схема «минимум метаданных, без хранения bytes».
- Триггеры: `audit_kb_notice` после UPDATE загрузок, `ct_dokumenty_aktivnaya_versiya` при обновлении active pointer, `tr_profili_immutable` запрещает изменение/удаление профиля. Перед B3 проверить тела этих триггерных функций и побочные эффекты.
- Все 10 прямых KB-функций — `SECURITY DEFINER`, владелец `postgres`; `katona_n8n_service_login` имеет EXECUTE на них. Это **не доказывает** корректность внутренних проверок аренды/статуса и необходимость расширения прав.

**Не подтверждено:** первопричина обрыва n8n-worker; фактические настройки n8n и политика резервных копий; окончательная физическая очистка ранее сохранённых копий; отсутствие публикации по иным документам.

**Ближайшее действие:** посмотреть настройки сохранения выполнений служебного Workflow в n8n (read-only, скриншот без токенов), затем уточнить бинарное хранение/резервные копии. Не менять таблицы, задания, функции и расписание.

## 1B. Полученный отчёт SQL №2 — проверка 10 живых функций

Источник: результат Supabase SQL Editor, присланный пользователем файлом в чат; 10 определений функций. **В репозиторий тела функций и тестовые SQL не публикуются.**

**Доказано:**
1. `zaregistrirovat_zagruzku_znaniy` действительно записывает исходные bytes в `zagruzki_znaniy.ishodnyy_fayl`, затем ставит job в `ozhidaet`; дубль уже зарегистрированного события сам по себе вторую DB-загрузку не создаёт.
2. `zabrat_zadanie_znaniy` выбирает job со статусом `povtor` **и** автоматически повторно выдаёт `v_rabote` с истёкшим `arenda_do`; при каждой выдаче растёт `popytki`, лимит старой логики — до 5 попыток. Значит выключенный Schedule Trigger не убирает автоповтор на уровне SQL/других вызовов.
3. `podgotovit_versiyu_znaniy` для конкурирующего `v_rabote` проверяет статус, **не** проверяет истечение `arenda_do`, отвечает `dokument_zanyat` и переводит текущий job в `povtor` через 30 секунд. Это точный механизм наблюдавшейся логической блокировки, но **не** первопричина первой остановки исполнения n8n.
4. `zavershit_zadanie_znaniy` принимает `povtor`, а при `oshibka` меняет только status/error загрузки, **не удаляет** исходные bytes.
5. **Критично:** `opublikovat_versiyu_znaniy` защищает ожидаемый active pointer, наличие фрагментов/проверок и состояние версии `gotova`, но **не проверяет актуальный job, его владельца/аренду/токен и не запрещает публикацию после отмены job**. Поздний worker при готовой версии потенциально может опубликовать результат; это стоп-фактор для перехода в production без изменения контракта.
6. `sohranit_kontrolnye_voprosy` и `sohranit_proverki_znaniy` разрешают изменение черновика без проверки актуальной аренды/fencing job. Переход черновика в `gotova` также должен быть защищён.
7. `sohranit_fragmenty_znaniy` и `poluchit_kontrolnye_voprosy_znaniy` проверяют текущую аренду. Это полезная защита, но её недостаточно для всей цепочки.
8. Для B3 нужно предусмотреть безопасную очистку failed bytes/неопубликованной версии и независимые уведомления, сохраняя активную версию и связи FK/триггеров.

**Ожидаем:** read-only настройки хранения n8n, при необходимости определения 3 триггерных функций и функции аудита; всё только после уточнения, без вмешательства в рабочую систему.

## 1C. Полученный отчёт SQL №3 — текущие исходные bytes

Источник: агрегат SQL Editor, присланный пользователем в чат. Единственная возвращённая группа: `status='oshibka'`, `gruppa='отмененные_тесты'`, `kolichestvo_zagruzok=2`, `faylov_v_baze=2`, `obshchiy_razmer_bayt=8944`.

**Подтверждено:** в двух ранее отменённых TEST-загрузках продолжает храниться исходное содержимое, в сумме **8 944 байта**. SQL №3 выполнял только SELECT и не удалял данные. Иных групп в результате нет — в рамках данного запроса другие сохранённые загрузки не обнаружены.

**Для проекта B3:** отмена меняет статусы, но не очищает `ishodnyy_fayl`. Простая подстановка `NULL` нарушит действующий NOT NULL. Удаление целой загрузки требует анализа FK, связанных jobs/версий и событий; потребуется отдельный согласованный проект очистки со страховкой от затрагивания активных знаний. Исторические bytes не удалять без отдельного разрешения.

## 2. SQL-диагностика: запросы в личном чате, НЕ в GitHub

По указанию пользователя **удалены из текущей ветки GitHub 3 временных SQL-файла B2**; тестовые SQL дальше предоставляются только в чате для ручного выполнения в Supabase SQL Editor. Здесь храним лишь подтверждённые результаты и очередность: №1 (структура) ✅, №2 (10 функций) ✅, №3 (агрегаты исходных bytes) ✅. Результаты функции SQL №2 не копировать в публичный репозиторий.

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

## 3A. Результат осмотра Workflow Settings в живом n8n

Источник: скриншот настроек служебного Workflow, предоставленный пользователем. Это **фактические значения, видимые в UI**, но режим `Default` может наследовать серверные настройки.

| Параметр | На скриншоте | Оценка |
| --- | --- | --- |
| Execution Logic | `v1 (recommended)` | Зафиксировано |
| Error Workflow | `- No Workflow -` | Отдельного общего обработчика ошибок нет |
| Timezone | `Default - Europe/Moscow` | Зафиксировано |
| Save failed production executions | `Default - Save` | Неудачные выполнений настроены на сохранение |
| Save successful production executions | `Default - Save` | Успешные выполнений настроены на сохранение |
| Save manual executions | `Default - Save` | Ручные выполнения настроены на сохранение |
| Save execution progress | `Default - Do not save` | Промежуточный прогресс отдельно не сохраняется этим параметром |
| Redact production execution data | `Default - Do not redact`, заблокировано (Upgrade) | Содержимое не скрывается данной опцией |
| Redact manual execution data | `Default - Do not redact`, заблокировано (Upgrade) | Аналогично |
| Timeout Workflow | Переключатель выключен | Локальное ограничение времени не включено |
| Available in MCP | Выключено | Для KB несущественно |

**Риск подтверждён настройками:** история завершённых выполнений может сохранять Markdown/base64, так как текущий Workflow формирует `kb01a_base64` и история настроена на Save. **Само фактическое местоположение и наличие конкретных bytes в n8n пока не проверены**: режим binary, глобальные сроки удаления, worker/queue, retention/backup остаются неизвестными.

**Новый отчёт об установке (пользователь, только чтение):** n8n **2.41.0**, на сервере Docker-контейнеры `n8n` с образом `n8nio/n8n:2.41.0` и `n8n-postgres` с образом `postgres:17-alpine`. Системной службы `n8n` и локального бинарника `n8n` на хосте нет. Это **подтверждает Docker**, но сам по себе вывод не подтверждает использование Docker Compose.

**Фактический Docker Compose / переменные среды:** пользователь выполнил `docker inspect n8n`: запуск **Docker Compose** подтверждён лейблом. Для всех 15 проверенных параметров (`EXECUTIONS_MODE`, таймауты, сохранение success/error/manual/progress, prune, age, max count, delete buffer, execution/binary mode и пути) получено **«не задано»**. Это значит, что явных override этих имён в `.Config.Env` нет; фактическое наличие исторических данных этим запросом **не проверяется**. Пароли/пути в вывод не попали.

**Значения из официальной текущей документации n8n (проверить совместимость с 2.41.0 при необходимости):** `EXECUTIONS_MODE=regular`, `EXECUTIONS_DATA_SAVE_ON_SUCCESS=all`, `EXECUTIONS_DATA_SAVE_ON_ERROR=all`, `EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=true`, `EXECUTIONS_DATA_SAVE_ON_PROGRESS=false`, `EXECUTIONS_TIMEOUT=-1`, `N8N_EXECUTION_DATA_STORAGE_MODE=database`, `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=336 часов`, `EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000`, `N8N_DEFAULT_BINARY_DATA_MODE=default` (бинарные файлы в памяти). Источники: [Executions](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/executions.md), [Binary data](https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/binary-data.md), [Data pruning](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/manage-execution-data.md).

**Риск:** сохранённая история содержит output Code-узла `kb01a_base64` независимо от режима хранения binary. По документации очистка касается **завершённых** execution, а `new/running/waiting` и аннотированные executions не подлежат обычной очистке. Это не гарантия физического удаления из PostgreSQL backups и журналов.

**Новый read-only отчёт пользователя — Docker mounts и каталоги:**
- `docker inspect n8n`: один подключённый **Docker volume** с назначением `/home/node/.n8n`. Отдельные mount-источники/названия томов в ответ не выводились.
- Внутри контейнера `/home/node/.n8n/binaryData` **отсутствует** на момент осмотра.
- `/home/node/.n8n/storage` **существует**, вывод `du -sh`: **5.8M**. Это размер *всего каталога*, не доказательство хранения именно KB-документов и не доказательство их удаления.
- Отдельный PostgreSQL-контейнер `n8n-postgres` уже обнаружен; его mount и наличие backup-политики ещё не проверялись.
- Возможность сохранения `kb01a_base64` в базе n8n остаётся, поскольку execution history включена.

**Отчёт пользователя — постоянное хранение PostgreSQL n8n:** контейнер `n8n-postgres` использует Docker `volume` в `/var/lib/postgresql/data`. Данные БД переживают обычные перезапуски контейнера; наличие backup/snapshot/WAL-архивов **этой проверкой не установлено**. Нельзя делать вывод, что старые execution уже удалены или что существуют резервные копии.

**Отчёт read-only проверки названий заданий backup:**
- Docker: по шаблону `backup|restic|borg|duplicati|pgbackrest|wal-g|snapshot` имён контейнеров не найдено (это **не доказательство** отсутствия backup).
- Systemd timer: найден `dpkg-db-backup.timer`; это типовое резервирование данных пакетного менеджера ОС, **не свидетельство** резервного копирования PostgreSQL n8n.
- Cron: найдены **упоминания** `pg_dump|backup|restic|borg|rclone|snapshot|pgbackrest|wal-g`, но не показаны источники. По этим данным нельзя назвать ни программу, ни содержимое backup, ни расписание, ни срок хранения.

**Следующий read-only осмотр:** выяснить **только имена источников Cron**, где встретились маркеры; не показывать содержимое cron-команд, пароли и тексты скриптов, не запускать backup. После проверки локального расписания внешние snapshots провайдера остаются неизвестными; зафиксировать ограничение аудита и переход к B3 только по разрешению.

## 4. Критерии завершения B2

- [x] Отчёт 01 получен, разобраны NOT NULL, связи, индексы и триггеры выбранных таблиц (9 таблиц; полные побочные эффекты функций — следующий этап).
- [x] Отчёт 02 получен: прочитаны 10 функций, проверены дедупликация, `dokument_zanyat`, истечение аренды, `povtor`, отсутствие проверки job/аренды при публикации. Дополнительные триггерные функции остаются к просмотру по необходимости.
- [x] Отчёт 03 получен: 2 ошибочные отменённые TEST-загрузки по-прежнему содержат 2 исходных файла, вместе 8 944 байта. Данные не удалялись.
- [ ] **Частично:** настройки Workflow Settings из скриншота просмотрены (Save, Do not redact, timeout off, Error Workflow none). Настройки глобальной retention/binary, версия, backup и независимая проверка живого расписания ещё неизвестны.
- [ ] Подготовлено точное сопоставление «старая таблица/функция → безопасная замена», порядок миграции и условия rollback для B3 (только проект).
- [ ] Никаких изменений живых компонентов не выполнялось.

**Следующий шаг после отчётов:** дополнить этот документ доказанными фактами и закрыть B2. Перейти к B3 **только после отдельного разрешения**.

