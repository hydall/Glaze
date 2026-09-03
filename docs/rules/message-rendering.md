# Message Rendering Rules

Rules for `assets/chat_webview/formatter/`, `assets/chat_webview/renderer/` and
the virtualised list they render into (`assets/chat_webview/useVirtualScroll.js`)
— everything that turns a message body into what the reader sees.

Read this before changing any of them. The behaviour it describes is
covered by `test/webview_js` (a real browser renders the card corpus); the
shape of the modules is covered by `test/webview_assets_test.dart`.

---

## Every rendering bug becomes a corpus entry before it is fixed

`test/webview_js/corpus/cards.js` holds the message bodies worth protecting,
verbatim, each with the PR or audit it came from. The workflow is:

1. add the card that renders wrong, exactly as the author or model wrote it;
2. add the assertion that fails;
3. fix the renderer.

A fix without an entry is a fix the next refactor is free to undo — which is
how the same three bugs came back six times in ten days. If a case cannot be
served yet, commit it as `test.fail()` naming what would make it pass, rather
than leaving it out.

---

## The render is two phases, and the parser owns structure

```
protect  →  parse (phase A)  →  format text nodes (phase B)  →  restore
```

* **Phase A** (`html_scan.js`, `parseHtml`) hands the message to the browser's
  HTML parser. What is an element, how elements nest, and where an unclosed tag
  ends are the parser's answers. This is what makes a card render as a card
  from its first streamed chunk instead of flickering as raw tags.
* **Phase B** (`dom_format.js`, `block_syntax.js`, `inline_syntax.js`) applies
  markdown to **text nodes only**, with elements masked out of the string the
  passes see.

**Never add a markdown pass that runs over a string containing live HTML.**
That is what the old formatter did, and every one of its 25 numbered steps was
one more chance to eat somebody's markup.

---

## What is markup is decided by the vocabulary, not by counting

`escapeProseTags()` escapes a tag into visible text only when its name is not
an HTML/SVG/MathML element **and** the message's own CSS does not style it
**and** it has no matching closing tag. `<вздох>` in prose stays a word;
`<loomledger>` in a card stays a container.

Do not reintroduce either of the heuristics this replaced:

* an "orphan" rule keyed on how many times a tag name occurs in the message;
* a hand-kept list of which tags are block-level.

Both were lists that every slightly-different card fell off the end of.

---

## `<p>` is added at the top level of a message and nowhere else

Inside markup the author wrote, nothing is wrapped. A paragraph of ours around
someone's card reparents their elements, and `#toggle:checked ~ .overlay` —
the selector every CSS-only card is built on — stops matching the moment its
two halves stop being siblings.

At the top level a run of text is still not wrapped when it touches a block
element the author wrote with no blank line between them
(`touchesBlockSibling` in `dom_format.js`): `<input><label>…</label><div>` is
one card, not a paragraph followed by a card.

---

## A protected region is atomic

`protect.js` takes out, before the parse:

| Region | Why |
|---|---|
| fenced and inline code | prose *about* a tag is not a tag |
| image tags (`[IMG:…]`, `<img data-iig-…>`) | they render as app UI, and their order is `data-img-index` (INV-IG6) |
| markdown images | the wrapper, the picture and the options button are one positioned card |
| `<think>` blocks | the model's own panel, rendered recursively |
| style markers (`==hc:…==`, `**…**`) | a marker may span a tag, and a parsed marker is two text nodes with an element between them |

A region comes back as one unit after phase B. Do not emit its markup into the
text mid-pipeline: whatever pass runs next will take it apart.

---

## Markers are inline, always — and they come from a run, not from the message

`renderStyledSegment()` renders a marker's content through
`formatInlineMasked()`, which cannot produce a block element. A `<p>` inside a
marker's `<span>` is markup the browser throws straight back out — the marker
then shows as empty text. See `docs/markdown-markers.md` for the marker list
itself.

Markers are taken in `formatRun` (`dom_format.js`), from the string that pass
has already built: one container's text nodes escaped, its inline elements
replaced by `E_n` placeholders. That string holds no markup at all, which is
what makes the scan safe. Three properties follow from *where* it runs, not
from anything the scan checks:

* a marker cannot reach across a block element, because a block element ends
  the run;
* a marker cannot open inside an element and close outside it, because those
  are two different runs;
* a marker cannot reach inside `<pre>`, `<script>` or `<style>`, because those
  are `OPAQUE` and never get a run.

It still runs before `applyBlockSyntax`, not per line: `==hc:#fff==` matches
with `s` and may wrap several lines, and the block pass formats a line at a
time.

**This is the pass that used to be the exception.** It ran before the parse, on
the raw message, with tags masked — and every property above was something it
had to guess. A `*` a model wrote before a regex-built card and the `*` the
script's capture pulled into the card matched as one emphasis run over the
whole card, taking its `<style>` with it; the same scan reached inside a `<pre>`
the block pass never formats, so the run it held was never restored and the
leak sweep deleted it. Do not move it back in front of the parse: there is now
no markdown pass anywhere that reads a string containing live HTML.

---

## The render window is never allowed to leave the viewport

The list is virtualised (`useVirtualScroll.js`): only a window of rows is
mounted, and an `IntersectionObserver` grows that window as rows come into
view. The observer is a *local* mechanism — it can only report on rows that
are already mounted and within its `1000px` margin. So the one state it cannot
recover from is the window drifting entirely off the viewport: nothing is near
enough to report, `visibleIndices` empties, and there is no visible index left
to grow the window from. The chat renders nothing, and no amount of scrolling
brings it back — only a fresh `setMessages`, which is why the symptom was
"open another chat and come back".

Three things move the rows out from under a scroll position that does not move
with them: a delete or an append rewrites the spacers, a late height correction
(images, fonts, badges) rewrites them again from the `ResizeObserver`, and a
fast scroll can outrun the observer entirely.

So every one of those paths ends at `_recoverIfViewportIsBlank()`, and the
recovery it runs (`_recenterOnScrollPosition`) is derived from the scroll
position and the height cache alone — it needs neither an observer entry nor a
mounted row. It moves the window and never `scrollTop`, so a `scrollToBottom`
or a streaming `smartScroll` already in flight still lands where it meant to.

Two rules follow, and `specs/virtual_window.spec.js` holds them:

* **no early return may leave the list with nothing rendered.** `updateWindow`
  returning on an empty `visibleIndices` is exactly the bug above.
* **anything that renumbers `items` renumbers the observer's index sets too.**
  The observer reports an index, not an id. `remove` and `prepend` shift
  `visibleIndices` / `realVisibleIndices` the same way they shift the height
  cache; a set left on the old numbering points the next `updateWindow` at
  somebody else's row, and past the end of the list once enough rows go.

---

## A user message wears the persona it was sent as, not the active one

Every user message stores the persona it was sent under — `personaId` and
`personaName` (`ChatNotifier._sendMessage`). By the time the map reaches the
page that id is already resolved against the live roster
(`ChatBridgeController.setPersonaRoster`):

* the persona still exists → the map carries its `avatarUrl` and its *current*
  name, so renaming a persona renames the messages it sent;
* it was deleted, or has no picture → `avatarFallback: true`, and the message
  keeps the name stored on it while the avatar drops to the initial letter.

Either way the renderer stamps `data-avatar-pinned` on the section, and
`setIdentity` — which repaints every avatar in the DOM — skips the pinned ones.
Without that skip, switching persona re-faces the whole history, and a message
from a deleted persona borrows the picture of whoever is active now.
`specs/message_persona.spec.js` holds this.

A message written before personas were stamped carries neither field: it is
unpinned and keeps following the active identity, which is all there is to go
on for it.

---

## The message body renders into a shadow root

`.message-content` gets an open shadow root (`message_renderer.js`), which is
what keeps a card's CSS out of the app chrome. What a card may rely on inside
that root is a fixed list, not a guess: `renderer/message_document.js` and
`docs/INVARIANTS.md` § 11 (INV-MR1…INV-MR8). Add to that contract rather than
shimming one more case where it happens to be needed.
