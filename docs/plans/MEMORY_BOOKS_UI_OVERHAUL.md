# Memory Books UI Overhaul — аудит и два концепта

**Статус:** design proposal. Код не менялся — документ описывает аудит текущего
состояния и два варианта переработки.
**Область:** UI вкладки Memory Books внутри `MemorySheet`, sheet настроек
генерации, редактор записи, панель графа, i18n всего этого.
**Ревизия:** v1.

**Карта кода:**

| Что | Файл | Строк |
|---|---|---|
| Хост-sheet (Summary / Books) | `lib/features/chat/widgets/memory_sheet.dart` | 160 |
| Вкладка Memory Books | `lib/features/chat/widgets/memory_books_tab.dart` | 522 |
| Hero + счётчики | `lib/features/chat/widgets/memory/memory_books_overview.dart` | 166 |
| Тулбар + batch-панель | `lib/features/chat/widgets/memory/memory_books_toolbar.dart` | 149 |
| Примитивы (pill / chip / tile / card) | `lib/features/chat/widgets/memory/memory_books_controls.dart` | 296 |
| Карточка записи | `lib/features/chat/widgets/memory/memory_entry_card.dart` | 161 |
| Карточка черновика | `lib/features/chat/widgets/memory/memory_draft_card.dart` | 208 |
| Редактор записи | `lib/features/chat/widgets/memory_entry_editor_sheet.dart` | 148 |
| Настройки генерации | `lib/features/chat/widgets/memory_generation_settings_sheet.dart` | **1223** |
| Панель графа | `lib/features/chat/widgets/memory_graph_panel.dart` | 188 |
| Контроллер | `lib/features/memory/controllers/memory_book_controller.dart` | — |

---

## Сводка

Вкладка `MemoryBooksTab` и её три виджета в `widgets/memory/` уже переведены на
Glaze-кит (`GlazeTabBar`, `SwipeTabSwitcher`, `GlassSurface`, `MenuGroup`) —
это ровно тот кейс, который `docs/UI_KIT.md` приводит как исторический пример
нарушения, и он закрыт. Но переезд остановился на границе вкладки:

- **`memory_generation_settings_sheet.dart` (1223 строки, один класс)** — целиком
  на голом Material: 5× `SegmentedButton`, `ExpansionTile`, `SwitchListTile`,
  `Slider`, 2× `DropdownButtonFormField`, `DropdownButton<int>`, `TextField` с
  `InputDecoration`, `AlertDialog`, `TextButton`/`FilledButton`. Плюс нарушает
  `docs/CODE_STYLE.md` (~200–250 строк на класс) в 5–6 раз.
- **`memory_entry_editor_sheet.dart`** — 3 голых `TextField` + `TextButton` /
  `FilledButton`, при том что в ките есть `GenericEditor`, который этот файл
  схлопывает почти целиком.
- **`memory_graph_panel.dart`** — голый `Dialog` + `TabBar`/`TabBarView` (с
  **одной** вкладкой) + `ListTile`, и **ни одной** строки через `.tr()`.
- **i18n-баги, ломающие поведение**, а не только текст (§2).
- **IA**: до первой записи на экране ~60% хрома — hero, три счётчика, пять
  плиток тулбара, batch-панель, полоса вкладок. Ни поиска, ни фильтра, ни
  сортировки по записям.

---

## 1. Нарушения UI-кита

### 1.1 Sheet настроек генерации — главный очаг

`docs/UI_KIT.md` даёт прямое соответствие для каждого виджета, который здесь
используется:

| Сейчас | Строки | Должно быть |
|---|---|---|
| `SegmentedButton<String>` ×5 (memory mode, injection target, key match, packing, budget) | 264, 312, 544, 584, 694 | `GlazeTabBar(style: pill)` либо `MenuSelectorItem` + `showGlazePickerSheet` |
| `ExpansionTile` (advanced selector) | 362 | `MenuCollapsibleSection` |
| `SwitchListTile` | `_switchTile` | `MenuSwitchItem` |
| `Slider` | 990 | `MenuRangeItem` |
| `DropdownButton<int>` — генерирует `(max-min)/step+1` пунктов; для `autoCreateInterval` (1…200) это **200 `DropdownMenuItem`** на каждый build | 675 | `MenuRangeItem` или `MenuSelectorItem` + `showGlazePickerSheet` |
| `DropdownButtonFormField<String>` ×2 (connection, model) | 1051, 1117 | `MenuSelectorItem` + `showGlazePickerSheet` |
| `TextField` + `InputDecoration` + `fillColor: Colors.white.withValues(alpha: 0.05)` | 736, 758 | `MenuFieldItem` |
| `GestureDetector` + `Container(color: Colors.white…0.05, radius 12)` (выбор промпт-пресета) | 813–862 | `MenuSelectorItem` |
| `AlertDialog` для help | 1021 | `HelpTip` (кит специально держит его под «tooltip, объясняющий термин», и он уважает настройку `hideTooltips`) |
| `TextButton` / `FilledButton` в футере | 338, 343 | `GlazePillButton` / `GlassSurface`-плитка |
| `TextButton.icon` ×2 (view prompt / manage) | 872, 878 | `MenuItem` в группе или `MemoryActionChip` |
| `IconButton.filledTonal` (refresh models) | — | `SheetViewAction` в шапке |

