# Known Bugs — 83 карточки, по которым не хватает инфы

Снято с доски `GlazeFlutter` → **Known Bugs**, только карточки с лейблом **Audited**.
Из 156 исключены:

- **22** карточки с галочкой (`dueComplete` — считаю решёнными, список в конце);
- **43** карточки, по которым инфы достаточно (группы G1–G24 в `KNOWN_BUGS_TRIAGE.md`);
- **8** карточек, закрытых без изменений кода (там же).

Остаётся **83**. Ниже — по одной строке на карточку: что понял DeepSeek-агент из кода
(если понял) и что мне нужно от тебя. Отвечай как удобно, хоть подряд:
`#12 — jar это JanitorAI, нужен прокси для картинок` — этого достаточно.

`[фича?]` — по формулировке похоже на change request, а не на дефект. По твоему решению
такие идут отдельным списком, а не в бранчи, — но подтвердить надо тебе.

---

## Пустые «gui»-карточки

- **#3 memory books gui** — описания нет. Это задача «перевести на Glaze UI kit» (как уже сделано в `30d9ec56` / PR #408) или конкретный дефект? Если первое — карточку можно закрывать. # сделано
- **#4 extblocks gui** — то же: редизайн на UI kit или баг? # редизайн
- **#5 lorebooks gui** — то же. # редизайн сделан

## Ссылки без текста

- **#7** `https://t.me/c/3873909202/6945` — вставь текст сообщения или скажи «выкинуть».
- **#8** `https://t.me/c/3873909202/6946` — то же.
- **#23 nightsyr mention** — карточка пустая. Что репортил nightsyr?
- **#42** `janitorai.com/.../character-twilight-saga-rpg` — что с этой картой не так (импорт, лорбук, рендер)?

## Чат: пустой / не грузится

Похоже на одну группу — подтверди, и я сведу их в один бранч.

- **#87 chat blank on first open** — платформа? Каждый раз после запуска или иногда? Пусто всё или только область сообщений (хедер и composer видны)?
- **#155 first chat open is blank** — дубль #87 или другое? Есть ли диалог с ошибкой?
- **#129 empty chat** — дубль этих двух, или «в чате нет сообщений, гритинг не пришёл»?
- **#154 regex not working on first chat open** — агент нашёл конкретную причину: инициализатор WebView читает async-провайдер display-регексов через `valueOrNull`, поэтому на первом открытии список пустой и это запекается в рендер. Речь про «Alter Display»-регексы (display-time), или про prompt-time?
- **#109 Chats not loading** — iOS, `Chat WebView JS bridge did not initialize within 30s`, воспроизводилось эпизодически и репортер не смог поймать. Живо ли ещё на актуальном nightly?

## Удаления и гонки

- **#2 new chat broken when deleting older chat** — обычный repro в коде уже защищён (cache epoch, репарация `currentSessionIndex`, инвалидация провайдеров). Остаётся узкая гонка: мутация сообщения в полёте на удалённой сессии докатывается и воскрешает строку через `ChatRepo.put`. Воспроизводится ли ещё?
- **#75 optimistic delete with swipes** — баг или фича? Это тот же сюжет, что #2/#78?
- **#78 deleting races** — какие именно гонки: удаление сессий, сообщений, свайпов? Дубль #2/#75?

## Пресеты и папки

- **#25 preset images** — что с картинками пресетов: не показываются, не сохраняются, не импортируются?
- **#46 hide presets that are in folder** — на верхнем уровне экрана Presets это **уже** работает (папочные пресеты отфильтрованы). Где они всё ещё видны — в пикере пресетов из чата, в Studio, внутри папки?
- **#47 imported presets are not visible until a reboot** — агент нашёл дыру: Studio/agentic-импорт (`StudioPresetWorkflowService.importPreset`) пишет в БД и не инвалидирует `studioPresetListProvider`; у restore из бэкапа и cloud sync та же проблема. Какой путь импорта ты использовал — обычный JSON, Studio, restore или sync?
- **#48 folders in usual presets** `[фича?]` — баг (папки не показываются) или фича (разложить сидовые пресеты по папкам)?
- **#72 stick preset filters to header** `[фича?]` — какие «preset filters» и на каком экране?
- **#79 folder navigation presets** — баг или фича? Что с навигацией по папкам ломается?
- **#88 stashed preset blocks** — что «stashed» и что именно блокируется (сохранение, применение, список)?

