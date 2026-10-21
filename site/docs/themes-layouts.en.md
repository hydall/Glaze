## What a layout replaces

A theme without a layout only changes colours and fonts. A layout goes further:
it chooses where the parts of a message go, what surrounds them, and what the
chat header, composer and drawer look like.

The app still builds the parts. The template decides where they appear, so
live updates keep working: a new swipe, a token count or a name change reaches
the element the template placed.

There is no HTML editor inside the app. Layouts are written in a theme file and
imported.

## The layout object

A theme archive can keep each part in its own file:

```json
{
  "name": "Cards",
  "accentColor": "#C42A4A",
  "layout": {
    "message": "layout/message.html",
    "css": "layout/chat.css",
    "contentCss": "layout/content.css",
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

Every value is either a path inside the archive or the markup/CSS itself. A
path that is not found is ignored, so a missing part keeps the built-in look
for that surface. A part is limited to 256 KiB.

The flat spelling works too: `message`, `css`, `contentCss`, `header`,
`composer`, `drawerCard`, `drawerTab` and `chromeCss` may sit directly under
`layout`; for the chrome parts this is an alternative to the `chrome` object.
A JSON preset exported by the app has every part already expanded into the
preset, so it imports without an archive.

| Part | What it draws |
|------|---------------|
| `message` | Each message. |
| `css` | The chat page: scroll area, separators, message spacing. |
| `contentCss` | Inside every message body, where Markdown is rendered. |
| `header` | The chat header. |
| `composer` | The message box. |
| `card` | The inside of every card in the chat drawer. |
| `tab` | The inside of every drawer tab. |
| `chromeCss` | The chrome: header, composer and drawer. |
| `settings` | The theme's own Chat screen in the editor. |

## Template syntax

| Syntax | Meaning |
|--------|---------|
| `{{ name }}` | A value, or part of an attribute value. |
| `g-if="cond"` | Draw the element only while the condition holds. |
| `g-else-if="cond"`, `g-else` | Branches after a `g-if`. |
| `g-each="pins" g-as="pin"` | Repeat the element for each item. |
| `<g-part name="content"></g-part>` | Place one of the app's pieces here. |
| `<g-icon name="search">` | A named glyph from the built-in icon set. |
| `<g-icon value="{{icon}}">` | A glyph whose name comes from the data. |
| `g-action="regenerate"` | A tap does that chat action. |

Expressions are paths (`swipe.total`), literals, `!`, `==`, `!=`, `<`, `<=`,
`>`, `>=`, `&&`, `||` and `a ? b : c`. Inside `g-each`, an item's fields are
available bare (`{{label}}`) and under its name (`{{pin.label}}`); `{{index}}`
is the position.

Markup is limited to text and layout elements: `div`, `span`, `p`, headings,
lists, `table`, `button`, `img`, `svg` and its shapes. A `script`, `style`,
`iframe`, `a`, event handler or `id` is dropped together with its contents.
Inline `style` may only load `data:` images.

## Messages

The message layout can place these pieces:

| Piece | What it is |
|-------|------------|
| `header` | The whole header: avatar, name and time. |
| `avatar` | The avatar alone. |
| `name` | The name, with the message number and memory badge. |
| `time` | The time and the hidden-message eye. |
| `guidance` | The guidance block, when the message has one. |
| `content` | Reasoning, message body, images and footer. |
| `footer` | Swipe arrows, regenerate and the menu. |

A message template receives these fields:

| Field | Meaning |
|-------|---------|
| `id`, `role`, `isUser`, `isChar`, `isSystem` | Identity of the message. |
| `name`, `initial`, `avatarUrl`, `avatarColor`, `persona` | Who sent it. |
| `text`, `reasoning` | The message as the app formatted it. |
| `timestamp`, `time`, `date` | Timestamp and ready-made labels. |
| `index` | 1-based message number, or empty when unknown. |
| `swipe.index`, `swipe.total` | Current variation and how many there are. |
| `tokens`, `genTime`, `model` | Generation stats; empty when absent. |
| `isLast`, `isError`, `isHidden`, `isTyping` | State flags. |

A `g-action` on a message element uses the app's own action with that message
already filled in:

```
open-actions, regenerate, translate, swipe-left, swipe-right,
greeting-prev, greeting-next, agent-swipe-left, agent-swipe-right,
memory-click, inject-click, toggle-hidden, output-limit-click,
rerun-cleaner, toggle-guided, edit-save, edit-cancel, stop
```

## Header, composer and drawer

The header pieces are `back`, `title` (the whole title box), `character` (the
character block alone), `avatar`, `name`, `session` and `search`. The mobile
search field lives inside `title`, so a layout that wants a working search
places `title`. Its actions are `back`, `character`, `avatar`, `search` and
`closeSearch`.

The composer pieces are `attachments`, `pill` (the input surface), `guidance`,
`input`, `row`, `pins` and `send`. The text stays in the field the template
places, so the keyboard, draft and send keep working. Its actions are `send`
and `focus`.

A drawer card has `label`, `status`, `icon`, `statusIcon`, `kind`, `add`,
`editing` and `tab`; a drawer tab has `label`, `icon`, `active` and `index`. The card and tab themselves stay the drawer's, so taps, long-press
drags and edit badges work as before.

## Stylesheets

The three stylesheets have different scopes:

- `css` is added to the chat page. It sees the message sections, the scroll
  area and the background, but cannot reach into the chrome, which lives in a
  closed shadow root.
- `contentCss` is added inside every message's shadow root. This is the only
  way to style what the Markdown renderer writes: paragraphs, quotes, lists,
  code, tables and links.
- `chromeCss` is added inside the chrome. Use it to style what the header,
  composer and drawer templates drew.

All three pass through a sanitizer. `url()` may load `data:` images only;
`@import`, `@font-face`, `expression()` and escapes that could hide a `url()`
are dropped with the rule they are in. A theme file is shared, so it cannot
send what it is shown anywhere.

The page and the chrome also expose the active theme as CSS variables. On the
page the useful ones are `--user-bubble-bg`, `--char-bubble-bg`,
`--user-text-color`, `--char-text-color`, `--user-quote-color`,
`--char-quote-color`, `--user-italic-color`, `--char-italic-color`,
`--user-bubble-radius`, `--char-bubble-radius`, `--element-opacity`,
`--element-blur`, `--avatar-radius`, `--font-size`, `--font-family`,
`--text-bg-opacity` and `--bg-dim`.

The chrome adds its own: `--gc-accent`, `--gc-text`, `--gc-text2`,
`--gc-corner`, `--gc-fill`, `--gc-fill-header`, `--gc-fill-surface`,
`--gc-outline`, `--gc-outline-var`, `--gc-font`, `--gc-bw`, `--gc-bc`,
`--gc-safe-top` and `--gc-safe-bottom`.

## Theme settings

`layout.settings` is a declaration, or the path of a JSON file, that replaces
the built-in Chat screen in the editor. It describes tabs, groups in each tab
and rows in each group:

```json
{
  "tabs": [
    {
      "id": "theme",
      "label": { "en": "Theme", "ru": "Тема" },
      "icon": "brush",
      "groups": [
        {
          "header": {
            "en": "Cards",
            "ru": "Карточки"
          },
          "items": [
            {
              "type": "color",
              "key": "card-edge",
              "label": { "en": "Card edge", "ru": "Кромка" },
              "default": "#C42A4A"
            },
            {
              "type": "slider",
              "key": "card-pad",
              "label": { "en": "Padding", "ru": "Отступ" },
              "min": 4,
              "max": 24,
              "step": 1,
              "unit": "px",
              "default": 12
            },
            {
              "type": "switch",
              "key": "compact",
              "label": { "en": "Compact header", "ru": "Компактная шапка" }
            },
            { "field": "userBubbleColor", "when": "chatLayout == 'bubble'" }
          ]
        }
      ]
    }
  ]
}
```

A row is one of:

| Row | Meaning |
|-----|---------|
| `{"field": "..."}` | A preset field, drawn exactly as the built-in screen draws it. |
| `{"type": "color", "key": "..."}` | A colour owned by the theme. |
| `{"type": "slider", "key": "...", "min": 0, "max": 10}` | A number; `unit` may be `px`, `%`, `em`, `rem`, `deg`, `s` or `ms`, and `percent` shows the value multiplied by 100. |
| `{"type": "switch", "key": "..."}` | An on/off setting. |
| `{"type": "select", "key": "...", "options": [{"value": "left", "label": "Left"}]}` | A choice from `options`, each with a `value` and a `label`. |
| `{"type": "subheader"}` or `{"type": "note"}` | A heading or a line of explanation, with a `label`. |

The fields a theme may bind are `chatLayout`, `chatBgMode`, `chatBgColor`,
`chatBgImage`, `chatFontMode`, `chatFontSize`, `chatLetterSpacing`,
`userMessageFontWeight`, `charMessageFontWeight`, `userBubbleColor`,
`charBubbleColor`, `userBubbleRadius`, `charBubbleRadius`, `showUserAvatar`,
`showCharAvatar`, `showUserName`, `showCharName`, `hideMessageId`,
`hideGenerationTime`, `hideTokenCount`, `userQuoteColor`, `charQuoteColor`,
`userTextColor`, `charTextColor`, `userItalicColor`, `charItalicColor` and
`textBgOpacity`.

Labels are a string, one string per language, or `"@key"` for an app
translation. A tab's icon is one of `text_fields`, `palette`, `tune`, `chat`,
`image`, `brush`, `star`, `layers`, `person` or `auto_awesome`.

`when` on a group or a row shows it only while the condition holds. It can read
the preset fields above, the theme's own values by key, and `desktop` /
`mobile`; it has `!`, comparisons, `&&`, `||`, parentheses, strings, numbers,
`true`, `false` and `null`.

The theme's own values reach the layout three ways, on the page and in the
chrome alike:

| | |
|---|---|
| `--theme-<key>` | A CSS variable: a colour, a number with its unit, `1`/`0` for a switch, or the selected option. |
| `theme-<key>` | A class while a switch is on. |
| `theme-<key>-<value>` | A class for the chosen option of a select. |

On the page the variables are on the document and the classes on
`#chat-container`; in the chrome both are on its root. A message template gets
them as `theme.<key>`, so `g-if="theme.compact"` works. Only colours, numbers
and plain words get through.

## Template and preview

The repository's `docs/theme_template` is a working theme: a message template,
page and chrome stylesheets, and a `settings.json` with the built-in Chat
screen plus one tab of the theme's own settings. Zip the contents so
`theme.json` is at the root and import the archive.

The eye button in the editor's header shows the same page a chat uses, with a
few sample messages. What the preview shows is what the chat will show.
