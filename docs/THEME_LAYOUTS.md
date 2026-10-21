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
    "settings": "settings.json",
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
256 KiB. `settings` is the theme's own Chat screen in the editor — see
[Settings](#settings).

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

## Settings

A theme can declare its own settings for the theme editor's **Chat** screen
in `layout.settings` — the declaration itself, or the path of a JSON file in
the archive. A declaration replaces the built-in Chat screen as a whole: its
tabs (picked from the dropdown under the editor's header), the groups in each
tab and the rows in each group. A theme without one gets the built-in screen,
which is itself such a declaration (`lib/shared/theme/default_chat_settings.dart`).

```json
{
  "tabs": [
    {
      "id": "theme", "label": { "en": "Theme", "ru": "Тема" }, "icon": "brush",
      "groups": [
        {
          "header": "Cards",
          "items": [
            { "type": "color", "key": "card-edge", "label": "Card edge", "default": "#C42A4A" },
            { "type": "slider", "key": "card-pad", "label": "Padding", "min": 4, "max": 24, "step": 1, "unit": "px", "default": 12 },
            { "type": "switch", "key": "compact", "label": "Compact header" },
            { "type": "select", "key": "edge", "label": "Edge side",
              "options": [{ "value": "left", "label": "Left" }, { "value": "top", "label": "Top" }] },
            { "field": "userBubbleColor", "when": "chatLayout == 'bubble'" }
          ]
        }
      ]
    }
  ]
}
```

A row is one of:

- `{"field": …}` — one of the preset's own chat fields, drawn exactly as the
  built-in screen draws it. The fields a theme may use: `chatLayout`,
  `chatBgMode`, `chatBgColor`, `chatBgImage`, `chatFontMode`, `chatFontSize`,
  `chatLetterSpacing`, `userMessageFontWeight`, `charMessageFontWeight`,
  `userBubbleColor`, `charBubbleColor`, `userBubbleRadius`,
  `charBubbleRadius`, `showUserAvatar`, `showCharAvatar`, `showUserName`,
  `showCharName`, `hideMessageId`, `hideGenerationTime`, `hideTokenCount`,
  `userQuoteColor`, `charQuoteColor`, `userTextColor`, `charTextColor`,
  `userItalicColor`, `charItalicColor`, `textBgOpacity`. Without a `label` it
  keeps the app's own.
- A value of the theme's own: `type` is `color`, `slider` (`min`, `max`,
  `step`, `unit` — one of `px % em rem deg s ms` — and `percent` to show it
  ×100), `switch` or `select` (`options`), with a `key` (letters, digits, `-`
  and `_`) and a `default`.
- `{"type": "subheader"}` or `{"type": "note"}` with a `label`.

Labels are a string, one string per language (`{"en": …, "ru": …}`), or
`"@key"` for one of the app's own translations. Tab icons are one of
`text_fields palette tune chat image brush star layers person auto_awesome`.
`description` adds a line under a row.

`when` on a group or a row shows it only while the condition holds. It reads
the preset's fields by name (`chatLayout`, `chatBgMode`, …), the theme's own
values by key (or `theme.key`), and `desktop` / `mobile`; it has `!`, `==`,
`!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, parentheses, strings, numbers,
`true`, `false` and `null`. A condition that does not parse holds.

The theme's own values reach it three ways, on the chat page and in the
chrome alike:

| | |
|---|---|
| `--theme-<key>` | a CSS variable: the colour, the number with its unit, `1`/`0` for a switch, the option of a select |
| `theme-<key>` | a class, while a switch is on |
| `theme-<key>-<value>` | a class for the chosen option of a select |

On the page the variables are on the document and the classes on
`#chat-container`; in the chrome both are on its root (`.gc`), so `chrome.css`
reads them there. A message template also gets them as `theme.<key>`
(`g-if="theme.compact"`). Only colours, numbers and plain words get through, so
a value can never carry a `url()` into a stylesheet.

## Template

`docs/theme_template/` is a theme to start from: `theme.json`, a message
template and stylesheets in `layout/`, and `settings.json` — the built-in Chat
screen's declaration (the Font, Colors and General tabs) with one more tab of
the theme's own settings, used by its stylesheets. Zip the folder's contents
(so `theme.json` is at the root of the archive) and import it.

The editor's preview (the eye button in its header) is the chat page itself
(`assets/chat_webview/theme_preview.html`): the same renderer, stylesheet,
chrome and theme layout, fed a few sample messages — what it shows is what a
chat will show.

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
