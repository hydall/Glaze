// A theme's own message layout: its template lays out the pieces the renderer
// builds (header, avatar, name, time, guidance, content, footer) and shows the
// message's data around them, and its stylesheet styles the lot. See
// chrome/template.js for what a template may contain, and
// docs/THEME_LAYOUTS.md for the pieces and the data.
//
// The renderer always builds the usual section first; the template only moves
// its pieces. Whatever the template leaves out waits in a hidden holder, so
// every in-place update (a new swipe, the token count, an identity change)
// still finds the element it updates, and dropping the template puts each
// piece back where it was.

import { compile, arrange, sanitizeCss } from '../chrome/template.js';
import { formatDate, formatDateDisplay, formatTime, roleKey } from './message_template.js';

const STYLE_ID = 'glaze-theme-layout';
const BASE_CSS = `
g-part { display: contents; }
.g-unplaced { display: none !important; }
.layout-themed .gc-icon { display: inline-flex; align-items: center; justify-content: center; flex: none; line-height: 0; }
.layout-themed .gc-icon svg { display: block; }
.layout-themed .gc-icon-mask { display: block; background-color: currentColor; -webkit-mask-size: contain; mask-size: contain; -webkit-mask-repeat: no-repeat; mask-repeat: no-repeat; -webkit-mask-position: center; mask-position: center; }
.layout-themed .gc-icon-img { display: block; object-fit: contain; }
`;

let template = null;
// The theme's stylesheet for what a message draws inside its shadow root:
// code blocks, headings, quotes. A closed boundary otherwise.
let contentCss = '';

const CONTENT_STYLE_ID = 'glaze-theme-content';

/**
 * Puts [contentCss] into [host]'s shadow root (or takes it out when empty).
 * Called for every content host the renderer makes, and for every one on
 * screen when the theme changes.
 */
export function applyContentStyle(host) {
  const shadow = host && host.shadowRoot;
  if (!shadow) return;
  let style = shadow.getElementById ? shadow.getElementById(CONTENT_STYLE_ID) : null;
  if (!style) {
    for (const child of shadow.children) {
      if (child.id === CONTENT_STYLE_ID) { style = child; break; }
    }
  }
  if (!contentCss) {
    if (style) style.remove();
    return;
  }
  if (!style) {
    style = document.createElement('style');
    style.id = CONTENT_STYLE_ID;
    shadow.appendChild(style);
  }
  if (style.textContent !== contentCss) style.textContent = contentCss;
}

/** The pieces of a rendered section a template may place. */
function piecesOf(section) {
  const header = section.querySelector('.msg-header');
  const stack = section.querySelector('.msg-content-stack');
  return {
    header,
    avatar: header && header.querySelector('.msg-avatar'),
    name: header && header.querySelector('.msg-name'),
    time: header && header.querySelector('.msg-time'),
    guidance: section.querySelector('.msg-guidance-block'),
    content: stack,
    footer: stack && stack.querySelector('.msg-footer'),
  };
}

/** What a message template sees. [m] is the message map the bridge renders. */
export function messageData(m, identity, name) {
  const role = roleKey(m.role);
  const pinned = !!(m.avatarUrl || m.avatarFallback);
  const avatarUrl = m.avatarUrl || (pinned ? null : (role === 'user'
    ? identity && identity._personaAvatarUrl
    : role === 'char' ? identity && identity._charAvatarUrl : null)) || '';
  const day = m.timestamp ? formatDate(m.timestamp) : null;
  return {
    id: m.id || '',
    role,
    isUser: role === 'user',
    isChar: role === 'char',
    isSystem: role === 'system',
    name,
    initial: (name || '?').charAt(0).toUpperCase(),
    avatarUrl,
    avatarColor: m.avatarColor || '',
    persona: m.personaName || '',
    text: m.text || '',
    reasoning: m.reasoning || '',
    timestamp: m.timestamp || 0,
    time: m.timestamp ? formatTime(m.timestamp) : '',
    date: day ? formatDateDisplay(day) : '',
    index: m.messageIndex != null ? m.messageIndex + 1 : null,
    swipe: {
      index: (m.swipeIndex || 0) + 1,
      total: m.swipeTotal || 1,
    },
    greeting: {
      index: (m.greetingIndex || 0) + 1,
      total: m.greetingTotal || 1,
    },
    agentSwipe: {
      index: (m.agentSwipeIndex || 0) + 1,
      total: m.agentSwipeTotal || 1,
    },
    tokens: m.tokens || 0,
    genTime: m.genTime && m.genTime !== '0s' ? m.genTime : '',
    model: m.modelVersion || '',
    isLast: !!m.isLast,
    isError: !!m.isError,
    isHidden: !!m.isHidden,
    isTyping: !!m.isTyping,
    editing: !!m.isEditing,
  };
}

