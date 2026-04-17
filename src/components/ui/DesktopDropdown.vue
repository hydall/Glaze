<script setup>
import { watch, nextTick, ref } from 'vue';
import { desktopDropdownState, closeDesktopDropdown } from '@/core/states/desktopDropdownState.js';

// Реактивный стиль позиционирования — пересчитывается при открытии
const dropdownStyle = ref({});
const DROPDOWN_WIDTH = 220;
const ITEM_HEIGHT = 42; // approx px per item
const PADDING = 12; // px from viewport edges

function recalcPosition() {
    const { x, y, items, isTriggered, bigInfo } = desktopDropdownState.value;
    const itemCount = items?.length ?? 0;
    
    const width = isTriggered ? 280 : 220;
    const itemHeight = isTriggered ? 56 : 42;
    let estimatedHeight = itemCount * itemHeight + 16;
    if (bigInfo) estimatedHeight += 120; // Approx height for bigInfo block

    let left = x;
    let top = y;

    // Fit within viewport
    if (left < PADDING) left = PADDING;
    if (left + width > window.innerWidth - PADDING) {
        left = window.innerWidth - width - PADDING;
    }
    if (top + estimatedHeight > window.innerHeight - PADDING) {
        top = y - estimatedHeight; // flip above
        if (top < PADDING) top = PADDING;
    }

    dropdownStyle.value = {
        top: top + 'px',
        left: left + 'px',
        width: width + 'px',
        transformOrigin: top < y ? 'left bottom' : 'left top',
    };
}

watch(
    () => desktopDropdownState.value.visible,
    (val) => {
        if (val) nextTick(recalcPosition);
    }
);
</script>

<template>
    <Teleport to="body">
        <Transition name="dd-fade">
            <div
                v-if="desktopDropdownState.visible"
                class="dd-overlay"
                @mousedown.self="closeDesktopDropdown"
                @contextmenu.prevent
            >
                <div class="dd-panel" :style="dropdownStyle" @click.stop :class="{ 'dd-panel--triggered': desktopDropdownState.isTriggered }">
                    <div v-if="desktopDropdownState.title || desktopDropdownState.headerAction" class="dd-header">
                        <div v-if="desktopDropdownState.title" class="dd-title">
                            {{ desktopDropdownState.title }}
                        </div>
                        <div v-if="desktopDropdownState.headerAction" class="dd-header-action" @click="desktopDropdownState.headerAction.onClick" v-html="desktopDropdownState.headerAction.icon"></div>
                    </div>

                    <!-- Big Info Block -->
                    <div v-if="desktopDropdownState.bigInfo" class="dd-big-info">
                        <div v-if="desktopDropdownState.bigInfo.icon" class="dd-big-info-icon" v-html="desktopDropdownState.bigInfo.icon"></div>
                        <div class="dd-big-info-label" v-if="desktopDropdownState.bigInfo.label">{{ desktopDropdownState.bigInfo.label }}</div>
                        <div class="dd-big-info-desc" v-if="desktopDropdownState.bigInfo.description">{{ desktopDropdownState.bigInfo.description }}</div>
                        <div v-if="desktopDropdownState.bigInfo.buttonText" class="dd-big-info-btn" @click="desktopDropdownState.bigInfo.onButtonClick">
                            {{ desktopDropdownState.bigInfo.buttonText }}
                        </div>
                    </div>

                    <!-- Items -->
                    <div
                        v-for="(item, idx) in desktopDropdownState.items"
                        :key="idx"
                        class="dd-item"
                        :class="{
                            'dd-item--destructive': item.isDestructive,
                            'dd-item--active': item.isActive,
                            'dd-item--disabled': item.disabled,
                            'dd-item--triggered': desktopDropdownState.isTriggered,
                            'dd-item--has-bg': item.image
                        }"
                        :style="item.image ? { backgroundImage: `url(${item.image})` } : {}"
                        @click="!item.disabled && (item.onClick?.(), closeDesktopDropdown())"
                    >
                        <div v-if="item.image" class="dd-card-overlay"></div>
                        <div v-if="item.isFeatured" class="dd-featured-badge">FEATURED</div>

                        <!-- Icon slot -->
                        <span
                            v-if="item.icon && !item.image"
                            class="dd-item-icon"
                            :style="item.iconColor ? { color: item.iconColor } : {}"
                            v-html="item.icon"
                        ></span>
                        
                        <div class="dd-item-info">
                            <span class="dd-item-label" :class="{ 'with-bg': item.image }">{{ item.label }}</span>
                            <span v-if="item.sublabel" class="dd-item-sublabel" :class="{ 'with-bg': item.image }">{{ item.sublabel }}</span>
                        </div>

                        <span v-if="item.hint" class="dd-item-hint">{{ item.hint }}</span>

                        <!-- Item Actions (Buttons on the right) -->
                        <div class="dd-item-actions" v-if="item.actions && item.actions.length">
                            <div v-for="(action, aIndex) in item.actions" :key="aIndex" 
                                 class="dd-item-action-btn"
                                 :class="{ 'with-bg': item.image }"
                                 @click.stop="action.onClick"
                                 v-html="action.icon"
                                 :style="{ color: action.color }">
                            </div>
                        </div>

                        <!-- Active checkmark -->
                        <svg v-if="item.isActive" class="dd-item-check" viewBox="0 0 24 24">
                            <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>
                        </svg>
                    </div>
                </div>
            </div>
        </Transition>
    </Teleport>
