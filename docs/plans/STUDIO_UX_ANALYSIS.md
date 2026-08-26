# Studio UX Analysis — переход к модели «Agentic Preset»

**Статус:** частично реализованный design plan. Значительная часть фаз уже
вошла в код, тогда как полный нейминг `Studio -> AgenticPreset` и отдельные
cleanup-пункты еще не завершены. Разделы "Как сейчас" и старые номера строк
фиксируют исходный аудит и не являются текущей картой файлов.
**Ревизия:** v4 — актуальная карта реализации добавлена в 2026-08.
**Область:** UI студии, ontology агентов, модель блоков пресета, нейминг.

**Текущая карта кода:**

- Studio seed payload: `lib/core/db/studio_preset_seed.dart`;
- DB registration/schema: `lib/core/db/app_db.dart` (`schemaVersion = 130`);
- split table declarations: `lib/core/db/tables/studio_and_presets.dart` and
  `lib/core/db/tables/ledger.dart`;
- Ledger facade: `lib/core/llm/studio_ledger_service.dart`;
- Ledger execution/commit specialists: `lib/core/llm/ledger/`;
- Studio block model: `lib/core/models/studio_config.dart`;
- Studio UI: `lib/features/studio/`.

Документ описывает целевую модель: что есть сейчас (с привязкой к коду), что
предлагается, что придётся тронуть, какие миграции и риски. Пошаговый план
(фазы/коммиты) — в конце, §«Порядок работ».

---

## Принятые решения

Эти решения зафиксированы и заменяют варианты, которые рассматривались в
черновиках:

1. **У Ledger — свой слот модели.** Он больше не делит слот с постпроцессом.
2. **Обязательный агент ровно один — Main Response.** Post Clean работает как
   раньше (включается/выключается), просто в списке агентов стоит после Main
   Response.
3. **Narrative удаляется как агент.** Его задача — переводить правила пресета в
   контракт формы ответа — становится не нужна: агентный пресет сам несёт
   промпт-блоки, и они инжектятся прямо в Main Response.
4. **`kind` заменяется полем «Режим» с тремя значениями** (§5),
   **«корзинка» (`isStashed`) удаляется** из обычного пресета. Контекстные
   блоки агентного пресета становятся такими же, как в обычном (character desc,
   scenario и т.д.). **`section` → «Точка инжекта»**, с новым значением
   **«специфический агент»** и выбором конкретного агента.
5. **Нейминг в коде:** преген-контроллеры переименовываются из `tracker` в
   `controller`; **в коде Ledger остаётся `ledger`**.
6. **Recovery переезжает в Agentic Ops.**
7. **Выключение агентного режима = переключение на обычный пресет.** Активный
   пресет один, он либо обычный, либо агентный.
8. Старая логика режимов (Direct/Assisted/Legacy) удаляется без обратной
   совместимости поведения.
9. **В интерфейсе Ledger называется «Трекер».** Код остаётся `ledger`, UI —
   «Трекер».
10. **Выключение Трекера выключает Continuity.** Continuity зависит от него
    напрямую (§11), поэтому связь делается явной, а не предупреждением.
11. **Режимы `tracker_instruction` и `agent_instruction` не нужны** — их роль
    берёт на себя точка инжекта «специфический агент».
12. **Включение Трекера возвращает Continuity** в то состояние, в котором он
    был до автоотключения.
13. **Макросы `{{studio_<имя>_brief}}` сохраняются** как синтаксический сахар
    поверх режима «Ответ агента» — но перечень имён в них становится
    динамическим (§5).
14. **Beauty работает и без Post Clean.** Захват стилевого состояния
    отвязывается от постпроцесса (§1).
15. **Бейдж запросов — формат `5/ход`.** MemoryBook и ExtBlocks в счёт не
    входят (§7).
16. **Секции `build` и `brief_parser` удаляются целиком** — это мёртвые
    данные (§5).

---

## 0. Словарь

| Было (UI + код) | Стало |
|---|---|
| Studio, Loom, Legacy Studio, Direct Loom, Assisted Loom | **Agentic Preset** (агентный пресет) |
| Controller, Tracker, Shard, Studio agent | **Агент** (UI) / `Controller` (код, преген) |
| Main Responder | **Main Response** (главный писатель) |
| POST-cleaner, Cleaner, Post-Gen | **Post Clean** (постпроцесс) |
| Studio Ledger | UI: **Трекер** · код: `ledger` |
| Beauty Shard | *(упраздняется как сущность — §1)* |
| Narrative / Pacing / Style Controller | *(упраздняется как сущность — §3)* |
| Previous Agents | **Pregen Brief** (§5) |

⚠️ Слово `tracker` сегодня в коде означает **преген-контроллеры**
(`TrackerBatcher`, `studioTracker*`, `StudioTrackerPhaseRunner`), а таблица
`tracker_rows` (`lib/core/db/tables.dart:283`) — это хранилище **Ledger**.
Два разных смысла одного слова уже сосуществуют в коде.

Решения 5 и 9 разводят их окончательно, по слоям:

| | UI | Код |
|---|---|---|
| Преген-агенты | «агенты» | `controller` |
| Ledger | «Трекер» | `ledger` |

То есть «трекер» остаётся ровно одним понятием и означает **только** Ledger.
Таблица `tracker_rows` при этом попадает в целевой нейминг без миграции: она
хранит именно данные Трекера. Переименование самой таблицы не делается
(миграция схемы того не стоит), а вот `TrackerRepo` / `trackerRepoProvider`
→ `LedgerRepo` / `ledgerRepoProvider`, потому что в коде слой называется
`ledger`.

---

## Сводка

Нумерация в скобках — пункты исходной постановки.

| § | Изменение | Тип | Риск |
|---|---|---|---|
| 1 (1) | Beauty уходит внутрь Post Clean | пайплайн + пресет | средний |
| 2 (2) | Post Clean и Трекер — агенты в списке, после Main Response | ontology + UI | средний |
| 3 (3) | Обязателен только Main Response; Narrative удаляется | ontology | средний |
| 4 (4а) | Идентичность агента прибита к spec, имя read-only | ontology + prompt | **высокий** |
| 5 (4б) | `kind` удаляется, `section` → «Точка инжекта» + «специфический агент» | **модель данных** | **высокий** |
| 6 (5) | Direct/Assisted/Legacy удаляются | модель | средний |
| 7 (6,7) | Пресеты в экране «Пресеты», один активный пресет | UI + архитектура | **высокий** |
| 8 (7,6) | Старый шит удаляется, Recovery → Agentic Ops | UI | низкий |
| 9 (8,1) | Вкладка «Агенты» в API Sheet, 4 слота | UI + модель | средний |
| 10 (9,5) | Консолидация нейминга | рефактор | средний |

---

## 1. Beauty уходит в Post Clean

### Как сейчас

Beauty — полноценный преген-агент: `lib/core/llm/studio_controller_ontology.dart:164-176`
(`id: 'beauty'`, `phase: 'pre_generation'`).

