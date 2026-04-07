<!-- src/components/ui/SheetView.vue -->
<script setup>
import { ref, onMounted, onBeforeUnmount, computed } from 'vue';
import { Capacitor } from '@capacitor/core';
import { isKeyboardOpen as globalKeyboardOpen, hideKeyboard, showKeyboard, applyKeyboardOverlap, onKeyboardShow, onKeyboardHide } from '@/core/services/keyboardHandler.js';

const props = defineProps({
    fitContent: { type: Boolean, default: false },
    zIndex: { type: [Number, String], default: 11000 },
    title: { type: String, default: '' },
    showBack: { type: Boolean, default: false },
    actions: { type: Array, default: () => [] },
    tabs: { type: Array, default: () => [] },
    activeTab: { type: String, default: '' },
    viewMode: { type: Boolean, default: false },
});

const emit = defineEmits(['close', 'back', 'update:expanded', 'update:activeTab', 'tab-click']);

const isVisible = ref(false);
const isExpanded = ref(false);
const isDragging = ref(false);
const startY = ref(0);
const currentDragY = ref(0);
const wasExpandedBeforeKeyboard = ref(false);

const sheetStyle = computed(() => {
    if (!isVisible.value) {
        if (props.fitContent) {
            return { 
                transform: 'translate3d(0, 100%, 0)',
                height: 'auto',
                paddingBottom: 'calc(0px + var(--sab, 0px))',
                '--sheet-translate': '0px'
            };
        }
        return { 
            transform: 'translate3d(0, 100vh, 0)',
            height: '100vh',
            paddingBottom: isExpanded.value ? 'calc(0vh + var(--sab, 0px))' : 'calc(15vh + var(--sab, 0px))',
            '--sheet-translate': isExpanded.value ? '0vh' : '15vh'
        };
    }
    
    if (props.fitContent) {
        const t = isDragging.value ? currentDragY.value : 0;
        return { 
            transform: `translate3d(0, ${t}px, 0)`,
            height: 'auto',
            paddingBottom: 'calc(0px + var(--sab, 0px))',
            '--sheet-translate': `${t}px`
        };
    }

    const baseTranslateVh = isExpanded.value ? 0 : 15;
    const dragDeltaVh = (currentDragY.value / window.innerHeight) * 100;
    const targetTranslateVh = baseTranslateVh + dragDeltaVh;

    if (isDragging.value && targetTranslateVh < 0) {
        // Stretching: height grows, translateY stays 0 so bottom stays at 100%
        return {
            height: `calc(100vh + ${Math.abs(targetTranslateVh)}vh)`,
            transform: 'translate3d(0, 0, 0)',
            paddingBottom: 'calc(0px + var(--sab, 0px))',
            '--sheet-translate': '0vh'
        };
    } else {
        // Normal movement
        const t = isDragging.value ? targetTranslateVh : baseTranslateVh;
        return {
            height: '100vh',
            transform: `translate3d(0, ${t}vh, 0)`,
            paddingBottom: `calc(${t}vh + var(--sab, 0px))`,
            '--sheet-translate': `${t}vh`
        };
    }
});

function open() {
    if (props.viewMode) return;
    isVisible.value = true;
    isExpanded.value = false;
}

function close() {
    // Hide keyboard and blur active element before closing
    if (isLocalKeyboardOpen.value) {
        isLocalKeyboardOpen.value = false;
        const active = document.activeElement;
        if (active && sheetViewContentRef.value?.contains(active)) {
            active.blur();
        }
        if (Capacitor.isNativePlatform()) {
            hideKeyboard();
        }
    }
    isVisible.value = false;
    emit('close');
}

function toggle() {
    if (props.fitContent) {
        close();
        return;
    }
    isExpanded.value = !isExpanded.value;
    emit('update:expanded', isExpanded.value);
}

function onHandleTouchStart(e) {
    // Don't start dragging if the user tapped a button in the header
    if (e.target.closest('.header-btn') || e.target.closest('.clickable-no-drag') || e.target.closest('.sub-tab-btn')) return;
    isDragging.value = true;
    startY.value = e.touches[0].clientY;
}

function onHandleTouchMove(e) {
    if (!isDragging.value) return;
    const delta = e.touches[0].clientY - startY.value;
    
    // When expanded or fitContent, only allow dragging down (with resistance upward)
    if ((isExpanded.value || props.fitContent) && delta < 0) {
        currentDragY.value = delta * 0.2;
    } else {
        currentDragY.value = delta;
    }
}

function onHandleTouchEnd() {
    if (!isDragging.value) return;
    isDragging.value = false;
    
    if (currentDragY.value > 80) { // Swipe down
        if (isExpanded.value) {
            isExpanded.value = false;
            emit('update:expanded', false);
        } else {
            close();
        }
    } else if (currentDragY.value < -40 && !isExpanded.value && !props.fitContent) { // Swipe up
        isExpanded.value = true;
        emit('update:expanded', true);
    }
    currentDragY.value = 0;
}

