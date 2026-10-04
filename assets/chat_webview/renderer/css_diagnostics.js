import { withParsedSheet } from '../bridge/css_sanitizer.js';

// Tells the author of a card that its CSS did not survive the parser.
//
// Message CSS is inserted verbatim (see html_sanitizer.js), so a missing `}` or
// a selector the engine does not understand simply produces a card that renders
// wrong, with nothing on screen to say why — and the model that wrote it never
// finds out either. This pass only *reads* the `<style>` blocks a message
// carries and appends a short report; it never rewrites the CSS.

/** Problems shown per message — a broken block must not fill the bubble. */
const MAX_REPORTED = 5;

/** Longest selector text echoed back into the report. */
const MAX_SELECTOR_LENGTH = 48;

// A streaming reply re-renders its message on every chunk with the same
// `<style>` block, so results are memoized (FIFO, same shape as the CSS
// parser cache in css_sanitizer.js).
const CACHE_MAX_SIZE = 200;
const cache = new Map();

const OPENING_BRACKET = { '}': '{', ')': '(', ']': '[' };

function countNewlines(text, from, to) {
  let count = 0;
  for (let i = from; i < to; i++) {
    if (text[i] === '\n') count++;
  }
  return count;
}

function shorten(text) {
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > MAX_SELECTOR_LENGTH
    ? `${flat.slice(0, MAX_SELECTOR_LENGTH - 1)}…`
    : flat;
}

/** Index of the quote closing the string that starts at [start], or -1. */
function endOfString(css, start) {
  const quote = css[start];
  for (let i = start + 1; i < css.length; i++) {
    if (css[i] === '\\') {
      i++;
      continue;
    }
    if (css[i] === quote) return i;
  }
  return -1;
}

// One pass over the source: counts lines, skips comments and strings, and pairs
// the brackets. Returns the structural problems and — when the source is
// balanced — its top-level blocks, which the rule check below re-parses one by
// one. A structural problem stops the walk: past an unclosed brace every later
// position is guesswork.
function scanStructure(css) {
  const problems = [];
  const blocks = [];
  const stack = [];
  let line = 1;
  let blockStart = 0;
  let i = 0;

  while (i < css.length) {
    const char = css[i];
    if (char === '\n') {
      line++;
      i++;
      continue;
    }
    if (char === '\\') {
      if (css[i + 1] === '\n') line++;
      i += 2;
      continue;
    }
    if (char === '/' && css[i + 1] === '*') {
      const end = css.indexOf('*/', i + 2);
      if (end === -1) {
        problems.push({ line, message: 'unterminated comment' });
        return { problems, blocks: [] };
      }
      line += countNewlines(css, i, end);
      i = end + 2;
      continue;
    }
    if (char === '"' || char === "'") {
      const end = endOfString(css, i);
      if (end === -1) {
        problems.push({ line, message: `unterminated string ${char}` });
        return { problems, blocks: [] };
      }
      line += countNewlines(css, i, end);
      i = end + 1;
      continue;
    }
    if (char === '{' || char === '(' || char === '[') {
      stack.push({ char, line });
      i++;
      continue;
    }
    if (char === '}' || char === ')' || char === ']') {
      const open = stack.pop();
      if (!open || open.char !== OPENING_BRACKET[char]) {
        problems.push({ line, message: `unexpected "${char}"` });
        return { problems, blocks: [] };
      }
      if (char === '}' && stack.length === 0) {
        blocks.push({ text: css.slice(blockStart, i + 1), line: open.line });
        blockStart = i + 1;
      }
      i++;
      continue;
    }
    i++;
  }

  for (const open of stack) {
    problems.push({ line: open.line, message: `unclosed "${open.char}"` });
  }
  return { problems, blocks };
}

