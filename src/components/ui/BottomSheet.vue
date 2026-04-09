<script setup>
import { ref, watch, nextTick, onMounted, onBeforeUnmount } from 'vue';
import { Capacitor } from '@capacitor/core';
import { hideKeyboard, showKeyboard, applyKeyboardOverlap, onKeyboardShow, onKeyboardHide } from '@/core/services/keyboardHandler.js';
import { translations, t } from '@/utils/i18n.js';
import HelpTip from '@/components/ui/HelpTip.vue';
const props = defineProps({
    visible: Boolean,
    locked: { type: Boolean, default: false }, // when true, prevents backdrop/drag dismiss
    title: String,
    helpTip: String,
    content: [String, Object], // HTML string or DOM node
    items: Array, // [{ label, icon, iconColor, onClick, isDestructive, actions: [{icon, color, onClick}] }]
    headerAction: Object, // { icon, onClick }
    bigInfo: Object, // { icon, description, buttonText, buttonDisabled, onButtonClick, glossaryChip: { term, label } }
    sessionItems: Array, // [{ title, count, time, preview, isActive, onClick, onDelete }]
    cardItems: Array, // [{ label, sublabel, icon, onClick }]
    input: Object // { placeholder, value, confirmLabel, onConfirm }
});

const emit = defineEmits(['close']);

function openGlossaryChip(term) {
    emit('close');
    nextTick(() => {
        window.dispatchEvent(new CustomEvent('open-glossary', { detail: { term } }));
    });
}

function close() {
    // Hide keyboard and blur active element before closing
    if (isLocalKeyboardOpen.value) {
        isLocalKeyboardOpen.value = false;
        const active = document.activeElement;
        if (active && (domContent.value?.contains(active) || inputRef.value === active)) {
            active.blur();
        }
        if (Capacitor.isNativePlatform()) {
            hideKeyboard();
        }
    }
    emit('close');
}

const domContent = ref(null);
const inputValue = ref('');
const inputRef = ref(null);

// When visible becomes false externally (via closeBottomSheet()), reset keyboard state
watch(() => props.visible, (newVal) => {
    if (!newVal && isLocalKeyboardOpen.value) {
        isLocalKeyboardOpen.value = false;
    }
});

watch(() => props.input, (newVal) => {
    if (newVal) {
        inputValue.value = newVal.value || '';
        isLocalKeyboardOpen.value = true;
        
        // Pre-emptively set overlap if it's 0 to avoid delay in sheet raising
        applyKeyboardOverlap();

        nextTick(() => {
            if (inputRef.value) {
                inputRef.value.focus();
                if (Capacitor.isNativePlatform()) {
                    showKeyboard();
                }
            }
        });
    }
});

function onInputConfirm() {
    if (props.input && props.input.onConfirm && inputValue.value.trim()) {
        props.input.onConfirm(inputValue.value.trim());
    }
}

// Handle DOM elements passed as content (legacy support)
watch(() => [domContent.value, props.content], () => {
    if (domContent.value && props.content && typeof props.content !== 'string') {
        domContent.value.innerHTML = '';
        if (props.content instanceof HTMLElement || props.content instanceof DocumentFragment) {
            domContent.value.appendChild(props.content);
        }
    }
}, { immediate: true });

// Drag to close logic
const startY = ref(0);
const currentDragY = ref(0);
const isDragging = ref(false);

function onHandleTouchStart(e) {
    startY.value = e.touches[0].clientY;
    isDragging.value = true;
}

function onHandleTouchMove(e) {
    if (!isDragging.value) return;
    const delta = e.touches[0].clientY - startY.value;
    if (delta > 0) {
        currentDragY.value = delta;
    }
}

function onHandleTouchEnd() {
    isDragging.value = false;
    if (!props.locked && currentDragY.value > 80) {
        close();
    }
    currentDragY.value = 0;
}

const isLocalKeyboardOpen = ref(false);

