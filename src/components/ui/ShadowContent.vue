<script setup>
import { ref, onMounted, onUnmounted, watch, nextTick } from 'vue';
import RollingNumber from '@/components/ui/RollingNumber.vue';

const props = defineProps({
  html: { type: String, required: true },
  isSelected: { type: Boolean, default: false }
});

const container = ref(null);
let shadow = null;
let contentDiv = null;
let timerRafId = null;

const activeTimers = ref([]);

const updateTimers = () => {
  if (activeTimers.value.length > 0) {
    const now = Date.now();
    activeTimers.value.forEach(t => {
      if (t.start) {
        const newVal = ((now - t.start) / 1000).toFixed(1) + 's';
        if (t.value !== newVal) {
          t.value = newVal;
        }
      }
    });
  }
  timerRafId = requestAnimationFrame(updateTimers);
};

const getStyles = () => `
  :host {
    display: block;
    font-size: inherit;
    line-height: inherit;
    color: inherit;
    word-break: break-word;
    min-width: 0;
  }
  .content {
    width: 100%;
    min-width: 0;
    user-select: var(--user-select, none);
    -webkit-user-select: var(--user-select, none);
  }
  p {
    margin: 0;
    margin-bottom: 0.8em;
  }
  p:last-child {
    margin-bottom: 0;
  }
  em {
    font-style: italic;
  }
  strong {
    font-weight: bold;
  }
  pre.code-block {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.1);
    padding: 10px;
    border-radius: 8px;
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 0.9em;
    overflow-x: auto;
    margin: 10px 0;
    white-space: pre-wrap;
    color: inherit;
  }
  hr {
    border: none;
    border-top: 1px solid rgba(var(--text-gray-rgb, 0,0,0), 0.1);
    margin: 1.5em 0;
  }
  .typing-dots-bounce {
    display: inline-block;
    margin-left: 4px;
  }
  .typing-dots-bounce span {
    display: inline-block;
    animation: dotBounce 1.4s infinite ease-in-out both;
    color: #888;
    font-size: 1.4em;
    line-height: 10px;
    vertical-align: middle;
  }
  .typing-dots-bounce span:nth-child(1) { animation-delay: -0.32s; }
  .typing-dots-bounce span:nth-child(2) { animation-delay: -0.16s; }
  @keyframes dotBounce {
    0%, 80%, 100% { transform: translateY(0); opacity: 0.5; }
    40% { transform: translateY(-5px); opacity: 1; }
  }
  sup.item-version {
    font-size: 0.7em;
    opacity: 0.7;
    margin-left: 2px;
  }
  /* For quotes colored by textFormatter */
  span[style*="color: var(--vk-blue)"] {
    color: #007AFF !important; /* Fallback if var not reachable, but vars are reachable */
  }
  .search-highlight-text {
    background-color: rgba(255, 215, 0, 0.4);
    color: #fff;
    border-radius: 4px;
    padding: 0 2px;
  }
  .search-highlight-text.active-search-match {
    background-color: rgba(244, 67, 54, 0.8);
    color: #fff;
    border-radius: 4px;
    padding: 0 2px;
  }
  img {
    -webkit-touch-callout: default;
  }
  .janitor-img-wrapper {
    display: block;
    position: relative;
    margin-top: 8px;
  }
  .janitor-img {
    width: 100%;
    border-radius: 12px;
    display: block;
  }
  .janitor-options-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: rgba(0,0,0,0.50);
    border: none;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    padding: 0;
    opacity: 0;
    transition: opacity 0.2s, background 0.15s;
  }
  .janitor-img-wrapper:hover .janitor-options-btn { opacity: 1; }
  @media (hover: none) { .janitor-options-btn { opacity: 0.7; } }
  .janitor-options-btn:active { background: rgba(0,0,0,0.75); }
  .janitor-options-btn svg { width: 16px; height: 16px; fill: #fff; pointer-events: none; }
  .imggen-loading {
    display: block;
    max-width: 100%;
    min-height: 120px;
    border-radius: 12px;
    margin: 8px 0;
    background: linear-gradient(90deg,
      rgba(255,255,255,0.04) 25%,
      rgba(255,255,255,0.10) 50%,
      rgba(255,255,255,0.04) 75%);
    background-size: 200% 100%;
    animation: imggen-shimmer 1.5s infinite linear;
    position: relative;
    overflow: hidden;
    border: none;
  }
  .imggen-loading-hint {
    display: inline-block;
    padding: 12px 0 0 12px;
    font-size: 14px;
    font-weight: 600;
    color: rgba(255,255,255,0.9);
    user-select: none;
  }
  .imggen-loading-timer {
    display: inline-block;
    padding: 12px 12px 0 4px;
    font-size: 14px;
    font-weight: 600;
    color: rgba(255,255,255,0.7);
    user-select: none;
  }
  .imggen-loading-prompt {
    position: absolute;
    bottom: 10px;
    left: 10px;
    right: 10px;
    font-size: 11px;
    color: rgba(128,128,128,0.7);
    line-height: 1.4;
    max-height: 2.8em;
    overflow: hidden;
    transition: max-height 0.25s ease;
    user-select: none;
  }
  @keyframes imggen-shimmer {
    0% { background-position: 100% 0; }
    100% { background-position: -100% 0; }
  }
  .imggen-loading.expanded .imggen-loading-prompt {
    top: 44px;
    max-height: calc(100% - 54px);
    overflow-y: auto;
  }
  .imggen-error {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 8px;
    width: 240px;
    max-width: 100%;
    border-radius: 12px;
    margin: 8px 0;
    padding: 14px 12px;
    box-sizing: border-box;
    background: rgba(255,59,48,0.13);
    border: 1px solid rgba(255,59,48,0.32);
  }
  .imggen-error-icon { font-size: 20px; line-height: 1; flex-shrink: 0; }
  .imggen-error-msg {
    font-size: 10px;
    color: rgba(255,59,48,0.9);
    text-align: center;
    word-break: break-all;
    line-height: 1.4;
  }
  .imggen-error-retry {
    display: flex;
    align-items: center;
    gap: 4px;
    border-radius: 12px;
    padding: 2px 8px;
    height: 22px;
    font-size: 11px;
    color: rgba(255,59,48,0.9);
    background: rgba(255,59,48,0.1);
    border: 1px solid rgba(255,59,48,0.3);
    cursor: pointer;
    transition: background 0.15s;
  }
  .imggen-error-retry:active { background: rgba(255,59,48,0.2); }
  .imggen-error-retry svg { width: 13px; height: 13px; fill: currentColor; pointer-events: none; }
  .imggen-result-wrapper {
    display: inline-block;
    position: relative;
    margin: 6px 0;
  }
  .imggen-result {
    max-width: 100%;
    border-radius: 10px;
    display: block;
    margin: 0;
  }
  .imggen-options-btn {
    position: absolute;
    top: 8px;
    right: 8px;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: rgba(0,0,0,0.50);
    border: none;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    padding: 0;
    opacity: 0;
    transition: opacity 0.2s, background 0.15s;
  }
  .imggen-result-wrapper:hover .imggen-options-btn { opacity: 1; }
  @media (hover: none) { .imggen-options-btn { opacity: 0.7; } }
  .imggen-options-btn:active { background: rgba(0,0,0,0.75); }
  .imggen-options-btn svg { width: 16px; height: 16px; fill: #fff; pointer-events: none; }

  .chat-quote {
    color: var(--current-quote-color, var(--char-quote-color, var(--vk-blue))) !important;
  }
  .chat-quote .chat-italic {
    color: inherit !important;
  }
  .chat-italic {
    color: var(--current-italic-color, var(--char-italic-color, #888));
    font-style: italic;
  }

  /* RollingNumber styles */
  .rolling-number { display: inline-flex; align-items: center; vertical-align: middle; height: 1.2em; font-variant-numeric: tabular-nums; }
  .rolling-number-inner { display: inline-flex; align-items: center; }
  .rolling-column { position: relative; display: inline-flex; justify-content: center; }
  .column-enter-active, .column-leave-active { transition: all 0.2s ease; }
  .column-enter-from, .column-leave-to { opacity: 0; width: 0 !important; transform: scaleX(0); }
  .digit-container { display: inline-block; position: relative; height: 1.2em; overflow: hidden; vertical-align: top; }
  .digit-measure { visibility: hidden; display: inline-block; line-height: 1.2em; }
  .digit { position: absolute; top: 0; left: 0; right: 0; text-align: center; line-height: 1.2em; }
  .symbol { line-height: 1.2em; }
  .is-symbol { width: auto; }
  .slide-digit-enter-active, .slide-digit-leave-active { transition: transform 0.2s cubic-bezier(0.4, 0.0, 0.2, 1), opacity 0.2s cubic-bezier(0.4, 0.0, 0.2, 1); }
  .slide-digit-fast-enter-active, .slide-digit-fast-leave-active { transition: transform 0.05s linear, opacity 0.05s linear; }
  .slide-digit-enter-from, .slide-digit-fast-enter-from { transform: translateY(100%); opacity: 0; }
  .slide-digit-leave-to, .slide-digit-fast-leave-to { transform: translateY(-100%); opacity: 0; }
  .slide-digit-enter-to, .slide-digit-leave-from, .slide-digit-fast-enter-to, .slide-digit-fast-leave-from { transform: translateY(0); opacity: 1; }
`;