## Лорбуки и JAR

- **#12 no proxy for jar** — что такое «jar» (JanitorAI? домен в URL картинок? файл?) и какой прокси нужен — для картинок, для API, приватный?
- **#43 separate advanced and simple closed lorebooks in jar** `[фича?]` — сейчас JAR-извлечение мержит всё найденное в один лорбук `{name} — Closed Lorebook`. Хочешь разделять advanced (JS/Nine-API) и simple (JSON) на два отдельных лорбука?
- **#58 JAR background extraction** — что такое «background extraction»: извлечение в фоне (без UI) или извлечение картинки-фона? Что ломается?
- **#60 prompt blocks tab when using jar** — что за jar и что происходит с табом Prompt Blocks?
- **#69 janitor custom tags** — кастомные теги при импорте, при фильтрации в Discover, при редактировании?
- **#83 jai jar losing credentials and 502** — «jai jar» это JanitorAI + JAR-извлечение? Какие креды теряются (сессия Janitor, API-ключ) и на каком запросе прилетает 502?
- **#84 lorebook ui rework (lorebook coverage and triggered items)** `[фича?]` — что редизайн должен исправить: неверный процент coverage, отсутствующие записи в triggered items, или это чисто UI-задача?
- **#125 Lorebook entries being triggered even when the keywords are not present** — твоя гипотеза («Estella» матчит ключ «Estella's mother») кодом не подтверждается: матчинг односторонний, ключ должен встретиться в тексте, не наоборот. Реальные подозреваемые — окно сканирования (последние N сообщений, не только текущее), рекурсивное сканирование и sticky/cooldown. Нужно: какой глобальный search type (Keys / Vector / Both), стоит ли на записи sticky/cooldown, и ~10 сообщений перед тем, где она сработала.
- **#135 check lorebook settings when importing st** — агент нашёл конкретное: импортированные ST-книги получают `settings: null`, у записей `caseSensitive`/`matchWholeWords` прибиты в false, а экспортёр вообще не сериализует `Lorebook.settings` — то есть per-book настройки не выживают ни импорт, ни round-trip Glaze→ST→Glaze. Это оно?

## Память (Memory Books / Summary)

- **#138 trigger type dropdown in memory books doesn't open** — контрола с подписью «Trigger type» в коде нет. Ближайшие кандидаты: «Search Type» на обзоре Memory Books (это `MenuSelectorItem`, он переключается тапом по кругу Keys→Vector→Both, а не открывает меню) и несколько настоящих `DropdownButton` в настройках лорбуков. Как контрол подписан на экране и что происходит при тапе — вообще ничего или меню открывается и сразу закрывается?
- **#142 tapping memory section in header acrolls chat** — в хедере чата memory-секции нет: там только аватар, имя, имя сессии и поиск. Memory живёт в `MemorySheet`, в MEM-бейджах на сообщениях и в плавающей `ContextCoverageCard`. Что именно ты тапаешь и куда скроллит чат?
- **#148 memory sheet flickering** — что мигает: весь шит, подсветка табов, карточки списка, спиннер? На какой табе (Summary / Memory Books) и когда — при открытии, при переключении таба, во время стрима ответа, во время генерации драфтов?
- **#71 summary with protocols** — что такое «protocols» в этом контексте и что ломается в summary?

## Prompt Inspector

- **#49 prompt inspector sab** — «sab» это человек (репортер/ассайни) или сокращение? Что с инспектором не так?