</template>

<style>
/* ── Desktop Dropdown ─────────────────────────────────────── */
.dd-overlay {
    position: fixed;
    inset: 0;
    z-index: 19000;
}

.dd-panel {
    position: fixed;
    z-index: 19001;
    /* menu-group style: mirror base.css:359 */
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.03'/%3E%3C/svg%3E");
    border: var(--border-width, 1px) solid var(--border-color, rgba(255, 255, 255, 0.1));
    border-radius: 20px;
    padding: 8px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.25);
    transition: background-color 0.3s ease, border-color 0.3s ease, width 0.3s ease;
    overflow: hidden;
}

.dd-panel--triggered {
    gap: 8px;
    display: flex;
    flex-direction: column;
}

.dd-title {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: var(--text-gray, rgba(200,200,200,0.6));
    padding: 6px 12px 4px;
}

.dd-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 2px;
}

.dd-header-action {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    border-radius: 50%;
    color: var(--vk-blue, #5b9ae8);
    transition: background-color 0.2s;
    margin-right: 4px;
}

.dd-header-action:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
}

.dd-header-action svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.dd-big-info {
    padding: 20px 16px;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 8px;
}

.dd-big-info-icon {
    width: 48px;
    height: 48px;
    color: var(--text-gray);
    opacity: 0.5;
    margin-bottom: 4px;
}

.dd-big-info-icon svg {
    width: 48px;
    height: 48px;
    fill: currentColor;
}

.dd-big-info-label {
    font-size: 16px;
    font-weight: 700;
}

.dd-big-info-desc {
    font-size: 13px;
    color: var(--text-gray);
    line-height: 1.4;
}

.dd-big-info-btn {
    margin-top: 10px;
    padding: 8px 16px;
    background-color: var(--vk-blue);
    color: white;
    border-radius: 12px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: opacity 0.2s;
}

.dd-big-info-btn:hover {
    opacity: 0.9;
}

.dd-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 12px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 14px;
    font-weight: 500;
    color: var(--text-black, #e8e8e8);
    transition: background-color 0.12s ease, color 0.12s ease, transform 0.1s ease;
    user-select: none;
    -webkit-tap-highlight-color: transparent;
}

.dd-item:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.18);
    color: var(--vk-blue, #5b9ae8);
}

.dd-item:active {
    transform: scale(0.98);
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.28);
}

