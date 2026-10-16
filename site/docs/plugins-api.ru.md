Всё, что делает плагин, идёт через глобальный объект `glaze`. Методы, которые обращаются к приложению, возвращают Promise; несколько локальных (`glaze.plugin`, `glaze.ui.insets`, `glaze.variables.peek`, `glaze.files.url`) отвечают сразу.

В объекте есть только методы, разрешения для которых просит манифест. Id сообщений, чатов, персонажей и остального — непрозрачные строки: не собирайте их сами.

## Ошибки

Неудачный вызов завершается ошибкой `Error` с полями `code` и `message`:

| `code` | Когда |
|---|---|
| `permission_denied` | Разрешение выключено или пользователь отказал. |
| `invalid_arguments` | Неверные или недостающие аргументы. |
| `not_found` | Нет такого сообщения, чата, файла и т. п. |
| `no_chat` | Для вызова нужен открытый чат. |
| `busy` | Чат занят (например, идёт генерация) и сейчас не может принять изменение. |
| `timeout` | Вызов длился слишком долго. |
| `too_large`, `quota_exceeded` | Превышен лимит размера. |
| `network_error` | Запрос не удался. |
| `no_connection` | В Glaze не настроено подключение к API. |
| `generation_failed` | Генерация не удалась. |
| `unknown_preset` | В манифесте нет настройки `apiPreset`/`imagePreset` нужного вида с таким `preset`. |
| `unavailable` | Здесь недоступно (например, нет поля ввода). |
| `conflict`, `read_only`, `invalid_file`, `import_failed`, `unknown_command` | Бывают у отдельных методов; в `message` сказано, что не так. |

## glaze.plugin

Доступен всегда.

