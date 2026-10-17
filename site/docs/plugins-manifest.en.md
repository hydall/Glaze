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
| `icon` | no | Path to an image in the package: the cover of the Info tab on the plugin's page, filling the screen behind the name and description. |
| `main` | no | Path to the main script. Required if the plugin has actions. |
| `permissions` | no | What the plugin asks for. See [Permissions and network](#info/plugins-permissions). |
| `hosts` | no | Internet hosts the plugin needs: `api.example.com` or `*.example.com`, each a string or `{ "host", "description" }`. See [Network](#info/plugins-permissions/network). |
| `locales` | no | Translation files, see below. |
| `minGlazeVersion` | no | Lowest Glaze version the plugin is written for. Glaze does not check it yet. |
| `contributes` | no | What the plugin adds to the interface: actions, panels, file handlers, settings and their tabs. |

## Translatable text

Wherever the manifest takes user-facing text (`name`, `description`, action labels, settings, tab names, host descriptions), you can write a string or a key into the translation files:

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

Glaze picks the user's interface language, then another variant of the same language, then English, then `default`. If a key is missing everywhere, the key itself is shown. The same files are available in code through `glaze.plugin.i18n` (see the [API reference](#info/plugins-api/glaze-plugin)).

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

In the chat drawer an SVG icon is tinted like the app's own icons; other images keep their colours. Without an icon the card shows a standard one. Under the label every plugin card has a puzzle piece and the plugin's name.

A tap runs the handler the main script registered for that `id`; see [Hooks, actions and panels](#info/plugins-runtime/actions).

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

How panels are laid out and how they load package files: [Hooks, actions and panels](#info/plugins-runtime/panels).

## File handlers

A file handler turns an attached file into text for the message. For example, it can pull the text out of a `.docx` or a `.pdf`.

```json
"fileHandlers": [
  { "id": "docx", "extensions": ["docx"], "mimeTypes": [], "scripts": ["docx.js"] }
]
```

`extensions` (without the dot) and `mimeTypes` say which files it takes; at least one is required. `scripts` are loaded only to run this handler; if the list is empty, the handler is registered by the main script. Registering in code: [Hooks, actions and panels](#info/plugins-runtime/file-handlers).

## Settings

`settings` describes a form on the plugin's page in **Tools → Plugins**. Glaze draws it, stores the values and passes them to the plugin. Fields are shown in the order they are listed, all on one **Settings** tab, unless the plugin splits them into [tabs](#info/plugins-manifest/tabs).

```json
"settings": [
  { "type": "toggle", "key": "enabled", "label": "Enabled", "default": true },
  { "type": "select", "key": "mode", "label": "Mode", "default": "short",
    "options": [{ "value": "short", "label": "Short" }, { "value": "long", "label": "Long" }] },
  { "type": "slider", "key": "count", "label": "Count", "min": 1, "max": 10, "step": 1, "default": 3 },
  { "type": "text", "key": "name", "label": "Name", "description": "Shown in replies" },
  { "type": "textarea", "key": "prompt", "label": "Prompt" },
  { "type": "note", "text": "Changes apply the next time the chat opens.", "icon": "info" },
  { "type": "divider" },
  { "type": "apiPreset", "key": "summary", "label": "Summaries", "description": "A cheap model is fine" },
  { "type": "imagePreset", "key": "photos", "label": "Photos" }
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
| `apiPreset` | `key`, `label`, `description`. An API connection and model for one of the plugin's features. |
| `imagePreset` | `key`, `label`, `description`. An image service and image style for one of the plugin's images. |

Any field can also have `tab`, see below.

`label`, `description`, `text`, option labels and text defaults can be translation keys. The values are read with `glaze.plugin.settings.get(key)`. When the user changes a setting, the plugin's frames restart with the new values.

### API presets

A plugin often generates in several places, and each may want its own model: chat replies on a strong one, background scene reading on a quick cheap one, photos in a style different from other pictures. For each such feature, declare an `apiPreset` (text) or `imagePreset` (images) and name it in the call:

```js
await glaze.generate(prompt, { preset: 'summary' });
await glaze.images.generate(prompt, { preset: 'photos' });
```

Each preset is drawn on the plugin's page as its own group, headed by its `label` and `description`, with the same rows as the other API slots in Glaze:

- `apiPreset`: **API connection** and **Model**;
- `imagePreset`: **Image service** and **Image style**. The service can follow the image generation settings or be any of the services set up there (NovelAI, Naistera and the others); it draws with that service's own key, model and options from the image settings. Services that draw through the LLM endpoint use the open chat's connection. The style can follow the image generation settings, be "No style", or be one from the style library.

Until the user picks something, and for calls without `preset`, Glaze uses the open chat's connection and the image settings, as before. If the chosen connection is deleted, the call falls back to the chat's. A `preset` that the manifest doesn't declare, or declares for the other kind of call, fails with `unknown_preset`. Glaze stores the pick with the plugin's other settings; the plugin doesn't need to read it.

Preset settings appeared in Glaze 0.9.0 (Nightly). Older versions don't know these types and won't install the plugin, so set `minGlazeVersion` to `0.9.0`.

### Tabs

The plugin's page has the tabs **Info**, **Permissions** and **Data**; a plugin with settings adds its own between Permissions and Data. Without `settingsTabs` that is one **Settings** tab with every field. To split the fields, list up to 10 tabs in `contributes.settingsTabs` and name a tab in each field's `tab`:

```json
"contributes": {
  "settingsTabs": [
    { "id": "main", "label": "General" },
    { "id": "look", "label": { "t": "tabs.look" }, "icon": "icons/palette.svg" }
  ],
  "settings": [
    { "type": "toggle", "key": "auto", "label": "Run on every reply", "default": true },
    { "type": "select", "key": "theme", "label": "Panel theme", "tab": "look", "options": ["light", "dark"] }
  ]
}
```

| Field | What it is |
|---|---|
| `id` | Tab id, unique among the tabs. |
| `label` | Tab name. Text or a translation key. |
| `icon` | Optional path to an image in the package; without it the tab has a standard icon. |

A field without `tab` goes on the first tab. A `tab` that names no tab in the list, a repeated `id` or more than 10 tabs make the manifest invalid. A tab no field is on is not shown. The user switches tabs from the menu under the page's header.

Tabs appeared in Glaze 0.9.0 (Nightly); older versions ignore `settingsTabs` and `tab` and show every field on one page.

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
  "minGlazeVersion": "0.9.0",
  "permissions": ["messages", "variables", "generate", "network"],
  "hosts": [{ "host": "api.example.com", "description": { "t": "hosts.api" } }],
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