function checkFocus() {
    const active = document.activeElement;
    if (!active) return;

    const isInside = domContent.value?.contains(active) || inputRef.value === active || active?.closest('.bottom-sheet-content');

    if (isInside) {
        // Only trigger if it's a text-entry field that actually opens a virtual keyboard
        const tagName = active.tagName;
        let isTextEntry = false;
        
        if (tagName === 'TEXTAREA') {
            isTextEntry = true;
        } else if (tagName === 'INPUT') {
            const textTypes = ['text', 'password', 'email', 'number', 'tel', 'url', 'search', 'date', 'datetime-local', 'month', 'time', 'week'];
            isTextEntry = textTypes.includes(active.type.toLowerCase());
        } else if (active.isContentEditable) {
            isTextEntry = true;
        }

        if (isTextEntry) {
            isLocalKeyboardOpen.value = true;
            
            // Ensure overlap is set so the sheet can actually rise
            applyKeyboardOverlap();

            // Force keyboard on Android if needed
            if (Capacitor.isNativePlatform()) {
                showKeyboard();
            }
        } else {
            isLocalKeyboardOpen.value = false;
        }
    } else {
        isLocalKeyboardOpen.value = false;
    }
}

let kbListeners = [];

function onSheetFocusIn() {
    checkFocus();
    // Reset viewport pan to prevent double offset (CSS padding + browser pan)
    if (isLocalKeyboardOpen.value) {
        window.scrollTo(0, 0);
    }
}

onMounted(async () => {
    // Listen to focus to instantly apply padding and prevent Android visualViewport pan
    document.addEventListener('focusin', onSheetFocusIn);
    document.addEventListener('focusout', () => { setTimeout(checkFocus, 50); });

    if (Capacitor.isNativePlatform()) {
        kbListeners.push(await onKeyboardShow((info) => {
            checkFocus();
            // Height might not be set yet if it's the first time
            if (info && info.keyboardHeight) {
                applyKeyboardOverlap(info.keyboardHeight);
            }
        }));
        kbListeners.push(await onKeyboardHide(() => { 
            isLocalKeyboardOpen.value = false; 
        }));
    }
});

onBeforeUnmount(() => {
    document.removeEventListener('focusin', onSheetFocusIn);
    kbListeners.forEach(l => l.remove());
});
</script>