Его бриф **намеренно не попадает** к писателю — он извлекается и отдаётся
клинеру: `lib/features/chat/services/stages/cleaner_stage.dart:263-309`
(`BeautyStateHandler.extractBeautyBrief` → `beautyBrief` → cleaner).

Один переключатель владеет тремя persisted-блоками
(`lib/features/chat/widgets/studio_agents_sheet.dart:10-37`): `beauty_extractor`
(секция `build`), `beauty_task` (`pregen`), `cleaner_beauty` (`cleaner`).

В Direct-режиме Beauty уже выводится **внутри** постклинера
(`lib/core/models/studio_preset_topology.dart:66-74`) — то есть рабочий режим
без преген-части существует и проверен.

### Что предлагается

Beauty перестаёт быть агентом; стилевое состояние — внутренняя часть Post Clean.

- Spec `beauty` удаляется из `StudioControllerOntology.specs`.
- `beauty_task` и `beauty_extractor` выключаются как legacy; `cleaner_beauty`
  принудительно включён и относится к Post Clean.
- `agentEnabled['beauty']` удаляется, тройной toggle
  (`studio_agents_sheet.dart:10-37`) уходит целиком.
- Полоса ответственности Beauty (`studio_prompt_text.dart:104-111`) переезжает
  в промпт Post Clean секцией «стилевое состояние».

### Что трогаем

`studio_controller_ontology.dart`, `studio_agents_sheet.dart`,
`studio_preset_topology.dart`, `studio_prompt_text.dart`, `cleaner_stage.dart`,
сид-блоки `app_db.dart:1691` / `:2043` / `:2080`.

### Миграция

Разово при чтении пресета: выкинуть `agentEnabled['beauty']`, выключить
`beauty_task`/`beauty_extractor`, включить `cleaner_beauty`. Та же нормализация
на импорте (`StudioPreset.fromJson`), чтобы чужой JSON не воскрешал слот.

### Beauty должна работать и без Post Clean (решение 14)

Здесь важная поправка к тому, что я писал раньше: «регрессия» при выключенном
Post Clean **уже существует в текущем коде**, и §1 её не создаёт.

Разбор по коду: `<glaze_beauty_state>` парсится и сохраняется **только** внутри
клинера — `parseBeautyState` в `cleaner_stage.dart:631` и запись в
`sessionVars[beautyStateVarKey]` в `:888-904`, плюс `post_cleaner_service.dart:207-210`.
Других путей нет. А `PostGenCoordinator` пропускает всю стадию клинера, когда
`postCleanerEnabled == false`. То есть сегодня при выключенном Post Clean
преген-агент Beauty исправно тратит запрос, его бриф уходит в никуда (его
потребитель — клинер, который не запустился), и состояние не сохраняется.

Что нужно добавить, чтобы Beauty жила без постпроцесса:

- Разбор маркера `<glaze_beauty_state>` из текста **Main Response** и запись в
  `sessionVars` переносятся из стадии клинера в post-gen-путь, который
  выполняется всегда. Маркер эмитит именно писатель — так уже устроено сейчас,
  сид-блок `beauty_task` прямо это фиксирует: «Do not append the
  `<glaze_beauty_state>` marker yourself — the Main Responder handles
  persistence» (`app_db.dart:1691`).
- Post Clean при этом сохраняет свою роль: когда он включён, он дополнительно
  применяет стилевые правила (`cleaner_beauty`) и может обновить состояние
  своим выводом. Когда выключен — состояние всё равно копится с ответов
  писателя.

Итого: Beauty перестаёт быть агентом (минус запрос), но её состояние живёт
независимо от постпроцесса — то есть становится надёжнее, чем сейчас.

### Ещё одна эвристика по имени, которую надо снять

`BeautyStateHandler.extractBeautyBrief`
(`lib/features/chat/services/stages/beauty_state_handler.dart:16-32`) ищет бриф
перебором `studioOutputs` с матчингом `agentId.contains('beauty')` /
`agentName.contains('beauty')` — тот же класс хардкода, что четыре эвристики из
§4. После удаления агента Beauty этот метод теряет источник и удаляется вместе
с ним: состояние берётся из маркера в тексте писателя, а не из вывода агента.

---

## 2. Post Clean и Трекер — агенты в списке

### Как сейчас

Список агентов = `StudioControllerOntology.specs` — только преген + `final`.
Post Clean и Ledger в него не входят:

- Post Clean — булев тумблер `CleanerSettings.postCleanerEnabled`, UI в
  `studio_settings_sheet.dart:873-894`, отдельно от списка агентов.
- Ledger — always-on, тумблера нет вообще; только каденс
  `LedgerSettings.studioLedgerRunMode`, и в UI он не выведен.

### Что предлагается

Два новых spec'а, оба с `phase: 'post_processing'`:

| id | Имя в UI | Позиция | Поведение |
|---|---|---|---|
| `post_clean` | Post Clean | сразу после `final` | **как раньше** — включается/выключается |
| `ledger` | **Трекер** | сразу после `post_clean` | включается/выключается |

Порядок в списке: преген-агенты → **Main Response** → **Post Clean** → **Трекер**.

Post Clean не меняет поведения — меняется только место, где им управляют:
вместо отдельного тумблера «Пост-клинер» в шите он становится строкой в списке
агентов. Источник правды переезжает в пресет (`agentEnabled['post_clean']`),
а `cleaner.postCleanerEnabled` синхронизируется с ним; `PipelineSettings`
сохраняет за собой только тюнинг (temperature/tokens/таймауты/каденс).

### ⚠️ Обязательное условие: `phase` строго `post_processing`

`StudioActivationGate.splitAgentsByPhase`
(`lib/core/llm/studio_activation_gate.dart:90-135`) выбирает генератора как
**последний** агент с `phase == 'pre_generation'`. Если добавить новые spec'ы
с преген-фазой, генератором станет Ledger, а Main Response превратится в
преген-контроллер.

Отсюда два следствия:

1. Оба новых spec'а — строго `post_processing`.
2. Генератор определяется явным флагом `isFinal`, а не позицией в списке.
   Позиционный выбор остаётся только как fallback для старых строк
   `agents_json`. Это же требуется для §3 (Main Response нельзя выключить) и
   §6 (топология больше не задаётся режимом).

### Зависимость: Трекер → Continuity

Continuity опирается на `<studio_session_state>`, который производит Трекер
(разбор в §11). По решению 10 связь делается явной в модели, а не
предупреждением в тексте:

- **Выключение Трекера выключает Continuity.** Переключатель Continuity
  становится неактивным с подписью «требует Трекер».
- **Включение Трекера возвращает Continuity** в то состояние, в котором он был
  до автоотключения, а не безусловно в «включён» (решение 12). Требует
  запоминания: в пресете рядом с `agentEnabled` появляется
  `agentEnabledBeforeDependencyOff` — карта состояний, снятых каскадом.
  Без неё «вернуть как было» неотличимо от «включить», и агент, который
  пользователь выключил сам, воскреснет при первом же тумблере Трекера.
