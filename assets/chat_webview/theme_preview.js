// The theme editor's live preview (theme_preview.html).
//
// Flutter sends the theme the way it sends it to the chat page — the same CSS
// variables, font, background, message layout and chrome sections — plus a
// few sample messages, through `window.__glazePreview.apply(json)`. Only the
// sections that changed are sent; the messages are drawn again whenever what
// shapes them (the messages, the layout, the theme's template) changes.

import { Formatter } from './formatter/index.js';
import { Renderer } from './renderer/message_renderer.js';
import { setMessageLayout } from './renderer/theme_layout.js';
import {
  BackgroundLayers,
  applyMessageSettingsClasses,
  applyThemeVars,
  setChatFont,
} from './bridge/page_theme.js';

const chrome = window.__glazeChrome || null;
// The chrome hands its keys out once per page; on this page they are ours.
const handshake = chrome ? chrome.handshake() : null;
const chromeKey = handshake ? handshake.split(':')[0] : null;

const root = document.documentElement;
const container = document.getElementById('chat-container');
const formatter = new Formatter();
const background = new BackgroundLayers();

// What the renderer reads off the chat page's bridge: avatars, and whether a
// reply is streaming.
window.bridge = { _charAvatarUrl: null, _personaAvatarUrl: null, isGenerating: false };

let messages = [];
let layout = null;
let chatLayout = null;

function render() {
  // The template goes first: a section is laid out as it is built.
  setMessageLayout(layout, []);
  // A fresh renderer each time, so the date separator is drawn again.
  const renderer = new Renderer(formatter, null);
  container.textContent = '';
  for (const m of messages) {
    for (const el of renderer.renderMessage(Object.assign({}, m))) {
      el.classList.remove('msg-appear');
      container.appendChild(el);
    }
  }
  container.scrollTop = container.scrollHeight;
}

function px(v) {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? `${Math.round(n)}px` : null;
}

function apply(json) {
  let msg;
  try {
    msg = JSON.parse(json);
  } catch (_) {
    return false;
  }
  if (!msg || typeof msg !== 'object') return false;
  let redraw = false;

  if (msg.theme) {
    applyThemeVars(msg.theme);
    if (msg.theme['chat-layout'] !== chatLayout) {
      chatLayout = msg.theme['chat-layout'];
      redraw = true;
    }
  }
  if (msg.font) {
    const f = msg.font;
    setChatFont(f.family || null, f.data || null, f.size, f.letterSpacing);
  }
  if (msg.background) {
    const b = msg.background;
    root.style.backgroundColor = typeof b.color === 'string' ? b.color : '';
    background.setImage(b.url || null, b.blur || 0);
    background.setNoise(b.noiseOpacity || 0, b.noiseIntensity);
  }
  if (msg.settings) applyMessageSettingsClasses(msg.settings);
  if (msg.identity) {
    window.bridge._charAvatarUrl = msg.identity.charAvatarUrl || null;
    window.bridge._personaAvatarUrl = msg.identity.personaAvatarUrl || null;
    redraw = true;
  }
  if ('layout' in msg) {
    layout = msg.layout && typeof msg.layout === 'object' ? msg.layout : null;
    redraw = true;
  }
  if (Array.isArray(msg.messages)) {
    messages = msg.messages;
    redraw = true;
  }
  if (msg.insets) {
    const top = px(msg.insets.top);
    const bottom = px(msg.insets.bottom);
    if (top) root.style.setProperty('--preview-top', top);
    if (bottom) root.style.setProperty('--preview-bottom', bottom);
    redraw = true;
  }
  if (msg.chrome && chromeKey) chrome.apply(chromeKey, JSON.stringify(msg.chrome));

  if (redraw) render();
  return true;
}

Object.defineProperty(window, '__glazePreview', {
  value: Object.freeze({ apply }),
  writable: false,
  configurable: false,
});