<template>
    <div class="modal-overlay" :class="{ visible: visible }">
        <div class="modal-backdrop" @click="locked ? undefined : close()"></div>
        <div class="bottom-sheet-content" @click.stop 
             :style="{ transform: isDragging ? `translateY(${currentDragY}px)` : '' }"
             :class="{ 'is-dragging': isDragging, 'keyboard-open': isLocalKeyboardOpen }">
            <div class="sheet-handle-bar"
                 @touchstart="onHandleTouchStart"
                 @touchmove.prevent="onHandleTouchMove"
                 @touchend="onHandleTouchEnd"
            ></div>
            <div class="sheet-header" v-if="title || headerAction">
                <div class="sheet-title">
                    {{ title }}
                    <HelpTip v-if="helpTip" :term="helpTip" />
                </div>
                <div class="sheet-action-btn" v-if="headerAction" @click="headerAction.onClick" v-html="headerAction.icon"></div>
            </div>
            
            <div class="sheet-scroll-container">
                <!-- Custom Content (HTML) -->
                <div v-if="typeof content === 'string'" class="sheet-custom-content" v-html="content"></div>
                <div v-else-if="content" class="sheet-custom-content" ref="domContent"></div>
                
                <!-- Vue Slot Content -->
                <slot></slot>

                <!-- Big Info Sheet (Moved out of else-if chain to allow combination) -->
                <div v-if="bigInfo" class="sheet-big-info">
                    <div class="big-info-icon" v-html="bigInfo.icon"></div>
                    <div class="big-info-desc">{{ bigInfo.description }}</div>
                    <div v-if="bigInfo.glossaryChip" class="big-info-chip-line">{{ bigInfo.glossaryChip.hint }} <button class="big-info-chip" @click.stop="openGlossaryChip(bigInfo.glossaryChip.term)">{{ bigInfo.glossaryChip.label }}</button></div>
                    <div class="sheet-big-info-btn" :class="{ disabled: bigInfo.buttonDisabled }" @click="!bigInfo.buttonDisabled && bigInfo.onButtonClick()">{{ bigInfo.buttonText }}</div>
                </div>

                <!-- List Items -->
                <div v-if="items && items.length" class="sheet-list">
                    <div v-for="(item, index) in items" :key="index" class="sheet-item" :class="{ 'centered': item.centered, 'has-hint': item.hint }" @click="item.onClick">
                        <div class="sheet-item-icon" v-if="item.icon" v-html="item.icon" :style="{ color: item.iconColor }"></div>
                        <div class="sheet-item-content">
                            <span :class="{ 'text-destructive': item.isDestructive }">{{ item.label }}</span>
                            <span v-if="item.hint" class="sheet-item-hint">{{ item.hint }}</span>
                        </div>
                        
                        <!-- Item Actions (Buttons on the right) -->
                        <div class="sheet-item-actions" v-if="item.actions && item.actions.length">
                            <div v-for="(action, aIndex) in item.actions" :key="aIndex" 
                                 class="sheet-item-action-btn"
                                 @click.stop="action.onClick"
                                 v-html="action.icon"
                                 :style="{ color: action.color }">
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Session Items (Custom Layout) -->
                <div v-if="sessionItems && sessionItems.length" class="sheet-list">
                    <div v-for="(item, index) in sessionItems" :key="index" class="sheet-item session-item" @click="item.onClick">
                        <div class="session-content">
                            <div class="session-title">{{ item.title }} <span class="session-count"><svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>{{ item.count }}</span></div>
                            <div class="session-preview">{{ item.preview }}</div>
                        </div>
                        <div class="session-right">
                            <div class="session-meta-right">
                                <div class="session-time">{{ item.time }}</div>
                                <div v-if="item.isActive" class="active-dot"></div>
                            </div>
                            <div class="session-delete-btn" @click.stop="item.onDelete"><svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg></div>
                        </div>
                    </div>
                </div>

                <!-- Card Items (Triggered style) -->
                <div v-if="cardItems && cardItems.length" class="sheet-card-list">
                    <div v-for="(item, index) in cardItems" :key="index" 
                         class="triggered-item-card" 
                         :class="{ 'has-bg': item.image, 'is-active': item.isActive }"
                         :style="item.image ? { backgroundImage: `url(${item.image})` } : {}"
                         @click="item.onClick">
                        <div class="card-overlay" v-if="item.image"></div>
                        <div v-if="item.isFeatured" class="featured-badge">
                            {{ t('label_featured_preset') || 'FEATURED PRESET' }}
                        </div>
                        <div class="item-icon" v-if="item.icon">
                            <div v-if="item.icon.startsWith('<')" v-html="item.icon"></div>
                            <svg v-else viewBox="0 0 24 24"><path :d="item.icon"/></svg>
                        </div>
                        <div class="item-info">
                            <div class="item-label-row">
                                <div class="item-label" :class="{ 'with-bg': item.image }">{{ item.label }}</div>
                                <div v-if="item.badge" class="item-badge" :class="{ 'with-bg': item.image }">
                                    <svg viewBox="0 0 24 24" class="badge-icon"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                    {{ item.badge }}
                                </div>
                            </div>
                            <div v-if="item.sublabel" class="item-sublabel" :class="{ 'with-bg': item.image }">{{ item.sublabel }}</div>
                        </div>
                        
                        <!-- Item Actions (Buttons on the right) -->
                        <div class="sheet-item-actions" :class="{ 'card-actions-right': item.actions && item.actions.length }" v-if="item.actions && item.actions.length">
                            <div v-for="(action, aIndex) in item.actions" :key="aIndex" 
                                 class="sheet-item-action-btn card-action-btn"
                                 :class="{ 'with-bg': item.image }"
                                 @click.stop="action.onClick"
                                 v-html="action.icon"
                                 :style="{ color: action.color }">
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Input Sheet -->
                <div v-if="input" class="sheet-input-container">
                    <div class="settings-item">
                        <input 
                            ref="inputRef"
                            type="text" 
                            v-model="inputValue" 
                            :placeholder="input.placeholder"
                            @keydown.enter="onInputConfirm"
                        >
                    </div>
                    <div class="settings-padding" style="padding-top: 0;">
                        <div class="btn-save" style="margin-top: 10px;" @click="onInputConfirm">{{ input.confirmLabel || 'Save' }}</div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</template>

