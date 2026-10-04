#!/usr/bin/env node
// Renders the site's link-preview images (1200x630) in a real browser, so they
// use the site's own Inter, the SVG logo and its colours:
//   site/assets/img/og.png            the site
//   site/articles/<slug>/og.png       every article in data.js with a folder
//
// Run:
//   node scripts/site_og.js
// Needs playwright-core and a Chromium. PLAYWRIGHT_CORE points at the module
// when it is not installed locally, CHROMIUM at the browser binary.

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');

const SITE = path.join(__dirname, '..', 'site');
const asset = (p) => pathToFileURL(path.join(SITE, p)).href;

global.window = {};
require(path.join(SITE, 'assets', 'data.js'));
const G = window.GLAZE;

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// Shared frame: the site's background, its grain and the cherry glow.
const page = (body, extraCss = '') => `<!doctype html><html><head><meta charset="utf-8"><style>
  @font-face { font-family: 'Inter'; src: url('${asset('assets/fonts/InterVariable.ttf')}'); font-weight: 100 900; }
  * { box-sizing: border-box; margin: 0; }
  html, body { width: 1200px; height: 630px; overflow: hidden; }
  body {
    position: relative;
    font-family: 'Inter', sans-serif;
    color: #E1E3E6;
    background:
      radial-gradient(900px 620px at 0% 0%, rgba(196, 42, 74, 0.30), rgba(196, 42, 74, 0) 70%),
      radial-gradient(700px 500px at 100% 100%, rgba(196, 42, 74, 0.10), rgba(196, 42, 74, 0) 70%),
      #141415;
    -webkit-font-smoothing: antialiased;
  }
  body::after {
    content: ''; position: absolute; inset: 0; opacity: 0.05; pointer-events: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
  }
  .brand { display: flex; align-items: center; gap: 18px; }
  .brand img { display: block; }
  .brand b { font-weight: 800; letter-spacing: -0.03em; color: #F1F2F4; }
  .muted { color: #99A2AD; }
  .url { position: absolute; left: 80px; bottom: 56px; font-size: 24px; font-weight: 500; color: #99A2AD; }
  /* A phone screenshot leaning in from the right. */
  .phone {
    position: absolute; right: 70px; top: 70px; width: 300px; border-radius: 34px; overflow: hidden;
    border: 2px solid rgba(255, 255, 255, 0.12);
    box-shadow: 0 40px 80px rgba(0, 0, 0, 0.55), 0 0 0 10px rgba(255, 255, 255, 0.03);
    transform: rotate(6deg);
  }
  .phone img { display: block; width: 100%; }
  ${extraCss}
</style></head><body>${body}</body></html>`;

function siteCard() {
  return page(`
    <div style="position:absolute; left:80px; top:96px; width:640px">
      <div class="brand"><img src="${asset('assets/img/glaze.svg')}" width="112" height="112"><b style="font-size:104px">Glaze</b></div>
      <div style="margin-top:44px; font-size:44px; font-weight:700; letter-spacing:-0.02em; line-height:1.15">AI roleplay chat client</div>
      <div class="muted" style="margin-top:18px; font-size:28px; font-weight:500; line-height:1.4">Local, novice-friendly, open-source.<br>Android · iOS · Windows · Linux</div>
    </div>
    <div class="phone"><img src="${asset('assets/img/screens/web/phone_chat_en.webp')}"></div>
    <div class="url">hydall.github.io/Glaze</div>`);
}

const KIND = { changelog: { ru: 'Чейнджлог', en: 'Changelog' }, news: { ru: 'Новости', en: 'News' } };

function articleCard(a) {
  // Previews are in English, the language link previews reach the widest.
  const lang = a.langs.includes('en') ? 'en' : a.langs[0];
  const title = a.title[lang] || a.title.en;
  const lead = a.lead[lang] || a.lead.en;
  const date = new Intl.DateTimeFormat(lang === 'ru' ? 'ru-RU' : 'en-GB', { day: 'numeric', month: 'long', year: 'numeric' })
    .format(new Date(a.date + 'T12:00:00Z'));
  // "Glaze beta 0.8.0": the version in the accent colour.
  const titleHtml = esc(title).replace(/(\d+\.\d+\.\d+\S*)$/, '<span style="color:#E0566F">$1</span>');
  const au = G.authors[a.author];
  return page(`
    <div style="position:absolute; left:80px; top:72px; right:80px; display:flex; align-items:center; gap:18px">
      <div class="brand"><img src="${asset('assets/img/glaze.svg')}" width="56" height="56"><b style="font-size:40px">Glaze</b></div>
      <span class="chip">${esc((KIND[a.kind] || {})[lang] || a.kind)}</span>
    </div>
    <div style="position:absolute; left:80px; top:196px; width:1040px">
      <div style="font-size:96px; font-weight:800; letter-spacing:-0.035em; line-height:1.02">${titleHtml}</div>
      <div class="muted" style="margin-top:28px; font-size:28px; font-weight:500; line-height:1.4; max-width:1000px; display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden">${esc(lead)}</div>
    </div>
    <div style="position:absolute; left:80px; bottom:56px; display:flex; align-items:center; gap:16px; font-size:26px; font-weight:600">
      ${au ? `<img src="${asset('assets/img/' + au.img)}" style="width:52px; height:52px; border-radius:50%; object-fit:cover; border:2px solid rgba(196,42,74,0.7)">` : ''}
      <span>${esc(au ? au.name : a.author || '')} <span class="muted" style="font-weight:500">· ${esc(date)}</span></span>
    </div>
    <div class="muted" style="position:absolute; right:80px; bottom:62px; font-size:24px; font-weight:500">hydall.github.io/Glaze</div>`,
  `.chip { padding: 8px 18px; border-radius: 999px; background: rgba(196, 42, 74, 0.18); border: 1.5px solid rgba(196, 42, 74, 0.55); color: #F08DA0; font-size: 22px; font-weight: 700; letter-spacing: 0.02em; }`);
}

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined, args: ['--no-sandbox'] });
  const shot = async (html, out) => {
    const tmp = path.join(SITE, '.og-render.html');
    fs.writeFileSync(tmp, html);
    const p = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
    await p.goto(pathToFileURL(tmp).href, { waitUntil: 'load' });
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: out });
    await p.close();
    fs.unlinkSync(tmp);
    console.log('wrote', path.relative(process.cwd(), out));
  };
  await shot(siteCard(), path.join(SITE, 'assets', 'img', 'og.png'));
  for (const a of G.articles) {
    const dir = path.join(SITE, 'articles', a.slug);
    if (fs.existsSync(dir)) await shot(articleCard(a), path.join(dir, 'og.png'));
  }
  await browser.close();
})();
