// The chat page's look: the theme's CSS variables, the chat font and the
// in-page copy of the background. Shared by the chat page (Bridge) and the
// theme editor's preview page (theme_preview.js), so the preview paints with
// exactly the code the chat does.

/** 'bubble' or 'default' — the two layouts the page draws. */
export function normalizeLayout(layout) {
  const raw = String(layout || '').trim().toLowerCase();
  return (raw === 'bubble' || raw === 'bubbles') ? 'bubble' : 'default';
}

/**
 * Sets every entry of [theme] as a `--key` variable on the document, except
 * `chat-layout`, which switches the layout class of the container and of
 * every message on it.
 */
export function applyThemeVars(theme) {
  const container = document.getElementById('chat-container') || document.body;

  for (const [key, value] of Object.entries(theme)) {
    if (key === 'chat-layout') {
      const layout = normalizeLayout(value);
      container.classList.remove('layout-bubble', 'layout-default');
      container.classList.add(`layout-${layout}`);
      document.querySelectorAll('.message-section').forEach(el => {
        el.classList.remove('layout-bubble', 'layout-default');
        el.classList.add(`layout-${layout}`);
      });
      continue;
    }
    document.documentElement.style.setProperty(`--${key}`, value);
  }

  const toggleClass = (className, enabled) => {
    container.classList.toggle(className, !!enabled);
  };
  toggleClass('hide-user-avatar', theme['show-user-avatar'] === '0');
  toggleClass('hide-char-avatar', theme['show-char-avatar'] === '0');
  toggleClass('hide-user-name', theme['show-user-name'] === '0');
  toggleClass('hide-char-name', theme['show-char-name'] === '0');
}

export function setChatFont(fontFamily, fontDataUrl, fontSize, letterSpacing) {
  const root = document.documentElement;
  if (fontSize != null) {
    root.style.setProperty('--font-size', fontSize + 'px');
    root.style.setProperty('--chat-font-size', fontSize + 'px');
  }
  if (letterSpacing != null) {
    root.style.setProperty('--letter-spacing', letterSpacing + 'px');
    root.style.setProperty('--chat-letter-spacing', letterSpacing + 'px');
  }

  let fontFace = document.getElementById('custom-font-face');
  if (fontDataUrl) {
    if (!fontFace) {
      fontFace = document.createElement('style');
      fontFace.id = 'custom-font-face';
      document.head.appendChild(fontFace);
    }
    fontFace.textContent = `@font-face { font-family: '${fontFamily || 'CustomChatFont'}'; src: url('${fontDataUrl}'); font-display: swap; }`;
    root.style.setProperty('--font-family', `'${fontFamily || 'CustomChatFont'}', sans-serif`);
  } else {
    if (fontFace) fontFace.remove();
    if (fontFamily) root.style.setProperty('--font-family', fontFamily);
    else root.style.removeProperty('--font-family');
  }
}

/** The background image and noise layers at the bottom of the page. */
export class BackgroundLayers {
  constructor() {
    this._bgBlurToken = null;
    this._bgBlurCache = null;
    this._noiseCache = new Map();
  }

  setImage(url, blur) {
    // Duplicate the app background inside the WebView so its own
    // backdrop-filter blur regions have real pixels to sample — CSS
    // backdrop-filter can't see the natively-composited Flutter layer
    // behind the transparent WebView. Flutter keeps painting the same
    // background underneath as a fallback; this opaque copy sits on top.
    //
    // The bg blur must be BAKED into the image (offscreen canvas), not a
    // live `filter: blur()` on #bg-layer: a CSS filter turns the element
    // into a backdrop root (isolated composited layer), which excludes it
    // from every sibling backdrop-filter's sampling set — the overlay-blur
    // strips under the Flutter glass and the bubbles' element-blur would
    // silently go flat whenever bg blur is enabled.
    let bg = document.getElementById('bg-layer');
    if (!url) {
      this._bgBlurToken = null;
      if (bg) {
        bg.style.display = 'none';
        bg.style.backgroundImage = '';
      }
      return;
    }
    if (!bg) {
      bg = document.createElement('div');
      bg.id = 'bg-layer';
      document.body.insertBefore(bg, document.body.firstChild);
    }
    bg.style.display = 'block';
    // The layer stays fully opaque: darkening is the `--bg-dim` overlay in
    // #bg-layer::after. Fading the layer itself would let the transparent
    // WebView show the Flutter background painted behind it.
    bg.style.opacity = '';

    const b = Math.max(0, Number(blur) || 0);
    if (b <= 0) {
      this._bgBlurToken = null;
      bg.style.backgroundImage = `url("${url}")`;
      bg.style.filter = '';
      bg.style.inset = '0';
      return;
    }

    const cacheKey = `${b}|${url}`;
    if (this._bgBlurCache && this._bgBlurCache.key === cacheKey) {
      this._bgBlurToken = null;
      this._applyPreBlurredBg(bg, this._bgBlurCache.dataUrl);
      return;
    }

    // Immediate placeholder while the canvas render is in flight — and the
    // permanent fallback when canvas 2D filters are unsupported. CSS blur on
    // an inset:0 layer bleeds transparent (darkened) edges, unlike Flutter's
    // TileMode.clamp; overscan so the fringe falls outside the viewport.
    bg.style.backgroundImage = `url("${url}")`;
    bg.style.filter = `blur(${b}px)`;
    bg.style.inset = `-${b * 2}px`;

    const token = cacheKey;
    this._bgBlurToken = token;
    this._preBlurImage(url, b).then((dataUrl) => {
      if (!dataUrl) return; // canvas filter unsupported/failed → keep fallback
      this._bgBlurCache = { key: cacheKey, dataUrl };
      if (this._bgBlurToken !== token) return; // superseded by a newer call
      const layer = document.getElementById('bg-layer');
      if (!layer || layer.style.display === 'none') return;
      this._applyPreBlurredBg(layer, dataUrl);
    });
  }