<style scoped>
.sheet-big-info-btn.disabled {
    opacity: 0.45;
    cursor: not-allowed;
    pointer-events: none;
}

.sheet-item.centered {
    justify-content: center;
}
.sheet-item.centered .sheet-item-content {
    flex: 0 0 auto;
}
</style>

<style>
/* Base Styles moved from components.css */
.modal-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: rgba(0,0,0,0.5);
    z-index: 1000;
    display: flex;
    justify-content: center;
    align-items: flex-end;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.3s;
}

.modal-overlay.visible {
    opacity: 1;
    pointer-events: auto;
}

.bottom-sheet-content {
    width: 100%;
    max-width: 600px;
    background-color: var(--ui-bg);
    border-top-left-radius: 16px;
    border-top-right-radius: 16px;
    padding-bottom: calc(10px + var(--sab));
    transform: translateY(100%);
    transition: padding-bottom 0.25s cubic-bezier(0.2, 0.8, 0.2, 1), transform 0.3s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.3s ease, max-height 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
    max-height: 95vh;
    box-shadow: 0 -5px 15px rgba(0,0,0,0.1);
    display: flex;
    flex-direction: column;
}

.modal-overlay.visible .bottom-sheet-content {
    transform: translateY(0);
}

.sheet-handle-bar {
    width: 100%;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    cursor: grab;
    touch-action: none;
}

.sheet-handle-bar::after {
    content: '';
    width: 32px;
    height: 4px;
    background-color: #e0e0e0;
    border-radius: 2px;
}

.sheet-scroll-container {
    overflow-y: auto;
    max-height: 70vh;
    width: 100%;
    overscroll-behavior: contain;
}

