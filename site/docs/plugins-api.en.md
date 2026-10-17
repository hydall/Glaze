Everything a plugin does goes through the global `glaze` object. Methods that talk to the app return a Promise; a few local ones (`glaze.plugin`, `glaze.ui.insets`, `glaze.variables.peek`, `glaze.files.url`) answer right away.

The object holds only the methods whose permissions the manifest asks for. Ids of messages, chats, characters and the rest are opaque strings: don't build them yourself.

## Errors

A failed call rejects with an `Error` with a `code` and a `message`:

| `code` | When |
|---|---|
| `permission_denied` | The permission is off, or the user said no. |
| `invalid_arguments` | Wrong or missing arguments. |
| `not_found` | No such message, chat, file, etc. |
| `no_chat` | The call needs an open chat. |
| `busy` | The chat is busy (for example, generating) and can't take the change now. |
| `timeout` | The call took too long. |
| `too_large`, `quota_exceeded` | Over a size limit. |
| `network_error` | The request failed. |
| `no_connection` | No API connection is set up in Glaze. |
| `generation_failed` | Generation failed. |
| `unknown_preset` | `preset` names no `apiPreset`/`imagePreset` setting of the right kind in the manifest. |
| `unavailable` | Not available here (for example, no message box). |
| `conflict`, `read_only`, `invalid_file`, `import_failed`, `unknown_command` | Specific to a few methods; `message` says what went wrong. |

## glaze.plugin

Always available.

| Member | What it is |
|---|---|
| `id` | The plugin's id. |
| `kind` | The frame: `main`, `panel`, `message` or `file`. |
| `panelId`, `messageId` | The panel's id; the message of a message panel. Otherwise `null`. |
| `on(name, handler)` | Subscribe to a hook, an event or a message from the plugin's other frames. Returns a function that unsubscribes. See [Hooks, actions and panels](#info/plugins-runtime). |
| `emit(name, detail)` | Send a message to the plugin's other frames. |
| `onComposerAction(id, fn)`, `onToolsAction(id, fn)`, `onMessageAction(id, fn)` | Handle the manifest's actions. Main script only. |
| `registerFileHandler(id, { extract })` | Register a file handler. |
| `settings.get(key)`, `settings.all()` | The values of the plugin's settings. |
| `i18n` | Translations, if the manifest has `locales`. |

`glaze.plugin.i18n`:

```js
const { t, locale } = glaze.plugin.i18n;
t('toast.count', { count: 5 });          // "Messages in this chat: 5"
glaze.plugin.i18n.onChange(() => redraw()); // the user changed the app's language
```

