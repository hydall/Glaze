## Importing a .thm

A Tavo theme is a ZIP with `theme.json` and an `assets/` folder. Glaze accepts
it through the same **Import Theme** dialog as its own presets. The result is
an ordinary Glaze preset: it appears in the list, can be edited, exported and
shared like any other theme.

The import maps the parts Tavo and Glaze have in common:

| Tavo | Glaze |
|------|-------|
| Background, console and status colours | App palette and background |
| User and character bubble colours, radii and fonts | Chat bubble and font settings |
| Avatar and name visibility, including group settings | The matching chat switches |
| `background.image` from the archive | App background image |
| `background.charAvatar` | Character avatar as the chat background |
| `custom_css` | Page, message-body and chrome stylesheets |

## What happens to custom CSS

Tavo themes style a different DOM. Glaze adds Tavo's public `.tavo-*` class
names as aliases next to its own, then sorts the rules by what they can reach:

- Rules for the page, message sections, bubbles, avatars, speaker names,
  reasoning, attachments and action buttons go to the page stylesheet.
- Rules that reach the text inside a message, such as `.tavo-message-content p`
  or `q::after`, go to each message's shadow root. The user/character
  distinction is kept with `:host(.user)` and `:host(.char)`.
- Composer rules go to the chrome stylesheet, where the input surface, field
  and send button carry the matching `.tavo-composer-*` aliases.

A few Tavo constructs have a direct Glaze equivalent:

| Tavo | Glaze |
|------|-------|
| `<q>` and `a[href="#speech"]` | The quote and speech styling, `.chat-quote` and `.chat-quote-text` |
| Reasoning `<summary>` | The reasoning header |
| Legacy `.tav-*` selectors | Normalised to `.tavo-*` |

Tavo's `url("theme/assets/...")` references are replaced with the file from the
archive as a `data:` image. External URLs and fonts are not fetched.

## Limits

Only Tavo's documented public selectors are translated. Private classes may
match by accident, but they are not covered and can change.

Tavo's visual-novel display mode has no Glaze equivalent. Such a theme imports
as a normal chat with the colours, fonts and CSS it carries.

A converted theme will not always be pixel-identical: the two apps arrange
avatars, headers and message parts differently. The CSS is kept as a starting
point: colours and chat settings can be adjusted in the Glaze editor, while the
layout and CSS are edited in the exported JSON and imported again.
