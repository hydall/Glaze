// Glaze VN3D — first-person 3D visual-novel engine.
//
// The model writes a compact line-based script (see model_spec.txt); this file
// turns it into walkable rooms with cardboard characters. The player walks
// by dragging on the left half, looks around by dragging on the right half,
// and taps people and objects to run the script's `on` blocks.
//
// Host API: `VN.load(scriptText, { lang })`. Events go back to the host through
// `window.flutter_inappwebview.callHandler('vn', json)` when it exists.
(function () {
  'use strict';

  const STRINGS = {
    ru: {
      talk: 'Поговорить', examine: 'Осмотреть', go: 'Перейти', closer: 'Подойди ближе',
      restart: 'Сыграть заново', end: 'Конец', noScene: 'Сцены «%s» нет в сценарии',
      empty: 'В сценарии нет ни одной сцены (строка «# имя»).',
      help: 'Слева — идти · справа — осмотреться · тап — взаимодействовать',
      nothing: 'Ничего интересного.', noWebgl: 'WebGL недоступен на этом устройстве.',
      got: 'Получено: %s', lost: 'Потеряно: %s',
    },
    en: {
      talk: 'Talk', examine: 'Examine', go: 'Go', closer: 'Get closer',
      restart: 'Play again', end: 'The End', noScene: 'Scene "%s" is not in the script',
      empty: 'The script has no scenes (a "# name" line).',
      help: 'Drag left to walk · drag right to look · tap to interact',
      nothing: 'Nothing interesting.', noWebgl: 'WebGL is not available on this device.',
      got: 'Got: %s', lost: 'Lost: %s',
    },
  };
  let S = STRINGS.ru;

  const PROP_NAMES = {
    ru: {
      desk: 'парта', board: 'доска', door: 'дверь', window: 'окно', clock: 'часы', lamp: 'фонарь',
      tank: 'бак', rail: 'перила', bench: 'скамейка', tree: 'дерево', pillar: 'колонна', crate: 'ящик',
      bed: 'кровать', shelf: 'шкаф', table: 'стол', plant: 'растение', locker: 'шкафчик', sofa: 'диван', tv: 'телевизор',
    },
    en: {},
  };

  // ── Parser: one command per line; anything unknown is skipped, never fatal ──
  const ID = '[\\p{L}\\p{N}_]+';
  const re = (s) => new RegExp(s, 'u');
  const NUM = '-?\\d+(?:\\.\\d+)?';
  const HEX = '#[0-9a-fA-F]{3,6}';
  const R = {
    scene: re(`^#\\s*(${ID})(?:\\s*<\\s*(${ID}))?\\s*$`),
    location: re(`^location\\s+(${ID})\\s*$`),
    texture: re(`^texture\\s+(${ID})\\s+([a-z]+)\\s+(${HEX})(?:\\s+(${HEX}))?(?:\\s+(${NUM}))?`),
    cast: re(`^cast\\s+(${ID})\\s+"([^"]+)"(?:\\s+(${HEX}))?`),
    item: re(`^item\\s+(${ID})\\s+"([^"]+)"(?:\\s+(.+))?$`),
    give: re(`^(give|take)\\s+(${ID})\\s*$`),
    on: re(`^on\\s+(${ID})\\s*$`),
    room: re(`^room\\s+(${NUM})\\s+(${NUM})(.*)$`),
    light: /^light\s+(day|dusk|night)\b/,
    spawn: re(`^spawn\\s+(${NUM}),\\s*(${NUM})(?:,\\s*(${NUM}))?`),
    prop: /^prop\s+(\S+)\s+(.+)$/u,
    place: re(`^place\\s+(${ID})\\s+(${NUM}),\\s*(${NUM})`),
    hide: re(`^hide\\s+(${ID})\\s*$`),
    look: re(`^look\\s+(${ID})\\s*$`),
    narr: /^>\s*(.+)$/,
    choice: re(`^\\?\\s*(.+?)\\s*->\\s*(${ID})\\s*$`),
    flag: re(`^(set|unset)\\s+(${ID})\\s*$`),
    iff: re(`^if\\s+(!?)(?:(has)\\s+)?(${ID})\\s*->\\s*(${ID})\\s*$`),
    goto: re(`^goto\\s+(${ID})\\s*$`),
    move: re(`^move\\s+(${ID})\\s+(${NUM}),\\s*(${NUM})`),
    end: /^end\s*$/,
    next: /^next(?:\s+(.+))?$/,
    once: /^once\s*$/,
    say: re(`^(${ID})(?:\\[(\\w+)\\])?\\s*:\\s*(.+)$`),
  };
  const STATIC = new Set(['room', 'light', 'prop', 'place', 'hide', 'spawn']);

  function parseLine(l) {
    let m;
    if ((m = l.match(R.room))) {
      // A surface is a color or the id of a `texture` line.
      const f = m[3].match(/floor\s+(\S+)/i);
      const w = m[3].match(/wall\s+(\S+)/i);
      return {
        op: 'room', w: clamp(+m[1], 4, 40), d: clamp(+m[2], 4, 40),
        floor: f ? f[1] : '#7a7f90', wall: w ? (w[1].toLowerCase() === 'none' ? 'none' : w[1]) : '#c8c4ba',
      };
    }
    if ((m = l.match(R.light))) return { op: 'light', v: m[1] };
    if ((m = l.match(R.spawn))) return { op: 'spawn', x: +m[1], z: +m[2], rot: +(m[3] || 0) };
    if ((m = l.match(R.prop))) {
      const out = { op: 'prop', type: m[1].toLowerCase(), color: null, link: null, label: null, pos: [] };
      for (const t of m[2].split(/\s+/)) {
        if (/^-?[\d.]+,-?[\d.]+(,-?[\d.]+)?$/.test(t)) out.pos.push(t.split(',').map(Number));
        else if (/^#[0-9a-f]{3,6}$/i.test(t)) out.color = t;
        else if (t.startsWith('@') && t.length > 1) out.link = t.slice(1);
        else if (t.startsWith('!') && t.length > 1) out.label = t.slice(1);
      }
      return out.pos.length ? out : null;
    }
    if ((m = l.match(R.place))) return { op: 'place', id: m[1], x: +m[2], z: +m[3] };
    if ((m = l.match(R.hide))) return { op: 'hide', id: m[1] };
    if ((m = l.match(R.look))) return { op: 'look', id: m[1] };
    if ((m = l.match(R.narr))) return { op: 'narr', text: m[1] };
    if ((m = l.match(R.choice))) return { op: 'choice', text: m[1], to: m[2] };
    if ((m = l.match(R.flag))) return { op: m[1], f: m[2] };
    if ((m = l.match(R.iff))) return { op: 'if', not: !!m[1], has: !!m[2], f: m[3], to: m[4] };
    if ((m = l.match(R.give))) return { op: m[1], item: m[2] };
    if ((m = l.match(R.goto))) return { op: 'goto', to: m[1] };
    if ((m = l.match(R.move))) return { op: 'move', id: m[1], x: +m[2], z: +m[3] };
    if (R.end.test(l)) return { op: 'end' };
    if ((m = l.match(R.next))) return { op: 'next', hint: (m[1] || '').trim() };
    if (R.once.test(l)) return { op: 'once' };
    if ((m = l.match(R.say))) return { op: 'say', id: m[1], emo: (m[2] || '').toLowerCase(), text: m[3] };
    return null;
  }

  // A script is the story so far: every pass the model wrote, joined. A later
  // definition of a cast member, texture, location or scene replaces the
  // earlier one. Each block carries a key so `once` survives a reload.
  function parse(src) {
    const cast = {}, scenes = {}, locations = {}, textures = {}, items = {}, order = [], skipped = [];
    let cur = null, block = null;
    const blockOf = (key) => { const b = []; b.key = key; return b; };
    String(src || '').split('\n').forEach((raw, i) => {
      const l = raw.trim();
      if (!l || l.startsWith('//')) return;
      // Separates two parts of the story: nothing carries over the line.
      if (l === '---') { cur = null; block = null; return; }
      let m;
      if ((m = l.match(R.scene))) {
        cur = { id: m[1], base: m[2] || null, stat: [], intro: blockOf(`${m[1]}/`), on: {} };
        if (!scenes[cur.id]) order.push(cur.id);
        scenes[cur.id] = cur; block = cur.intro;
        return;
      }
      if ((m = l.match(R.location))) {
        cur = { id: m[1], base: null, stat: [], intro: [], on: {}, loc: true };
        locations[cur.id] = cur; block = null;
        return;
      }
      if ((m = l.match(R.texture))) {
        textures[m[1]] = { kind: m[2], c1: m[3], c2: m[4] || null, scale: clamp(+(m[5] || 1), 0.25, 4) };
        return;
      }
      if ((m = l.match(R.cast))) { cast[m[1]] = { name: m[2], color: m[3] || '#c9c9d6' }; return; }
      if ((m = l.match(R.item))) { items[m[1]] = { name: m[2], desc: (m[3] || '').trim() }; return; }
      if (cur && !cur.loc && (m = l.match(R.on))) { block = cur.on[m[1]] = blockOf(`${cur.id}/${m[1]}`); return; }
      const c = cur && parseLine(l);
      if (!c) { skipped.push(i + 1); return; }
      if (STATIC.has(c.op)) cur.stat.push(c);
      else if (block) block.push(c);
      else skipped.push(i + 1);
    });
    return { cast, scenes, locations, textures, items, order, skipped };
  }

  function clamp(v, a, b) { return Math.max(a, Math.min(b, Number.isFinite(v) ? v : a)); }

  // ── three.js scene ──────────────────────────────────────────────────────────
  const T3 = window.THREE;
  const $ = (s) => document.querySelector(s);
  const stageEl = $('#stage');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  let renderer = null;
  try {
    renderer = new T3.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
    renderer.outputEncoding = T3.sRGBEncoding;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = T3.PCFSoftShadowMap;
    stageEl.prepend(renderer.domElement);
  } catch (e) {
    renderer = null;
  }
  const scene = new T3.Scene();
  const camera = new T3.PerspectiveCamera(68, 1, 0.05, 200);
  camera.rotation.order = 'YXZ';
  const EYE = 1.55, SPEED = 2.6, REACH = 3.2, BODY = 0.32;
  const player = { x: 0, z: 0, yaw: 0, pitch: -0.05 };

  function resize() {
    const r = stageEl.getBoundingClientRect();
    if (!renderer || !r.width || !r.height) return;
    renderer.setSize(r.width, r.height, false);
    camera.aspect = r.width / r.height;
    camera.updateProjectionMatrix();
  }
  new ResizeObserver(resize).observe(stageEl);

  const LIGHTS = {
    day: { bg: '#a8c6e6', hemi: ['#ffffff', '#8a95a8', 0.95], dir: ['#fff6e8', 0.9, [5, 10, 6]], tint: '#ffffff', glass: '#d6ecff' },
    dusk: { bg: '#3a2a45', hemi: ['#ffb894', '#2a2140', 0.7], dir: ['#ff9d5e', 1.1, [-9, 5, 3]], tint: '#ffe2cf', glass: '#ffb072' },
    night: { bg: '#0c1020', hemi: ['#6a78b8', '#0e0f18', 0.5], dir: ['#9fb4ff', 0.45, [4, 10, 3]], tint: '#b9c3ea', glass: '#2c3d74' },
  };
  let lightMode = 'day';

  const mat = (c, o) => new T3.MeshStandardMaterial(Object.assign({ color: c, roughness: 0.85, metalness: 0 }, o || {}));
  function add(g, geo, m, x, y, z) {
    const me = new T3.Mesh(geo, m); me.position.set(x, y, z);
    me.castShadow = me.receiveShadow = true; g.add(me); return me;
  }
  const B = (g, w, h, d, m, x, y, z) => add(g, new T3.BoxGeometry(w, h, d), m, x, y, z);
  const C = (g, rt, rb, h, m, x, y, z) => add(g, new T3.CylinderGeometry(rt, rb, h, 20), m, x, y, z);
  const shade = (hex, l) => { const c = new T3.Color(hex); c.offsetHSL(0, 0, l); return '#' + c.getHexString(); };
  const glassMat = () => mat(LIGHTS[lightMode].glass, { emissive: LIGHTS[lightMode].glass, emissiveIntensity: 0.75 });

  // Each builder draws a prop facing +z with its base on the floor.
  const PROPS = {
    desk(g, c) {
      const w = mat(c || '#a47b55'), l = mat('#3b3d4a');
      B(g, 1.2, 0.06, 0.7, w, 0, 0.76, 0);
      [[-0.55, -0.3], [0.55, -0.3], [-0.55, 0.3], [0.55, 0.3]].forEach(([x, z]) => B(g, 0.05, 0.74, 0.05, l, x, 0.37, z));
      B(g, 0.46, 0.05, 0.44, w, 0, 0.46, 0.62); B(g, 0.46, 0.42, 0.05, w, 0, 0.72, 0.84);
      [[-0.2, 0.44], [0.2, 0.44], [-0.2, 0.8], [0.2, 0.8]].forEach(([x, z]) => B(g, 0.04, 0.44, 0.04, l, x, 0.22, z));
    },
    table(g, c) {
      const w = mat(c || '#8d6a4c'), l = mat('#3b3d4a');
      B(g, 1.6, 0.06, 0.9, w, 0, 0.76, 0);
      [[-0.72, -0.38], [0.72, -0.38], [-0.72, 0.38], [0.72, 0.38]].forEach(([x, z]) => B(g, 0.06, 0.74, 0.06, l, x, 0.37, z));
    },
    board(g, c) {
      B(g, 3.3, 1.5, 0.08, mat('#5b4634'), 0, 1.75, 0);
      B(g, 3.1, 1.3, 0.1, mat(c || '#2e4b3c', { roughness: 1 }), 0, 1.75, 0.01);
      B(g, 3.1, 0.05, 0.14, mat('#5b4634'), 0, 1.07, 0.07);
      B(g, 1.1, 0.02, 0.02, mat('#e9e6da'), -0.6, 2.0, 0.07); B(g, 0.7, 0.02, 0.02, mat('#e9e6da'), -0.8, 1.8, 0.07);
    },
    door(g, c) {
      B(g, 1.3, 2.35, 0.08, mat('#e6dccd'), 0, 1.17, 0);
      B(g, 1.1, 2.2, 0.12, mat(c || '#6e4b34'), 0, 1.1, 0);
      B(g, 0.42, 0.5, 0.13, glassMat(), 0, 1.65, 0);
      add(g, new T3.SphereGeometry(0.05, 12, 12), mat('#d8b45a', { metalness: 0.6, roughness: 0.3 }), 0.4, 1.05, 0.09);
    },
    window(g, c) {
      const f = mat(c || '#ece6dc');
      B(g, 1.7, 1.4, 0.1, f, 0, 1.75, 0);
      B(g, 1.5, 1.2, 0.12, glassMat(), 0, 1.75, 0);
      B(g, 0.06, 1.2, 0.14, f, 0, 1.75, 0); B(g, 1.5, 0.06, 0.14, f, 0, 1.75, 0);
    },
    clock(g) {
      add(g, new T3.CylinderGeometry(0.32, 0.32, 0.06, 28), mat('#f4f1ea'), 0, 2.6, 0.04).rotation.x = Math.PI / 2;
      add(g, new T3.TorusGeometry(0.32, 0.03, 8, 28), mat('#3b3d4a'), 0, 2.6, 0.07);
      B(g, 0.03, 0.2, 0.02, mat('#222'), 0, 2.68, 0.09); B(g, 0.15, 0.03, 0.02, mat('#222'), 0.06, 2.6, 0.09);
    },
    tv(g, c) {
      B(g, 1.2, 0.5, 0.4, mat(c || '#3a3328'), 0, 0.25, 0);
      B(g, 1.3, 0.75, 0.06, mat('#15161c'), 0, 0.95, 0);
      B(g, 1.2, 0.66, 0.065, mat('#1d2a48', { emissive: '#22355f', emissiveIntensity: 0.6 }), 0, 0.95, 0.005);
    },
    lamp(g) {
      C(g, 0.05, 0.08, 3, mat('#2c2f3d'), 0, 1.5, 0);
      const bulb = new T3.Mesh(new T3.SphereGeometry(0.22, 16, 16), new T3.MeshBasicMaterial({ color: '#ffe1a6' }));
      bulb.position.set(0, 3.05, 0); g.add(bulb);
      const pl = new T3.PointLight('#ffd08a', 1.3, 10, 2); pl.position.set(0, 2.85, 0); g.add(pl);
    },
    tank(g, c) {
      const m = mat(c || '#8f98a6', { metalness: 0.3, roughness: 0.6 });
      C(g, 1, 1, 1.8, m, 0, 1.5, 0); C(g, 0.15, 1, 0.35, m, 0, 2.57, 0);
      [[-0.6, -0.6], [0.6, -0.6], [-0.6, 0.6], [0.6, 0.6]].forEach(([x, z]) => B(g, 0.1, 0.6, 0.1, mat('#555a68'), x, 0.3, z));
    },
    rail(g, c) {
      const m = mat(c || '#9aa3b5', { metalness: 0.4, roughness: 0.5 });
      for (let x = -2; x <= 2; x++) B(g, 0.06, 1.1, 0.06, m, x, 0.55, 0);
      B(g, 4.06, 0.06, 0.06, m, 0, 1.08, 0); B(g, 4.06, 0.04, 0.04, m, 0, 0.55, 0);
    },
    bench(g, c) {
      const w = mat(c || '#9b7652');
      B(g, 1.6, 0.07, 0.45, w, 0, 0.45, 0); B(g, 1.6, 0.38, 0.06, w, 0, 0.76, -0.2);
      [-0.7, 0.7].forEach((x) => B(g, 0.07, 0.45, 0.4, mat('#3b3d4a'), x, 0.22, 0));
    },
    sofa(g, c) {
      const m = mat(c || '#6c5a8e');
      B(g, 1.9, 0.42, 0.85, m, 0, 0.21, 0); B(g, 1.9, 0.55, 0.22, m, 0, 0.62, -0.32);
      [-0.88, 0.88].forEach((x) => B(g, 0.18, 0.6, 0.85, m, x, 0.3, 0));
    },
    bed(g, c) {
      B(g, 1.1, 0.35, 2.1, mat('#7b5a40'), 0, 0.18, 0);
      B(g, 1.0, 0.18, 2.0, mat('#f1efe9'), 0, 0.44, 0);
      B(g, 1.02, 0.12, 1.3, mat(c || '#6f8fc7'), 0, 0.55, 0.35);
      B(g, 0.6, 0.12, 0.35, mat('#ffffff'), 0, 0.58, -0.75);
      B(g, 1.1, 0.8, 0.08, mat('#7b5a40'), 0, 0.4, -1.05);
    },
    shelf(g, c) {
      const w = mat(c || '#7b5a40');
      B(g, 1.6, 2.0, 0.08, w, 0, 1.0, -0.18); [-0.78, 0.78].forEach((x) => B(g, 0.05, 2.0, 0.4, w, x, 1.0, 0));
      const books = ['#b4544b', '#4b77b4', '#d8b45a', '#5f9a68', '#8a5ab4'];
      for (let r = 0; r < 4; r++) {
        B(g, 1.56, 0.04, 0.4, w, 0, 0.1 + r * 0.5, 0);
        for (let i = 0; i < 9; i++) B(g, 0.12, 0.3 + (i % 3) * 0.05, 0.28, mat(books[(i + r) % 5]), -0.62 + i * 0.155, 0.28 + r * 0.5, 0);
      }
    },
    locker(g, c) {
      const m = mat(c || '#7d8ba0', { metalness: 0.4, roughness: 0.5 });
      B(g, 0.5, 1.9, 0.5, m, 0, 0.95, 0);
      for (let i = 0; i < 3; i++) B(g, 0.3, 0.02, 0.01, mat('#3b3d4a'), 0, 1.6 + i * 0.06, 0.255);
    },
    plant(g, c) {
      C(g, 0.22, 0.16, 0.4, mat('#b56d4a'), 0, 0.2, 0);
      add(g, new T3.SphereGeometry(0.42, 12, 10), mat(c || '#4f8a5b'), 0, 0.8, 0);
      add(g, new T3.SphereGeometry(0.3, 12, 10), mat(c || '#5a9a66'), 0.15, 1.12, 0.05);
    },
    tree(g, c) {
      C(g, 0.12, 0.16, 1.2, mat('#6b4a33'), 0, 0.6, 0);
      add(g, new T3.ConeGeometry(0.95, 1.6, 10), mat(c || '#4f8a5b'), 0, 1.8, 0);
      add(g, new T3.ConeGeometry(0.65, 1.2, 10), mat(c || '#5a9a66'), 0, 2.55, 0);
    },
    pillar(g, c) { C(g, 0.3, 0.3, 3.4, mat(c || '#cfc8bb'), 0, 1.7, 0); },
    crate(g, c) { B(g, 0.8, 0.8, 0.8, mat(c || '#a8824f'), 0, 0.4, 0); },
  };
  // Wall-mounted props: no collision, and the camera turns to them at this height.
  const WALLISH = { board: 1.75, door: 1.2, window: 1.75, clock: 2.6 };
  // Collision radius per prop; a missing entry means a 0.5 m box.
  const RADIUS = {
    desk: 0.6, table: 0.85, tv: 0.6, lamp: 0.2, tank: 1.15, rail: 0, bench: 0.85, sofa: 0.95,
    bed: 1.1, shelf: 0.8, locker: 0.35, plant: 0.4, tree: 0.5, pillar: 0.4, crate: 0.5,
  };

  // ── Cardboard character sprites ─────────────────────────────────────────────
  function drawChar(ctx, col, emo) {
    ctx.clearRect(0, 0, 256, 512);
    const P = Math.PI;
    const sil = [
      () => { ctx.beginPath(); ctx.ellipse(128, 195, 92, 122, 0, 0, P * 2); },
      () => { ctx.beginPath(); ctx.moveTo(84, 262); ctx.lineTo(172, 262); ctx.lineTo(206, 420); ctx.lineTo(50, 420); ctx.closePath(); },
      () => { ctx.beginPath(); ctx.rect(92, 410, 28, 84); ctx.rect(136, 410, 28, 84); },
      () => { ctx.beginPath(); ctx.ellipse(128, 165, 72, 76, 0, 0, P * 2); },
    ];
    ctx.save(); ctx.fillStyle = ctx.strokeStyle = '#fffaf1'; ctx.lineWidth = 22; ctx.lineJoin = 'round';
    sil.forEach((p) => { p(); ctx.fill(); ctx.stroke(); }); ctx.restore();

    ctx.fillStyle = shade(col, -0.12); sil[0](); ctx.fill();
    ctx.fillStyle = '#f2d8c6'; ctx.fillRect(98, 410, 18, 30); ctx.fillRect(140, 410, 18, 30);
    ctx.fillStyle = '#23263c'; ctx.fillRect(92, 438, 28, 48); ctx.fillRect(136, 438, 28, 48);
    ctx.fillStyle = '#4a3428'; ctx.fillRect(88, 482, 34, 12); ctx.fillRect(134, 482, 34, 12);
    ctx.fillStyle = '#2c3150'; sil[1](); ctx.fill();
    ctx.fillStyle = shade(col, -0.3);
    ctx.beginPath(); ctx.moveTo(66, 352); ctx.lineTo(190, 352); ctx.lineTo(206, 420); ctx.lineTo(50, 420); ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#f2d8c6'; ctx.fillRect(114, 222, 28, 44);
    ctx.fillStyle = '#eef0f6'; ctx.beginPath(); ctx.moveTo(96, 262); ctx.lineTo(128, 300); ctx.lineTo(160, 262); ctx.closePath(); ctx.fill();
    ctx.fillStyle = col; ctx.beginPath();
    ctx.moveTo(128, 292); ctx.lineTo(104, 280); ctx.lineTo(104, 306); ctx.closePath();
    ctx.moveTo(128, 292); ctx.lineTo(152, 280); ctx.lineTo(152, 306); ctx.closePath(); ctx.fill();
    ctx.fillStyle = '#ffe6d6'; sil[3](); ctx.fill();
    ctx.fillStyle = col;
    ctx.beginPath(); ctx.moveTo(56, 150); ctx.lineTo(82, 160); ctx.lineTo(76, 268); ctx.lineTo(50, 252); ctx.closePath(); ctx.fill();
    ctx.beginPath(); ctx.moveTo(200, 150); ctx.lineTo(174, 160); ctx.lineTo(180, 268); ctx.lineTo(206, 252); ctx.closePath(); ctx.fill();
    ctx.beginPath(); ctx.moveTo(52, 168); ctx.quadraticCurveTo(48, 72, 128, 70); ctx.quadraticCurveTo(208, 72, 204, 168);
    [[190, 140], [176, 162], [160, 126], [142, 158], [126, 124], [106, 156], [94, 128], [74, 160], [64, 140]].forEach((p) => ctx.lineTo(p[0], p[1]));
    ctx.closePath(); ctx.fill();
    ctx.fillStyle = 'rgba(255,255,255,.28)'; ctx.beginPath(); ctx.ellipse(104, 96, 22, 7, -0.35, 0, P * 2); ctx.fill();

    const iris = shade(col, -0.28), ink = '#2a2238';
    const eye = (x, big) => {
      const rx = big ? 12 : 10, ry = big ? 16 : 13;
      ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.ellipse(x, 176, rx + 2, ry + 1, 0, 0, P * 2); ctx.fill();
      ctx.fillStyle = iris; ctx.beginPath(); ctx.ellipse(x, 178, rx, ry, 0, 0, P * 2); ctx.fill();
      ctx.fillStyle = ink; ctx.beginPath(); ctx.ellipse(x, 180, rx * 0.5, ry * 0.55, 0, 0, P * 2); ctx.fill();
      ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.arc(x - 4, 172, 3.5, 0, P * 2); ctx.fill();
      ctx.strokeStyle = ink; ctx.lineWidth = 4; ctx.beginPath(); ctx.ellipse(x, 176, rx + 2, ry + 1, 0, P * 1.12, P * 1.88); ctx.stroke();
    };
    ctx.lineCap = 'round';
    if (emo === 'smile') {
      ctx.strokeStyle = ink; ctx.lineWidth = 5;
      [100, 156].forEach((x) => { ctx.beginPath(); ctx.arc(x, 182, 11, P * 1.15, P * 1.85); ctx.stroke(); });
    } else { eye(100, emo === 'surprised'); eye(156, emo === 'surprised'); }
    ctx.strokeStyle = shade(col, -0.35); ctx.lineWidth = 4;
    const line = (x1, y1, x2, y2) => { ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); };
    if (emo === 'angry') { line(86, 150, 114, 160); line(170, 150, 142, 160); }
    else if (emo === 'sad') { line(86, 158, 112, 150); line(170, 158, 144, 150); }
    else if (emo === 'surprised') { line(88, 146, 112, 143); line(168, 146, 144, 143); }
    if (emo === 'smile' || emo === 'surprised') {
      ctx.fillStyle = 'rgba(255,120,140,.35)';
      [88, 168].forEach((x) => { ctx.beginPath(); ctx.ellipse(x, 200, 13, 6, 0, 0, P * 2); ctx.fill(); });
    }
    ctx.strokeStyle = '#8a3f4a'; ctx.lineWidth = 4;
    if (emo === 'smile') { ctx.beginPath(); ctx.arc(128, 202, 12, P * 0.15, P * 0.85); ctx.stroke(); }
    else if (emo === 'sad') { ctx.beginPath(); ctx.arc(128, 222, 10, P * 1.2, P * 1.8); ctx.stroke(); }
    else if (emo === 'angry') line(118, 214, 140, 210);
    else if (emo === 'surprised') { ctx.fillStyle = '#8a3f4a'; ctx.beginPath(); ctx.ellipse(128, 214, 7, 9, 0, 0, P * 2); ctx.fill(); }
    else line(121, 212, 135, 212);
  }

  // ── World build ─────────────────────────────────────────────────────────────
  let game = { cast: {}, scenes: {}, locations: {}, textures: {}, items: {}, order: [], skipped: [] };
  let world = null, worldSig = '';
  let room = { w: 12, d: 9, wall: '#c8c4ba' };
  const chars = new Map();
  let interactables = [], obstacles = [], markers = [], spawn = null;

  // `# scene < base` builds on a location first, else on an earlier scene.
  function baseOf(sc) {
    if (!sc.base) return null;
    return game.locations[sc.base] || (sc.base !== sc.id ? game.scenes[sc.base] : null) || null;
  }
  function staticOf(sc, depth) {
    if (!sc || depth > 8) return [];
    return staticOf(baseOf(sc), depth + 1).concat(sc.stat);
  }
  function handlersOf(sc, depth) {
    if (!sc || depth > 8) return {};
    return Object.assign(handlersOf(baseOf(sc), depth + 1), sc.on);
  }

  function makeChar(id, x, z) {
    const info = game.cast[id] || { name: id, color: '#c9c9d6' };
    const cv = document.createElement('canvas'); cv.width = 256; cv.height = 512;
    const ctx = cv.getContext('2d');
    drawChar(ctx, info.color, 'normal');
    const tex = new T3.CanvasTexture(cv); tex.encoding = T3.sRGBEncoding; tex.anisotropy = 4;
    const m = new T3.MeshBasicMaterial({ map: tex, transparent: true, alphaTest: 0.4, side: T3.DoubleSide, color: LIGHTS[lightMode].tint });
    const g = new T3.Group();
    const card = new T3.Mesh(new T3.PlaneGeometry(1.05, 2.1), m); card.position.y = 1.05; g.add(card);
    const stand = new T3.Mesh(new T3.BoxGeometry(0.4, 0.5, 0.04), mat('#8b7a63'));
    stand.position.set(0, 0.25, -0.12); stand.rotation.x = -0.35; stand.castShadow = true; g.add(stand);
    const blob = new T3.Mesh(new T3.CircleGeometry(0.45, 24), new T3.MeshBasicMaterial({ color: '#000', transparent: true, opacity: 0.32, depthWrite: false }));
    blob.rotation.x = -Math.PI / 2; blob.position.y = 0.01; g.add(blob);
    g.position.set(x, 0, z);
    world.add(g);
    const o = { id, g, card, m, ctx, tex, info, emo: 'normal', tx: x, tz: z, cy: 1.05 };
    g.userData.target = { kind: 'char', id, keys: [id], label: info.name };
    chars.set(id, o);
    wearSprite(o);
    return o;
  }
  function setEmo(o, emo) {
    emo = ['smile', 'angry', 'sad', 'surprised'].includes(emo) ? emo : 'normal';
    if (o.emo === emo) return;
    o.emo = emo;
    if (!wearSprite(o)) { drawChar(o.ctx, o.info.color, emo); o.tex.needsUpdate = true; }
  }

  // ── Drawn sprites: the host sends pictures of the cast once the image
  // provider has drawn them; until then, and for a missing emotion, the
  // cardboard above stands in. Kept across scenes and script reloads. ──
  const SPRITE_H = 1.8;
  const sprites = {};
  function spriteOf(id, emo) {
    const set = sprites[id];
    if (!set) return null;
    const e = set[emo] && set[emo].tex ? set[emo] : set.normal;
    return e && e.tex ? e : null;
  }
  // Puts the character's sprite for its emotion on the card; false when
  // there is none yet.
  function wearSprite(o) {
    const e = spriteOf(o.id, o.emo);
    if (!e) return false;
    if (o.m.map !== e.tex) { o.m.map = e.tex; o.m.alphaTest = 0.2; o.m.needsUpdate = true; }
    const w = SPRITE_H * e.w / e.h;
    o.card.scale.set(w / 1.05, SPRITE_H / 2.1, 1);
    o.cy = SPRITE_H / 2;
    return true;
  }
  function addSprites(map) {
    for (const [id, emos] of Object.entries(map || {})) {
      const old = sprites[id];
      if (old) Object.values(old).forEach((e) => e.tex && e.tex.dispose());
      const set = sprites[id] = {};
      for (const [emo, url] of Object.entries(emos || {})) {
        const e = set[emo] = { tex: null, w: 1, h: 2 };
        const im = new Image();
        im.onload = () => {
          if (sprites[id] !== set) return;
          const t = new T3.Texture(im);
          t.encoding = T3.sRGBEncoding; t.anisotropy = 4; t.vnKeep = true; t.needsUpdate = true;
          Object.assign(e, { tex: t, w: im.naturalWidth, h: im.naturalHeight });
          const o = chars.get(id);
          if (o) wearSprite(o);
        };
        im.src = url;
      }
    }
  }

  // ── Surfaces: a `texture` line names a pattern and its colors; the pattern
  // is painted here, so the model describes materials without any images ──
  const PATTERNS = {
    plain(c, a, b, rnd) {
      for (let i = 0; i < 900; i++) { c.fillStyle = shade(a, (rnd() - 0.5) * 0.06); c.fillRect(rnd() * 256, rnd() * 256, 3, 3); }
    },
    planks(c, a, b, rnd) {
      for (let y = 0; y < 256; y += 32) {
        c.fillStyle = shade(a, (rnd() - 0.5) * 0.08); c.fillRect(0, y, 256, 32);
        c.fillStyle = b; c.fillRect(0, y, 256, 2);
        c.fillRect(rnd() * 256, y, 2, 32);
      }
    },
    tiles(c, a, b) {
      c.strokeStyle = b; c.lineWidth = 3;
      for (let i = 0; i <= 256; i += 64) { c.beginPath(); c.moveTo(i, 0); c.lineTo(i, 256); c.moveTo(0, i); c.lineTo(256, i); c.stroke(); }
    },
    checker(c, a, b) {
      c.fillStyle = b;
      for (let y = 0; y < 4; y++) for (let x = 0; x < 4; x++) if ((x + y) % 2) c.fillRect(x * 64, y * 64, 64, 64);
    },
    brick(c, a, b, rnd) {
      c.fillStyle = b; c.fillRect(0, 0, 256, 256);
      for (let r = 0; r < 8; r++) {
        const off = r % 2 ? 32 : 0;
        for (let x = -64; x < 256; x += 64) {
          c.fillStyle = shade(a, (rnd() - 0.5) * 0.1); c.fillRect(x + off + 2, r * 32 + 2, 60, 28);
        }
      }
    },
    stone(c, a, b, rnd) {
      c.fillStyle = b; c.fillRect(0, 0, 256, 256);
      for (let i = 0; i < 40; i++) {
        c.fillStyle = shade(a, (rnd() - 0.5) * 0.12);
        c.beginPath(); c.ellipse(rnd() * 256, rnd() * 256, 14 + rnd() * 18, 10 + rnd() * 14, rnd() * 3, 0, Math.PI * 2); c.fill();
      }
    },
    carpet(c, a, b, rnd) {
      for (let i = 0; i < 4000; i++) { c.fillStyle = shade(a, (rnd() - 0.5) * 0.1); c.fillRect(rnd() * 256, rnd() * 256, 2, 2); }
      c.strokeStyle = b; c.lineWidth = 6; c.strokeRect(16, 16, 224, 224);
    },
    grass(c, a, b, rnd) {
      c.lineWidth = 2;
      for (let i = 0; i < 1400; i++) {
        const x = rnd() * 256, y = rnd() * 256;
        c.strokeStyle = rnd() < 0.3 ? b : shade(a, (rnd() - 0.5) * 0.14);
        c.beginPath(); c.moveTo(x, y); c.lineTo(x + (rnd() - 0.5) * 6, y - 4 - rnd() * 6); c.stroke();
      }
    },
    sand(c, a, b, rnd) {
      for (let i = 0; i < 3000; i++) { c.fillStyle = rnd() < 0.2 ? b : shade(a, (rnd() - 0.5) * 0.08); c.fillRect(rnd() * 256, rnd() * 256, 2, 2); }
    },
    concrete(c, a, b, rnd) {
      PATTERNS.plain(c, a, b, rnd);
      c.strokeStyle = b; c.lineWidth = 1.5;
      for (let i = 0; i < 3; i++) {
        let x = rnd() * 256, y = rnd() * 256; c.beginPath(); c.moveTo(x, y);
        for (let k = 0; k < 6; k++) { x += (rnd() - 0.5) * 40; y += (rnd() - 0.5) * 40; c.lineTo(x, y); }
        c.stroke();
      }
    },
    metal(c, a, b, rnd) {
      for (let y = 0; y < 256; y += 2) { c.fillStyle = shade(a, (rnd() - 0.5) * 0.05); c.fillRect(0, y, 256, 2); }
      c.fillStyle = b; [32, 224].forEach((x) => [32, 224].forEach((y) => { c.beginPath(); c.arc(x, y, 4, 0, Math.PI * 2); c.fill(); }));
    },
    stripes(c, a, b) {
      c.fillStyle = b;
      for (let x = 0; x < 256; x += 32) c.fillRect(x, 0, 12, 256);
    },
    wallpaper(c, a, b) {
      c.fillStyle = b;
      for (let y = 0; y < 256; y += 32) for (let x = (y / 32) % 2 ? 16 : 0; x < 256; x += 32) {
        c.beginPath(); c.moveTo(x + 16, y + 6); c.lineTo(x + 24, y + 16); c.lineTo(x + 16, y + 26); c.lineTo(x + 8, y + 16); c.closePath(); c.fill();
      }
    },
    panels(c, a, b) {
      c.strokeStyle = b; c.lineWidth = 4;
      c.strokeRect(8, 8, 112, 240); c.strokeRect(136, 8, 112, 240);
    },
    water(c, a, b, rnd) {
      c.strokeStyle = b; c.lineWidth = 2;
      for (let i = 0; i < 60; i++) {
        const x = rnd() * 256, y = rnd() * 256;
        c.beginPath(); c.arc(x, y, 6 + rnd() * 10, Math.PI * 1.15, Math.PI * 1.85); c.stroke();
      }
    },
  };
  const paintCache = new Map();

  // [value] is a color or a texture id; [kind] is the pattern a bare color gets.
  function surface(value, kind) {
    const t = game.textures[value];
    const spec = t
      ? { kind: PATTERNS[t.kind] ? t.kind : 'plain', c1: t.c1, c2: t.c2, scale: t.scale }
      : { kind, c1: /^#[0-9a-f]{3,6}$/i.test(value) ? value : '#8a8f9c', c2: null, scale: 1 };
    spec.c2 = spec.c2 || shade(spec.c1, -0.14);
    return spec;
  }
  function surfaceTex(spec, w, h) {
    const sig = `${spec.kind}${spec.c1}${spec.c2}`;
    let cv = paintCache.get(sig);
    if (!cv) {
      cv = document.createElement('canvas'); cv.width = cv.height = 256;
      const c = cv.getContext('2d');
      c.fillStyle = spec.c1; c.fillRect(0, 0, 256, 256);
      let s = 7; const rnd = () => (s = (s * 9301 + 49297) % 233280) / 233280;
      PATTERNS[spec.kind](c, spec.c1, spec.c2, rnd);
      paintCache.set(sig, cv);
    }
    const t = new T3.CanvasTexture(cv); t.encoding = T3.sRGBEncoding; t.wrapS = t.wrapT = T3.RepeatWrapping;
    t.repeat.set(w / (3 * spec.scale), h / (3 * spec.scale));
    return t;
  }

  function disposeWorld() {
    if (!world) return;
    // A character wearing a sprite still owns its cardboard canvas.
    chars.forEach((o) => o.tex.dispose());
    world.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
      if (o.material) {
        if (o.material.map && !o.material.map.vnKeep) o.material.map.dispose();
        o.material.dispose();
      }
    });
    scene.remove(world);
    world = null;
  }

  // Rebuilds only when the scene's static description differs from the
  // current room, so `# talk < hall` keeps the player where they stand.
  function build(list, handlers) {
    const sig = JSON.stringify(list);
    if (sig === worldSig && world) { refreshInteractables(handlers); return false; }
    worldSig = sig;
    disposeWorld(); chars.clear(); obstacles = []; markers = [];
    world = new T3.Group(); scene.add(world);
    room = { w: 12, d: 9, floor: '#7a7f90', wall: '#c8c4ba' }; lightMode = 'day'; spawn = null;
    const props = [], places = new Map();
    for (const c of list) {
      if (c.op === 'room') room = c;
      else if (c.op === 'light') lightMode = c.v;
      else if (c.op === 'spawn') spawn = c;
      else if (c.op === 'prop') props.push(c);
      else if (c.op === 'place') places.set(c.id, [c.x, c.z]);
      else if (c.op === 'hide') places.delete(c.id);
    }
    const L = LIGHTS[lightMode], open = room.wall === 'none', H = 3.4;
    scene.background = new T3.Color(L.bg);
    scene.fog = new T3.Fog(L.bg, 12, open ? 70 : 40);
    world.add(new T3.HemisphereLight(L.hemi[0], L.hemi[1], L.hemi[2]));
    const dir = new T3.DirectionalLight(L.dir[0], L.dir[1]);
    dir.position.set(L.dir[2][0], L.dir[2][1], L.dir[2][2]); dir.castShadow = true;
    dir.shadow.mapSize.set(1024, 1024);
    Object.assign(dir.shadow.camera, { left: -14, right: 14, top: 14, bottom: -14, near: 0.5, far: 50 });
    dir.shadow.bias = -0.0005; world.add(dir);
    if (!open) {
      const fill = new T3.PointLight(L.tint, 0.35, 18, 2); fill.position.set(0, H - 0.4, 0); world.add(fill);
    }

    const fs = surface(room.floor, open ? 'tiles' : 'planks');
    const floor = new T3.Mesh(new T3.PlaneGeometry(room.w, room.d), mat('#ffffff', { map: surfaceTex(fs, room.w, room.d) }));
    floor.rotation.x = -Math.PI / 2; floor.receiveShadow = true; world.add(floor);
    if (!open) {
      const ws = surface(room.wall, 'plain'), base = mat(shade(ws.c1, -0.3));
      const wall = (w, x, z, ry) => {
        const p = new T3.Mesh(new T3.PlaneGeometry(w, H), mat('#ffffff', { map: surfaceTex(ws, w, H) }));
        p.position.set(x, H / 2, z); p.rotation.y = ry; p.receiveShadow = true; world.add(p);
        const b = new T3.Mesh(new T3.BoxGeometry(w, 0.14, 0.04), base); b.position.set(x, 0.07, z); b.rotation.y = ry; world.add(b);
      };
      wall(room.w, 0, -room.d / 2, 0); wall(room.w, 0, room.d / 2, Math.PI);
      wall(room.d, -room.w / 2, 0, Math.PI / 2); wall(room.d, room.w / 2, 0, -Math.PI / 2);
      // Lit from below only, so it gets a little of its own glow to stay pale.
      const ceil = new T3.Mesh(new T3.PlaneGeometry(room.w, room.d), mat(shade(ws.c1, 0.06), { emissive: ws.c1, emissiveIntensity: 0.35 }));
      ceil.rotation.x = Math.PI / 2; ceil.position.y = H; world.add(ceil);
      for (let x = -room.w / 2 + 2; x < room.w / 2 - 1; x += 3) {
        const panel = new T3.Mesh(new T3.BoxGeometry(1.2, 0.04, 0.3), new T3.MeshBasicMaterial({ color: '#fff8ea' }));
        panel.position.set(x, H - 0.03, 0); world.add(panel);
      }
    } else {
      let s = 3; const rnd = () => (s = (s * 9301 + 49297) % 233280) / 233280;
      const bm = mat('#161b2e', { roughness: 1 }), pts = [];
      for (let i = 0; i < 60; i++) {
        const a = rnd() * Math.PI * 2, r = 26 + rnd() * 18, h = 3 + rnd() * 14, w = 2 + rnd() * 3;
        const x = Math.cos(a) * r, z = Math.sin(a) * r;
        const b = new T3.Mesh(new T3.BoxGeometry(w, h, w), bm); b.position.set(x, h / 2 - 8, z); b.lookAt(0, h / 2 - 8, 0); world.add(b);
        for (let k = 0; k < 8; k++) {
          const v = new T3.Vector3((rnd() - 0.5) * w, -8 + rnd() * h, w / 2 + 0.05).applyQuaternion(b.quaternion);
          pts.push(x + v.x, v.y, z + v.z);
        }
      }
      const pg = new T3.BufferGeometry(); pg.setAttribute('position', new T3.Float32BufferAttribute(pts, 3));
      world.add(new T3.Points(pg, new T3.PointsMaterial({ color: '#ffd38a', size: 0.35, fog: false })));
    }

    for (const p of props) {
      const make = PROPS[p.type] || ((g, c) => B(g, 0.8, 0.8, 0.8, mat(c || '#8a8fa8'), 0, 0.4, 0));
      for (const [x, z, rot = 0] of p.pos) {
        const g = new T3.Group(); make(g, p.color);
        g.position.set(x, 0, z); g.rotation.y = rot * Math.PI / 180;
        world.add(g);
        const keys = [p.label, p.type].filter(Boolean);
        const label = p.label || (PROP_NAMES[langKey][p.type] || p.type);
        g.userData.target = { kind: 'prop', type: p.type, keys, label, link: p.link, wall: WALLISH[p.type] };
        if (!WALLISH[p.type]) {
          const r = RADIUS[p.type] != null ? RADIUS[p.type] : 0.5;
          if (r > 0) obstacles.push({ x, z, r });
          if (p.type === 'rail') for (let k = -2; k <= 2; k++) obstacles.push({ x: x + Math.cos(g.rotation.y) * k, z: z - Math.sin(g.rotation.y) * k, r: 0.25 });
        }
      }
    }
    for (const [id, [x, z]] of places) makeChar(id, x, z);
    refreshInteractables(handlers);
    return true;
  }

  // Only what the script reacts to is tappable: an `on` block, or a door link.
  function refreshInteractables(handlers) {
    st.handlers = handlers;
    markers.forEach((m) => { world.remove(m); m.geometry.dispose(); m.material.dispose(); });
    markers = []; interactables = [];
    world.children.forEach((g) => {
      const t = g.userData && g.userData.target;
      if (!t) return;
      t.key = t.keys.find((k) => handlers[k]) || null;
      if (!t.key && !t.link) return;
      interactables.push(g);
      const mk = new T3.Mesh(new T3.OctahedronGeometry(0.09), new T3.MeshBasicMaterial({ color: '#c3b2ff', fog: false, transparent: true, opacity: 0.9 }));
      const front = t.wall ? 0.3 : 0;
      const y = t.kind === 'char' ? 2.3 : t.wall ? t.wall + 0.95 : 1.5;
      mk.position.set(g.position.x + Math.sin(g.rotation.y) * front, y, g.position.z + Math.cos(g.rotation.y) * front);
      mk.userData.baseY = y; mk.userData.owner = g;
      world.add(mk); markers.push(mk);
    });
  }

  // ── Runtime ────────────────────────────────────────────────────────────────
  const st = { scene: null, seq: [], pc: 0, flags: new Set(), mode: 'idle', speaking: null, full: '', shown: 0, handlers: {}, lookAt: null };
  const dlg = $('#dlg'), who = $('#who'), lineEl = $('#line'), choicesEl = $('#choices'), moreEl = $('#more');
  const fadeEl = $('#fade'), toastEl = $('#toast'), focusEl = $('#focus'), reticle = $('#reticle');
  const endEl = $('#endcard');
  let langKey = 'ru';

  function host(type, data) {
    try {
      const h = window.flutter_inappwebview;
      if (h && h.callHandler) h.callHandler('vn', JSON.stringify(Object.assign({ type }, data || {})));
    } catch (_) { /* no host */ }
  }
  function toast(msg) {
    toastEl.textContent = msg; toastEl.hidden = false;
    clearTimeout(toast.h); toast.h = setTimeout(() => { toastEl.hidden = true; }, 2600);
  }
  // Flags and items are shown by the host's status window, not here.
  function renderHud() {
    $('#sceneName').textContent = st.scene ? st.scene.id : '—';
  }
  function setMode(mode) {
    st.mode = mode;
    document.body.dataset.mode = mode;
    if (mode !== 'say' && mode !== 'choice') { dlg.hidden = true; st.speaking = null; tintChars(); }
    if (mode !== 'roam') stopMove();
  }
  function fade(on) {
    return new Promise((res) => {
      fadeEl.classList.toggle('on', on);
      setTimeout(res, reduce ? 0 : 320);
    });
  }

  // [resume] puts the player back where a saved game left them, without
  // replaying the scene's intro.
  async function enter(id, resume) {
    const sc = game.scenes[id];
    if (!sc) { toast(S.noScene.replace('%s', id)); setMode('roam'); return; }
    setMode('fade');
    const list = staticOf(sc, 0), handlers = handlersOf(sc, 0);
    const willRebuild = JSON.stringify(list) !== worldSig || !world;
    if (willRebuild) await fade(true);
    const rebuilt = build(list, handlers);
    st.scene = sc;
    if (resume && resume.pos) {
      player.x = +resume.pos.x || 0; player.z = +resume.pos.z || 0; player.yaw = +resume.pos.yaw || 0;
      player.pitch = -0.05; st.lookAt = null; collide();
    } else if (rebuilt) placePlayer();
    renderHud();
    if (willRebuild) await fade(false);
    if (!resume) note({ k: 'scene', text: sc.id });
    saveSoon();
    const exits = exitsOf(sc);
    if (exits.length && !pendingNext) host('near', { state: snapshot(), exits });
    if (resume) setMode('roam'); else run(sc.intro);
  }
  function placePlayer() {
    const s = spawn || { x: 0, z: room.d / 2 - 1.2, rot: 0 };
    player.x = s.x; player.z = s.z; player.yaw = (s.rot || 0) * Math.PI / 180; player.pitch = -0.05;
    st.lookAt = null;
    collide();
  }

  // Keys of the blocks that started with `once` and already ran.
  let seen = new Set();
  // What the player chose, newest last: the model reads it to write on.
  let log = [];
  // Items the player carries, in the order they were received.
  let inv = [];
  // Everything the player read, newest last: the status window's journal.
  // Entries: { k: 'scene'|'narr'|'say'|'choice'|'item', who?, text }.
  let backlog = [];
  const BACKLOG_MAX = 200;
  function note(entry) {
    backlog.push(entry);
    if (backlog.length > BACKLOG_MAX) backlog.splice(0, backlog.length - BACKLOG_MAX);
  }
  // Set while the host writes the next part of the story.
  let pendingNext = null;
  // How many parts the host has written; kept on a `next` so the host can
  // tell whether it was answered before the app closed.
  let parts = 0;
  function run(seq) { st.seq = seq || []; st.pc = 0; step(); }

  function snapshot() {
    return {
      scene: st.scene && st.scene.id,
      flags: [...st.flags],
      seen: [...seen],
      log: log.slice(-60),
      inv: inv.slice(),
      backlog: backlog.slice(),
      pos: { x: +player.x.toFixed(2), z: +player.z.toFixed(2), yaw: +player.yaw.toFixed(3) },
      next: pendingNext,
    };
  }
  // Batches the state writes of one step into one host call.
  function saveSoon() {
    if (saveSoon.queued) return;
    saveSoon.queued = true;
    setTimeout(() => { saveSoon.queued = false; host('state', { state: snapshot() }); }, 0);
  }

  // The `next` hints a scene can reach from its own intro and blocks. A
  // scene with any is where the current part ends, so the host starts
  // writing the next one before the player gets there.
  function exitsOf(sc) {
    const blocks = [sc.intro].concat(Object.values(handlersOf(sc, 0)));
    const hints = [];
    blocks.forEach((b) => b.forEach((c) => { if (c.op === 'next') hints.push(c.hint || ''); }));
    return hints;
  }

  // The story so far ends here: the host writes what comes next and calls
  // `VN.extend`. The player keeps walking meanwhile.
  function requestNext(hint) {
    if (!pendingNext) {
      pendingNext = { scene: st.scene && st.scene.id, hint: hint || '', part: parts };
      host('next', { state: snapshot() });
    }
    setMode('roam');
  }

  function jump(to) {
    if (st.handlers[to]) { run(st.handlers[to]); return; }
    enter(to);
  }

  function step() {
    const seq = st.seq;
    while (st.pc < seq.length) {
      const c = seq[st.pc++];
      switch (c.op) {
        case 'look': lookAtTarget(c.id); break;
        case 'set': st.flags.add(c.f); renderHud(); saveSoon(); break;
        case 'unset': st.flags.delete(c.f); renderHud(); saveSoon(); break;
        case 'move': { const o = chars.get(c.id); if (o) { o.tx = c.x; o.tz = c.z; } break; }
        case 'if': if ((c.has ? inv.includes(c.f) : st.flags.has(c.f)) !== c.not) { jump(c.to); return; } break;
        case 'give':
          if (!inv.includes(c.item)) {
            inv.push(c.item);
            const name = itemName(c.item);
            toast(S.got.replace('%s', name)); note({ k: 'item', text: S.got.replace('%s', name) }); saveSoon();
          }
          break;
        case 'take':
          if (inv.includes(c.item)) {
            inv = inv.filter((x) => x !== c.item);
            const name = itemName(c.item);
            toast(S.lost.replace('%s', name)); note({ k: 'item', text: S.lost.replace('%s', name) }); saveSoon();
          }
          break;
        case 'goto': jump(c.to); return;
        case 'narr': say(null, c.text); return;
        case 'say': say(c.id, c.text, c.emo); return;
        case 'choice': {
          const list = [c];
          while (st.pc < seq.length && seq[st.pc].op === 'choice') list.push(seq[st.pc++]);
          choose(list); return;
        }
        case 'once':
          if (seen.has(seq.key)) { st.pc = seq.length; break; }
          seen.add(seq.key); saveSoon(); break;
        case 'next': requestNext(c.hint); return;
        case 'end': finish(); return;
      }
    }
    if (queuedEnter) { const to = queuedEnter; queuedEnter = null; enter(to); return; }
    setMode('roam');
  }

  function itemName(id) { return (game.items[id] && game.items[id].name) || id; }

  function lookAtTarget(id) {
    const o = chars.get(id);
    if (o) { st.lookAt = new T3.Vector3(o.tx, 1.45, o.tz); return; }
    const g = interactables.concat(world ? world.children : []).find((x) => x.userData.target && x.userData.target.keys.includes(id));
    if (g) st.lookAt = new T3.Vector3(g.position.x, g.userData.target.wall || 0.8, g.position.z);
  }

  function say(id, text, emo) {
    setMode('say');
    dlg.hidden = false; choicesEl.innerHTML = ''; moreEl.hidden = true;
    st.full = text; st.shown = reduce ? text.length : 0;
    const o = id && chars.get(id);
    st.speaking = o || null;
    if (o) { setEmo(o, emo); lookAtTarget(id); }
    note(id ? { k: 'say', who: (game.cast[id] || { name: id }).name, text } : { k: 'narr', text });
    if (id) {
      const info = game.cast[id] || { name: id, color: '#f1c56e' };
      who.textContent = info.name; who.style.background = info.color; who.hidden = false; lineEl.className = '';
    } else { who.hidden = true; lineEl.className = 'narr'; }
    tintChars();
  }
  function tintChars() {
    const base = new T3.Color(LIGHTS[lightMode].tint);
    chars.forEach((o) => { o.m.color.copy(base); if (st.speaking && st.speaking !== o) o.m.color.multiplyScalar(0.62); });
  }
  function choose(list) {
    const keepLine = st.mode === 'say';
    st.mode = 'choice'; document.body.dataset.mode = 'choice';
    dlg.hidden = false; moreEl.hidden = true;
    if (!keepLine) { who.hidden = true; lineEl.textContent = ''; }
    st.shown = st.full.length;
    choicesEl.innerHTML = '';
    list.forEach((c, i) => {
      const b = document.createElement('button'); b.type = 'button';
      b.textContent = `${i + 1}. ${c.text}`;
      b.addEventListener('pointerup', (e) => {
        e.stopPropagation();
        if (st.mode !== 'choice') return;
        log.push({ scene: st.scene && st.scene.id, choice: c.text });
        note({ k: 'choice', text: c.text });
        st.full = ''; saveSoon(); jump(c.to);
      });
      choicesEl.append(b);
    });
  }
  function finish() {
    setMode('end');
    endEl.hidden = false;
    host('ended', { scene: st.scene && st.scene.id, flags: [...st.flags] });
  }

  function advance() {
    if (st.mode !== 'say') return;
    if (st.shown < st.full.length) { st.shown = st.full.length; return; }
    const next = st.seq[st.pc];
    if (next && next.op === 'choice') { step(); return; }
    st.full = ''; step();
  }

  function interact(g) {
    const t = g.userData.target;
    const d = Math.hypot(g.position.x - player.x, g.position.z - player.z);
    if (d > REACH + (t.wall ? 0.6 : 0)) { toast(S.closer); return; }
    if (t.key) {
      if (t.kind === 'char') lookAtTarget(t.id);
      run(st.handlers[t.key]);
    } else if (t.link) enter(t.link);
  }

  // ── Controls: drag on the left half walks, drag on the right half looks,
  // a tap anywhere interacts (or advances the dialogue) ─────────────────────
  // A walking finger acts as an invisible stick anchored where it landed.
  const move = { id: null, x: 0, y: 0 };
  const pointers = new Map();
  const keys = new Set();
  const STICK_R = 70, TAP_SLOP = 12;

  function stopMove() { move.id = null; move.x = move.y = 0; }

  // Pointer handling, fed by the page's own pointer events on desktop and by
  // `VN.input` where the host forwards touches itself (see vn_screen.dart).
  function pointerDown(id, x, y) {
    const r = stageEl.getBoundingClientRect();
    const side = x - r.left < r.width / 2 ? 'move' : 'look';
    pointers.set(id, { side, x, y, sx: x, sy: y, t: performance.now(), moved: 0 });
    if (side === 'move' && move.id === null) move.id = id;
  }
  function pointerMove(id, x, y) {
    const p = pointers.get(id);
    if (!p) return;
    const dx = x - p.x, dy = y - p.y;
    p.x = x; p.y = y; p.moved += Math.abs(dx) + Math.abs(dy);
    if (st.mode !== 'roam' || p.moved <= TAP_SLOP / 2) return;
    if (p.side === 'move' && id === move.id) {
      let vx = x - p.sx, vy = y - p.sy;
      const len = Math.hypot(vx, vy);
      if (len > STICK_R) { vx = vx / len * STICK_R; vy = vy / len * STICK_R; }
      move.x = vx / STICK_R; move.y = vy / STICK_R;
    } else if (p.side === 'look') {
      // A finger cannot cross a third of the screen between two events; a
      // jump that large is a coordinate glitch, not a turn.
      const r = stageEl.getBoundingClientRect();
      if (Math.abs(dx) + Math.abs(dy) > Math.min(r.width, r.height) / 3) return;
      player.yaw -= dx * 0.0055;
      player.pitch = clamp(player.pitch - dy * 0.0045, -0.85, 0.75);
      st.lookAt = null;
    }
  }
  function pointerUp(id, x, y, cancelled) {
    const p = pointers.get(id);
    pointers.delete(id);
    if (id === move.id) stopMove();
    if (!p || cancelled) return;
    if (p.moved < TAP_SLOP && performance.now() - p.t < 450) tap(x, y);
  }

  stageEl.addEventListener('pointerdown', (e) => {
    if (e.target.closest('button')) return;
    pointerDown(e.pointerId, e.clientX, e.clientY);
    try { stageEl.setPointerCapture(e.pointerId); } catch (_) { /* already released */ }
    e.preventDefault();
  });
  stageEl.addEventListener('pointermove', (e) => pointerMove(e.pointerId, e.clientX, e.clientY));
  const endPointer = (e) => pointerUp(e.pointerId, e.clientX, e.clientY, e.type === 'pointercancel');
  stageEl.addEventListener('pointerup', endPointer);
  stageEl.addEventListener('pointercancel', endPointer);

  // Host-forwarded touches: [[kind, id, x, y], ...] with kind d/m/u/c. A touch
  // that lands on a button presses that button instead of steering.
  const hostButtons = new Map();
  function hostInput(list) {
    for (const ev of list || []) {
      const [kind, raw, x, y] = ev;
      const id = `h${raw}`;
      if (kind === 'd') {
        const el = document.elementFromPoint(x, y);
        const b = el && el.closest('button');
        if (b) hostButtons.set(id, b); else pointerDown(id, x, y);
      } else if (kind === 'm') {
        if (!hostButtons.has(id)) pointerMove(id, x, y);
      } else {
        const b = hostButtons.get(id);
        if (b) {
          hostButtons.delete(id);
          if (kind === 'u') b.dispatchEvent(new PointerEvent('pointerup'));
        } else pointerUp(id, x, y, kind === 'c');
      }
    }
  }

  const ray = new T3.Raycaster(), ndc = new T3.Vector2();
  function pick(clientX, clientY) {
    if (!renderer) return null;
    const r = renderer.domElement.getBoundingClientRect();
    ndc.set(((clientX - r.left) / r.width) * 2 - 1, -((clientY - r.top) / r.height) * 2 + 1);
    return pickNdc(ndc);
  }
  function pickNdc(v) {
    ray.setFromCamera(v, camera);
    ray.far = 12;
    const hit = ray.intersectObjects(interactables, true)[0];
    if (!hit) return null;
    let o = hit.object; while (o && !(o.userData && o.userData.target)) o = o.parent;
    return o;
  }
  function tap(x, y) {
    if (st.mode === 'say') { advance(); return; }
    if (st.mode !== 'roam') return;
    const g = pick(x, y);
    if (g) interact(g);
  }
  $('#restart').addEventListener('pointerup', (e) => { e.stopPropagation(); start(); });

  addEventListener('keydown', (e) => {
    const k = e.key.toLowerCase();
    keys.add(k);
    if (k === ' ' || k === 'enter') {
      e.preventDefault();
      if (st.mode === 'say') advance();
      else if (st.mode === 'roam' && focused) interact(focused);
    }
    if (k === 'e' && st.mode === 'roam' && focused) interact(focused);
    if (st.mode === 'choice' && /^[1-9]$/.test(k)) { const b = choicesEl.children[+k - 1]; if (b) b.dispatchEvent(new PointerEvent('pointerup')); }
  });
  addEventListener('keyup', (e) => keys.delete(e.key.toLowerCase()));
  addEventListener('blur', () => keys.clear());

  // ── Movement and collision ─────────────────────────────────────────────────
  function collide() {
    const mx = room.w / 2 - BODY, mz = room.d / 2 - BODY;
    player.x = clamp(player.x, -mx, mx); player.z = clamp(player.z, -mz, mz);
    const solid = obstacles.concat([...chars.values()].map((o) => ({ x: o.g.position.x, z: o.g.position.z, r: 0.7 })));
    for (const o of solid) {
      const dx = player.x - o.x, dz = player.z - o.z, d = Math.hypot(dx, dz), min = o.r + BODY;
      if (d < min && d > 1e-4) { player.x = o.x + dx / d * min; player.z = o.z + dz / d * min; }
    }
  }

  function walk(dt) {
    let fx = -move.y, sx = move.x;
    if (keys.has('w') || keys.has('arrowup') || keys.has('ц')) fx += 1;
    if (keys.has('s') || keys.has('arrowdown') || keys.has('ы')) fx -= 1;
    if (keys.has('d') || keys.has('в')) sx += 1;
    if (keys.has('a') || keys.has('ф')) sx -= 1;
    if (keys.has('arrowleft')) { player.yaw += dt * 2; st.lookAt = null; }
    if (keys.has('arrowright')) { player.yaw -= dt * 2; st.lookAt = null; }
    const len = Math.hypot(fx, sx);
    if (len < 0.08) return;
    if (len > 1) { fx /= len; sx /= len; }
    const sy = Math.sin(player.yaw), cy = Math.cos(player.yaw);
    player.x += (-sy * fx + cy * sx) * SPEED * dt;
    player.z += (-cy * fx - sy * sx) * SPEED * dt;
    st.lookAt = null;
    collide();
  }

  function angleTo(a, b, k) {
    let d = b - a;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    return a + d * k;
  }

  // ── Frame loop ─────────────────────────────────────────────────────────────
  let focused = null, last = performance.now(), frame = 0;
  const center = new T3.Vector2(0, 0);
  let frameId = 0, stopped = false;
  function tick(t) {
    if (stopped) return;
    frameId = requestAnimationFrame(tick);
    const dt = Math.min(0.05, (t - last) / 1000); last = t; frame++;
    if (st.mode === 'roam') walk(dt);
    if (st.lookAt) {
      const dx = st.lookAt.x - player.x, dz = st.lookAt.z - player.z;
      const yaw = Math.atan2(-dx, -dz), pitch = Math.atan2(st.lookAt.y - EYE, Math.hypot(dx, dz));
      const k = reduce ? 1 : 1 - Math.pow(0.004, dt);
      player.yaw = angleTo(player.yaw, yaw, k); player.pitch += (pitch - player.pitch) * k;
    }
    camera.position.set(player.x, EYE + (st.mode === 'roam' && (Math.abs(move.x) + Math.abs(move.y) > 0.1) && !reduce ? Math.sin(t * 0.011) * 0.025 : 0), player.z);
    camera.rotation.set(player.pitch, player.yaw, 0);

    const typing = st.mode === 'say' && st.shown < st.full.length;
    const k2 = 1 - Math.pow(0.02, dt);
    chars.forEach((o) => {
      const p = o.g.position; p.x += (o.tx - p.x) * k2 * 0.6; p.z += (o.tz - p.z) * k2 * 0.6;
      o.g.rotation.y = Math.atan2(camera.position.x - p.x, camera.position.z - p.z);
      o.card.position.y = o.cy + (typing && st.speaking === o && !reduce ? Math.abs(Math.sin(t * 0.012)) * 0.03 : 0);
    });
    markers.forEach((m) => {
      const g = m.userData.owner;
      if (g.userData.target.kind === 'char') { m.position.x = g.position.x; m.position.z = g.position.z; }
      const near = Math.hypot(m.position.x - player.x, m.position.z - player.z) < 7;
      m.visible = st.mode === 'roam' && near && g !== focused;
      m.rotation.y = t * 0.002;
      if (!reduce) m.position.y = m.userData.baseY + Math.sin(t * 0.004) * 0.06;
    });

    if (st.mode === 'roam' && frame % 3 === 0) {
      const g = pickNdc(center);
      const t2 = g && g.userData.target;
      const d = g ? Math.hypot(g.position.x - player.x, g.position.z - player.z) : 99;
      focused = g && d <= REACH + (t2.wall ? 0.6 : 0) ? g : null;
      if (focused) {
        const verb = t2.kind === 'char' ? S.talk : t2.key ? S.examine : S.go;
        focusEl.textContent = `${verb}: ${t2.label}`; focusEl.hidden = false;
      } else focusEl.hidden = true;
      reticle.classList.toggle('hot', !!focused);
    }
    if (st.mode !== 'roam') { focusEl.hidden = true; reticle.classList.remove('hot'); }

    if (st.mode === 'say') {
      if (typing) st.shown = Math.min(st.full.length, st.shown + dt * 48);
      lineEl.textContent = st.full.slice(0, Math.floor(st.shown));
      moreEl.hidden = typing;
    }
    if (renderer) renderer.render(scene, camera);
  }

  // ── Entry ──────────────────────────────────────────────────────────────────
  let source = '';
  // A scene a new part of the story opens on, held until the current
  // dialogue has finished.
  let queuedEnter = null;
  // [saved] is a snapshot() from an earlier session of this game.
  function start(saved) {
    game = parse(source);
    st.flags = new Set(saved && Array.isArray(saved.flags) ? saved.flags : []);
    seen = new Set(saved && Array.isArray(saved.seen) ? saved.seen : []);
    log = saved && Array.isArray(saved.log) ? saved.log.slice(-60) : [];
    inv = saved && Array.isArray(saved.inv) ? saved.inv.slice() : [];
    backlog = saved && Array.isArray(saved.backlog) ? saved.backlog.slice(-BACKLOG_MAX) : [];
    pendingNext = (saved && saved.next) || null;
    queuedEnter = null; worldSig = ''; st.full = ''; endEl.hidden = true;
    if (!game.order.length) { disposeWorld(); setMode('idle'); toast(S.empty); renderHud(); return; }
    host('loaded', { scenes: game.order.length, skipped: game.skipped });
    if (saved && game.scenes[saved.scene]) enter(saved.scene, saved.pos ? { pos: saved.pos } : null);
    else enter(game.order[0]);
  }

  window.VN = Object.freeze({
    load(text, opts) {
      langKey = opts && opts.lang === 'en' ? 'en' : 'ru';
      S = STRINGS[langKey];
      $('#help').textContent = S.help;
      $('#endTitle').textContent = S.end;
      $('#restart').textContent = S.restart;
      source = String(text || '');
      parts = (opts && +opts.parts) || 0;
      if (!renderer) { toast(S.noWebgl); return; }
      resize();
      start(opts && opts.state);
    },
    // Swaps in a longer script without restarting: flags, `once` blocks and
    // the player's place are kept. [opts.enter] is the scene the new part
    // opens on; it starts once the current dialogue is over.
    extend(text, opts) {
      source = String(text || '');
      parts = (opts && +opts.parts) || parts;
      const here = st.scene && st.scene.id;
      game = parse(source);
      pendingNext = null;
      const to = opts && opts.enter;
      if (to && game.scenes[to]) {
        if (st.mode === 'roam' || st.mode === 'idle') enter(to); else queuedEnter = to;
      } else if (here && game.scenes[here]) {
        st.scene = game.scenes[here];
        if (world) refreshInteractables(handlersOf(st.scene, 0));
      }
      saveSoon();
    },
    input: hostInput,
    // { castId: { emotion: imageUrl } }; a set replaces that character's.
    sprites: addSprites,
    // The host gave up on writing the next part; a later `next` asks again.
    cancelNext() { pendingNext = null; saveSoon(); },
    snapshot,
    parse,
    // Stops the frame loop and hands the GPU context back before the host
    // destroys the WebView: a WebGL context torn down mid-frame can take the
    // shared renderer process with it.
    stop() {
      if (stopped) return;
      stopped = true;
      cancelAnimationFrame(frameId);
      setMode('idle');
      disposeWorld();
      if (renderer) {
        renderer.dispose();
        renderer.forceContextLoss();
        renderer.domElement.remove();
        renderer = null;
      }
    },
    // Interacts with the target whose key or label is [key], as a tap would,
    // ignoring distance. For keyboardless accessibility and automated runs.
    interactWith(key) {
      if (st.mode !== 'roam') return false;
      const g = interactables.find((x) => x.userData.target.keys.includes(key));
      if (!g) return false;
      const t = g.userData.target;
      if (t.key) run(st.handlers[t.key]); else if (t.link) enter(t.link);
      return true;
    },
    advance,
    choose(i) { const b = choicesEl.children[i]; if (b) b.dispatchEvent(new PointerEvent('pointerup')); },
    get state() {
      return { mode: st.mode, scene: st.scene && st.scene.id, flags: [...st.flags], player: Object.assign({}, player), focused: focused && focused.userData.target.label };
    },
  });

  resize();
  frameId = requestAnimationFrame(tick);
  host('ready');
})();