.sheet-header {
    padding: 8px 20px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.sheet-title {
    font-size: 18px;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: 8px;
}

.sheet-action-btn {
    font-size: 24px;
    color: var(--vk-blue);
    cursor: pointer;
    line-height: 1;
}

.sheet-action-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.sheet-list {
    overflow-y: auto;
}

.sheet-item {
    padding: 12px 16px;
    display: flex;
    align-items: center;
    cursor: pointer;
}

.sheet-item:active {
    background-color: var(--bg-gray);
}

.sheet-item-icon {
    width: 24px;
    height: 24px;
    margin-right: 16px;
    fill: var(--text-gray);
    display: flex;
    align-items: center;
    justify-content: center;
}

.sheet-item-icon svg {
    width: 24px;
    height: 24px;
}

.sheet-item-content {
    flex: 1;
    font-size: 16px;
    color: var(--text-black);
    word-break: break-word;
    white-space: pre-wrap;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.sheet-item-hint {
    font-size: 12px;
    color: var(--text-gray);
    font-weight: normal;
    white-space: normal;
    line-height: 1.3;
}

.sheet-item.has-hint {
    align-items: center;
}

.sheet-item-remove, .sheet-item-edit {
    padding: 8px;
    color: var(--text-gray);
    cursor: pointer;
}

.sheet-item-remove svg, .sheet-item-edit svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.sheet-item-actions {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-right: -5px;
}

.sheet-item-action-btn {
    padding: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    cursor: pointer;
}

.sheet-item-action-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.sheet-item-action-btn:active {
    background-color: rgba(0,0,0,0.05);
}

.text-destructive {
    color: #ff4444;
}

.sheet-big-info {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 20px 20px 10px;
    text-align: center;
}

.big-info-icon {
    width: 64px;
    height: 64px;
    margin-bottom: 16px;
    color: var(--text-gray);
    opacity: 0.5;
}

.big-info-desc {
    font-size: 16px;
    color: var(--text-black);
    margin-bottom: 24px;
    line-height: 1.5;
    word-break: break-word;
    white-space: pre-wrap;
}

.big-info-chip-line {
    font-size: 14px;
    color: var(--text-gray);
    margin-bottom: 18px;
    line-height: 1.5;
}

.big-info-chip {
    display: inline-flex;
    align-items: center;
    padding: 2px 10px;
    border-radius: 6px;
    background: rgba(var(--vk-blue-rgb), 0.12);
    color: var(--vk-blue);
    font-size: 13px;
    font-weight: 600;
    font-family: inherit;
    border: 1px solid rgba(var(--vk-blue-rgb), 0.2);
    cursor: pointer;
    vertical-align: baseline;
    transition: background 0.15s, opacity 0.15s;
    -webkit-tap-highlight-color: transparent;
}
.big-info-chip:active {
    background: rgba(var(--vk-blue-rgb), 0.22);
    opacity: 0.8;
}

.sheet-big-info-btn {
    width: 100%;
    padding: 12px;
    background-color: var(--vk-blue);
    color: white;
    border-radius: 8px;
    font-weight: 500;
    cursor: pointer;
    text-align: center;
}

.session-item {
    padding: 12px 16px;
    display: flex;
    align-items: center;
    justify-content: space-between;
}
.session-content {
    flex: 1;
    overflow: hidden;
    margin-right: 12px;
}
.session-title {
    font-weight: 600;
    font-size: 16px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    margin-bottom: 4px;
    display: flex;
    align-items: center;
}
.session-count { 
    color: var(--text-gray); 
    font-size: 0.85em; 
    font-weight: normal; 
    display: flex;
    align-items: center;
    gap: 4px;
    margin-left: 8px;
}
.session-count svg { width: 14px; height: 14px; fill: currentColor; opacity: 0.7; }
.session-meta-right { display: flex; align-items: center; gap: 8px; }
.session-time { font-size: 0.85em; color: var(--text-gray); white-space: nowrap; }
.session-preview { font-size: 0.9em; color: var(--text-gray); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; opacity: 0.8; }
.session-right { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; min-width: fit-content; }
.active-dot {
    width: 8px; height: 8px; background-color: var(--vk-blue); border-radius: 50%;
    flex-shrink: 0;
}
.session-delete-btn {
    color: #ff4444; 
    padding: 4px; 
    cursor: pointer; 
    display: flex; 
    align-items: center; 
    justify-content: center;
    opacity: 0.7; 
    transition: opacity 0.2s;
}
.session-delete-btn:active { opacity: 1; }
.session-delete-btn svg { 
    width: 20px; 
    height: 20px; 
    fill: currentColor; 
}

/* Fix for blur during animation: separate backdrop opacity from content */
.modal-overlay {
    background-color: transparent !important;
    opacity: 1 !important;
    visibility: hidden;
    transition: visibility 0s linear 0.3s !important;
    z-index: 12000 !important;
}

.modal-overlay.visible {
    visibility: visible;
    transition-delay: 0s !important;
}

.modal-backdrop {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background-color: rgba(0,0,0,0.5);
    opacity: 0;
    transition: opacity 0.3s ease;
}

.modal-overlay.visible .modal-backdrop {
    opacity: 1;
}

.bottom-sheet-content {
    z-index: 2;
    background-color: rgba(var(--theme-ui-color-rgb, 255, 255, 255), var(--element-opacity, 0.8)) !important;
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.03'/%3E%3C/svg%3E");
    border-top: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    box-shadow: 0 -5px 20px rgba(0,0,0,0.1);
    transition: background-color 0.3s ease, transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
    border-top-left-radius: 20px;
    border-top-right-radius: 20px;
}

.bottom-sheet-content.keyboard-open {
    padding-bottom: calc(var(--keyboard-overlap, var(--keyboard-height, 300px)) + 10px + var(--sab, 0px));
    max-height: 95vh;
}

.bottom-sheet-content.is-dragging {
    transition: none;
}

body.dark-theme .bottom-sheet-content {
    background-color: rgba(var(--theme-ui-color-rgb, 30, 30, 30), var(--element-opacity, 0.8)) !important;
    border-top: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 -5px 20px rgba(0,0,0,0.3);
}

/* Card Items (Triggered style) */
.sheet-card-list {
    padding: 8px 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.triggered-item-card {
    display: flex;
    align-items: center;
    padding: 10px 12px;
    background: var(--menu-group-bg, rgba(0, 0, 0, 0.02));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 12px;
    gap: 12px;
    cursor: pointer;
    transition: background 0.2s, transform 0.1s;
    position: relative;
    overflow: hidden;
    background-size: cover;
    background-position: center center;
}

.triggered-item-card.has-bg {
    min-height: 160px; /* Provide more space for the background image to show */
    align-items: flex-end; /* Push text to the bottom if desired, or keep center */
    padding: 12px 16px;
}

.card-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.3) 100%);
    z-index: 1;
}

