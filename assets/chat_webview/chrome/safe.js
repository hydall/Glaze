// Platform primitives the chat chrome uses, captured before anything else in
// the page runs.
//
// The chrome (header, composer, drawer) shares its page with the messages, and
// a message may run its own `<script>` once the user allows it. Such a script
// can patch any prototype it likes: wrap `Node.prototype.appendChild`, a
// `textContent` setter or `Event.prototype.preventDefault`, and every call the
// chrome made through the patched member would hand the script one of the
// chrome's own nodes — and with it the closed shadow root the chrome lives in.
//
// So the chrome never calls a DOM member through the prototype chain. Every
// method, getter and setter it needs is taken here, at module evaluation —
// this is the first module the page loads, long before a message is rendered
// — and called through a bound `Function.prototype.call`, which looks nothing
// up when it runs. Adding a DOM call to the chrome means adding it here.

const call = Function.prototype.call;
const uncurry = (fn) => call.bind(fn);
const desc = (target, name) => {
  let o = target;
  while (o) {
    const d = Object.getOwnPropertyDescriptor(o, name);
    if (d) return d;
    o = Object.getPrototypeOf(o);
  }
  throw new Error(`chrome: no ${name}`);
};
const getter = (target, name) => uncurry(desc(target, name).get);
const setter = (target, name) => uncurry(desc(target, name).set);

const doc = document;
const win = window;

export const freeze = Object.freeze;
export const defineProperty = Object.defineProperty;
export const jsonParse = JSON.parse;
export const jsonStringify = JSON.stringify;
export const mathMax = Math.max;
export const mathMin = Math.min;
export const mathRound = Math.round;
export const mathRandom = Math.random;
export const mathCeil = Math.ceil;
export const mathFloor = Math.floor;
export const mathAbs = Math.abs;
export const mathPow = Math.pow;
export const isArray = Array.isArray;
export const numberIsFinite = Number.isFinite;
export const stringFn = String;
export const now = uncurry(Performance.prototype.now).bind(null, performance);
export const dateNow = Date.now;

const createElementRaw = uncurry(Document.prototype.createElement);
const createElementNSRaw = uncurry(Document.prototype.createElementNS);
export const createElement = (tag) => createElementRaw(doc, tag);
export const createSvg = (tag) => createElementNSRaw(doc, 'http://www.w3.org/2000/svg', tag);
const createTextNodeRaw = uncurry(Document.prototype.createTextNode);
export const createText = (text) => createTextNodeRaw(doc, text);
export const attachShadow = uncurry(Element.prototype.attachShadow);
export const setAttribute = uncurry(Element.prototype.setAttribute);
export const removeAttribute = uncurry(Element.prototype.removeAttribute);
export const getAttribute = uncurry(Element.prototype.getAttribute);
export const appendChild = uncurry(Node.prototype.appendChild);
export const insertBefore = uncurry(Node.prototype.insertBefore);
export const removeChild = uncurry(Node.prototype.removeChild);
export const getParentNode = getter(Node.prototype, 'parentNode');
export const getFirstChild = getter(Node.prototype, 'firstChild');
export const getNextSibling = getter(Node.prototype, 'nextSibling');
export const getNodeType = getter(Node.prototype, 'nodeType');
export const getIsConnected = getter(Node.prototype, 'isConnected');
export const setTextContent = setter(Node.prototype, 'textContent');
export const getBoundingClientRect = uncurry(Element.prototype.getBoundingClientRect);
export const getScrollHeight = getter(Element.prototype, 'scrollHeight');
export const getScrollWidth = getter(Element.prototype, 'scrollWidth');
export const getClientWidth = getter(Element.prototype, 'clientWidth');
export const getScrollLeft = getter(Element.prototype, 'scrollLeft');
export const setScrollLeft = setter(Element.prototype, 'scrollLeft');
export const getScrollTop = getter(Element.prototype, 'scrollTop');
export const setScrollTop = setter(Element.prototype, 'scrollTop');
export const getOffsetHeight = getter(HTMLElement.prototype, 'offsetHeight');
export const focusRaw = uncurry(HTMLElement.prototype.focus);
export const blurRaw = uncurry(HTMLElement.prototype.blur);
export const setPointerCapture = uncurry(Element.prototype.setPointerCapture);
export const releasePointerCapture = uncurry(Element.prototype.releasePointerCapture);
const styleOf = getter(HTMLElement.prototype, 'style');
const svgStyleOf = getter(SVGElement.prototype, 'style');
const setPropertyRaw = uncurry(CSSStyleDeclaration.prototype.setProperty);
const removePropertyRaw = uncurry(CSSStyleDeclaration.prototype.removeProperty);
export const setStyle = (el, prop, value) => {
  const decl = el instanceof SVGElement ? svgStyleOf(el) : styleOf(el);
  if (value === null || value === undefined || value === '') removePropertyRaw(decl, prop);
  else setPropertyRaw(decl, prop, stringFn(value));
};

