// The card corpus.
//
// Every rendering bug becomes an entry here *before* it is fixed. An entry is
// the message text exactly as a model (or a card author) writes it; the specs
// say what the browser must make of it. `origin` records where the case came
// from, so nobody has to guess later whether an oddity is deliberate.
//
// Keep entries verbatim. Trimming a card to "just the failing part" is how a
// case stops covering the thing that broke.

export const cards = [
  {
    id: 'html-table',
    title: 'Hand-written HTML table',
    origin: 'audit 28.08 — <p> was injected between <table> and <tr>',
    text: `<table class="stats">
<tr><th>Стат</th><th>Знач</th></tr>
<tr><td>HP</td><td>12</td></tr>
</table>`,
  },
  {
    id: 'css-only-checkbox',
    title: 'CSS-only card: hidden checkbox toggles a sibling overlay',
    origin: '#326 — fixed for a paragraph without text; text in the <label> broke it again',
    text: `<style>
.ov { display: none; }
#t1:checked ~ .ov { display: block; }
</style>
<input type="checkbox" id="t1"><label for="t1">жать</label><div class="ov">скрыто</div>`,
  },
  {
    id: 'target-card',
    title: ':target panel toggled by a fragment link',
    origin: '#339',
    text: `<style>
.panel { opacity: 0; height: 0; overflow: hidden; }
#vn-k7x1:target { opacity: 1; height: auto; }
</style>
<a href="#vn-k7x1" class="open">Открыть</a>
<div id="vn-k7x1" class="panel">Содержимое панели</div>`,
  },
  {
    id: 'script-card',
    title: 'Card whose <script> declares the function its onclick calls',
    origin: 'f7477cf — the function was scoped to the wrapper, so onclick threw',
    text: `<div class="jsc"><button id="jsc-btn" onclick="jscToggle()">Показать</button><div id="jsc-out" hidden>Открыто</div></div>
<script>
function jscToggle() {
  var out = document.getElementById('jsc-out');
  out.hidden = !out.hidden;
}
</script>`,
  },
  {
    id: 'style-and-inline-style',
    title: '<style> block and inline style="" survive with scripts off',
    origin: '#290',
    text: `<style>.plate { color: rgb(10, 200, 30); }</style>
<div class="plate" style="letter-spacing: 3px;">Табличка</div>`,
  },
  {
    id: 'video-source',
    title: '<video> with a single <source> child',
    origin: '#326 — <source> is void, the orphan rule escaped it into text',
    text: `<video controls width="240"><source src="clip.mp4" type="video/mp4"></video>`,
  },
  {
    id: 'details-block',
    title: '<details>/<summary> spoiler',
    origin: '#326',
    text: `<details><summary>Спойлер</summary>
Скрытый текст под катом.
</details>`,
  },
  {
    id: 'svg-icon',
    title: 'Inline SVG icon inside a card',
    origin: '#326 — <p> was inserted inside <svg>',
    text: `<div class="ico"><svg viewBox="0 0 24 24" width="16" height="16"><path d="M12 2 2 22h20z"></path></svg> готово</div>`,
  },
  {
    id: 'markdown-basics',
    title: 'Plain markdown message: prose, emphasis, quotes',
    origin: 'baseline',
    text: `Она вошла в комнату.

*Он поднял взгляд.* "Ты опоздала," — сказал он.

**Важно:** ~~забудь~~ помни об этом.`,
  },
  {
    id: 'markdown-structure',
    title: 'Markdown headings, lists and a pipe table',
    origin: 'baseline',
    text: `## Отчёт

- первый пункт
- второй пункт
  - вложенный

1. раз
2. два

| Поле | Значение |
| --- | --- |
| HP | 12 |
| MP | 3 |`,
  },
  {
    id: 'ordered-list-zero',
    title: 'Ordered Markdown list starting at zero',
    origin: 'Discord #1543310048007295086 — `0. test` rendered as `1. test`',
    text: `0. test`,
  },
  {
    id: 'prose-angle-brackets',
    title: 'Prose that contains angle brackets',
    origin: 'the orphan heuristic existed for this case',
    text: `Он прошептал <вздох> и добавил: 5 < 7 > 3.`,
  },
  {
    id: 'inline-code-tag',
    title: 'A tag written inside backticks is prose about a tag',
    origin: 'formatter step 2b',
    text: 'Пиши `<div>` в начале карточки, а не ```<span>```.',
  },
  {
    id: 'fenced-code',
    title: 'Fenced code block with HTML inside',
    origin: 'baseline',
    text: '```html\n<div class="card">\n  <b>x</b>\n</div>\n```',
  },
  {
    id: 'md-link',
    title: 'Markdown link and a bare anchor inside a message',
    origin: '#339 — links inside the message did not fire',
    text: `Смотри [документацию](https://example.org/docs) и <a href="https://example.org/two">вторую ссылку</a>.`,
  },
  {
    id: 'md-image',
    title: 'Janitor-style markdown image with its options button',
    origin: 'formatter step 5b',
    text: `![портрет](https://example.org/p.png)`,
  },
  {
    id: 'stat-card',
    title: 'Composite card: header, table, bars, custom element',
    origin: 'representative of the diary/ledger cards users write',
    text: `<style>
@import url('https://fonts.example/css2?family=Card');
loomledger { display: block; font-family: 'Card', cursive; }
.ll-head { color: rgb(200, 40, 90); font-weight: 700; }
.ll-bar { height: 6px; background: rgb(40, 40, 40); }
.ll-bar > i { display: block; height: 100%; background: rgb(200, 40, 90); }
</style>
<loomledger>
<div class="ll-head">Дневник</div>
<table class="ll-tab"><tr><td>Доверие</td><td><div class="ll-bar"><i style="width:70%"></i></div></td></tr></table>
<div class="ll-note">*Она отвела взгляд.*</div>
</loomledger>`,
  },
  {
    id: 'think-block',
    title: 'Reasoning block written inline by the model',
    origin: 'formatter step 1a/17',
    text: `<think>Надо ответить коротко.</think>
Хорошо, идём.`,
  },
  {
    id: 'imggen-pending',
    title: 'Pending image block',
    origin: 'INV-IG1',
    text: `Смотри: [IMG:GEN:девушка у окна]`,
  },
  {
    id: 'imggen-result',
    title: 'Finished image block with two variants',
    origin: 'INV-IG8',
    text: `<img src="a.png" data-iig-instruction="девушка" data-iig-variants="a.png;;b.png" data-iig-index="0">`,
  },
  {
    id: 'glaze-markers',
    title: 'Glaze colour markers',
    origin: 'formatter step 7',
    text: `==hc:#ff0066==Красным== и ==accent==акцентом==, обычный текст.`,
  },
  {
    id: 'blockquote-hr',
    title: 'Blockquote and horizontal rule',
    origin: 'baseline',
    text: `> цитата

---

после черты`,
  },
  {
    id: 'br-in-card',
    title: '<br> inside a card body',
    origin: '#326',
    text: `<div class="note">Первая строка<br>Вторая строка</div>`,
  },
  {
    id: 'nested-quotes',
    title: 'Guillemets and straight quotes in one message',
    origin: 'formatter step 8',
    text: `«Он сказал «тихо» и вышел», — а потом "добавил вслух".`,
  },
  {
    id: 'inline-tags-in-prose',
    title: 'Prose with inline tags, quotes and markers across them',
    origin: 'audit 28.08 — the string formatter matched these across live HTML',
    text: `Привет <b>мир</b>

"Диалог с <b>тегом</b> внутри", ==hc:#ff0066==<i>цветной курсив</i>== и всё.`,
  },
  {
    id: 'font-gradient',
    title: '<font> gradient fill with the text in a nested span',
    origin: 'formatter step 18 — background-clip:text had nothing to clip',
    text: `<font style="background-image:linear-gradient(90deg,#ff0000,#0000ff);-webkit-background-clip:text;-webkit-text-fill-color:transparent"><span style="letter-spacing:1px">Градиент</span></font>`,
  },
  {
    id: 'form-controls',
    title: 'A card built out of form controls',
    origin: 'html_sanitizer keeps <form> for message HTML',
    text: `<form class="picker"><fieldset><legend>Выбор</legend><input type="radio" name="r" id="r1" checked><label for="r1">Раз</label></fieldset></form>`,
  },
  {
    id: 'doc-query-card',
    title: 'Card script that looks its elements up through the document',
    origin: 'INV-MR3/MR4 — a shadow root is not the document',
    text: `<div class="dq"><span id="dq-out">-</span><b class="dq-tag">x</b><form name="dq-form"><input name="dq-field" value="v"></form></div>
<script>
(function () {
  var out = document.getElementById('dq-out');
  out.textContent = [
    document.querySelector('.dq-tag') ? 'qs' : '',
    document.getElementsByClassName('dq-tag').length,
    document.getElementsByTagName('b').length,
    document.getElementsByName('dq-field').length,
    document.forms.length,
  ].join('/');
})();
</script>`,
  },
  {
    id: 'doc-body-card',
    title: 'Card that puts its modal in document.body',
    origin: 'INV-MR6 — the node used to leave the message and lose its CSS',
    text: `<style>.db-modal { color: rgb(9, 90, 200); }</style>
<div class="db"><button id="db-open" onclick="dbOpen()">Открыть</button></div>
<script>
function dbOpen() {
  var modal = document.createElement('div');
  modal.className = 'db-modal';
  modal.id = 'db-modal';
  modal.textContent = 'модалка';
  document.body.appendChild(modal);
}
</script>`,
  },
  {
    id: 'doc-ready-card',
    title: 'Card that waits for DOMContentLoaded',
    origin: 'INV-MR7 — the real event fired long before the message existed',
    text: `<div class="dr"><span id="dr-out">ждём</span></div>
<script>
document.addEventListener('DOMContentLoaded', function () {
  document.getElementById('dr-out').textContent = 'готово';
});
window.onload = function () {
  document.getElementById('dr-out').textContent += '+load';
};
</script>`,
  },
  {
    id: 'script-comparison',
    title: 'Card script that compares with < and > and no spaces',
    origin: 'audit 28.08 — the tag scan read `i<n; i++) { if (i>` as a tag',
    text: `<div id="sc-out">-</div>
<script>
var n=3,o='';
for(var i=0;i<n;i++){if(i>1)o+=i;}
document.getElementById('sc-out').textContent='ok'+o;
</script>`,
  },
  {
    id: 'regex-card-in-emphasis',
    title: 'Regex-built card with the model\'s asterisks around it',
    origin: 'a display regex turns `(out) Name | text` lines into this card, ' +
      'and the model wrote the block in italics. The opening `*` sat before ' +
      'the card and the closing one was pulled into the last bubble, so the ' +
      'marker held the whole card: its <style> was dropped and <details> ' +
      'lost everything up to the footer, which the browser reparented as a ' +
      'sibling.',
    text: `Он набрал сообщение.

*<div class="imsg-wrap"><style>@import url('https://fonts.example/css2?family=Card');.imsg-wrap{display:flex;justify-content:center}.imsg-details{width:fit-content;border-radius:20px}.imsg-msg{display:none;flex-direction:column}.imsg-msg[data-dir="(out)"]{display:flex;align-items:flex-start}.imsg-bubble{padding:6px 11px;border-radius:16px}.imsg-send svg{width:11px;height:11px;fill:none;stroke:#fff}</style><details class="imsg-details" open><summary class="imsg-summary"><span class="imsg-dot"></span><span class="imsg-label">New Notification</span></summary><div class="imsg-body"><div class="imsg-msg" data-dir="(out)"><span class="imsg-name">Влад</span><div class="imsg-bubble">спокойной кошка</div></div><div class="imsg-msg" data-dir="(out)"><span class="imsg-name">Влад</span><div class="imsg-bubble">🤍*</div></div></div><div class="imsg-footer"><div class="imsg-input">iMessage</div><div class="imsg-send"><svg viewBox="0 0 24 24"><line x1="12" y1="19" x2="12" y2="5"/><polyline points="5 12 12 5 19 12"/></svg></div></div></details></div>

Он убрал телефон.`,
  },
  {
    id: 'emphasis-over-inline-tag',
    title: 'Emphasis and a colour marker that legitimately span a tag',
    origin: 'the guard for regex-card-in-emphasis must not cost these: the ' +
      'markup inside is balanced, so the marker still holds it',
    text: `*шёпот <b>громче</b> и снова тише* — ==hc:#00ff00==<i>зелёный</i>== и <br> подряд.`,
  },
  {
    id: 'import-font-card',
    title: 'Card whose CSS imports a web font',
    origin: 'INV-MR5 — @import is ignored inside a shadow root',
    text: `<style>
@import url('https://fonts.example/css2?family=Card');
.if-title { font-family: 'Card', cursive; }
</style>
<div class="if-title">Заголовок</div>`,
  },
  {
    id: 'import-insecure-card',
    title: 'Card that imports over http, and one that imports a data: sheet',
    origin: 'INV-MR5 — only https is hoisted',
    text: `<style>
@import url('http://fonts.example/plain.css');
@import "data:text/css,body{display:none}";
.ii-title { color: rgb(3, 4, 5); }
</style>
<div class="ii-title">Заголовок</div>`,
  },
];

/** Cards whose first chunks must already render as a card, not as raw tags. */
export const streamingCards = [
  'html-table',
  'css-only-checkbox',
  'target-card',
  'stat-card',
  'details-block',
  'svg-icon',
  'br-in-card',
  'regex-card-in-emphasis',
];

export function card(id) {
  const found = cards.find((entry) => entry.id === id);
  if (!found) throw new Error(`No corpus card "${id}"`);
  return found;
}

/**
 * Streaming prefixes of a card body: what the reader sees while the reply is
 * still arriving. The steps are deliberately coarse — the point is to cross
 * every "tag half written / element not yet closed" boundary, not to test
 * every character.
 */
export function prefixes(text, steps = 8) {
  const out = [];
  for (let i = 1; i <= steps; i++) {
    const cut = Math.floor((text.length * i) / (steps + 1));
    if (cut > 0) out.push(text.slice(0, cut));
  }
  return out;
}
