/* Counts with a layout of their own; past this the grid falls back to the
 * three-up `count-many` rule, which grows downwards for any number. */
const NAMED_LAYOUTS = 4;

/* One attachment block per message, holding every image the message carries.
 *
 * It stays a single element on purpose: `updateMessage` lifts `.msg-image-
 * attachment` out of the body and puts it back around the re-rendered text,
 * the eye toggle covers the whole message (there is one `imageHidden` flag),
 * and the click handler resolves the picture the reader actually hit from the
 * `<img>` under the pointer. */
export function createImageAttachments(sources, hidden, icon) {
  const paths = (Array.isArray(sources) ? sources : [sources])
    .filter((src) => typeof src === 'string' && src);
  if (!paths.length) return null;

  const wrap = document.createElement('div');
  wrap.className = 'msg-image-attachment';
  wrap.classList.add(
    paths.length <= NAMED_LAYOUTS ? `count-${paths.length}` : 'count-many',
  );
  // The grid layouts start at two: one image keeps the free-size block it has
  // always had, so a portrait screenshot is not cropped into a square.
  if (paths.length > 1) wrap.classList.add('multi');

  for (const src of paths) {
    const img = document.createElement('img');
    img.src = src;
    img.alt = 'attachment';
    img.loading = 'lazy';
    wrap.appendChild(img);
  }

  const toggle = document.createElement('div');
  toggle.className = 'image-ctx-toggle';
  toggle.dataset.action = 'toggle-image-hidden';
  wrap.appendChild(toggle);

  applyToggleState(wrap, toggle, hidden, icon);
  return wrap;
}

// Re-applies the attachment's visibility state in place — used when Flutter
// pushes an `imageHidden` change through `updateMessage` instead of a full
// re-render. `hidden` means "not sent to the model"; the pictures themselves
// stay on screen either way.
export function setImageAttachmentHidden(wrap, hidden, icon) {
  if (!wrap) return;
  applyToggleState(wrap, wrap.querySelector('.image-ctx-toggle'), hidden, icon);
}

function applyToggleState(wrap, toggle, hidden, icon) {
  wrap.classList.toggle('image-hidden', !!hidden);
  if (!toggle) return;
  toggle.innerHTML = hidden ? icon.hidden : icon.eye;
  toggle.title = hidden ? 'Hidden from the model' : 'Sent to the model';
}
