<script setup>
import { computed } from 'vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

/**
 * Reusable connection-status section header + animated error banner.
 *
 * Usage:
 *   <ConnectionStatus :status="apiStatus" :error-message="errorMsg" @retry="checkConnection">
 *       <!-- left side of the header row (slot) -->
 *       <span>Connection</span>
 *   </ConnectionStatus>
 *
 * Props:
 *   status       – 'idle' | 'connecting' | 'connected' | 'failed'
 *   errorMessage – string shown in the error banner when status is 'failed'
 *
 * Emits:
 *   retry – when the badge is clicked
 */
const props = defineProps({
    status: { type: String, default: 'idle' },
    errorMessage: { type: String, default: '' },
});

const emit = defineEmits(['retry']);

const t = (key) => translations[currentLang.value]?.[key] || key;
const statusText = computed(() => t('status_' + props.status) || props.status);

function copyError() {
    if (props.errorMessage && navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(props.errorMessage);
    }
}

// Height + opacity animation for the error banner
function onBeforeEnter(el) {
    el.style.height = '0';
    el.style.opacity = '0';
}
function onEnter(el, done) {
    el.offsetHeight; // force reflow
    el.style.transition = 'height 0.4s cubic-bezier(0.16,1,0.3,1), opacity 0.4s cubic-bezier(0.16,1,0.3,1)';
    el.style.height = el.scrollHeight + 'px';
    el.style.opacity = '1';
    el.addEventListener('transitionend', done, { once: true });
}
function onAfterEnter(el) { el.style.height = 'auto'; }
function onBeforeLeave(el) { el.style.height = el.offsetHeight + 'px'; }
function onLeave(el, done) {
    el.offsetHeight;
    el.style.transition = 'height 0.4s cubic-bezier(0.16,1,0.3,1), opacity 0.4s cubic-bezier(0.16,1,0.3,1)';
    el.style.height = '0';
    el.style.opacity = '0';
    el.addEventListener('transitionend', done, { once: true });
}
</script>

<template>
    <div class="conn-status-root">
        <div class="section-header section-header-flex">
            <slot />
            <div class="conn-badge" @click="emit('retry')">
                <div class="status-dot" :class="status"></div>
                <Transition name="status-fade" mode="out-in">
                    <span class="status-text" :key="status">{{ statusText }}</span>
                </Transition>
            </div>
        </div>

        <Transition
            :css="false"
            @before-enter="onBeforeEnter"
            @enter="onEnter"
            @after-enter="onAfterEnter"
            @before-leave="onBeforeLeave"
            @leave="onLeave"
        >
            <div v-if="status === 'failed' && errorMessage" class="conn-error-banner">
                <div class="conn-error-inner">
                    <div class="error-window">
                        <div class="error-header">
                            <span>ERROR</span>
                            <div class="error-copy-btn" @click.stop="copyError">
                                <svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
                            </div>
                        </div>
                        <div class="error-content">{{ errorMessage }}</div>
                    </div>
                </div>
            </div>
        </Transition>
    </div>
</template>

<style scoped>
.conn-status-root {
    /* transparent wrapper — inherits surrounding layout */
}

/* Badge (status dot + animated text) */
.conn-badge {
    display: flex;
    align-items: center;
    cursor: pointer;
    padding: 4px 8px;
    border-radius: 16px;
    font-size: 0.75em;
    font-weight: normal;
    text-transform: none;
    user-select: none;
    flex-shrink: 0;
    transition: opacity 0.15s;
}
.conn-badge:active { opacity: 0.6; }

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background-color: var(--text-gray, #888);
    margin-right: 6px;
    flex-shrink: 0;
    transition: background-color 0.3s ease;
}
.status-dot.idle       { background-color: var(--text-gray, #888); opacity: 0.4; }
.status-dot.connecting { background-color: orange; }
.status-dot.connected  { background-color: #4CAF50; }
.status-dot.failed     { background-color: #ff4444; }

.status-text {
    color: var(--text-secondary, var(--text-gray, #888));
    font-size: 12px;
}

.status-fade-enter-active,
.status-fade-leave-active {
    transition: opacity 0.2s ease, transform 0.2s ease;
}
.status-fade-enter-from,
.status-fade-leave-to {
    opacity: 0;
    transform: translateY(5px);
}

/* Error banner */
.conn-error-banner {
    overflow: hidden;
}

.conn-error-inner {
    padding: 0 16px 8px;
}

.error-window {
    background-color: rgba(43, 14, 14, 0.85);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid #ff3b30;
    border-radius: 8px;
    overflow: hidden;
}

.error-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background-color: rgba(255, 59, 48, 0.2);
    padding: 6px 12px;
    border-bottom: 1px solid rgba(255, 59, 48, 0.3);
}

.error-header span {
    color: #ff3b30;
    font-size: 10px;
    font-weight: bold;
    letter-spacing: 1px;
}

.error-copy-btn {
    cursor: pointer;
    color: #ff3b30;
    opacity: 0.7;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2px;
    border-radius: 4px;
    transition: opacity 0.2s;
}
.error-copy-btn:active { opacity: 1; }
.error-copy-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.error-content {
    padding: 10px 12px;
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 12px;
    color: #ffb3b3;
    white-space: pre-wrap;
    word-break: break-word;
}
</style>
