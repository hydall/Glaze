<script setup>
import { onMounted, ref, computed } from 'vue';
import { t, updateLanguage } from '@/utils/i18n.js';
import { initRipple } from '@/core/services/ui.js';

import { getApiPresets, fetchRemoteModels } from '@/core/config/APISettings.js';
import { presetState, DEFAULT_PRESETS } from '@/core/states/presetState.js';
import { lorebookState } from '@/core/states/lorebookState.js';
import { activePersona } from '@/core/states/personaState.js';

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
    const str = [p.systemPrompt || '', p.postHistoryInstructions || '', p.jailbreakPrompt || '', p.jailbreakCharPrompt || ''].join(' ');
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
    window.dispatchEvent(new CustomEvent('navigate-to', { detail: viewId }));
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
    <div id="view-tools" class="view active-view">
        <div 
            v-for="tool in tools"
            :key="tool.id"
            class="menu-group"
            style="margin-bottom: 12px;"
        >
            <div
                class="menu-item tool-card"
                :class="{ 'has-bg': tool.backgroundImage, 'is-large': tool.isLarge, 'is-persona': tool.id === 'view-personas' }"
                :style="tool.backgroundImage ? `background-image: linear-gradient(rgba(0,0,0,0.6), rgba(0,0,0,0.7)), url(${tool.backgroundImage}); background-size: cover; background-position: center; border: 1px solid rgba(255,255,255,0.1); border-radius: 16px; overflow: hidden;` : ''"
                @click="openView(tool.id)"
            >
                <!-- Custom Persona Avatar Block -->
                <template v-if="tool.id === 'view-personas'">
                    <div class="avatar-wrapper persona-avatar-box">
                        <div class="avatar-header-overlay">{{ tool.label }}</div>
                        <img v-if="tool.image" :src="tool.image" class="avatar-img">
                        <div v-else class="avatar-placeholder">
                            {{ (tool.sublabel || "?")[0].toUpperCase() }}
                        </div>
                        
                        <div class="persona-details-overlay">
                            <div class="persona-name-row">
                                <span class="persona-name">{{ tool.sublabel }}</span>
                                <span v-if="tool.tokens" class="tool-tokens persona-tokens">{{ tool.tokens }}t</span>
                            </div>
                            <div class="tool-desc persona-desc" v-if="tool.desc">{{ tool.desc }}</div>
                        </div>
                    </div>
                </template>

                <!-- Default Tool Card Layout -->
                <template v-else>
                    <div class="tool-icon-wrapper" :style="tool.backgroundImage ? 'background: rgba(255,255,255,0.1);' : ''">
                        <img v-if="tool.image" :src="tool.image" class="tool-image"/>
                        <span v-else-if="tool.imageIcon" class="tool-image-icon">
                            <img :src="tool.imageIcon" style="width:100%;height:100%;object-fit:contain;border-radius:4px;" onerror="this.style.display='none';this.nextElementSibling.style.display='block'">
                            <svg style="display:none;" class="menu-icon" viewBox="0 0 24 24"><path :d="tool.icon"/></svg>
                        </span>
                        <svg v-else class="menu-icon" viewBox="0 0 24 24" :style="tool.backgroundImage ? 'fill: #fff;' : ''">
                            <path :d="tool.icon"/>
                        </svg>
                        
                        <div v-if="tool.status" :class="['status-dot', tool.status]"></div>
                    </div>
                    
                    <div class="tool-info">
                        <div class="tool-title" :style="tool.backgroundImage ? 'color: #fff;' : ''">
                            {{ tool.label }}
                            <span v-if="tool.tokens !== undefined" class="tool-tokens" :style="tool.backgroundImage ? 'background: rgba(255,255,255,0.2); color: #fff;' : ''">{{ tool.tokens }}t</span>
                        </div>
                        <div class="tool-sublabel" v-if="tool.sublabel" :style="tool.backgroundImage ? 'color: #90caf9;' : ''">{{ tool.sublabel }}</div>
                        <div class="tool-desc" v-if="tool.desc" :style="tool.backgroundImage ? 'color: rgba(255,255,255,0.7);' : ''">{{ tool.desc }}</div>
                    </div>
                    
                    <svg class="menu-arrow" viewBox="0 0 24 24" :style="tool.backgroundImage ? 'stroke: #fff; opacity: 0.8;' : ''">
                        <path d="M9 18l6-6-6-6"/>
                    </svg>
                </template>
            </div>
        </div>
    </div>
