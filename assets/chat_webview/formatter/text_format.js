export function renderStyledSegment(seg, processRichText) {
  // Variant C support: the captured inner content may contain raw HTML/Markdown
  // because html_to_markdown emits rich content inside ==hc:...== markers.
  let m = seg.match(/^==hc:(#[0-9a-fA-F]{3,8})==([\s\S]+?)==$/);
  if (m) {
    const color = m[1];
    const rich = processRichText ? processRichText(m[2]) : m[2];
    return `<span class="glaze-hc" style="color:${color}">${rich}</span>`;
  }

  m = seg.match(/^==glow:(#[0-9a-fA-F]{3,8}),(\d+)==([\s\S]+?)==$/);
  if (m) {
    const rich = processRichText ? processRichText(m[3]) : m[3];
    return `<span class="glaze-glow" style="text-shadow:${m[1]} 0 0 ${m[2]}px, ${m[1]} 0 0 ${parseInt(m[2])/2}px">${rich}</span>`;
  }

  m = seg.match(/^==cg:(#[0-9a-fA-F]{3,8}),([0-9a-fA-F]{3,8}),(\d+)==([\s\S]+?)==$/);
  if (m) {
    const rich = processRichText ? processRichText(m[4]) : m[4];
    return `<span class="glaze-cg" style="color:${m[1]};text-shadow:${m[2]} 0 0 ${m[3]}px, ${m[2]} 0 0 ${parseInt(m[3])/2}px">${rich}</span>`;
  }

  m = seg.match(/^==grad:(#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+)==([\s\S]+?)==$/);
  if (m) {
    const colors = m[1].match(/#[0-9a-fA-F]{3,8}/g);
    const gradient = colors.join(',');
    const rich = processRichText ? processRichText(m[2]) : m[2];
    return `<span class="glaze-grad" style="background:linear-gradient(90deg,${gradient});-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent">${rich}</span>`;
  }

  m = seg.match(/^==bg:(#[0-9a-fA-F]{3,8})==([\s\S]+?)==$/);
  if (m) {
    const rich = processRichText ? processRichText(m[2]) : m[2];
    return `<span class="glaze-bg" style="background:${m[1]};padding:1px 4px;border-radius:3px">${rich}</span>`;
  }

  m = seg.match(/^==mark==(.+?)==$/s);
  if (m) return `<span class="glaze-mark">${m[1]}</span>`;

  m = seg.match(/^==active==(.+?)==$/s);
  if (m) return `<span class="glaze-active">${m[1]}</span>`;

  m = seg.match(/^\*\*\*(.+?)\*\*\*$/s);
  if (m) return `<strong><em>${m[1]}</em></strong>`;
  m = seg.match(/^\*\*(.+?)\*\*$/s);
  if (m) return `<strong>${m[1]}</strong>`;
  m = seg.match(/^\*(.+?)\*$/s);
  if (m) return `<em class="chat-italic">${m[1]}</em>`;
  m = seg.match(/^__(.+?)__$/s);
  if (m) return `<strong>${m[1]}</strong>`;
  m = seg.match(/^_(.+?)_$/s);
  if (m) return `<em class="chat-italic">${m[1]}</em>`;
  m = seg.match(/^~~(.+?)~~$/s);
  if (m) return `<del>${m[1]}</del>`;

  return seg;
}
