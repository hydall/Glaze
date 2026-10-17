// The scope a script block written for the original ExtBlocks extension
// expects, rebuilt inside Glaze's script sandbox.
//
// The original runs a script with `eval` inside its own module, so the code
// sees the extension's variables and services and SillyTavern's `context`.
// Dart hands the data over as `context.extBlocks` (see
// `ext_blocks_script_scope.dart`); this file is run with that `context` and
// returns the names the script is called with. Work that needs the app
// (generating, rewriting, storing block states) goes through the
// `glaze.extBlocks*` methods, under the preset's "run blocks" permission.
'use strict';

var eb = context.extBlocks || {};
var glaze = window.glaze;
var PREFIX = '[ExtBlocks]';
var ROLES = ['system', 'user', 'assistant'];

// Every bridge call carries the context it was made in; the chat need not
// ride along with each one. `extBlocks` stays as a mark (see glaze_sdk.js).
var slim = {};
Object.keys(context).forEach(function (key) {
  if (key !== 'extBlocks' && key !== 'messages') slim[key] = context[key];
});
slim.extBlocks = true;
window.__glazeContext = slim;

// SillyTavern's context: the chat in its shape, the two names.
context.chat = eb.chat || [];
context.name1 = eb.name1;
context.name2 = eb.name2;
context.chatMetadata = context.chatMetadata || {};
context.generateRaw = function (options) {
  var prompt = typeof options === 'string' ? options : (options && options.prompt) || '';
  return glaze.generateText(String(prompt));
};
context.generateQuietPrompt = function (options) {
  var prompt = typeof options === 'string' ? options : (options && options.quietPrompt) || '';
  return glaze.generateText(String(prompt));
};
// Glaze saves and redraws the chat on its own.
context.saveChat = function () { return Promise.resolve(); };
context.saveChatDebounced = function () {};
context.reloadCurrentChat = function () { return Promise.resolve(); };

function bridge(method, params) {
  return glaze[method](params || {});
}

function blockNames(blocks) {
  var list = Array.isArray(blocks) ? blocks : [blocks];
  return list
    .filter(Boolean)
    .map(function (b) { return typeof b === 'string' ? b : b.name; })
    .filter(function (n) { return typeof n === 'string' && n.length > 0; });
}

function messageIndex(id) {
  var n = Number(id);
  if (!isFinite(n)) n = context.chat.length - 1;
  return Math.max(0, Math.min(Math.trunc(n), context.chat.length - 1));
}

// `checkAttributesInBlockName` / `getBlockFromMessage` of the original.
function tagNames(name) {
  if (name.indexOf('=') === -1) return { upper: name, bottom: name };
  var bottom = name.substring(0, name.indexOf('=')).trim().split(/\s+/).slice(0, -1).join(' ');
  return { upper: name, bottom: bottom };
}

function getBlockFromMessage(message, name) {
  if (!message) return '';
  var names = tagNames(name);
  var open = '<' + names.upper;
  var close = '</' + names.bottom + '>';
  var start = message.indexOf(open);
  while (start !== -1) {
    var next = message[start + open.length];
    if (next === '>' || next === ' ' || next === '\t' || next === '\n' || next === '\r') {
      var tagEnd = message.indexOf('>', start);
      var end = tagEnd === -1 ? -1 : message.indexOf(close, tagEnd);
      if (end !== -1) return message.substring(start, end + close.length);
    }
    start = message.indexOf(open, start + 1);
  }
  return '';
}

var ContextService = {
  getPreviousBlockContextUnconditional: function (block, messageId, mayCurrent, count) {
    var found = [];
    if (count === undefined || count < 1) count = 1;
    var start = Number(messageId) - (mayCurrent ? 0 : 1);
    for (var i = start; i >= 0 && found.length < count; i--) {
      var message = context.chat[i];
      var stored = message && message.extra && message.extra.extblocks;
      if (!stored) continue;
      var content = getBlockFromMessage(stored, block.name);
      if (content !== '') found.push(content);
    }
    return found.reverse().join('\n\n');
  },
};

var BlockService = {
  getAllBlocks: function () { return (eb.blocks || []).slice(); },
  getAllEnabledBlocks: function () {
    return (eb.blocks || []).filter(function (b) { return !b.disabled; });
  },
  getBlocksByType: function (types, enabledOnly) {
    var wanted = Array.isArray(types) ? types : [types];
    var blocks = enabledOnly ? BlockService.getAllEnabledBlocks() : BlockService.getAllBlocks();
    return blocks.filter(function (b) { return wanted.indexOf(b.block_type) !== -1; });
  },
  getAllPreviousBlocks: function () {
    return BlockService.getAllEnabledBlocks()
      .map(function (b) {
        return ContextService.getPreviousBlockContextUnconditional(b, context.chat.length - 1, true).trim();
      })
      .join('\n\n');
  },
  injectBlock: function (block, blockConfig) {
    var id = PREFIX + ' ' + blockConfig.name;
    if (!block) return glaze.uninjectPrompt(id).catch(function () {});
    return glaze.injectPrompt(id, String(block), {
      depth: blockConfig.injection_position === 1 ? Number(blockConfig.injection_depth) || 0 : 0,
      role: ROLES[blockConfig.injection_role] || 'system',
    });
  },
  addBlocksToExtra: function (messageId, blocksStr) {
    return bridge('extBlocksStore', { messageId: messageIndex(messageId), text: String(blocksStr || '') });
  },
  purgeBlocksExtra: function (messageId) {
    return bridge('extBlocksStore', { messageId: messageIndex(messageId), purge: true });
  },
  // Glaze redraws messages and panels itself.
  updateBlocksDisplay: function () { return Promise.resolve(); },
  updateDisplayForBlocks: function () { return Promise.resolve(); },
  selfReloadCurrentChat: function () { return Promise.resolve(); },
};

