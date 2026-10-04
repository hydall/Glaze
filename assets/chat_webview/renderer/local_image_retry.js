/* One failed load of a locally served picture is not the picture's fault.
 *
 * Generated images, avatars, attachments and ext-block cards are all served by
 * the app's own loopback file server, and any of those fetches can lose a race
 * the file itself is not to blame for: the server is still answering an aborted
 * request from the render this one replaced, the WebView is mid-resize as a
 * reply settles, or the page mounted a moment before the file server was ready.
 * The browser never retries a failed <img>, so the element keeps its broken
 * glyph until something re-renders it — which for an ext-block card or an
 * avatar may be never.
 *
 * A couple of delayed attempts with a fresh query string turn that into a
 * picture that simply arrives a moment later. The file server reads only the
 * `path` query parameter, and a new URL sidesteps any cached failure.
 */

/** How many times a local image may re-request itself after a failure. */
export const LOCAL_IMAGE_RETRY_LIMIT = 2;

/** Backoff before the first retry; later attempts scale with the attempt. */
const LOCAL_IMAGE_RETRY_DELAY_MS = 350;

/** The app's per-launch loopback file endpoint, as the page receives it. */
const LOOPBACK_FILE_URL =
  /^https?:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?\/__glaze_file__\b/i;

/** The source an image should be re-requested from. */
function imageSource(img) {
  return img?.dataset?.src || img?.getAttribute?.('src') || '';
}

/** Whether [img] is a picture the app itself is serving. */
export function isLocalServedImage(img) {
  return LOOPBACK_FILE_URL.test(imageSource(img));
}

/**
 * Wires a bounded retry onto one local picture. Idempotent: an image already
 * wired keeps its single handler. Remote pictures are left alone — their URL
 * cannot be re-resolved, and a cache-busting parameter would only break it.
 */
export function scheduleLocalImageRetry(img) {
  if (!img || img.dataset?.retryWired) return;
  if (!isLocalServedImage(img)) return;
  img.dataset.retryWired = '1';
  img.addEventListener('error', () => {
    const source = imageSource(img);
    if (!source) return;
    const attempt = Number(img.dataset.retryAttempt || '0') + 1;
    if (attempt > LOCAL_IMAGE_RETRY_LIMIT) return;
    img.dataset.retryAttempt = String(attempt);
    setTimeout(() => {
      const base = imageSource(img);
      if (!base) return;
      const separator = base.includes('?') ? '&' : '?';
      img.src = `${base}${separator}__glaze_retry=${attempt}`;
    }, LOCAL_IMAGE_RETRY_DELAY_MS * attempt);
  });
}

/**
 * Wires the retry for every local picture under [root].
 *
 * Called wherever pictures are inserted — a message body, a message section
 * (avatars and attachments), an ext-block card — so an image that fails before
 * its point of insertion is registered is still caught the next time it is.
 * A shadow root is not pierced on purpose: `writeShadowContent` calls this on
 * the message's own root, which is where its pictures live.
 */
export function retryFailedLocalImages(root) {
  if (!root?.querySelectorAll) return;
  for (const img of root.querySelectorAll('img')) {
    scheduleLocalImageRetry(img);
  }
}
