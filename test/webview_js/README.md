# WebView render tests

Browser tests for the chat WebView assets. They load the **real** modules out
of `assets/chat_webview/` in a headless Chromium and assert on what the browser
built: the DOM inside the message shadow root, the CSS it resolved, and what a
click does.

`test/webview_assets_test.dart` stays what it is — static checks on the *source*
of those assets. It cannot catch a rendering regression, which is why these
exist.

## Running

```bash
cd test/webview_js
npm ci                       # or: npm install
npx playwright install chromium
npm test
```

`npm test` starts the static server in `harness/server.js` itself (the harness
imports the assets by their real paths, and ES modules do not load over
`file://`).

## Layout

| Path | What it is |
|---|---|
| `corpus/cards.js` | the card corpus — one entry per message body worth protecting |
| `harness/harness.html`, `harness/harness.js` | one message, rendered exactly the way `message_renderer.js` renders it |
| `harness/server.js` | static server rooted at the repository |
| `specs/cards.spec.js` | the structure the browser must build for each card |
| `specs/interaction.spec.js` | clicks, `:target`, links, scripts-off behaviour |
| `specs/streaming.spec.js` | every prefix of a card body renders as a card |
| `specs/document_contract.spec.js` | what a card may rely on inside the shadow root (INV-MR1…MR8) |

## The rule

**Every rendering bug becomes a corpus entry before it is fixed.** A fix
without an entry is a fix the next refactor is free to undo. Add the message
body verbatim to `corpus/cards.js` with an `origin` note, add the assertion
that fails, then fix the renderer.

A case the current renderer genuinely cannot serve yet is marked `test.fail()`
with a comment naming the stage that will make it pass — so the baseline is
recorded rather than lost.