Отдельно: sheet показывается через `GlazeBottomSheet.show(child: …)`, у которого
тело — `SingleChildScrollView` с **неограниченной высотой**. Форма такого
размера — это `SheetView` (см. `docs/UI_KIT.md` § «Which sheet»).

### 1.2 Редактор записи

`_field()` строит `TextField` с `InputDecoration` и `fillColor:
Colors.white.withValues(alpha: 0.05)` (строка 143) — дословно тот антипаттерн,
который UI_KIT называет «stop — это `GlassSurface` или `MenuGroup`». Весь файл
заменяется декларативным `GenericEditor`:

```
GenericEditorSection(fields: [
  GenericEditorField.text('label_block_name'),
  GenericEditorField.tags('memory_books_keys'),      // вместо строки «через запятую»
  GenericEditorField.textarea('label_content'),
])
```

`tags` попутно решает проблему ввода ключей через запятую, которую сейчас
приходится парсить руками (`_save`, строки 40–45).

### 1.3 Панель графа

`Dialog` + `TabBar` с одной вкладкой + `ListTile` + `Colors.red`. Целиком
переезжает в `SheetView` (или `GlazeBottomSheet` с `cardItems`), `TabBar`
исчезает — вкладка одна.

### 1.4 Примитивы

`MemoryCard` (`memory_books_controls.dart:238`) держит
`Colors.white.withValues(alpha: 0.05)` как фон по умолчанию — он же не темизуется.
Замена: `context.cs.surfaceContainerHighest` / `context.cs.outlineVariant`.
Остальные примитивы (`MemoryPill`, `MemoryActionChip`, `MemoryActionTile`,
`MemoryStatTile`) написаны корректно и осознанно избегают `GlassSurface` в
списках — это оставляем.

### 1.5 Секция активности

`memory_activity_section.dart:91,100` — два голых `IconButton` и `showDialog`
для панели графа. `showDialog` → `showModalBottomSheet` + `SheetView`.

---

## 2. i18n: баги, а не только непереведённые строки

### 2.1 ⚠️ Ветвление по английскому литералу над локализованной строкой

`memory_books_tab.dart:435`:

```dart
if (msg.startsWith('Reindex failed') || msg.startsWith('Set up')) {
  GlazeErrorDialog.show(context, msg);
} else {
  GlazeToast.show(context, msg);
}
```

`msg` приходит из контроллера уже переведённым:
`memory_books_reindex_failed` → RU «Переиндексация не удалась: {arg0}»,
`memory_books_setup_embedding_first` → RU «Сначала настройте API эмбеддингов…».
**В русской локали обе ветки не срабатывают**, и ошибка переиндексации
показывается тостом вместо `GlazeErrorDialog`. Починка: контроллер должен
возвращать типизированный результат (`sealed class ReindexResult`), а не строку,
по которой UI гадает.

### 2.2 ⚠️ Неверная строка в подтверждении

`memory_books_tab.dart:468` — после удаления индексов показывается
`'export_success'.tr()` = «Export Complete» / «Экспорт завершен». Нужен свой
ключ (`memory_books_indexes_deleted`).

### 2.3 Непереведённое в интерфейсе

| Где | Строка |
|---|---|
| `memory_sheet.dart:86` | `title: 'Memory'` — заголовок всего sheet'а |
| `memory_graph_panel.dart:49` | `'Memory Graph'` |
| `memory_graph_panel.dart:65` | `'Rebuild'` |
| `memory_graph_panel.dart:77` | `Tab(text: 'Entities')` |
| `memory_graph_panel.dart:103` | `'No entities extracted yet. Run Rebuild to populate.'` |
| `memory_graph_panel.dart:120` | `'$entityType · salience … · N mentions · aliases: …'` |
| `memory_generation_settings_sheet.dart:730–731` | `'At 32k context: min(…) = …. Entries cap stays N.'` |
| `memory_entry_card.dart:132` | `MemoryPill(label: 'idx')` — магический токен, недоступный скринридеру |

### 2.4 Конкатенация переведённых фрагментов с английским клеем