.dd-item--triggered {
    border: 1px solid rgba(128, 128, 128, 0.2);
    background: var(--menu-group-bg, rgba(255, 255, 255, 0.03));
    padding: 10px 12px;
}

.dd-item--triggered:hover {
    border-color: var(--border-color, rgba(255, 255, 255, 0.25));
    background: rgba(var(--vk-blue-rgb), 0.1);
}

.dd-item--has-bg {
    min-height: 80px;
    background-size: cover;
    background-position: center;
    position: relative;
    border: none;
    align-items: flex-end;
}

.dd-card-overlay {
    position: absolute;
    inset: 0;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.2) 100%);
    z-index: 1;
}

.dd-item--has-bg > *:not(.dd-card-overlay):not(.dd-featured-badge) {
    position: relative;
    z-index: 2;
}

.dd-featured-badge {
    position: absolute;
    top: 6px;
    left: 8px;
    font-size: 8px;
    font-weight: 800;
    letter-spacing: 0.1em;
    color: rgba(255, 255, 255, 0.6);
    z-index: 3;
}

.dd-item--destructive {
    color: #ff5252;
}

.dd-item--destructive:hover {
    background-color: rgba(255, 82, 82, 0.12);
    color: #ff5252;
}

.dd-item--active {
    color: var(--vk-blue, #5b9ae8);
    font-weight: 600;
}

.dd-item--disabled {
    opacity: 0.4;
    cursor: not-allowed;
    pointer-events: none;
}

.dd-item-icon {
    width: 20px;
    height: 20px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: inherit;
    opacity: 0.85;
}

.dd-item-icon svg,
.dd-item-icon img {
    width: 20px;
    height: 20px;
    fill: currentColor;
    display: block;
}

.dd-item-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.dd-item-hint {
    font-size: 11px;
    color: var(--text-gray, rgba(180,180,180,0.7));
    font-weight: 400;
    flex-shrink: 0;
}

.dd-item-check {
    width: 16px;
    height: 16px;
    fill: var(--vk-blue, #5b9ae8);
    flex-shrink: 0;
    margin-left: auto;
}

.dd-item-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
    gap: 1px;
}

.dd-item-label.with-bg {
    color: #fff;
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.dd-item-sublabel {
    font-size: 11px;
    color: var(--text-gray, rgba(180, 180, 180, 0.7));
    font-weight: 400;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.dd-item-sublabel.with-bg {
    color: rgba(255, 255, 255, 0.7);
    text-shadow: 0 1px 1px rgba(0,0,0,0.8);
}

.dd-item-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-left: auto;
    z-index: 10;
}

.dd-item-action-btn {
    padding: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    color: var(--text-gray);
    transition: background 0.2s, color 0.2s;
}

.dd-item-action-btn:hover {
    background: rgba(var(--vk-blue-rgb), 0.15);
    color: var(--vk-blue);
}

.dd-item-action-btn svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.dd-item-action-btn.with-bg {
    color: white !important;
    background: rgba(0, 0, 0, 0.4);
    backdrop-filter: blur(4px);
}

.dd-item-action-btn.with-bg:hover {
    background: rgba(0, 0, 0, 0.6);
}

/* ── Animation ─────────────────────────────────────────── */
.dd-fade-enter-active {
    animation: dd-in 0.22s cubic-bezier(0.2, 0, 0.2, 1) both;
}

.dd-fade-leave-active {
    animation: dd-out 0.15s cubic-bezier(0.4, 0, 1, 1) both;
}

@keyframes dd-in {
    from {
        opacity: 0;
        transform: scale(0.96) translateY(-4px);
        filter: blur(4px);
    }
    to {
        opacity: 1;
        transform: scale(1) translateY(0);
        filter: blur(0);
    }
}

@keyframes dd-out {
    from {
        opacity: 1;
        transform: scale(1) translateY(0);
        filter: blur(0);
    }
    to {
        opacity: 0;
        transform: scale(0.96) translateY(-4px);
        filter: blur(4px);
    }
}
</style>
