<script setup>
import { onMounted, ref, computed } from 'vue';
import { t, updateLanguage } from '@/utils/i18n.js';
import { initRipple } from '@/core/services/ui.js';

import { getApiPresets, fetchRemoteModels } from '@/core/config/APISettings.js';
import { presetState, DEFAULT_PRESETS } from '@/core/states/presetState.js';
import { lorebookState } from '@/core/states/lorebookState.js';
import { activePersona } from '@/core/states/personaState.js';

const props = defineProps({
    sidebarMode: { type: Boolean, default: false }
});
const emit = defineEmits(['tool-select']);

const apiStatus = ref('idle');
const activeApiPreset = ref(null);
const regexCount = ref(0);
const presetRegexCount = ref(0);

const currentGlobalPreset = computed(() => {
    const id = presetState.globalPresetId || 'default_shino';
    return presetState.presets[id] || DEFAULT_PRESETS['default_shino'] || Object.values(presetState.presets)[0] || {};
});

const lorebooksCount = computed(() => lorebookState.lorebooks?.length || 0);
const lorebooksEntriesCount = computed(() => lorebookState.lorebooks?.reduce((sum, lb) => sum + (lb.entries ? lb.entries.length : 0), 0) || 0);

const countPresetTokens = computed(() => {
    const p = currentGlobalPreset.value;
    if (!p) return 0;
    
    // Sum contents of all enabled blocks
    const blocksContent = (p.blocks || [])
        .filter(b => b.enabled && b.content)
        .map(b => b.content)
        .join(' ');
    
    const str = [
        blocksContent,
        p.impersonationPrompt || '',
        p.reasoningStart || '',
        p.reasoningEnd || ''
    ].join(' ');

    // Approx 4 chars per token roughly
    return Math.max(0, Math.floor(str.length / 4));
});

onMounted(async () => {
    initRipple();
    updateLanguage();

    try {
        const presets = await getApiPresets();
        const activeId = localStorage.getItem('gz_active_api_preset_id') || 'default';
        activeApiPreset.value = presets.find(p => p.id === activeId) || presets[0] || {};
        checkConnection();
    } catch { /* ok */ }

    try {
        const stored = localStorage.getItem('regex_scripts');
        regexCount.value = stored ? JSON.parse(stored).length : 0;
    } catch (e) { regexCount.value = 0; }
    
    presetRegexCount.value = currentGlobalPreset.value.regexes ? currentGlobalPreset.value.regexes.length : 0;
});

async function checkConnection() {
    const endpoint = localStorage.getItem('gz_api_endpoint_normalized') || localStorage.getItem('api-endpoint');
    if (!endpoint) {
        apiStatus.value = 'failed';
        return;
    }
    apiStatus.value = 'connecting';
    try {
        await fetchRemoteModels(endpoint, localStorage.getItem('api-key'));
        apiStatus.value = 'connected';
    } catch (e) {
        apiStatus.value = 'failed';
    }
}

const openView = (viewId) => {
    if (props.sidebarMode) {
        emit('tool-select', viewId);
    } else {
        window.dispatchEvent(new CustomEvent('navigate-to', { detail: viewId }));
    }
};

