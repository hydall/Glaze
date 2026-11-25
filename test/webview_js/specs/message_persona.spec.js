// Every user message wears the persona the chat speaks as now. Switching
// persona must re-face the messages already on screen at once — name and
// avatar — without waiting for a re-render.
import { test, expect } from '@playwright/test';

const PAGE = '/assets/chat_webview/index.html';

// 1x1 transparent PNGs — the renderer only ever sets `src`, so the bytes are
// irrelevant; what matters is which of the two ends up on the message.
const RED =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const BLUE =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

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

/// The identity Flutter pushes: the character Alice, and the persona the
/// reader is writing as right now — "Nyx" with the red avatar unless the test
/// switches to somebody else.
async function activeIdentity(page, personaAvatarUrl, personaName = 'Nyx') {
  await page.evaluate(
    ([url, name]) => {
      window.bridge.setIdentity({
        charName: 'Alice',
        personaName: name,
        charAvatarUrl: null,
        personaAvatarUrl: url,
      });
    },
    [personaAvatarUrl, personaName],
  );
}

/// What the header of message [id] shows: its name and its avatar, where a
/// null `src` means the letter fallback was drawn instead of an image.
const header = (page, id) =>
  page.evaluate((messageId) => {
    const section = document.querySelector(
      `.message-section[data-message-id="${messageId}"]`,
    );
    const avatar = section.querySelector('.msg-avatar');
    const img = avatar.querySelector('img');
    return {
      name: section.querySelector('.msg-name-label').textContent,
      src: img ? img.getAttribute('src') : null,
      letter: img ? null : avatar.textContent,
    };
  }, id);

test('a user message renders with the active persona', async ({ page }) => {
  await boot(page);
  await activeIdentity(page, RED);
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(window.__M('u1', 'user', 'hi', { displayName: 'Nyx' })),
      ]),
    );
  });

  expect(await header(page, 'u1')).toEqual({
    name: 'Nyx',
    src: RED,
    letter: null,
  });
});

test('switching persona re-faces the messages already sent', async ({
  page,
}) => {
  await boot(page);
  await activeIdentity(page, RED);
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(window.__M('u1', 'user', 'hi', { displayName: 'Nyx' })),
        JSON.parse(window.__M('a1', 'assistant', 'hello')),
      ]),
    );
  });

  await activeIdentity(page, BLUE, 'Kai');

  expect(await header(page, 'u1')).toEqual({
    name: 'Kai',
    src: BLUE,
    letter: null,
  });
  // The character's side is untouched by a persona switch.
  expect((await header(page, 'a1')).name).toBe('Alice');
});

test('a persona with no avatar shows its letter after the switch', async ({
  page,
}) => {
  await boot(page);
  await activeIdentity(page, RED);
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(window.__M('u1', 'user', 'hi', { displayName: 'Nyx' })),
      ]),
    );
  });

  await activeIdentity(page, null, 'Kai');

  expect(await header(page, 'u1')).toEqual({
    name: 'Kai',
    src: null,
    letter: 'K',
  });
});
