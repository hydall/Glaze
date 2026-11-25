// The ext-block card and the interactive panel of a block that draws a
// picture (issue #839): the card pages through the block's images, a running
// block offers nothing a second tap could hit by mistake, and a block shown as
// a panel replaces its panel on every run instead of stacking frames.
import { test, expect } from '@playwright/test';

const URL = '/test/webview_js/harness/plugins.html';

const element = (variants, index) =>
  `<img data-iig-instruction='{"prompt":"a cat"}' data-iig-variants='${variants.join(';;')}' data-iig-index='${index}' src="${variants[index]}">`;

/** Renders the panel under message m1 with [blocks]; returns the sent calls. */
async function showPanel(page, blocks) {
  await page.goto(URL);
  await page.evaluate(async (blocks) => {
    const { Bridge } = await import('/assets/chat_webview/bridge/chat_bridge_controller.js');
    const { InteractionDispatch } = await import('/assets/chat_webview/bridge/interaction_dispatch.js');
    // The harness covers the page with a stand-in chat that takes every tap.
    document.getElementById('chat-container')?.remove();
    const section = document.createElement('div');
    section.dataset.messageId = 'm1';
    section.innerHTML = '<div class="msg-content"></div>';
    document.body.appendChild(section);

    window.__sent = [];
    const bridge = Object.create(Bridge.prototype);
    bridge.renderer = { allowExternalMedia: true };
    bridge._sendToFlutter = (name, args) => window.__sent.push({ name, args });
    bridge._selectionManager = { handleClick: () => false };
    const dispatch = new InteractionDispatch(bridge);
    document.addEventListener('click', (e) => dispatch.handleClick(e));
    window.__bridge = bridge;
    bridge.showExtBlocksPanel(JSON.stringify({ messageId: 'm1', blocks }));
  }, blocks);
}

const sent = (page) => page.evaluate(() => window.__sent);

test('a card picture with several images pages through them and reports the choice', async ({ page }) => {
  const content = `<p>scene</p>${element(['http://127.0.0.1:1/a.png', 'http://127.0.0.1:1/b.png', 'http://127.0.0.1:1/c.png'], 2)}`;
  await showPanel(page, [{ id: 'row1', blockId: 'comic', blockName: 'Comic', status: 'done', content }]);

  const wrapper = page.locator('.ext-block-image-wrapper');
  await expect(wrapper.locator('.ext-block-variant-count')).toHaveText('3/3');
  await expect(wrapper.locator('img.ext-block-image')).toHaveAttribute('src', 'http://127.0.0.1:1/c.png');

  await wrapper.locator('[data-action="ext-block-img-variant-prev"]').click();
  await expect(wrapper.locator('.ext-block-variant-count')).toHaveText('2/3');
  await expect(wrapper.locator('img.ext-block-image')).toHaveAttribute('src', 'http://127.0.0.1:1/b.png');
  await expect(wrapper.locator('.img-download-btn')).toHaveAttribute('data-src', 'http://127.0.0.1:1/b.png');

  // The last image is a hard edge, like a message swipe.
  await wrapper.locator('[data-action="ext-block-img-variant-next"]').click();
  await wrapper.locator('[data-action="ext-block-img-variant-next"]').click();
  await expect(wrapper.locator('.ext-block-variant-count')).toHaveText('3/3');

  const variants = (await sent(page)).filter((c) => c.name === 'onExtBlockImgVariant');
  expect(variants.map((c) => JSON.parse(c.args[0]))).toEqual([
    { blockId: 'comic', messageId: 'm1', imgIndex: 0, variantIndex: 1 },
    { blockId: 'comic', messageId: 'm1', imgIndex: 0, variantIndex: 2 },
  ]);
});

test('the switcher reports the picture by its place among the block images', async ({ page }) => {
  const content = `[IMG:ERROR:{"error":"boom"}] ${element(['http://127.0.0.1:1/a.png', 'http://127.0.0.1:1/b.png'], 1)}`;
  await showPanel(page, [{ id: 'row1', blockId: 'comic', blockName: 'Comic', status: 'done', content }]);
  await expect(page.locator('.ext-block-image-error')).toHaveCount(1);
  await page.locator('[data-action="ext-block-img-variant-prev"]').click();
  const variants = (await sent(page)).filter((c) => c.name === 'onExtBlockImgVariant');
  expect(JSON.parse(variants[0].args[0])).toMatchObject({ imgIndex: 1, variantIndex: 0 });
});

test('a single image keeps the plain card picture', async ({ page }) => {
  await showPanel(page, [{
    id: 'row1', blockId: 'comic', blockName: 'Comic', status: 'done',
    content: element(['http://127.0.0.1:1/a.png'], 0),
  }]);
  await expect(page.locator('img.ext-block-image')).toHaveCount(1);
  await expect(page.locator('.ext-block-variants')).toHaveCount(0);
});

test('a redraw tap disables the button so a second tap sends nothing', async ({ page }) => {
  await showPanel(page, [{
    id: 'row1', blockId: 'comic', blockName: 'Comic', status: 'done',
    content: element(['http://127.0.0.1:1/a.png'], 0),
  }]);
  const regen = page.locator('[data-action="ext-block-regen-image"]');
  await regen.click();
  await expect(regen).toBeDisabled();
  await regen.click({ force: true });
  const taps = (await sent(page)).filter((c) => c.name === 'onExtBlockRegenImage');
  expect(taps).toHaveLength(1);
});

test('a running block shows Stop alone, so Delete never slides under the finger', async ({ page }) => {
  await showPanel(page, [{ id: 'row1', blockId: 'comic', blockName: 'Comic', status: 'running', content: '[IMG:GEN]' }]);
  const actions = await page.locator('.ext-block-actions .ext-block-btn').evaluateAll(
    (buttons) => buttons.map((b) => b.dataset.action));
  expect(actions).toEqual(['ext-block-stop']);
});

test('a keyed panel replaces the panel an earlier run left', async ({ page }) => {
  await page.goto(URL);
  const result = await page.evaluate(async () => {
    window.__glazeSdkSource = '';
    const { PanelHost } = await import('/assets/chat_webview/bridge/panel_host.js');
    const section = document.createElement('div');
    section.dataset.messageId = 'm1';
    document.body.appendChild(section);
    const host = new PanelHost({ _sendToFlutter: () => {}, _callGlazeBridge: async () => null });
    const key = JSON.stringify({ key: 'ext-block:comic' });
    host.open('m1', '<p>one</p>', key);
    host.open('m1', '<p>two</p>', key);
    const last = host.open('m1', '<p>three</p>', key);
    host.open('m1', '<p>other</p>', JSON.stringify({ key: 'ext-block:other' }));
    host.open('m1', '<p>unkeyed</p>', '{}');
    return {
      count: section.querySelectorAll('.interactive-panel').length,
      kept: !!section.querySelector(`.interactive-panel[data-panel-id="${last}"]`),
      keyed: section.querySelectorAll('.interactive-panel[data-panel-key="ext-block:comic"]').length,
    };
  });
  expect(result).toEqual({ count: 3, kept: true, keyed: 1 });
});
