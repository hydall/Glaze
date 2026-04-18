<!-- src/components/ui/SheetView.vue -->
<script setup>
import { ref, onMounted, onBeforeUnmount, computed, watch } from 'vue';
import { sidebarState, setSidebarOccupied } from '@/core/states/sidebarState.js';
import { bottomSheetState, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { useSheetGestures } from '@/composables/ui/useSheetGestures.js';
import { attachKeyboardFocusHandler } from '@/core/services/keyboardHandler.js';

let _sheetIdCounter = 0;

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

const isDesktop = ref(window.innerWidth >= 768);
const checkDesktop = () => { isDesktop.value = window.innerWidth >= 768; };
const sidebarExists = ref(false);
const isSidebarMode = computed(() => {
    return isDesktop.value && !props.viewMode && sidebarExists.value;
});

const emit = defineEmits(['close', 'back', 'update:expanded', 'update:activeTab', 'tab-click']);

const isVisible = ref(false);
const instanceId = ref(`sv_${++_sheetIdCounter}`);

watch(isVisible, (val) => {
    if (isDesktop.value) {
        if (val) {
            setSidebarOccupied(true, instanceId.value);
        } else if (sidebarState.activeSheetId === instanceId.value) {
            setSidebarOccupied(false);
        }
    }
});

watch(() => sidebarState.activeSheetId, (newId) => {
    if (isVisible.value && isDesktop.value && newId && newId !== instanceId.value) {
        close();
    }
});

watch(() => bottomSheetState.visible, (val) => {
    if (val && isVisible.value && isDesktop.value) {
        close();
    }
});

const isExpanded = ref(false);
const wasExpandedBeforeKeyboard = ref(false);
const sheetViewContentRef = ref(null);

const { 
    isDragging, 
    sheetStyle, 
    toggle, 
    onHandleTouchStart, 
    onHandleTouchMove, 
    onHandleTouchEnd 
} = useSheetGestures({
    isVisible,
    isExpanded,
    isSidebarMode,
    fitContent: computed(() => props.fitContent),
    emit,
    close: () => {
        close();
    }
});

const { 
    isLocalKeyboardOpen, 
    mount: mountKeyboard, 
    unmount: unmountKeyboard, 
    hideLocalKeyboard 
} = attachKeyboardFocusHandler(sheetViewContentRef, {
    onKeyboardOpen: () => { window.scrollTo(0, 0); },
    onKeyboardExpanded: (info) => {
        if (!isVisible.value) return;
        if (!isExpanded.value && !props.fitContent) {
            wasExpandedBeforeKeyboard.value = false;
            isExpanded.value = true;
            emit('update:expanded', true);
        } else {
            wasExpandedBeforeKeyboard.value = true;
        }
    },
    onKeyboardRestored: () => {
        if (!wasExpandedBeforeKeyboard.value && !props.fitContent) {
            isExpanded.value = false;
            emit('update:expanded', false);
        }
    }
});

function open() {
    if (props.viewMode) return;
    sidebarExists.value = !!document.getElementById('desktop-sidebar-content');
    if (isDesktop.value && bottomSheetState.visible) {
        closeBottomSheet();
    }
    
    // Double requestAnimationFrame ensures that the browser has enough time
    // to paint the initial state before transition classes are applied
    requestAnimationFrame(() => {
        requestAnimationFrame(() => {
            isVisible.value = true;
            isExpanded.value = false;
        });
    });
}

function close() {
    hideLocalKeyboard();
    isVisible.value = false;
    emit('close');
}

function onHwBack(e) {
    if (props.showBack) {
        emit('back');
        e.preventDefault();
    }
}

defineExpose({ open, close, isVisible, isExpanded });


onMounted(async () => {
    sidebarExists.value = !!document.getElementById('desktop-sidebar-content');
    window.addEventListener('resize', checkDesktop);
    await mountKeyboard();
});

onBeforeUnmount(() => {
    window.removeEventListener('resize', checkDesktop);
    unmountKeyboard();
    if (isVisible.value && isDesktop.value) {
        setSidebarOccupied(false);
    }
});
</script>

<template>
    <!-- ── View mode: inline content, no overlay/drag ── -->
    <div v-if="viewMode" class="sheet-view-inline" v-bind="$attrs">
        <slot name="header-bottom"></slot>
        <slot></slot>
    </div>

    <Teleport v-else :to="isSidebarMode ? '#desktop-sidebar-content' : 'body'">
        <div class="sheet-view-overlay" :class="{ visible: isVisible, 'is-sidebar': isSidebarMode }" :style="{ zIndex: zIndex }" @click.self="close" @hw-back="onHwBack">
            <div ref="sheetViewContentRef"
                 class="sheet-view-content" 
                 :class="{ 'expanded': isExpanded, 'is-dragging': isDragging, 'keyboard-open': isLocalKeyboardOpen, 'is-sidebar': isSidebarMode, 'fit-content': fitContent }"
                 :style="sheetStyle">
                
                <div class="sheet-header-area"
                     :class="{ 'no-drag': isSidebarMode }"
                     @touchstart="isSidebarMode ? undefined : onHandleTouchStart"
                     @touchmove.prevent="isSidebarMode ? undefined : onHandleTouchMove"
                     @touchend="isSidebarMode ? undefined : onHandleTouchEnd"
                >
                    <div v-if="!isSidebarMode" class="sheet-handle-bar" @click.stop="toggle"></div>
                    
                    <div class="sc-sheet-header-wrapper" v-if="title || showBack || isSidebarMode || actions?.length || tabs?.length || $slots['header-right'] || $slots['header-title'] || $slots['header-bottom']">
                        <div class="sc-sheet-header" v-if="title || showBack || isSidebarMode || actions?.length || $slots['header-right'] || $slots['header-title']">
                            <div class="sc-header-left">
                                <div v-if="showBack || isSidebarMode" class="sc-header-btn back-btn" @click="isSidebarMode ? close() : $emit('back')">
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
                        
                        <div class="sc-sheet-header-bottom" v-if="$slots['header-bottom']">
                            <slot name="header-bottom"></slot>
                        </div>
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
    display: flex;
    flex-direction: column;
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

.sheet-view-overlay.is-sidebar {
    position: absolute;
    inset: 0;
    background: transparent;
    flex: none;
    min-height: 0;
    width: 100%;
    flex-direction: column;
    align-items: stretch;
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
}

.sheet-view-content.is-dragging {
    transition: none;
}


.sheet-header-area {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    flex-shrink: 0;
    touch-action: none;
    z-index: 10;
    padding-bottom: 12px;
    pointer-events: none;
}

.sheet-view-content.expanded .sheet-header-area {
    padding-top: var(--sat);
}

.sheet-header-area::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: linear-gradient(to bottom, 
        rgba(var(--ui-bg-rgb), 0.85) 0%, 
        rgba(var(--ui-bg-rgb), 0) 100%
    );
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    mask-image: linear-gradient(to bottom, 
        black 0%, 
        black 40%, 
        transparent 100%
    );
    -webkit-mask-image: linear-gradient(to bottom, 
        black 0%, 
        black 40%, 
        transparent 100%
    );
    z-index: -1;
}

