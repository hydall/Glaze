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
    id: 'audio-embed',
    title: 'An audio embed inside a message',
    origin: 'Discord #1531795415253385277 - the player overhung the bubble',
    text: `Listen to this:
<audio controls src="https://cdn.discordapp.com/attachments/1/2/voice-message.ogg"></audio>`,
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
    id: 'imggen-authored-layout',
    title: 'Finished image block the card positioned itself',
    origin: 'INV-IG14 — "Polaroid Diaries" ExtBlocks preset',
    text: `<div style="display:flex;justify-content:center;margin:14px 0;padding:0 4px;box-sizing:border-box">
<div style="background:transparent;width:100%;max-width:380px;border-radius:3px;position:relative;box-sizing:border-box">
<div class="pol-frame" style="position:relative;overflow:hidden;line-height:0;width:100%;padding-top:66.3%">
<img data-iig-instruction='{"prompt":"a cat on a windowsill","aspect_ratio":"3:2"}' src="a.png" style="position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover;display:block;filter:saturate(0.8) contrast(1.1) brightness(1.03) sepia(0.1)" class="pol-photo">
<div style="position:absolute;top:0;left:0;right:0;bottom:0;background:linear-gradient(135deg,rgba(255,255,255,0.4) 0%,transparent 40%);pointer-events:none;mix-blend-mode:soft-light"></div>
</div>
<div style="padding:9px 14px 11px 14px;background:#f5f0e8;font-family:Georgia,serif;font-style:italic;color:#3a2e22;font-size:11.5px;text-align:center">Он даже не заметил, что я смотрю.</div>
</div>
</div>`,
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
    title: 'Guillemets, curly and straight quotes in one message',
    origin: 'formatter step 8; Discord #1549835404016881744',
    text: `«Он сказал «тихо» и вышел», затем “добавил <b title="не диалог">вслух</b>”, а после "прямо".`,
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
    id: 'pre-with-emphasis',
    title: 'Code in a <pre> that uses * and _ as operators',
    origin: 'the pre-parse marker scan reached inside a raw-text element the ' +
      'block pass never formats, so the run it held was never restored and ' +
      'the leak sweep deleted it: `<pre>if (*p) *p = 1;</pre>` rendered as ' +
      '`if (p = 1;`',
    text: `<pre>int *p = &n;
if (*p) *p = 1;
long _t_ = a * b * c;</pre>`,
  },
  {
    id: 'emphasis-across-element-boundary',
    title: 'Emphasis that opens inside an element and closes outside it',
    origin: 'the boundary the marker pass is now bound by: the two asterisks ' +
      'are in different containers, so they are not one run',
    text: `<span>*начало</span> конец* и <b>жирно *курсив* внутри</b>`,
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
  {
    id: 'fandom-guide-card',
    title: 'Regex-built guide card: styled <summary> headers and embedded fonts',
    origin: 'fandom_guide_regex over the fandom_guide_state ExtBlock — the ' +
      'arrow wrapper put the cover\'s picture, title and "now" paragraph in ' +
      'one flex row, so the title rendered one letter per line, and its ' +
      'data: @font-face was reported as a network load and never applied. ' +
      'Verbatim replace string with the regex groups filled in; the base64 ' +
      'images and fonts are swapped for tiny payloads.',
    text: `<div class="sg-root"><style>@font-face{font-family:"Shino Larp Display";font-style:normal;font-weight:700;font-display:swap;src:url("data:font/woff;base64,d09GRgABAAA=") format("woff")}
@font-face{font-family:"Shino Larp Text";font-style:normal;font-weight:400;font-display:swap;src:url("data:font/woff;base64,d09GRgABAAA=") format("woff")}
.sg{--sg-ink:#f2edf9;--sg-muted:#b8afca;--sg-line:#c6bbff26;--sg-mint:#acf3e4;font-family:"Shino Larp Text","Segoe UI",sans-serif!important;width:100%;max-width:420px;min-width:0;margin:10px auto;font-size:13px;line-height:1.7;color:var(--sg-ink);color-scheme:dark;text-align:left;overflow-wrap:anywhere}
.sg,.sg *{box-sizing:border-box;min-width:0}.sg p,.sg h2,.sg h3{margin:0}.sg summary{display:block;list-style:none;cursor:pointer;-webkit-tap-highlight-color:transparent}.sg summary::-webkit-details-marker{display:none}.sg img{display:block;max-width:100%;height:auto}.sg strong{color:#fff1dd}.sg summary:focus-visible{outline:2px solid #acf3e4;outline-offset:-4px;border-radius:14px}
.sg .sg-shell{position:relative;isolation:isolate;background:linear-gradient(145deg,#25203a,#15182c 55%,#172e32) padding-box,linear-gradient(135deg,#d3bef39c,#a3efe553 30%,#8d74c727 58%,#c9abe88f 85%,#adf8e97d) border-box;border:1px solid transparent;border-radius:23px;overflow:hidden;box-shadow:0 12px 28px #07071455,0 0 19px #b197ed0b,inset 0 1px 0 #fff2}
.sg .sg-cover{padding:13px;position:relative;background:radial-gradient(ellipse at 3% 0%,#b696e829,transparent 58%),radial-gradient(ellipse at 100% 50%,#8ddac114,transparent 65%)}
.sg .sg-cover:before{content:"";position:absolute;left:22px;right:22px;top:0;height:1px;background:linear-gradient(90deg,transparent,#d5c1ff,#b7ffed,transparent);opacity:.8;pointer-events:none}
.sg .sg-cover:after{content:"✧";position:absolute;right:12px;top:7px;color:#ccece5;font-size:24px;line-height:1;text-shadow:0 0 11px #b2e9f077;animation:sg-larp-star 5s ease-in-out infinite alternate;pointer-events:none}
.sg .sg-intro{display:flex;gap:13px;align-items:center}.sg .sg-hero{flex:0 0 98px;width:98px;height:112px!important;object-fit:cover;object-position:center;border:1px solid #ded0ff80;border-radius:35px 35px 13px 13px;background:#24253d;box-shadow:0 4px 17px #070a1944,0 0 0 3px #cbb3f309,inset 0 0 0 1px #fff2}
.sg .sg-heading{flex:1;padding-top:4px}.sg .sg-heading h2{font-family:"Shino Larp Display",Georgia,serif!important;font-weight:700!important;font-size:36px!important;line-height:.94!important;letter-spacing:-.8px;margin:3px 0 9px;padding:2px 0 5px}.sg .sg-title-tail{display:block;font:inherit;letter-spacing:inherit}
.sg .sg-heading h2,.sg .sg-label h3,.sg .sg-answer h3{color:#dfcfff;background-image:linear-gradient(105deg,#e6bffc 0%,#b8f8ec 22%,#fff4dd 40%,#d0c0ff 58%,#a6efe8 78%,#e6bffc 100%);background-size:260% 100%;background-position:0% 50%;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;animation:sg-larp-prism 9s ease-in-out infinite alternate;text-shadow:none!important}
.sg .sg-fandom{font-family:"Shino Larp Text","Segoe UI",sans-serif!important;font-size:10.5px;line-height:1.55;color:#c6bddb}.sg .sg-now{margin-top:13px;padding:11px 12px;background:linear-gradient(120deg,#d4b6ff0c,#b2f3de05);border:1px solid #ccbcf12c;border-left:2px solid #c1aeeb80;border-radius:3px 13px 13px 3px;font-size:12px;line-height:1.75;color:#dcd5e9;box-shadow:inset 0 1px 0 #fff04}.sg .sg-now b{font-weight:700;color:#c4f2e5}
.sg .sg-open{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:12px 2px 0;font-size:9px;letter-spacing:.3px;color:#baaacb}.sg .sg-open:after{content:"Развернуть ↘";flex:0 0 auto;color:#ccf4e9;padding:3px 9px;border:1px solid #b8eadd30;border-radius:99px;background:#b8eadd08}.sg .sg-shell[open]>.sg-cover .sg-open:after{content:"Свернуть ↗"}.sg .sg-body{padding:0 10px 11px;animation:sg-larp-enter .28s ease-out}.sg .sg-boundary{font-size:10px;line-height:1.65;color:var(--sg-muted);padding:2px 4px 9px}
.sg .sg-chapter{border:1px solid #c4b8eb29;border-radius:15px;margin-top:8px;background:linear-gradient(110deg,#c7aaf609,#a3edde03),#12152552;overflow:hidden;transition:border-color .25s,background-color .25s,box-shadow .25s}.sg .sg-chapter[open]{border-color:#b9e6dc55;background-color:#111a285c;box-shadow:0 3px 12px #090d1726}.sg .sg-chapter>summary{display:flex;align-items:center;gap:10px;min-height:71px;padding:7px 10px 7px 7px}.sg .sg-thumb{width:54px;height:54px!important;flex:0 0 54px;border-radius:11px;object-fit:cover;background:#302a43;border:1px solid #e0cef042;box-shadow:0 2px 8px #0003}.sg .sg-label{flex:1}.sg .sg-label h3{font-family:"Shino Larp Display",Georgia,serif!important;font-weight:700!important;font-size:27px!important;line-height:1.12!important;letter-spacing:-.3px;padding-bottom:2px;animation-delay:-3s}.sg .sg-caption{display:block;font-size:9px;color:#b5adc6;line-height:1.5;margin-top:1px}.sg .sg-chapter>summary:after{content:"+";display:grid;place-items:center;width:21px;height:21px;flex:0 0 21px;border:1px solid #c6b2ed24;border-radius:50%;background:#d2baff08;font-size:15px;color:#c9b7e8;line-height:1}.sg .sg-chapter[open]>summary:after{content:"−";color:#bcf0df;border-color:#a5e5d844}
.sg .sg-content{padding:0 12px 12px;border-top:1px solid #c8b5ee20;animation:sg-larp-enter .25s ease-out}.sg .sg-entry{padding:12px 0;border-bottom:1px solid #d9c8fa10}.sg .sg-entry:last-of-type{border:0}.sg .sg-entry-title{font-family:"Shino Larp Text","Segoe UI",sans-serif!important;display:flex;align-items:center;flex-wrap:wrap;gap:5px;font-weight:700;font-size:12px;color:#d5f1eb;line-height:1.5}.sg .sg-copy{font-size:12px;line-height:1.85;color:#cec5dc;margin-top:5px}.sg .sg-answer{border:1px solid #b9e6d73b;background:linear-gradient(125deg,#b0ead80c,#c4a2e709);border-radius:14px;margin:0 0 10px;padding:12px}.sg .sg-answer small{font-size:9px;letter-spacing:1.2px;color:#b5e4d7;font-weight:700}.sg .sg-answer h3{font-family:"Shino Larp Display",Georgia,serif!important;font-weight:700!important;font-size:27px!important;line-height:1.15;margin:5px 0 8px}.sg .sg-answer p{font-size:12px;color:#cbdcd8;line-height:1.8}
.sg .sg-boundary:empty,.sg .sg-answer[data-has-answer=""],.sg .sg-entry[data-has-entry=""]{display:none!important}.sg .sg-empty:not([data-has-entry=""]){display:none}.sg .sg-empty{color:var(--sg-muted);font-size:12px;padding-top:10px}
@keyframes sg-larp-prism{from{background-position:0% 50%}to{background-position:100% 50%}}@keyframes sg-larp-star{from{opacity:.45;transform:scale(.9) rotate(-12deg)}to{opacity:1;transform:scale(1.08) rotate(12deg)}}@keyframes sg-larp-enter{from{opacity:.65;transform:translateY(3px)}to{opacity:1;transform:translateY(0)}}
@media(hover:hover){.sg .sg-chapter:hover{border-color:#c9bbf66b;box-shadow:0 0 15px #baa3eb0a}.sg .sg-open:after{transition:background .2s}.sg .sg-cover:hover .sg-open:after{background:#b8eadd14}}
@media(max-width:350px){.sg .sg-cover{padding:10px}.sg .sg-intro{gap:10px}.sg .sg-hero{width:78px;height:98px!important;flex-basis:78px}.sg .sg-heading h2{font-size:31px!important}.sg .sg-label h3{font-size:25px!important}.sg .sg-thumb{width:46px;height:50px!important;flex-basis:46px}.sg .sg-chapter>summary{gap:8px;padding-right:8px}.sg .sg-body{padding:0 8px 9px}}
@media(prefers-reduced-motion:reduce){.sg *,.sg *:before,.sg *:after{animation:none!important;transition:none!important}.sg .sg-heading h2,.sg .sg-label h3,.sg .sg-answer h3{background-position:45% 50%}}
</style><div class="sg"><details class="sg-shell"><summary class="sg-cover"><div class="sg-intro"><img class="sg-hero" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="Шино в очках: объясняет у доски" width="112" height="112" decoding="async"><div class="sg-heading"><h2>Ларп <span class="sg-title-tail">с Шино</span></h2><p class="sg-fandom">Судная ночь: Кровавая неделя</p></div></div><div class="sg-now"><b>Сейчас · </b>События происходят в Новом Орлеане во время пятидневного периода абсолютного беззакония.</div><div class="sg-open"><span>Открыть темы</span></div></summary><div class="sg-body"><p class="sg-boundary"></p><section class="sg-answer" data-has-answer=""><small>ТВОЙ ВОПРОС</small><h3></h3><p></p></section><details class="sg-chapter"><summary><img class="sg-thumb" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="Шино в очках: изучает карту" width="56" height="56" decoding="async"><div class="sg-label"><h3>Мир</h3><span class="sg-caption">Жизнь, места и привычки</span></div></summary><div class="sg-content"><article class="sg-entry" data-has-entry="fg_entry"><div class="sg-entry-title">Заголовок</div><p class="sg-copy">Текст записи.</p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><p class="sg-empty" data-has-entry="fg_entry">Недостаточно достоверных сведений для этого раздела.</p></div></details><details class="sg-chapter"><summary><img class="sg-thumb" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="Шино в очках: рассматривает портреты" width="56" height="56" decoding="async"><div class="sg-label"><h3>Персонажи</h3><span class="sg-caption">Кто они и чем отличаются</span></div></summary><div class="sg-content"><article class="sg-entry" data-has-entry="fg_entry"><div class="sg-entry-title">Заголовок</div><p class="sg-copy">Текст записи.</p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><p class="sg-empty" data-has-entry="fg_entry">Недостаточно достоверных сведений для этого раздела.</p></div></details><details class="sg-chapter"><summary><img class="sg-thumb" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="Шино в очках: показывает магию" width="56" height="56" decoding="async"><div class="sg-label"><h3>Правила</h3><span class="sg-caption">Как всё устроено</span></div></summary><div class="sg-content"><article class="sg-entry" data-has-entry="fg_entry"><div class="sg-entry-title">Заголовок</div><p class="sg-copy">Текст записи.</p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><p class="sg-empty" data-has-entry="fg_entry">Недостаточно достоверных сведений для этого раздела.</p></div></details><details class="sg-chapter"><summary><img class="sg-thumb" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="Шино в очках: читает свиток у часов" width="56" height="56" decoding="async"><div class="sg-label"><h3>История</h3><span class="sg-caption">Прошлое и становление мира</span></div></summary><div class="sg-content"><article class="sg-entry" data-has-entry="fg_entry"><div class="sg-entry-title">Заголовок</div><p class="sg-copy">Текст записи.</p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><p class="sg-empty" data-has-entry="fg_entry">Недостаточно достоверных сведений для этого раздела.</p></div></details><details class="sg-chapter"><summary><img class="sg-thumb" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="Шино в очках: читает словарь" width="56" height="56" decoding="async"><div class="sg-label"><h3>Словарь</h3><span class="sg-caption">Термины простыми словами</span></div></summary><div class="sg-content"><article class="sg-entry" data-has-entry="fg_entry"><div class="sg-entry-title">Заголовок</div><p class="sg-copy">Текст записи.</p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><p class="sg-empty" data-has-entry="fg_entry">Недостаточно достоверных сведений для этого раздела.</p></div></details><details class="sg-chapter"><summary><img class="sg-thumb" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="Шино в очках: придумывает историю" width="56" height="56" decoding="async"><div class="sg-label"><h3>Идеи</h3><span class="sg-caption">Простор для твоей игры</span></div></summary><div class="sg-content"><article class="sg-entry" data-has-entry="fg_entry"><div class="sg-entry-title">Заголовок</div><p class="sg-copy">Текст записи.</p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><article class="sg-entry" data-has-entry=""><div class="sg-entry-title"></div><p class="sg-copy"></p></article><p class="sg-empty" data-has-entry="fg_entry">Недостаточно достоверных сведений для этого раздела.</p></div></details></div></details></div></div>`,
  },
  {
    id: 'https-font-face-card',
    title: 'Card whose @font-face loads its font over https',
    origin: 'INV-MR5 — https fonts are allowed, as SillyTavern allows external media',
    text: `<style>
@font-face { font-family: "Net Card Font"; src: url("https://fonts.example/net.woff2") format("woff2"); }
.nf-title { color: rgb(6, 7, 8); font-family: "Net Card Font", serif; }
</style>
<div class="nf-title">Заголовок</div>`,
  },
  {
    id: 'http-font-face-card',
    title: 'Card whose @font-face loads its font over plain http',
    origin: 'INV-MR5 — http is a downgrade and is refused, like an http @import',
    text: `<style>
@font-face { font-family: "Plain Card Font"; src: url("http://fonts.example/plain.woff2") format("woff2"); }
.pf-title { color: rgb(6, 7, 9); font-family: "Plain Card Font", serif; }
</style>
<div class="pf-title">Заголовок</div>`,
  },
  {
    id: 'external-media-card',
    title: 'Card that loads media, a sheet and a font from third-party hosts',
    origin: '"Allow external media" — off must drop every remote load and ' +
      'keep embedded and Glaze-served media',
    text: `<style>
@import url('https://fonts.example/sheet.css');
@font-face { font-family: "Remote Face"; src: url("https://fonts.example/r.woff2") format("woff2"); }
@font-face { font-family: "Embedded Face"; src: url("data:font/woff2;base64,d09GMgABAAA=") format("woff2"); }
.em-bg { background: url("https://cdn.example/bg.png") center / cover, rgb(1, 2, 3); color: rgb(4, 5, 6); }
.em-local { background-image: url("http://127.0.0.1:1/local.png"); }
</style>
<div class="em-bg">Фон</div>
<div class="em-local">Локально</div>
<img class="em-remote" src="https://cdn.example/pic.png" alt="remote">
<img class="em-proto" src="//cdn.example/pic.png" alt="protocol-relative">
<img class="em-data" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" alt="data">
<img class="em-file" src="file:///data/user/0/app/files/pic.png" alt="file">
<img class="em-srcset" srcset="https://cdn.example/a.png 1x, /local/b.png 2x" alt="srcset">
<video class="em-video" poster="https://cdn.example/poster.png"><source src="https://cdn.example/clip.mp4"></video>
<div class="em-inline" style="background-image: url(https://cdn.example/i.png); color: rgb(7, 8, 9);">Инлайн</div>
<a class="em-link" href="https://example.com/page">ссылка</a>`,
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
  'pre-with-emphasis',
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