const getPresetIcon = (endpoint) => {
    if (!endpoint) return '';
    let origin;
    try { origin = new URL(/^https?:\/\//i.test(endpoint) ? endpoint : 'http://' + endpoint).origin; } catch { return ''; }
    return origin + '/favicon.ico';
}

const getStoredPersonaImage = (base64) => {
    if (!base64) return '';
    if (base64.startsWith('data:')) return base64;
    return `data:image/png;base64,${base64}`;
}

const tools = computed(() => [
    {
        id: 'view-personas',
        label: t('tab_personas') || 'Personas',
        icon: 'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z',
        sublabel: activePersona.value?.name || 'user',
        desc: activePersona.value?.description || activePersona.value?.prompt,
        image: getStoredPersonaImage(activePersona.value?.avatar),
        tokens: Math.floor((activePersona.value?.prompt?.length || 0) / 4),
        isLarge: true
    },
    {
        id: 'view-presets',
        label: t('subtab_preset') || 'Presets',
        icon: 'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z',
        sublabel: currentGlobalPreset.value.name || 'Default',
        desc: currentGlobalPreset.value.descriptionKey ? t(currentGlobalPreset.value.descriptionKey) : currentGlobalPreset.value.description,
        backgroundImage: currentGlobalPreset.value.image,
        tokens: countPresetTokens.value || 0,
        isLarge: true
    },
    {
        id: 'view-api',
        label: t('tab_api') || 'API',
        icon: 'M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z',
        sublabel: activeApiPreset.value?.name || 'Default',
        status: apiStatus.value,
        imageIcon: getPresetIcon(activeApiPreset.value?.endpoint)
    },
    {
        id: 'view-lorebook',
        label: t('menu_lorebooks') || 'World Info',
        icon: 'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z',
        sublabel: `${lorebooksCount.value} books, ${lorebooksEntriesCount.value} entries`
    },
    {
        id: 'view-regex',
        label: t('menu_regex') || 'Regex Scripts',
        icon: 'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z',
        sublabel: `${regexCount.value} global, ${presetRegexCount.value} preset`
    }
]);
</script>

<template>
    <div id="view-tools" class="view active-view dashboard-view" :class="{ 'is-mobile': !sidebarMode }">
        <div class="tools-header" v-if="sidebarMode">
            {{ t('tab_tools') || 'Tools' }}
        </div>
        
        <div class="dashboard-content">
            <!-- Hero Cards (Personas & Presets) -->
            <div class="dashboard-hero-section">
            <div
                v-for="tool in tools.filter(t => t.isLarge)"
                :key="tool.id"
                class="dashboard-hero-card"
                :class="{ 'is-persona': tool.id === 'view-personas', 'has-bg': tool.backgroundImage }"
                @click="openView(tool.id)"
            >
                <!-- HERO: Persona -->
                <template v-if="tool.id === 'view-personas'">
                    <div class="hero-avatar-bg">
                        <img v-if="tool.image" :src="tool.image" class="avatar-layer">
                        <div v-else class="avatar-placeholder-layer">
                            {{ (tool.sublabel || "?")[0].toUpperCase() }}
                        </div>
                    </div>
                    <div class="hero-overlay">
                        <div class="hero-label">{{ tool.label }}</div>
                        <div class="hero-info">
                            <div class="hero-title-row">
                                <span class="hero-title">{{ tool.sublabel }}</span>
                                <span v-if="tool.tokens" class="hero-badge">{{ tool.tokens }}t</span>
                            </div>
                            <div class="hero-desc" v-if="tool.desc">{{ tool.desc }}</div>
                        </div>
                    </div>
                </template>

                <!-- HERO: With Custom Background (Preset) -->
                <template v-else-if="tool.backgroundImage">
                    <div class="hero-avatar-bg">
                        <div class="avatar-layer" :style="`background-image: url(${tool.backgroundImage}); background-size: cover; background-position: center;`"></div>
                    </div>
                    <div class="hero-overlay">
                        <div class="hero-header">
                            <div class="hero-icon-box" style="background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.1);">
                                <svg class="hero-icon" viewBox="0 0 24 24"><path :d="tool.icon"/></svg>
                            </div>
                            <div class="hero-label">{{ tool.label }}</div>
                        </div>
                        <div class="hero-info">
                            <div class="hero-title-row">
                                <span class="hero-title">{{ tool.sublabel }}</span>
                                <span v-if="tool.tokens !== undefined" class="hero-badge">{{ tool.tokens }}t</span>
                            </div>
                            <div class="hero-desc" v-if="tool.desc">{{ tool.desc }}</div>
                        </div>
                    </div>
                </template>

                <!-- HERO: Default Solid/Gradient -->
                <template v-else>
                    <div class="hero-overlay default-hero">
                        <div class="hero-header">
                            <div class="hero-icon-box">
                                <svg class="hero-icon" viewBox="0 0 24 24"><path :d="tool.icon"/></svg>
                            </div>
                            <div class="hero-label">{{ tool.label }}</div>
                        </div>
                        <div class="hero-info">
                            <div class="hero-title-row">
                                <span class="hero-title">{{ tool.sublabel }}</span>
                                <span v-if="tool.tokens !== undefined" class="hero-badge">{{ tool.tokens }}t</span>
                            </div>
                            <div class="hero-desc" v-if="tool.desc">{{ tool.desc }}</div>
                        </div>
                    </div>
                </template>
            </div>
        </div>

        <!-- Grid Cards (API, Lorebook, Regex) -->
        <div class="dashboard-grid">
            <div
                v-for="tool in tools.filter(t => !t.isLarge)"
                :key="tool.id"
                class="dashboard-tile"
                @click="openView(tool.id)"
            >
                <div class="tile-icon-wrapper">
                    <img v-if="tool.image" :src="tool.image" class="tile-image"/>
                    <span v-else-if="tool.imageIcon" class="tile-image-icon">
                        <img :src="tool.imageIcon" onerror="this.style.display='none';this.nextElementSibling.style.display='block'">
                        <svg style="display:none;" class="tile-icon" viewBox="0 0 24 24"><path :d="tool.icon"/></svg>
                    </span>
                    <svg v-else class="tile-icon" viewBox="0 0 24 24"><path :d="tool.icon"/></svg>
                    <div v-if="tool.status" :class="['status-dot', tool.status]"></div>
                </div>
                
                <div class="tile-content">
                    <div class="tile-label">{{ tool.label }}</div>
                    <div class="tile-sublabel" v-if="tool.sublabel">{{ tool.sublabel }}</div>
                </div>
            </div>
            </div>
        </div>
    </div>
</template>

<style scoped>
.dashboard-view {
    padding: 0 !important;
    display: flex;
    flex-direction: column;
    background: transparent;
}

.dashboard-view.is-mobile .dashboard-content {
    padding-top: calc(var(--header-height, 56px) + 16px) !important;
    padding-bottom: calc(var(--footer-height, 56px) + var(--keyboard-overlap, 0px) + 20px) !important;
}

.tools-header {
    position: sticky;
    top: 0;
    z-index: 50;
    height: 56px;
    display: flex;
    align-items: center;
    padding: 0 16px;
    font-size: 18px;
    font-weight: 700;
    color: var(--text-color, #fff);
    background: transparent;
}

.tools-header::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: -12px; /* Extend mask slightly below text to match SheetView */
    background: linear-gradient(to bottom, 
        rgba(var(--ui-bg-rgb, 18, 18, 18), 0.85) 0%, 
        rgba(var(--ui-bg-rgb, 18, 18, 18), 0) 100%
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
    pointer-events: none;
}

.dashboard-content {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
}

/* Hero Section */
.dashboard-hero-section {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.dashboard-hero-card {
    position: relative;
    width: 100%;
    border-radius: 20px;
    overflow: hidden;
    cursor: pointer;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.08);
    transition: transform 0.2s cubic-bezier(0.2, 0, 0, 1), box-shadow 0.2s, border-color 0.2s;
    min-height: 140px;
    display: flex;
    flex-direction: column;
}

.dashboard-hero-card.is-persona {
    aspect-ratio: 1 / 1;
}

.dashboard-hero-card:hover {
    transform: translateY(-2px);
    box-shadow: 0 12px 24px rgba(0, 0, 0, 0.3);
    border-color: rgba(255, 255, 255, 0.15);
}

.dashboard-hero-card:active {
    transform: translateY(1px);
}

.hero-avatar-bg {
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    z-index: 1;
}

.avatar-layer {
    width: 100%; height: 100%;
    object-fit: cover;
}

.avatar-placeholder-layer {
    width: 100%; height: 100%;
    background: linear-gradient(135deg, #66ccff 0%, #7996ce 100%);
    display: flex; align-items: center; justify-content: center;
    color: rgba(255,255,255,0.8);
    font-weight: 800; font-size: 6em;
}

.hero-overlay {
    position: relative;
    z-index: 2;
    flex: 1;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    padding: 20px;
    background: linear-gradient(to bottom, rgba(0,0,0,0.3) 0%, rgba(0,0,0,0.8) 100%);
}

.hero-overlay.default-hero {
    background: linear-gradient(135deg, rgba(255,255,255,0.05) 0%, rgba(255,255,255,0.01) 100%);
}

.hero-label {
    font-size: 13px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: rgba(255, 255, 255, 0.9);
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
}

.hero-header {
    display: flex;
    align-items: center;
    gap: 12px;
}

.hero-icon-box {
    width: 36px; height: 36px;
    background: rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    display: flex; align-items: center; justify-content: center;
    backdrop-filter: blur(10px);
}

.hero-icon {
    width: 20px; height: 20px;
    fill: #fff;
}

.hero-info {
    margin-top: 30px;
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.hero-title-row {
    display: flex; align-items: center; justify-content: space-between; gap: 8px;
}

.hero-title {
    font-size: 20px; font-weight: 600; color: #fff;
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}

.hero-badge {
    background: rgba(255, 255, 255, 0.2);
    backdrop-filter: blur(4px);
    color: #fff;
    font-size: 12px; font-weight: 600;
    padding: 4px 8px; border-radius: 12px;
    flex-shrink: 0;
}

.hero-desc {
    color: rgba(255, 255, 255, 0.8);
    font-size: 13px; line-height: 1.4;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
}

/* Grid Layout */
.dashboard-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    grid-auto-rows: 1fr;
    gap: 12px;
}

.dashboard-tile {
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 16px;
    padding: 16px;
    cursor: pointer;
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 16px;
    transition: background 0.2s, transform 0.2s, border-color 0.2s;
}

.dashboard-tile:hover {
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.15);
    transform: translateY(-2px);
}

.dashboard-tile:active {
    transform: translateY(0);
}

.tile-icon-wrapper {
    position: relative;
    width: 42px; height: 42px;
    background: var(--bg-root, #121212);
    border-radius: 12px;
    display: flex; align-items: center; justify-content: center;
}

.tile-icon {
    width: 22px; height: 22px;
    fill: var(--text-gray);
}

.tile-image-icon {
    width: 22px; height: 22px;
    display: flex; align-items: center; justify-content: center;
}

.tile-image-icon img {
    width: 100%; height: 100%; border-radius: 4px; object-fit: contain;
}

.status-dot {
    position: absolute; bottom: -2px; right: -2px;
    width: 12px; height: 12px; border-radius: 50%;
    border: 2px solid var(--bg-item); background: #ff3b30;
    box-shadow: 0 0 8px rgba(255, 59, 48, 0.6);
}

.status-dot.connected { background: #34c759; box-shadow: 0 0 8px rgba(52, 199, 89, 0.6); }
.status-dot.connecting { background: #ff9500; box-shadow: 0 0 8px rgba(255, 149, 0, 0.6); }
.status-dot.idle { background: var(--text-gray); box-shadow: none; }

.tile-content {
    display: flex; flex-direction: column; gap: 4px;
}

.tile-label {
    font-size: 14px; font-weight: 600; color: var(--text-color, #fff);
}

.tile-sublabel {
    font-size: 12px; color: var(--vk-blue, #528bcc); font-weight: 500;
    white-space: normal;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
}
</style>