.sheet-header-area > * {
    pointer-events: auto;
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
    padding-top: 80px;
    scroll-padding-top: 80px;
    padding-bottom: var(--sab, 0px);
}


.sheet-view-content.is-sidebar {
    height: 100% !important;
    max-height: none !important;
    border-radius: 0 !important;
    border: none !important;
    box-shadow: none !important;
    transform: translateX(100%) !important;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8)) !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    background-image: none !important;
    padding-top: 8px !important;
}

.sheet-view-overlay.visible .sheet-view-content.is-sidebar {
    transform: translateX(0) !important;
}


.sheet-view-content:has(.sc-sheet-tabs) .sheet-view-body,
.sheet-view-content:has(.sc-sheet-header-bottom) .sheet-view-body {
    padding-top: 140px;
    scroll-padding-top: 140px;
}

.sheet-view-content:has(.sc-sheet-tabs):has(.sc-sheet-header-bottom) .sheet-view-body {
    padding-top: 200px;
    scroll-padding-top: 200px;
}

.sheet-view-content.expanded .sheet-view-body {
    padding-top: calc(80px + var(--sat, 0px));
    scroll-padding-top: calc(80px + var(--sat, 0px));
}

.sheet-view-content.expanded:has(.sc-sheet-tabs) .sheet-view-body,
.sheet-view-content.expanded:has(.sc-sheet-header-bottom) .sheet-view-body {
    padding-top: calc(140px + var(--sat, 0px));
    scroll-padding-top: calc(140px + var(--sat, 0px));
}

.sheet-view-content.expanded:has(.sc-sheet-tabs):has(.sc-sheet-header-bottom) .sheet-view-body {
    padding-top: calc(200px + var(--sat, 0px));
    scroll-padding-top: calc(200px + var(--sat, 0px));
}

.sheet-view-body::-webkit-scrollbar-track {
    margin-top: 80px;
}

.sheet-view-content:has(.sc-sheet-tabs) .sheet-view-body::-webkit-scrollbar-track,
.sheet-view-content:has(.sc-sheet-header-bottom) .sheet-view-body::-webkit-scrollbar-track {
    margin-top: 140px;
}

.sheet-view-body .active-view  {
    padding: 10px 0px !important;
}

.sc-sheet-header-wrapper {
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
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
    border: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3);
    transition: all 0.2s ease;
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
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-gray);
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
    font-family: inherit;
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
