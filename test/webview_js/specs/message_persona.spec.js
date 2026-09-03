// A user message records the persona it was sent as (`personaId` + the name),
// and the page renders that persona rather than whichever one is active now.
//
// The failure these protect against is a chat that rewrites its own history:
// switch persona and every message you ever sent suddenly claims to be from
// the new one — and, once a persona is deleted, wears a stranger's face while
// still carrying the right name.
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

test('a message keeps the avatar of the persona it was sent as', async ({
  page,
}) => {
  await boot(page);
  await activeIdentity(page, RED);
  await page.evaluate(
    ([blue]) => {
      window.bridge.setMessages(
        JSON.stringify([
          JSON.parse(
            window.__M('u1', 'user', 'hi', {
              displayName: 'Mara',
              personaId: 'p-mara',
              personaName: 'Mara',
              avatarUrl: blue,
            }),
          ),
        ]),
      );
    },
    [BLUE],
  );

  expect(await header(page, 'u1')).toEqual({
    name: 'Mara',
    src: BLUE,
    letter: null,
  });
});

test('switching persona does not repaint the messages already sent', async ({
  page,
}) => {
  await boot(page);
  await activeIdentity(page, RED);
  await page.evaluate(
    ([blue]) => {
      window.bridge.setMessages(
        JSON.stringify([
          JSON.parse(
            window.__M('u1', 'user', 'hi', {
              displayName: 'Mara',
              personaId: 'p-mara',
              personaName: 'Mara',
              avatarUrl: blue,
            }),
          ),
        ]),
      );
    },
    [BLUE],
  );

  // The reader switches to another persona, with another picture. Only the
  // active identity changed — the message was sent as Mara and stays hers.
  await activeIdentity(page, RED, 'Kai');

  expect(await header(page, 'u1')).toEqual({
    name: 'Mara',
    src: BLUE,
    letter: null,
  });
});

test('a deleted persona keeps its name and falls back to its letter', async ({
  page,
}) => {
  await boot(page);
  await activeIdentity(page, RED);
  // `avatarFallback` is what Dart sends when the stored `personaId` no longer
  // resolves — the persona was deleted, or never had a picture.
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([
        JSON.parse(
          window.__M('u1', 'user', 'hi', {
            displayName: 'Mara',
            personaId: 'p-mara',
            personaName: 'Mara',
            avatarFallback: true,
          }),
        ),
      ]),
    );
  });

  expect(await header(page, 'u1')).toEqual({
    name: 'Mara',
    src: null,
    letter: 'M',
  });

  // An identity push must not hand the deleted persona the active one's face.
  await activeIdentity(page, RED, 'Kai');

  expect(await header(page, 'u1')).toEqual({
    name: 'Mara',
    src: null,
    letter: 'M',
  });
});

test('a message with no stored persona still follows the active one', async ({
  page,
}) => {
  await boot(page);
  await activeIdentity(page, RED);
  await page.evaluate(() => {
    window.bridge.setMessages(
      JSON.stringify([JSON.parse(window.__M('u1', 'user', 'hi'))]),
    );
  });

  // Chats written before messages carried a persona: the active identity is
  // all there is to go on, and it must still reach them — the avatar on the
  // first render, and the name on the next identity push.
  expect(await header(page, 'u1')).toEqual({
    name: 'You',
    src: RED,
    letter: null,
  });

  await activeIdentity(page, RED);

  expect(await header(page, 'u1')).toEqual({
    name: 'Nyx',
    src: RED,
    letter: null,
  });
});