## API и подключения

- **#51 connections choosing** — какой экран выбора (bindings пресетов, bindings лорбуков, что-то ещё) и что ломается: пустой список, не выбирается, не скроллится, крэш?
- **#86 connection preset not applying, check persona** — тут три разные подсистемы с похожими названиями: API-пресет (`ApiConfig`), промпт-пресет (`Preset` с `presetConnections`) и персона (`Persona` с `personaConnections`). Какой экран, что выбрал, что применилось вместо этого? И что значит подсказка «check persona»?
- **#77 openrouter specific settings steal from st** `[фича?]` — тайтл выглядит обрезанным. Что такое «st» (SillyTavern? streaming? пресет с таким именем?) и что «украсть» — какие поля?
- **#128 405 Naistera** — на каком действии прилетает 405 (чат, image gen, test connection) и какой endpoint настроен?
- **#130 decouple embedding settings from api settings** `[фича?]` — расцепление уже почти сделано: embedding-пресеты живут в своём списке, со своим active id, миграцией, отдельной табой Embeddings и экраном `/tools/embeddings`. Какая связка осталась — «Use LLM API» endpoint borrow, поля embedding на модели `ApiConfig`, общая таблица `api_configs`, или таба внутри экрана API?

## Онбординг

Все три ниже агент нашёл **уже реализованными** в `onboarding_screen.dart`, поэтому по каждой: это дефект или change request?

- **#80 start with API** — онбординг должен начинаться со слайда API?
- **#28 shino as default** `[фича?]` — сделать пресет Shino (`default_shino`) дефолтным вместо `Default Chat`? Для свежих установок, существующих, или обоих?

## Уведомления, батарея, фон

- **#1 background generation** — карточка говорит «перепроверить работает ли генерация сообщений в фоне». В коде всё подключено: `GenerationPipeline.run` берёт foreground-lease, стартует `flutter_foreground_task` dataSync с wake lock, манифест декларирует сервис и разрешения. Так работает или нет, и на каком девайсе/ОС ломается?
- **#9 notifications** — карточка перечисляет три вещи: (1) уведомления о новых сообщениях не приходят совсем, (2) увед «generating» залипает, (3) перенести из Vue открытие чата по тапу. Все три в коде **реализованы** (`sendMessageNotification` в post-generation pipeline, ref-counted лизы на foreground service, `_openChatFromNotification` + `scrollToMessage`). Какой девайс/ОС (MIUI/HyperOS? код их уже отдельно обрабатывает), выдано ли разрешение на уведомления, и какой из трёх пунктов ещё живой?
- **#29 notifications dialog** — какой диалог: строка Settings → General → Notifications (открывает системные настройки), одноразовый запрос battery-optimization, системный запрос разрешения? И что с ним — не появляется, крэш, неверный текст?
- **#30 battery dialog** — тот же вопрос про диалог исключения из battery optimization: не появляется, появляется каждый раз, не запоминает ответ?
- **#53 battery saver on system battery saver** `[фича?]` — включать Glaze Battery Saver автоматически, когда включён системный энергосберегающий режим? Или это баг — что-то ломается под системным battery saver?
- **#52 instantly show timer on no animation** — агент прочитал так: в режиме «Battery saver UI» (анимации выключены) `GenTimer` рисует первый тик только через секунду, поэтому бейдж таймера появляется с задержкой вместо мгновенного 0s. Это оно?

## Скролл и поиск

- **#67 add a toggle for scroll on edit** `[фича?]` — какое поведение тоглить: автоскроллить к редактируемому сообщению, или наоборот не скроллить вниз при правке?
- **#68 scroll with touchpad on pc** — тачпад не скроллит вообще, слишком медленно, слишком быстро, не в ту сторону? Где — в чате (WebView) или в нативных списках? Какая ОС?
- **#73 search on pc** — какой поиск (в чате, по чатам, по персонажам) и что с ним на десктопе?
- **#74 search for models** — где поиск моделей (пикер модели в чате, список моделей провайдера) и что ломается — пусто, крэш, неверные результаты?