| Поле | Что это |
|---|---|
| `id` | Id плагина. |
| `kind` | Вид фрейма: `main`, `panel`, `message` или `file`. |
| `panelId`, `messageId` | Id панели; сообщение панели сообщения. Иначе `null`. |
| `on(name, handler)` | Подписаться на хук, событие или сообщение из других фреймов плагина. Возвращает функцию отписки. См. [Хуки, действия и панели](#info/plugins-runtime). |
| `emit(name, detail)` | Отправить сообщение в другие фреймы плагина. |
| `onComposerAction(id, fn)`, `onToolsAction(id, fn)`, `onMessageAction(id, fn)` | Обработчики действий из манифеста. Только в основном скрипте. |
| `registerFileHandler(id, { extract })` | Зарегистрировать обработчик файлов. |
| `settings.get(key)`, `settings.all()` | Значения настроек плагина. |
| `i18n` | Переводы, если в манифесте есть `locales`. |

`glaze.plugin.i18n`:

```js
const { t, locale } = glaze.plugin.i18n;
t('toast.count', { count: 5 });             // "Сообщений в чате: 5"
glaze.plugin.i18n.onChange(() => redraw()); // пользователь сменил язык приложения
```

`t(key, params)` подставляет в `{name}` значения из `params`. Ещё есть `locale` (выбранный язык), `requestedLocale` (язык приложения), `defaultLocale`, `supportedLocales`.

## glaze.ui

Разрешений не нужно. Окна и уведомления подписаны именем плагина.

| Метод | Возвращает | Что делает |
|---|---|---|
| `toast(text)` | | Показывает короткое уведомление. |
| `select(options, title?, defaultValue?)` | значение или `null` | Список для выбора. |
| `ask({ question, options?, allowOther?, placeholder?, defaultValue? })` | `{ status, answer?, source? }` | Вопрос с вариантами ответа и/или полем для текста. |
| `openUrl(url)` | | Открывает http(s)-ссылку в браузере. |
| `preview(source)` | | Открывает картинку на весь экран: data URL, http(s)-ссылка, путь к файлу плагина или base64. |
| `insets()` | `{ topSafe, topBar, bottomInput, bottomSafe }` | Размеры элементов приложения поверх чата, в пикселях. |
| `onInsetsChanged(fn)` | функция отписки | Вызывается, когда они меняются. |

Вариант — строка или `{ value, label, description? }`. `ask` возвращает `{ status: 'answered', answer, source: 'option' | 'custom' }` или `{ status: 'cancelled' }`. Если не передать `allowOther: false`, пользователь может ещё и написать свой ответ.

```js
const r = await glaze.ui.ask({
  question: 'Как отреагирует персонаж?',
  options: ['Рассмеётся', 'Разозлится'],
  placeholder: 'Или опишите сами',
});
if (r.status === 'answered') glaze.composer.append(r.answer);
```

## glaze.app

| Метод | Возвращает |
|---|---|
| `version()` | Версию приложения, например `"0.9.0"`. |
| `versionNumber()` | Версию числом: `0.9.0` — это `900`, `1.2.3` — `10203`. |

## glaze.composer

Нужно `composer`.

| Метод | Возвращает | Что делает |
|---|---|---|
| `get()` | строку | Текст в поле ввода. |
| `set(text)` | | Заменяет его. |
| `append(text)` | | Дописывает в конец. |
| `clear()` | | Очищает. |
| `send()` | `{ ok, text, reason? }` | Отправляет то, что в поле, как кнопка «Отправить». |

## glaze.messages

Нужно `messages`. Работает с открытым чатом.

| Метод | Возвращает |
|---|---|
| `list(range?, filter?)` | Массив сообщений. `range`: индекс или `[start, end]`, отрицательные считаются с конца (`[-10, -1]` — последние десять). `filter`: `{ role?, hidden? }`. |
| `get(id)` или `get({ index })` | Сообщение или `null`. |
| `count()` | Число сообщений. |
| `current()` | Сообщение панели сообщения. |
| `add({ content, role?, hidden? })` | Id нового сообщения. `role`: `assistant` (по умолчанию) или `user`. Ответ не запускает. |
| `edit({ id, content?, reasoning?, hidden? })` | Id. Меняет показанный вариант. |
| `remove(id)` | Id. |

Сообщение:

```js
{
  id: 'm1a2b3',
  index: 4,                 // место в чате
  role: 'assistant',        // 'user' | 'assistant' | 'system'
  content: '...',
  hidden: false,            // скрыто от модели
  characterId: '...',       // у сообщений персонажа
  personaId: '...',         // у сообщений пользователя, если известна
  reasoning: '...',         // если модель рассуждала
  timestamp: 1760000000000,
  variantCount: 3,          // число вариантов (свайпов)
  variant: 0,               // какой показан
  attachmentCount: 1        // если есть вложения
}
```

### Варианты

`glaze.messages.variants` работает с альтернативными ответами сообщения (свайпами). Id варианта — его номер в списке.

| Метод | Возвращает |
|---|---|
| `list(messageId)` | Варианты, которые сейчас не показаны: `[{ id, content, reasoning? }]`. |
| `add(messageId, { content, reasoning? }, { select? })` | Id нового варианта. Он показывается, если не передать `select: false`. |
| `edit(messageId, { id, content?, reasoning? })` | Id. Показанный вариант меняется через `messages.edit`. |
| `remove(messageId, id)` | Id. Показанный вариант удалить нельзя. |
| `select(messageId, id)` | Id. Показывает этот вариант. |

## glaze.chats

Чат здесь — один чат с одним персонажем; его id не меняется.

| Метод | Возвращает | Нужно |
|---|---|---|
| `current()` | Открытый чат или `null`. | `messages` |
| `get(id)` | Чат или `null`. | `messages` для открытого, `chats.read` для остальных |
| `find({ name?, match?, characterId? })` | Чаты, кратко: `{ id, characterId, index, name, messageCount, updatedAt, current }`. | `chats.read` |
| `open(id)` | Id. Открывает чат. | `chats.read` |
| `create({ characterId?, name? })` | Id нового чата. По умолчанию с персонажем открытого чата. | `chats.create` |
| `update({ id?, name?, persona?, preset?, lorebooks? })` | Id. Без `id` — открытый чат. | `messages`; `chats.update` для остальных |
| `copy(id)` | Id копии. | `chats.create` и чтение этого чата |
| `remove(id)` | Id. | `chats.delete` |
| `export(id?)` | Описание файла (см. `glaze.files`): чат в `.jsonl` в файлах плагина. | `files` и чтение этого чата |
| `inspectImport(path)` | `{ messageCount, userName }` файла `.jsonl`. | `files` |
| `import(path, { characterId? })` | Id нового чата. | `files`, `chats.create` |

Чтение чата требует `messages` для открытого и `chats.read` для любого другого. `persona` и `preset` в `update` принимают id (или `null`, чтобы сбросить); `lorebooks` — массив id. `match` в `find`: `exact` (по умолчанию), `prefix`, `suffix`, `contains`.

Чат:

```js
{
  id: '...', characterId: '...', index: 2, name: 'Вечерняя прогулка',
  characters: [{ id, name, avatar }],
  persona: { id, name } | null,
  preset: { id, name } | null,
  lorebooks: [{ id, name }],
  messageCount: 42, updatedAt: 1760000000, current: true
}
```

## glaze.memory

Книга памяти открытого чата. Нужно `messages`.

| Метод | Возвращает |
|---|---|
| `get()` | `{ enabled, entries: [{ id, title, content, keys, status }] }` |
| `append(entry)` или `append([entries])` | `{ added: [id], total, enabled }`. Запись — строка или `{ title?, content, keys? }`. |
| `update({ enabled?, entries? })` | Включает или выключает книгу; заменяет список записей. Записи с известным `id` обновляются, остальные добавляются. |

## glaze.variables

Данные, которые плагин хранит между запусками. Нужно `variables`; для области `shared` — `variables.shared`. Значение — любой JSON. Имя может быть путём по вложенным объектам: `stats.hp`.

| Метод | Возвращает |
|---|---|
| `get(name, scope?)` | Значение или `null`. |
| `set(name, value, scope?)` | Записывает значение. |
| `update(name, value, scope?)` | Объединяет объект с сохранённым (на один уровень вглубь); другие значения заменяются. |
| `delete(name, scope?)` | `true`, если было что удалять. |
| `list(scope?)` | Все переменные области одним объектом. |
| `peek(name?, scope?)` | Сразу, без ожидания: последнее известное значение. Только `chat` и `global`. |

| Область | Где хранится |
|---|---|
| `'chat'` (по умолчанию) | В открытом чате. Удаляется вместе с чатом. |
| `'global'` | Во всех чатах. |
| `{ scope: 'message', id }` | В одном сообщении; удаляется вместе с ним. В панели сообщения достаточно `'message'`. |
| `'shared'` | Общая для всех плагинов. |

У каждого плагина свои переменные; чужие плагины видят только `shared`. Лимиты: 1 МБ на чат или сообщение, 16 МБ на `global` и на `shared`.

```js
await glaze.variables.update('stats', { hp: 10 });
const hp = glaze.variables.peek('stats.hp');
```

## glaze.files

Собственные файлы плагина. Нужно `files`. Каждый файл лежит в одной из трёх областей:

| Область | Что это |
|---|---|
| `chat` (по умолчанию) | Файлы открытого чата; удаляются вместе с чатом. |
| `global` | Файлы плагина. |
| `tmp` | Временные; очищаются при запуске приложения. |

Путь к файлу выглядит как `files/global/notes.txt`. Методы, которые принимают имя, принимают и такой путь.

| Метод | Возвращает |
|---|---|
| `save(name, content, { scope?, encoding? })` | Путь. |
| `load(name, { scope?, encoding? })` | Содержимое или `null`. |
| `exists(name, { scope? })` | `true` / `false`. |
| `remove(name, { scope? })` | |
| `list({ scope?, limit?, cursor? })` | `{ files: [file], nextCursor? }`, до 200 за раз. |
| `pick({ multiple?, extensions?, scope?, conflict? })` | Файлы, которые выбрал пользователь, скопированные в файлы плагина: `[file]` с `originalName`. `conflict`: `rename` (по умолчанию), `overwrite`, `error`. |
| `share(path)` или `share(name, content, { encoding? })` | Открывает системное окно «Поделиться» или «Сохранить». |
| `dataUrl(path)` | `data:` URL файла. |
| `url(name, scope?)` | Путь к файлу, сразу (не проверяет, есть ли он). |

`file` — это `{ path, name, size, mimeType, modifiedAt }`.

`content` в `save` — строка или массив байтов. Строка сохраняется как текст, если `encoding` не `base64` и не `dataUrl`; строка с `data:` URL декодируется, а http(s)-ссылка скачивается (по правилам доступа плагина в интернет). `load` возвращает текст, а с `encoding` — `base64`, `dataUrl` или `bytes`.

Лимиты: 32 МБ на файл, 256 МБ на все файлы плагина.

## glaze.generate

`glaze.generate(prompt, options?)` один раз обращается к модели через подключение к API открытого чата и возвращает текст ответа. Нужно `generate`.

| Параметр | Что делает |
|---|---|
| `preset` | `key` настройки `apiPreset`: запрос идёт через подключение и модель, выбранные пользователем для этой функции ([Пресеты API](#info/plugins-manifest/пресеты-api)). Не выбрано — подключение чата. |
| `system` | Системный промпт. |
| `context: true` | Ставит перед промптом последние 40 видимых сообщений чата. Нужно также `messages`. |
| `settings: { temperature?, maxTokens? }` | Переопределяет настройки подключения. |
| `timeout` | В миллисекундах; по умолчанию 5 минут. |

```js
const summary = await glaze.generate('Перескажи разговор одним предложением.', {
  context: true,
  settings: { maxTokens: 200 },
});
```

Запрос идёт без стриминга и в чате не появляется; его видно в инспекторе промпта.

## glaze.images

`glaze.images.generate(prompt, options?)` генерирует картинку по настройкам генерации изображений пользователя. Нужно `images`, которое каждый раз спрашивает пользователя, если он не разрешил его насовсем.

| Параметр | Что делает |
|---|---|
| `preset` | `key` настройки `imagePreset`: сервис картинок и стиль, выбранные пользователем для этих картинок ([Пресеты API](#info/plugins-manifest/пресеты-api)). |
| `character`, `persona` | `false` не передаёт аватар и внешность этого человека. По умолчанию оба уходят референсами, поэтому для картинки, где нет персонажа или пользователя, передайте `false`. |
| `aspectRatio`, `size` | Передаются генератору, если он их поддерживает. |
| `timeout` | В миллисекундах. |
| `saveAs`, `scope` | Сохранить в файлы плагина под этим именем (нужно `files`). |

Возвращает `data:` URL картинки, а с `saveAs` — её путь. Неудачная генерация завершается ошибкой с кодом ответа и сообщением провайдера.

## glaze.net

`glaze.net.fetch(input, init?)` работает как `fetch`, но запрос отправляет приложение. Нужно `network`; действуют [правила доступа плагина в интернет](#info/plugins-permissions/сеть).

```js
const res = await glaze.net.fetch('https://api.example.com/v1/items', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
  body: JSON.stringify({ q: 'hello' }),
  timeout: 30000,
});
const data = await res.json();
```

Чем отличается от `fetch`:

- Правила CORS сайта не действуют.
- Cookies не отправляются и не принимаются. Заголовки, которые ставит само приложение (`Cookie`, `Host`, `Origin`, `Referer`, `Sec-*`, `Proxy-*`), игнорируются.
- При перенаправлении на другой сайт `Authorization` отбрасывается.
- Ответ приходит целиком, а не потоком; до 32 МБ в обе стороны.
- `init.timeout` — в миллисекундах, до 10 минут. `signal` (`AbortController`) работает.

## glaze.commands

`glaze.commands.run(script)` выполняет простые слеш-команды. Команды разделяются ` | `, а результат каждой доступен следующей как `{{pipe}}`. Возвращает последний результат.

| Команда | Что делает | Нужно |
|---|---|---|
| `/send текст` | Добавляет сообщение пользователя (ответ не запускает). | `messages` |
| `/sendas текст` | Добавляет сообщение персонажа. | `messages` |
| `/trigger` | Запускает ответ. | `generate` |
| `/gen промпт` | Как `glaze.generate`. | `generate` |
| `/echo текст` | Показывает уведомление. | |
| `/setvar key=имя значение`, `/getvar имя`, `/flushvar имя` | Переменные чата. | `variables` |

```js
await glaze.commands.run('/gen Придумай название таверны | /sendas Таверна называется {{pipe}}');
```

## Библиотека

Одинаковый набор методов для каждого вида объектов библиотеки. Каждому нужно соответствующее разрешение: `library.read.characters`, чтобы читать персонажей, `library.update.presets`, чтобы менять пресеты, и так далее. Добавление, изменение и удаление спрашивают пользователя.

| Объект | Вид |
|---|---|
| `glaze.characters` | `characters` |
| `glaze.personas` | `personas` |
| `glaze.presets` | `presets` |
| `glaze.lorebooks` | `lorebooks` |
| `glaze.regex` | `regex` |
| `glaze.themes` | `themes` |

| Метод | Возвращает | Разрешение |
|---|---|---|
| `list()` | Краткий список: `{ id, name, ... }`. | `read` |
| `get(id)` | Объект или `null`. | `read` |
| `find(name, { match? })` | Объекты, чьё имя подходит; `match` как в `chats.find`. | `read` |
| `create(data)` | Новый id. `name` обязательно. | `create` |
| `update({ id, ...поля })` | Id. Меняются только переданные поля. | `update` |
| `remove(id)` | Id. | `delete` |
| `import(source)` | Новый id. `source` — объект или путь к JSON-файлу в файлах плагина (нужно ещё `files`). | `create` |
| `export(id, { format? })` | `format: 'object'` возвращает объект; иначе пишет файл в файлы плагина и возвращает его описание (нужно `files`). | `read` |

Дополнительные методы:

| Метод | Что делает | Разрешение |
|---|---|---|
| `characters.current()` | Персонаж открытого чата. | `read` |
| `lorebooks.coverage()` | Какие записи лорбуков открытый чат положит в промпт и почему (см. ниже). Нужно также `messages`. | `read` |
| `characters.import(source)` | Принимает карточку (объект) или файл карточки `.png`/`.json`. Возвращает `{ characterId, lorebookId }`. | `create` |
| `characters.export(id, { format })` | `json` (по умолчанию) или `png` пишут файл карточки в файлы плагина (нужно `files`); `object` возвращает карточку. | `read` |
| `personas.current()` | Персона открытого чата. | `read` |
| `personas.setDefault(id)`, `presets.setDefault(id)` | Сделать основной. | `update` |
| `themes.current()`, `themes.apply(id)` | Текущая тема; переключиться на другую. | `read`; `update` |
| `themes.assets.list(id)`, `load(id, name, { encoding? })` | Картинки и другие файлы темы. | `read` |
| `themes.assets.save(id, name, content, { encoding? })`, `rename(id, name, newName)`, `remove(id, name)` | Изменить их. Встроенные темы менять нельзя. | `update` |

Персонаж:

```js
{
  id, name, displayName, avatar,
  description, personality, scenario, appearance,
  firstMessage, alternateGreetings: [], exampleMessages,
  systemPrompt, postHistoryInstructions,
  creator, creatorNotes, tags: [], version, macroName,
  createdAt, updatedAt
}
```

`lorebooks.coverage()` — тот же разбор чата, что показывает инспектор промпта, поэтому он всегда совпадает с тем, что получает модель:

```js
{
  entries: [{
    id, comment, content, position, order, lorebookId, lorebookName,
    constant, activated,          // activated: ключи совпали (или запись постоянная)
    matchedKeys: [], matchedSecondaryKeys: [], matchMessageIndex,
    cutOff,                       // null, 'budget' (общий лимит) или 'bookLimit' (лимит её лорбука)
    recursionPass,                // 1 или больше, если запись включил текст другой записи
    stickyHeld, onCooldown
  }],
  totalCandidates, activatedCount, cutOffCount, injectedCount, inactiveCount,
  settings: { ...настройки лорбуков, entryCap }
}
```

Запись с `probability` ниже 100% показывается так, будто у неё 100%, чтобы ответ не менялся от вызова к вызову. Нужна Glaze 0.9.0 (Nightly).

Персона: `{ id, name, displayName, description, avatar, active }`. Пресеты, лорбуки, regex-скрипты и темы приходят в том виде, в каком их хранит Glaze; `import` принимает также пресеты, лорбуки и regex-скрипты SillyTavern.
