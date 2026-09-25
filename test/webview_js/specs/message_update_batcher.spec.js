// The end of a generation enqueues several message updates in one frame. The
// batch used to run bare, so the first update that threw aborted the loop and
// silently dropped every later message in the batch. One bad message must not
// cost the others their render.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

test('a throwing update does not drop the rest of the batch', async ({
  page,
}) => {
  const errors = [];
  page.on('console', (msg) => {
    if (msg.type() === 'error') errors.push(msg.text());
  });
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);

  const ran = await page.evaluate(async () => {
    const { MessageUpdateBatcher } = await import(
      '/assets/chat_webview/bridge/message_update_batcher.js'
    );
    const batcher = new MessageUpdateBatcher();
    const order = [];
    batcher.enqueue('a', () => {
      throw new Error('boom');
    });
    batcher.enqueue('b', () => order.push('b'));
    batcher.enqueue('c', () => order.push('c'));
    batcher.flush();
    return order;
  });

  expect(ran).toEqual(['b', 'c']);
  expect(errors.some((line) => line.includes('Message update failed'))).toBe(
    true,
  );
});
