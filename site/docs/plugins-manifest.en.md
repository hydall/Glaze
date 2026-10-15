`plugin.json` sits at the root of the package and describes the plugin: what it is called, what it asks for and where it shows up. Glaze checks it on import and refuses a package with an invalid manifest or a missing file it refers to.

## Top-level fields

| Field | Required | What it is |
|---|---|---|
| `format` | yes | Manifest format version. Currently `1`. |
| `id` | yes | Unique id: lowercase letters, digits, `.`, `_`, `-`, up to 128 characters, e.g. `author.plugin-name`. Don't change it between versions: updates are matched by `id`. |
| `name` | yes | Name shown to the user. Text or a translation key. |
| `version` | yes | Version in SemVer: `1.0.0`, `1.2.0-beta.1`. |
| `author` | no | Author. An update from a different author is installed as a separate plugin. |
| `description` | no | Short description. Text or a translation key. |
| `releaseNotes` | no | What changed in this version; shown on the plugin's page. |
| `icon` | no | Path to an image in the package, shown as the cover on the plugin's page. |
| `main` | no | Path to the main script. Required if the plugin has actions. |
| `permissions` | no | What the plugin asks for. See [Permissions and network](#docs/plugins-permissions). |
| `hosts` | no | Internet hosts the plugin needs: `api.example.com` or `*.example.com`. |
| `locales` | no | Translation files, see below. |
| `minGlazeVersion` | no | Lowest Glaze version the plugin is written for. Glaze does not check it yet. |
| `contributes` | no | What the plugin adds to the interface: actions, panels, file handlers, settings. |

## Translatable text

Wherever the manifest takes user-facing text (`name`, `description`, action labels, settings), you can write a string or a key into the translation files:

```json
"name": { "t": "plugin.name" }
```

Translations are listed in `locales`:

```json
"locales": {
  "default": "en",
  "files": {
    "en": "locales/en.json",
    "ru": "locales/ru.json"
  }
}
```

A translation file is a flat object of keys and strings:

```json
{
  "plugin.name": "Message counter",
  "action.count": "Count messages",
  "toast.count": "Messages in this chat: {count}"
}
```

Glaze picks the user's interface language, then another variant of the same language, then English, then `default`. If a key is missing everywhere, the key itself is shown. The same files are available in code through `glaze.plugin.i18n` (see the [API reference](#docs/plugins-api/glaze-plugin)).

## Actions

Actions are buttons the plugin adds to the chat. Each has an `id` (unique within its list), a `label` and, optionally, an `icon` (a path in the package).

```json
"contributes": {
  "composerActions": [{ "id": "tone", "label": "Change tone" }],
  "toolsActions": [{ "id": "count", "label": "Count messages" }],
  "messageActions": [{ "id": "rate", "label": "Rate", "icon": "icons/star.svg", "role": "character" }]
}
```

| List | Where it shows |
|---|---|
| `composerActions` | The Actions tab of the chat drawer, which opens from the message box. |
| `toolsActions` | The Tools tab of the same drawer. |
| `messageActions` | A round button in the footer of the last message. `role`: `character` (default), `user` or `any`, whose message it appears on. Without an icon the button shows the first letter of the label. |

A tap runs the handler the main script registered for that `id`; see [Hooks, actions and panels](#docs/plugins-runtime/actions).

## Panels

A panel is an HTML page of the plugin shown in the chat.

```json
"panels": [
  { "id": "hud", "src": "hud.html", "placement": "chat" },
  { "id": "stats", "src": "stats.html", "placement": "message", "role": "character", "position": "last", "slot": "end" }
]
```

| Field | What it is |
|---|---|
| `id` | Panel id. |
| `src` | Path to the panel's HTML in the package. |
| `placement` | `chat`: over the whole chat; `message`: inside messages. |
| `slot` | `start` or `end` (default): before or after the content. |
| `role` | Message panels: only in `user` or only in `character` messages. |
| `position` | Message panels: only in the `first` or only in the `last` message. |

How panels are laid out and how they load package files: [Hooks, actions and panels](#docs/plugins-runtime/panels).

## File handlers

A file handler turns an attached file into text for the message. For example, it can pull the text out of a `.docx` or a `.pdf`.

```json
"fileHandlers": [
  { "id": "docx", "extensions": ["docx"], "mimeTypes": [], "scripts": ["docx.js"] }
]
```

`extensions` (without the dot) and `mimeTypes` say which files it takes; at least one is required. `scripts` are loaded only to run this handler; if the list is empty, the handler is registered by the main script. Registering in code: [Hooks, actions and panels](#docs/plugins-runtime/file-handlers).

## Settings

`settings` describes a form on the plugin's page in **Tools → Plugins**. Glaze draws it, stores the values and passes them to the plugin. Fields are shown in the order they are listed.

```json
"settings": [
  { "type": "toggle", "key": "enabled", "label": "Enabled", "default": true },
  { "type": "select", "key": "mode", "label": "Mode", "default": "short",
    "options": [{ "value": "short", "label": "Short" }, { "value": "long", "label": "Long" }] },
  { "type": "slider", "key": "count", "label": "Count", "min": 1, "max": 10, "step": 1, "default": 3 },
  { "type": "text", "key": "name", "label": "Name", "description": "Shown in replies" },
  { "type": "textarea", "key": "prompt", "label": "Prompt" },
  { "type": "note", "text": "Changes apply the next time the chat opens.", "icon": "info" },
  { "type": "divider" }
]
```

| `type` | Fields |
|---|---|
| `toggle` | `key`, `label`, `description`, `default` (true/false). |
| `select` | `key`, `label`, `description`, `default`, `options`: strings or `{ value, label }`. |
| `slider` | `key`, `label`, `description`, `default`, `min`, `max`, `step`. |
| `text`, `textarea` | `key`, `label`, `description`, `default`. |
| `note` | `text`, `icon`: `info` or `warning`. A note, stores nothing. |
| `divider`, `group` | Splits the form. |

`label`, `description`, `text`, option labels and text defaults can be translation keys. The values are read with `glaze.plugin.settings.get(key)`. When the user changes a setting, the plugin's frames restart with the new values.

## A full example

```json
{
  "format": 1,
  "id": "example.mood",
  "name": { "t": "plugin.name" },
  "version": "1.2.0",
  "author": "you",
  "description": { "t": "plugin.description" },
  "icon": "icon.png",
  "main": "main.js",
  "permissions": ["messages", "variables", "generate", "network"],
  "hosts": ["api.example.com"],
  "locales": {
    "default": "en",
    "files": { "en": "locales/en.json", "ru": "locales/ru.json" }
  },
  "contributes": {
    "toolsActions": [{ "id": "reset", "label": { "t": "action.reset" } }],
    "panels": [{ "id": "mood", "src": "mood.html", "placement": "message", "role": "character", "position": "last" }],
    "settings": [
      { "type": "toggle", "key": "auto", "label": { "t": "settings.auto" }, "default": true }
    ]
  }
}
```
