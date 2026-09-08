const BLOCKED_ELEMENTS = new Set([
  'script', 'iframe', 'object', 'embed', 'form', 'math', 'meta',
  'link', 'base', 'style',
  // Preserve formatter-generated static <svg><path> icons, but reject SVG
  // features that can load resources, embed HTML, or trigger animation.
  'foreignobject', 'animate', 'animatemotion', 'animatetransform', 'set',
  'use', 'image', 'feimage',
]);

const URL_ATTRIBUTES = new Set([
  'href', 'src', 'xlink:href', 'action', 'formaction', 'poster',
]);

const SAFE_IMAGE_DATA_URL = /^data:image\/(?:png|jpe?g|webp|gif|avif);base64,/i;
const CSS_URL = /url\(\s*(['"]?)(.*?)\1\s*\)/gi;
const UNSAFE_CSS = /@import|expression\s*\(|behavior\s*:|-moz-binding\s*:/i;
const EXT_BLOCK_STYLE_PROPERTIES = new Set([
  'color', 'background', 'background-color', 'background-image',
  'font', 'font-family', 'font-size', 'font-style', 'font-weight',
  'line-height', 'letter-spacing', 'text-align', 'text-decoration',
  'text-shadow', 'white-space', 'word-break', 'overflow-wrap',
  'border', 'border-color', 'border-radius', 'border-style', 'border-width',
  'padding', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
  'display', 'gap', 'row-gap', 'column-gap', 'align-items',
  'justify-content', 'flex-direction', 'flex-wrap', 'opacity',
  '-webkit-background-clip', '-webkit-text-fill-color',
]);

function isSafeDataUrl(element, attributeName, value) {
  if (!SAFE_IMAGE_DATA_URL.test(value)) return false;
  const localName = element.localName.toLowerCase();
  return attributeName === 'src' &&
    (localName === 'img' || localName === 'source');
}

function hasUnsafeCssUrl(css) {
  if (UNSAFE_CSS.test(String(css || ''))) return true;
  CSS_URL.lastIndex = 0;
  // Inline CSS does not need network resources. Reject every url(), including
  // remote images, so untrusted HTML cannot beacon or exploit parser-specific
  // URL scheme quirks. Gradients and ordinary color styling remain available.
  return CSS_URL.test(String(css || ''));
}

function sanitizeStyleAttribute(element) {
  const raw = element.getAttribute('style') || '';
  if (hasUnsafeCssUrl(raw)) {
    element.removeAttribute('style');
    return;
  }
  // Message and ExtBlock HTML live in the privileged parent document. Keep
  // local visual formatting, but reject layout primitives that can cover or
  // impersonate the app UI (position/z-index/inset etc.).
  const safe = [];
  for (const declaration of raw.split(';')) {
    const colon = declaration.indexOf(':');
    if (colon <= 0) continue;
    const property = declaration.slice(0, colon).trim().toLowerCase();
    const value = declaration.slice(colon + 1).trim();
    if (!EXT_BLOCK_STYLE_PROPERTIES.has(property) || !value) continue;
    safe.push(`${property}: ${value}`);
  }
  if (safe.length) element.setAttribute('style', safe.join('; '));
  else element.removeAttribute('style');
}

function sanitizeHtml(html) {
  const template = document.createElement('template');
  template.innerHTML = String(html == null ? '' : html);

  for (const element of Array.from(template.content.querySelectorAll('*'))) {
    if (BLOCKED_ELEMENTS.has(element.localName.toLowerCase())) {
      element.remove();
      continue;
    }
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith('on') || name === 'srcdoc') {
        element.removeAttribute(attribute.name);
        continue;
      }
      if (name === 'style') {
        sanitizeStyleAttribute(element);
        continue;
      }
      if (!URL_ATTRIBUTES.has(name)) continue;
      const value = attribute.value.trim();
      const compact = value.replace(/[\u0000-\u0020]+/g, '').toLowerCase();
      if (compact.startsWith('javascript:') || compact.startsWith('vbscript:') ||
          (compact.startsWith('data:') &&
            !isSafeDataUrl(element, name, value))) {
        element.removeAttribute(attribute.name);
      }
    }
    if (element.hasAttribute('srcset')) {
      const candidates = element.getAttribute('srcset').split(',');
      const unsafe = candidates.some(candidate => {
        const value = candidate.trim().split(/\s+/)[0] || '';
        const compact = value.replace(/[\u0000-\u0020]+/g, '').toLowerCase();
        return compact.startsWith('javascript:') ||
          compact.startsWith('vbscript:') ||
          (compact.startsWith('data:') && !SAFE_IMAGE_DATA_URL.test(value));
      });
      if (unsafe) element.removeAttribute('srcset');
    }
  }

  return template.innerHTML;
}

export function sanitizeMessageHtml(html) {
  return sanitizeHtml(html);
}

export function sanitizeExtBlockHtml(html) {
  return sanitizeHtml(html);
}
