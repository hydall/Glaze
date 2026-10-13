// Compatibility with Tavo plugins: defines `tavo.*` (and the global
// `triggerSlash`) on top of `glaze.*`. Loaded after plugin_sdk.js only for
// packages converted from Tavo's `.tpg` format.
(function () {
  'use strict';
  var g = window.glaze;
  if (!g) return;

  function missing(name) {
    return function () { return Promise.reject(new Error(name + ' is not available to this plugin')); };
  }
  function fn(ns, name) { return ns && typeof ns[name] === 'function' ? ns[name] : missing(name); }
  function idOf(v) { return v && typeof v === 'object' ? v.id : v; }
  function pick(obj, map) {
    var out = {};
    Object.keys(map).forEach(function (k) {
      var src = map[k];
      for (var i = 0; i < src.length; i++) {
        if (obj && obj[src[i]] !== undefined) { out[k] = obj[src[i]]; break; }
      }
    });
    return out;
  }

  /* ---------- Shapes ---------- */
  var ROLE_IN = { assistant: 'assistant', user: 'user', system: 'system' };
  function message(m) {
    if (!m) return m;
    var out = { id: m.id, content: m.content, hidden: !!m.hidden, role: ROLE_IN[m.role] || m.role };
    if (m.characterId != null) out.characterId = m.characterId;
    if (m.reasoning) out.reasoning = m.reasoning;
    return out;
  }
  function messages(list) { return Array.isArray(list) ? list.map(message) : list; }

  function character(c) {
    if (!c) return c;
    return {
      id: c.id, avatar: c.avatar, name: c.name, description: c.description,
      firstMes: c.firstMessage, personality: c.personality, scenario: c.scenario,
      mesExample: c.exampleMessages, creatorNotes: c.creatorNotes, systemPrompt: c.systemPrompt,
      postHistoryInstructions: c.postHistoryInstructions, alternateGreetings: c.alternateGreetings || [],
      tags: c.tags || [], creator: c.creator, characterVersion: c.version, nickname: c.macroName,
      groupOnlyGreetings: [], creationDate: c.createdAt ? new Date(c.createdAt) : null,
      modificationDate: c.updatedAt ? new Date(c.updatedAt) : null,
    };
  }
  function characterIn(c) {
    var src = c && c.data && typeof c.data === 'object' ? Object.assign({}, c.data, { id: c.id }) : (c || {});
    return pick(src, {
      id: ['id'], name: ['name'], description: ['description'], personality: ['personality'],
      scenario: ['scenario'], firstMessage: ['firstMes', 'first_mes'], exampleMessages: ['mesExample', 'mes_example'],
      creatorNotes: ['creatorNotes', 'creator_notes'], systemPrompt: ['systemPrompt', 'system_prompt'],
      postHistoryInstructions: ['postHistoryInstructions', 'post_history_instructions'],
      alternateGreetings: ['alternateGreetings', 'alternate_greetings'], tags: ['tags'],
      creator: ['creator'], version: ['characterVersion', 'character_version'], macroName: ['nickname'],
    });
  }

  function persona(p) {
    if (!p) return p;
    return { id: p.id, name: p.name, description: p.description, avatar: p.avatar, active: !!p.active };
  }

  function chat(c) {
    if (!c) return c;
    return {
      id: c.id, name: c.name, characters: c.characters || [], persona: c.persona || null,
      preset: c.preset || null, lorebooks: c.lorebooks || [], regexes: [], background: null,
      theme: null, responseMode: 'natural', allowSelfResponses: false, overrideScenario: '',
    };
  }

  function presetOut(p) {
    if (!p) return p;
    return {
      id: p.id, name: p.name, basicPrompts: {},
      entries: (p.blocks || []).map(function (b) {
        return {
          identifier: b.id, name: b.name, content: b.content, enabled: b.enabled !== false, active: true,
          type: 'custom', role: b.role || 'system',
          injectionPosition: b.insertionMode === 'depth' ? 'absolute' : 'relative',
          injectionDepth: b.depth == null ? 4 : b.depth,
        };
      }),
    };
  }
  function presetIn(p) {
    if (!p) return p;
    var out = { id: p.id, name: p.name };
    if (Array.isArray(p.entries)) {
      out.blocks = p.entries.map(function (e) {
        return {
          id: e.identifier || e.id || String(Math.random()).slice(2), name: e.name || e.identifier || 'Entry',
          role: e.role || 'system', content: e.content || '', enabled: e.enabled !== false,
          insertionMode: e.injectionPosition === 'absolute' ? 'depth' : 'relative',
          depth: e.injectionPosition === 'absolute' ? (e.injectionDepth == null ? 4 : e.injectionDepth) : null,
        };
      });
    }
    return out;
  }

  function lorebookOut(b) {
    if (!b) return b;
    return {
      id: b.id, name: b.name,
      entries: (b.entries || []).map(function (e) {
        return {
          identifier: e.id, name: e.comment, content: e.content, enabled: e.enabled !== false,
          strategy: e.constant ? 'constant' : 'keyword', keywords: e.keys || [],
          secondaryKeywords: e.secondaryKeys || [], scanDepth: e.scanDepth == null ? 2 : e.scanDepth,
          caseSensitive: !!e.caseSensitive, matchWholeWord: !!e.matchWholeWords,
          probability: e.probability == null ? 100 : e.probability,
          sticky: e.sticky || 0, cooldown: e.cooldown || 0, delay: e.delay || 0,
        };
      }),
    };
  }
  function lorebookIn(b) {
    if (!b) return b;
    var out = { id: b.id, name: b.name };
    if (Array.isArray(b.entries)) {
      out.entries = b.entries.map(function (e) {
        return {
          id: e.identifier, comment: e.name || '', content: e.content || '', enabled: e.enabled !== false,
          constant: e.strategy === 'constant' || e.constant === true,
          keys: e.keywords || e.keys || [], secondaryKeys: e.secondaryKeywords || e.secondary_keys || [],
          scanDepth: e.scanDepth, caseSensitive: e.caseSensitive, matchWholeWords: e.matchWholeWord,
          probability: e.probability == null ? 100 : e.probability,
          sticky: e.sticky || 0, cooldown: e.cooldown || 0, delay: e.delay || 0,
        };
      });
    }
    return out;
  }

  var PLACEMENT = { user: 1, char: 2 };
  function regexEntry(r) {
    return {
      name: r.name, findRegex: r.regex, replaceString: r.replacement,
      trimStrings: r.trimOut ? String(r.trimOut).split('\n') : [],
      placements: (r.placement || []).map(function (p) { return p === 1 ? 'user' : 'char'; }),
      timing: 'sendAndDisplay', substitution: 'none',
      minDepth: r.minDepth == null ? null : r.minDepth, maxDepth: r.maxDepth == null ? null : r.maxDepth,
      enabled: !r.disabled,
    };
  }
  function regexOut(r) { return r && { id: r.id, name: r.name, entries: [regexEntry(r)] }; }
  function regexRuleIn(setName, e, single) {
    return {
      name: single ? setName : (setName + ' / ' + (e.name || 'rule')),
      regex: e.findRegex || '', replacement: e.replaceString || '',
      trimOut: Array.isArray(e.trimStrings) ? e.trimStrings.join('\n') : '',
      placement: (e.placements || ['char']).map(function (p) { return PLACEMENT[p] || 2; }),
      disabled: e.enabled === false,
      minDepth: e.minDepth == null ? null : e.minDepth, maxDepth: e.maxDepth == null ? null : e.maxDepth,
    };
  }

  /* ---------- Variables ---------- */
  function scopeIn(scope) { return scope == null ? 'chat' : scope; }
  var V = g.variables || {};
  var variable = {
    list: function (scope) { return fn(V, 'list')(scopeIn(scope)); },
    get: function (name, scope) { return fn(V, 'get')(name, scopeIn(scope)); },
    set: function (name, value, scope) { return fn(V, 'set')(name, value, scopeIn(scope)); },
    update: function (name, value, scope) { return fn(V, 'update')(name, value, scopeIn(scope)); },
    unset: function (name, scope) { return fn(V, 'delete')(name, scopeIn(scope)); },
  };
  function legacyScope(scope) {
    if (scope === 'message') return { scope: 'message' };
    return scope;
  }
  var legacy = {
    get: function (name, scope) { return V.peek ? V.peek(name, scope) : undefined; },
    set: function (name, value, scope) { variable.set(name, value, legacyScope(scope)).catch(function () {}); },
    update: function (name, value, scope) { variable.update(name, value, legacyScope(scope)).catch(function () {}); },
    unset: function (name, scope) { variable.unset(name, legacyScope(scope)).catch(function () {}); },
  };

  /* ---------- Namespaces ---------- */
  var M = g.messages || {}, MV = M.variants || {};
  var message = {
    find: function (range, filter) {
      filter = filter || {};
      return fn(M, 'list')(range, { role: filter.role, hidden: filter.hidden }).then(messages);
    },
    get: function (ref) { return fn(M, 'get')(ref).then(message); },
    current: function () { return fn(M, 'current')().then(message); },
    count: function () { return fn(M, 'count')(); },
    append: function (m) {
      m = m || {};
      return fn(M, 'add')({ content: m.content, role: m.role === 'user' ? 'user' : 'assistant', hidden: !!m.hidden });
    },
    update: function (m) {
      m = m || {};
      var data = { id: m.id, content: m.content, hidden: m.hidden === true };
      if (m.reasoning !== undefined) data.reasoning = m.reasoning;
      return fn(M, 'edit')(data);
    },
    'delete': function (id) { return fn(M, 'remove')(idOf(id)); },
    variant: {
      list: function (id) { return fn(MV, 'list')(id); },
      create: function (id, v, o) { return fn(MV, 'add')(id, v, o); },
      update: function (id, v) { return fn(MV, 'edit')(id, v); },
      'delete': function (id, vid) { return fn(MV, 'remove')(id, vid); },
      select: function (id, vid) { return fn(MV, 'select')(id, vid); },
    },
  };

  var C = g.chats || {};
  var chatApi = {
    current: function () { return fn(C, 'current')().then(chat); },
    get: function (id) { return fn(C, 'get')(id).then(chat); },
    find: function (name, options) {
      options = options || {};
      return fn(C, 'find')({ name: name == null ? undefined : name, match: options.match,
        characterId: options.characters && options.characters[0] }).then(function (list) {
        return Array.isArray(list) ? list.map(function (c) { return chat({ id: c.id, name: c.name }); }) : list;
      });
    },
    create: function (c) {
      c = c || {};
      return fn(C, 'create')({ characterId: idOf((c.characters || [])[0]), name: c.name });
    },
    update: function (c) {
      c = c || {};
      var data = { id: c.id };
      ['name', 'persona', 'preset', 'lorebooks'].forEach(function (k) { if (c[k] !== undefined) data[k] = c[k]; });
      return fn(C, 'update')(data);
    },
    open: function (id) { return fn(C, 'open')(id); },
    copy: function (id) { return fn(C, 'copy')(id); },
    'delete': function (id) { return fn(C, 'remove')(id); },
    inspectImport: function (path) {
      return fn(C, 'inspectImport')(path).then(function (r) {
        return r && { messageCount: r.messageCount, characters: [], personas: r.userName ? [r.userName] : [] };
      });
    },
    'import': function (path, options) {
      options = options || {};
      return fn(C, 'import')(path, { characterId: options.character });
    },
    'export': function (id) { return fn(C, 'export')(id); },
  };

  var CH = g.characters || {};
  var characterApi = {
    all: function () { return fn(CH, 'list')(); },
    get: function (id) { return fn(CH, 'get')(idOf(id)).then(character); },
    find: function (name, o) { return fn(CH, 'find')(name, o).then(function (l) { return (l || []).map(character); }); },
    create: function (c) { return fn(CH, 'create')(characterIn(c)); },
    update: function (c) { return fn(CH, 'update')(characterIn(c)); },
    'import': function (src) {
      return fn(CH, 'import')(src).then(function (r) {
        return r && { characterId: r.characterId, lorebookId: r.lorebookId || null, regexId: null };
      });
    },
    'export': function (id, o) { return fn(CH, 'export')(idOf(id), o || { format: 'json' }); },
    'delete': function (id) { return fn(CH, 'remove')(idOf(id)); },
  };

  var PE = g.personas || {};
  var personaApi = {
    all: function () { return fn(PE, 'list')(); },
    get: function (id) { return fn(PE, 'get')(idOf(id)).then(persona); },
    find: function (n, o) { return fn(PE, 'find')(n, o).then(function (l) { return (l || []).map(persona); }); },
    create: function (p) { return fn(PE, 'create')(p); },
    update: function (p) { return fn(PE, 'update')(p); },
    'delete': function (id) { return fn(PE, 'remove')(idOf(id)); },
    current: function () { return fn(PE, 'current')().then(persona); },
  };

  var PR = g.presets || {};
  var presetApi = {
    all: function () { return fn(PR, 'list')(); },
    get: function (id) { return fn(PR, 'get')(idOf(id)).then(presetOut); },
    find: function (n, o) { return fn(PR, 'find')(n, o).then(function (l) { return (l || []).map(presetOut); }); },
    'import': function (src) { return fn(PR, 'import')(src); },
    'export': function (id, o) { return fn(PR, 'export')(idOf(id), o); },
    create: function (p) { return fn(PR, 'create')(presetIn(p)); },
    update: function (p) { return fn(PR, 'update')(presetIn(p)); },
    'delete': function (id) { return fn(PR, 'remove')(idOf(id)); },
  };

  var L = g.lorebooks || {};
  var lorebookApi = {
    all: function () {
      return fn(L, 'list')().then(function (l) {
        return (l || []).map(function (b) { return { id: b.id, name: b.name, entries: b.entryCount }; });
      });
    },
    get: function (id) { return fn(L, 'get')(idOf(id)).then(lorebookOut); },
    find: function (n, o) { return fn(L, 'find')(n, o).then(function (l) { return (l || []).map(lorebookOut); }); },
    'import': function (src) { return fn(L, 'import')(src); },
    'export': function (id, o) { return fn(L, 'export')(idOf(id), o); },
    create: function (b) { return fn(L, 'create')(lorebookIn(b)); },
    update: function (b) { return fn(L, 'update')(lorebookIn(b)); },
    'delete': function (id) { return fn(L, 'remove')(idOf(id)); },
  };

  var R = g.regex || {};
  var regexApi = {
    all: function () {
      return fn(R, 'list')().then(function (l) {
        return (l || []).map(function (r) { return { id: r.id, name: r.name, entries: 1 }; });
      });
    },
    get: function (id) { return fn(R, 'get')(idOf(id)).then(regexOut); },
    find: function (n, o) { return fn(R, 'find')(n, o).then(function (l) { return (l || []).map(regexOut); }); },
    'import': function (src) {
      return fn(R, 'import')(src).then(function (ids) { return Array.isArray(ids) ? ids[0] : ids; });
    },
    'export': function (id, o) { return fn(R, 'export')(idOf(id), o); },
    create: async function (set) {
      set = set || {};
      var entries = Array.isArray(set.entries) && set.entries.length ? set.entries : [{}];
      var first = null;
      for (var i = 0; i < entries.length; i++) {
        var id = await fn(R, 'create')(regexRuleIn(set.name || 'Regex', entries[i], entries.length === 1));
        if (first == null) first = id;
      }
      return first;
    },
    update: function (set) {
      set = set || {};
      var e = (set.entries || [])[0] || {};
      return fn(R, 'update')(Object.assign({ id: set.id }, regexRuleIn(set.name, e, true)));
    },
    'delete': function (id) { return fn(R, 'remove')(idOf(id)); },
  };

  var MEM = g.memory || {};
  var memoryApi = {
    current: function () {
      return fn(MEM, 'get')().then(function (m) {
        return m && { id: null, enabled: m.enabled, memories: (m.entries || []).map(function (e) { return e.content; }) };
      });
    },
    update: function (m) {
      m = m || {};
      var data = {};
      if (typeof m.enabled === 'boolean') data.enabled = m.enabled;
      if (Array.isArray(m.memories)) data.entries = m.memories;
      return fn(MEM, 'update')(data);
    },
    append: function (list) {
      return fn(MEM, 'append')(list).then(function (r) {
        return r && { appendedCount: (r.added || []).length, totalCount: r.total, enabled: r.enabled };
      });
    },
  };

  var T = g.themes || {}, TA = T.assets || {}, F = g.files || {};
  var themeApi = {
    all: function () { return fn(T, 'list')(); },
    get: function (id) { return fn(T, 'get')(idOf(id)); },
    find: function (n, o) { return fn(T, 'find')(n, o); },
    create: function (t) { return fn(T, 'create')(t); },
    update: function (t) { return fn(T, 'update')(t); },
    'import': function (src) { return fn(T, 'import')(src); },
    'export': function (id, o) { return fn(T, 'export')(idOf(id), o); },
    'delete': function (id) { return fn(T, 'remove')(idOf(id)); },
    assets: {
      list: function (themeId) { return fn(TA, 'list')(idOf(themeId)); },
      'import': async function (themeId, path) {
        var data = await fn(F, 'load')(path, { encoding: 'base64' });
        return fn(TA, 'save')(idOf(themeId), String(path).split('/').pop(), data, { encoding: 'base64' });
      },
      'export': async function (themeId, name) {
        var data = await fn(TA, 'load')(idOf(themeId), name, { encoding: 'base64' });
        if (data == null) return null;
        return fn(F, 'save')(name, data, { encoding: 'base64' });
      },
      rename: function (themeId, name, newName) { return fn(TA, 'rename')(idOf(themeId), name, newName); },
      'delete': function (themeId, name) { return fn(TA, 'remove')(idOf(themeId), name); },
    },
  };

  var file = {
    list: function (o) { return fn(F, 'list')(o); },
    'import': function (o) { return fn(F, 'pick')(o); },
    save: function (n, c, o) { return fn(F, 'save')(n, c, o); },
    load: function (n, o) { return fn(F, 'load')(n, o); },
    'delete': function (n, o) { return fn(F, 'remove')(n, o); },
    exists: function (n, o) { return fn(F, 'exists')(n, o); },
    url: function (n, s) { return F.url ? F.url(n, s) : 'files/' + (s || 'chat') + '/' + n; },
    'export': function (n, c, o) { return fn(F, 'share')(n, c, o); },
  };

  var CO = g.composer || {};
  var input = {
    get: function () { return fn(CO, 'get')(); },
    set: function (t) { return fn(CO, 'set')(t); },
    append: function (t) { return fn(CO, 'append')(t); },
    clear: function () { return fn(CO, 'clear')(); },
    send: function () { return fn(CO, 'send')(); },
  };

  var U = g.ui || {};
  var utils = {
    toast: function (t) { return fn(U, 'toast')(t); },
    openUrl: function (u) { return fn(U, 'openUrl')(u); },
    'export': function (name, data) {
      var encoding = /^data:/.test(String(data)) ? 'dataUrl' : 'base64';
      return fn(F, 'share')(name, data, { encoding: encoding }).catch(function () {
        return fn(F, 'share')(name, data, { encoding: 'utf8' });
      });
    },
    preview: function (src) {
      if (src && typeof src === 'object' && src.src) src = src.currentSrc || src.src;
      if (typeof src !== 'string' || !src) throw new Error('preview needs an image source');
      fn(U, 'preview')(src).catch(function (e) { console.warn('[tavo] preview', e); });
    },
    ask: function (o) { return fn(U, 'ask')(o); },
    select: function (options, title, def) { return fn(U, 'select')(options, title, def); },
  };

  /* ---------- Plugin namespace ---------- */
  var EVENT_IN = { 'input:beforeSend': 'send:before', 'input:afterSend': 'send:after' };
  var EVENT_OUT = { 'send:before': 'input:beforeSend', 'send:after': 'input:afterSend' };
  var SOURCE_OUT = { plugin: 'tavojs' };

  function wrapEvent(handler, tavoType) {
    return function (e) {
      var props = { type: { value: tavoType || EVENT_OUT[e.type] || e.type, enumerable: true } };
      if (e.source && SOURCE_OUT[e.source]) props.source = { value: SOURCE_OUT[e.source], enumerable: true };
      if (e.message) props.message = { value: message(e.message), enumerable: true };
      if (e.chat) props.chat = { value: chat(e.chat), enumerable: true };
      return handler(Object.create(e, props));
    };
  }

  var GP = g.plugin;
  function on(type, handler) {
    if (typeof type !== 'string') throw new Error('Unsupported plugin event: ' + type);
    var m = /^(inputActions|sidebar|lastMessageActions):(.+)$/.exec(type);
    if (m) {
      var where = { inputActions: 'composer', sidebar: 'tools', lastMessageActions: 'message' }[m[1]];
      return GP.on('action:' + where + ':' + m[2], handler);
    }
    return GP.on(EVENT_IN[type] || type, wrapEvent(handler, type === 'chat:changed' ? 'chat:updated' : null));
  }

  var pluginNs = {
    pluginId: GP.id,
    fragmentId: GP.panelId,
    on: on,
    emit: GP.emit,
    onInputAction: function (id, h) { return GP.onComposerAction(id, h); },
    onSidebarAction: function (id, h) { return GP.onToolsAction(id, h); },
    onLastMessageAction: function (id, h) { return GP.onMessageAction(id, h); },
    registerFileProcessor: function (id, p) { return GP.registerFileHandler(id, p); },
    config: GP.settings,
  };
  if (GP.i18n) pluginNs.i18n = GP.i18n;

  var tavo = {
    variable: Object.freeze(variable),
    get: legacy.get, set: legacy.set, update: legacy.update, unset: legacy.unset,
    message: message, chat: chatApi, character: characterApi, persona: personaApi,
    preset: presetApi, lorebook: lorebookApi, regex: regexApi, memory: memoryApi,
    theme: themeApi, file: file, input: input, utils: utils,
    generate: function (prompt, options) { return (g.generate || missing('generate'))(prompt, options); },
    image: { generate: function (p, o) { return fn(g.images, 'generate')(p, o); } },
    tts: {
      // Glaze has no text-to-speech for plugins.
      play: function () { return Promise.resolve(false); },
      stop: function () { return Promise.resolve(); },
    },
    app: { version: fn(g.app, 'version'), versionNumber: fn(g.app, 'versionNumber') },
    plugin: Object.freeze(pluginNs),
    ui: Object.freeze({ getInsets: g.ui.insets, onInsetsChanged: g.ui.onInsetsChanged }),
  };
  tavo.v1 = Object.freeze(legacy);
  tavo = Object.freeze(tavo);
  try {
    Object.defineProperty(window, 'tavo', { value: tavo, writable: false, configurable: false });
  } catch (e) { window.tavo = tavo; }
  window.triggerSlash = function (command) { return fn(g.commands, 'run')(command); };

  // Tavo panels read these inset variables.
  var applyVars = function (i) {
    var root = document.documentElement;
    if (!root) return;
    root.style.setProperty('--tavo-inset-top-safe', i.topSafe + 'px');
    root.style.setProperty('--tavo-inset-top-bar', i.topBar + 'px');
    root.style.setProperty('--tavo-inset-bottom-input', i.bottomInput + 'px');
    root.style.setProperty('--tavo-inset-bottom-safe', i.bottomSafe + 'px');
  };
  applyVars(g.ui.insets());
  g.ui.onInsetsChanged(applyVars);
})();