onMounted(() => {
  if (!container.value) return;
  
  shadow = container.value.attachShadow({ mode: 'open' });
  
  const style = document.createElement('style');
  style.textContent = getStyles();
  shadow.appendChild(style);
  
  contentDiv = document.createElement('div');
  contentDiv.className = 'content';
  shadow.appendChild(contentDiv);
  
  // Track interactions to help errorHandler suppress errors from this shadow root
  const handleInteraction = (e) => {
    // Check if the event passed through our shadow root
    // composedPath() works through shadow boundaries
    if (e.composedPath().includes(shadow)) {
      window._lastShadowInteraction = Date.now();
    }
  };

  // Listen globally (capturing) to catch the interaction BEFORE any prospective error
  window.addEventListener('click', handleInteraction, true);
  window.addEventListener('change', handleInteraction, true);
  window.addEventListener('input', handleInteraction, true);

  const executeScripts = (containerEl) => {
    if (!containerEl) return;
    const scripts = containerEl.querySelectorAll('script');
    scripts.forEach(oldScript => {
      const newScript = document.createElement('script');
      
      // Copy attributes
      Array.from(oldScript.attributes).forEach(attr => {
        newScript.setAttribute(attr.name, attr.value);
      });

      if (oldScript.textContent) {
        // We execute the script directly. 
        // We no longer monkey-patch global async functions (setTimeout, etc.) 
        // to avoid infinite recursion when multiple components are mounted.
        const code = `
          try {
            ${oldScript.textContent}
          } catch (e) {
            e.isShadowError = true;
            console.error('Shadow Script Error:', e);
          }
        `;
        newScript.textContent = code;
      }

      oldScript.parentNode.replaceChild(newScript, oldScript);
    });
  };

  watch(() => props.html, async (newHtml) => {
    if (contentDiv) {
      activeTimers.value = [];
      await nextTick();
      
      contentDiv.innerHTML = newHtml;
      
      const timers = Array.from(contentDiv.querySelectorAll('.imggen-loading-timer'));
      if (timers.length > 0) {
        activeTimers.value = timers.map(el => {
          el.textContent = '';
          return {
            el,
            start: parseInt(el.dataset.start, 10),
            value: '0.0s'
          };
        });
      }
      
      setTimeout(() => executeScripts(contentDiv), 0);
    }
  }, { immediate: true });

  timerRafId = requestAnimationFrame(updateTimers);

  // Clean up
  onUnmounted(() => {
    if (timerRafId) cancelAnimationFrame(timerRafId);
    window.removeEventListener('click', handleInteraction, true);
    window.removeEventListener('change', handleInteraction, true);
    window.removeEventListener('input', handleInteraction, true);
  });
});
</script>

<template>
  <div class="shadow-content-wrapper">
    <div ref="container" class="shadow-content-root" :style="{ '--user-select': isSelected ? 'text' : 'none' }"></div>
    <Teleport v-for="(timer, i) in activeTimers" :key="i" :to="timer.el">
      <RollingNumber :value="timer.value" />
    </Teleport>
  </div>
</template>

<style scoped>
.shadow-content-wrapper {
  width: 100%;
  display: block;
}
</style>
