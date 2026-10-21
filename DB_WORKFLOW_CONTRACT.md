# Катона — связь Supabase с n8n

**Статус: ✅ SQL №3, №5, №6, №7, №8 и два PostgreSQL Credentials n8n подтверждены пользователем; 🔄 подготовка JSON Workflow.** Схема Qbit остаётся без изменений. Файлы SQL №3, №5 и №6 пользователь получает через чат и запускает последовательно. Репозиторий публичный — никакие токены, пароли, секреты, Telegram ID, PII здесь не размещать.

## 1. Схема и объекты

| Объект | Требование | Статус |
|---|---|---|
| Исходная схема | `qbit_bot_pervichnogo_obrascheniya` — только чтение | ✅ аудит |
| Новая схема | `katona`, в той же БД Supabase | ✅ создана |
| Таблицы | 35, пустые | ✅ контроль SQL №3: 35 |
| Индексы | 135, включая HNSW cosine | ✅ контроль SQL №3: 135 |
| Внешние ключи | 69, ссылки только внутри `katona` | ✅ контроль SQL №3: 69 |
| Векторная колонка | `katona.fragmenty_znaniy.vektor vector(1024)` | ✅ создана по SQL №3; поиск не тестировался |
| IDENTITY | 1 | ✅ заложена в SQL №3; отдельная проверка позже |
| SQL-функции | 65, источник SQL №4, все `SECURITY DEFINER` | ✅ SQL №5: 65 |
| Триггеры | 5 | ✅ SQL №5: 5 |
| Роли вызова функций | `katona_bot`, `katona_service`, `katona_dashboard_read`, `katona_dashboard_admin` | ✅ SQL №6: 4 NOLOGIN |
| Проверка прямых прав и изоляции | SQL №7, только чтение | ✅ 0 прямого доступа, 0 PUBLIC EXECUTE, 0 Qbit-ссылок |
| PostgreSQL LOGIN для n8n | `katona_n8n_bot_login`, `katona_n8n_service_login` | ✅ SQL №8: 30 и 28 функций, Qbit недоступен |
| Клиентские данные и Qbit-документы | НЕ копировать | ✅ принято |

**Важно:** пароли/SSH-ключи не публиковать. Ранее показанный в чате фрагмент приватного SSH-ключа требует плановой замены ключа перед production. Источник RLS не использует. В Катоне прямые права на таблицы не выдаём Workflow, функциям выдаём минимально нужные права. Владельца функций `SECURITY DEFINER` и доступ для дашборда проверим до production. SQL №6 создаёт **NOLOGIN**-группы без паролей; логины n8n настраиваем отдельно.

## 2. Параметры для двух Workflow

| Что заменить | Значение/правило | Статус |
|---|---|---|
| PostgreSQL | Два Credentials созданы через SSH-туннель к серверу Supabase: PostgreSQL `127.0.0.1:5433`, БД `postgres`, SSL `Disable` внутри туннеля; два разных пароля хранятся только в n8n | ✅ пользователь подтвердил |
| Схема в SQL | Все `qbit_bot_pervichnogo_obrascheniya.` заменить на `katona.` | ⬜ |
| Клиентская роль | `katona_n8n_bot_login` → группа `katona_bot` (30 функций), пароль назначен, Credential создан | ✅ |
| Служебная роль | `katona_n8n_service_login` → группа `katona_service` (28 функций), пароль ещё не назначен | ✅ SQL №8; 🔄 Credentials |
| Dashboard read/admin | `katona_dashboard_read` (1) / `katona_dashboard_admin` (3) | ⬜ |
| `kompaniya_kod` | `katona` | ⬜ |
| `sreda` | `test` до успешного тестирования | ⬜ |
| Вход первой версии | **Сайт** выбран заказчиком для пилота (бриф №59); нужен новый веб-чат/форма с продолжением | 🔄 спроектировать |
| Битрикс24 | Сделка после получения контакта, поиск дублей, полная история и краткое резюме; воронку/этап/поля проверить | 🔄 требует интеграции |
| Telegram | В брифе действующего Telegram-бота **нет**; не переносить Qbit Telegram-вход/форумные темы без отдельного решения | ⬜ на будущее |
| Webhooks | Новые пути Katona; не использовать URL Qbit | ⬜ |
| OpenAI | Новые Credentials и проверенная поддерживаемая модель | ⬜ |
| STT/Telegram bridge | Проверить инфраструктуру Катоны, не подключаться к сервисам Qbit | ⬜ |
| KB worker | `katona_test_kb_worker_v1` | ⬜ |
| Embeddings | `text-embedding-3-large`, 1024, `cl100k_base`, cosine | ⬜ |
| Профиль знаний | Новый ID формируется при первой загрузке документов Катоны, не использовать Qbit UUID | ⬜ |
| Бизнес-факты | 4 сценария, продукты, география и правила общения извлечены из S1–S4, см. `docs/01_BOT_REQUIREMENTS.md` | ✅ черновик |
| Прайс и обещания | Бриф допускает цены «от», но в требованиях директор против | ⬜ согласовать, цены пока не называть |