- Зависимость описывается декларативно — поле `requiresSpecId` в
  `StudioControllerSpec` (`'continuity' → 'ledger'`), а не хардкодом в
  обработчике переключателя. Тогда следующая такая связь не потребует править
  UI-код.

Каскад применяется в `applyStudioAgentToggle` (`studio_agents_sheet.dart:18-37`)
и повторно при резолве пресета — импортированный чужой JSON с
`ledger: false, continuity: true` должен нормализоваться так же.

---

## 3. Обязателен только Main Response; Narrative удаляется

### Как сейчас

`StudioAgentsSheet` рисует `SwitchListTile` **на каждый** spec, включая `final`
(`studio_agents_sheet.dart:112-147`); единственная блокировка — топология
режима (`:145`). То есть `final` сегодня можно выключить.

Что произойдёт: `splitAgentsByPhase` возьмёт последним преген-агентом кого
угодно и объявит его генератором — сцену будет писать контроллер стиля.

### Что предлагается

**Main Response — единственный обязательный агент.**

- В `StudioControllerSpec` поле `lockedOn: bool`, `true` только для `final`.
- UI: переключатель отрисован, `onChanged: null`, значение всегда `true`,
  иконка замка + подпись «обязательный агент».
- `applyStudioAgentToggle` игнорирует запрос на выключение locked-спеки.
- Слой резолва принудительно ставит `enabled: true` для `final` **вне
  зависимости** от содержимого пресета — защита от импортированного JSON, где
  `agentEnabled['final'] == false`.

**Narrative удаляется как агент.**

Spec `narrative` (`studio_controller_ontology.dart:83-95`) исчезает из
онтологии. Его задача — «convert the active preset's narrative mode, style,
POV, pacing, sensory budget… into a response-shape contract» — теряет смысл в
новой модели: по §5 агентный пресет сам несёт промпт-блоки, а по §7 он
единственный активный, поэтому правила формы ответа инжектятся прямо в Main
Response, без посредника-переводчика.

Сид-блоки `narrative_task`, `narrative_task_universal`, `narrative_task_orig`
(`app_db.dart:1614`, `:1625`, `:1636`) не выбрасываются: они превращаются в
обычные промпт-блоки с точкой инжекта «финал» (§5). Содержательная часть —
маппинг длины/абзацев по типу бита, `LENGTH BAND MAPPING` — сохраняется, она
ценная; меняется только способ доставки: не через отдельный LLM-запрос, а
текстом в промпте писателя.

Аналогично снимается полоса ответственности `narrative` из
`studio_prompt_text.dart:72-79` и алиас `['narrative','pacing','style']` из
карты роутинга (`studio_runtime_block_expander.dart:119`).

### Что это даёт

Минус один LLM-запрос на ход (или один агент из батча), минус один слой
пересказа правил пресета. Правила доходят до писателя дословно, а не в виде
брифа, который контроллер пересобрал своими словами.

---

## 4. Идентичность агента прибита к spec, имя не редактируется

### Как сейчас — четыре независимых эвристики по строке имени

1. **Полоса ответственности** — `StudioPromptText._controllerScope(agent.name)`
   (`lib/core/llm/studio_prompt_text.dart:54-116`): `name.toLowerCase()` и
   `contains('continuity')`, `contains('beauty')`… Отсюда берётся «твоя полоса /
   не твоя полоса» в рантайм-конверте (`:23-51`).
2. **Роутинг блоков** — `StudioRuntimeBlockExpander.trackerInstructionAppliesToAgent`
   (`lib/core/llm/studio/studio_runtime_block_expander.dart:110-131`):
   алиас-карта, матчится по `'${agent.id}\n${agent.name}'`.
3. **Обратный маппинг агент → spec** — `StudioControllerOntology.specForAgent`
   (`studio_controller_ontology.dart:226-235`): `contains` по id/имени с
   fallback **по индексу** `agent.order`.
4. **Подстановка брифа конкретного агента** —
   `StudioBriefMacroRenderer.briefsForController`
   (`lib/core/llm/studio/studio_brief_macro_renderer.dart:93-112`): ещё одна
   алиас-карта плюс regex с зашитым перечнем имён контроллеров (`:13-16`),
   обслуживающий макросы `{{studio_continuity_brief}}`, `{{studio_world_brief}}`
   и т.д.

Следствие: имя агента — фактически ключ маршрутизации. Переименование (или
чужой пресет с другим именем агента) молча меняет и полосу ответственности, и
то, какие блоки до агента доедут, и какой spec подтянется при одиночном
регене, и какой бриф подставится в макрос. Fallback по `order` довершает
картину: при любом расхождении длины списка агент получает чужую личность.

Наборы алиасов в этих четырёх местах **не совпадают** между собой — например
`_controllerScope` ловит `'character'` внутри ветки agency, а карты экспандера
и макро-рендерера отдельно перечисляют `'lumia'` для meta. Кроме того, regex
макросов (`:13-16`) — это отдельный, пятый по счёту список имён, который надо
править руками при любом изменении состава агентов: §1 и §3 (удаление `beauty`
и `narrative`) ломают его напрямую.

### Что предлагается

**Личность агента — константа spec'а, ключ — `specId`, имя не участвует ни в
чём кроме отображения.**

1. `StudioControllerSpec` получает полный набор полей идентичности в одном
   месте: `purpose` («кто ты»), `outputContract` («как выводить»),
   `laneOwns` / `laneSkip` (полоса — переезжает из `_controllerScope`).
2. `StudioAgent.specId` (новое persisted-поле). Все четыре эвристики заменяются
   на `specs.byId(agent.specId)`. Матчинг по имени и fallback по `order`
   удаляются.
3. `agent.name` берётся из spec'а при отображении и **не редактируется**.
4. UI: тап по строке агента открывает read-only карточку:

   ```
   ┌ Continuity ───────────────────────────── 🔒
   │ Кто ты        purpose
   │ Твоя полоса   laneOwns
   │ Не твоя       laneSkip
   │ Как выводить  outputContract
   └ Эти инструкции фиксированы и не редактируются
   ```

   Никаких полей ввода — только текст и «копировать». Редактируемым остаётся
   ровно то, что и раньше: промпт-блоки пресета, которые открываются отдельно.

### Миграция

Разовый backfill `specId` для существующих `agents_json`: прогнать текущий
`specForAgent` **один раз** при чтении конфига, записать `specId`, дальше
эвристику не вызывать. Несмапившиеся агенты помечаются в логе — их проще
пересоздать из `buildDefaultAgents`, чем угадывать.

Роутинг блоков на агента после §5 делается не алиасами, а явным
`targetAgentId` в блоке — эвристика №2 удаляется вместе с `tracker_instruction`.
Эвристика №4 удаляется там же: режим «Ответ агента» с явным `sourceAgentId`
заменяет захардкоженные `{{studio_<имя>_brief}}`-макросы (§5).

### Риск

Высокий: любой пресет, который сегодня «случайно попадал» в нужную ветку по
подстроке, после перехода на `specId` попадёт туда же только если backfill
отработал верно. Нужны тесты на маппинг всех сид-блоков и на импорт
`Loom Adapt v1`-подобного пресета.

