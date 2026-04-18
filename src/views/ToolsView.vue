<script setup>
import { onMounted } from 'vue';
import { t, updateLanguage } from '@/utils/i18n.js';
import { initRipple } from '@/core/services/ui.js';

onMounted(() => {
    initRipple();
    updateLanguage();
});

const openView = (viewId) => {
    window.dispatchEvent(new CustomEvent('navigate-to', { detail: viewId }));
};

const tools = [
    {
        id: 'view-api',
        label: () => t('tab_api') || 'API',
        icon: 'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z'
    },
    {
        id: 'view-presets',
        label: () => t('subtab_preset') || 'Presets',
        icon: 'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z'
    },
    {
        id: 'view-lorebook',
        label: () => t('menu_lorebooks') || 'World Info',
        icon: 'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z'
    },
    {
        id: 'view-regex',
        label: () => t('menu_regex') || 'Regex Scripts',
        icon: 'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z'
    },
    {
        id: 'view-personas',
        label: () => t('tab_personas') || 'Personas',
        icon: 'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z'
    }
];
</script>

<template>
    <div id="view-tools" class="view active-view">
        <div class="menu-group">
            <div class="section-header">{{ t('tab_tools') }}</div>
            <div
                v-for="tool in tools"
                :key="tool.id"
                class="menu-item"
                @click="openView(tool.id)"
            >
                <svg class="menu-icon" viewBox="0 0 24 24">
                    <path :d="tool.icon"/>
                </svg>
                <div class="menu-text">{{ tool.label() }}</div>
                <svg class="menu-arrow" viewBox="0 0 24 24">
                    <path d="M9 18l6-6-6-6"/>
                </svg>
            </div>
        </div>
    </div>
</template>

<style scoped>
.menu-arrow {
    width: 18px;
    height: 18px;
    stroke: var(--text-gray);
    stroke-width: 2;
    fill: none;
    stroke-linecap: round;
    stroke-linejoin: round;
    opacity: 0.5;
    flex-shrink: 0;
}
</style>