`memory_book_controller.dart:121` — `settingsSummary`:

```
'$mode • $interval msgs • Batch $batchSize • $outTokens • … • th=$vectorThreshold • $maxEntries entries • $memoryBudget • $packing • NxM chunks'
```

Переведены только `$mode`, `$autoCreate`, `$autoGen`, `$delayed`, `$target`,
`$packing`. Английскими остаются `msgs`, `Batch`, `out`, `th=`, `entries`,
`memory tokens` (строка 113), `chunks`. Плюс это 13 полей в одну строку 12 px
под hero — её физически не прочитать; см. §3.

### 2.5 Порядок слов и множественное число

- `_formatTokens` (строка 804): `'$tokens ${'memory_tokens'.tr()}'` — сборка под
  английский порядок слов. Нужен ключ с плейсхолдером: `memory_tokens_n` =
  `{n} tokens` / `{n} токенов`.
- `memory_entry_card.dart:_subtitle`: `'${entry.messageIds.length} ${'memory_books_entry_messages'.tr()}'`
  — в русском три формы (1 сообщение / 2 сообщения / 5 сообщений). Нужен
  `easy_localization` `.plural()`.
- `memory_books_toolbar.dart` (batch-панель): `'$pendingCount ${'memory_books_needs_generation'.tr()}'` — то же самое.

### 2.6 Паритет RU

Из 213 ключей `memory_*` ни один не отсутствует в `ru.json`, но 15 реально не
переведены (значение совпадает с английским, и это не плейсхолдер):
`memory_provider_use_chat_api`, `memory_provider_custom`,
`memory_select_current_api`, `memory_select_custom`, `memory_api_current`,
`memory_api_custom`, `memory_size_small/medium/large`,
`memory_generation_combined/separate`, `memory_injection_hard_block`,
`memory_packing_plain`, `memory_max_tokens_label`, `memory_leave_blank_hint`,
`memory_unlimited`, `memory_tokens`.

### 2.7 Циклический селектор без списка

`memory_books_overview.dart:54` отдаёт `MenuSelectorItem(onTap: onCycleSearchType)` —
тап вслепую перебирает keys → vector → vector+keys. Пользователь не видит
множества вариантов. Нужен `showGlazePickerSheet` с тремя пунктами.

---

## 3. IA и производительность

1. **Хром перед контентом.** Первый экран: hero (20 px радиус, 2 строки текста +
   pill) → `MenuGroup` с типом поиска → 3 счётчика → 5 плиток тулбара →
   (batch-панель) → полоса вкладок → и только потом первая запись.
2. **Нет ни поиска, ни фильтра, ни сортировки.** Длинный чат даёт десятки
   записей, доступ к ним — только вертикальный скролл.
3. **Деструктив рядом с рутиной.** «Удалить индексы» — такая же плитка, как
   «Настройки» и «Сканировать чат».
4. **Настройки — одна простыня.** ~35 контролов, единственная группировка —
   `ExpansionTile`, которая по умолчанию **раскрыта** (`_advancedSelectorOpen = true`).
5. **Смешанная семантика сохранения.** Connection и model пишутся в
   `pipelineSettingsProvider` сразу в `onChanged`, всё остальное — только по
   «Сохранить». Отмена не откатывает модель.
6. **`_loadEmbeddingStatuses`** — последовательный запрос в репозиторий на
   каждую запись при каждом открытии вкладки.
7. **Таймер 200 мс** во время генерации дёргает `setState(() {})` на весь
   `MemoryBooksTab`, т.е. на весь `ListView` вместе со всеми `GlassSurface`.
   Счётчик времени должен жить внутри карточки черновика.

---

## Концепт A — «Shelf» (эволюционный)

Та же ментальная модель (Approved / Drafts), но хром сжат, а список получает
рабочие инструменты.

- **Hero сворачивается.** Одна строка: название + модель + `HelpTip`. 13-польный
  `settingsSummary` уезжает в `MenuCollapsibleSection` «Текущая конфигурация» и
  разбивается на строки `MenuItem` (label / value), где каждое значение —
  отдельный ключ. Строка-простыня удаляется.
- **Счётчики становятся фильтром.** Три `MemoryStatTile` → `GlazeFilterChipBar`:
  «Активные N» / «Нужна пересборка N» / «Черновики N». Тап фильтрует список,
  цифра остаётся на месте.
- **Тулбар: 2 + overflow.** В строке остаются «Сканировать чат» и «Добавить»
  (emphasised). «Настройки», «Переиндексировать», «Удалить индексы» уходят в
  `SheetViewAction` шапки → `GlazeBottomSheet` с `items`, где удаление помечено
  `isDestructive`.
