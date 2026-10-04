// Block markdown: what a line of a message can be.
//
// Runs over one run of text, line by line. A construct is recognised only at
// the start of a line, which is what markdown means by "block", and the text
// it wraps goes through the inline pass. Elements are opaque placeholders
// here too, so a list item can hold a `<b>` and a table cell can hold a card
// without either pass reaching into the other.

import { SENTINEL } from './protect.js';

/**
 * A line that carries nothing but protected regions — never a paragraph.
 * Only `P_`: a style marker is inline content and belongs in a paragraph like
 * any other word.
 */
const ONLY_REGIONS = new RegExp(`^(?:${SENTINEL}P_\\d+${SENTINEL}|\\s)+$`);

const HEADING = /^(#{1,6})[ \t]+(.+?)[ \t]*#*$/;
const RULE = /^(_{3,}|-{3,}|\*{3,})$/;
const BULLET = /^([ \t]*)[-*] (.*)$/;
const NUMBERED = /^(\d+)\. (.*)$/;
const QUOTED = /^>[ \t]?(.*)$/;
const TABLE_ROW = /^[ \t]*\|.*\|[ \t]*$/;
const TABLE_SEPARATOR = /^[ \t]*\|[ \t:|-]+\|[ \t]*$/;

function renderList(items, inline) {
  // An indented item belongs to the list above it. Splitting the run at the
  // first indented line left it stranded as its own paragraph between two
  // lists; nesting it keeps the run one list.
  let out = '';
  let nested = false;
  let open = false;
  for (const item of items) {
    if (item.depth) {
      // The sub-list lives inside the item above it, which stays open until
      // the run ends or the next top-level item starts.
      if (!nested) { out += '<ul class="chat-list">'; nested = true; }
      out += `<li>${inline(item.text)}</li>`;
      continue;
    }
    if (nested) { out += '</ul>'; nested = false; }
    if (open) out += '</li>';
    out += `<li>${inline(item.text)}`;
    open = true;
  }
  if (nested) out += '</ul>';
  if (open) out += '</li>';
  return `<ul class="chat-list">${out}</ul>`;
}

function renderTable(rows, inline) {
  const cells = (row) => row.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
  const head = cells(rows[0]).map((c) => `<th>${inline(c)}</th>`).join('');
  const body = rows.slice(2)
    .map((row) => `<tr>${cells(row).map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`)
    .join('');
  return `<table class="chat-table"><thead><tr>${head}</tr></thead>` +
    `${body ? `<tbody>${body}</tbody>` : ''}</table>`;
}

/**
 * Renders one run of text.
 *
 * [paragraphs] wraps loose text in `<p>`. It is set only at the top level of a
 * message: inside markup the author wrote, a `<p>` of ours would reparent
 * their elements, and a card built on `#toggle:checked ~ .overlay` stops
 * working the moment its two halves stop being siblings.
 */
export function applyBlockSyntax(text, { inline, paragraphs }) {
  const lines = text.split('\n');
  const out = [];
  let pending = [];

  const flush = () => {
    while (pending.length && !pending[0].trim()) pending.shift();
    while (pending.length && !pending[pending.length - 1].trim()) pending.pop();
    if (!pending.length) return;
    const body = pending.map((line) => (line.trim() ? inline(line) : '')).join('<br>');
    const bare = pending.every((line) => ONLY_REGIONS.test(line) || !line.trim());
    out.push(paragraphs && !bare ? `<p>${body}</p>` : body);
    pending = [];
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (!line.trim()) {
      // A blank line ends a paragraph. Where nothing is wrapped in `<p>` it is
      // just another line break, and keeping it preserves the author's spacing.
      if (paragraphs) flush();
      else pending.push('');
      continue;
    }

    if (ONLY_REGIONS.test(line)) {
      // A protected region stands on its own: a `<p>` around an image block or
      // a code block is a `<p>` the browser immediately throws back out.
      flush();
      out.push(line.trim());
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      flush();
      const level = heading[1].length;
      out.push(`<h${level} class="chat-heading">${inline(heading[2])}</h${level}>`);
      continue;
    }

    if (RULE.test(line.trim())) {
      flush();
      out.push('<hr>');
      continue;
    }

    // A table needs its separator row: that is what tells a table from a line
    // of prose that happens to use pipes.
    if (TABLE_ROW.test(line) && TABLE_SEPARATOR.test(lines[i + 1] || '')) {
      flush();
      const rows = [line, lines[i + 1]];
      let j = i + 2;
      while (j < lines.length && TABLE_ROW.test(lines[j])) rows.push(lines[j++]);
      out.push(renderTable(rows, inline));
      i = j - 1;
      continue;
    }

    if (BULLET.test(line)) {
      flush();
      const items = [];
      let j = i;
      let match;
      while (j < lines.length && (match = BULLET.exec(lines[j])) !== null) {
        items.push({ depth: match[1].length ? 1 : 0, text: match[2] });
        j++;
      }
      out.push(renderList(items, inline));
      i = j - 1;
      continue;
    }

    if (NUMBERED.test(line)) {
      flush();
      const items = [];
      let j = i;
      let match;
      let start = 1;
      while (j < lines.length && (match = NUMBERED.exec(lines[j])) !== null) {
        if (!items.length) start = Number(match[1]);
        items.push(`<li>${inline(match[2])}</li>`);
        j++;
      }
      const startAttr = start === 1 ? '' : ` start="${start}"`;
      out.push(`<ol class="chat-list"${startAttr}>${items.join('')}</ol>`);
      i = j - 1;
      continue;
    }

    if (QUOTED.test(line)) {
      flush();
      const quoted = [];
      let j = i;
      let match;
      while (j < lines.length && (match = QUOTED.exec(lines[j])) !== null) {
        quoted.push(inline(match[1]));
        j++;
      }
      out.push(`<blockquote class="chat-blockquote">${quoted.join('<br>')}</blockquote>`);
      i = j - 1;
      continue;
    }

    pending.push(line);
  }

  flush();
  return out.join('');
}