  // Swap #bg-layer to the pre-blurred image with no live CSS filter.
  // #bg-layer transitions `filter` 0.3s; suppress it for the swap so the
  // baked blur + decaying live blur don't visibly stack.
  _applyPreBlurredBg(layer, dataUrl) {
    const prevTransition = layer.style.transition;
    layer.style.transition = 'none';
    layer.style.backgroundImage = `url("${dataUrl}")`;
    layer.style.filter = '';
    layer.style.inset = '0';
    void layer.offsetWidth; // flush so the un-transitioned state commits
    layer.style.transition = prevTransition;
  }

  // Renders [url] blurred into an offscreen canvas, once, at a capped working
  // resolution. Resolves to a data URL, or null when canvas 2D filters are
  // unavailable (older WKWebView) or the render fails — callers keep the live
  // CSS-filter fallback in that case.
  _preBlurImage(url, blur) {
    return new Promise((resolve) => {
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');
      if (!ctx || typeof ctx.filter !== 'string') {
        resolve(null);
        return;
      }
      const img = new Image();
      img.onload = () => {
        try {
          const iw = img.naturalWidth;
          const ih = img.naturalHeight;
          if (!iw || !ih) {
            resolve(null);
            return;
          }
          // The blur destroys detail anyway, so a capped resolution keeps
          // the canvas + data URL small; scale the radius to match.
          const scale = Math.min(1, 1536 / Math.max(iw, ih));
          const scaledBlur = Math.max(0.5, blur * scale);
          canvas.width = Math.max(1, Math.round(iw * scale));
          canvas.height = Math.max(1, Math.round(ih * scale));
          // Overscan: draw expanded by 2×blur per side so the transparent
          // blurred fringe lands outside the canvas and edges stay clamped
          // (Flutter TileMode.clamp equivalent), at the cost of a slight
          // zoom-crop.
          const pad = Math.ceil(scaledBlur * 2);
          ctx.filter = `blur(${scaledBlur}px)`;
          ctx.drawImage(
            img,
            -pad,
            -pad,
            canvas.width + pad * 2,
            canvas.height + pad * 2,
          );
          // WebP keeps the alpha channel (PNG wallpapers) unlike JPEG;
          // engines without a WebP encoder silently return PNG instead.
          resolve(canvas.toDataURL('image/webp', 0.9));
        } catch (_) {
          resolve(null);
        }
      };
      img.onerror = () => resolve(null);
      img.src = url;
    });
  }

  setNoise(opacity, intensity) {
    let noise = document.getElementById('bg-noise-layer');
    if (!noise) {
      noise = document.createElement('div');
      noise.id = 'bg-noise-layer';
      const bg = document.getElementById('bg-layer');
      if (bg && bg.nextSibling) {
        document.body.insertBefore(noise, bg.nextSibling);
      } else {
        document.body.insertBefore(noise, document.body.firstChild);
      }
    }
    const op = Math.max(0, Math.min(1, opacity || 0));
    if (op <= 0) {
      noise.style.display = 'none';
      noise.style.backgroundImage = '';
      return;
    }
    const i = Math.max(0, Math.min(2, intensity == null ? 1 : intensity));
    noise.style.display = 'block';
    noise.style.opacity = op;
    noise.style.backgroundImage = `url("${this._noiseTile(i)}")`;
    noise.style.backgroundSize = '128px 128px';
  }

  _noiseTile(intensity) {
    const key = intensity.toFixed(2);
    const hit = this._noiseCache.get(key);
    if (hit) return hit;
    const size = 128;
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = size;
    const ctx = canvas.getContext('2d');
    const img = ctx.createImageData(size, size);
    const data = img.data;
    for (let p = 0; p < data.length; p += 4) {
      const a = Math.min(1, Math.random() * intensity);
      data[p] = 255;
      data[p + 1] = 255;
      data[p + 2] = 255;
      data[p + 3] = Math.round(a * 255);
    }
    ctx.putImageData(img, 0, 0);
    const url = canvas.toDataURL('image/png');
    this._noiseCache.set(key, url);
    return url;
  }
}

/** The message-display switches the app's settings control. */
export function applyMessageSettingsClasses(s) {
  const container = document.getElementById('chat-container') || document.body;
  container.classList.toggle('battery-saver', !!s.batterySaver);
  container.classList.toggle('hide-message-id', !!s.hideMessageId);
  container.classList.toggle('hide-gen-time', !!s.hideGenerationTime);
  container.classList.toggle('hide-token-count', !!s.hideTokenCount);
  // Re-run cleaner is a Studio-only affordance — hide it when Studio is off.
  container.classList.toggle('hide-rerun-cleaner', !s.studioEnabled);
}
