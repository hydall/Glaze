// The chat chrome's stylesheet. It lives inside the chrome's closed shadow
// root, so nothing a message writes can match these elements, and every value
// it reads is a `--gc-*` property the chrome sets on its own root from the
// theme Flutter sends — inherited custom properties from the page are always
// shadowed. Metrics mirror the Flutter widgets they replaced: GlazeAppBar /
// ChatHeader, ChatInputBar and ChatDrawerPanel.

export const CHROME_CSS = `
:host { all: initial; }
.gc, .gc * { box-sizing: border-box; margin: 0; padding: 0; }
.gc {
  position: fixed; inset: 0; pointer-events: none; overflow: hidden;
  font-family: var(--gc-font); color: var(--gc-text);
  -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
  /* Flutter never picks an optical size by itself; the page would, and a
     variable font with an opsz axis (Inter) would set narrower than it. */
  font-optical-sizing: none; font-kerning: normal;
  -webkit-text-size-adjust: none; text-size-adjust: none;
  -webkit-tap-highlight-color: transparent; -webkit-touch-callout: none;
  user-select: none; -webkit-user-select: none;
  font-size: 14px; line-height: normal; letter-spacing: normal;
  direction: ltr; text-align: left; white-space: normal;
}
:where(.gc button) {
  font: inherit; color: inherit; background: none; border: 0; outline: none;
  cursor: pointer; -webkit-appearance: none; appearance: none;
}
:where(.gc textarea, .gc input) {
  font: inherit; color: inherit; background: transparent; border: 0;
  outline: none; resize: none; -webkit-appearance: none; appearance: none;
  user-select: text; -webkit-user-select: text; pointer-events: auto;
  caret-color: var(--gc-accent); width: 100%; display: block;
}
.gc textarea::placeholder, .gc input::placeholder { opacity: 1; }
.gc-hidden { display: none !important; }
.gc-live { pointer-events: auto; }
.gc-click { cursor: pointer; }

/* ---------- Shared pieces ---------- */
.gc-icon { display: inline-flex; align-items: center; justify-content: center; flex: none; line-height: 0; }
.gc-icon svg { display: block; }
.gc-icon-mask { display: block; background-color: currentColor; -webkit-mask-size: contain; mask-size: contain;
  -webkit-mask-repeat: no-repeat; mask-repeat: no-repeat; -webkit-mask-position: center; mask-position: center; }
.gc-icon-img { display: block; object-fit: contain; }
.gc-glyph-text { font-weight: 700; letter-spacing: -1px; line-height: 1; white-space: nowrap; }

.gc-glass {
  position: relative; overflow: hidden; isolation: isolate;
  background-color: var(--gc-fill, transparent);
  -webkit-backdrop-filter: var(--gc-backdrop, none); backdrop-filter: var(--gc-backdrop, none);
}
.gc-glass::after {
  content: ''; position: absolute; inset: 0; border-radius: inherit; pointer-events: none; z-index: 3;
  box-shadow: inset 0 0 0 var(--gc-bw, 0px) var(--gc-bc, transparent);
}
.gc-noise { position: absolute; inset: 0; z-index: 0; pointer-events: none; display: none;
  background-repeat: repeat; image-rendering: pixelated; border-radius: inherit; }
.gc-glass-content { position: relative; z-index: 1; }
.gc-glow-layer { position: absolute; inset: 0; z-index: 2; pointer-events: none; overflow: hidden; border-radius: inherit; }
.gc-glow { position: absolute; border-radius: 50%; pointer-events: none; will-change: transform, opacity;
  background: radial-gradient(circle closest-side, var(--gc-glow-color) 0%, transparent 70%);
  filter: blur(10px); }
.gc-glow { --gc-glow-color: rgba(0,0,0,0); }

/* Material IconButton: 48px target, a soft state layer while pressed. */
.gc-iconbtn { position: relative; display: flex; align-items: center; justify-content: center;
  width: 48px; height: 48px; flex: none; color: var(--gc-accent); pointer-events: auto; }
.gc-iconbtn::before { content: ''; position: absolute; width: 40px; height: 40px; border-radius: 50%;
  background: currentColor; opacity: 0; transition: opacity 120ms; }
.gc-iconbtn:hover::before { opacity: 0.08; }
.gc-iconbtn:active::before { opacity: 0.1; }
.gc-iconbtn[disabled] { color: var(--gc-disabled) !important; cursor: default; }
.gc-iconbtn[disabled]::before { opacity: 0 !important; }

.gc-tooltip { position: absolute; z-index: 50; pointer-events: none; opacity: 0; transition: opacity 150ms;
  max-width: 280px; padding: 4px 8px; border-radius: 4px; font-size: 12px; line-height: 1.35;
  color: var(--gc-tip-text); background: var(--gc-tip-bg); white-space: normal; }

/* ---------- Fades ---------- */
.gc-fade-top, .gc-fade-bottom { position: absolute; left: 0; right: 0; pointer-events: none; }
.gc-fade-top { top: 0; background: linear-gradient(to bottom, rgba(0,0,0,0.541), rgba(0,0,0,0)); }
.gc-fade-bottom { bottom: 0; background: linear-gradient(to top, rgba(0,0,0,0.541), rgba(0,0,0,0)); }

/* ---------- Header ---------- */
.gc-hdr-slot { position: absolute; top: 0; left: 0; right: 0; }
.gc-hdr { height: 56px; pointer-events: auto; --gc-fill: var(--gc-fill-header);
  transition: transform 300ms cubic-bezier(0.215, 0.61, 0.355, 1), opacity 300ms cubic-bezier(0.215, 0.61, 0.355, 1); }
.gc-hdr > .gc-glass-content { display: flex; align-items: center; height: 56px; }
.gc-hdr-lead { width: 52px; height: 56px; display: flex; align-items: center; justify-content: center; flex: none; }
.gc-hdr-lead .gc-iconbtn { width: 52px; }
.gc-hdr-title { flex: 1 1 0; min-width: 0; height: 56px; display: flex; align-items: center; }
.gc-hdr-actions { display: flex; align-items: center; padding-right: 4px; flex: none; }
.gc-char { display: flex; align-items: center; min-width: 0; flex: 1 1 0; }
.gc-char.gc-hug { flex: 0 1 auto; }
.gc-avatar { flex: none; display: flex; align-items: center; justify-content: center; overflow: hidden;
  background-size: cover; background-position: center; font-weight: 700; cursor: pointer; }
.gc-char-texts { min-width: 0; margin-left: 10px; cursor: pointer; display: flex; flex-direction: column; flex: 1 1 0; }
.gc-char.gc-hug .gc-char-texts { flex: 0 1 auto; }
.gc-char-name { font-weight: 600; line-height: 1.1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--gc-text); }
.gc-char-session { margin-top: 2px; font-weight: 400; line-height: 1.1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--gc-text2); }
.gc-hdr-searchfield { flex: 1 1 0; min-width: 0; display: flex; align-items: center; height: 40px;
  border-radius: calc(12px * var(--gc-corner, 1)); background: var(--gc-surface-high);
  box-shadow: inset 0 0 0 1px var(--gc-outline); }
/* The app's input theme stays on the field: filled, outlined, the accent
   outline while it has the focus. */
.gc-hdr-searchfield:focus-within { box-shadow: inset 0 0 0 2px var(--gc-accent); }
.gc-hdr-searchfield input { font-size: 16px; line-height: 1.5; color: var(--gc-on); padding: 8px 16px; height: 40px; }
.gc-hdr-searchfield input::placeholder { color: var(--gc-onvar-50); }
.gc-hdr-searchfield .gc-iconbtn { color: var(--gc-on); }
/* Desktop: the search toggle after the session line, and the inline field. */
.gc-hdr-desk { position: relative; display: inline-flex; align-items: center; min-height: 36px; max-width: 100%; min-width: 0; }
.gc-hdr-desk.gc-open > .gc-char { visibility: hidden; }
.gc-mini-btn { width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; flex: none;
  color: var(--gc-accent); border-radius: 50%; pointer-events: auto; }
.gc-mini-btn:hover { background: var(--gc-accent-08); }
.gc-desk-field { position: absolute; inset: 0; display: flex; align-items: center; border-radius: 8px; background: var(--gc-on-06); }
.gc-desk-field input { flex: 1; min-width: 0; margin-left: 10px; font-size: 14px; line-height: 1.25; color: var(--gc-on); }
.gc-desk-field input::placeholder { color: var(--gc-onvar-50); }
.gc-desk-field .gc-mini-btn { margin-right: 2px; }

/* ---------- Composer ---------- */
.gc-cmp { position: absolute; bottom: 0; padding: 0 16px 16px 16px; pointer-events: none; }
.gc-atts { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 8px; pointer-events: auto; }
.gc-att { position: relative; border-radius: 12px; overflow: hidden; box-shadow: inset 0 0 0 var(--gc-ui-bw) var(--gc-ui-bc); }
.gc-att.gc-single { max-width: 150px; max-height: 150px; }
.gc-att.gc-multi { width: 84px; height: 84px; }
.gc-att img { display: block; border-radius: 12px; }
.gc-att.gc-single img { max-width: 150px; max-height: 150px; object-fit: contain; }
.gc-att.gc-multi img { width: 84px; height: 84px; object-fit: cover; }
.gc-att-x { position: absolute; top: 4px; right: 4px; width: 22px; height: 22px; border-radius: 50%;
  background: rgba(0,0,0,0.6); color: #fff; display: flex; align-items: center; justify-content: center; }
.gc-pill { pointer-events: auto; --gc-fill: var(--gc-fill-surface); --gc-bw: var(--gc-ui-bw); --gc-bc: var(--gc-ui-bc); }
.gc-pill.gc-guiding { --gc-bw: var(--gc-guide-bw); --gc-bc: rgba(255,152,0,0.3); }
.gc-pill > .gc-glass-content { display: flex; flex-direction: column; }
/* Flutter's TextField takes the theme's bodyLarge, whose line is 1.5 em, and
   the app's compact visual density takes 4px off each side of the 16px
   content padding the composer asked for. */
.gc-input { min-height: 56px; padding: 12px 18px; color: var(--gc-text); overflow-y: hidden; line-height: 1.5; }
.gc-input::placeholder { color: var(--gc-text2); }
.gc-input.gc-nocaret { caret-color: transparent; user-select: none; -webkit-user-select: none; }
.gc-guide { background: rgba(255,152,0,0.06); box-shadow: inset 0 -1px 0 rgba(255,152,0,0.25); }
.gc-guide-head { display: flex; align-items: center; padding: 8px 8px 0 18px; }
.gc-guide-caption { flex: 1; min-width: 0; font-weight: 700; letter-spacing: 0.8px; color: rgba(255,152,0,0.8); line-height: normal; }
.gc-guide-x { padding: 6px; color: rgba(255,152,0,0.7); display: flex; }
.gc-guide-body { display: flex; align-items: flex-start; min-height: 48px; }
.gc-guide-prefix { min-width: 42px; min-height: 32px; margin-top: 8px; display: flex; align-items: center; justify-content: center; color: rgba(255,152,0,0.7); flex: none; }
.gc-guide-input { padding: 10px 18px 6px 0; margin-left: 4px; color: #FF9800; overflow-y: hidden; line-height: 1.5; }
.gc-guide-input::placeholder { color: rgba(255,152,0,0.5); }
.gc-row { display: flex; align-items: center; margin-top: 4px; }
.gc-pins { flex: 1 1 0; min-width: 0; overflow-x: auto; overflow-y: hidden; scrollbar-width: none; pointer-events: auto;
  padding: 6px 6px 0 0; -webkit-overflow-scrolling: touch; overscroll-behavior-x: contain; }
.gc-pins::-webkit-scrollbar { display: none; }
.gc-pins.gc-editing { overflow-x: hidden; touch-action: none; }
.gc-pins.gc-empty { padding: 0; height: 0; }
.gc-pins-inner { display: inline-flex; gap: 8px; vertical-align: top; }
.gc-pin { position: relative; width: 40px; height: 40px; flex: none; touch-action: manipulation; }
.gc-pins.gc-editing .gc-pin { touch-action: none; }
.gc-circle { width: 40px; height: 40px; --gc-fill: var(--gc-fill-surface); --gc-bw: var(--gc-ui-bw); --gc-bc: var(--gc-ui-bc);
  pointer-events: auto; cursor: pointer; }
.gc-circle > .gc-glass-content { width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; }
.gc-badge { position: absolute; border-radius: 50%; display: flex; align-items: center; justify-content: center;
  color: #fff; pointer-events: auto; cursor: pointer; z-index: 5; }
.gc-pin > .gc-badge { top: -6px; right: -6px; }
.gc-send-wrap { position: relative; margin-left: 8px; flex: none; transition: transform 120ms; pointer-events: auto; }
.gc-send-wrap.gc-candidate { transform: scale(1.15); }
.gc-send-wrap > .gc-badge { top: -6px; right: -6px; }
.gc-send { position: relative; width: 40px; height: 40px; border-radius: 50%; background: var(--gc-accent);
  overflow: hidden; display: block; pointer-events: auto; }
.gc-send::after { content: ''; position: absolute; inset: 0; border-radius: 50%; background: #000; opacity: 0; transition: opacity 200ms; }
.gc-send:active::after { opacity: 0.12; }
.gc-send-glyph { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; color: #000;
  transition: opacity 200ms cubic-bezier(0.215, 0.61, 0.355, 1), transform 200ms cubic-bezier(0.215, 0.61, 0.355, 1); }
.gc-send-glyph.gc-leaving, .gc-send-glyph.gc-entering { opacity: 0; transform: scale(0.8); }
.gc-bar { display: flex; align-items: center; min-height: 56px; }
.gc-bar-label { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--gc-text); }
.gc-bar .gc-iconbtn { color: var(--gc-text); }

/* ---------- Drawer ---------- */
.gc-drw { position: absolute; background: #1E1E1E; border-top: 1px solid var(--gc-outline-var); pointer-events: auto; overflow: hidden; }
.gc-drw-body { position: absolute; inset: 0; }
.gc-drw-tab { position: absolute; inset: 0; overflow-y: auto; overflow-x: hidden; scrollbar-width: thin;
  scrollbar-color: rgba(255,255,255,0.24) transparent; -webkit-overflow-scrolling: touch; overscroll-behavior: contain; }
.gc-drw-tab::-webkit-scrollbar { width: 3px; }
.gc-drw-tab::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.24); border-radius: 3px; }
.gc-drw-tab::-webkit-scrollbar-track { background: transparent; margin-top: 66px; }
.gc-drw-tab.gc-dragging { overflow-y: hidden; touch-action: none; }
.gc-drw-edge { position: absolute; top: 0; left: 0; right: 0; height: 68px; pointer-events: none;
  -webkit-backdrop-filter: blur(24px); backdrop-filter: blur(24px);
  -webkit-mask-image: linear-gradient(to bottom, #000 50%, transparent 100%); mask-image: linear-gradient(to bottom, #000 50%, transparent 100%); }
.gc-drw-edge.gc-flat { -webkit-backdrop-filter: none; backdrop-filter: none; }
.gc-drw-tint { position: absolute; top: 0; left: 0; right: 0; height: 68px; pointer-events: none;
  background: linear-gradient(to bottom, rgba(30,30,30,0.88) 0%, rgba(30,30,30,0.88) 50%, rgba(30,30,30,0) 100%); }
.gc-drw-head { position: absolute; top: 0; left: 0; right: 0; padding: 20px 20px 0 20px; display: flex; align-items: center; }
.gc-tabs { flex: 1 1 0; min-width: 0; display: flex; align-items: center; }
.gc-tab { flex: 0 1 auto; min-width: 0; padding: 6px 0; cursor: pointer; }
.gc-tab + .gc-tab { margin-left: 22px; }
.gc-tab-inner { display: flex; align-items: center; padding-bottom: 6px; border-bottom: 2px solid transparent;
  transition: border-color 200ms cubic-bezier(0.25, 0.1, 0.25, 1), color 200ms cubic-bezier(0.25, 0.1, 0.25, 1); color: var(--gc-on-45); }
.gc-tab-label { margin-left: 7px; font-size: 15px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  line-height: normal; transition: color 200ms; color: var(--gc-on-45); }
.gc-tab.gc-active .gc-tab-inner { border-bottom-color: var(--gc-accent); color: var(--gc-accent); }
.gc-tab.gc-active .gc-tab-label { color: var(--gc-on); }
.gc-edit { margin-left: 10px; width: 34px; height: 34px; border-radius: 50%; flex: none; display: flex; align-items: center; justify-content: center;
  border: 1px solid transparent; background: transparent; color: var(--gc-on-55); cursor: pointer;
  transition: background-color 200ms, border-color 200ms, color 200ms; }
.gc-edit.gc-on { background: var(--gc-accent-22); border-color: var(--gc-accent-38); color: var(--gc-accent); }
.gc-handle { position: absolute; top: 0; left: 0; right: 0; height: 34px; touch-action: none; }
.gc-handle::before { content: ''; position: absolute; top: 8px; left: 50%; width: 32px; height: 4px; margin-left: -16px;
  border-radius: 2px; background: #757575; }
.gc-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); column-gap: 6px; row-gap: 8px; padding: 66px 12px 16px 12px; }
.gc-card { position: relative; border-radius: 14px; padding: 10px 8px; border: 1px solid rgba(255,255,255,0.06);
  background: rgba(255,255,255,0.04); overflow: hidden; cursor: pointer; display: flex; align-items: center;
  transition: background-color 180ms, border-color 180ms, transform 120ms cubic-bezier(0.25, 0.1, 0.25, 1), box-shadow 120ms;
  touch-action: pan-y; }
.gc-card.gc-pressed, .gc-card.gc-hovered { background: rgba(255,255,255,0.08); }
.gc-card.gc-pressed { transform: scale(0.96); }
.gc-card.gc-hovered { transform: scale(1.02); box-shadow: 0 0 14px var(--gc-accent-35); }
.gc-card.gc-editing { border-color: var(--gc-accent-55); }
.gc-card.gc-ghosted { opacity: 0.25; }
.gc-card-row { display: flex; align-items: center; width: 100%; min-width: 0; }
.gc-card-row > .gc-icon { color: rgba(255,255,255,0.85); }
.gc-card-texts { flex: 1 1 0; min-width: 0; margin-left: 8px; display: flex; flex-direction: column; }
.gc-card-label { font-size: 11px; font-weight: 600; line-height: 1; color: var(--gc-on);
  display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; overflow-wrap: anywhere; }
.gc-card-status { margin-top: 1px; display: flex; align-items: center; min-width: 0; font-size: 9px; line-height: 1; color: var(--gc-onvar-95); }
.gc-card-status > .gc-icon { margin-right: 3px; }
.gc-card-status span.gc-st { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.gc-card.gc-add .gc-card-row > .gc-icon { color: var(--gc-on-60); }
.gc-card > .gc-badge { top: 2px; right: 0; }
.gc-drw-loading { position: absolute; inset: 0; background: rgba(0,0,0,0.133); display: flex; align-items: center; justify-content: center; }
.gc-spinner { width: 28px; height: 28px; border-radius: 50%; border: 3px solid rgba(255,255,255,0.1);
  border-top-color: var(--gc-accent); animation: gc-spin 0.8s linear infinite; }
@keyframes gc-spin { to { transform: rotate(360deg); } }

/* ---------- Drag ---------- */
.gc-ghost { position: absolute; z-index: 40; pointer-events: none; opacity: 0.92; }
.gc-ghost .gc-card { cursor: default; }
`;
