import { ICON } from './icon_library.js';

/* ============================================================
 * TTS voice pill — the messenger-style voice note drawn under a message's
 * avatar and name while TTS is on:
 *
 *   .msg-tts[data-tts-state=idle|loading|ready|playing|error]
 *     button.msg-tts-btn[data-action=tts-toggle]   play / stop / spinner
 *     .msg-tts-wave > span × N                      bars, .played while playing
 *     .msg-tts-time                                 duration, or elapsed
 *
 * State comes from Flutter as a compact map: { s, d?, p?, e? } — status,
 * duration in ms, peaks as 0..100 integers, error text.
 * ============================================================ */

const PLACEHOLDER_BARS = 32;

export function formatTtsTime(ms) {
  if (ms == null || !isFinite(ms) || ms < 0) return '';
  const total = Math.round(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

export function createTtsPill(messageId, state) {
  const pill = document.createElement('div');
  pill.className = 'msg-tts';
  pill.dataset.messageId = messageId;

  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'msg-tts-btn';
  btn.dataset.action = 'tts-toggle';
  btn.dataset.messageId = messageId;
  pill.appendChild(btn);

  const wave = document.createElement('div');
  wave.className = 'msg-tts-wave';
  pill.appendChild(wave);

  const time = document.createElement('span');
  time.className = 'msg-tts-time';
  pill.appendChild(time);

  applyTtsState(pill, state || { s: 'idle' });
  return pill;
}

function renderBars(wave, peaks) {
  const values = peaks && peaks.length
    ? peaks
    : new Array(PLACEHOLDER_BARS).fill(18);
  const key = values.join(',');
  if (wave.dataset.peaks === key) return;
  wave.dataset.peaks = key;
  wave.textContent = '';
  wave.classList.toggle('placeholder', !(peaks && peaks.length));
  for (const v of values) {
    const bar = document.createElement('span');
    bar.style.height = `${Math.max(12, Math.min(100, v))}%`;
    wave.appendChild(bar);
  }
}

export function applyTtsState(pill, state) {
  const status = state.s || 'idle';
  pill.dataset.ttsState = status;
  pill.hidden = status === 'none';
  pill.title = status === 'error' ? (state.e || '') : '';
  if (state.d != null) pill.dataset.duration = String(state.d);
  else delete pill.dataset.duration;

  const btn = pill.querySelector('.msg-tts-btn');
  if (btn) {
    btn.innerHTML = status === 'playing' || status === 'loading' ? ICON.stop : ICON.play;
  }
  const wave = pill.querySelector('.msg-tts-wave');
  if (wave) renderBars(wave, state.p);
  if (status !== 'playing') setTtsProgress(pill, 0, null);

  const time = pill.querySelector('.msg-tts-time');
  if (time) {
    time.textContent = status === 'error'
      ? '!'
      : formatTtsTime(state.d);
  }
}

/** Marks played bars and shows elapsed time while a pill plays. */
export function setTtsProgress(pill, positionMs, durationMs) {
  const duration = durationMs ?? (pill.dataset.duration ? Number(pill.dataset.duration) : null);
  const bars = pill.querySelectorAll('.msg-tts-wave > span');
  const ratio = duration ? Math.max(0, Math.min(1, positionMs / duration)) : 0;
  const played = Math.round(ratio * bars.length);
  bars.forEach((bar, i) => bar.classList.toggle('played', i < played));
  if (positionMs > 0) {
    const time = pill.querySelector('.msg-tts-time');
    if (time) time.textContent = formatTtsTime(positionMs);
  }
}

/**
 * Decodes compressed audio with the WebView's decoder and returns its
 * duration and [buckets] normalised peaks (0..1), for formats Dart cannot
 * read on its own.
 */
export async function decodeTtsPeaks(base64, mime, buckets) {
  const Ctx = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  if (!Ctx) return null;
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const ctx = new Ctx(1, 1, 44100);
  const audio = await ctx.decodeAudioData(bytes.buffer);
  const n = Math.max(1, buckets || 64);
  const peaks = new Array(n).fill(0);
  const per = Math.max(1, Math.ceil(audio.length / n));
  for (let ch = 0; ch < audio.numberOfChannels; ch++) {
    const data = audio.getChannelData(ch);
    const stride = Math.max(1, Math.floor(per / 256));
    for (let i = 0; i < data.length; i += stride) {
      const b = Math.min(n - 1, Math.floor(i / per));
      const v = Math.abs(data[i]);
      if (v > peaks[b]) peaks[b] = v;
    }
  }
  const max = Math.max(...peaks);
  return {
    durationMs: Math.round(audio.duration * 1000),
    peaks: peaks.map((p) => (max > 0 ? Math.max(0.08, p / max) : 0.08)),
  };
}