---

## 5. Модель блоков: `kind` → «Режим», `section` → «Точка инжекта»

Самый крупный пункт по объёму изменений в данных.

### Как сейчас

```dart
// lib/core/models/studio_config.dart:80-93
StudioPresetBlock { id, title, kind, role, content, enabled, order, section }
```

`kind` — 16 значений (`studio_block_editor_dialog.dart:45-62`):
`custom_text`, `slot`, `instruction`, `agent_instruction`, `tracker_instruction`,
`previous_agents`, `user_persona`, `char_card`, `scenario`, `char_personality`,
`example_dialogue`, `authors_note`, `static_context`, `chat_history`, `memory`,
`dynamic_context`.

`kind` — это switch в сборке сообщений (`studio_message_builder.dart:68-175`):
часть значений эмитит собственный контент, часть подтягивает бакет контекста
через `context.messagesForKind(block.kind)` (`:159`, `:313`).

Для сравнения — обычный пресет **не имеет `kind` вообще**
(`lib/core/models/preset.dart:6-27`): у него канонические id
(`_staticBlockIds`, `preset.dart:79-92`: `char_card`, `scenario`,
`chat_history`, `memory`, …) + флаг `isStatic`.

### Ключевое наблюдение: пространства имён уже совпадают

`byKind` в бакетайзере заполняется **по `blockId` обычного пресета**
(`studio_context_bucketizer.dart:97-103`: `addByKind(blockId, message)`).
То есть `messagesForKind(block.kind)` работает ровно потому, что значения
`kind` в агентном пресете названы так же, как id блоков в обычном.

Значит переход `kind` → `id` — это не изобретение нового маппинга, а
схлопывание двух параллельных названий одного и того же в одно.

### Что предлагается

`kind` из 16 значений схлопывается в **два ортогональных поля** плюс
канонический `id` для контекстных слотов:

```dart
StudioPresetBlock {
  id,            // канонический для слотов: char_card, scenario, chat_history…
  title,
  role,
  content,
  enabled,
  order,
  isStatic,      // как в обычном пресете, вместо kind-слотов
  mode,             // ← «Режим»: что блок эмитит
  injectionPoint,   // ← бывший section, «Точка инжекта»: кому это уходит
  targetAgentId,    // ← при injectionPoint == specificAgent
  sourceAgentId,    // ← при mode == agentResponse
  groupBoundary,    // ← служебное, см. ниже
}
```

### Поле «Режим» — что блок эмитит

| Режим (UI) | Код | Было (`kind`) | Что делает | Доп. поле |
|---|---|---|---|---|
| **Прямая инструкция** | `direct` | `custom_text` | эмитит собственный контент блока | — |
| **Pregen Brief** | `pregenBrief` | `previous_agents` | подставляет брифы всех преген-агентов | — |
| **Ответ агента** | `agentResponse` | *(новое)* | подставляет ответ одного конкретного агента | `sourceAgentId` |

`previous_agents` переименовывается именно потому, что нынешнее имя не
объясняет содержимое: блок подставляет не «предыдущих агентов», а их брифы,
причём только преген-фазы. «Pregen Brief» это и говорит.

**Режим «Ответ агента» уже существует в коде — но в виде хардкода.** Сегодня
подстановка брифа конкретного агента делается макросами
`{{studio_continuity_brief}}`, `{{studio_world_brief}}` и т.д.
(`studio_brief_macro_renderer.dart:39-70`), где перечень имён зашит и в regex
(`:13-16`), и в алиас-карту (`:93-112`) — это эвристика №4 из §4. Новый режим
обобщает механизм: вместо девяти захардкоженных макросов — один режим и
явный `sourceAgentId`.

**Макросы при этом сохраняются** (решение 13) — они остаются удобным способом
вставить бриф в середину произвольного текста, чего режим блока не умеет: режим
задаёт содержимое блока целиком. Но хардкод из них убирается:

- regex (`:13-16`) собирается из `StudioControllerOntology.specs`, а не пишется
  руками — иначе §1 и §3 (удаление `beauty` и `narrative`) ломают его напрямую,
  а новый агент не получает своего макроса;
- алиас-карта (`:93-112`) заменяется на поиск по `specId`, как и остальные три
  эвристики из §4;
- имя макроса выводится из `specId`: `{{studio_<specId>_brief}}`.

Итог: `{{studio_continuity_brief}}` продолжает работать, `{{studio_narrative_brief}}`
и `{{studio_beauty_brief}}` перестают существовать вместе со своими агентами
(и должны молча раскрываться в пустую строку, как сегодня уже сделано для
beauty, `:68`).

### Поле «Точка инжекта» — кому уходит

| Значение | UI | Куда уходит контент |
|---|---|---|
| `pregen` | Прегенерация | всем включённым преген-агентам |
| `final` | Финал | Main Response |
| `cleaner` | Постпроцесс | Post Clean |
| `ledger` | Трекер | Трекер |
| `specificAgent` | **Специфический агент** | одному агенту из выпадающего списка |

При выборе «специфический агент» появляется второе поле — выпадающий список
агентов; выбранный пишется в `targetAgentId` (это `specId` из §4, не имя).

Секции `build` и `brief_parser` в списке не появляются — они удаляются целиком
(разбор ниже).

### Секции `build` и `brief_parser` — мёртвые данные, удаляются

Проверка показала: это остатки удалённой архитектуры, а не «внутренние секции»,
как я предполагал раньше. Ни одна строка рантайма их не читает.

**Что в них лежит** (5 блоков, `app_db.dart:2058-2113`): `build_router`,
`build_synthesizer`, `beauty_extractor`, `cleaner_rules_extractor` в секции
`build`; `brief_parser_fallback` в секции `brief_parser`.

**Почему они мертвы:**

1. **Сервисов, которым они принадлежали, больше нет.** Комментарий к сиду
   (`app_db.dart:1544-1548`) перечисляет источники: `studio_beauty_extractor.dart`,
   `studio_block_router.dart`, `studio_cleaner_rules_extractor.dart`,
   `studio_shard_synthesizer.dart` — ни одного из этих файлов в `lib/` нет.
   Историческая decomposition pipeline, block router, shard synthesizer,
   beauty extractor и cleaner rules extractor удалены.
2. **Никто не фильтрует блоки по этим секциям.** Единственные потребители
   секций — `StudioAuxPromptAssembler`, который принимает только `'cleaner'` и
   `'ledger'` (`studio_aux_prompt_assembler.dart:28,41,49`), и
   `sectionForRun`, возвращающий `'final' | 'cleaner' | 'pregen'`
   (`studio_runtime_block_expander.dart:79-83`).
3. **Контент четырёх блоков не читается нигде.** У `build_router`,
   `build_synthesizer`, `cleaner_rules_extractor`, `brief_parser_fallback` ноль
   ссылок за пределами сида.
4. **`StudioBriefParser` не читает пресет вообще** — это чистый разбор
   текста/JSON, поэтому у `brief_parser_fallback` физически нет потребителя.
