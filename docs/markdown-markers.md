# Custom Markdown Markers

The app extends GptMarkdown with custom `==...==` inline markers. When adding a
new marker, update all of the following in sync:

1. **Converter:** `lib/core/utils/html_to_markdown.dart` — produces marker syntax from HTML
2. **JS formatter extraction:** `assets/chat_webview/formatter/protect.js` — `MARKER_REGEX`, matched by `extractMarkers`. It runs in phase B, from `formatRun` in `assets/chat_webview/formatter/dom_format.js`, over one container's run of text with its inline elements masked — so a marker may still span a `<b>`, but never a block element or the inside of a `<pre>`. `assets/chat_webview/formatter/formatter.js` drives the passes.
3. **JS marker rendering:** `assets/chat_webview/formatter/text_format.js` — `renderStyledSegment()` HTML output
4. **JS CSS:** `assets/chat_webview/renderer/shadow_style.js` — `SHADOW_STYLE` styling for marker classes
5. **Dart renderer:** `lib/shared/widgets/colored_markdown.dart` — `InlineMd` subclass for Flutter-native rendering

## Registered `==...==` Markers

| Marker | Example | Renders as | Dart class | CSS class |
|---|---|---|---|---|
| `==hc:#hex==text==` | `==hc:#ff33ff==pink==` | Colored text | `HtmlColorMd` | `.glaze-hc` |
| `==glow:#hex,blur==text==` | `==glow:#ffffff,4==echo==` | Text with glow shadow | `GlowTextMd` | `.glaze-glow` |
| `==cg:#textHex,#glowHex,blur==text==` | `==cg:#ffb6c1,#ff6eb4,4==rosa==` | Colored text + glow | `ColorGlowTextMd` | `.glaze-cg` |
| `==grad:#hex1,#hex2==text==` | `==grad:#ff33ff,#ff1493==text==` | Gradient text (ShaderMask) | `GradientTextMd` | `.glaze-grad` |
| `==bg:#hex==text==` | `==bg:#333333==highlighted==` | Text with background color | `BackgroundTextMd` | `.glaze-bg` |
| `==mark==text==` | `==mark=="dialogue"==` | Quote-highlighted text | `MarkMd` | `.glaze-mark` |
| `==active==text==` | `==active==search hit==` | Active search match | `ActiveMarkMd` | `.glaze-active` |
| `==accent==text==` | `==accent==Continue==` | Theme accent colour | `AccentTextMd` | `.glaze-accent` |

Note: `==mark==` and `==active==` are injected by JS-side quote highlighting and
search highlighting. `==accent==` is written by the app itself — the `Continue`
header a continuation adds to a message's reasoning block (see
`docs/INVARIANTS.md` INV-CM5). Unlike `==hc:#hex==`, it resolves against the
active theme at render time (`var(--primary-color)`) rather than baking a colour
into the stored text, so a marker written once follows theme changes.
`html_to_markdown.dart` does not produce any of these three; it only produces the
five styling markers above.

`==mark==`, `==active==` and `==accent==` render their inner content raw. Every
other marker renders its content through `formatInlineMasked()`, which is
inline by construction: a marker is a `<span>`, and a `<p>` inside one is markup
the browser throws straight back out, leaving the marker empty on screen.

## Additional Custom InlineMd/BlockMd Classes

These do not use `==...==` syntax but are registered alongside the markers in
`colored_markdown.dart`:

| Class | Pattern | Renders as |
|---|---|---|
| `ColoredItalicMd` | `*italic*` | Italic with optional color override from theme preset |
| `ColoredUnderscoreItalicMd` | `_italic_` | Underscore-italic with optional color override |
| `ColoredBoldMd` | `**bold**` | Bold with optional color override |
| `ColoredUnderscoreBoldMd` | `__bold__` | Underscore-bold with optional color override |
| `DetailsSummaryMd` | `<details><summary>` | Collapsible details/summary block |

## Guard: `styledRegex` In Formatter

`Formatter._processText()` in `assets/chat_webview/formatter/formatter.js` uses
`styledRegex` to extract all custom `==...==` markers plus standard markdown
formatting patterns (`**bold**`, `*italic*`, `__bold__`, `_italic_`,
`~~strike~~`) before wrapping quotes in `==mark==`. This prevents `==mark==`
from being injected inside other markers, for example a `"..."` inside
`==grad:...==`.

When adding a marker, add its pattern to `styledRegex` and add matching output
logic in `renderStyledSegment()`.

Single quotes (`'...'`) are not protected so nested quotes like `"...'...'..."`
work. The outer quote regex captures the entire span and the inner single quotes
inherit the color from the outer `==mark==` region.