- **Поиск.** `GlazeTextField` в `headerBottom` рядом с `GlazeTabBar` — фильтрация
  по title / content / keys.
- **Строки вместо карточек.** Запись — `Material` + `InkWell` над
  `DecoratedBox` (как `GlazeSessionRow`), ведущая точка статуса вместо двух
  pill'ов, действия — в свайпе и в long-press-меню, а не в постоянном `Wrap` из
  2–5 чипов. Это убирает 3 чипа × N записей из дерева.
- **Настройки → `SheetView`** с `GlazeTabBar` в `headerBottom`:
  «Захват» (auto-create / interval / lag / batch / prompt) ·
  «Отбор» (mode / max entries / budget / packing / diversity / recency /
  importance) · «Модель» (connection / model / injection target / vector).
  Каждая вкладка — `MenuGroup` из `MenuSwitchItem` / `MenuRangeItem` /
  `MenuSelectorItem` / `MenuFieldItem`. Класс на 1223 строки распадается на
  три виджета по ~200.

**Цена:** механика не меняется, риск регрессий низкий. Файлов трогается ~8.

---

## Концепт B — «Pipeline» (переосмысление)

Memory Books — это конвейер `scan → draft → generate → approve → inject`.
Разделение на две вкладки прячет половину конвейера и заставляет переключаться,
чтобы понять состояние.

- **Вкладок нет.** Один список, состояние — свойство строки.
  `GlazeFilterChipBar`: Все · Черновики · Нужна генерация · Активные · Нужна
  пересборка. Полоса `GlazeTabBar` внутри вкладки исчезает (она и так вложена в
  `GlazeTabBar` хост-sheet'а — две одинаковые полосы одна под другой).
- **Одна карточка «Очередь».** Вместо hero + 3 счётчиков + batch-панели —
  `GlassSurface` с одним предложением о текущем состоянии и **ровно одним**
  primary-действием, которое меняется по состоянию:
  - нет покрытия → «Сканировать чат»
  - есть пустые черновики → «Сгенерировать N»
  - есть готовые черновики → «Проверить и принять N»
  - всё чисто → тихая строка «N активных · покрыто до сообщения M».
  Это же место показывает прогресс генерации (`RollingNumber` + линия
  прогресса) вместо отдельной batch-панели.
- **Покрытие видно.** Полоска покрытия чата (сколько сообщений уже покрыто
  записями) — единственная вещь, которую сейчас нельзя узнать, не нажав
  «Сканировать чат» и не прочитав тост.
- **Действия по состоянию, не по типу.** У строки-черновика primary — «Принять»,
  у записи — «Править»; всё остальное в long-press. Черновик и запись — одна
  строка с разным бейджем, а не два разных виджета на 161 и 208 строк.
- **Настройки — три пресета + «Тонко».** `GlazeTabBar` pill: Быстро /
  Сбалансированно / Точно задаёт memory mode, budget, packing и excerpting
  одним движением; `MenuCollapsibleSection` «Тонкая настройка» (свёрнутая по
  умолчанию) открывает нынешние ~35 контролов. Сейчас `memory_mode` и
  `memory_budget`/`packing` задаются независимо, хотя осмысленных комбинаций
  немного.
- **Граф и Agentic Ops** переезжают из иконок в `memory_activity_section` в
  `SheetViewAction` самого Memory-sheet'а — они про сессию, а не про одно
  сообщение.

**Цена:** меняется модель взаимодействия, нужен пересмотр
`MemoryBookController` (состояние строки вместо двух коллекций) и
характеризационных тестов. Файлов трогается ~14.

---

## Общий фундамент (нужен обоим концептам)

1. `ReindexResult` вместо строки из `reindexAll()` — снимает §2.1.
2. Свой ключ для удаления индексов — §2.2.
3. Перевод всех строк из §2.3, ключи для §2.4, `.plural()` для §2.5.
4. Дозаполнение 15 RU-строк из §2.6.
5. `MemoryCard` на токены темы вместо `Colors.white…0.05`.
6. Таймер elapsed — внутрь `MemoryDraftCard`.
7. `_loadEmbeddingStatuses` — один batch-запрос вместо N.

## Порядок работ

| Фаза | Содержание | Зависит от |
|---|---|---|
| 1 | Фундамент §1–7 выше | — |
| 2 | Разбор `memory_generation_settings_sheet.dart` на 3 виджета + переезд на `MenuGroup`/`SheetView` | 1 |
| 3 | `memory_entry_editor_sheet.dart` → `GenericEditor` | 1 |
| 4 | `memory_graph_panel.dart` → `SheetView` + i18n | 1 |
| 5 | Выбранный концепт (A или B) для самой вкладки | 2–4 |