5. **Сама функция сида называется** `_legacyStudioPresetMigrationBlocks()` и
   документирована как «retained only so upgrades from old database schemas can
   finish without changing their historical migration behavior»
   (`app_db.dart:1553-1555`).

**Единственное исключение — `beauty_extractor`,** и он используется не по
назначению: его читают **по id**, а не по содержимому, и только чтобы хранить
состояние галочки Beauty (`studio_agents_sheet.dart:11,121`,
`studio_preset_topology.dart:69`). То есть блок работает как ячейка для
булева флага. Вместе с удалением агента Beauty (§1) эта роль исчезает.

**Что делать:** удалить обе секции и все 5 блоков из модели, редактора и новых
пресетов; в миграции существующих пресетов — выбросить блоки этих секций.
Историческую функцию `_legacyStudioPresetMigrationBlocks()` **трогать нельзя**:
она воспроизводит поведение старых миграций схемы и должна остаться как есть.

### ⚠️ Два выпадающих списка агентов означают противоположное

Это главный риск нового редактора блока: на одном экране появляются два
селектора агента с прямо противоположным смыслом.

| Поле | Смысл | Направление |
|---|---|---|
| Точка инжекта → `targetAgentId` | контент блока **уходит** этому агенту | блок → агент |
| Режим → `sourceAgentId` | контент блока **берётся** у этого агента | агент → блок |

В UI их нужно развести не только подписью, но и формой: например
`→ Отправить агенту: <…>` против `← Взять ответ агента: <…>`. Иначе
пользователь будет уверенно настраивать одно вместо другого, и ошибка
проявится только в промпте.

### Что уходит вместе с `kind`

| Было (`kind`) | Стало |
|---|---|
| `custom_text`, `slot`, `instruction` | режим **Прямая инструкция** |
| `previous_agents` | режим **Pregen Brief** |
| `tracker_instruction` | **удаляется** — точка инжекта `specificAgent` + `targetAgentId` |
| `agent_instruction` | **удаляется** — конверт идентичности эмитит сам агент (§4) |
| `char_card`, `scenario`, `user_persona`, `char_personality`, `example_dialogue`, `authors_note`, `memory`, `chat_history` | канонический `id` + `isStatic` (как в обычном пресете) |
| `static_context`, `dynamic_context` | канонические `id` служебных блоков |

`slot` и `instruction` схлопываются в «Прямую инструкцию» без потери
поведения: в switch'е сборки они уже падают в `default:`
(`studio_message_builder.dart:159-175`), где `messagesForKind` не находит
бакета и блок эмитит собственный контент — то есть ведут себя ровно как
`custom_text`.

### ⚠️ `group_open` / `group_close` — не трогать

Эти два значения `kind` **не** входят в список редактора: они синтезируются
машинерией группировки (`studio_preset_block_groups.dart:71`, `:176`, `:220`)
для секций-заголовков Loom-пресетов. Они структурные, а не семантические, и при
удалении `kind` их нельзя просто выбросить — иначе развалится нормализация
границ групп. Предлагается вынести их в отдельное поле
`groupBoundary: none | open | close`.

### Удаление «корзинки» из обычного пресета

`PresetBlock.isStashed` (`preset.dart:19`) удаляется вместе с UI. Потребители:
`prompt_builder.dart:277` (`if (!rawBlock.enabled || rawBlock.isStashed) continue`),
`preset_macro_attribution.dart:46`, `preset_export.dart:25`,
`silly_tavern_preset_parser.dart:99`, `preset_editor_screen.dart:377`, `:703-718`.

Отложенный в корзинку блок — это по сути выключенный блок с отдельным флагом.
Миграция: `isStashed == true` → `enabled = false`, поле удаляется. На импорте
ST-пресета `isStashed` читается и схлопывается в `enabled` там же
(`silly_tavern_preset_parser.dart:99`), чтобы чужие файлы не ломались.

### Миграция

1. `kind` → `mode` для трёх остающихся режимов; `kind` → `id` + `isStatic` для
   контекстных слотов (уже есть `normalizeBlockId`, `prompt_builder.dart:276`).
2. `section` → `injectionPoint` (переименование значения 1:1).
3. `tracker_instruction`-блоки: `injectionPoint = specificAgent`,
   `targetAgentId` проставляется разово по действующей алиас-карте
   (`studio_runtime_block_expander.dart:116-125`), после чего карта удаляется.
4. `agent_instruction`-блоки удаляются из пресетов — их содержимое уже дублирует
   конверт из §4.
5. Блоки с макросами `{{studio_<имя>_brief}}` не трогаются — макросы остаются
   рабочими (решение 13). Меняется только их реализация: перечень имён
   собирается из онтологии вместо хардкода в
   `studio_brief_macro_renderer.dart:13-16`.
6. `messagesForKind(block.kind)` → `messagesForBlockId(block.id)` —
   переименование метода, логика та же.

### Риск

Высокий по площади: затрагивает сборку промпта для **всех** агентов
(`studio_message_builder.dart:68-175`), сид-данные (`app_db.dart:1559-2255`,
~50 блоков) и экспортированные пользователями JSON. Нужны характеризационные
тесты «промпт до / промпт после» на дефолтном пресете —
`test/characterization/memory_studio_pipeline_test.dart` уже даёт каркас.

---

## 6. Удаление режимов Direct/Assisted/Legacy

### Как сейчас

`StudioExecutionMode { legacy, direct, assisted }`
(`lib/core/models/studio_config.dart:7-20`) живёт в пяти местах:

- `StudioPreset.executionMode` (`studio_config.dart:100-113`);
- `StudioActivationGate.isControllerAllowed` (`studio_activation_gate.dart:21-31`) —
  зашитые списки агентов на режим;
- `applyExecutionMode` (`:36-48`) — второй рубеж, гасит преген-агентов в рантайме;
- `prepareStudioPresetForMode` (`studio_preset_topology.dart`) — переписывает блоки;
- UI-селектор (`studio_settings_sheet.dart:281-292`, `315-364`), который вдобавок
  **подменяет пресет**: выбор режима ищет пресет с таким `executionMode`
  (`_selectStudioMode`, `:343-364`).

Одна ручка несёт три смысла: фильтр агентов, селектор пресета, мутатор блоков.

### Что предлагается

Понятие режима удаляется целиком; топология = набор включённых агентов.

- `StudioExecutionMode` и `StudioPreset.executionMode` удаляются из модели.
  В `fromJson` поле принимается и игнорируется один релиз (чтобы старые
  экспорты импортировались), затем выпиливается.
- `isControllerAllowed`, `applyExecutionMode`, `prepareStudioPresetForMode`
  удаляются. Гейт остаётся один: `enabled` + `lockedOn` для `final`.
- Селектор режима удаляется вместе со старым шитом (§8).
- Включённые агенты пишутся в пресет **явной картой** (не «отсутствует =
  включён», как сейчас в `agentEnabled`), чтобы экспорт был однозначным.