function onHwBack(e) {
    if (props.showBack) {
        emit('back');
        e.preventDefault();
    }
}

defineExpose({ open, close, isVisible, isExpanded });

const sheetViewContentRef = ref(null);
const isLocalKeyboardOpen = ref(false);
const isTextFieldFocusedInSheet = ref(false);

function updateFocusState() {
    const active = document.activeElement;
    if (!active) {
        isTextFieldFocusedInSheet.value = false;
        return;
    }
    
    const isInside = sheetViewContentRef.value?.contains(active) || active?.closest('.sheet-view-content');

    if (isInside) {
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

        isTextFieldFocusedInSheet.value = isTextEntry;

        // Force keyboard on Android if needed
        if (isTextEntry && Capacitor.isNativePlatform()) {
            showKeyboard();
        }
    } else {
        isTextFieldFocusedInSheet.value = false;
    }

    // On non-native (web), drive keyboard state from focus since there are no native keyboard events
    if (!Capacitor.isNativePlatform()) {
        isLocalKeyboardOpen.value = isTextFieldFocusedInSheet.value;
    }
}

let kbListeners = [];

function onSheetFocusIn() {
    updateFocusState();
    if (isLocalKeyboardOpen.value) {
        window.scrollTo(0, 0);
    }
}

function expandForKeyboard() {
    if (!isExpanded.value && !props.fitContent) {
        wasExpandedBeforeKeyboard.value = false;
        isExpanded.value = true;
        emit('update:expanded', true);
    } else {
        wasExpandedBeforeKeyboard.value = true;
    }
}

function restoreAfterKeyboard() {
    if (!wasExpandedBeforeKeyboard.value && !props.fitContent) {
        isExpanded.value = false;
        emit('update:expanded', false);
    }
}

onMounted(async () => {
    document.addEventListener('focusin', onSheetFocusIn);
    document.addEventListener('focusout', () => { setTimeout(updateFocusState, 50); });

    if (Capacitor.isNativePlatform()) {
        kbListeners.push(await onKeyboardShow((info) => { 
            updateFocusState();
            // Only react if a text field inside THIS sheet is focused
            if (isTextFieldFocusedInSheet.value && isVisible.value) {
                window.scrollTo(0, 0);
                if (info && info.keyboardHeight) {
                    applyKeyboardOverlap(info.keyboardHeight);
                }
                isLocalKeyboardOpen.value = true;
                expandForKeyboard();
            }
        }));
        kbListeners.push(await onKeyboardHide(() => { 
            isLocalKeyboardOpen.value = false;
            isTextFieldFocusedInSheet.value = false;
            restoreAfterKeyboard();
        }));
    }
});

onBeforeUnmount(() => {
    document.removeEventListener('focusin', onSheetFocusIn);
    kbListeners.forEach(l => l.remove());
});
</script>

<template>
    <!-- ── View mode: inline content, no overlay/drag ── -->
    <div v-if="viewMode" class="sheet-view-inline">
        <slot></slot>
    </div>

    <Teleport v-else to="body">
        <div class="sheet-view-overlay" :class="{ visible: isVisible }" :style="{ zIndex: zIndex }" @click.self="close" @hw-back="onHwBack">
            <div ref="sheetViewContentRef"
                 class="sheet-view-content" 
                 :class="{ 'expanded': isExpanded, 'is-dragging': isDragging, 'keyboard-open': isLocalKeyboardOpen || globalKeyboardOpen, 'fit-content': fitContent }"
                 :style="sheetStyle">
                
                <div class="sheet-header-area"
                     @touchstart="onHandleTouchStart"
                     @touchmove.prevent="onHandleTouchMove"
                     @touchend="onHandleTouchEnd"
                >
                    <div class="sheet-handle-bar" @click.stop="toggle"></div>
                    
                    <div class="sc-sheet-header-wrapper" v-if="title || showBack || actions?.length || tabs?.length || $slots['header-right'] || $slots['header-title'] || $slots['header-bottom']">
                        <div class="sc-sheet-header" v-if="title || showBack || actions?.length || $slots['header-right'] || $slots['header-title']">
                            <div class="sc-header-left">
                                <div v-if="showBack" class="sc-header-btn back-btn" @click="$emit('back')">
                                    <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
                                </div>
                                <div class="sc-header-title" v-if="title">{{ title }}</div>
                                <slot name="header-title"></slot>
                            </div>
                            <div class="sc-header-right">
                                <template v-if="actions && actions.length">
                                    <template v-for="(action, idx) in actions" :key="idx">
                                        <div class="sc-header-btn" :style="{ color: action.color }" @click.stop="action.onClick" :title="action.title || action.label" v-html="action.icon"></div>
                                    </template>
                                </template>
                                <slot name="header-right"></slot>
                            </div>
                        </div>
                        
                        <div class="sc-sheet-tabs" v-if="tabs && tabs.length">
                            <button
                                v-for="tab in tabs"
                                :key="tab.key || tab.id"
                                class="sc-sheet-tab"
                                :class="{ active: activeTab === (tab.key || tab.id) }"
                                @click="$emit('update:activeTab', tab.key || tab.id); $emit('tab-click', tab)"
                            >
                                <svg v-if="tab.icon" viewBox="0 0 24 24"><path :d="tab.icon"/></svg>
                                <span v-if="tab.label">{{ tab.label }}</span>
                            </button>
                        </div>
                        
                        <slot name="header-bottom"></slot>
                    </div>
                    
                    <!-- Slot for a custom header (title, buttons) -->
                    <slot name="header"></slot>
                </div>

                <div class="sheet-view-body">
                    <slot></slot>
                </div>
            </div>
        </div>
    </Teleport>
