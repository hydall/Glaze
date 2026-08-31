# Message Rendering Rules

Rules for `assets/chat_webview/formatter/` and `assets/chat_webview/renderer/` —
everything that turns a message body into what the reader sees.

Read this before changing either directory. The behaviour it describes is
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

## Markers are inline, always

`renderStyledSegment()` renders a marker's content through `formatInlineRaw()`,
which cannot produce a block element. A `<p>` inside a marker's `<span>` is
markup the browser throws straight back out — the marker then shows as empty
text. See `docs/markdown-markers.md` for the marker list itself.

Which is why **a marker only holds markup it opened and closed itself**
(`holdsOwnMarkup` in `protect.js`). Tags are one opaque run to the marker scan,
so a `*` a model wrote before a card and a `*` that landed inside it — which is
what a display regex does when its capture group swallows the closing marker —
match as one emphasis run over the whole card. Holding that span hands the card
to the inline pass: its `<style>` goes with it (a held segment is never
unmasked, so the leak sweep deletes the stylesheet) and the browser throws the
card's block elements back out of the `<em>` as siblings of the message.

Two rules keep that from happening, both on the way *into* the marker store:

* a candidate whose tags do not nest to zero is not a marker — the asterisks
  stay literal text, and the card renders as the card it is;
* a candidate carrying a masked `<style>` / `<script>` body is not a marker
  either. A stylesheet is not emphasis.

Balance is counted with `markupTagTest` — the same answer `escapeProseTags`
gives — so `*он прошептал <вздох> тихо*` is still one italic run, and void
elements (`<br>`, `<img>`) never leave anything open. A marker that spans
*balanced* markup, which is how `html_to_markdown` writes rich colour
(`==hc:#fff==<b>x</b>==`), matches exactly as before.

---

## The message body renders into a shadow root

`.message-content` gets an open shadow root (`message_renderer.js`), which is
what keeps a card's CSS out of the app chrome. What a card may rely on inside
that root is a fixed list, not a guess: `renderer/message_document.js` and
`docs/INVARIANTS.md` § 11 (INV-MR1…INV-MR8). Add to that contract rather than
shimming one more case where it happens to be needed.