// Rules the engine threw away. The whole sheet is parsed first — when it keeps
// as many rules as the source has blocks, nothing was lost and no block has to
// be re-parsed. `@import` and other braceless at-rules are not counted as
// blocks, so dropping them cannot fake a loss here.
function droppedRules(css, blocks) {
  if (!blocks.length) return [];
  const parsed = withParsedSheet(css, sheet => sheet.cssRules.length);
  if (parsed == null || parsed >= blocks.length) return [];

  const dropped = [];
  for (const block of blocks) {
    const kept = withParsedSheet(block.text, sheet => sheet.cssRules.length > 0);
    if (kept !== false) continue;
    const brace = block.text.indexOf('{');
    const selector = brace > 0 ? shorten(block.text.slice(0, brace)) : '';
    dropped.push({
      line: block.line,
      message: selector ? `rule ignored: ${selector}` : 'rule ignored',
    });
  }
  return dropped;
}

/**
 * At-rules the CSS policy drops before the message is rendered.
 *
 * Not `@import`: that one is lifted into the document head instead
 * (renderer/message_document.js, INV-MR5). These three have nowhere to go —
 * the card author saw only a rule that did nothing, so the drop is reported
 * rather than hidden. Read from the *pre-sanitize* source: by the time the
 * style element exists, the rule is already gone.
 */
const BLOCKED_AT_RULE = /@(font-face|page|namespace)\b/gi;

export function inspectBlockedAtRules(css) {
  const source = String(css == null ? '' : css);
  const found = [];
  BLOCKED_AT_RULE.lastIndex = 0;
  let match;
  while ((match = BLOCKED_AT_RULE.exec(source)) !== null) {
    const line = countNewlines(source, 0, match.index) + 1;
    found.push(
      `line ${line}: @${match[1].toLowerCase()} is not applied ` +
      '(message CSS cannot load anything over the network)',
    );
    if (found.length >= MAX_REPORTED) break;
  }
  return found;
}

/** Problems in one `<style>` block, as lines ready to show. */
export function inspectCss(css) {
  const source = String(css == null ? '' : css);
  if (!source.trim()) return [];
  if (cache.has(source)) return cache.get(source);

  const { problems, blocks } = scanStructure(source);
  // A structural problem makes the parse unreliable, so the rule check only
  // runs on sources that are at least balanced.
  const found = problems.length ? problems : droppedRules(source, blocks);
  const result = found.map(problem => `line ${problem.line}: ${problem.message}`);

  if (cache.size >= CACHE_MAX_SIZE) cache.delete(cache.keys().next().value);
  cache.set(source, result);
  return result;
}

function buildReport(problems) {
  const box = document.createElement('div');
  box.className = 'glaze-css-error';

  const head = document.createElement('div');
  head.className = 'glaze-css-error-head';
  head.textContent = 'CSS ERROR';
  box.appendChild(head);

  for (const problem of problems.slice(0, MAX_REPORTED)) {
    const item = document.createElement('div');
    item.className = 'glaze-css-error-item';
    // textContent: the line quotes a selector the message wrote.
    item.textContent = problem;
    box.appendChild(item);
  }

  const hidden = problems.length - MAX_REPORTED;
  if (hidden > 0) {
    const more = document.createElement('div');
    more.className = 'glaze-css-error-item';
    more.textContent = `+${hidden} more`;
    box.appendChild(more);
  }

  return box;
}

/**
 * Appends a CSS report to [root] when the message carries broken `<style>`.
 *
 * Called after the message HTML is in place, on a root that was just rewritten
 * from scratch — so a stale report cannot survive and the pass is a no-op for
 * the overwhelming majority of messages, which carry no `<style>` at all.
 */
export function reportCssErrors(root, extraProblems = []) {
  if (!root) return;
  const styles = root.querySelectorAll('style');
  if (!styles.length && !extraProblems.length) return;

  const problems = [...extraProblems];
  for (const style of styles) {
    problems.push(...inspectCss(style.textContent));
  }
  if (!problems.length) return;

  root.appendChild(buildReport(problems));
}