## Варианты и свайпы

- **#27 variations of a character** — баг или фича? «Варианты персонажа» это несколько версий одной карточки, или свайпы сообщений?
- **#62 dynamic swipe for segmented control tabs** `[фича?]` — сейчас свайп по табам снапит на одну табу по завершении жеста (`resolveSwipeTarget`). Хочешь, чтобы выбор следовал за пальцем во время драга? Или свайп вообще не работает на каком-то конкретном экране?
- **#151 no variants on branching** — branch копирует срез сообщений дословно, вместе с `swipes`/`swipesMeta`. Что пропадает после branch: стрелки 1/N на перенесённых сообщениях, или возможность генерить новые варианты внутри бранча?

## Импорт и бэкапы

- **#31 pc backup import** — что происходит при импорте бэкапа на ПК: диалог с ошибкой, крэш, тихий отказ, часть данных? Какой формат файла и откуда он?
- **#32 backup file pick** — системный пикер не открывается, не показывает нужные файлы, файл выбирается но ничего не происходит, или ошибка?
- **#76 gdrive sync** — это дубль #107 (Google Drive → `401 invalid_client`, ревокнутый OAuth-клиент, группа G6), или отдельный сценарий?

## Каталог

- **#10 handle idiots on datacat** — что именно «idiots» делают на DataCat и что приложение должно делать в ответ (рейт-лимит, понятная ошибка, блок-лист)?
- **#140 JanitorAI session expires** — в коде есть точное совпадение по формулировке: `JanitorAuthException` («Janitor.AI session expired (401)»). Это дубль #152 (Janitor browse/search 401, группа G4), или отдельный сценарий — например форс-релогин после перезапуска приложения?
- **#63 updates checking for characters** — это про апдейт-чекер приложения (который уже в группе G15) или про обновления импортированных карточек персонажей из каталога?

## Extblocks / Studio

- **#133 protocols and error handling in extblocks** — что за protocols и какая обработка ошибок падает: неразобранный ответ, необработанное исключение, неверная ошибка пользователю?

## UI-мелочи — по строчке на каждую

- **#11 image on nonimage modal** — какая модалка показывает лишнюю картинку и что это за картинка (аватар, вложение, битый плейсхолдер)?
- **#15 editing padding** — padding при редактировании сообщения: слишком большой, слишком маленький, съехал? Где — textarea внутри бабла, кнопки Save/Cancel, или composer снизу?
- **#16 keyboard padding jump** — что прыгает (input bar, список сообщений, drawer, весь экран) и когда (открытие клавиатуры, закрытие, переключение на magic drawer)?
- **#39 post a message when action is started/denied** `[фича?]` — какое «action» (отправка, regenerate, continue, slash-команда, действие расширения, системное разрешение) и что значит «post a message» — вставить системное сообщение в чат, показать тост, или push?
- **#44 for open advanced show "convert button"** — где находится «Advanced» и что значит «open»? Что должна конвертировать кнопка?
- **#50 magic drawer loading** — что с загрузкой magic drawer: вечный спиннер, пустое/устаревшее состояние, крэш, не открывается?
- **#54 webview background opacity** — что не той прозрачности: сплошной белый/серый блок вместо фона чата, прозрачность фоновой картинки, glass-оверлеи хедера/инпута, `elementOpacity`? На какой платформе?
- **#55 only Flutter background** — какой экран показывает «только фон Flutter»: запуск/домашний, чат, настройки? Пустой весь UI или одна область? Зависит ли от кастомной фоновой картинки и настроек bg-blur/bg-dim?
- **#56 change loading spinner** `[фича?]` — какой спиннер и где (старт, стрим, выбор модели, настройки)? Что с ним не так и на что менять?
- **#57 greetings naming in character sheet** — неверная подпись поля, гритинги отображаются под неправильным именем, или импортированный гритинг переименовывается?
- **#59 long names in characters** — где видно (сетка My Characters, detail sheet, редактор, хедер чата) и что происходит: обрезается, перекрывается, overflow-ошибка, не сохраняется?
- **#70 adding quick actions** + **#82 adding quick actions** — две карточки с одинаковым названием, подтверди что это дубль. Что именно: quick actions отсутствуют на каком-то экране, не работают, или это запрос на новую фичу?
- **#85 show connected persona in quick access** `[фича?]` — где именно показывать и что такое «connected persona» (персона чата или аккаунт провайдера)?
- **#143 image.png** — скриншот экрана «Изменить Персонаж» → «Дополнительные настройки». Единственный дефект, который агент видит на картинке — жёстко зашитый английский placeholder `Injected at a specific depth in the prompt` в полностью русском UI. Это оно, или проблема в том, что значения Depth не применяются?
- **#156 change text color** — баг (текст нечитаемый, не тот цвет) или фича (дать настройку цвета текста)? Какой экран и какая тема?

