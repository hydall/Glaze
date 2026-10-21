## What a theme is

A theme is a preset that changes how Glaze looks. It can recolour the app and
the chat, set fonts and backgrounds, and stop there. It can also bring its own
chat layout: HTML templates and CSS that rearrange the messages, the header,
the composer and the drawer, and declare the controls the theme exposes in the
editor.

Themes are local files. Glaze has no theme server and does not fetch anything
from the internet when a theme is applied.

## Make a theme in the app

1. Open **Menu → Settings → Appearance → Theme Presets**.
2. Tap **New Theme**. The editor opens on the theme you just created.
3. **General** holds the app palette, background, fonts, corners and effects.
4. **Chat** holds the chat font, bubble colours, reply colours, avatars and
   background. Its dropdown switches between the theme's sections; a theme can
   add sections of its own.
5. The eye button in the header opens a live preview of the real chat page:
   the same renderer, stylesheets, chrome and layout that a chat will use.
6. Close the editor and use the preset's menu to **Export** it.

The preset list marks a theme that brings its own layout or CSS with a CSS
chip. That chip is only a hint: the theme is still an ordinary preset and can
be edited, exported and shared like any other.

## Import and export

**Import Theme** is on the same screen. It accepts four kinds of file:

| File | What it is |
|------|------------|
| `.json` | A theme preset. This is what Export writes. |
| `.gtheme` | A ZIP with `theme.json` at the root and, usually, files under `layout/` and `assets/`. |
| `.zip` | The same container as `.gtheme`; the extension is just a convenience. |
| `.thm` | A theme made for Tavo, converted on import. See [Tavo themes](#info/themes-tavo). |

Export writes one JSON file with everything inline, including any templates and
stylesheets, so it can be imported on another device without the original
archive. The `id` is assigned by Glaze on import; `name` is what the list shows.

On iOS the file picker offers all files, and Glaze checks the extension when
the file arrives.

## What a theme can change

| Layer | What it covers |
|-------|----------------|
| App palette | Accent, surfaces, text, borders, corner rounding, fonts, the app background and glass effects. |
| Chat | Chat font, bubble colours, gradients and radii, quote, text and italic colours, avatars, names, timestamps and tokens, chat background. |
| Layout | Message, header, composer and drawer templates, plus page, message-body and chrome stylesheets. |
| Chat settings | The tabs, groups and rows the theme adds to the editor's Chat screen. |

## The smallest useful theme

A JSON preset works on its own. This one sets a dark palette, bubble layout and
a plain chat background:

```json
{
  "name": "Cherry glass",
  "author": "you",
  "themeMode": "dark",
  "accentColor": "#C42A4A",
  "chatLayout": "bubble",
  "userBubbleColor": "#5A2230",
  "charBubbleColor": "#2B2B33",
  "userBubbleRadius": 20,
  "charBubbleRadius": 20,
  "chatBgMode": "color",
  "chatBgColor": "#141418"
}
```

Save it as `cherry.json`, import it, then tap it in the list to apply it.

## Start from the template

The source tree includes a small theme under `docs/theme_template`: a message
template, two stylesheets, a `settings.json` declaration and an example
`theme.json`. It is a working starting point for a custom layout.

Zip the **contents** of the folder, so `theme.json` is at the root of the
archive, then import the archive.

## Next

- [The theme file](#info/themes-json) lists every field a preset understands.
- [Chat layout](#info/themes-layouts) covers templates, CSS and theme settings.
- [Tavo themes](#info/themes-tavo) explains what happens to a `.thm` file.