export const getActiveElementOfRoot = getter(ShadowRoot.prototype, 'activeElement');

// Form fields.
export const getValue = getter(HTMLTextAreaElement.prototype, 'value');
export const setValue = setter(HTMLTextAreaElement.prototype, 'value');
export const getInputValue = getter(HTMLInputElement.prototype, 'value');
export const setInputValue = setter(HTMLInputElement.prototype, 'value');
export const getSelectionStart = getter(HTMLTextAreaElement.prototype, 'selectionStart');
export const getSelectionEnd = getter(HTMLTextAreaElement.prototype, 'selectionEnd');
export const setSelectionRange = uncurry(HTMLTextAreaElement.prototype.setSelectionRange);
export const setRangeText = uncurry(HTMLTextAreaElement.prototype.setRangeText);

// Events. `isTrusted` is an unforgeable own property of every event, so it
// needs no capture.
const addEventListenerRaw = uncurry(EventTarget.prototype.addEventListener);
export const on = (target, type, fn, opts) => addEventListenerRaw(target, type, fn, opts);
export const preventDefault = uncurry(Event.prototype.preventDefault);
export const eventTarget = getter(Event.prototype, 'target');
export const stopPropagation = uncurry(Event.prototype.stopPropagation);
export const clientX = getter(MouseEvent.prototype, 'clientX');
export const clientY = getter(MouseEvent.prototype, 'clientY');
export const mouseButton = getter(MouseEvent.prototype, 'button');
export const pointerId = getter(PointerEvent.prototype, 'pointerId');
export const pointerType = getter(PointerEvent.prototype, 'pointerType');
export const keyOf = getter(KeyboardEvent.prototype, 'key');
export const shiftKeyOf = getter(KeyboardEvent.prototype, 'shiftKey');
export const keyIsComposing = getter(KeyboardEvent.prototype, 'isComposing');
export const inputTypeOf = getter(InputEvent.prototype, 'inputType');
export const inputIsComposing = getter(InputEvent.prototype, 'isComposing');
export const clipboardDataOf = getter(ClipboardEvent.prototype, 'clipboardData');
// Desktop engines without touch input have no TouchEvent at all.
const hasTouch = typeof TouchEvent === 'function' && typeof TouchList === 'function' &&
  typeof Touch === 'function';
const touchesOf = hasTouch ? getter(TouchEvent.prototype, 'touches') : null;
const touchListLength = hasTouch ? getter(TouchList.prototype, 'length') : null;
const touchListItem = hasTouch ? uncurry(TouchList.prototype.item) : null;
const touchClientY = hasTouch ? getter(Touch.prototype, 'clientY') : null;
/** The first touch's clientY, or null. Touch objects carry their target. */
export const firstTouchY = (e) => {
  if (!hasTouch) return null;
  const list = touchesOf(e);
  if (!list || touchListLength(list) < 1) return null;
  return touchClientY(touchListItem(list, 0));
};
export const deltaXOf = getter(WheelEvent.prototype, 'deltaX');
export const deltaYOf = getter(WheelEvent.prototype, 'deltaY');
const dtFiles = getter(DataTransfer.prototype, 'files');
const dtTypes = getter(DataTransfer.prototype, 'types');
const fileListLength = getter(FileList.prototype, 'length');
const fileListItem = uncurry(FileList.prototype.item);
const fileType = getter(Blob.prototype, 'type');
export const clipboardFiles = (dt) => {
  const out = [];
  if (!dt) return out;
  const list = dtFiles(dt);
  const n = fileListLength(list);
  for (let i = 0; i < n; i++) out[out.length] = fileListItem(list, i);
  return out;
};
export const clipboardHasText = (dt) => {
  if (!dt) return false;
  const types = dtTypes(dt);
  for (let i = 0; i < types.length; i++) {
    if (types[i] === 'text/plain' || types[i] === 'text/html') return true;
  }
  return false;
};
export const blobType = (blob) => fileType(blob);
const FileReaderCtor = FileReader;
const readAsDataURL = uncurry(FileReader.prototype.readAsDataURL);
const readerResult = getter(FileReader.prototype, 'result');
export const readDataUrl = (blob) => new Promise((resolve) => {
  const reader = new FileReaderCtor();
  on(reader, 'load', () => resolve(readerResult(reader)));
  on(reader, 'error', () => resolve(null));
  readAsDataURL(reader, blob);
});

// Observers.
const ResizeObserverCtor = typeof ResizeObserver === 'function' ? ResizeObserver : null;
const roObserve = ResizeObserverCtor ? uncurry(ResizeObserverCtor.prototype.observe) : null;
export const observeResize = (el, fn) => {
  if (!ResizeObserverCtor) return;
  // The callback's entries carry the element; they are never handed on.
  roObserve(new ResizeObserverCtor(() => fn()), el);
};
const MutationObserverCtor = MutationObserver;
const moObserve = uncurry(MutationObserver.prototype.observe);
export const observeMutations = (target, opts, fn) => {
  moObserve(new MutationObserverCtor(() => fn()), target, opts);
};