Обратная совместимость поведения не требуется (решение 8). Пресеты
`Loom Adapt v1 (direct/assisted)` после миграции становятся обычными пресетами
с разными наборами включённых агентов и остаются в списке как стартовые
профили.

### Риск

`executionMode` протекает в тесты (`test/studio_execution_mode_test.dart`,
`studio_preset_topology_test.dart`, `studio_activation_test.dart`,
`studio_3config_resolution_test.dart`) — их придётся переписать на проверку
`agentEnabled`.

---

## 7. Пресеты в экране «Пресеты»; один активный пресет

### Как сейчас — два параллельных мира

- Обычные пресеты: `PresetListScreen`, роут `/tools/presets`
  (`router.dart:201-207`), карточка `_PsCard` (`preset_list_screen.dart:246-378`)
  с иконкой `Icons.description_outlined` (`:296-308`) и бейджем токенов
  (`:325-328`). Активность — `activePresetIdProvider`.
- Агентные пресеты: выбираются в bottom sheet внутри шита студии
  (`_openStudioPresetSelector`, `studio_settings_sheet.dart:366-432`),
  редактируются в `StudioPresetEditorScreen` из Tools (`tools_screen.dart:123-132`).
  Активность — `activeStudioPresetProvider` (SharedPreferences, глобально).

При этом сегодня агентный прогон использует **оба** пресета: обычный собирает
контекст и историю (`PromptBuilder` итерирует `preset.blocks`,
`prompt_builder.dart:275`), агентный даёт блоки агентов.

### Что предлагается

**Один список, одна активность.**

Агентный пресет становится самодостаточным: по §5 он несёт те же промпт-блоки,
что и обычный (character desc, scenario, chat_history…), поэтому может занять
место обычного пресета в сборке промпта, а не дополнять его.

- В `PresetListScreen` — один список. Агентный пресет рендерится тем же
  `_PsCard`, но с иконкой `Icons.smart_toy_outlined` вместо
  `Icons.description_outlined`.
- Рядом с бейджем токенов — второй бейдж, **количество запросов**:
  `_SmallBadge(icon: Icons.bolt, label: 'N/ход')` (решение 15).
- Активация взаимоисключающая: выбор обычного пресета выключает агентный режим,
  выбор агентного — включает. Это и есть «выключение агентного режима»
  (решение 7). Отдельный тумблер `StudioConfig.enabled` больше не нужен.
- «Add / Import» получает пункты для агентного пресета (перенос
  `_createStudioPreset` / `_importPreset` из `studio_settings_sheet.dart:434-563`).

Глобальный мастер-флаг `studioFeatureEnabledProvider`
(`lib/core/state/studio_feature_provider.dart:20`, Experimental Features) —
отдельная сущность и остаётся как есть: он скрывает агентный режим целиком.

### ⚠️ Архитектурное следствие

Сегодня `PromptBuilder` принимает `Preset` (`prompt_inputs.dart:17`,
`prompt_builder.dart:275`). Чтобы агентный пресет мог быть единственным
активным, нужен один из двух путей:

- **(A) Унификация моделей** — `StudioPresetBlock` схлопывается с `PresetBlock`
  (§5 уже приводит их к одной форме), агентный пресет = `Preset` + метаданные
  агентов. `PromptBuilder` не меняется вообще.
- **(B) Обобщение `PromptBuilder`** — принимает интерфейс «источник блоков».

Рекомендуется **(A)**: она прямо следует из §5 («просто будут промпт-блоки, как
в обычном пресете») и не плодит абстракций. Тогда `StudioPreset` = `Preset`
плюс `agentEnabled` + `targetAgentId` на блоках.

Побочный эффект: слой дедупликации в бакетайзере
(`_collectStaticContextDropNames`, `studio_context_bucketizer.dart:110-137`),
который выбрасывает из статического контекста блоки, уже уехавшие в шард
агента, теряет смысл — дублирования двух пресетов больше нет. Его удаление
нужно проверить отдельно.

### Как считать количество запросов

Текущая функция `studioPresetRequestCount(preset)` оценивает целевую топологию:

```
pregen    = число батч-групп + число индивидуальных агентов
            (TrackerBatcher.groupAgents, lib/core/llm/tracker_batcher.dart:163)
final     = 1
postClean = enabled ? 2 : 0     // аудит + переписывание — два отдельных вызова
                                // (cleaner_stage.dart: аудит :568, rewrite :625)
ledger    = enabled && runMode == 'every_turn' ? 1 : 0
```

Для дефолтного пресета целевая оценка: 1 батч + 1 финал + 2 Post Clean +
1 Трекер = **`5/ход`**.

MemoryBook и ExtBlocks в счёт **не входят** (решение 15): они не агенты
пресета, живут по своим настройкам и от выбора пресета не зависят — иначе
бейдж перестанет отражать то, что пользователь этим пресетом настроил.

Это пока не точная верхняя граница: встроенные `post_clean` и `ledger` остаются
также в generic `post_processing` path `MemoryStudioService`, а затем
выполняются dedicated durable стадиями. Текущий badge не учитывает эти два
compatibility-вызова. При окончательном устранении двойного ownership формула
должна считать только один канонический путь. Кэш briefs и batching также могут
уменьшать фактическое число запросов.

---

## 8. Удаление старого шита; Recovery → Agentic Ops

Удаляется `lib/features/chat/widgets/studio_settings_sheet.dart` (1034 строки)
и точка входа `case 'studio'` в `magic_drawer.dart:541-542` + `_showStudioMenu`
(`:552-560`).

| Блок шита | Строки | Новый дом |
|---|---|---|
| Studio Enabled | `:144-149` | **удаляется** — режим = выбор пресета (§7) |
| Studio Mode | `:281-292`, `315-364` | **удаляется** (§6) |
| Studio Preset (селектор) | `:294-313`, `366-432` | Экран «Пресеты» (§7) |
| Слоты моделей + `Другой API` | `:155-211`, `656-775` | Вкладка «Агенты» в API Sheet (§9) |
| Тумблер «Пост-клинер» | `:873-894` | Агент Post Clean в списке агентов (§2) |
| Agents → `StudioAgentsSheet` | `:216-232` | Редактор агентного пресета |
| Edit Preset Blocks | `:233-249` | `StudioPresetEditorScreen` (уже существует) |
| Post-Processing context size | `:617-654` | Вкладка «Агенты» (§9) |
| **Recovery** | `:903-985`, `1006-1033` | **Agentic Ops** — пятая вкладка |

### Recovery в Agentic Ops

`AgenticOperationsLogDialog` (`lib/features/chat/widgets/agentic_operations_log_dialog.dart`)
уже session-scoped (`AgenticSessionScope`, `:105`) и имеет 4 вкладки
(`DefaultTabController(length: 4)`, `:41`): Operations, Tracker values,
Last turn, Snapshots. Recovery добавляется пятой вкладкой
(`length: 5`, `Icons.restore`) — это ровно то место, где пользователь смотрит,
что агенты насчитали, и логично оттуда же пересчитать.