**Жёстко заданные названия:** в функциях `otmetit_temu_neizvestnoy` и `zafiksirovat_rezultat_zerkala` было `kompaniya_kod='qbit'`; в SQL №5 меняется на `katona`. В обеих функциях `sreda='test'` оставлена до отдельного решения о production.

## 3. Ключевые SQL-функции → процессы

| Процесс | Клиентский Workflow / служебный Workflow | Роль |
|---|---|---|
| Вход клиента | `zaregistrirovat_vhod_klienta`, `zabrat_zadanie_obrabotki`, `poluchit_soderzhimoe_zadaniya` | `katona_bot` |
| Контекст и память | `poluchit_kontekst_dialoga`, `sohranit_obezlichivanie`, `sohranit_fakty_i_pamyat` | `katona_bot` |
| RAG | `poisk_aktivnyh_znaniy` | `katona_bot` |
| Отправка клиенту | `sozdat_ishodyashchee_deystvie`, `zabrat_ishodyashchee_deystvie`, `poluchit_soderzhimoe_ishodyashchego`, `zafiksirovat_rezultat_ishodyashchego` | `katona_bot` |
| Напоминания | `podgotovit_napominanie`, `poluchit_kontekst_dogonayushchego`, `obrabotat_sleduyushchee_napominanie` | `katona_bot` |
| Передача человеку | `zaprosit_cheloveka`, `zabrat_dialog_operatorom`, `vernut_dialog_botu` | `katona_bot` / `katona_service` |
| Служебный Telegram | `zaregistrirovat_sluzhebnoe_sobytie`, `obnovit_menedzherov_telegram`, `sozdat_ruchnoe_ishodyashchee` | `katona_service` |
| Загрузка знаний | `zaregistrirovat_zagruzku_znaniy`, `zabrat_zadanie_znaniy`, `podgotovit_versiyu_znaniy` | `katona_service` |
| Векторы и проверка KB | `sohranit_fragmenty_znaniy`, `poisk_chernovika_znaniy`, `sohranit_proverki_znaniy`, `opublikovat_versiyu_znaniy` | `katona_service` |
| Дашборд | `audit_dashboard_summary`, `otozvat_dokument_znaniy` | dashboard роли |

**Полный перечень 65 сигнатур и 59 PostgreSQL-узлов** подготовлен отдельно для проверки; GitHub-план пока фиксирует только предполагаемые привязки, не завершённую настройку.

## 4. Не подключать без разработки

В клиентском JSON есть неподключённый узел `Поставить внешнюю интеграцию в очередь`. Он вызывает отсутствующую функцию `postavit_integraciyu_v_ochered(uuid,jsonb)` **без указания схемы**. Этот узел — заготовка; не подключать. Site, Avito и MAX также пока заглушки.

## 5. Порядок подтверждения

1. ✅ **SQL №3:** отчёт получен: 35 таблиц, 135 индексов, 69 FK, 0 функций.
2. ✅ **SQL №5:** отчёт получен: 65 функций, 5 триггеров, 65 SECURITY DEFINER.
3. ✅ **SQL №6:** четыре роли NOLOGIN подтверждены; список создан.
4. ✅ **SQL №7:** 30/28/1/3, 0 прямых прав, 0 PUBLIC EXECUTE, 0 Qbit-ссылок.
5. ✅ **SQL №8:** два новых LOGIN-имени n8n без паролей; bot 30/service 28, Qbit нет.
6. ✅ Два разных пароля и два PostgreSQL Credentials n8n подтверждены пользователем; отдельная проверка SQL-вызовов после импорта.
7. 🔄 Подготовить два JSON `active=false`; после получения данных Катоны импортировать и привязать готовые Credentials.
8. ⬜ Загрузить документ Катоны и проверить публикацию/поиск.
9. ⬜ Проверить диалог, менеджера, напоминания и права, только потом включать.


## 6. Полученные клиентские требования

См. `docs/00_SOURCE_INDEX.md` (источники), `docs/01_BOT_REQUIREMENTS.md` (поведение), `docs/02_OPEN_DECISIONS.md` (спорные вопросы), `docs/03_WORKFLOW_MIGRATION.md` (адаптация), `docs/04_COMPANY_KB_DRAFT.md` (неутверждённая KB). Оригиналы 4 файлов заказчика в открытый репозиторий не загружены.
