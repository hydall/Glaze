import { getEffectivePreset } from '@/core/states/presetState.js';
import { applyRegexes } from '@/core/services/regexService.js';

export function cleanText(text) {
    if (!text) return "";
    return text.trim();
}

export function formatText(text, isUser = false, options = {}) {
    if (!text) return "";

    const { charId, sessionId, char, persona, triggeredRegexes } = options;

    // Remove leading/trailing line breaks
    text = cleanText(text);

    // Apply Regex Scripts (Before HTML formatting, simulating ST behavior)
    // 1 corresponds to User Input, 2 corresponds to AI Output
    // 1 corresponds to Alter Chat Display (ephemerality)
    text = applyRegexes(text, isUser ? 1 : 2, 1, { charId, sessionId, char, persona, triggeredRegexes });

    // 1. Allow HTML (No escaping)
    let html = text;

    // 2. Extract Code Blocks (to prevent formatting inside them)
    const codeBlocks = [];
    html = html.replace(/```(\w*)\n?([\s\S]*?)(?:```|$)/g, (match, lang, code) => {
        const isClosed = match.endsWith('```');
        const id = `__CODE_BLOCK_${codeBlocks.length}__`;
        codeBlocks.push({ lang, code, isClosed });
        return id;
    });

    // Extract Style Blocks (to prevent formatting inside them)
    const styleBlocks = [];
    html = html.replace(/<style([\s\S]*?)>([\s\S]*?)(?:<\/style>|$)/gi, (match, attributes, content) => {
        const isClosed = /<\/style>\s*$/i.test(match);
        const id = `__STYLE_BLOCK_${styleBlocks.length}__`;
        // Fix escaped newlines inside style blocks by converting them to real newlines
        content = content.replace(/&lt;br\s*\/?(?:&gt;|>)/gi, '\n');
        styleBlocks.push({ attributes, content, isClosed });
        return id;
    });

    // Extract Script Blocks (to prevent formatting inside them)
    const scriptBlocks = [];
    html = html.replace(/<script([\s\S]*?)>([\s\S]*?)(?:<\/script>|$)/gi, (match, attributes, content) => {
        const isClosed = /<\/script>\s*$/i.test(match);
        const id = `__SCRIPT_BLOCK_${scriptBlocks.length}__`;
        // Fix escaped newlines inside script blocks
        content = content.replace(/&lt;br\s*\/?(?:&gt;|>)/gi, '\n');
        scriptBlocks.push({ attributes, content, isClosed });
        return id;
    });

    // Extract CSS comments (to prevent formatting inside them)
    const cssComments = [];
    html = html.replace(/\/\*[\s\S]*?\*\//g, (match) => {
        const id = `__CSS_COMMENT_${cssComments.length}__`;
        cssComments.push(match);
        return id;
    });

    // Fix escaped newlines from model (in remaining text)
    html = html.replace(/&lt;br\s*\/?(?:&gt;|>)/gi, '<br>');

    // Janitor image: ![alt](url) -> wrapped img with options button
    const JANITOR_OPTIONS_SVG = `<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>`;
    html = html.replace(/!\[([^\]]*)\]\((https?:\/\/[^)]+)\)/g, (match, alt, src) => {
        return `<span class="janitor-img-wrapper"><img class="janitor-img" src="${src}"${alt ? ` alt="${alt}"` : ''}><button class="janitor-options-btn" type="button" title="Options">${JANITOR_OPTIONS_SVG}</button></span>`;
    });

    // 4. Protect HTML Tags (to prevent <br> injection inside them AND corruption by Quote formatter)
    const tagBlocks = [];
    const blockTagsRegex = /^\s*<\/?(div|p|style|pre|table|ul|ol|li|h[1-6]|blockquote|section|article|header|footer|hr|details|summary|figure|figcaption|svg|path|math|canvas|video|audio|form|fieldset|nav|aside|main)(?:\s+[^>]*?)?>/i;

    // Improved Regex for matching tags with internal quotes/greater-than
    const COMPLETE_TAG_REGEX = /<(?:[^"'>]|"[^"]*"|'[^']*')*?>/g;
    const UNCLOSED_TAG_REGEX = /<(?:[^"'>]|"[^"]*"|'[^']*')*$/;

    // Detect unclosed tag at the very end (streaming)
    let unclosedTag = null;
    const unclosedMatch = html.match(UNCLOSED_TAG_REGEX);
    if (unclosedMatch) {
        unclosedTag = unclosedMatch[0];
        html = html.substring(0, unclosedMatch.index) + "__UNCLOSED_TAG__";
    }

    // Extract all closed tags (including multiline ones)
    html = html.replace(COMPLETE_TAG_REGEX, (match) => {
        const isBlock = blockTagsRegex.test(match);
        const id = `__TAG_BLOCK_${isBlock ? 'BLOCK_' : ''}${tagBlocks.length}__`;
        tagBlocks.push(match);
        return id;
    });

    // 5. Quotes -> Blue
    // Regex matches all block placeholders, Quotes preceded by = (to skip), OR Quotes (to color)
    const quoteRegex = /(__[A-Z_]+_\d+__)|(=[ \t]*"(?:[^"]|\\")*?")|("((?:[^"]|\\")*?)"|"((?:[^"]|\\")*?)"|«((?:[^»])*?)»)/g;
    html = html.replace(quoteRegex, (match, placeholder, skipQuote) => {
        if (placeholder) return placeholder;
        if (skipQuote) return skipQuote;
        return `<span class="chat-quote">${match}</span>`;
    });

    // Unclosed quotes during streaming: opening quote with no closing quote
    // Matches " or « or \u201C at end of text (streaming delta) without a matching closer
    html = html.replace(/([ \t])("(?:[^"\\]|\\.)*?)$/gm, (fullMatch, prefix, unclosed) => {
        return `${prefix}<span class="chat-quote">${unclosed}</span>`;
    });
    html = html.replace(/^(("(?:[^"\\]|\\.)*?))$/gm, (fullMatch, unclosed) => {
        return `<span class="chat-quote">${unclosed}</span>`;
    });
    html = html.replace(/([ \t])(\u201C(?:[^\u201D])*?)$/gm, (fullMatch, prefix, unclosed) => {
        return `${prefix}<span class="chat-quote">${unclosed}</span>`;
    });
    html = html.replace(/^(\u201C(?:[^\u201D])*?)$/gm, (fullMatch, unclosed) => {
        return `<span class="chat-quote">${unclosed}</span>`;
    });
    html = html.replace(/([ \t])(\u00AB(?:[^\u00BB])*?)$/gm, (fullMatch, prefix, unclosed) => {
        return `${prefix}<span class="chat-quote">${unclosed}</span>`;
    });
    html = html.replace(/^(\u00AB(?:[^\u00BB])*?)$/gm, (fullMatch, unclosed) => {
        return `<span class="chat-quote">${unclosed}</span>`;
    });

    // 4. Markdown Parsing (in order of precedence)
    // Horizontal Rule on its own line
    html = html.replace(/^(_{3,}|-{3,}|\*{3,})$/gm, '<hr>');

    // Strikethrough
    html = html.replace(/~~([\s\S]+?)~~/g, '<del>$1</del>');

    // Bold and Italic
    html = html.replace(/\*\*\*([\s\S]+?)\*\*\*/g, '<strong><em>$1</em></strong>');

    // Bold
    html = html.replace(/\*\*([\s\S]+?)\*\*/g, '<strong>$1</strong>');

    // Italic/Action: *text* -> Gray
    html = html.replace(/\*([\s\S]+?)\*/g, '<em>$1</em>');

    // 5. Color styling for Actions
    // Color all em tags gray for actions
    html = html.replace(/<em>/g, '<em class="chat-italic">');

    // Restore CSS comments
    html = html.replace(/__CSS_COMMENT_(\d+)__/g, (match, index) => {
        return cssComments[index];
    });

    // 6. Paragraphs and Newlines
    // Ensure block-level placeholders are isolated to avoid being wrapped in <p> incorrectly
    html = html.replace(/\n?(__(?:CODE|STYLE|SCRIPT|TAG_BLOCK_BLOCK)_BLOCK_\d+__)\n?/g, '\n\n$1\n\n');

    const paragraphs = html.split(/\n\n+/);
    html = paragraphs
        .map(p => {
            let trimmed = p.trim();
            if (!trimmed) return "";

            // If the chunk is JUST a block-level placeholder, return it as is
            if (/^__(CODE|STYLE|SCRIPT|TAG_BLOCK_BLOCK)_BLOCK_\d+__$/.test(trimmed)) {
                return trimmed;
            }

            // For any chunk that STARTS with a block tag placeholder, do not wrap in <p>
            const startsWithBlock = /^__TAG_BLOCK_BLOCK_\d+__/.test(trimmed);

            // Clean up 'layout' newlines right next to tags before converting remaining ones to <br>
            trimmed = trimmed.replace(/(__TAG_BLOCK_(?:BLOCK_)?\d+__)\s*\n\s*/g, '$1 ');
            trimmed = trimmed.replace(/\s*\n\s*(__TAG_BLOCK_(?:BLOCK_)?\d+__)/g, ' $1');

            const content = trimmed.replace(/\n/g, '<br>');
            return startsWithBlock ? content : `<p>${content}</p>`;
        })
        .filter(p => p !== "")
        .join('');

    // 8. Restore HTML Tags
    html = html.replace(/__TAG_BLOCK_(?:BLOCK_)?(\d+)__/g, (match, index) => {
        return tagBlocks[index];
    });

    // Restore Unclosed Tag (Streaming)
    if (unclosedTag) {
        const escapedUnclosed = unclosedTag
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
        html = html.replace("__UNCLOSED_TAG__", `<span class="unclosed-tag">${escapedUnclosed}</span>`);
    }

    // Restore Style Blocks
    html = html.replace(/__STYLE_BLOCK_(\d+)__/g, (match, index) => {
        const block = styleBlocks[index];
        if (!block.isClosed) {
            // Render unclosed style as a code block to avoid broken CSS/raw text display
            const escapedContent = block.content.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            return `<pre class="code-block" data-lang="css"><code>&lt;style${block.attributes}&gt;${escapedContent}</code></pre>`;
        }
        return `<style${block.attributes}>${block.content}</style>`;
    });

    // Restore Script Blocks
    html = html.replace(/__SCRIPT_BLOCK_(\d+)__/g, (match, index) => {
        const block = scriptBlocks[index];
        if (!block.isClosed) {
            const escapedContent = block.content.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            return `<pre class="code-block" data-lang="javascript"><code>&lt;script${block.attributes}&gt;${escapedContent}</code></pre>`;
        }
        return `<script${block.attributes}>${block.content}</script>`;
    });

    // 7. Restore Code Blocks
    html = html.replace(/__CODE_BLOCK_(\d+)__/g, (match, index) => {
        const block = codeBlocks[index];
        // Escape HTML characters to display code literally
        const escapedCode = block.code
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");

        const content = `<pre class="code-block" data-lang="${block.lang}"><code>${escapedCode}</code></pre>`;
        // If unclosed, we might want to add a cursor or just leave as is
        return content;
    });

    return html;
}

export function formatInputPreview(text) {
    if (!text) return "";

    // Escape HTML
    let html = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

    // Strikethrough ~~text~~
    html = html.replace(/~~([\s\S]+?)~~/g, '<span class="md-strike">~~$1~~</span>');

    // Use entity to prevent re-matching of asterisks by subsequent regexes
    const AST = '&#42;';

    // Bold+Italic ***text***
    html = html.replace(/\*\*\*([\s\S]+?)\*\*\*/g, `<span class="md-bold-italic">${AST}${AST}${AST}$1${AST}${AST}${AST}</span>`);

    // Bold **text**
    html = html.replace(/\*\*([\s\S]+?)\*\*/g, `<span class="md-bold">${AST}${AST}$1${AST}${AST}</span>`);

    // Italic *text*
    html = html.replace(/\*([\s\S]+?)\*/g, `<span class="md-italic">${AST}$1${AST}</span>`);

    // Convert newlines to <br> for contenteditable (but avoid duplicates)
    // First, normalize any existing <br> tags to newlines temporarily
    html = html.replace(/<br\s*\/?>/gi, '\n');
    // Then convert all newlines to <br> (single conversion)
    html = html.replace(/\n/g, '<br>');

    return html;
}