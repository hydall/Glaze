A plugin gets only what it lists in `permissions` in its manifest, and only what the user has switched on. On a fresh install every permission is off: the user sees the list and turns on what they are willing to give. They can take any permission back at any time on the plugin's page.

## The list

| Permission | What it gives |
|---|---|
| `composer` | The message box: read, change and send its text (`glaze.composer`); the `send:*` hooks. |
| `messages` | The open chat: its messages and variants, the memory book, the chat's settings (`glaze.messages`, `glaze.memory`, `glaze.chats.current`); the `chat:*` and `message:*` events. |
| `variables` | The plugin's own variables: per chat, per message and global. |
| `variables.shared` | The `shared` variables, which every plugin reads and writes together. |
| `files` | The plugin's own files (`glaze.files`), import and export through files. |
| `generate` | Text generation with the chat's connection (`glaze.generate`); the `generation:*` hooks. |
| `images` | Image generation with the user's image settings (`glaze.images.generate`). Asks. |
| `network` | Internet access. See [Network](#info/plugins-permissions/network). |
| `library.read.<kind>` | Reading the library: characters, personas, presets, lorebooks, regex scripts or themes. |
| `library.create.<kind>` | Adding to the library. Asks. |
| `library.update.<kind>` | Changing the library. Asks. |
| `library.delete.<kind>` | Deleting from the library. Asks. |
| `chats.read` | Other chats: finding, reading, opening. |
| `chats.create` | Creating, copying and importing chats. Asks. |
| `chats.update` | Changing other chats. Asks. |
| `chats.delete` | Deleting chats. Asks. |

`<kind>` is one of `characters`, `personas`, `presets`, `lorebooks`, `regex`, `themes`. Ask only for what you use: `library.read.lorebooks` rather than the whole library.

Short forms: `library.read` (and `create`, `update`, `delete`) means that action on every kind.

## Permissions that ask

Permissions marked "Asks" are confirmed by the user on every call: Glaze shows a sheet with the plugin's name and what it wants to do, and the user picks **Allow once**, **Always allow** or **Deny**. Deny switches the permission off. On the plugin's Permissions tab each of them can be set to Ask, Always or Off.

The call waits for the answer. If the sheet is dismissed, the call is refused.

## Refusals

A call the plugin is not allowed to make rejects with an error whose `code` is `permission_denied`:

```js
try {
  await glaze.lorebooks.list();
} catch (e) {
  if (e.code === 'permission_denied') {
    // tell the user what to turn on, or do without
  }
}
```

The user gets a notice signed with the plugin's name, once per action. A refused plugin is never asked again: if it needs the permission, the user turns it on themselves. Every call and its answer go into the plugin's request history, on its page.

Methods of a permission the manifest does not ask for are not in `glaze` at all. Methods of a permission the user switched off are there, but reject.

Hooks and events need permissions too. A plugin without `composer` gets no `send:*`, without `generate` no `generation:*`, without `messages` no `chat:*` or `message:*`.

## Network

Without the `network` permission a plugin has no internet at all: its frames can't load anything from outside, and `glaze.net.fetch` is refused. If the plugin asks for it, the user sets it in the **Internet** group on the plugin's Permissions tab, under **Access**, to one of three modes:

| Mode | What the plugin can reach |
|---|---|
| Off | Nothing. |
| Listed hosts | The hosts from `hosts` in the manifest, except those the user switched off, and the hosts the user added. |
| Any host | Anything on the internet. |

List your hosts in the manifest. A host is a string, or an object with a `description` that tells the user what the plugin uses it for (text or a translation key):

```json
"permissions": ["network"],
"hosts": [
  "*.cdn.example.com",
  { "host": "api.example.com", "description": "Weather forecasts" }
]
```

`*.example.com` covers subdomains, but not `example.com` itself.

The `network` permission starts off, as every permission does. When the user turns it on, the mode is "Listed hosts" with every manifest host on. In that mode the Internet group has a **Hosts** row that opens the list: the manifest's hosts with their descriptions, each with a switch, then the hosts the user added (**Add a host**). An update keeps what the user set up. Host objects need Glaze 0.9.0 (Nightly): older versions refuse such a manifest.

The rules apply to everything the plugin does: `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, images, scripts and styles from the internet, and requests through `glaze.net.fetch`. Without the local network switch only https on the internet works. The local network (`192.168.*`, `*.local` and so on) and plain http there need a separate switch, off by default. Loopback (`localhost`, `127.0.0.1`, `::1`) is not part of that switch: it works like an internet host named in the plugin's list, plain http included. WebRTC is available only in the "Any host" mode.

The **Network** group on the Permissions tab lists every host the plugin's frames loaded from or were stopped from loading, and in the "Listed hosts" mode the user can allow or block each one right there.

## Requests through the app

`glaze.net.fetch` sends a request from the app rather than from the plugin's frame. The page's cross-origin rules (CORS) don't apply, so a plugin can call an API that doesn't allow browsers without a relay server of its own. The plugin's internet rules apply as usual. Details: [glaze.net](#info/plugins-api/glaze-net).

## Security

Isolated frames and permissions limit what a plugin can do, but are not a full guarantee of security. Only install plugins from authors you trust, and ask your users only for what the plugin really needs.
