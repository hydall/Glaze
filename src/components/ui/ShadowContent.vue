<script setup>
import { ref, onMounted, onUnmounted, watch } from 'vue';

const props = defineProps({
  html: { type: String, required: true },
  isSelected: { type: Boolean, default: false }
});

const container = ref(null);
let shadow = null;
let contentDiv = null;

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
    background: rgba(var(--ui-bg-rgb, 0,0,0), 0.05);
    border: 1px solid rgba(var(--ui-bg-rgb, 0,0,0), 0.1);
    padding: 10px;
    border-radius: 8px;
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 0.9em;
    overflow-x: auto;
    margin: 10px 0;
    white-space: pre-wrap;
    color: inherit;
  }
  .unclosed-tag {
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    background: rgba(var(--ui-bg-rgb, 0,0,0), 0.05);
    border: 1px solid rgba(var(--ui-bg-rgb, 0,0,0), 0.1);
    padding: 2px 4px;
    border-radius: 4px;
    color: #888;
    font-size: 0.9em;
  }
  :global(body.dark-theme) pre.code-block {
    background: rgba(255, 255, 255, 0.05);
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
    background-color: #ff9800;
    color: #fff;
    border-radius: 4px;
    padding: 0 2px;
  }
  .search-highlight-text.active-search-match {
    background-color: #f44336;
    border-radius: 4px;
    padding: 0 2px;
  }
  :global(body.dark-theme) .search-highlight-text {
    background-color: rgba(255, 215, 0, 0.4);
  }
  :global(body.dark-theme) .search-highlight-text.active-search-match {
    background-color: rgba(244, 67, 54, 0.8);
    color: #fff;
  }
  img {
    -webkit-touch-callout: default;
  }
  .imggen-loading {
    display: inline-block;
    width: 48px;
    height: 48px;
    border-radius: 50%;
    border: 3px solid rgba(128, 128, 128, 0.2);
    border-top-color: #007AFF;
    animation: imggen-spin 0.8s linear infinite;
    vertical-align: middle;
    margin: 8px 0;
  }
  @keyframes imggen-spin { to { transform: rotate(360deg); } }
  .imggen-error {
    display: inline-block;
    padding: 6px 10px;
    background: rgba(255, 59, 48, 0.12);
    border-radius: 8px;
    color: #FF3B30;
    font-size: 12px;
    margin: 4px 0;
    max-width: 100%;
    word-break: break-word;
  }
  .imggen-result {
    max-width: 100%;
    border-radius: 10px;
    margin: 6px 0;
    display: block;
  }
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

  watch(() => props.html, (newHtml) => {
    if (contentDiv) {
      contentDiv.innerHTML = newHtml;
      setTimeout(() => executeScripts(contentDiv), 0);
    }
  }, { immediate: true });

  // Clean up
  onUnmounted(() => {
    window.removeEventListener('click', handleInteraction, true);
    window.removeEventListener('change', handleInteraction, true);
    window.removeEventListener('input', handleInteraction, true);
  });
});
</script>

<template>
  <div ref="container" class="shadow-content-wrapper" :style="{ '--user-select': isSelected ? 'text' : 'none' }"></div>
</template>

<style scoped>
.shadow-content-wrapper {
  width: 100%;
  display: block;
}
</style>
