// The typing placeholder is a virtual message: Flutter owns one constant id
// for it and the page draws it. Every bug in this file is the page keeping
// that bubble alive after Flutter has stopped believing in it — the reply,
// shown a second time under itself, in a chat that may not even be generating.
//
// These drive the real bridge in a real browser, because the failure is an
// ordering one: `updateMessage` is rAF-batched, so a delta issued before the
// placeholder was taken away executes after it.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';
const STREAMING_ID = '__streaming__';

async function boot(page) {
  await page.goto(PAGE);
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, role, text, extra = {}) =>
      JSON.stringify({
        id,
        role,
        text,
        timestamp: 1767225600000,
        isUser: role === 'user',
        isAssistant: role !== 'user',
        isSystem: false,
        displayName: role === 'user' ? 'You' : 'Alice',
        isError: false,
        isHidden: false,
        isGenerating: false,
        isPostGenRunning: false,
        ...extra,
      });
  });
}

/// Ids of every message section the browser actually laid out, in order.
const renderedIds = (page) =>
  page.evaluate(() =>
    [...document.querySelectorAll('.message-section')]
      .filter((el) => el.offsetHeight > 0)
      .map((el) => el.dataset.messageId),
  );

/// A chat with a greeting, the user's message and a reply streaming into the
/// placeholder — the state every case below starts from.
async function generating(page) {
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([JSON.parse(window.__M('a1', 'assistant', 'greeting'))]),
    );
    window.bridge.appendMessages(
      JSON.stringify([JSON.parse(window.__M('u1', 'user', 'hi'))]),
    );
    window.bridge.appendMessage(
      window.__M('__streaming__', 'assistant', 'the reply', { isTyping: true }),
    );
  });
  await page.waitForTimeout(60);
}

test('a delta that lands after the placeholder was taken away is dropped', async ({
  page,
}) => {
  await boot(page);
  await generating(page);

  // The run settles: the dispatcher removes the placeholder and the durable
  // reply is appended in its place.
  await page.evaluate(() => {
    window.bridge.removeMessage('__streaming__');
    window.bridge.appendMessages(
      JSON.stringify([JSON.parse(window.__M('a2', 'assistant', 'the reply'))]),
    );
  });
  await page.waitForTimeout(500);

  // A last delta for that run arrives afterwards. Re-creating the bubble here
  // is what showed the finished reply twice — and the copy survived, because
  // nothing removes a placeholder Flutter no longer knows about.
  await page.evaluate(() => {
    window.bridge.updateMessage(
      window.__M('__streaming__', 'assistant', 'the reply', { isTyping: true }),
    );
  });
  await page.waitForTimeout(300);

  expect(await renderedIds(page)).toEqual(['a1', 'u1', 'a2']);
});

test('a delta batched across the removal does not resurrect the bubble', async ({
  page,
}) => {
  await boot(page);
  await generating(page);

  // Same turn, tighter: the update is issued in the same tick as the removal,
  // so the batcher runs it while the exit animation is still on screen.
  await page.evaluate(() => {
    window.bridge.removeMessage('__streaming__');
    window.bridge.appendMessages(
      JSON.stringify([JSON.parse(window.__M('a2', 'assistant', 'the reply'))]),
    );
    window.bridge.updateMessage(
      window.__M('__streaming__', 'assistant', 'the reply', { isTyping: true }),
    );
  });
  await page.waitForTimeout(900);

  expect(await renderedIds(page)).toEqual(['a1', 'u1', 'a2']);
});

test('opening another chat does not carry the typing bubble into it', async ({
  page,
}) => {
  await boot(page);
  await generating(page);

  // Session switch: clearAll(false) + setMessages. The park-and-restore that
  // carries the placeholder across a re-render must not apply here.
  await page.evaluate(async () => {
    await window.bridge.clearAll(false);
    await window.bridge.setMessages(
      JSON.stringify([JSON.parse(window.__M('b1', 'assistant', 'other chat'))]),
    );
  });
  await page.waitForTimeout(200);

  expect(await renderedIds(page)).toEqual(['b1']);

  // And a delta still in flight for the chat that was left cannot put it back.
  await page.evaluate(() => {
    window.bridge.updateMessage(
      window.__M('__streaming__', 'assistant', 'the reply', { isTyping: true }),
    );
  });
  await page.waitForTimeout(300);
  expect(await renderedIds(page)).toEqual(['b1']);
});

test('a re-render of the same chat still carries the typing bubble', async ({
  page,
}) => {
  await boot(page);
  await generating(page);

  // The message-sync path: clearAll immediately followed by setMessages of the
  // same session. Dropping the placeholder here would leave every following
  // delta updating a node that is gone.
  await page.evaluate(async () => {
    await window.bridge.clearAll();
    await window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(window.__M('a1', 'assistant', 'greeting')),
        JSON.parse(window.__M('u1', 'user', 'hi')),
      ]),
    );
  });
  await page.waitForTimeout(200);

  expect(await renderedIds(page)).toEqual(['a1', 'u1', STREAMING_ID]);

  // And it is still the live bubble: the next delta reaches it.
  await page.evaluate(() => {
    window.bridge.updateMessage(
      window.__M('__streaming__', 'assistant', 'more text', { isTyping: true }),
    );
  });
  await page.waitForTimeout(200);
  const text = await page.evaluate(
    () =>
      document.querySelector('[data-message-id="__streaming__"]').dataset
        .rawText,
  );
  expect(text).toBe('more text');
});

test('a placeholder the list lost mid-run is still re-created', async ({
  page,
}) => {
  await boot(page);
  await generating(page);

  // The case the re-create branch exists for: the node is gone while the run
  // is still on. Dropping the delta here would stream the reply into nothing.
  await page.evaluate(() => {
    window.bridge.virtualList.remove('__streaming__');
    window.bridge.updateMessage(
      window.__M('__streaming__', 'assistant', 'the reply', { isTyping: true }),
    );
  });
  await page.waitForTimeout(200);

  expect(await renderedIds(page)).toEqual(['a1', 'u1', STREAMING_ID]);
});
