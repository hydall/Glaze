## One flat object

A Glaze theme is a single JSON object. Every field is optional; a missing field
keeps its default. Unknown fields are ignored, so a file written for a newer
version still imports.

Colours are `#RRGGBB` or `#AARRGGBB` (alpha first). Sizes and radii are numbers
in logical pixels. An image or a font file is a `data:` URI; the editor writes
those for you when you pick a file.

| Field | Type | Meaning |
|-------|------|---------|
| `name` | string | Shown in the preset list and exported as the file name. |
| `author` | string | Free-form credit. |
| `themeMode` | `dark`, `light`, `system` | Which brightness the palette is drawn in. |
| `accentColor` | colour | Accent used by controls, links and highlights. Default `#C42A4A`. |
| `id` | string | Ignored on import; Glaze assigns a new one. |

## App interface

| Field | Default | Meaning |
|-------|---------|---------|
| `uiColor` | derived | Base surface colour of the app. |
| `uiTextColor` | derived | Primary text. |
| `uiTextGrayColor` | derived | Secondary text and hints. |
| `bgColor` | derived | App background behind every screen. |
| `bgImage` | none | App background image as a `data:` URI. |
| `bgDim` | `0.15` | Black overlay over the background image, `0`–`1`. |
| `bgBlur` | `0` | Background image blur in pixels. |
| `elementOpacity` | `0.8` | Opacity of glass surfaces and chat bubbles, `0`–`1`. |
| `elementBlur` | `12` | Backdrop blur of those surfaces in pixels. |
| `borderWidth` | `1` | Border width of cards and surfaces. |
| `borderColor` | derived | Border colour. |
| `borderOpacity` | `0.1` | Border opacity, `0`–`1`. |
| `cornerScale` | `1` | Multiplier for buttons, cards and sheets; `0` squares them off, `1` is the shipped look. |
| `avatarRoundness` | `1` | Avatar shape: `1` is a circle, `0` a square. |
| `noiseOpacity` | `0.03` | Film grain over the app chrome. |
| `noiseIntensity` | `0.8` | Grain strength. |
| `bgNoiseOpacity` | `0.03` | Grain over the chat background. |
| `bgNoiseIntensity` | `0.4` | Chat grain strength. |

## Fonts

| Field | Default | Meaning |
|-------|---------|---------|
| `uiFontMode` | `glaze` | `glaze` (bundled Inter), `custom` or `google`. |
| `uiFontSize` | `system` | A number of pixels, or `system`. |
| `uiFontWeight` | `400` | `100`–`900`. |
| `uiLetterSpacing` | `0` | Extra spacing in pixels. |
| `customFont` | none | UI font file as a `data:` URI. |
| `customFontName` | none | Family name for `customFont`. |
| `googleFontName` | none | Google Fonts family for `google`. |
| `chatFontMode` | `ui` | `ui` (follow the UI font), `glaze`, `custom` or `google`. |
| `chatFontSize` | `system` | A number of pixels, or `system`. |
| `chatLetterSpacing` | `0` | Extra spacing in pixels. |
| `userMessageFontWeight` | `400` | User message weight, `100`–`900`. |
| `charMessageFontWeight` | `400` | Character message weight, `100`–`900`. |
| `chatFont` | none | Chat font file as a `data:` URI. |
| `chatFontName` | none | Family name for `chatFont`. |
| `chatGoogleFontName` | none | Google Fonts family for the chat. |

## Chat

| Field | Default | Meaning |
|-------|---------|---------|
| `chatLayout` | `default` | `default` (flat messages) or `bubble`. |
| `userBubbleColor` | derived | User bubble colour. |
| `charBubbleColor` | derived | Character bubble colour. |
| `userBubbleRadius` | `18` | User bubble corner radius. |
| `charBubbleRadius` | `18` | Character bubble corner radius. |
| `userBubbleGradient` | none | Two-stop gradient instead of the solid colour, encoded as `angle|#hex1|#hex2`; the angle is in CSS degrees, `0` points up. |
| `charBubbleGradient` | none | The same for character bubbles. |
| `userQuoteColor` | accent | Colour of quoted text in user messages. |
| `charQuoteColor` | accent | Colour of quoted text in character messages. |
| `userTextColor` | derived | User message text. |
| `charTextColor` | derived | Character message text. |
| `userItalicColor` | accent | Italic text, used for thoughts and actions. |
| `charItalicColor` | accent | The same for character messages. |
| `showUserAvatar` | `true` | Show the user avatar. |
| `showCharAvatar` | `true` | Show the character avatar. |
| `showUserName` | `true` | Show the user name. |
| `showCharName` | `true` | Show the character name. |
| `hideMessageId` | `false` | Hide the message number. |
| `hideGenerationTime` | `false` | Hide generation time. |
| `hideTokenCount` | `false` | Hide token counts. |
| `textBgOpacity` | `0` | Backdrop behind message text in the default layout, desktop only. |
| `chatBgMode` | `inherit` | `inherit` (the app background), `color`, `avatar` (the character's avatar) or `custom`. |
| `chatBgColor` | none | Chat background colour for `color`. |
| `chatBgImage` | none | Chat background image for `custom`, as a `data:` URI. |

## Layout and theme settings

| Field | Meaning |
|-------|---------|
| `layout` | Templates, stylesheets and the Chat-screen declaration. Covered in [Chat layout](#info/themes-layouts). |
| `themeValues` | The reader's values for the theme's own settings. Export writes them; there is rarely a reason to author them by hand. |

## A theme with a background

```json
{
  "name": "Paper",
  "themeMode": "light",
  "accentColor": "#8A5A3B",
  "uiColor": "#F4EBDD",
  "bgColor": "#EAE0CF",
  "bgImage": "data:image/png;base64,...",
  "bgDim": 0.05,
  "chatBgMode": "color",
  "chatBgColor": "#F4EBDD",
  "charTextColor": "#3A312A",
  "userTextColor": "#3A312A"
}
```

The editor writes the same fields and gives you a preview, so the usual way to
build a theme is to start there and export the result. Editing JSON by hand is
most useful for a layout that ships as an archive.
