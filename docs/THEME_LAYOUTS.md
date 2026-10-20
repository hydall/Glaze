# Theme layouts

A theme can bring its own layout, not just its colors: HTML templates that
rearrange the messages, the chat header, the message box (composer) and the
drawer's cards and tabs, plus stylesheets for the chat page and for the chrome.

The layout lives in the theme preset, travels with it in export/import, and is
read from a theme file's `layout` object. There is no in-app code editor —
themes are written outside the app and imported.

The engine is `assets/chat_webview/chrome/template.js`; the message side is
`assets/chat_webview/renderer/theme_layout.js`, the chrome side
`assets/chat_webview/chrome/skin.js`.

## File format

```json
{
  "name": "Cards",
  "accentColor": "#C42A4A",
  "layout": {
    "message": "layout/message.html",
    "css": "layout/chat.css",
    "chrome": {
      "header": "layout/header.html",
      "composer": "layout/composer.html",
      "card": "layout/card.html",
      "tab": "layout/tab.html",
      "css": "layout/chrome.css"
    }
  }
}
```

Every value is either the path of a file inside the theme archive (`.zip` /
`.gtheme`) or the markup/CSS itself. A path that is not in the archive is
ignored, not treated as inline text. The flat spelling also works when a
`chrome` object is inconvenient:

```json
"layout": {
  "message": "...", "css": "...",
  "header": "...", "composer": "...",
  "drawerCard": "...", "drawerTab": "...", "chromeCss": "..."
}
```

Missing parts keep the built-in look for that surface. Each part is capped at
256 KiB.

## Template syntax

```
{{ name }}                     a value, or part of an attribute value
g-if="cond"                    draw the element only when cond holds
g-else-if="cond" g-else        branches of the g-if right before them
g-each="pins" g-as="pin"       repeat the element for each item
<g-part name="content">        where one of the app's pieces goes
<g-icon name="search">         a named glyph from chrome/icons.js
<g-icon value="{{icon}}">      a glyph the data carries
g-action="regenerate"          a tap on it does that action
```

Expressions are paths (`swipe.total`), string and number literals, `!`,
`==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||` and `a ? b : c`. Inside
`g-each` the item's fields are in scope bare (`{{label}}`) and under its name
(`{{pin.label}}`); `{{index}}` is the position.

`g-icon name` takes any name exported by `assets/chat_webview/chrome/icons.js`;
a message's own icons come as data instead (`<g-icon value="{{swipeIcon}}">`).

Allowed markup: common text and layout elements (`div`, `span`, `p`, headings,
lists, `table`, `button`, `img`, `svg` and its shapes, …). A `script`,
`style`, `iframe`, `a`, event handler or `id` is dropped, and so is anything
inside it. Inline `style` may only load `data:` images.

## Data and pieces

### Messages

`message` lays out each message. The app still builds the header, the body and
the footer; the template chooses where they go and what to show around them.

| Piece      | What it is                                                   |
|------------|--------------------------------------------------------------|
| `header`   | the whole header (avatar + name + time)                      |
| `avatar`   | the avatar                                                   |
| `name`     | the name, with the message index and memory badge            |
| `time`     | the time (and the hidden-message eye)                        |
| `guidance` | the guidance block, if the message has one                   |
| `content`  | the content stack: reasoning, body, image, footer            |
| `footer`   | the footer with the swipe arrows, regenerate and menu        |

A piece the template does not place is kept out of sight, not removed, so
live updates (a new swipe, a token count, a name change) keep working.

| Field | |
|---|---|
| `id`, `role`, `isUser`, `isChar`, `isSystem` | identity of the message |
| `name`, `initial`, `avatarUrl`, `avatarColor`, `persona` | who sent it |
| `text`, `reasoning` | as sent by the app (already formatted for display) |
| `timestamp`, `time`, `date` | timestamp and ready-made labels |
| `index` | 1-based message number (`null` when unknown) |
| `swipe.index`, `swipe.total` | 1-based current variation |
| `tokens`, `genTime`, `model` | generation stats (`''` when absent) |
| `isLast`, `isError`, `isHidden`, `isTyping` | state flags |

