import { expandMacros } from './macros.js';
import { renderStyledSegment } from './text_format.js';

// Vertical 3-dot "options" icon (ported from Glaze useMessageImageGen.js).
const OPTIONS_SVG = '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>';

export class Formatter {
  constructor() {
    this.cache = new Map();
    this.cacheMaxSize = 500;
  }

  format(text, isUser = false) {
    const key = `${text}:${isUser}`;
    if (this.cache.has(key)) return this.cache.get(key);

    let result;
    try {
      result = this._processText(text, isUser);
    } catch (e) {
      console.error('Formatter error:', e);
      result = (text || '').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\n/g, '<br>');
    }

    const leaked = result.match(/\x01[A-Z_]+\d+\x01/g);
    if (leaked) {
      console.error('Formatter LEAK:', leaked, 'text:', text?.substring(0, 100));
      result = result.replace(/\x01[A-Z_]+\d+\x01/g, '');
    }

    if (this.cache.size >= this.cacheMaxSize) {
      const firstKey = this.cache.keys().next().value;
      this.cache.delete(firstKey);
    }
    this.cache.set(key, result);
    return result;
  }

  _ph(prefix, i, isBlock) {
    return `\x01${prefix}${isBlock ? 'BLOCK_' : ''}${i}\x01`;
  }

  _processText(text, isUser, skipQuotes = false) {
    if (!text) return '';
    text = expandMacros(text).replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();

    let html = text;

    // 1a. Extract <think...</think...> reasoning blocks
    const thinkBlocks = [];
    html = html.replace(/<think\b[^>]*>([\s\S]*?)<\/think\b[^>]*>/gi, (match, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    html = html.replace(/<think\b([^>]*?)(?:>|\n)([\s\S]*?)<\/think\b/gi, (match, attrs, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    html = html.replace(/<thinking\b[^>]*>([\s\S]*?)<\/thinking\b[^>]*>/gi, (match, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    html = html.replace(/<thinking\b([^>]*?)(?:>|\n)([\s\S]*?)<\/thinking\b/gi, (match, attrs, content) => {
      const id = this._ph('TB_', thinkBlocks.length, true);
      thinkBlocks.push(content.trim());
      return '\n\n' + id + '\n\n';
    });

    // 1b. Extract <style>...</style> blocks
    const styleBlocks = [];
    html = html.replace(/<style\b[^>]*>([\s\S]*?)<\/style>/gi, (match, content) => {
      const id = this._ph('STY_', styleBlocks.length, true);
      styleBlocks.push(match);
      return '\n\n' + id + '\n\n';
    });

    // 1c. Extract <script>...</script> blocks
    const scriptBlocks = [];
    html = html.replace(/<script\b[^>]*>([\s\S]*?)<\/script>/gi, (match, content) => {
      const id = this._ph('SCR_', scriptBlocks.length, true);
      scriptBlocks.push(match);
      return '\n\n' + id + '\n\n';
    });

    // 2. Extract Code Blocks
    const codeBlocks = [];
    html = html.replace(/```(\w*)\n?([\s\S]*?)(?:```|$)/g, (match, lang, code) => {
      const id = this._ph('CB_', codeBlocks.length);
      codeBlocks.push({ lang, code });
      return id;
    });

    // 3. Extract CSS comments inside code blocks are already protected
    //    Extract standalone CSS comments (outside code blocks)
    const cssComments = [];
    html = html.replace(/\/\*([\s\S]*?)\*\//g, (match) => {
      const id = this._ph('CC_', cssComments.length);
      cssComments.push(match);
      return id;
    });

    // 4. Fix escaped HTML line breaks
    html = html.replace(/&lt;br\s*\/?&gt;/gi, '<br>');

    // 5. Extract <font color="..."> blocks before quote processing
    const fontBlocks = [];
    html = html.replace(/<font\s+color=["']?(#[0-9a-fA-F]{3,8})["']?\s*>([\s\S]*?)<\/font>/gi, (match, color, content) => {
      const id = this._ph('FC_', fontBlocks.length);
      fontBlocks.push({ type: 'color', color, content });
      return id;
    });
    // font style with double-quoted attribute value
    html = html.replace(/<font\s+style\s*=\s*"([^"]*)"['"]*\s*>([\s\S]*?)<\/font>/gi, (match, style, content) => {
      const id = this._ph('FC_', fontBlocks.length);
      fontBlocks.push({ type: 'style', style, content });
      return id;
    });
    // font style with single-quoted attribute value
    html = html.replace(/<font\s+style\s*=\s*'([^']*)'\s*>([\s\S]*?)<\/font>/gi, (match, style, content) => {
      const id = this._ph('FC_', fontBlocks.length);
      fontBlocks.push({ type: 'style', style, content });
      return id;
    });

    // 5b. Janitor images: ![alt](url) → <span class="janitor-img-wrapper"> with options button
    //
    // The card is stashed as ONE atomic placeholder and restored at the very
    // end (step 12c). Emitting its raw HTML here instead would hand it to the
    // tag extraction in step 6, which classifies <img>/<svg>/<path> as *block*
    // tags — step 11 then isolates every block placeholder in its own
    // paragraph, so `<span class="janitor-img-wrapper">`, the `<img>` and the
    // options `<button>` end up in three different <p> elements. The button
    // would lose its positioned wrapper and its `position: absolute` would
    // resolve against the message container, pinning the 3-dot menu to the top
    // of the whole message instead of the top of the image.
    const mdImages = [];
    html = html.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (match, alt, url) => {
      const safeUrl = this._escapeHtml(this._normalizeMdUrl(url));
      const id = this._ph('MI_', mdImages.length);
      mdImages.push(`<span class="janitor-img-wrapper"><img src="${safeUrl}" alt="${this._escapeHtml(alt)}" class="janitor-img" loading="lazy" data-action="image-click" data-src="${safeUrl}"><button class="janitor-options-btn" type="button" data-action="img-options" data-src="${safeUrl}" title="Options">${OPTIONS_SVG}</button></span>`);
      return id;
    });

    // 5c. Glaze image gen tags
    const imgBlocks = [];
    html = html.replace(/\[IMG:GEN(?::(.*?))?\]/g, (match, instruction) => {
      const id = this._ph('IG_', imgBlocks.length, true);
      imgBlocks.push({ type: 'gen', instruction: instruction || '' });
      return '\n\n' + id + '\n\n';
    });
    html = html.replace(/\[IMG:RESULT:(.*?)\]/g, (match, payload) => {
      const id = this._ph('IG_', imgBlocks.length, true);
      const pipeIdx = payload.indexOf('|');
      const path = pipeIdx !== -1 ? payload.substring(0, pipeIdx) : payload;
      const instruction = pipeIdx !== -1 ? payload.substring(pipeIdx + 1) : '';
      imgBlocks.push({ type: 'result', path, instruction });
      return '\n\n' + id + '\n\n';
    });
    html = html.replace(/\[IMG:ERROR:(.*?)\]/g, (match, data) => {
      const id = this._ph('IG_', imgBlocks.length, true);
      imgBlocks.push({ type: 'error', data });
      return '\n\n' + id + '\n\n';
    });

    // 6. Extract HTML Tags — distinguish block vs inline
    //    Skip orphan tags (no matching pair) so they render as visible text
    //    instead of being interpreted as real HTML elements.
    const tagBlocks = [];
    const blockTags = new Set(['div','p','style','pre','table','ul','ol','li','h1','h2','h3','h4','h5','h6','blockquote','section','article','header','footer','hr','details','summary','figure','figcaption','svg','path','math','canvas','video','audio','form','fieldset','nav','aside','main','img','br','loomledger']);
    const TAG_REGEX = /<(?:[^"'>]|"[^"]*"|'[^']*')*>/g;

    const allTagMatches = [...html.matchAll(TAG_REGEX)];
    const tagCounts = new Map();
    for (const m of allTagMatches) {
      const nameMatch = m[0].match(/^<\/?(\w+)/);
      if (nameMatch) {
        const name = nameMatch[1].toLowerCase();
        tagCounts.set(name, (tagCounts.get(name) || 0) + 1);
      }
    }

    html = html.replace(TAG_REGEX, (match) => {
      const tagMatch = match.match(/^<\/?(\w+)/);
      if (!tagMatch) return match;
      const name = tagMatch[1].toLowerCase();
      const count = tagCounts.get(name) || 0;
      // Self-closing tags (br, hr, img) and paired tags are fine;
      // single occurrence of a non-self-closing tag is orphan — escape it.
      const selfClosing = new Set(['br', 'hr', 'img', 'input', 'meta', 'link']);
      const isExplicitSelfClosing = /\/\s*>$/.test(match);
      if (count === 1 && !selfClosing.has(name) && !isExplicitSelfClosing) {
        return match.replace(/</g, '&lt;').replace(/>/g, '&gt;');
      }
      const isBlock = blockTags.has(name);
      const id = this._ph('T_', tagBlocks.length, isBlock);
      tagBlocks.push(match);
      return id;
    });

    // 7. Extract Glaze custom markers BEFORE quotes
    const styledSegments = [];
    const styledRegex = /(==hc:#[0-9a-fA-F]{3,8}==.+?==|==glow:#[0-9a-fA-F]{3,8},\d+==.+?==|==cg:#[0-9a-fA-F]{3,8},#[0-9a-fA-F]{3,8},\d+==.+?==|==grad:#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+==.+?==|==bg:#[0-9a-fA-F]{3,8}==.+?==|==mark==.+?==|==active==.+?==|\*\*[^*]+?\*\*|(?<!\*)\*[^*]+?\*(?!\*)|__[^_]+?__|(?<!\w)_[^_]+?_(?!\w)|~~[^~]+?~~)/gs;

    html = html.replace(styledRegex, (match) => {
      const id = this._ph('S_', styledSegments.length);
      styledSegments.push(match);
      return id;
    });

    // 8. Quote formatting — with unclosed quote handling for streaming
    if (!skipQuotes) {
      const phGroup = '\x01[A-Z_]+\\d+\x01';
      const quoteRegex = new RegExp(`(${phGroup})|(=[ \\t]*"(?:[^"]|\\\\")*?")|(")((?:[^"]|\\\\")*?)(")|(«)((?:[^»])*?)(»)|(")((?:[^"]*)$)`, 'gm');
      html = html.replace(quoteRegex, (match, placeholder, skipQuote, openQ, closedContent, closeQ, openG, guillemetContent, closeG, openU, unclosedContent) => {
        if (placeholder) return placeholder;
        if (skipQuote) return skipQuote;
        if (openQ !== undefined) return `<span class="chat-quote">${openQ}</span><span class="chat-quote-text">${closedContent}</span><span class="chat-quote">${closeQ}</span>`;
        if (openG !== undefined) return `<span class="chat-quote">${openG}</span><span class="chat-quote-text">${guillemetContent}</span><span class="chat-quote">${closeG}</span>`;
        if (openU !== undefined) return `<span class="chat-quote">${openU}</span><span class="chat-quote-text">${unclosedContent}</span>`;
        return match;
      });
    }

    // 9. Restore styled segments with Glaze marker rendering
    html = html.replace(/\x01S_(\d+)\x01/g, (_, i) => {
      const seg = styledSegments[parseInt(i)];
      return renderStyledSegment(seg, (innerRaw) => this._processText(innerRaw, false, true));
    });

    // 10. Markdown Parsing
    html = html.replace(/^>\s?(.*)$/gm, '<blockquote class="chat-blockquote">$1</blockquote>');
    html = html.replace(/<\/blockquote>\n*<blockquote class="chat-blockquote">/g, '<br>');
    html = html.replace(/^(_{3,}|-{3,}|\*{3,})$/gm, '<hr>');
    html = html.replace(/~~([\s\S]+?)~~/g, '<del>$1</del>');
    html = html.replace(/\*\*\*([\s\S]+?)\*\*\*/g, '<strong><em>$1</em></strong>');
    html = html.replace(/\*\*([\s\S]+?)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/\*([\s\S]+?)\*/g, '<em>$1</em>');
    html = html.replace(/<em>/g, '<em class="chat-italic">');

    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');

    // 10b. Markdown lists
    const listBlocks = [];
    html = html.replace(/((?:^|\n)((?:[-*] .+(?:\n|$))+))/g, (match) => {
      const id = this._ph('LB_', listBlocks.length, true);
      const items = match.trim().split('\n')
        .filter(line => line.match(/^[-*] /))
        .map(line => `<li>${line.replace(/^[-*] /, '')}</li>`)
        .join('');
      listBlocks.push(`<ul class="chat-list">${items}</ul>`);
      return '\n\n' + id + '\n\n';
    });
    html = html.replace(/((?:^|\n)((?:\d+\. .+(?:\n|$))+))/g, (match) => {
      const id = this._ph('LB_', listBlocks.length, true);
      const items = match.trim().split('\n')
        .filter(line => line.match(/^\d+\. /))
        .map(line => `<li>${line.replace(/^\d+\. /, '')}</li>`)
        .join('');
      listBlocks.push(`<ol class="chat-list">${items}</ol>`);
      return '\n\n' + id + '\n\n';
    });

    // 11. Paragraphs — isolate block placeholders, don't wrap in <p>
    const blockPh = '\x01T_BLOCK_\\d+\x01';
    const codePh = '\x01CB_\\d+\x01';
    const stylePh = '\x01STY_BLOCK_\\d+\x01';
    const scriptPh = '\x01SCR_BLOCK_\\d+\x01';
    const listPh = '\x01LB_BLOCK_\\d+\x01';
    const imgPh = '\x01IG_BLOCK_\\d+\x01';
    const allBlockPh = `${codePh}|${blockPh}|${stylePh}|${scriptPh}|${listPh}|${imgPh}`;
    html = html.replace(new RegExp(`\\n?(${allBlockPh})\\n?`, 'g'), '\n\n$1\n\n');

    const paragraphs = html.split(/\n\n+/);
    html = paragraphs
      .map(p => {
        let trimmed = p.trim();
        if (!trimmed) return '';

        if (new RegExp(`^(${allBlockPh})$`).test(trimmed)) return trimmed;

        const startsWithBlock = new RegExp(`^(${blockPh}|${stylePh}|${scriptPh})`).test(trimmed);
        trimmed = trimmed.replace(new RegExp(`(\x01T_(?:BLOCK_)?\\d+\x01)\\s*\\n\\s*`, 'g'), '$1 ');
        trimmed = trimmed.replace(new RegExp(`\\s*\\n\\s*(\x01T_(?:BLOCK_)?\\d+\x01)`, 'g'), ' $1');
        trimmed = trimmed.replace(/\n/g, '<br>');
        return startsWithBlock ? trimmed : `<p>${trimmed}</p>`;
      })
      .filter(p => p !== '')
      .join('');

    // 12. Restore HTML Tags
    html = html.replace(/\x01T_(?:BLOCK_)?(\d+)\x01/g, (_, i) => tagBlocks[parseInt(i)]);
    html = html.replace(/(<svg\b[^>]*>)\s*<p>([\s\S]*?)<\/p>\s*(<\/svg>)/gi, '$1$2$3');

    // 12b. Restore list blocks
    html = html.replace(/\x01LB_BLOCK_(\d+)\x01/g, (_, i) => listBlocks[parseInt(i)]);

    // 12c. Restore markdown image cards — kept whole so the options button
    //      stays inside its positioned .janitor-img-wrapper (see step 5b).
    html = html.replace(/\x01MI_(\d+)\x01/g, (_, i) => mdImages[parseInt(i)]);

    // 13. Restore CSS comments
    html = html.replace(/\x01CC_(\d+)\x01/g, (_, i) => cssComments[parseInt(i)]);

    // 14. Restore style blocks
    html = html.replace(/\x01STY_BLOCK_(\d+)\x01/g, (_, i) => styleBlocks[parseInt(i)]);

    // 15. Restore script blocks (will be executed by renderer via DOM API)
    html = html.replace(/\x01SCR_BLOCK_(\d+)\x01/g, (_, i) => {
      return scriptBlocks[parseInt(i)];
    });

    // 16. Restore Code Blocks
    html = html.replace(/\x01CB_(\d+)\x01/g, (_, i) => {
      const block = codeBlocks[parseInt(i)];
      const escapedCode = block.code
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
      const langAttr = block.lang ? ` class="language-${block.lang}"` : '';
      const langLabel = block.lang ? `<span class="code-lang">${block.lang}</span>` : '';
      return `<div class="code-block-wrapper">${langLabel}<pre><code${langAttr}>${escapedCode}</code></pre></div>`;
    });

    // 17. Restore think blocks
    html = html.replace(/\x01TB_BLOCK_(\d+)\x01/g, (_, i) => {
      const content = thinkBlocks[parseInt(i)];
      const formatted = this._processText(content, isUser);
      return `<details class="reasoning-block"><summary class="reasoning-summary">💭 Reasoning</summary><div class="reasoning-content">${formatted}</div></details>`;
    });

    // 18. Restore font color/style blocks
    // skipQuotes=true: quotes inside styled spans keep their visual style intact
    // (chat-quote color would override gradient/color fills)
    html = html.replace(/\x01FC_(\d+)\x01/g, (_, i) => {
      const block = fontBlocks[parseInt(i)];
      if (block.type === 'style') {
        let formatted = this._processText(block.content, isUser, true);
        formatted = formatted.replace(/^\s*<p>([\s\S]*?)<\/p>\s*$/i, '$1');

        // Propagate gradient / text-fill / clip styles down to the first nested inline element
        // when the LLM put the visible text inside <span style="transform..."> inside the <font>.
        // Without this the background-clip:text on the outer span has no text to clip.
        const hasGradientClip = /background-clip\s*:\s*text/i.test(block.style) ||
                                /-webkit-background-clip\s*:\s*text/i.test(block.style) ||
                                /-webkit-text-fill-color\s*:\s*transparent/i.test(block.style);
        if (hasGradientClip) {
          const toMerge = [];
          const bg = block.style.match(/background-image\s*:\s*[^;]+/i);
          const clip = block.style.match(/-webkit-background-clip\s*:\s*[^;]+/i);
          const fill = block.style.match(/-webkit-text-fill-color\s*:\s*[^;]+/i);
          const stroke = block.style.match(/-webkit-text-stroke\s*:\s*[^;]+/i);
          const filter = block.style.match(/filter\s*:\s*[^;]+/i);
          for (const m of [bg, clip, fill, stroke, filter]) if (m) toMerge.push(m[0]);
          if (toMerge.length) {
            const extra = toMerge.join('; ');
            formatted = formatted.replace(/^(\s*<span)(\s+style=")([^"]*)(")/i, (m, tagOpen, styleOpen, inner, styleClose) => {
              const merged = (inner || '').replace(/;?\s*$/, '') + '; ' + extra;
              return `${tagOpen}${styleOpen}${merged}${styleClose}`;
            });
          }
        }

        return `<span class="font-style-block" style="${block.style}">${formatted}</span>`;
      }
      let formatted = this._processText(block.content, isUser, true);
      formatted = formatted.replace(/^\s*<p>([\s\S]*?)<\/p>\s*$/i, '$1');
      return `<span class="font-color-block" style="color:${block.color}">${formatted}</span>`;
    });

    // 19. Restore image gen blocks (Imagen UI ported from Glaze ShadowContent.vue)
    html = html.replace(/\x01IG_BLOCK_(\d+)\x01/g, (_, i) => {
      const block = imgBlocks[parseInt(i)];
      if (block.type === 'result') {
        const src = this._imageSrc(block.path);
        const encInstr = encodeURIComponent(block.instruction || '');
        return `<span class="imggen-result-wrapper"><img src="${src}" class="imggen-result" loading="lazy" data-action="image-click" data-src="${src}"><button class="imggen-options-btn" type="button" data-action="img-options" data-src="${src}" data-instruction="${encInstr}" title="Options">${OPTIONS_SVG}</button></span>`;
      }
      if (block.type === 'gen') {
        const start = Date.now();
        const prompt = this._escapeHtml(this._imgPrompt(block.instruction));
        const promptEl = prompt ? `<div class="imggen-loading-prompt">${prompt}</div>` : '';
        return `<div class="imggen-loading" data-start="${start}"><span class="imggen-loading-hint">Generating image…</span><span class="imggen-loading-timer" data-start="${start}">0.0s</span><button class="imggen-stop-btn" type="button" data-action="img-stop" title="Stop image generation">⏹</button>${promptEl}</div>`;
      }
      if (block.type === 'error') {
        let errorMsg = 'Unknown error';
        let instruction = '';
        try {
          const parsed = JSON.parse(block.data);
          errorMsg = parsed.error || errorMsg;
          instruction = parsed.instruction || '';
        } catch(_) {}
        const encInstr = encodeURIComponent(instruction);
        return `<div class="imggen-error" data-instruction="${encInstr}"><span class="imggen-error-icon">⚠</span><span class="imggen-error-msg">${this._escapeHtml(errorMsg)}</span><div class="imggen-error-actions"><button class="imggen-error-retry" type="button" data-action="img-retry" data-instruction="${encInstr}">↻ Retry</button><button class="imggen-error-retry imggen-error-find" type="button" data-action="img-find" data-instruction="${encInstr}">Find on disk</button></div></div>`;
      }
      return '';
    });

    html = html.replace(/\x01[A-Z_]+\d+\x01/g, '');

    return html;
  }

  _renderStyledSegment(seg) {
    return renderStyledSegment(seg, (innerRaw) => this._processText(innerRaw, false, true));
  }

  _imageSrc(path) {
    if (!path) return '';
    if (path.startsWith('data:') || path.startsWith('http://') || path.startsWith('https://') || path.startsWith('file://')) {
      return path;
    }
    const normalized = path.replace(/\\/g, '/');
    return normalized.startsWith('/') ? `file://${normalized}` : `file:///${normalized}`;
  }

  // Normalizes the destination of a markdown image/link.
  //
  // The raw capture is everything between the parens, which for CommonMark can
  // carry padding, an <…> wrapper and a title: `![a]( <u> "cap" )`. A browser
  // trims and re-encodes most of that when it loads the <img>, so the picture
  // still appears in the message — but the same raw string handed to Flutter
  // (via data-src) is not a valid URL there, and the full-screen viewer opens
  // onto nothing. Normalize once, so both sides see the same URL.
  _normalizeMdUrl(url) {
    let out = String(url == null ? '' : url).trim();
    // Trailing title: `url "caption"` / `url 'caption'` / `url (caption)`.
    const titled = out.match(/^(\S+)\s+(?:"[^"]*"|'[^']*'|\([^)]*\))$/);
    if (titled) out = titled[1];
    if (out.startsWith('<') && out.endsWith('>')) out = out.slice(1, -1).trim();
    return out;
  }

  _escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Extract a human-readable prompt from an IMG:GEN instruction payload.
  // The payload may be a JSON object ({prompt, caption, ...}) or raw text.
  _imgPrompt(instruction) {
    const raw = (instruction || '').trim();
    if (!raw) return '';
    try {
      const json = JSON.parse(raw);
      if (json && typeof json === 'object') {
        const p = (json.prompt || json.caption || '').replace(/^SCENE_PROMPT:\s*/, '');
        return p || '';
      }
    } catch (_) { /* fall through to raw */ }
    return raw;
  }
}