</template>

<style scoped>
.tool-card {
    align-items: center;
    padding: 12px 16px;
    height: auto;
    min-height: 56px;
}

.tool-card.is-large {
    min-height: 100px;
    padding: 20px 16px;
}

.tool-card.is-persona {
    padding: 0;
    border: none;
    background: transparent !important;
    overflow: hidden;
    border-radius: 20px;
}

/* Avatar Block Styles from GenericEditor */
.avatar-wrapper {
    width: 100%;
    aspect-ratio: 1 / 1;
    position: relative;
    cursor: pointer;
    background-color: var(--bg-gray, #222);
    border-radius: 20px;
    overflow: hidden;
}

.avatar-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.avatar-placeholder {
    width: 100%;
    height: 100%;
    background: linear-gradient(135deg, #66ccff 0%, #7996ce 100%);
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 6em;
}

.avatar-header-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    padding: 14px 16px 30px 16px;
    font-size: 14px;
    font-weight: 700;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.9);
    letter-spacing: 0.5px;
    z-index: 2;
    background: linear-gradient(to bottom, rgba(0,0,0,0.6), transparent);
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    pointer-events: none;
}

/* Persona Details Overlay */
.persona-details-overlay {
    position: absolute;
    bottom: 0;
    left: 0;
    width: 100%;
    padding: 30px 16px 16px 16px;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.4) 60%, transparent 100%);
    display: flex;
    flex-direction: column;
    gap: 4px;
    pointer-events: none;
}

.persona-name-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
}

.persona-name {
    font-size: 18px;
    font-weight: 600;
    color: #fff;
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
}

.persona-tokens {
    background: rgba(255, 255, 255, 0.2) !important;
    color: #fff !important;
}

.persona-desc {
    color: rgba(255, 255, 255, 0.8) !important;
    white-space: normal !important;
    display: -webkit-box !important;
    -webkit-line-clamp: 2 !important;
    -webkit-box-orient: vertical !important;
    font-size: 13px !important;
    line-height: 1.4 !important;
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
}

.tool-card.is-large .tool-desc {
    white-space: normal;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    -webkit-box-orient: vertical;
    margin-top: 6px;
    line-height: 1.4;
}

.tool-icon-wrapper {
    position: relative;
    width: 32px;
    height: 32px;
    border-radius: 8px;
    flex-shrink: 0;
    margin-right: 14px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--bg-root, #121212);
}

.tool-image {
    width: 100%;
    height: 100%;
    object-fit: cover;
    border-radius: 8px;
}

.tool-image-icon {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
}

.menu-icon {
    width: 20px;
    height: 20px;
    fill: var(--text-gray);
}

.status-dot {
    position: absolute;
    bottom: -2px;
    right: -2px;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    border: 2px solid var(--bg-item);
    background: #ff3b30;
}
.status-dot.connected { background: #34c759; }
.status-dot.connecting { background: #ff9500; }
.status-dot.idle { background: var(--text-gray); }

.tool-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    justify-content: center;
    min-width: 0;
}

.tool-title {
    font-size: 15px;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: 8px;
}

.tool-tokens {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-gray);
    background: rgba(128, 128, 128, 0.15);
    padding: 2px 6px;
    border-radius: 10px;
}

.tool-sublabel {
    font-size: 13px;
    color: var(--vk-blue, #528bcc);
    margin-top: 2px;
    font-weight: 500;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.tool-desc {
    font-size: 12px;
    color: var(--text-gray);
    margin-top: 2px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

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
