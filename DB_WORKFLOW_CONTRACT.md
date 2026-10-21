# Катона — связь Supabase с n8n

**Статус: 🔄 SQL №3, исправленный SQL №5 и SQL №6 выполнены; SQL №7 — проверка прав перед n8n.** Схема Qbit остаётся без изменений. Файлы SQL №3, №5 и №6 пользователь получает через чат и запускает последовательно. Репозиторий публичный — никакие токены, пароли, секреты, Telegram ID, PII здесь не размещать.

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
| Проверка прямых прав и изоляции | SQL №7, только чтение | 🔄 ожидается отчёт |
| Клиентские данные и Qbit-документы | НЕ копировать | ✅ принято |

**Важно:** источник RLS не использует. В Катоне прямые права на таблицы не выдаём Workflow, функциям выдаём минимально нужные права. Владельца функций `SECURITY DEFINER` и доступ для дашборда проверим до production. SQL №6 создаёт **NOLOGIN**-группы без паролей; логины n8n настраиваем отдельно.

## 2. Параметры для двух Workflow

| Что заменить | Значение/правило | Статус |
|---|---|---|
| PostgreSQL | Новое защищённое подключение; host/port/database брать в Supabase Connect | ⬜ |
| Схема в SQL | Все `qbit_bot_pervichnogo_obrascheniya.` заменить на `katona.` | ⬜ |
| Клиентская роль | Член группы `katona_bot` (30 разрешённых SQL-функций) | ⬜ |
| Служебная роль | Член группы `katona_service` (28 функций) | ⬜ |
| Dashboard read/admin | `katona_dashboard_read` (1) / `katona_dashboard_admin` (3) | ⬜ |
| `kompaniya_kod` | `katona` | ⬜ |
| `sreda` | `test` до успешного тестирования | ⬜ |
| Telegram | **Новые** клиентский бот, служебный бот, группа, разрешённые менеджеры и Credentials | ⬜ |
| Webhooks | Новые пути Katona; не использовать URL Qbit | ⬜ |
| OpenAI | Новые Credentials и проверенная поддерживаемая модель | ⬜ |
| STT/Telegram bridge | Проверить инфраструктуру Катоны, не подключаться к сервисам Qbit | ⬜ |
| KB worker | `katona_test_kb_worker_v1` | ⬜ |
| Embeddings | `text-embedding-3-large`, 1024, `cl100k_base`, cosine | ⬜ |
| Профиль знаний | Новый ID формируется при первой загрузке документов Катоны, не использовать Qbit UUID | ⬜ |
| Бизнес-факты | Название, описание, темы, цель, поля и сценарии продаж Катоны | ⬜ |

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
4. 🔄 **SQL №7:** проверка EXECUTE 30/28/1/3, запрета PUBLIC и прямых прав на таблицы.
5. ⬜ Подготовить и импортировать два JSON `active=false`, настроить новые Credentials.
6. ⬜ Загрузить документ Катоны и проверить публикацию/поиск.
7. ⬜ Проверить диалог, менеджера, напоминания и права, только потом включать.