## Документация

- **#146 describe tokenizer differences in glossary** `[docs]` — написать статью в глоссарий про разницу между локальной оценкой Glaze (`o200k_base`), токенизатором конкретного провайдера и фоллбэком ~4 символа/токен? Новый термин или расширение существующей статьи «Token»? Нужна ли русская версия?

## Прочее

- **#6 guided** — карточка: «починить гайдед, перенести функционал из вуе». Агент проверил: Guided Generation подключён end-to-end (тоггл в composer, проброс через send/regenerate/impersonate, блок `guided_generation`, макрос `{{guidance}}`, guided-свайп в JS). Единственный проверяемый по коду пробел против Vue — в редакторе пресетов нет UI для правки Guided-промптов. Это и есть задача, или сломано что-то ещё?
- **#114 Weird Search Behavior** — только скриншот, репортер отказался дать файл чата, симптом так и не описан. Помнишь, что там было, или выкидываем карточку?
- **#81 make feedback setting based on system setting and let it disable in settings** `[фича?]` — агент прочитал «feedback» как хаптику: `AppSettings` уже несёт `hapticFeedback` и `messageVibration` (оба по умолчанию true), есть центральный гейт `Haptics` и группа настроек «Input & feedback». Единственный пробел против тайтла — на Android app-level тоггла хаптики намеренно нет, хаптика всегда срабатывает и доверяет системной настройке. Задача — добавить этот тоггл на Android?

---

## Исключены как решённые (галочка / `dueComplete`)

Если какая-то из них на самом деле не решена — скажи, верну в работу.

| # | Карточка |
|---|---|
| 13 | testers |
| 14 | read mark |
| 17 | markdown image control |
| 18 | repo url in about |
| 19 | wire API settings in onboarding |
| 20 | select persona from onboarding |
| 21 | bubbles in onboarding not setting |
| 22 | `files.kammii.org/tACftoO2qI.webp` |
| 26 | edit button square |
| 34 | even height magic drawr |
| 35 | prompt inspector i18n |
| 36 | load multiple presets and lorebooks |
| 37 | pill for idle button |
| 38 | sorting as an icon |
| 40 | variation header |
| 41 | icons in bottom sheet |
| 64 | variation switching not instant |
| 65 | hide dev settings |
| 66 | system prompt from st |
| 144 | prompt inspector — no groups when single request and design |
| 145 | response in prompt inspector |
| 147 | ignore virtual scroll when searching and selecting |

**Важно:** #145 «response in prompt inspector» помечена решённой, но #153 «response in
prompt inspection doesn't work, shows "no captured"» — нет, а это та же проблема, и она
реально живая в коде: у главного запроса нет `callId`, поэтому таба Response никогда не
получает call-event. Оставил #153 в группе G14, #145 выкинул как дубль.