Переносится содержимое `_buildRecoverySection` (`:903-985`) и `_startRecovery`
(`:1006-1033`) вместе с `recoveryStateProvider` и
`trackerMemoryRecoveryServiceProvider` — sessionId берётся из
`AgenticSessionScope` вместо конструктора.

Вкладка «Tracker values» (`AgenticTrackerValuesTab`) показывает данные Ledger,
то есть по решению 9 её название **уже верное** и остаётся: в UI Ledger
называется Трекер. Русская подпись — «Значения трекера». Переименовывается
только класс (`AgenticTrackerValuesTab` → `AgenticLedgerValuesTab`), потому что
в коде слой называется `ledger`.

### Заодно удаляется

`StudioPresetEditorSheet` (`lib/features/chat/widgets/studio_preset_editor_sheet.dart`,
348 строк) дублирует `StudioPresetEditorScreen` (252 строки) — остаётся один.
`StudioSlotSettingsDialog` (491 строка) **сохраняется** — его переиспользует
новая вкладка.

---

## 9. Вкладка «Агенты» в API Sheet — четыре слота

### Как сейчас

`ApiSettingsScreen` — две вкладки, состояние в `int _tab`
(`api_settings_screen.dart:36`), таб-бар `_buildTabBar()` (`:427-436`),
`SwipeTabSwitcher(length: 2)` (`:401-410`), скролл-контроллер выбирается
тернарником `_tab == 0 ? ... : ...` (`:391`).

Модели агентов настраиваются в шите через `_buildModelSlot`
(`studio_settings_sheet.dart:656-775`) для трёх слотов
`StudioSlot { finalGenerator, tracker, cleaner }` (`studio_slot_settings_dialog.dart:13`).

### У Ledger сегодня нет своего слота — его надо создать

Ledger ходит через слот клинера — прямо задокументировано в
`lib/core/models/ledger_settings.dart` («Model/endpoint/apiKey overrides are
removed — the ledger uses the Studio cleaner slot»). Поля `studioLedgerModel`
в коде нет: `StudioSlotResolver` упоминает его только в примере докстринга
(`studio_slot_resolver.dart:34`) — это мёртвая ссылка.

По решению 1 добавляются:

- `StudioConfig.ledgerApiConfigId` (freezed → `build_runner`);
- `LedgerSettings.studioLedgerModel`;
- `StudioSlot.ledger` в enum + ветка в `StudioSlotSettings.applyTo`
  (`studio_slot_settings_dialog.dart:50-108`);
- ветка в `AgentConfigResolver` (`lib/core/llm/studio/agent_config_resolver.dart:73-80`),
  который сейчас для `phase == 'post_processing'` безусловно берёт
  `cleaner.postCleanerModel`.

### Что предлагается

`_tab` расширяется до 3, вкладка «Агенты» (`Icons.smart_toy_outlined`),
`SwipeTabSwitcher(length: 3)`, третий скролл-контроллер (тернарник в `:391`
заменяется на `switch`).

Четыре слота, каждый — существующий `_buildModelSlot` + шестерёнка
`StudioSlotSettingsDialog`:

| Слот | Кого настраивает | Хранилище |
|---|---|---|
| **Прегенерация** | все преген-агенты (батч) | `cheapApiConfigId` + `studioAgent.studioTrackerModelOverride` → после §10 `studioControllerModelOverride` |
| **Финал** | Main Response | `expensiveApiConfigId` + `studioAgent.studioFinalModelOverride` |
| **Постпроцесс** | Post Clean (аудит + переписывание) | `cleanerApiConfigId` + `cleaner.postCleanerModel` |
| **Трекер** | Трекер (Ledger) | **новое:** `ledgerApiConfigId` + `studioLedgerModel` |

Плюс на вкладке — то, что осталось от шита: `studioPostTrackerContextSize` и
модель аудита `postCleanerAuditModel`, которая уже есть в
`cleaner_settings.dart`, но в UI не выведена.

### Миграция

`ledgerApiConfigId` / `studioLedgerModel` по умолчанию пустые → резолвятся в
слот постпроцесса, как сейчас. Поведение по умолчанию не меняется, настройка
опциональна.

---

## 10. Консолидация нейминга

### Фаза A — UI-строки и документация (безопасно)

Подписи, заголовки, тексты тумблеров; `docs/STUDIO_OVERVIEW.md` →
`docs/AGENTIC_PRESET_OVERVIEW.md`. Из текстов уходят «Loom», «Direct»,
«Assisted», «Legacy Studio», «Shard», «контроллер», «совет директоров».
Слово «трекер» в UI закрепляется за Ledger и **только** за ним: преген-агенты
в интерфейсе называются агентами.

Затрагивает `assets/translations/{en,ru}.json`; ключи вроде
`theme_preset_deleted`, переиспользуемые шитом студии
(`studio_settings_sheet.dart:614`), после удаления шита освобождаются.

### Фаза B — `tracker` → `controller` для преген-агентов

| Сейчас | Станет |
|---|---|
| `TrackerBatcher`, `TrackerBatchGroup`, `TrackerGrouping` | `ControllerBatcher`, `ControllerBatchGroup`, `ControllerGrouping` |
| `StudioTrackerPhaseRunner` | `ControllerPhaseRunner` |
| `studioTracker*` (12 полей `StudioAgentSettings`) | `studioController*` |
| `StudioSlot.tracker` | `StudioSlot.controller` |
| `studioPostTrackerContextSize` | `studioPostControllerContextSize` |
| `trackerMemoryRecoveryService` | `controllerMemoryRecoveryService` |

**Ledger в коде не переименовывается** — `StudioLedgerService`,
`LedgerSettings`, `ledger_stage.dart`, `ledger_op_applier.dart` остаются как
есть. В UI он называется «Трекер» (решение 9); слой перевода — только строки
интерфейса, не типы.

⚠️ `studioTracker*` — persisted-поля в SharedPreferences JSON
(`PipelineSettings`). Переименование требует нормализации при чтении по образцу
`_normalizeStudioAgentSettingsJson` (`studio_agent_settings.dart:113-120`).

⚠️ `tracker_rows` (`tables.dart:283`) — таблица Ledger, **не переименовывается**
(миграция схемы того не стоит), и по решению 9 её имя оказывается согласованным
с UI: она хранит данные Трекера. В коде окружающие типы приводятся к `ledger`:
`TrackerRepo` / `trackerRepoProvider` (`db_provider.dart:159`) → `LedgerRepo` /
`ledgerRepoProvider`, `AgenticTrackerValuesTab` → `AgenticLedgerValuesTab`.

### Фаза C — `Studio` → `AgenticPreset` в коде

~138 файлов, ~1365 вхождений `Studio`. Механический рефактор, но делать его до
A/B бессмысленно: §1-§6 удаляют часть сущностей. Порядок внутри фазы: модели →
сервисы → провайдеры → UI → тесты. Отдельным коммитом без функциональных
изменений, чтобы ревью было читаемым.

Часть имён уже «agentic» (`agentic_operations_log_dialog.dart`,
`memory_agentic_service.dart`) — они попадают в целевой нейминг без
переименования.

