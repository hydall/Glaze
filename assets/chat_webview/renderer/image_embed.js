export function createImageAttachment(src, hidden, icon) {
  const wrap = document.createElement('div');
  wrap.className = 'msg-image-attachment';

  const img = document.createElement('img');
  img.src = src;
  img.alt = 'attachment';
  img.loading = 'lazy';
  wrap.appendChild(img);

  const toggle = document.createElement('div');
  toggle.className = 'image-ctx-toggle';
  toggle.dataset.action = 'toggle-image-hidden';
  wrap.appendChild(toggle);

  applyToggleState(wrap, toggle, hidden, icon);
  return wrap;
}

// Re-applies the attachment's visibility state in place — used when Flutter
// pushes an `imageHidden` change through `updateMessage` instead of a full
// re-render. `hidden` means "not sent to the model"; the picture itself stays
// on screen either way.
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