</template>

<style scoped>
.sheet-view-inline {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow-y: auto;
    padding-bottom: 16px;
}

.sheet-view-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: rgba(0,0,0,0.5);
    z-index: 11000;
    display: flex;
    justify-content: center;
    align-items: flex-end;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
    will-change: opacity;
}

.sheet-view-overlay.visible {
    opacity: 1;
    pointer-events: auto;
}

.sheet-view-content {
    width: 100%;
    max-width: 600px;
    background-color: var(--app-bg);
    border-top-left-radius: 20px;
    border-top-right-radius: 20px;
    display: flex;
    flex-direction: column;
    transition: transform 0.3s cubic-bezier(0.2, 0.8, 0.2, 1), height 0.3s cubic-bezier(0.2, 0.8, 0.2, 1), border-radius 0.3s ease, padding-bottom 0.25s cubic-bezier(0.2, 0.8, 0.2, 1), max-height 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
    overflow: hidden;
    position: relative;
    box-shadow: 0 -5px 20px rgba(0,0,0,0.2);
    will-change: transform, height;
    backface-visibility: hidden;
}


.sheet-view-content.fit-content {
    height: auto;
    max-height: 90vh;
}

.sheet-view-content.keyboard-open {
    padding-bottom: calc(var(--keyboard-overlap, 0px) + 10px) !important;
}

.sheet-view-content.expanded {
    border-radius: 0;
    padding-top: calc(var(--sat) + 10px) !important;
}

.sheet-view-content.is-dragging {
    transition: none;
}


.sheet-header-area {
    flex-shrink: 0;
    touch-action: none;
    cursor: grab;
    background-color: var(--app-bg);
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
    background-color: var(--app-bg);
}

.sheet-view-content.fit-content .sheet-handle-bar {
    padding-bottom: 8px;
}

.sheet-handle-bar::after {
    content: '';
    width: 32px;
    height: 4px;
    background-color: #e0e0e0;
    border-radius: 2px;
}

.sheet-view-body {
    flex: 1;
    overflow-y: auto;
    position: relative;
    display: flex;
    flex-direction: column;
}

.sheet-view-body .active-view  {
    padding: 10px 0px !important;
}

.sc-sheet-header-wrapper {
    display: flex;
    flex-direction: column;
    border-bottom: 1px solid var(--border-color, rgba(0, 0, 0, 0.1));
    flex-shrink: 0;
}

body.dark-theme .sc-sheet-header-wrapper {
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.sc-sheet-header {
    min-height: 56px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 16px;
    flex-shrink: 0;
}

.sc-header-left {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
}

.sc-header-right {
    display: flex;
    align-items: center;
    flex-shrink: 0;
}

.sc-header-title {
    font-weight: 700;
    font-size: 18px;
    color: var(--text-black);
    text-align: left;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.sc-header-btn {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: var(--accent-color, var(--vk-blue));
    flex-shrink: 0;
    
    border-radius: 50%;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1);
    transition: all 0.2s ease;
}

.sc-header-btn:active {
    transform: scale(0.9);
    opacity: 0.8;
}

:global(body.dark-theme) .sc-header-btn {
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    border: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3);
}

.sc-header-btn.back-btn {
    margin-left: -8px;
}

.sc-header-btn :deep(svg) {
    width: 20px !important;
    height: 20px !important;
    fill: currentColor !important;
}

/* ── Tabs ─────────────────────────────────────────────────  */
.sc-sheet-tabs {
    display: flex;
    gap: 8px;
    padding: 0 16px 12px;
}

.sc-sheet-tab {
    flex: 1;
    display: flex;
    flex-direction: row;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 10px 8px;
    border: none;
    border-radius: 12px;
    background: rgba(0, 0, 0, 0.03);
    color: var(--text-gray);
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
    font-family: inherit;
}

body.dark-theme .sc-sheet-tab {
    background: rgba(255, 255, 255, 0.04);
}

.sc-sheet-tab svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
    transition: transform 0.2s;
}

.sc-sheet-tab.active {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

.sc-sheet-tab:active {
    opacity: 0.6;
}
</style>