---

## 11. Ответ на вопрос: `<studio_session_state>`, Continuity и «трекер»

Вопрос из обсуждения: *«О каких continuity агентах речь и что ты понимаешь под
трекером?»* — в v1 я выразился неточно в обоих словах. По коду:

### «Трекер» — я использовал слово в двух смыслах, и это была ошибка

В первом черновике я предложил переименовать Ledger в «трекер», а потом в том
же абзаце употребил «трекер» в его нынешнем кодовом значении —
преген-контроллеры. Это ровно та путаница, которую документ и должен был
устранить.

Решения 5 и 9 разводят слои: в UI «Трекер» = Ledger и только он; в коде
преген-агенты становятся `controller`, а Ledger остаётся `ledger`. Имя таблицы
`tracker_rows` при этом попадает в целевой UI-нейминг без миграции — она и
хранит данные Трекера.

### Continuity — это один агент, а не группа

Я написал «continuity-агенты» во множественном числе; на деле речь про один
spec — `continuity` / `Continuity Controller`
(`studio_controller_ontology.dart:54-66`).

Конкретная зависимость от Ledger — в его сид-блоке `continuity_task_universal`
(`app_db.dart:1581`), где явно записано:

> `PRESENT ENTITIES ANCHOR: Before writing your brief, check the
> <studio_session_state> block for "Present now:" — these characters ARE in the
> scene.`

То есть инструкция агента напрямую требует блок, который производит Ledger.

### Что такое `<studio_session_state>` и кто его видит

Цепочка: Ledger пишет канон в `tracker_rows`
(`studio_ledger_service.dart:54`) → `compileStudioSessionState` собирает из
закоммиченных строк текстовый блок (`prompt_payload_builder.dart:343`, `:481`) →
`PromptBuilder` инжектит его в промпт (`prompt_builder.dart:686-704`), плюс он
доступен макросом `{{studio_session_state}}` (`macro_engine.dart:327`).

Важное уточнение: блок попадает **в промпт целиком**, то есть его видит и
Main Response, и преген-агенты — не только Continuity. Разница в том, что
Continuity — единственный, чьи инструкции **явно предписывают** на него
опираться.

### Что из этого следует для §2

Выключение Трекера (теперь возможное, раз он стал агентом) означает, что
`<studio_session_state>` перестаёт обновляться: блок либо исчезает, либо
застывает на последнем состоянии. Continuity при этом продолжал бы выполнять
инструкцию «сверься с Present now» по устаревшим или отсутствующим данным.

**Решение 10: выключение Трекера выключает Continuity.** Зависимость
объявляется декларативно (`requiresSpecId` в spec'е Continuity), а не хардкодом
в обработчике переключателя — детали в §2, «Зависимость: Трекер → Continuity».

Это строже, чем предупреждение: агент, чья инструкция опирается на
несуществующие данные, просто не запускается. Побочный эффект — конфигурация
«Трекер выключен, Continuity включён» становится невыразимой, в том числе при
импорте чужого пресета, где нормализация приведёт её к «оба выключены».

---

## Итоговая модель

```text
Активный пресет: либо обычный, либо агентный (взаимоисключающе)

Agentic Preset
├── Промпт-блоки (как в обычном пресете: char desc, scenario, history, …)
│   ├── «Режим»: Прямая инструкция | Pregen Brief | Ответ агента ← <агент>
│   └── «Точка инжекта»: прегенерация | финал | постпроцесс | трекер
│                        | специфический агент → <агент>
│
├── Агенты (прегенерация)          ← включаются/выключаются, пишутся в пресет
│   ├── Continuity                 ← требует Трекер
│   ├── Agency & Character
│   ├── Dialogue
│   ├── Anti-Loop & Prose Guard
│   ├── World / NPC
│   └── Meta / OOC
├── Main Response                  🔒 нельзя выключить
├── Post Clean                     ← как раньше, + Beauty внутри
└── Трекер                         ← код: ledger

Слоты моделей (API Sheet → Агенты):
  Прегенерация | Финал | Постпроцесс | Трекер

У каждого агента:
  • неизменяемое имя + фиксированные инструкции (кто / полоса / как выводить) — read-only
  • промпт-блоки пресета, адресованные ему точкой инжекта
```

Убрано: режимы Direct/Assisted/Legacy, Beauty Shard, Narrative Controller,
`kind` из 16 значений, `tracker_instruction`, `agent_instruction`, секции
`build` и `brief_parser` (5 мёртвых блоков), «корзинка», шит студии, пять
эвристик матчинга по имени агента, второй параллельный список пресетов.

---

## Порядок работ

Таблица ниже сохраняет исходный порядок зависимостей. Фазы 1-5 и большая часть
фаз 6-9 уже реализованы; оставшиеся пункты — удаление `isStashed`, устранение
двойного ownership `post_clean`/`ledger`, перенос Recovery, завершение
унификации preset model и нейминга. Legacy `build`/`brief_parser` уже
фильтруются миграцией/нормализацией, а их seed payload сохраняется только для
исторических апгрейдов. Для
каждого нового изменения нужны отдельный коммит, focused tests, полный
`flutter test` и `build_runner` после изменений generated models или Drift.

| Фаза | Статус | Содержание | Зависит от |
|---|---|---|---|
| 1 | Выполнено | §4: `specId` + идентичность в spec'ах, backfill, удаление эвристик 1 и 3 | — |
| 2 | Выполнено | §3: `lockedOn` для `final`, `isFinal`-first в split, удаление Narrative | 1 |
| 3 | Выполнено | §1: Beauty внутрь Post Clean, захват состояния отвязан от постпроцесса, миграция пресетов | 1 |
| 4 | Выполнено | §2: `post_clean` и `ledger` как агенты, `phase: post_processing`, `requiresSpecId` | 2, 3 |
| 5 | Выполнено | §6: удаление `StudioExecutionMode` + миграция в `agentEnabled` | 4 |
| 6 | Частично | §5: новая block model и cleanup legacy sections реализованы; остаётся `isStashed` | 5 |
| 7 | Выполнено | §9: вкладка «Агенты» + отдельный слот Ledger | 4 |
| 8 | Частично | §7: preset UI и badge реализованы; estimate неточен до устранения двойного post-processing ownership, полная унификация model ещё не завершена | 6, 7 |
| 9 | Частично | §8: старые sheets удалены; Recovery ещё нужно перенести пятой вкладкой в Agentic Ops | 7, 8 |
| 10 | Не начато | §10 фазы A→B→C: полный нейминг `Studio -> AgenticPreset` | 9 |

Исторический список предполагаемых тестов больше не является картой файлов.
Для каждого оставшегося изменения сначала ищутся текущие tests по затронутым
symbols; обязательный regression gate включает существующие Studio ontology,
config resolution, preset DB, Ledger, migration и pipeline suites.

---

## Открытые вопросы

Нет — все развилки закрыты решениями 1-16. Документ готов к разбивке на задачи
по таблице «Порядок работ».