function runBlocks(blocks, options) {
  var names = blockNames(blocks);
  if (names.length === 0) return Promise.resolve();
  options = options || {};
  return bridge('extBlocksRun', {
    messageId: messageIndex(options.messageId),
    blocks: names,
    additionalMacro: options.additionalMacro || {},
    parallel: !!options.parallel,
  });
}

function isType(type) {
  return function (b) { return b && b.block_type === type; };
}

var ScriptPlugin = {
  execute: async function (blocks, options) {
    options = options || {};
    var list = (blocks || []).filter(function (b) {
      return !options.execution_order || b.execution_order === options.execution_order;
    });
    for (var i = 0; i < list.length; i++) {
      var block = list[i];
      if (block.script_type === 'js') {
        await runScript(block.script, options);
      } else {
        await executeST(block.script);
      }
    }
  },
};

var GeneratedPlugin = {
  execute: function (blocks, options) { return runBlocks(blocks, options); },
  generateBlockContent: function (blocksInGroup, messageId, allBlocks, additionalMacro) {
    return bridge('extBlocksGenerate', {
      messageId: messageIndex(messageId),
      blocks: blockNames(blocksInGroup),
      additionalMacro: additionalMacro || {},
    });
  },
};

var RewritePlugin = {
  generateRewrite: function (rewriteBlock, messageId, allBlocks, additionalMacro) {
    return bridge('extBlocksRewrite', {
      messageId: messageIndex(messageId),
      blocks: blockNames(rewriteBlock),
      additionalMacro: additionalMacro || {},
      apply: false,
    });
  },
  execute: function (blocks, options) {
    options = options || {};
    var list = (blocks || []).filter(function (b) {
      return !options.generation_order || b.generation_order === options.generation_order;
    });
    if (list.length === 0) return Promise.resolve();
    return bridge('extBlocksRewrite', {
      messageId: messageIndex(options.messageId),
      blocks: blockNames(list),
      additionalMacro: options.additionalMacro || {},
      rewriteTarget: options.rewriteTarget || null,
      apply: true,
    });
  },
};

var AccumulationPlugin = {
  execute: function (blocks, options) { return runBlocks(blocks, options); },
};

var GenerationService = {
  handleBlocksGeneration: async function (messageId, isUser, allBlocks, triggeredBlocks, additionalMacro, is_separate, parallel) {
    var triggered = triggeredBlocks || [];
    var scripts = triggered.filter(isType('script'));
    var options = { messageId: messageId, additionalMacro: additionalMacro || {}, parallel: !!parallel };
    await ScriptPlugin.execute(scripts, Object.assign({}, options, { execution_order: 'before' }));
    await runBlocks(triggered.filter(function (b) { return !isType('script')(b); }), options);
    await ScriptPlugin.execute(scripts, Object.assign({}, options, { execution_order: 'after' }));
  },
};

var ApiService = {
  abortGeneration: function () { return bridge('extBlocksAbort', {}); },
};

var extStates = {
  ExtBlocks_settings: { extblocks_is_enabled: true },
  current_set: eb.currentSet || null,
  api_preset: null,
  spoilerRegex: null,
  self_reload_flag: false,
  is_chat_modified: false,
};

function executeST() {
  return Promise.reject(new Error('STscript is not supported in Glaze; only JavaScript runs.'));
}

function toast(severity) {
  return function (message, title) {
    var text = title ? title + ': ' + message : message;
    glaze.showToast(String(text), { severity: severity }).catch(function () {});
  };
}

var toastr = {
  success: toast('success'),
  info: toast('info'),
  warning: toast('warning'),
  error: toast('error'),
  clear: function () {},
};

var SillyTavern = { getContext: function () { return context; } };

var scope = {
  context: context,
  messageId: eb.messageId,
  isUser: !!eb.isUser,
  allBlocks: eb.allBlocks || [],
  triggeredBlocks: eb.triggeredBlocks || [],
  additionalMacro: eb.additionalMacro || {},
  is_separate: false,
  BlockService: BlockService,
  ContextService: ContextService,
  GenerationService: GenerationService,
  GeneratedPlugin: GeneratedPlugin,
  RewritePlugin: RewritePlugin,
  ScriptPlugin: ScriptPlugin,
  AccumulationPlugin: AccumulationPlugin,
  ApiService: ApiService,
  extStates: extStates,
  executeST: executeST,
  toastr: toastr,
  SillyTavern: SillyTavern,
};

// Runs [code] the way the original's `executeJS` does: an async body with
// the scope's names in reach, not in strict mode. A nested script takes the
// options it was started with as its own variables.
function runScript(code, options) {
  var own = Object.assign({}, scope);
  if (options) {
    if (options.messageId !== undefined) own.messageId = options.messageId;
    if (options.additionalMacro) own.additionalMacro = options.additionalMacro;
  }
  var names = Object.keys(own);
  var body = 'return (async function () {\n' + code + '\n})();';
  var fn = Function.apply(null, names.concat([body]));
  return fn.apply(null, names.map(function (n) { return own[n]; }));
}

scope.__run = runScript;
return scope;
