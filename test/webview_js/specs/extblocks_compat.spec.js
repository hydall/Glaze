// Scripts written for the original ExtBlocks extension, run in the real
// script sandbox (`Bridge.runSandboxedScript`) with the real compatibility
// layer (`extblocks_compat.js`) and the real `window.glaze` SDK.
import { test, expect } from '@playwright/test';

const URL = '/test/webview_js/harness/plugins.html';

const scope = {
  messageId: 1,
  isUser: false,
  is_separate: false,
  blocks: [
    { name: 'stats', block_type: 'generated', disabled: false, injection_role: 0, injection_position: 1, injection_depth: 2 },
    { name: 'off', block_type: 'generated', disabled: true },
    { name: 'tidy', block_type: 'rewrite', disabled: false, generation_order: 'after' },
  ],
  allBlocks: [{ name: 'stats' }, { name: 'tidy' }],
  triggeredBlocks: [{ name: 'stats' }],
  additionalMacro: { fruit: 'apple' },
  currentSet: { name: 'Set', global_blocks: [] },
  name1: 'Ann',
  name2: 'Mira',
  chat: [
    { name: 'Ann', is_user: true, mes: 'Hi', extra: { extblocks: '<stats>\nhp 2\n</stats>' } },
    { name: 'Mira', is_user: false, mes: 'Hello </script><b>x</b>', extra: { extblocks: '<stats>\nhp 3\n</stats>' } },
  ],
};

/** Runs [script] in the sandbox; returns its result and every bridge call. */
async function run(page, script, extBlocks) {
  await page.goto(URL);
  return page.evaluate(async ({ script, extBlocks }) => {
    const load = async (p) => (await fetch('/assets/chat_webview/' + p)).text();
    window.__glazeSdkSource = await load('glaze_sdk.js');
    window.__extBlocksCompatSource = await load('extblocks_compat.js');
    const calls = [];
    // Stands in for the page's relay to Flutter.
    window.addEventListener('message', (e) => {
      const data = e.data || {};
      if (data.type !== 'glaze:request') return;
      calls.push({ method: data.method, params: data.params, context: data.context });
      e.source.postMessage({ type: 'glaze:response', id: data.id, ok: true, result: 'from ' + data.method }, '*');
    });
    const { Bridge } = await import('/assets/chat_webview/bridge/chat_bridge_controller.js');
    const context = { messages: [], sessionId: 's1', characterId: 'c1', extBlocks };
    const json = JSON.stringify(context).replace(/</g, '\\u003c');
    let result;
    try {
      result = await Bridge.prototype.runSandboxedScript.call({}, script, json);
    } catch (e) {
      result = 'error: ' + e.message;
    }
    return { result, calls };
  }, { script, extBlocks });
}

test('a script of the original finds its variables and services', async ({ page }) => {
  const { result } = await run(page, `
    return JSON.stringify({
      messageId, isUser, is_separate,
      all: allBlocks.map((b) => b.name),
      triggered: triggeredBlocks.map((b) => b.name),
      fruit: additionalMacro.fruit,
      chat: context.chat[messageId].mes,
      names: [context.name1, SillyTavern.getContext().name2],
      byType: BlockService.getBlocksByType(['rewrite']).map((b) => b.name),
      enabled: BlockService.getAllEnabledBlocks().map((b) => b.name),
      previous: ContextService.getPreviousBlockContextUnconditional({ name: 'stats' }, messageId, true, 2),
      setName: extStates.current_set.name,
      services: [typeof GenerationService.handleBlocksGeneration, typeof RewritePlugin.execute, typeof toastr.error],
    });
  `, scope);
  expect(JSON.parse(result)).toEqual({
    messageId: 1,
    isUser: false,
    is_separate: false,
    all: ['stats', 'tidy'],
    triggered: ['stats'],
    fruit: 'apple',
    chat: 'Hello </script><b>x</b>',
    names: ['Ann', 'Mira'],
    byType: ['tidy'],
    enabled: ['stats', 'tidy'],
    previous: '<stats>\nhp 2\n</stats>\n\n<stats>\nhp 3\n</stats>',
    setName: 'Set',
    services: ['function', 'function', 'function'],
  });
});

test('the original\'s services reach the app through glaze.extBlocks*', async ({ page }) => {
  const { result, calls } = await run(page, `
    const blocks = BlockService.getAllBlocks();
    await GenerationService.handleBlocksGeneration(messageId, isUser, blocks, blocks.filter((b) => b.name === 'stats'), { k: 'v' });
    const text = await GeneratedPlugin.generateBlockContent([blocks[0]], 0, blocks);
    await RewritePlugin.execute(blocks, { generation_order: 'after', messageId });
    await BlockService.addBlocksToExtra(99, '<stats>new</stats>');
    await BlockService.injectBlock('<stats>s</stats>', blocks[0]);
    toastr.error('bad', 'Title');
    return text;
  `, scope);
  expect(result).toBe('from extBlocksGenerate');
  const byMethod = calls.map((c) => [c.method, c.params]);
  expect(byMethod).toEqual([
    ['extBlocksRun', { messageId: 1, blocks: ['stats'], additionalMacro: { k: 'v' }, parallel: false }],
    ['extBlocksGenerate', { messageId: 0, blocks: ['stats'], additionalMacro: {} }],
    ['extBlocksRewrite', { messageId: 1, blocks: ['tidy'], additionalMacro: {}, rewriteTarget: null, apply: true }],
    // Clamped into the chat, as the original does.
    ['extBlocksStore', { messageId: 1, text: '<stats>new</stats>' }],
    ['injectPrompt', { id: '[ExtBlocks] stats', content: '<stats>s</stats>', options: { depth: 2, role: 'system' } }],
    ['showToast', { message: 'Title: bad', options: { severity: 'error' } }],
  ]);
  // The chat itself does not ride along with every call.
  expect(calls[0].context).toEqual({ sessionId: 's1', characterId: 'c1', extBlocks: true });
});

test('STscript fails plainly, and a plain script keeps the strict sandbox', async ({ page }) => {
  const st = await run(page, `await executeST('/echo hi');`, scope);
  expect(st.result).toBe('error: STscript is not supported in Glaze; only JavaScript runs.');

  const plain = await run(page, `
    return [typeof BlockService, typeof messageId, (function () { return this === undefined; })()].join();
  `, undefined);
  expect(plain.result).toBe('undefined,undefined,true');
});
