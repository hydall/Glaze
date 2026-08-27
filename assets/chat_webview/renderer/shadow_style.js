/* Style block injected into every shadow root */
export const SHADOW_STYLE = `
  :host { display: block; font-size: inherit; color: inherit; }
  .glaze-message { word-wrap: break-word; line-height: 1.6; color: inherit; }
  .glaze-message p { margin: 0 0 0.8em 0; }
  .glaze-message p:first-child { margin-top: 0; }
  .glaze-message p:last-child { margin-bottom: 0; }
  .glaze-message strong { font-weight: 700; }
  .glaze-message em { font-style: italic; }
  .glaze-message del { text-decoration: line-through; }
  .glaze-message code {
    background: rgba(0,0,0,0.18);
    padding: 2px 6px;
    border-radius: 4px;
    font-family: 'Consolas','Monaco','Courier New',monospace;
    font-size: 0.9em;
  }
  .glaze-message pre {
    background: rgba(0,0,0,0.18);
    padding: 12px;
    border-radius: 8px;
    overflow-x: auto;
    margin: 12px 0;
  }
  .glaze-message pre code { background: none; padding: 0; }
  .glaze-message blockquote,
  .glaze-message .chat-blockquote {
    border-left: 3px solid var(--current-italic-color, var(--italic-color, #888));
    margin: 4px 0;
    padding: 2px 8px;
    color: var(--current-italic-color, var(--italic-color, #888));
    font-style: italic;
  }
  .glaze-message .chat-quote,
  .glaze-message .chat-quote-text {
    color: var(--current-quote-color, var(--quote-color, #7996CE));
  }
  .glaze-message .font-color-block .chat-quote,
  .glaze-message .font-color-block .chat-quote-text,
  .glaze-message .font-color-block .chat-italic { color: inherit; }
  .glaze-message .chat-italic {
    color: var(--current-italic-color, var(--italic-color, #888));
    font-style: italic;
  }
  .glaze-message a { color: var(--primary-color, #7996CE); text-decoration: underline; }
  .glaze-message img { max-width: 100%; height: auto; border-radius: 8px; margin: 8px 0; }
  .glaze-message .chat-quote-unclosed {
    color: var(--current-quote-color, var(--quote-color, #7996CE));
    opacity: 0.7;
  }
  .glaze-message .glaze-hc,
  .glaze-message .glaze-glow,
  .glaze-message .glaze-cg,
  .glaze-message .glaze-grad { font-weight: inherit; }
  .glaze-message .glaze-bg { color: #fff; }
  .glaze-message .glaze-mark { color: var(--current-quote-color, var(--quote-color, #7996CE)); }
  .glaze-message .glaze-active { background: #ffeb3b; color: #000; padding: 2px 4px; border-radius: 4px; }
  .glaze-message .glaze-accent { color: var(--primary-color, #7996CE); font-weight: 600; font-style: normal; }
  .glaze-message hr {
    border: 0;
    border-top: 1px solid var(--border-color, rgba(255,255,255,0.1));
    margin: 10px 0;
  }
  .glaze-message .font-style-block,
  .glaze-message .font-color-block { display: inline-block; vertical-align: baseline; color: inherit; }
  .glaze-message .code-block-wrapper { position: relative; margin: 8px 0; }
  .glaze-message .code-lang {
    position: absolute; top: 4px; right: 8px;
    font-size: 10px; opacity: 0.4;
    text-transform: uppercase; font-family: monospace;
  }
  .glaze-message .janitor-img-wrapper {
    display: inline-block; position: relative; max-width: 100%; margin: 4px 0;
  }
  .glaze-message .janitor-img-wrapper .janitor-img {
    max-width: 100%; border-radius: 8px; cursor: pointer; display: block;
  }
  .glaze-message .janitor-options-btn,
  .glaze-message .imggen-options-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: rgba(0,0,0,0.50);
    border: none;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    padding: 0;
    opacity: 0;
    color: #fff;
    font-size: 18px;
    line-height: 1;
    transition: opacity 0.2s, background 0.15s;
  }
  .glaze-message .janitor-img-wrapper:hover .janitor-options-btn,
  .glaze-message .imggen-result-wrapper:hover .imggen-options-btn { opacity: 1; }
  @media (hover: none) {
    .glaze-message .janitor-options-btn,
    .glaze-message .imggen-options-btn { opacity: 0.7; }
  }
  .glaze-message .janitor-options-btn:active,
  .glaze-message .imggen-options-btn:active { background: rgba(0,0,0,0.75); }
  .glaze-message .janitor-options-btn svg,
  .glaze-message .imggen-options-btn svg { width: 16px; height: 16px; fill: #fff; pointer-events: none; }

  /* ── Imagen: loading shimmer ── */
  .glaze-message .imggen-loading {
    display: block;
    max-width: 100%;
    min-height: 120px;
    border-radius: 12px;
    margin: 8px 0;
    background: linear-gradient(90deg,
      rgba(255,255,255,0.04) 25%,
      rgba(255,255,255,0.10) 50%,
      rgba(255,255,255,0.04) 75%);
    background-size: 200% 100%;
    animation: imggen-shimmer 1.5s infinite linear;
    position: relative;
    overflow: hidden;
    border: none;
    cursor: pointer;
  }
  .glaze-message .imggen-loading-hint {
    display: inline-block;
    padding: 12px 0 0 12px;
    font-size: 14px;
    font-weight: 600;
    color: rgba(255,255,255,0.9);
    user-select: none;
  }
  .glaze-message .imggen-loading-timer {
    display: inline-block;
    padding: 12px 12px 0 4px;
    font-size: 14px;
    font-weight: 600;
    color: rgba(255,255,255,0.7);
    font-variant-numeric: tabular-nums;
    user-select: none;
  }
  .glaze-message .imggen-stop-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: rgba(0,0,0,0.55);
    color: #fff;
    border: none;
    font-size: 13px;
    line-height: 1;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 3;
  }
  .glaze-message .imggen-stop-btn:active { background: rgba(0,0,0,0.8); }
  .glaze-message .imggen-loading-prompt {
    position: absolute;
    bottom: 10px;
    left: 10px;
    right: 10px;
    font-size: 11px;
    color: rgba(128,128,128,0.85);
    line-height: 1.4;
    max-height: 2.8em;
    overflow: hidden;
    transition: max-height 0.25s ease;
    user-select: none;
  }
  .glaze-message .imggen-loading.expanded .imggen-loading-prompt {
    top: 44px;
    max-height: calc(100% - 54px);
    overflow-y: auto;
  }
  @keyframes imggen-shimmer {
    0% { background-position: 100% 0; }
    100% { background-position: -100% 0; }
  }

  /* ── Broken message CSS: author-facing report ── */
  .glaze-message .glaze-css-error {
    margin: 8px 0;
    padding: 8px 10px;
    border-radius: 8px;
    box-sizing: border-box;
    max-width: 100%;
    background: rgba(255,59,48,0.1);
    border: 1px solid rgba(255,59,48,0.28);
    font-family: 'Consolas','Monaco','Courier New',monospace;
    font-size: 11px;
    line-height: 1.5;
    color: rgba(255,59,48,0.9);
    word-break: break-word;
  }
  .glaze-message .glaze-css-error-head {
    font-weight: 700;
    letter-spacing: 0.06em;
    margin-bottom: 3px;
  }
  .glaze-message .glaze-css-error-item { opacity: 0.85; }

  /* ── Imagen: error card ── */
  .glaze-message .imggen-error {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 8px;
    width: 240px;
    max-width: 100%;
    border-radius: 12px;
    margin: 8px 0;
    padding: 14px 12px;
    box-sizing: border-box;
    background: rgba(255,59,48,0.13);
    border: 1px solid rgba(255,59,48,0.32);
  }
  .glaze-message .imggen-error-icon { font-size: 20px; line-height: 1; flex-shrink: 0; }
  .glaze-message .imggen-error-msg {
    font-size: 11px;
    color: rgba(255,59,48,0.9);
    text-align: center;
    word-break: break-word;
    line-height: 1.4;
  }
  .glaze-message .imggen-error-actions { display: flex; gap: 6px; flex-wrap: wrap; justify-content: center; }
  .glaze-message .imggen-error-retry {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    border-radius: 12px;
    padding: 2px 10px;
    height: 24px;
    font-size: 11px;
    color: rgba(255,59,48,0.95);
    background: rgba(255,59,48,0.1);
    border: 1px solid rgba(255,59,48,0.3);
    cursor: pointer;
  }
  .glaze-message .imggen-error-retry:active { background: rgba(255,59,48,0.2); }
  /* Same actions menu as a finished image, on the block that has no image. */
  .glaze-message .imggen-error-options {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border-radius: 12px;
    color: rgba(255,59,48,0.95);
    background: rgba(255,59,48,0.1);
    border: 1px solid rgba(255,59,48,0.3);
    cursor: pointer;
  }
  .glaze-message .imggen-error-options:active { background: rgba(255,59,48,0.2); }
  .glaze-message .imggen-error-options svg {
    width: 14px;
    height: 14px;
    fill: rgba(255,59,48,0.95);
    pointer-events: none;
  }

  /* ── Imagen: result ── */
  .glaze-message .imggen-result-wrapper {
    display: inline-block;
    position: relative;
    margin: 6px 0;
    max-width: 100%;
  }
  /* Block-level image switcher: the message switcher, shrunk and made
     see-through so it sits on the picture without covering it. Only rendered
     when the block holds more than one image. */
  .glaze-message .imggen-variants {
    position: absolute;
    left: 8px;
    bottom: 8px;
    display: flex;
    align-items: center;
    gap: 1px;
    height: 18px;
    padding: 0 2px;
    border-radius: 9px;
    background: rgba(0, 0, 0, 0.38);
    border: 1px solid rgba(255, 255, 255, 0.10);
    color: rgba(255, 255, 255, 0.92);
    font-size: 10px;
    line-height: 1;
    opacity: 0.45;
    transition: opacity 0.15s;
  }
  .glaze-message .imggen-result-wrapper:hover .imggen-variants { opacity: 1; }
  .glaze-message .imggen-variant-btn {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: none;
    background: none;
    color: inherit;
    cursor: pointer;
  }
  .glaze-message .imggen-variant-btn svg {
    width: 12px;
    height: 12px;
    fill: currentColor;
    pointer-events: none;
  }
  .glaze-message .imggen-variant-btn:active { opacity: 0.6; }
  .glaze-message .imggen-variant-count {
    min-width: 20px;
    text-align: center;
    font-variant-numeric: tabular-nums;
  }

  .glaze-message .imggen-result {
    max-width: 100%;
    border-radius: 10px;
    display: block;
    margin: 0;
    cursor: pointer;
  }
  .glaze-message table tbody tr:nth-child(even) { background-color: rgba(255,255,255,0.02); }
  .glaze-message table td { padding: 8px 12px; border-bottom: 1px solid rgba(255,255,255,0.08); }
  .glaze-message .chat-table {
    border-collapse: collapse;
    width: 100%;
    margin: 10px 0;
    font-size: 0.95em;
  }
  .glaze-message .chat-table th {
    padding: 8px 12px;
    text-align: left;
    font-weight: 600;
    border-bottom: 1px solid rgba(255,255,255,0.18);
  }
  /* Message headings stay close to body text — a bubble is not a document. */
  .glaze-message .chat-heading {
    margin: 12px 0 6px;
    line-height: 1.25;
    font-weight: 700;
  }
  .glaze-message .chat-heading:first-child { margin-top: 0; }
  .glaze-message h1.chat-heading { font-size: 1.35em; }
  .glaze-message h2.chat-heading { font-size: 1.22em; }
  .glaze-message h3.chat-heading { font-size: 1.12em; }
  .glaze-message h4.chat-heading,
  .glaze-message h5.chat-heading,
  .glaze-message h6.chat-heading { font-size: 1em; }
  .search-highlight-text {
    background-color: rgba(255, 215, 0, 0.4);
    color: #fff;
    border-radius: 4px;
    padding: 0 2px;
  }
  .search-highlight-text.active-search-match {
    background-color: rgba(244, 67, 54, 0.8);
    color: #fff;
  }
  .glaze-message details {
    margin: 8px 0;
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 8px;
    overflow: hidden;
    font-size: 0.95em;
    opacity: 0.9;
  }
  .glaze-message details summary {
    padding: 8px 12px;
    cursor: pointer;
    background: rgba(0,0,0,0.18);
    font-weight: 500;
    list-style: none !important;
    list-style-type: none !important;
    line-height: 1.4;
  }
  .glaze-message details summary::-webkit-details-marker { display: none !important; }
  .glaze-message details summary::marker { display: none !important; content: '' !important; }
  .glaze-message details summary::before { display: none !important; content: '' !important; }
  .glaze-message .glaze-arrow {
    display: inline;
    flex-shrink: 0;
    font-size: 1em;
    transition: transform 0.2s;
    opacity: 0.7;
    font-style: normal;
    font-weight: normal;
    user-select: none;
    -webkit-user-select: none;
  }
  .glaze-message .glaze-arrow.glaze-arrow-open { transform: rotate(90deg); }
  .search-highlight-text {
    background-color: rgba(255,215,0,0.4);
    border-radius: 4px;
    padding: 0 2px;
  }
  .search-highlight-text.active-search-match {
    background-color: rgba(244,67,54,0.8);
    color: #fff;
  }
  .edit-textarea {
    display: block;
    width: 100%;
    padding: 8px;
    border: 1px solid rgba(255,255,255,0.12);
    border-radius: 8px;
    background: var(--bg-color, #1a1a2e);
    color: var(--text-color, #e0e0e0);
    font-size: var(--font-size, 15px);
    font-family: inherit;
    resize: none;
    outline: none;
    line-height: 1.6;
    field-sizing: content;
  }
  .edit-textarea:focus { border-color: var(--primary-color, #7996CE); }
  .message-section.editing .msg-reasoning { display: none; }
`;