.triggered-item-card > *:not(.card-overlay):not(.featured-badge) {
    position: relative;
    z-index: 2;
}

.triggered-item-card:active {
    background-color: rgba(var(--vk-blue-rgb), 0.1);
    transform: scale(0.98);
}

.triggered-item-card.is-active {
    background: rgba(var(--vk-blue-rgb), 0.15);
    border-color: rgba(var(--vk-blue-rgb), 0.3);
}

body.dark-theme .triggered-item-card.is-active {
    background: rgba(var(--vk-blue-rgb), 0.2);
    border-color: rgba(var(--vk-blue-rgb), 0.4);
}

.triggered-item-card.has-bg:active .card-overlay {
    background: linear-gradient(to top, rgba(0,0,0,0.9) 0%, rgba(0,0,0,0.4) 100%);
}

.triggered-item-card .item-icon {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    border-radius: 50%;
    flex-shrink: 0;
    overflow: hidden;
    box-shadow: 0 2px 5px rgba(0,0,0,0.1);
}

.triggered-item-card.has-bg .item-icon {
    display: none; /* Hide standard icon if we have a full background, or keep it as an overlay badge */
}

.triggered-item-card .item-icon svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.triggered-item-card .item-icon img,
.triggered-item-card .item-icon > div {
    width: 100%;
    height: 100%;
    object-fit: cover;
    border-radius: inherit;
    display: flex;
    align-items: center;
    justify-content: center;
}

.triggered-item-card .item-info {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
}

.card-actions-right {
    margin-left: auto;
}

.triggered-item-card .item-label {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-black);
    text-shadow: none; /* Reset for non-bg */
}

.item-label-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-bottom: 2px;
}

.item-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 10px;
    font-weight: 700;
    padding: 2px 8px;
    border-radius: 12px;
    background: rgba(0, 0, 0, 0.05);
    color: var(--text-gray);
    flex-shrink: 0;
}

.item-badge.with-bg {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255, 255, 255, 0.1);
}

.badge-icon {
    width: 12px;
    height: 12px;
    fill: currentColor;
    opacity: 0.7;
}

.triggered-item-card .item-label.with-bg {
    color: #ffffff;
    text-shadow: 0 1px 3px rgba(0,0,0,0.8);
    font-size: 16px;
}

.triggered-item-card .item-sublabel {
    font-size: 12px;
    color: var(--text-light-gray);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
}

.triggered-item-card .item-sublabel.with-bg {
    color: rgba(255,255,255,0.7);
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.featured-badge {
    position: absolute;
    top: 10px;
    left: 12px;
    background: transparent;
    color: rgba(255, 255, 255, 0.5);
    font-size: 9px;
    font-weight: 700;
    padding: 0;
    border-radius: 0;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    z-index: 3;
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
}

.card-action-btn {
    padding: 6px;
}

.card-action-btn svg {
    width: 20px;
    height: 20px;
}

.card-action-btn.with-bg {
    color: white !important;
    background: rgba(0, 0, 0, 0.4);
    border-radius: 50%;
    backdrop-filter: blur(4px);
}
</style>