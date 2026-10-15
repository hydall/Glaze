## Frames

All plugin code runs in sandboxed frames inside the chat, each with its own empty origin. A plugin has several kinds of frames:

| Frame | What runs there | `glaze.plugin.kind` |
|---|---|---|
| Main | The `main` script. Invisible. Registers hooks, actions and file handlers. | `main` |
| Chat panel | The HTML of a panel with `placement: "chat"`. | `panel` |
| Message panel | The HTML of a panel with `placement: "message"`, one frame per message. | `message` |
| File handler | The `scripts` of a file handler, while it works on a file. | `file` |

Frames are created when a chat opens and recreated when plugins are installed, switched on or off, when the user changes a plugin's settings or switches one of its permissions off. Anything kept only in a JavaScript variable is lost then: store what matters in [variables](#info/plugins-api/glaze-variables), files or `localStorage`.

What works in a frame:

- `localStorage`: per plugin, kept by the app, up to 10 MB. Other browser storage (cookies, IndexedDB, `sessionStorage`) is not available.
- Network requests, within the plugin's [internet rules](#info/plugins-permissions/network).
- `console.log`: in the WebView's console when debugging.

The main script is one file: bundle your code into it if it is split into modules.

## Hooks

Hooks let the plugin take part in sending and generation. Only the main script can register them, with `glaze.plugin.on(name, handler)`; `on` returns a function that removes the handler.

| Hook | When | What it can do | Needs |
|---|---|---|---|
| `send:before` | The user sends a message, before it goes into the chat. | Change `event.text`; call `event.cancel(reason)` to stop the send. The reason is shown to the user. | `composer` |
| `generation:prepare` | A reply is being generated, before the prompt is built. | Change `event.text`, the last user message as the model will see it. The chat itself is not changed. | `generate` |
| `generation:success` | The reply is ready, before it is saved. | Change `event.text`, the reply. It can't be made empty. | `generate` |

```js
glaze.plugin.on('generation:prepare', async (event) => {
  const note = await glaze.variables.get('note');
  if (note) event.text += `\n\n(${note})`;
});
```

A handler may be `async`. Handlers run one after another, each one sees the text after the previous ones. If a handler throws, its changes are dropped. `send:before` and `generation:success` handlers have 5 seconds; `generation:prepare` handlers have no limit of their own, but keep them quick: the reply waits for them.

Every event also has `type`, `chatId`, `source` (what started it) and `at` (the time, ISO 8601); the generation hooks have `generationId`.

## Events

Events tell the plugin what happened; they can't change anything. The main script and panels can listen to them.

| Event | When | Fields | Needs |
|---|---|---|---|
| `send:after` | A message was sent. | `text`, `source` | `composer` |
| `generation:error` | Generation failed. | `generationId`, `error` | `generate` |
| `generation:cancelled` | The user stopped the generation. | `generationId` | `generate` |
| `chat:opened` | A chat was opened. | `chat` | `messages` |
| `chat:updated` | The chat's name, persona, preset or lorebooks changed. | `chat` | `messages` |
| `chat:closed` | The chat was left. | | `messages` |
| `message:added` | A message appeared. | `message`, `change` | `messages` |
| `message:updated` | A message was edited, or another variant was picked. | `message`, `change` | `messages` |
| `message:deleted` | A message was deleted. | `message` (only `id`), `change` | `messages` |
| `message:changed` | Any of the three above. | as above | `messages` |

All events have `chatId` and `at`. The shapes of `chat` and `message` are in the [API reference](#info/plugins-api/glaze-messages).

```js
glaze.plugin.on('message:added', ({ message }) => {
  if (message.role === 'assistant') console.log('New reply', message.id);
});
```

## Actions

The handlers for the actions listed in the manifest are registered by the main script:

```js
glaze.plugin.onComposerAction('tone', async () => {
  const text = await glaze.composer.get();
  const answer = await glaze.ui.select(['Formal', 'Casual'], 'Tone');
  if (!answer) return;
  await glaze.composer.set(await glaze.generate(`Rewrite in a ${answer} tone:\n${text}`));
});

glaze.plugin.onToolsAction('count', async () => { /* ... */ });

glaze.plugin.onMessageAction('rate', async ({ chatId, messageId, role }) => { /* ... */ });
```

If the handler throws, the user sees that the action failed, with the error's message. If there is no handler for the action, the user is told so too.

## Messages between frames

A plugin's frames can talk to each other: `glaze.plugin.emit(name, detail)` delivers `detail` to the plugin's other frames, which listen with `glaze.plugin.on(name, handler)`. Any name that is not a hook or event above is a plugin's own. `detail` must be JSON.

```js
// panel
glaze.plugin.emit('mood:set', { mood: 'happy' });

// main script
glaze.plugin.on('mood:set', ({ mood }) => glaze.variables.set('mood', mood));
```

Other plugins don't receive these messages. To share data between plugins, use the `shared` variables.

## Panels

A **chat panel** covers the whole chat page, but only what it draws takes taps; everything else passes through to the chat. Keep the page background transparent and place elements with `position: fixed`.

The chat has the app's controls over it: the status bar, the header, the message box. Their sizes are in CSS variables and in `glaze.ui.insets()`:

| Variable | `insets()` | What it is |
|---|---|---|
| `--glaze-inset-top-safe` | `topSafe` | Status bar. |
| `--glaze-inset-top-bar` | `topBar` | Where content may start at the top. For now the same as the status bar: panels draw over the app's header. |
| `--glaze-inset-bottom-input` | `bottomInput` | Message box (and the keyboard, when it is open). |
| `--glaze-inset-bottom-safe` | `bottomSafe` | System gesture area. |

```css
.hud {
  position: fixed;
  right: 12px;
  bottom: calc(var(--glaze-inset-bottom-input) + 12px);
}
```

What a panel draws shows over the app's controls too. Small fixed elements, such as floating buttons, are moved back between the status bar and the message box if they end up behind them (after a drag, for example).

A **message panel** sits inside the message, before or after its text (`slot`). Its height follows its content. `glaze.plugin.messageId` is the message's id, and the `message` scope of variables refers to it by default.

### Package files in a panel

A frame has no address of its own, so relative paths don't work. Refer to the package's files as `/plugins/<plugin id>/<path>`; Glaze builds them into the page:

```html
<link rel="stylesheet" href="/plugins/example.mood/style.css">
<script src="/plugins/example.mood/panel.js"></script>
<img src="/plugins/example.mood/images/smile.png">
```

The plugin's own files (`glaze.files`) can be used in `src`, `href` and `poster` by their path, e.g. `<img src="files/chat/portrait.png">`. This needs the `files` permission.

## File handlers

A handler from `fileHandlers` in the manifest is registered in code with the same `id`:

```js
glaze.plugin.registerFileHandler('docx', {
  async extract(file, { signal }) {
    // file: { path, name, mimeType, size }
    const base64 = await glaze.files.load(file.path, { encoding: 'base64' });
    return { content: convertToText(base64) };
  },
});
```

When the user attaches a file of that type, Glaze puts it into the plugin's `files/tmp` and calls `extract`, which returns the text for the message. Reading the file needs the `files` permission. A handler that can't read this particular file throws an error with `code: 'unsupported_format'`, and Glaze tries the next handler. A handler has 10 minutes.