`g-action` on a message element uses the app's own message actions, with the
message id filled in: `open-actions`, `regenerate`, `translate`, `swipe-left`,
`swipe-right`, `greeting-prev`, `greeting-next`, `agent-swipe-left`,
`agent-swipe-right`, `memory-click`, `inject-click`, `toggle-hidden`,
`output-limit-click`, `rerun-cleaner`, `toggle-guided`, `edit-save`,
`edit-cancel`, `stop`.

### Header

Pieces: `back`, `title` (the whole title box, the character block inside it),
`character` (just the character block, with the inline search field on
desktop), `avatar`, `name`, `session`, `search` (the search button). The
mobile search field lives inside `title`, so a layout that wants a working
search places `title`.

| Field | |
|---|---|
| `title`, `session` | what the character block shows |
| `avatar.url`, `avatar.initial` | the picture, or the letter |
| `search.available`, `search.open`, `search.desktop` | the search control |
| `flush`, `hidden` | desktop edge-to-edge, hidden-on-scroll |

Actions: `back`, `character`, `avatar`, `search`, `closeSearch`.

### Composer

Pieces: `attachments`, `pill` (the whole input surface), `guidance`,
`input` (the text field), `row`, `pins`, `send`.

| Field | |
|---|---|
| `placeholder`, `hasText`, `locked`, `readOnly` | the field |
| `guidance`, `attachments` | presence, and the attachment count |
| `pins` | `[{ key, icon }]` — the pinned buttons |
| `send.icon`, `send.enabled` | the send button |

The text stays in the field the template placed: it is still the app's
textarea, so the keyboard, draft and send behave as before. Actions: `send`,
`focus`.

### Drawer

`card` replaces the inside of every drawer card; `tab` replaces the inside of
a tab. The card and tab themselves stay the drawer's, so taps, long-press
drags and the edit badges work as before.

| Card field | |
|---|---|
| `label`, `status`, `icon`, `statusIcon` | what the card shows |
| `kind`, `add`, `editing`, `tab` | what it is (`tools` / `actions`) |

| Tab field | |
|---|---|
| `label`, `icon`, `active`, `index` | the tab |

## Stylesheets

- `css` is added to the chat page: messages, separators, the scroll area. It
  cannot reach the chrome (the chrome lives in a closed shadow root).
- `contentCss` is added inside every message's shadow root — the only way to
  style what the markdown renderer writes (code blocks, headings, quotes,
  tables, links). It is injected into each message separately, so its
  selectors apply per message body and nowhere else.
- `chrome.css` is added inside the chrome: use it to style what the header,
  composer and drawer templates drew, together with the chrome's own
  `--gc-*` variables (accent, text, corner radius, …).

Both go through the same sanitizer: `url()` may load `data:` images only, and
`@import`, `@font-face`, `expression()` and any escape that could hide a
`url()` are dropped, together with the rule they are in. A theme is a shared
file, so it must not be able to send what it is shown anywhere.

An image `src` is either a `data:` URL written in the template or one bare
`{{path}}` that the app provides (an avatar). Nothing else loads.

## Worked example

`layout/message.html`:

```html
<div class="card {{role}}">
  <div class="who">
    <g-part name="avatar"></g-part>
    <span class="nm">{{name}}</span>
    <span class="idx" g-if="index">#{{index}}</span>
    <span class="sw" g-if="swipe.total > 1">{{swipe.index}}/{{swipe.total}}</span>
  </div>
  <g-part name="content"></g-part>
  <div class="tools">
    <button g-action="swipe-left"><g-icon name="arrow_back_ios_new_rounded"></g-icon></button>
    <button g-action="swipe-right"><g-icon name="north_east"></g-icon></button>
    <button g-action="open-actions"><g-icon name="menu_book_outlined"></g-icon></button>
  </div>
</div>
```

`layout/chat.css`:

```css
.card { border-radius: 18px; padding: 12px; background: var(--char-bubble-bg); }
.card.user { background: var(--user-bubble-bg); }
.who { display: flex; gap: 8px; align-items: baseline; }
.tools { display: flex; gap: 6px; justify-content: flex-end; }
```

`layout/header.html`:

```html
<div class="bar">
  <button g-action="back"><g-icon name="arrow_back_ios_new_rounded"></g-icon></button>
  <g-part name="title"></g-part>
  <button g-action="search"><g-icon name="search"></g-icon></button>
</div>
```