// Fields of a message map that change what a template shows, by the name the
// template knows them under.
function patchData(data, msg) {
  const has = (k) => Object.prototype.hasOwnProperty.call(msg, k);
  if (has('text')) data.text = msg.text || '';
  if (has('reasoning')) data.reasoning = msg.reasoning || '';
  if (has('messageIndex') && msg.messageIndex != null) data.index = msg.messageIndex + 1;
  if (has('swipeIndex') || has('swipeTotal')) {
    data.swipe = {
      index: has('swipeIndex') ? (msg.swipeIndex || 0) + 1 : data.swipe.index,
      total: has('swipeTotal') ? msg.swipeTotal || 1 : data.swipe.total,
    };
  }
  if (has('isEditing')) data.editing = !!msg.isEditing;
  if (has('greetingIndex') || has('greetingTotal')) {
    data.greeting = {
      index: has('greetingIndex') ? (msg.greetingIndex || 0) + 1 : data.greeting.index,
      total: has('greetingTotal') ? msg.greetingTotal || 1 : data.greeting.total,
    };
  }
  if (has('agentSwipeIndex') || has('agentSwipeTotal')) {
    data.agentSwipe = {
      index: has('agentSwipeIndex') ? (msg.agentSwipeIndex || 0) + 1 : data.agentSwipe.index,
      total: has('agentSwipeTotal') ? msg.agentSwipeTotal || 1 : data.agentSwipe.total,
    };
  }
  if (has('tokens')) data.tokens = msg.tokens || 0;
  if (has('genTime')) data.genTime = msg.genTime && msg.genTime !== '0s' ? msg.genTime : '';
  if (has('modelVersion')) data.model = msg.modelVersion || '';
  if (has('isLast')) data.isLast = !!msg.isLast;
  if (has('isError')) data.isError = !!msg.isError;
  if (has('isHidden')) data.isHidden = !!msg.isHidden;
  if (has('isTyping')) data.isTyping = !!msg.isTyping;
  if (has('name')) {
    data.name = msg.name || '';
    data.initial = (data.name || '?').charAt(0).toUpperCase();
  }
  if (has('avatarUrl')) data.avatarUrl = msg.avatarUrl || '';
}

function actionHook(section) {
  // A g-action is one of the message actions the page already handles by
  // `data-action` (see bridge/interaction_dispatch.js), on this message.
  return (el, name) => {
    el.setAttribute('data-action', name);
    el.setAttribute('data-message-id', section.dataset.messageId || '');
  };
}

/** Lays [section] out with the current template, if there is one. */
export function applyMessageLayout(section, data) {
  section.__glazeData = data;
  if (!template) return;
  const pieces = piecesOf(section);
  const holder = document.createElement('div');
  holder.className = 'g-unplaced';
  // The view goes where the header was; context markers stay first and last.
  section.insertBefore(holder, pieces.header ? pieces.header.nextSibling : null);
  const homes = { avatar: pieces.header, name: pieces.header, time: pieces.header, footer: pieces.content };
  section.__glazeView = arrange(template, data, section, pieces, holder, { action: actionHook(section) }, homes);
  section.__glazePieces = pieces;
  section.__glazeHolder = holder;
}

/** Takes [section] back to the renderer's own layout. */
function restore(section) {
  const view = section.__glazeView;
  if (!view) return;
  view.destroy();
  const p = section.__glazePieces;
  const holder = section.__glazeHolder;
  if (p.header) {
    for (const k of ['avatar', 'name', 'time']) if (p[k]) p.header.appendChild(p[k]);
    section.insertBefore(p.header, holder);
  }
  if (p.guidance) section.insertBefore(p.guidance, holder);
  if (p.content) {
    section.insertBefore(p.content, holder);
    if (p.footer) p.content.appendChild(p.footer);
  }
  holder.remove();
  section.__glazeView = null;
  section.__glazePieces = null;
  section.__glazeHolder = null;
}

/** Brings what [section]'s template shows up to date with [msg]. */
export function refreshMessageLayout(section, msg) {
  if (!section || !section.__glazeData) return;
  patchData(section.__glazeData, msg);
  if (section.__glazeView) section.__glazeView.update(section.__glazeData);
}

/**
 * Sets the theme's message template and stylesheet. Returns the template's
 * problems, if any. [sections] are re-laid out in place.
 */
export function setMessageLayout(layout, sections) {
  const src = layout && typeof layout.message === 'string' ? layout.message : '';
  const compiled = src ? compile(src) : null;
  const next = compiled && !compiled.empty ? compiled : null;

  let style = document.getElementById(STYLE_ID);
  const sheet = layout && typeof layout.css === 'string' ? sanitizeCss(layout.css) : '';
  const nextContentCss =
    layout && typeof layout.contentCss === 'string' ? sanitizeCss(layout.contentCss) : '';
  if (next || sheet) {
    if (!style) {
      style = document.createElement('style');
      style.id = STYLE_ID;
      document.head.appendChild(style);
    }
    style.textContent = BASE_CSS + sheet;
  } else if (style) {
    style.remove();
  }

  const container = document.getElementById('chat-container');
  if (container) container.classList.toggle('layout-themed', !!next);

  template = next;
  contentCss = nextContentCss;
  for (const section of sections) {
    if (!section || !section.querySelectorAll) continue;
    for (const host of section.querySelectorAll('.message-content')) applyContentStyle(host);
  }
  for (const section of sections) {
    if (!section || !section.classList || !section.classList.contains('message-section')) continue;
    restore(section);
    section.classList.toggle('layout-themed', !!next);
    if (next && section.__glazeData) applyMessageLayout(section, section.__glazeData);
  }
  return compiled ? compiled.errors : [];
}

export function hasMessageLayout() {
  return !!template;
}