// Timers.
export const raf = win.requestAnimationFrame.bind(win);
export const cancelRaf = win.cancelAnimationFrame.bind(win);
export const setTimer = win.setTimeout.bind(win);
export const clearTimer = win.clearTimeout.bind(win);
export const viewportHeight = getter(win, 'innerHeight').bind(null, win);
export const matchMedia = win.matchMedia ? win.matchMedia.bind(win) : null;

// Popover / top layer and document roots.
const hasPopover = typeof HTMLElement.prototype.showPopover === 'function';
export const showPopover = hasPopover ? uncurry(HTMLElement.prototype.showPopover) : null;
export const hidePopover = hasPopover ? uncurry(HTMLElement.prototype.hidePopover) : null;
export const matches = uncurry(Element.prototype.matches);
export const bodyOf = () => getter(Document.prototype, 'body')(doc);
export const documentElement = getter(Document.prototype, 'documentElement')(doc);
export const getElementById = (id) => uncurry(Document.prototype.getElementById)(doc, id);

// Random ids for the host tag and the font family. crypto when there is one.
const cryptoObj = win.crypto;
const getRandomValues = cryptoObj && cryptoObj.getRandomValues
  ? uncurry(cryptoObj.getRandomValues).bind(null, cryptoObj)
  : null;
export function randomToken(len = 24) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let out = '';
  if (getRandomValues) {
    const bytes = new Uint8Array(len);
    getRandomValues(bytes);
    for (let i = 0; i < len; i++) out += alphabet[bytes[i] % alphabet.length];
    return out;
  }
  for (let i = 0; i < len; i++) out += alphabet[mathFloor(mathRandom() * alphabet.length)];
  return out;
}

// The Flutter transport, taken as early as it exists.
let flutterCall = null;
function bindFlutter() {
  const fiw = win.flutter_inappwebview;
  if (fiw && typeof fiw.callHandler === 'function') {
    flutterCall = fiw.callHandler.bind(fiw);
  }
}
bindFlutter();
export function callFlutter(name, ...args) {
  if (!flutterCall) bindFlutter();
  if (flutterCall) flutterCall(name, ...args);
}

// FontFace for the chrome's own UI font.
const FontFaceCtor = typeof FontFace === 'function' ? FontFace : null;
const fontFaceLoad = FontFaceCtor ? uncurry(FontFaceCtor.prototype.load) : null;
const fontSet = doc.fonts && typeof FontFaceSet === 'function' ? doc.fonts : null;
const fontsAdd = fontSet ? uncurry(FontFaceSet.prototype.add).bind(null, fontSet) : null;
const fontsDelete = fontSet ? uncurry(FontFaceSet.prototype.delete).bind(null, fontSet) : null;
export const onFontsLoaded = (fn) => {
  if (fontSet) on(fontSet, 'loadingdone', () => fn());
};
export function loadFont(family, source, descriptors) {
  if (!FontFaceCtor || !fontsAdd) return null;
  try {
    const face = new FontFaceCtor(family, `url("${source}")`, descriptors || {});
    fontsAdd(face);
    fontFaceLoad(face).catch(() => {});
    return face;
  } catch (_) {
    return null;
  }
}
export function unloadFont(face) {
  if (face && fontsDelete) fontsDelete(face);
}

// Noise tiles for the glass, painted on a canvas once per alpha.
const canvasGetContext = uncurry(HTMLCanvasElement.prototype.getContext);
const canvasToDataURL = uncurry(HTMLCanvasElement.prototype.toDataURL);
const ctxCreateImageData = uncurry(CanvasRenderingContext2D.prototype.createImageData);
const ctxPutImageData = uncurry(CanvasRenderingContext2D.prototype.putImageData);
const imageDataData = getter(ImageData.prototype, 'data');
export function noiseTile(cells, alphaScale) {
  const canvas = createElement('canvas');
  setAttribute(canvas, 'width', stringFn(cells));
  setAttribute(canvas, 'height', stringFn(cells));
  const ctx = canvasGetContext(canvas, '2d');
  if (!ctx) return null;
  const img = ctxCreateImageData(ctx, cells, cells);
  const data = imageDataData(img);
  // Seeded, so every surface and every reload grains the same way.
  let seed = 42;
  for (let i = 0; i < cells * cells; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    const v = seed / 0x7fffffff;
    data[i * 4 + 3] = mathRound(mathMin(1, v * alphaScale) * 255);
  }
  ctxPutImageData(ctx, img, 0, 0);
  return canvasToDataURL(canvas, 'image/png');
}