`t(key, params)` replaces `{name}` with values from `params`. Also available: `locale` (the language used), `requestedLocale` (the app's language), `defaultLocale`, `supportedLocales`.

## glaze.ui

No permission needed. Sheets and notices are signed with the plugin's name.

| Method | Returns | What it does |
|---|---|---|
| `toast(text)` | | Shows a short notice. |
| `select(options, title?, defaultValue?)` | value or `null` | A list to pick from. |
| `ask({ question, options?, allowOther?, placeholder?, defaultValue? })` | `{ status, answer?, source? }` | A question with answer options and/or a text field. |
| `openUrl(url)` | | Opens an http(s) link in the browser. |
| `preview(source)` | | Opens an image full screen: a data URL, an http(s) link, a plugin file path or base64. |
| `insets()` | `{ topSafe, topBar, bottomInput, bottomSafe, keyboard }` | Sizes of the app's controls over the chat, in pixels. |
| `onInsetsChanged(fn)` | unsubscribe function | Called when they change. |

An option is a string or `{ value, label, description? }`. `ask` returns `{ status: 'answered', answer, source: 'option' | 'custom' }` or `{ status: 'cancelled' }`. Without `allowOther: false` the user can also type their own answer.

```js
const r = await glaze.ui.ask({
  question: 'How should the character react?',
  options: ['Laugh', 'Get angry'],
  placeholder: 'Or describe it yourself',
});
if (r.status === 'answered') glaze.composer.append(r.answer);
```

## glaze.app

| Method | Returns |
|---|---|
| `version()` | The app's version, e.g. `"0.9.0"`. |
| `versionNumber()` | The version as a number: `0.9.0` is `900`, `1.2.3` is `10203`. |

## glaze.composer

Needs `composer`.

| Method | Returns | What it does |
|---|---|---|
| `get()` | string | The text in the message box. |
| `set(text)` | | Replaces it. |
| `append(text)` | | Adds to the end. |
| `clear()` | | Clears it. |
| `send()` | `{ ok, text, reason? }` | Sends what is in the box, as the user's Send button does. |

## glaze.messages

Needs `messages`. Works with the open chat.

| Method | Returns |
|---|---|
| `list(range?, filter?)` | Array of messages. `range`: an index or `[start, end]`, negative counts from the end (`[-10, -1]` is the last ten). `filter`: `{ role?, hidden? }`. |
| `get(id)` or `get({ index })` | A message or `null`. |
| `count()` | The number of messages. |
| `current()` | The message of a message panel. |
| `add({ content, role?, hidden? })` | The new message's id. `role`: `assistant` (default) or `user`. Doesn't start a reply. |
| `edit({ id, content?, reasoning?, hidden? })` | The id. Changes the shown variant. |
| `remove(id)` | The id. |

A message:

```js
{
  id: 'm1a2b3',
  index: 4,                 // position in the chat
  role: 'assistant',        // 'user' | 'assistant' | 'system'
  content: '...',
  hidden: false,            // hidden from the model
  characterId: '...',       // the character's messages
  personaId: '...',         // the user's messages, if known
  reasoning: '...',         // if the model reasoned
  timestamp: 1760000000000,
  variantCount: 3,          // number of variants (swipes)
  variant: 0,               // which one is shown
  attachmentCount: 1        // if there are attachments
}
```

### Variants

`glaze.messages.variants` works with a message's alternative replies (swipes). A variant's id is its position in the list.

| Method | Returns |
|---|---|
| `list(messageId)` | The variants not shown now: `[{ id, content, reasoning? }]`. |
| `add(messageId, { content, reasoning? }, { select? })` | The new variant's id. It is shown unless `select: false`. |
| `edit(messageId, { id, content?, reasoning? })` | The id. The shown variant is changed with `messages.edit`. |
| `remove(messageId, id)` | The id. The shown variant can't be removed. |
| `select(messageId, id)` | The id. Shows that variant. |

## glaze.chats

A chat here is one chat with one character; its id doesn't change.

| Method | Returns | Needs |
|---|---|---|
| `current()` | The open chat or `null`. | `messages` |
| `get(id)` | A chat or `null`. | `messages` for the open one, `chats.read` for others |
| `find({ name?, match?, characterId? })` | Chats, briefly: `{ id, characterId, index, name, messageCount, updatedAt, current }`. | `chats.read` |
| `open(id)` | The id. Opens the chat. | `chats.read` |
| `create({ characterId?, name? })` | The new chat's id. By default with the open chat's character. | `chats.create` |
| `update({ id?, name?, persona?, preset?, lorebooks? })` | The id. Without `id`, the open chat. | `messages`; `chats.update` for others |
| `copy(id)` | The copy's id. | `chats.create`, and reading that chat |
| `remove(id)` | The id. | `chats.delete` |
| `export(id?)` | A file description (see `glaze.files`): the chat as `.jsonl` in the plugin's files. | `files`, and reading that chat |
| `inspectImport(path)` | `{ messageCount, userName }` of a `.jsonl` file. | `files` |
| `import(path, { characterId? })` | The new chat's id. | `files`, `chats.create` |

Reading a chat needs `messages` for the open one and `chats.read` for any other. `persona` and `preset` in `update` take an id (or `null` to reset); `lorebooks` takes an array of ids. `match` in `find`: `exact` (default), `prefix`, `suffix`, `contains`.

A chat:

```js
{
  id: '...', characterId: '...', index: 2, name: 'Evening walk',
  characters: [{ id, name, avatar }],
  persona: { id, name } | null,
  preset: { id, name } | null,
  lorebooks: [{ id, name }],
  messageCount: 42, updatedAt: 1760000000, current: true
}
```

## glaze.memory

The open chat's memory book. Needs `messages`.

| Method | Returns |
|---|---|
| `get()` | `{ enabled, entries: [{ id, title, content, keys, status }] }` |
| `append(entry)` or `append([entries])` | `{ added: [ids], total, enabled }`. An entry is a string or `{ title?, content, keys? }`. |
| `update({ enabled?, entries? })` | Turns the book on or off; replaces the list of entries. Entries with a known `id` are updated, others are added. |

## glaze.variables

Data the plugin keeps between runs. Needs `variables`; the `shared` scope needs `variables.shared`. A value is any JSON. A name can be a path through nested objects: `stats.hp`.

| Method | Returns |
|---|---|
| `get(name, scope?)` | The value or `null`. |
| `set(name, value, scope?)` | Writes the value. |
| `update(name, value, scope?)` | Merges an object into the stored one (one level deep); other values are replaced. |
| `delete(name, scope?)` | `true` if there was something to delete. |
| `list(scope?)` | All variables of the scope as an object. |
| `peek(name?, scope?)` | Right away, without waiting: the last known value. Only `chat` and `global`. |

| Scope | Where it lives |
|---|---|
| `'chat'` (default) | The open chat. Goes away with the chat. |
| `'global'` | All chats. |
| `{ scope: 'message', id }` | One message; goes away with it. In a message panel `'message'` is enough. |
| `'shared'` | Shared by all plugins. |

Every plugin has its own variables; other plugins see only `shared`. Limits: 1 MB per chat or message, 16 MB for `global` and for `shared`.

```js
await glaze.variables.update('stats', { hp: 10 });
const hp = glaze.variables.peek('stats.hp');
```

## glaze.files

The plugin's own files. Needs `files`. Every file is in one of three scopes:

| Scope | What it is |
|---|---|
| `chat` (default) | Files of the open chat; deleted with the chat. |
| `global` | Files of the plugin. |
| `tmp` | Temporary; cleared when the app starts. |

A file's path looks like `files/global/notes.txt`. Methods that take a name also take such a path.

| Method | Returns |
|---|---|
| `save(name, content, { scope?, encoding? })` | The path. |
| `load(name, { scope?, encoding? })` | The content or `null`. |
| `exists(name, { scope? })` | `true` / `false`. |
| `remove(name, { scope? })` | |
| `list({ scope?, limit?, cursor? })` | `{ files: [file], nextCursor? }`, up to 200 at a time. |
| `pick({ multiple?, extensions?, scope?, conflict? })` | The files the user picked, copied into the plugin's files: `[file]` with `originalName`. `conflict`: `rename` (default), `overwrite`, `error`. |
| `share(path)` or `share(name, content, { encoding? })` | Opens the system "share" or "save" dialog. |
| `dataUrl(path)` | A `data:` URL of the file. |
| `url(name, scope?)` | The path of a file, right away (doesn't check it exists). |

`file` is `{ path, name, size, mimeType, modifiedAt }`.

`content` in `save` is a string or an array of bytes. A string is saved as text, unless `encoding` is `base64` or `dataUrl`; a string that is a `data:` URL is decoded, and an http(s) link is downloaded (by the plugin's internet rules). `load` returns text, or `base64`, `dataUrl` or `bytes` with that `encoding`.

Limits: 32 MB per file, 256 MB for all the plugin's files.

## glaze.generate

`glaze.generate(prompt, options?)` asks the model once, with the API connection of the open chat, and returns the reply text. Needs `generate`.

| Option | What it does |
|---|---|
| `preset` | The `key` of an `apiPreset` setting: runs on the connection and model the user picked for that feature ([API presets](#info/plugins-manifest/api-presets)). Unset, the chat's connection. |
| `system` | A system prompt. |
| `context: true` | Puts the chat's last 40 visible messages before the prompt. Also needs `messages`. |
| `settings: { temperature?, maxTokens? }` | Overrides the connection's settings. |
| `timeout` | In milliseconds; 5 minutes by default. |

```js
const summary = await glaze.generate('Sum up the conversation in one sentence.', {
  context: true,
  settings: { maxTokens: 200 },
});
```

The request is not streamed and doesn't appear in the chat; it is in the Prompt Inspector.

## glaze.images

`glaze.images.generate(prompt, options?)` generates an image with the user's image generation settings. Needs `images`, which asks the user every time unless they allowed it for good.

| Option | What it does |
|---|---|
| `preset` | The `key` of an `imagePreset` setting: the image service and style the user picked for these images ([API presets](#info/plugins-manifest/api-presets)). |
| `character`, `persona` | `false` leaves that person's avatar and appearance out of the request. By default both go along as references, so pass `false` for a picture the character or the user is not in. |
| `aspectRatio`, `size` | Passed to the generator, if it supports them. |
| `timeout` | In milliseconds. |
| `saveAs`, `scope` | Save into the plugin's files under this name (needs `files`). |

Returns a `data:` URL of the image, or its path with `saveAs`. A failed generation rejects with the provider's status and message.

## glaze.net

`glaze.net.fetch(input, init?)` works like `fetch`, but the request is sent by the app. Needs `network`; follows the plugin's [internet rules](#info/plugins-permissions/network).

```js
const res = await glaze.net.fetch('https://api.example.com/v1/items', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
  body: JSON.stringify({ q: 'hello' }),
  timeout: 30000,
});
const data = await res.json();
```

How it differs from `fetch`:

- The site's CORS rules don't apply.
- No cookies are sent or received. Headers the app sets itself (`Cookie`, `Host`, `Origin`, `Referer`, `Sec-*`, `Proxy-*`) are ignored.
- On a redirect to another site `Authorization` is dropped.
- The response comes in full, not as a stream; up to 32 MB both ways.
- `init.timeout` is in milliseconds, up to 10 minutes. `signal` (`AbortController`) works.

## glaze.commands

`glaze.commands.run(script)` runs simple slash commands. Commands are separated by ` | `, and each one's result is available to the next as `{{pipe}}`. Returns the last result.

| Command | What it does | Needs |
|---|---|---|
| `/send text` | Adds a user message (doesn't start a reply). | `messages` |
| `/sendas text` | Adds a character message. | `messages` |
| `/trigger` | Starts a reply. | `generate` |
| `/gen prompt` | Like `glaze.generate`. | `generate` |
| `/echo text` | Shows a notice. | |
| `/setvar key=name value`, `/getvar name`, `/flushvar name` | Chat variables. | `variables` |

```js
await glaze.commands.run('/gen Make up a name for a tavern | /sendas The tavern is called {{pipe}}');
```

## Library

The same set of methods for every kind of library item. Each needs the matching permission: `library.read.characters` to read characters, `library.update.presets` to change presets, and so on. Adding, changing and deleting ask the user.

| Object | Kind |
|---|---|
| `glaze.characters` | `characters` |
| `glaze.personas` | `personas` |
| `glaze.presets` | `presets` |
| `glaze.lorebooks` | `lorebooks` |
| `glaze.regex` | `regex` |
| `glaze.themes` | `themes` |

| Method | Returns | Permission |
|---|---|---|
| `list()` | Brief list: `{ id, name, ... }`. | `read` |
| `get(id)` | The item or `null`. | `read` |
| `find(name, { match? })` | Items whose name matches; `match` as in `chats.find`. | `read` |
| `create(data)` | The new id. `name` is required. | `create` |
| `update({ id, ...fields })` | The id. Only the given fields change. | `update` |
| `remove(id)` | The id. | `delete` |
| `import(source)` | The new id. `source` is an object or the path of a JSON file in the plugin's files (also needs `files`). | `create` |
| `export(id, { format? })` | `format: 'object'` returns the object; otherwise writes a file into the plugin's files and returns its description (needs `files`). | `read` |

Extra methods:

| Method | What it does | Permission |
|---|---|---|
| `characters.current()` | The open chat's character. | `read` |
| `lorebooks.coverage()` | Which lorebook entries the open chat will put into the prompt, and why (see below). Also needs `messages`. | `read` |
| `characters.import(source)` | Takes a card (object) or a `.png`/`.json` card file. Returns `{ characterId, lorebookId }`. | `create` |
| `characters.export(id, { format })` | `json` (default) or `png` write a card file into the plugin's files (needs `files`); `object` returns the card. | `read` |
| `personas.current()` | The persona of the open chat. | `read` |
| `personas.setDefault(id)`, `presets.setDefault(id)` | Make it the default. | `update` |
| `themes.current()`, `themes.apply(id)` | The current theme; switch to another. | `read`; `update` |
| `themes.assets.list(id)`, `load(id, name, { encoding? })` | A theme's images and other files. | `read` |
| `themes.assets.save(id, name, content, { encoding? })`, `rename(id, name, newName)`, `remove(id, name)` | Change them. Built-in themes can't be changed. | `update` |

A character:

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

`lorebooks.coverage()` is the same reading of the chat that the Prompt Inspector shows, so it always agrees with what the model gets:

```js
{
  entries: [{
    id, comment, content, position, order, lorebookId, lorebookName,
    constant, activated,          // activated: its keys matched (or it is constant)
    matchedKeys: [], matchedSecondaryKeys: [], matchMessageIndex,
    cutOff,                       // null, 'budget' (the global limit) or 'bookLimit' (its book's limit)
    recursionPass,                // 1, or more if another entry's text activated it
    stickyHeld, onCooldown
  }],
  totalCandidates, activatedCount, cutOffCount, injectedCount, inactiveCount,
  settings: { ...lorebook settings, entryCap }
}
```

An entry with a `probability` below 100% is reported as if it were 100%, so the answer doesn't change between calls. Needs Glaze 0.9.0 (Nightly).

A persona: `{ id, name, displayName, description, avatar, active }`. Presets, lorebooks, regex scripts and themes come in the form Glaze stores them in; `import` also takes SillyTavern's presets, lorebooks and regex scripts.
