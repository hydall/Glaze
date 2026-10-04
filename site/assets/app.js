(() => {
  'use strict';

  const G = window.GLAZE;
  const SECTIONS = ['overview', 'articles', 'features', 'screenshots', 'download', 'roadmap', 'resources'];
  // Download is reached through the header button, not a regular tab.
  const TABS = SECTIONS.filter((s) => s !== 'download');
  const LANGS = { ru: 'Русский', en: 'English' };
  const SECTION_ICONS = { overview: 'home', features: 'widgets', screenshots: 'photo_library', articles: 'article', download: 'download', roadmap: 'timeline', resources: 'link' };

  const BRAND = {
    github: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>',
    discord: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515a.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0a12.64 12.64 0 0 0-.617-1.25a.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057a19.9 19.9 0 0 0 5.993 3.03a.078.078 0 0 0 .084-.028a14.09 14.09 0 0 0 1.226-1.994a.076.076 0 0 0-.041-.106a13.107 13.107 0 0 1-1.872-.892a.077.077 0 1 1-.008-.128a10.2 10.2 0 0 0 .372-.292a.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127a12.299 12.299 0 0 1-1.873.892a.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028a19.839 19.839 0 0 0 6.002-3.03a.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.028zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419c0-1.333.956-2.419 2.157-2.419c1.21 0 2.176 1.096 2.157 2.42c0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419c0-1.333.955-2.419 2.157-2.419c1.21 0 2.176 1.096 2.157 2.42c0 1.333-.946 2.418-2.157 2.418z"/></svg>',
    telegram: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z"/></svg>',
    boosty: '<svg viewBox="0 0 235.6 292.2" fill="currentColor"><path d="M44.3,164.5L76.9,51.6H127l-10.1,35c-0.1,0.2-0.2,0.4-0.3,0.6L90,179.6h24.8c-10.4,25.9-18.5,46.2-24.3,60.9c-45.8-0.5-58.6-33.3-47.4-72.1 M90.7,240.6l60.4-86.9h-25.6l22.3-55.7c38.2,4,56.2,34.1,45.6,70.5c-11.3,39.1-57.1,72.1-101.7,72.1C91.3,240.6,91,240.6,90.7,240.6z"/></svg>',
  };

  const state = {
    lang: initialLang(),
    release: null,           // { tag, date, assets: [{ name, size, url }] }
    releaseState: 'loading', // loading | live | fallback
    open: new Set(),         // expanded roadmap entries
    active: 'overview',
    testersOpen: false,
    channel: 'stable',       // stable | nightly, the Download page's switch
    shots: 'phone',          // phone | desktop, the Screenshots page's switch
    shot: -1,                // index into visibleShots() shown full screen, -1 when closed
    article: null,           // slug of the article open on the Articles page, null for the list
    nightly: null,           // { run, sha, date, url, assets: [{ name, size, url }] }
    nightlyState: 'idle',    // idle | loading | live | failed
  };

  // ── helpers ────────────────────────────────────────────────────────────

  function initialLang() {
    const stored = localStorage.getItem('glaze-site-lang');
    if (stored === 'ru' || stored === 'en') return stored;
    return (navigator.language || 'en').toLowerCase().startsWith('ru') ? 'ru' : 'en';
  }

  const t = (key) => G.ui[state.lang][key] ?? G.ui.en[key] ?? key;
  const pick = (obj) => (obj && typeof obj === 'object' && !Array.isArray(obj) ? obj[state.lang] ?? obj.en : obj);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const ms = (name, cls = '') => `<span class="ms ${cls}" aria-hidden="true">${name}</span>`;
  const $ = (sel) => document.querySelector(sel);
  const ext = 'target="_blank" rel="noopener"';

  function fmtDate(iso) {
    return new Intl.DateTimeFormat(state.lang === 'ru' ? 'ru-RU' : 'en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
      .format(new Date(iso + (iso.length === 10 ? 'T12:00:00Z' : '')));
  }

  function fmtDateTime(iso) {
    return new Intl.DateTimeFormat(state.lang === 'ru' ? 'ru-RU' : 'en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
  }

  function fmtSize(bytes) {
    const mb = bytes / 1048576;
    const n = new Intl.NumberFormat(state.lang === 'ru' ? 'ru-RU' : 'en-US', { maximumFractionDigits: mb < 10 ? 1 : 0 }).format(mb);
    return `${n} ${state.lang === 'ru' ? 'МБ' : 'MB'}`;
  }

  // Every community and donation link is shown whatever the language.
  const LINK_CARDS = [
    { key: 'telegram', label: 'Telegram', url: G.links.telegram, color: '#2AABEE', sub: 'community_join' },
    { key: 'discord', label: 'Discord', url: G.links.discord, color: '#5865F2', sub: 'community_join' },
    { key: 'boosty', label: 'Boosty', url: G.links.boosty, color: '#F15F2C', sub: 'community_support' },
    { key: 'bmc', label: 'Buy Me a Coffee', url: G.links.bmc, color: '#FFDD00', sub: 'community_support' },
  ];

  function sectionHead(id, title, lead) {
    return `<div class="section-head">
      <h2>${esc(title)}</h2>
      ${lead ? `<p>${esc(lead)}</p>` : ''}
    </div>`;
  }

  function group({ icon, title, body, cls = '', desc = '' }) {
    return `<div class="group ${cls}" data-glow>
      ${title ? `<div class="group-header">${icon ? ms(icon) : ''}<h3>${esc(title)}</h3></div>` : ''}
      ${desc ? `<div class="group-desc">${esc(desc)}</div>` : ''}
      ${body}
    </div>`;
  }

  // A community link as a card of its own, tinted with the brand colour.
  function linkCard({ href, svg, color, label, sub, host }) {
    return `<a class="group link-card" href="${href}" ${ext} style="--brand:${color}" data-glow>
      <span class="tile">${svg}</span>
      <span class="link-card-label">${esc(label)}</span>
      <span class="link-card-sub">${esc(sub)}</span>
      <span class="link-card-host">${esc(host)}${ms('arrow_outward')}</span>
    </a>`;
  }

  // ── release data ───────────────────────────────────────────────────────

  function classify(name) {
    const n = name.toLowerCase();
    if (n.endsWith('.apk')) {
      if (n.includes('arm64')) return { platform: 'android', kind: 'arm64' };
      if (n.includes('armeabi') || n.includes('armv7')) return { platform: 'android', kind: 'arm32' };
      return { platform: 'android', kind: 'universal' };
    }
    if (n.endsWith('.ipa')) return { platform: 'ios', kind: 'IPA' };
    if (n.endsWith('.exe') || (n.endsWith('.zip') && n.includes('windows'))) return { platform: 'windows', kind: n.endsWith('.exe') ? 'EXE' : 'ZIP' };
    if (n.endsWith('.deb')) return { platform: 'linux', kind: 'DEB' };
    if (n.endsWith('.appimage')) return { platform: 'linux', kind: 'AppImage' };
    // pacman first: `<tag>-linux.pkg.tar.zst` also ends in `.tar.zst`.
    if (n.endsWith('.pacman') || n.includes('.pkg.tar')) return { platform: 'linux', kind: 'pacman' };
    if (n.endsWith('.tar.zst')) return { platform: 'linux', kind: 'tar.zst' };
    return null;
  }

  function useFallback() {
    const f = G.fallbackRelease;
    state.release = {
      tag: f.tag,
      date: f.date,
      assets: f.assets.map((a) => ({ ...a, url: `https://github.com/${G.repo}/releases/download/${f.tag}/${a.name}` })),
    };
  }

  // The unauthenticated GitHub API allows 60 requests an hour per IP, so the
  // answer is kept for an hour rather than fetched on every page view.
  const RELEASE_CACHE_KEY = 'glaze-site-release';
  const RELEASE_CACHE_MS = 60 * 60 * 1000;

  async function loadRelease() {
    try {
      const cached = JSON.parse(localStorage.getItem(RELEASE_CACHE_KEY) || 'null');
      if (cached && Date.now() - cached.at < RELEASE_CACHE_MS) {
        state.release = cached.release;
      } else {
        const res = await fetch(`https://api.github.com/repos/${G.repo}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
        if (!res.ok) throw new Error(res.status);
        const r = await res.json();
        state.release = {
          tag: r.tag_name,
          date: r.published_at.slice(0, 10),
          assets: r.assets.map((a) => ({ name: a.name, size: a.size, url: a.browser_download_url })),
        };
        localStorage.setItem(RELEASE_CACHE_KEY, JSON.stringify({ at: Date.now(), release: state.release }));
      }
      state.releaseState = 'live';
    } catch {
      state.releaseState = 'fallback';
    }
    renderDownload();
    const badge = $('#heroVersion');
    if (badge) badge.textContent = 'v' + shortVersion();
  }

  const shortVersion = () => state.release.tag.replace(/^v/, '');

  // Nightly builds exist only as Actions artifacts of the "Build (Branch)"
  // workflow on the nightly branch. GitHub serves those to signed-in users
  // only, so the files go through nightly.link, which proxies the artifacts
  // of a given run anonymously.
  const NIGHTLY_CACHE_KEY = 'glaze-site-nightly-v2';
  const NIGHTLY_CACHE_MS = 5 * 60 * 1000;

  function classifyArtifact(name) {
    const n = name.replace(/^Glaze-release-/, '').toLowerCase();
    if (n.startsWith('apk')) {
      if (n.includes('arm64')) return { platform: 'android', kind: 'arm64' };
      if (n.includes('armeabi')) return { platform: 'android', kind: 'arm32' };
      return { platform: 'android', kind: 'universal' };
    }
    return {
      ios: { platform: 'ios', kind: 'IPA' },
      windows: { platform: 'windows', kind: 'ZIP' },
      deb: { platform: 'linux', kind: 'DEB' },
      appimage: { platform: 'linux', kind: 'AppImage' },
      tarzst: { platform: 'linux', kind: 'tar.zst' },
      pacman: { platform: 'linux', kind: 'pacman' },
    }[n] || null;
  }

  async function loadNightly() {
    if (state.nightlyState !== 'idle') return;
    state.nightlyState = 'loading';
    try {
      const cached = JSON.parse(localStorage.getItem(NIGHTLY_CACHE_KEY) || 'null');
      if (cached && Date.now() - cached.at < NIGHTLY_CACHE_MS) {
        state.nightly = cached.nightly;
      } else {
        const api = `https://api.github.com/repos/${G.repo}/actions`;
        const headers = { Accept: 'application/vnd.github+json' };
        // The API's own `branch=` filter is unreliable: it has answered with a
        // run days older than the newest one on the branch. So take the newest
        // successful runs of the workflow and pick the branch here; the runs
        // come back newest first.
        const runs = await fetch(`${api}/workflows/${G.nightly.workflow}/runs?status=success&per_page=50`, { headers });
        if (!runs.ok) throw new Error(runs.status);
        const run = (await runs.json()).workflow_runs.find((r) => r.head_branch === G.nightly.branch);
        if (!run) throw new Error('no runs');
        const arts = await fetch(`${api}/runs/${run.id}/artifacts`, { headers });
        if (!arts.ok) throw new Error(arts.status);
        state.nightly = {
          run: run.run_number,
          sha: run.head_sha.slice(0, 7),
          date: run.created_at,
          url: run.html_url,
          assets: (await arts.json()).artifacts
            .filter((a) => !a.expired && a.name.startsWith('Glaze-release-'))
            .map((a) => ({ name: a.name, size: a.size_in_bytes, url: `https://nightly.link/${G.repo}/actions/runs/${run.id}/${a.name}.zip` })),
        };
        localStorage.setItem(NIGHTLY_CACHE_KEY, JSON.stringify({ at: Date.now(), nightly: state.nightly }));
      }
      state.nightlyState = 'live';
    } catch {
      state.nightlyState = 'failed';
    }
    renderDownload();
  }

  // ── chrome ─────────────────────────────────────────────────────────────

  function renderChrome() {
    document.documentElement.lang = state.lang;
    document.querySelectorAll('[data-t]').forEach((el) => { el.textContent = t(el.dataset.t); });

    // The app's DesktopPopup: a glass panel anchored under its button.
    $('#langMenu').innerHTML = `
      <button class="lang-btn" type="button" data-lang-menu aria-haspopup="menu" aria-expanded="false" aria-label="Language">
        ${ms('translate')}
      </button>
      <div class="popup" role="menu" hidden>
        ${Object.entries(LANGS).map(([code, name]) => `
          <button class="popup-row" type="button" role="menuitemradio" aria-checked="${code === state.lang}" data-lang="${code}">
            <span class="popup-label">${esc(name)}<small>${code.toUpperCase()}</small></span>
            ${code === state.lang ? ms('check', 'popup-check') : ''}
          </button>`).join('')}
      </div>`;

    $('#tabBar').innerHTML = TABS.map((s) => `<a class="tab" href="#${s}" data-section="${s}">${esc(t('nav_' + s))}</a>`).join('');
    $('#navBar').innerHTML = TABS.map((s) => `
      <a class="nav-item" href="#${s}" data-section="${s}">${ms(SECTION_ICONS[s])}<span>${esc(t('nav_' + s))}</span></a>`).join('');

  }

  // ── sections ───────────────────────────────────────────────────────────

  function renderOverview() {
    const glance = t('glance').map(([icon, label, sub]) => `
      <div class="row">
        <span class="tile">${ms(icon)}</span>
        <span class="row-text"><span class="tile-label">${esc(label)}</span><span class="tile-sub">${esc(sub)}</span></span>
      </div>`).join('');

    $('#overview').innerHTML = `<div class="container">
      <div class="hero-grid">
        <div>
          <h1>Glaze</h1>
          <p class="hero-tagline">${esc(t('tagline').replace('\n', ' '))}</p>
          <div class="hero-meta">
            <span>${ms('devices')}${esc(t('hero_platforms'))}</span>
            <span>${ms('code')}${esc(t('hero_license'))}</span>
          </div>
          <div class="hero-actions">
            <div class="hero-download">
              <a class="btn btn-primary" href="#download">${ms('download')}${esc(t('btn_download'))}</a>
              <span class="version-badge"><span id="heroVersion">v${esc(shortVersion())}</span><b>${esc(t('beta'))}</b></span>
            </div>
            <a class="btn btn-glass" href="${G.links.github}" ${ext}>${BRAND.github}${esc(t('btn_github'))}</a>
          </div>
        </div>
        <div class="notice">
          <div class="notice-head">${ms('warning')}<h3>${esc(t('notice_header'))}</h3></div>
          <p>${esc(t('notice_text'))}</p>
          <a class="text-link" href="${G.links.issues}" ${ext}>${esc(t('notice_report'))}${ms('open_in_new')}</a>
        </div>
      </div>
      <div class="overview-row">
        ${G.articles.length ? articleCard(G.articles[0], { latest: true }) : ''}
        ${group({ icon: 'info', title: t('about_header'), cls: 'overview-about', body: `<div class="prose">${t('about_text').map((p) => `<p>${esc(p)}</p>`).join('')}</div>` })}
      </div>
      <div class="group overview-glance" data-glow>
        <div class="group-header">${ms('widgets')}<h3>${esc(t('overview_features_header'))}</h3></div>
        ${glance}
        <a class="text-link overview-features-link" href="#features">${esc(t('overview_features_link'))}${ms('arrow_forward')}</a>
      </div>
    </div>`;
  }

  // "Based on SillyImages", "Inspired by Marinara Engine and Lumiverse".
  function featureCredit(credit) {
    if (!credit) return '';
    const links = credit.names.map((id) => {
      const [name, url] = G.credits[id];
      return `<a href="${url}" ${ext}>${esc(name)}</a>`;
    }).join(state.lang === 'ru' ? ' и ' : ' and ');
    return `<span class="row-credit">${ms('favorite')}<span>${esc(t('credit_' + credit.kind))} ${links}</span></span>`;
  }

  // A feature's own page, shown under it like a credit: `github.com/hydall/JAR`.
  function featureLink(url) {
    if (!url) return '';
    return `<span class="row-credit">${ms('open_in_new')}<a href="${url}" ${ext}>${esc(url.replace(/^https?:\/\//, ''))}</a></span>`;
  }

  function renderFeatures() {
    const groups = G.features.map((f) => group({
      icon: f.icon,
      title: pick(f.title),
      body: f.items.map((it) => {
        const [label, sub] = it[state.lang] || it.en;
        return `<div class="row"><span class="tile">${ms(it.icon)}</span><span class="row-text">
          <span class="row-label">${esc(label)}</span>
          <span class="row-sub">${esc(sub)}</span>${featureCredit(it.credit)}${featureLink(it.link)}</span></div>`;
      }).join(''),
    })).join('');
    $('#features').innerHTML = `<div class="container">
      ${sectionHead('features', t('features_title'), t('features_lead'))}
      <div class="feature-grid">${groups}</div>
    </div>`;
  }

  // ── markdown ───────────────────────────────────────────────────────────

  // Enough Markdown for an article: headings, paragraphs, lists, quotes, rules,
  // and inline bold, italics, code and links. Source is escaped first, so an
  // article can never inject markup of its own.
  function mdInline(text) {
    const code = [];
    return esc(text)
      .replace(/`([^`]+)`/g, (_, c) => `\u0000${code.push(c) - 1}\u0000`)
      .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, url) =>
        /^(https?:|mailto:|#)/.test(url) ? `<a href="${url}" ${url.startsWith('#') ? '' : ext}>${label}</a>` : label)
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*\w])\*([^*\s][^*]*)\*(?!\w)/g, '$1<em>$2</em>')
      .replace(/(^|[^_\w])_([^_\s][^_]*)_(?!\w)/g, '$1<em>$2</em>')
      .replace(/ {2,}\n/g, '<br>')
      .replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${code[i]}</code>`);
  }

  function md(src) {
    const lines = src.replace(/\r\n?/g, '\n').split('\n');
    const out = [];
    let i = 0;
    const isBlockStart = (l) => /^(#{1,6} |> ?|[-*] |\d+\. |---+\s*$|\s*$)/.test(l);
    while (i < lines.length) {
      const line = lines[i];
      if (!line.trim()) { i++; continue; }
      let m;
      if ((m = line.match(/^(#{1,6}) +(.*)$/))) {
        // An article's own headings start at h3: h2 is the page title's level.
        const level = Math.min(m[1].length + 1, 6);
        out.push(`<h${level}>${mdInline(m[2])}</h${level}>`);
        i++;
      } else if (/^---+\s*$/.test(line)) {
        out.push('<hr>');
        i++;
      } else if (/^> ?/.test(line)) {
        const quote = [];
        while (i < lines.length && /^> ?/.test(lines[i])) quote.push(lines[i++].replace(/^> ?/, ''));
        // Quote lines are kept as lines, as Telegraph shows them.
        out.push(`<blockquote>${md(quote.join('  \n'))}</blockquote>`);
      } else if (/^([-*]|\d+\.) /.test(line)) {
        const ordered = /^\d+\. /.test(line);
        const items = [];
        while (i < lines.length && /^([-*]|\d+\.) /.test(lines[i])) {
          let item = lines[i++].replace(/^([-*]|\d+\.) /, '');
          while (i < lines.length && /^ {2,}\S/.test(lines[i])) item += '\n' + lines[i++].trim();
          items.push(`<li>${mdInline(item)}</li>`);
        }
        out.push(`<${ordered ? 'ol' : 'ul'}>${items.join('')}</${ordered ? 'ol' : 'ul'}>`);
      } else {
        const para = [line];
        i++;
        while (i < lines.length && !isBlockStart(lines[i])) para.push(lines[i++]);
        out.push(`<p>${mdInline(para.join('\n'))}</p>`);
      }
    }
    return out.join('\n');
  }

  // ── articles ───────────────────────────────────────────────────────────

  const articleCache = new Map(); // `${slug}.${lang}` -> html | 'failed'

  // The language an article is shown in: the reader's, or the first it has.
  const articleLang = (a) => (a.langs.includes(state.lang) ? state.lang : a.langs[0]);

  async function loadArticle(a) {
    const key = `${a.slug}.${articleLang(a)}`;
    if (articleCache.has(key)) return;
    articleCache.set(key, 'loading');
    try {
      const res = await fetch(`articles/${key}.md`);
      if (!res.ok) throw new Error(res.status);
      articleCache.set(key, md(await res.text()));
    } catch {
      articleCache.set(key, 'failed');
    }
    if (state.article === a.slug) renderArticles();
  }

  // The author with their avatar. Inside a card (which is itself a link) the
  // name stays plain text; on the article page it links to their profile.
  function articleAuthor(a, link) {
    const au = G.authors[a.author];
    if (!au) return a.author ? `<span class="article-author">${esc(a.author)}</span>` : '';
    const inner = `<img src="assets/img/${au.img}" alt="" loading="lazy"><span>${esc(au.name)}</span>`;
    return link
      ? `<a class="article-author" href="${au.url}" ${ext}>${inner}</a>`
      : `<span class="article-author">${inner}</span>`;
  }

  function articleMeta(a, { link = false } = {}) {
    return `<div class="article-meta">
      ${articleAuthor(a, link)}
      <span>${esc(fmtDate(a.date))}</span>
      <span class="chip chip-accent">${esc(t('kind_' + a.kind))}</span>
    </div>`;
  }

  // One article as a card linking to its page: the list's rows, and the
  // Overview's "latest article".
  function articleCard(a, { latest = false } = {}) {
    return `<a class="group article-card ${latest ? 'latest' : ''}" href="#articles/${encodeURIComponent(a.slug)}" data-glow>
      ${latest ? `<div class="caps">${ms('newspaper')}${esc(t('article_latest'))}</div>` : ''}
      ${articleMeta(a)}
      <h3>${esc(pick(a.title))}</h3>
      <p>${esc(pick(a.lead))}</p>
      <span class="text-link">${esc(t('article_read'))}${ms('arrow_forward')}</span>
    </a>`;
  }

  function renderArticles() {
    const a = state.article && G.articles.find((x) => x.slug === state.article);
    if (!state.article) {
      $('#articles').innerHTML = `<div class="container">
        ${sectionHead('articles', t('articles_title'), t('articles_lead'))}
        <div class="article-list">${G.articles.map((x) => articleCard(x)).join('')}</div>
      </div>`;
      return;
    }
    const back = `<a class="text-link article-back" href="#articles">${ms('arrow_back')}${esc(t('article_back'))}</a>`;
    if (!a) {
      $('#articles').innerHTML = `<div class="container article-page">${back}<p class="article-status">${esc(t('article_not_found'))}</p></div>`;
      return;
    }
    loadArticle(a);
    const body = articleCache.get(`${a.slug}.${articleLang(a)}`);
    const content = body === 'failed'
      ? `<p class="article-status warn">${esc(t('article_failed'))}</p>`
      : !body || body === 'loading'
      ? `<p class="article-status">${esc(t('article_loading'))}</p>`
      : `<div class="article-body">${body}</div>`;
    $('#articles').innerHTML = `<div class="container article-page">
      ${back}
      <article class="group article">
        ${articleMeta(a, { link: true })}
        <h1>${esc(pick(a.title))}</h1>
        ${articleLang(a) !== state.lang ? `<div class="article-note">${ms('translate')}${esc(t('article_only_ru'))}</div>` : ''}
        ${content}
      </article>
    </div>`;
  }

  // ── screenshots ────────────────────────────────────────────────────────

  const shotSrc = (id) => `assets/img/screens/web/${state.shots}_${id}_${state.lang}.webp`;

  // The shots of the chosen device in page order; the viewer steps through it.
  const visibleShots = () => G.screenshots.flatMap((g) =>
    g.items.filter((it) => state.shots === 'phone' || !it.phoneOnly));

  function renderScreenshots() {
    const all = visibleShots();
    const groups = G.screenshots.map((g) => {
      const items = g.items.filter((it) => all.includes(it));
      const cards = items.map((it) => {
        const [label, sub] = it[state.lang] || it.en;
        return `<figure class="shot">
          <button class="shot-img" type="button" data-shot="${all.indexOf(it)}" aria-label="${esc(label)}">
            <img src="${shotSrc(it.id)}" alt="${esc(label)}" loading="lazy" decoding="async">
          </button>
          <figcaption><span class="row-label">${esc(label)}</span><span class="row-sub">${esc(sub)}</span></figcaption>
        </figure>`;
      }).join('');
      return `<div class="shots-group">
        <div class="group-header">${ms(g.icon)}<h3>${esc(pick(g.title))}</h3></div>
        <div class="shots-grid">${cards}</div>
      </div>`;
    }).join('');

    const devices = ['phone', 'desktop'].map((d) => `
      <a class="tab ${d === state.shots ? 'active' : ''}" href="#screenshots${d === 'desktop' ? '/desktop' : ''}">${esc(t('shots_' + d))}</a>`).join('');

    $('#screenshots').innerHTML = `<div class="container">
      ${sectionHead('screenshots', t('screenshots_title'), t('screenshots_lead'))}
      <nav class="tab-bar channel-switch" aria-label="${esc(t('shots_platform'))}">${devices}</nav>
      <div class="shots ${state.shots}">${groups}</div>
    </div>`;
  }

  function renderViewer() {
    const box = $('#viewer');
    const all = visibleShots();
    const it = all[state.shot];
    if (!it) {
      box.hidden = true;
      box.innerHTML = '';
      document.body.classList.remove('viewer-open');
      return;
    }
    const [label, sub] = it[state.lang] || it.en;
    box.hidden = false;
    document.body.classList.add('viewer-open');
    box.className = `viewer ${state.shots}`;
    box.innerHTML = `
      <button class="viewer-btn viewer-close" type="button" data-viewer="close" aria-label="${esc(t('shots_close'))}">${ms('close')}</button>
      <button class="viewer-btn viewer-prev" type="button" data-viewer="prev" aria-label="${esc(t('shots_prev'))}">${ms('chevron_left')}</button>
      <figure class="viewer-body">
        <img src="${shotSrc(it.id)}" alt="${esc(label)}">
        <figcaption><b>${esc(label)}</b><span>${esc(sub)}</span><small>${state.shot + 1} / ${all.length}</small></figcaption>
      </figure>
      <button class="viewer-btn viewer-next" type="button" data-viewer="next" aria-label="${esc(t('shots_next'))}">${ms('chevron_right')}</button>`;
  }

  function openShot(i) {
    const n = visibleShots().length;
    state.shot = i < 0 ? -1 : (i + n) % n;
    renderViewer();
  }

  // The release's notes: its post when the roadmap names one, else GitHub's
  // release page.
  function notesLink(tag) {
    const post = G.releases.find((x) => x.tag === tag)?.article;
    return post
      ? `<a class="text-link" href="#articles/${encodeURIComponent(post)}">${esc(t('release_notes'))}${ms('arrow_forward')}</a>`
      : `<a class="text-link" href="https://github.com/${G.repo}/releases/tag/${esc(tag)}" ${ext}>${esc(t('release_notes'))}${ms('open_in_new')}</a>`;
  }

  function renderDownload() {
    const nightly = state.channel === 'nightly';
    if (nightly) loadNightly();
    const r = state.release;
    const n = state.nightly;
    const byPlatform = {};
    const assets = nightly ? (n?.assets || []) : r.assets;
    for (const a of assets) {
      const c = nightly ? classifyArtifact(a.name) : classify(a.name);
      if (c) (byPlatform[c.platform] ||= []).push({ ...a, kind: c.kind });
    }
    const order = { universal: 0, arm64: 1, arm32: 2, ZIP: 0, EXE: 1, DEB: 0, AppImage: 1, pacman: 0, 'tar.zst': 1 };
    Object.values(byPlatform).forEach((list) => list.sort((a, b) => (order[a.kind] ?? 9) - (order[b.kind] ?? 9)));
    // Stable 0.7 ships a single APK, so it is just "APK"; nightly builds the
    // universal one next to the per-ABI splits.
    const kindLabel = (k) => ({ universal: nightly ? 'universal' : t('asset_universal'), arm64: t('asset_arm64'), arm32: t('asset_arm32') })[k] || k;

    // Android and Linux describe what the release actually ships: 0.7 had an
    // arm64-only APK and a lone .deb, 0.8 adds arm32 and two more Linux formats.
    const platformSub = (id, list) => {
      if (id === 'android' && list.length && nightly) return ['APK', ...list.filter((a) => a.kind !== 'universal').map((a) => a.kind)].join(' · ');
      if (id === 'android' && list.length) return list.some((a) => a.kind === 'arm32') ? 'APK · arm64 · arm32' : 'APK · arm64';
      if (id === 'linux' && list.length) return list.map((a) => a.kind).join(' · ');
      return t('plat_' + id + '_sub');
    };

    const platforms = [
      { id: 'android', icon: 'android', color: '#3DDC84' },
      { id: 'ios', icon: 'phone_iphone', color: '#C5C7CB' },
      { id: 'windows', icon: 'desktop_windows', color: '#4CA3F2' },
      { id: 'linux', icon: 'terminal', color: '#F2C14E' },
    ];

    // One card per platform: how to install it, then its files.
    const cards = platforms.map((p) => {
      const list = byPlatform[p.id] || [];
      const actions = nightly && state.nightlyState !== 'live'
        ? `<span class="chip chip-gray">${esc(t(state.nightlyState === 'failed' ? 'nightly_failed_short' : 'dl_loading_short'))}</span>`
        : list.length
        ? list.map((a, i) => `<a class="btn ${i === 0 ? 'btn-primary' : 'btn-glass'} btn-sm" href="${a.url}" download>
            ${i === 0 ? ms('download') : ''}${esc(kindLabel(a.kind))} <span class="size">${esc(fmtSize(a.size))}</span></a>`).join('')
        : `<span class="chip chip-gray">${esc(t('dl_missing'))}</span>`;
      return `<div class="group install-card" data-glow>
        <div class="head">
          <span class="tile" style="background:${p.color}1f;color:${p.color}">${ms(p.icon)}</span>
          <span class="row-text"><span class="tile-label">${esc(t('plat_' + p.id))}</span><span class="tile-sub">${esc(platformSub(p.id, list))}</span></span>
        </div>
        <p>${esc(t(nightly ? 'dl_how_nightly' : 'dl_how')[p.id])}</p>
        <div class="dl-actions">${actions}</div>
      </div>`;
    }).join('');

    const status = state.releaseState === 'loading'
      ? `<div class="dl-status">${esc(t('dl_loading'))}</div>`
      : state.releaseState === 'fallback' ? `<div class="dl-status warn">${esc(t('dl_api_failed'))}</div>` : '';

    const stableCard = `<div class="release-card">
          <div class="caps">${esc(t('dl_latest'))}</div>
          <span class="big-logo" aria-hidden="true"></span>
          <div class="card-version">v${esc(shortVersion())}</div>
          <div class="card-date">${esc(fmtDate(r.date))}</div>
          <div class="card-links">
            ${notesLink(r.tag)}
            <a class="text-link" href="${G.links.releases}" ${ext}>${esc(t('dl_all'))}${ms('open_in_new')}</a>
          </div>
          ${status}
        </div>`;

    const nightlyCard = `<div class="release-card nightly">
          <div class="caps">${esc(t('nightly_latest'))}</div>
          <span class="big-logo" aria-hidden="true"></span>
          ${n ? `<div class="card-version">${esc(t('nightly_build'))} #${n.run}</div>
          <div class="card-date">${esc(fmtDateTime(n.date))} · <code>${esc(n.sha)}</code></div>` : `<div class="card-version">Nightly</div>`}
          <div class="card-links">
            <a class="text-link" href="https://github.com/${G.repo}/commits/${G.nightly.branch}" ${ext}>${esc(t('nightly_commits'))}${ms('open_in_new')}</a>
            ${n ? `<a class="text-link" href="${n.url}" ${ext}>${esc(t('nightly_run'))}${ms('open_in_new')}</a>` : ''}
          </div>
          ${state.nightlyState === 'loading' ? `<div class="dl-status">${esc(t('dl_loading'))}</div>` : ''}
          ${state.nightlyState === 'failed' ? `<div class="dl-status warn">${esc(t('nightly_failed'))}</div>` : ''}
        </div>`;

    const channels = ['stable', 'nightly'].map((c) => `
      <a class="tab ${c === state.channel ? 'active' : ''}" href="#download${c === 'nightly' ? '/nightly' : ''}">${esc(t('channel_' + c))}</a>`).join('');

    $('#download').innerHTML = `<div class="container">
      ${sectionHead('download', t('download_title'), t('download_lead'))}
      <nav class="tab-bar channel-switch" aria-label="${esc(t('channel_label'))}">${channels}</nav>
      ${nightly ? `<div class="notice nightly-notice"><div class="notice-head">${ms('science')}<h3>${esc(t('nightly_header'))}</h3></div><p>${esc(t('nightly_text'))}</p></div>` : ''}
      <div class="download-grid">
        ${nightly ? nightlyCard : stableCard}
        <div class="install-grid">${cards}</div>
      </div>
    </div>`;
  }

  const releaseKey = (r) => r.version || 'planned';

  function renderRoadmap() {
    const items = G.releases.map((r) => {
      const key = releaseKey(r);
      const planned = r.status === 'planned';
      const open = planned || state.open.has(key);
      const chips = [];
      if (r.status === 'dev') chips.push(`<span class="chip chip-amber">${esc(t('status_dev'))}</span>`);
      if (r.status === 'latest') chips.push(`<span class="chip chip-accent">${esc(t('status_latest'))}</span>`);
      if (r.channel === 'beta') chips.push(`<span class="chip chip-orange">${esc(t('status_beta'))}</span>`);
      if (r.channel === 'alpha') chips.push(`<span class="chip chip-gray">${esc(t('status_alpha'))}</span>`);

      const body = r.groups.map((g) => `
        ${g.title ? `<div class="sub-header">${esc(pick(g.title))}</div>` : ''}
        <ul class="bullets">${pick(g.items).map((li) => `<li>${esc(li)}</li>`).join('')}</ul>`).join('')
        + (r.article
          ? `<a class="text-link" href="#articles/${encodeURIComponent(r.article)}">${esc(t('release_notes'))}${ms('arrow_forward')}</a>`
          : r.tag ? `<a class="text-link" href="https://github.com/${G.repo}/releases/tag/${r.tag}" ${ext}>${esc(t('release_notes'))}${ms('open_in_new')}</a>` : '');

      const head = planned
        ? `<div class="release-head"><div class="release-title"><div class="release-version">
            <b>${esc(pick(r.title))}</b><span class="chip chip-gray">${esc(t('status_planned'))}</span></div></div></div>`
        : `<button class="release-head" type="button" aria-expanded="${open}" data-release="${esc(key)}">
            <div class="release-title">
              <div class="release-version"><b>${esc(r.version)}</b>${chips.join('')}</div>
              <div class="release-name">${esc(pick(r.title))}${r.date ? `<span class="date-inline"> · ${esc(fmtDate(r.date))}</span>` : ''}</div>
            </div>
            ${r.date ? `<span class="release-date">${esc(fmtDate(r.date))}</span>` : ''}
            ${ms('keyboard_arrow_down', 'arrow')}
          </button>`;

      return `<div class="release ${r.status} ${open ? 'open' : ''}" id="release-${esc(key)}">
        <span class="release-node" aria-hidden="true"></span>
        <div class="group flat">${head}<div class="release-body">${body}</div></div>
      </div>`;
    }).join('');

    const shipped = G.releases.filter((r) => r.date);
    const first = shipped[shipped.length - 1];
    const stats = state.lang === 'ru'
      ? `${shipped.length} релизов с ${fmtDate(first.date)}`
      : `${shipped.length} releases since ${fmtDate(first.date)}`;

    $('#roadmap').innerHTML = `<div class="container roadmap-grid">
      <div class="roadmap-aside">
        ${sectionHead('roadmap', t('roadmap_title'), t('roadmap_lead'))}
        <div class="roadmap-stats">${ms('rocket_launch')}${esc(stats)}</div>
      </div>
      <div class="timeline">${items}</div>
    </div>`;
  }

  function renderResources() {
    const author = (name, role, img, color, note = '') => `
      <a class="row tile-row" href="https://github.com/${name}" ${ext}>
        <span class="tile photo" style="--tile-border:${color}66"><img src="assets/img/${img}" alt="" loading="lazy"></span>
        <span class="row-text"><span class="tile-label">${esc(name)}${note ? `<span class="chip chip-gray">${esc(note)}</span>` : ''}</span><span class="tile-sub">${esc(role)}</span></span>
      </a>`;

    $('#resources').innerHTML = `<div class="container">
      <div class="about-resources">
        <div class="about-head"><h3>${esc(t('resources_header'))}</h3></div>
        <div class="link-grid">
          ${linkCard({ href: G.links.github, svg: BRAND.github, color: '#E1E3E6', label: 'GitHub', sub: t('community_source'), host: 'github.com/hydall/Glaze' })}
          ${LINK_CARDS.map((c) => linkCard({ href: c.url, svg: c.key === 'bmc' ? ms('coffee') : BRAND[c.key], color: c.color, label: c.label, sub: t(c.sub), host: c.url.replace(/^https:\/\//, '') })).join('')}
        </div>
      </div>
      <div class="about-people">
        <div class="about-head"><h3>${esc(t('creators_header'))}</h3></div>
        <div class="about-grid">
          ${group({
            title: t('authors_header'),
            body: author('hydall', t('role_hydall'), 'hydall.jpg', '#C42A4A')
              + author('danvitv', t('role_danvitv'), 'danvitv.png', '#79CE96', t('danvitv_until')),
          })}
          <div class="group testers ${state.testersOpen ? 'open' : ''}">
            <button class="group-header testers-head" type="button" data-testers aria-expanded="${state.testersOpen}">
              <h3>${esc(t('testers_header'))}</h3><span class="testers-count">${G.testers.length}</span>${ms('keyboard_arrow_down', 'arrow')}
            </button>
            <div class="testers-body"><div>
              <div class="tester-list">${G.testers.map((n) => `<span class="tester">${esc(n)}</span>`).join('')}</div>
            </div></div>
          </div>
        </div>
      </div>
      <div class="about-credits">
        <div class="about-head"><h3>${esc(t('credits_header'))}</h3></div>
        <div class="group credits" data-glow>
          <div class="credits-list">
            ${Object.entries(G.credits).map(([id, [name, url]]) => `
              <a class="row tile-row" href="${url}" ${ext}>
                <span class="tile">${ms('link')}</span>
                <span class="row-text"><span class="tile-label">${esc(name)}</span><span class="tile-sub">${esc(pick(G.creditNotes[id] || {}))}</span></span>
                ${ms('open_in_new', 'chevron')}
              </a>`).join('')}
          </div>
          <div class="sub-header">${esc(t('credits_presets'))}</div>
          <div class="credits-list">
            ${G.presetCredits.map((p) => `
              <div class="row tile-row">
                <span class="tile">${ms('tune')}</span>
                <span class="row-text"><span class="tile-label">${esc(p.name)}</span><span class="tile-sub">${esc(t('credits_by'))}: ${esc(p.author)}</span></span>
              </div>`).join('')}
          </div>
        </div>
      </div>
    </div>`;
  }

  function renderAll() {
    renderChrome();
    renderOverview();
    renderFeatures();
    renderScreenshots();
    renderViewer();
    renderDownload();
    renderRoadmap();
    renderArticles();
    renderResources();
    markActive(state.active);
  }

  // ── navigation ─────────────────────────────────────────────────────────

  function markActive(id) {
    state.active = id;
    document.querySelectorAll('[data-section]').forEach((el) => {
      const on = el.dataset.section === id;
      el.classList.toggle('active', on);
      if (on) el.setAttribute('aria-current', 'true'); else el.removeAttribute('aria-current');
    });
  }

  // Every section is its own page, like a tab in the app: the header's
  // segmented control on desktop, the bottom nav bar on phones.
  function sectionFromHash() {
    const [head] = decodeURIComponent(location.hash.slice(1)).split('/');
    if (head === 'about') return 'resources';
    return SECTIONS.includes(head) ? head : 'overview';
  }

  function showTab(id, animate = true) {
    const prev = state.active;
    document.body.dataset.tab = id;
    SECTIONS.forEach((s) => {
      const el = document.getElementById(s);
      el.classList.toggle('current', s === id);
      el.classList.remove('enter-fwd', 'enter-back');
      if (s === id && animate && prev !== id) {
        void el.offsetWidth;
        el.classList.add(SECTIONS.indexOf(id) > SECTIONS.indexOf(prev) ? 'enter-fwd' : 'enter-back');
      }
    });
    markActive(id);
    document.title = id === 'overview' ? 'Glaze: AI roleplay chat client' : `${t('nav_' + id)} · Glaze`;
  }

  function route(animate = true) {
    const hash = decodeURIComponent(location.hash.slice(1));
    const id = sectionFromHash();
    const channel = hash === 'download/nightly' ? 'nightly' : 'stable';
    if (id === 'download' && channel !== state.channel) {
      state.channel = channel;
      renderDownload();
    }
    const shots = hash === 'screenshots/desktop' ? 'desktop' : 'phone';
    if (id === 'screenshots' && shots !== state.shots) {
      state.shots = shots;
      renderScreenshots();
    }
    if (state.shot >= 0) openShot(-1);
    const article = id === 'articles' ? hash.split('/').slice(1).join('/') || null : null;
    const articleChanged = id === 'articles' && article !== state.article;
    if (articleChanged) {
      state.article = article;
      renderArticles();
    }
    const changed = id !== state.active;
    showTab(id, animate);
    if (hash.startsWith('roadmap/')) focusReleaseFromHash();
    else if (changed || articleChanged || !animate) window.scrollTo({ top: 0, behavior: 'instant' });
  }

  function onScroll() {
    $('#topbar').classList.toggle('scrolled', window.scrollY > 8);
  }

  // #roadmap/<version> opens one release and scrolls to it.
  function focusReleaseFromHash() {
    const [head, sub] = decodeURIComponent(location.hash.slice(1)).split('/');
    if (head !== 'roadmap' || !sub) return;
    const el = document.getElementById('release-' + sub);
    if (!el) return;
    state.open.add(sub);
    el.classList.add('open');
    el.querySelector('[data-release]')?.setAttribute('aria-expanded', 'true');
    requestAnimationFrame(() => {
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      el.classList.remove('flash');
      void el.offsetWidth;
      el.classList.add('flash');
    });
  }

  // ── interactions ───────────────────────────────────────────────────────

  document.addEventListener('click', (e) => {
    // Re-tapping the active tab returns it to the top, as in the app.
    const link = e.target.closest('a[href^="#"]');
    if (link && link.getAttribute('href') === (location.hash || '#overview')) {
      e.preventDefault();
      window.scrollTo({ top: 0, behavior: 'smooth' });
      return;
    }
    if (e.target.closest('[data-lang-menu]')) {
      toggleLangMenu();
      return;
    }
    const lang = e.target.closest('[data-lang]');
    if (lang) {
      toggleLangMenu(false);
      if (lang.dataset.lang !== state.lang) {
        state.lang = lang.dataset.lang;
        localStorage.setItem('glaze-site-lang', state.lang);
        renderAll();
        showTab(state.active, false);
      }
      return;
    }
    if (!e.target.closest('#langMenu')) toggleLangMenu(false);
    const rel = e.target.closest('[data-release]');
    if (rel) {
      const key = rel.dataset.release;
      const open = !state.open.has(key);
      if (open) state.open.add(key); else state.open.delete(key);
      document.getElementById('release-' + key).classList.toggle('open', open);
      rel.setAttribute('aria-expanded', open);
      return;
    }
    const shot = e.target.closest('[data-shot]');
    if (shot) {
      openShot(Number(shot.dataset.shot));
      return;
    }
    const nav = e.target.closest('[data-viewer]');
    if (nav) {
      const a = nav.dataset.viewer;
      openShot(a === 'close' ? -1 : state.shot + (a === 'next' ? 1 : -1));
      return;
    }
    // A click on the dimmed backdrop, outside the picture, closes the viewer.
    if (state.shot >= 0 && e.target.id === 'viewer') {
      openShot(-1);
      return;
    }
    const testers = e.target.closest('[data-testers]');
    if (testers) {
      state.testersOpen = !state.testersOpen;
      testers.parentElement.classList.toggle('open', state.testersOpen);
      testers.setAttribute('aria-expanded', state.testersOpen);
      return;
    }
  });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') toggleLangMenu(false);
    if (state.shot < 0) return;
    if (e.key === 'Escape') openShot(-1);
    if (e.key === 'ArrowRight') openShot(state.shot + 1);
    if (e.key === 'ArrowLeft') openShot(state.shot - 1);
  });

  function toggleLangMenu(open) {
    const btn = $('[data-lang-menu]');
    const popup = $('#langMenu .popup');
    const show = open ?? popup.hidden;
    popup.hidden = !show;
    btn.setAttribute('aria-expanded', show);
  }

  document.addEventListener('pointermove', (e) => {
    if (e.pointerType !== 'mouse') return;
    const el = e.target.closest('[data-glow]');
    if (!el) return;
    // Pointer and rect are in screen px; the page is scaled by its CSS `zoom`
    // on wide monitors, and the glow is positioned in the element's own px.
    const r = el.getBoundingClientRect();
    const scale = r.width / el.offsetWidth || 1;
    el.style.setProperty('--mx', `${(e.clientX - r.left) / scale}px`);
    el.style.setProperty('--my', `${(e.clientY - r.top) / scale}px`);
  }, { passive: true });

  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('hashchange', () => route());

  // ── boot ───────────────────────────────────────────────────────────────

  for (const r of G.releases) if (r.status === 'dev' || r.status === 'latest') state.open.add(releaseKey(r));
  useFallback();
  renderAll();
  onScroll();
  route(false);
  loadRelease();
})();
