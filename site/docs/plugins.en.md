A plugin adds features to Glaze's chat: buttons in the chat drawer, its own panels over the chat or inside messages, processing of messages before they are sent and replies after they arrive, and its own settings. Plugins are written in HTML and JavaScript and talk to the app through the `glaze.*` API.

> Plugins are in Nightly builds for now. The API may still change before the release.

## How a plugin runs

Each plugin runs in its own isolated frame inside the chat. It does not see the chat page, other plugins or the app's data. Everything it needs it asks for through `glaze.*`, and the app checks every call against the plugin's permissions.

A plugin only gets what it lists in its manifest, and every permission starts switched off: the user turns on what they are willing to give. Some actions, such as changing the library or generating images, also ask the user each time. More on this in [Permissions and network](#info/plugins-permissions).

## The package

A plugin is a `.glzp` file: a zip archive with `plugin.json` at its root. Everything else is up to you:

```
my-plugin.glzp
├── plugin.json      manifest (required)
├── main.js          main script
├── panel.html       a panel
├── icon.png
└── locales/
    ├── en.json
    └── ru.json
```

Paths in the manifest are relative to the root of the archive, with forward slashes. A package can hold up to 2000 files and 64 MB unpacked.

## A first plugin

This plugin adds an action to the Tools tab of the chat drawer that shows how many messages the chat has, and turns `:shrug:` in an outgoing message into a shrug.

`plugin.json`:

```json
{
  "format": 1,
  "id": "example.counter",
  "name": "Message counter",
  "version": "1.0.0",
  "author": "you",
  "description": "Counts the messages in the chat.",
  "main": "main.js",
  "permissions": ["messages", "composer"],
  "contributes": {
    "toolsActions": [
      { "id": "count", "label": "Count messages" }
    ]
  }
}
```

`main.js`:

```js
glaze.plugin.onToolsAction('count', async () => {
  const count = await glaze.messages.count();
  glaze.ui.toast(`Messages in this chat: ${count}`);
});

glaze.plugin.on('send:before', (event) => {
  event.text = event.text.replaceAll(':shrug:', '¯\\_(ツ)_/¯');
});
```

Zip the two files (the files themselves, not the folder they are in) and rename the archive to `example.counter.glzp`.

## Installing and testing

In Glaze open **Tools → Plugins → Import plugin** and pick the file. Glaze shows the permissions the plugin asks for; switch on the ones it needs. Open a chat: the action appears in the Tools tab of the chat drawer (the button next to the message box).

To update the plugin, raise `version` and import the file again. The plugin keeps its data and the permissions the user gave it; new permissions arrive switched off. A package with the same `id` but another `author` is installed as a new plugin and does not get the old one's data.

What helps while developing:

- The plugin's page in **Tools → Plugins** has its permissions, settings, network log and request history: what the plugin asked for and whether it was allowed.
- Requests a plugin sends (`glaze.generate`, `glaze.net.fetch`, `fetch` in its frames) show in the chat's Prompt Inspector, on the Requests tab.
- A refused call rejects with an error whose `code` is `permission_denied`, and the user sees a notice once.

## Tavo extensions

Glaze can also install Tavo extensions (`.tpg` files and Tavo Hub links): they run through a compatibility layer. To write such an extension, see [Tavo's documentation](https://docs.tavoai.dev/en/guides/plugin-development/). New plugins for Glaze are best written in the format described here: it has more to offer and lets the user give exact permissions.

## Next

- [The plugin.json manifest](#info/plugins-manifest): every field.
- [Permissions and network](#info/plugins-permissions).
- [Hooks, actions and panels](#info/plugins-runtime): how plugin code plugs into the chat.
- [API reference](#info/plugins-api): every `glaze.*` method.
