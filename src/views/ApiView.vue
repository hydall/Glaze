<script setup>
import { ref, reactive, computed, onMounted, onBeforeUnmount, watch } from 'vue';
import { normalizeEndpoint, fetchRemoteModels, getApiPresets, saveApiPresets, getApiConfig, getBlacklistedProvider } from '@/core/config/APISettings.js';
import { updateLanguage, translations } from '@/utils/i18n.js';
import { initRipple } from '@/core/services/ui.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet, bottomSheetState } from '@/core/states/bottomSheetState.js';
import SheetView from '@/components/ui/SheetView.vue';
import HelpTip from '@/components/ui/HelpTip.vue';
import ConnectionStatus from '@/components/ui/ConnectionStatus.vue';

const sheet = ref(null);

const headerState = reactive({
    title: '',
    actions: [],
});

// --- API Settings State ---
const apiSettings = reactive({
    endpoint: '',
    key: '',
    model: '',
    maxTokens: 8000,
    contextSize: 32000,
    temp: 0.7,
    topP: 0.9,
    stream: true,
    autoHideImages: false,
    autoHideImagesN: 1,
    reasoningEnabled: false,
    reasoningEffort: 'medium'
});

const showApiKey = ref(false);

const errorMessage = ref('');
const apiStatus = ref('idle'); // idle, connecting, connected, failed
const availableModels = ref([]);
const apiPresets = ref([]);
const activeApiPresetId = ref('default');

const activeApiPreset = computed(() => {
    return apiPresets.value.find(p => p.id === activeApiPresetId.value) || apiPresets.value[0];
});

// --- Blacklist Warning ---
let blacklistCountdownTimer = null;

function showBlacklistWarning(providerName) {
    if (blacklistCountdownTimer) clearInterval(blacklistCountdownTimer);
    let countdown = 10;
    showBottomSheet({
        title: providerName,
        locked: true,
        bigInfo: {
            icon: '<svg viewBox="0 0 24 24" style="fill:#ff9800"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>',
            description: t('blacklist_warning_desc').replace('{providerName}', providerName),
            glossaryChip: { term: 'api', hint: t('blacklist_glossary_hint') || 'Recommended providers are here:', label: t('blacklist_glossary_chip') || 'Providers' },
            buttonText: `OK (${countdown})`,
            buttonDisabled: true,
            onButtonClick: closeBottomSheet
        }
    });
    blacklistCountdownTimer = setInterval(() => {
        countdown--;
        if (bottomSheetState.value.bigInfo) {
            bottomSheetState.value.bigInfo.buttonText = countdown > 0 ? `OK (${countdown})` : 'OK';
            bottomSheetState.value.bigInfo.buttonDisabled = countdown > 0;
        }
        if (countdown <= 0) {
            bottomSheetState.value.locked = false;
            clearInterval(blacklistCountdownTimer);
            blacklistCountdownTimer = null;
        }
    }, 1000);
}

function loadApiSettings() {
    apiSettings.endpoint = localStorage.getItem('api-endpoint') || '';
    apiSettings.key = localStorage.getItem('api-key') || '';
    apiSettings.model = localStorage.getItem('api-model') || '';
    const mt = parseInt(localStorage.getItem('api-max-tokens'));
    apiSettings.maxTokens = isNaN(mt) ? 8000 : mt;
    apiSettings.contextSize = parseInt(localStorage.getItem('api-context')) || 32000;
    apiSettings.temp = parseFloat(localStorage.getItem('gz_api_temp')) || 0.7;
    apiSettings.topP = parseFloat(localStorage.getItem('gz_api_topp')) || 0.9;
    apiSettings.stream = localStorage.getItem('gz_api_stream') === 'true';
    apiSettings.autoHideImages = localStorage.getItem('gz_api_auto_hide_images') === 'true';
    apiSettings.autoHideImagesN = parseInt(localStorage.getItem('gz_api_auto_hide_images_n') || '1', 10);
    apiSettings.reasoningEnabled = localStorage.getItem('gz_api_request_reasoning') === 'true';
    apiSettings.reasoningEffort = localStorage.getItem('gz_api_reasoning_effort') || 'medium';
}

function saveApiSetting(key, value) {
    if (key === 'api-endpoint') {
        const normalized = normalizeEndpoint(value);
        localStorage.setItem('gz_api_endpoint_normalized', normalized);
    }
    localStorage.setItem(key, value);
    
    // Update current preset
    if (activeApiPreset.value) {
        const map = {
            'api-endpoint': 'endpoint',
            'api-key': 'key',
            'api-model': 'model',
            'api-max-tokens': 'max_tokens',
            'api-context': 'context',
            'gz_api_temp': 'temp',
            'gz_api_topp': 'topp',
            'gz_api_stream': 'stream',
            'gz_api_auto_hide_images': 'auto_hide_images',
            'gz_api_auto_hide_images_n': 'auto_hide_images_n',
            'gz_api_request_reasoning': 'reasoning_enabled',
            'gz_api_reasoning_effort': 'reasoning_effort'
        };
        if (map[key]) {
            activeApiPreset.value[map[key]] = value;
            saveApiPresets(apiPresets.value);
        }
    }
}

let debounceTimer = null;
function onApiInput(key, value) {
    saveApiSetting(key, value);
    if (key === 'api-endpoint' || key === 'api-key') {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
            if (key === 'api-endpoint') {
                const endpoint = localStorage.getItem('gz_api_endpoint_normalized') || value;
                const blacklisted = getBlacklistedProvider(endpoint);
                if (blacklisted) showBlacklistWarning(blacklisted.name);
            }
            checkConnection();
        }, 1000);
    }
}

function flushApiDebounce() {
    if (debounceTimer) {
        clearTimeout(debounceTimer);
        debounceTimer = null;
        checkConnection();
    }
}

async function checkConnection() {
    const endpoint = localStorage.getItem('gz_api_endpoint_normalized') || apiSettings.endpoint;

    if (!endpoint) {
        apiStatus.value = 'failed';
        return;
    }
    
    apiStatus.value = 'connecting';
    try {
        const models = await fetchRemoteModels(endpoint, apiSettings.key);
        availableModels.value = models;
        apiStatus.value = 'connected';
    } catch (e) {
        console.warn(e);
        apiStatus.value = 'failed';
        errorMessage.value = e.message || 'Connection failed';
    }
}

function openModelSelector() {
    const items = availableModels.value.length > 0 ? availableModels.value.map(m => ({
        label: m,
        onClick: () => {
            apiSettings.model = m;
            saveApiSetting('api-model', m);
            closeBottomSheet();
        }
    })) : [{ label: t('no_models_found') || "No models found", onClick: closeBottomSheet }];

    showBottomSheet({ title: "Select Model", items });
}

function openReasoningEffortSelector() {
    const options = [
        { value: 'low', label: t('reasoning_effort_low') || 'Low' },
        { value: 'medium', label: t('reasoning_effort_medium') || 'Medium' },
        { value: 'high', label: t('reasoning_effort_high') || 'High' }
    ];

    const items = options.map(opt => ({
        label: opt.label,
        icon: apiSettings.reasoningEffort === opt.value ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
        onClick: () => {
            apiSettings.reasoningEffort = opt.value;
            saveApiSetting('gz_api_reasoning_effort', opt.value);
            closeBottomSheet();
        }
    }));

    showBottomSheet({
        title: t('label_reasoning_effort') || 'Reasoning Effort',
        items
    });
}

function createNewApiPreset() {
    showBottomSheet({
        title: t('new_preset') || 'New Preset',
        input: {
            placeholder: t('placeholder_preset_name') || 'Enter preset name',
            value: '',
            confirmLabel: t('btn_create') || 'Create',
            onConfirm: (name) => {
                const newPreset = {
                    id: Date.now().toString(36),
                    name: name,
                    endpoint: apiSettings.endpoint,
                    key: apiSettings.key,
                    model: apiSettings.model,
                    max_tokens: apiSettings.maxTokens,
                    context: apiSettings.contextSize,
                    temp: apiSettings.temp,
                    topp: apiSettings.topP,
                    stream: apiSettings.stream,
                    auto_hide_images: apiSettings.autoHideImages,
                    auto_hide_images_n: apiSettings.autoHideImagesN,
                    reasoning_effort: apiSettings.reasoningEffort
                };

                apiPresets.value.push(newPreset);
                saveApiPresets(apiPresets.value);
                
                activeApiPresetId.value = newPreset.id;
                localStorage.setItem('gz_active_api_preset_id', newPreset.id);
                closeBottomSheet();
            }
        }
    });
}

function applyApiPreset(p) {
    activeApiPresetId.value = p.id;
    localStorage.setItem('gz_active_api_preset_id', p.id);
    
    apiSettings.endpoint = p.endpoint;
    apiSettings.key = p.key;
    apiSettings.model = p.model;
    apiSettings.maxTokens = p.max_tokens;
    apiSettings.contextSize = p.context;
    apiSettings.temp = p.temp;
    apiSettings.topP = p.topp;
    apiSettings.stream = p.stream;
    
    apiSettings.autoHideImages = (p.auto_hide_images === true || p.auto_hide_images === 'true');
    apiSettings.autoHideImagesN = parseInt(p.auto_hide_images_n || '1', 10);
    apiSettings.reasoningEffort = p.reasoning_effort || 'medium';
    
    saveApiSetting('api-endpoint', p.endpoint);
    saveApiSetting('api-key', p.key);
    saveApiSetting('api-model', p.model);
    saveApiSetting('api-max-tokens', p.max_tokens);
    saveApiSetting('api-context', p.context);
    saveApiSetting('gz_api_temp', p.temp);
    saveApiSetting('gz_api_topp', p.topp);
    saveApiSetting('gz_api_stream', p.stream);
    saveApiSetting('gz_api_auto_hide_images', apiSettings.autoHideImages.toString());
    saveApiSetting('gz_api_auto_hide_images_n', apiSettings.autoHideImagesN.toString());
    saveApiSetting('gz_api_reasoning_effort', apiSettings.reasoningEffort);
    
    checkConnection();
}

function confirmDeleteApiPreset(id) {
    const preset = apiPresets.value.find(p => p.id === id);
    if (!preset) return;

    showBottomSheet({
        title: `${t('confirm_delete_preset')} "${preset.name}"?`,
        items: [
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    const index = apiPresets.value.findIndex(p => p.id === id);
                    if (index !== -1) {
                        apiPresets.value.splice(index, 1);
                        saveApiPresets(apiPresets.value);

                        if (activeApiPresetId.value === id) {
                            const defaultPreset = apiPresets.value.find(p => p.id === 'default') || apiPresets.value[0];
                            if (defaultPreset) {
                                applyApiPreset(defaultPreset);
                            }
                        }
                    }
                    closeBottomSheet();
                }
            },
            {
                label: t('btn_cancel') || 'Cancel',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: closeBottomSheet
            }
        ]
    });
}

function openApiPresetOptions(preset) {
    const items = [];

    items.push({
        label: t('action_edit_name') || 'Change Name',
        icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            showBottomSheet({
                title: t('action_edit_name') || 'Change Name',
                input: {
                    placeholder: t('placeholder_preset_name') || 'Enter name',
                    value: preset.name,
                    confirmLabel: t('btn_save') || 'Save',
                    onConfirm: (val) => {
                        if (val) {
                            preset.name = val;
                            saveApiPresets(apiPresets.value);
                            closeBottomSheet();
                        }
                    }
                }
            });
        }
    });

    items.push({
        label: t('btn_delete') || 'Delete',
        icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
        iconColor: '#ff4444',
        isDestructive: true,
        onClick: () => {
            closeBottomSheet();
            confirmDeleteApiPreset(preset.id);
        }
    });

    showBottomSheet({
        title: preset.name,
        items
    });
}

function openApiPresetSelector() {
    const cardItems = apiPresets.value.map(p => {
        const isActive = activeApiPresetId.value === p.id;
        const item = {
            label: p.name,
            sublabel: isActive ? (t('preset_active') || 'Active') : '',
            icon: getPresetIcon(p.endpoint, isActive),
            onClick: () => {
                applyApiPreset(p);
                closeBottomSheet();
            }
        };

        if (p.id !== 'default') {
            item.actions = [{
                icon: '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>',
                color: 'var(--text-gray)',
                onClick: (e) => {
                    e.stopPropagation();
                    closeBottomSheet();
                    openApiPresetOptions(p);
                }
            }];
        }

        return item;
    });

    cardItems.push({
        label: t('action_create_new') || 'Create New',
        sublabel: t('api_create_preset_desc') || 'Add new preset',
        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            createNewApiPreset();
        }
    });

    showBottomSheet({
        title: t('api_presets') || 'API Presets',
        cardItems
    });
}

// --- Favicon helper ---
function getPresetIcon(endpoint, isActive) {
    const dotColor = isActive ? 'var(--vk-blue)' : 'var(--text-gray)';
    const dotSvg = `<svg viewBox="0 0 24 24" style="fill:currentColor;"><circle cx="12" cy="12" r="10" fill="${dotColor}"/></svg>`;

    if (!endpoint) return dotSvg;

    let origin;
    try {
        const href = /^https?:\/\//i.test(endpoint) ? endpoint : 'http://' + endpoint;
        origin = new URL(href).origin;
    } catch {
        return dotSvg;
    }

    const faviconUrl = origin + '/favicon.ico';
    const escapedDot = dotSvg.replace(/'/g, '&#39;');
    return `<span style="display:inline-flex;align-items:center;justify-content:center;width:100%;height:100%;"><img src="${faviconUrl}" style="width:100%;height:100%;border-radius:6px;object-fit:contain;" onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><svg style="display:none;fill:currentColor;width:100%;height:100%;" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="${dotColor}"/></svg></span>`;
}

// --- Helpers ---
const t = (key) => {
    return translations[currentLang.value] ? translations[currentLang.value][key] : key;
};

// --- Lifecycle ---
async function open() {
    sheet.value?.open();
    headerState.title = t('tab_api') || 'API';
}

function close() {
    sheet.value?.close();
}

defineExpose({ open, close });

onMounted(async () => {
    initRipple();
    loadApiSettings();
    
    apiPresets.value = await getApiPresets();
    activeApiPresetId.value = localStorage.getItem('gz_active_api_preset_id') || 'default';
    
    checkConnection();
    updateLanguage();
    headerState.title = t('tab_api') || 'API';
});

onBeforeUnmount(() => {
    flushApiDebounce();
    if (blacklistCountdownTimer) clearInterval(blacklistCountdownTimer);
});
</script>

<template>
    <SheetView ref="sheet" :title="headerState.title">
        <div class="gen-sheet-body">
                <ConnectionStatus :status="apiStatus" :error-message="errorMessage" @retry="checkConnection">
                    <div class="preset-selector" @click="openApiPresetSelector">
                        <span>{{ activeApiPreset?.name || 'Default' }}</span>
                        <svg viewBox="0 0 24 24" style="width: 20px; height: 20px; fill: currentColor;"><path d="M7 10l5 5 5-5z"/></svg>
                    </div>
                </ConnectionStatus>

                <div class="menu-group">
                    <div class="section-header">{{ t('section_connection') || 'Connection' }} <HelpTip term="api"/></div>
                    <div class="settings-item">
                        <label>API Endpoint</label>
                        <input type="text" v-model="apiSettings.endpoint" @input="onApiInput('api-endpoint', $event.target.value)" placeholder="http://127.0.0.1:5000/v1" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                    </div>
                    <div class="settings-item">
                        <label>Model Name</label>
                        <div style="position: relative;">
                            <input type="text" v-model="apiSettings.model" @input="onApiInput('api-model', $event.target.value)" placeholder="gemini-3-pro-preview" style="width: 100%; padding-right: 44px;" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                            <div @click="openModelSelector" style="position: absolute; right: 0; top: 0; bottom: 0; width: 44px; cursor: pointer; display: flex; align-items: center; justify-content: center;">
                                <svg viewBox="0 0 24 24" style="width: 24px; height: 24px; fill: var(--text-gray);"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                    </div>
                    <div class="settings-item">
                        <label>API Key <HelpTip term="apikey"/></label>
                        <div style="position: relative;">
                            <input :type="showApiKey ? 'text' : 'password'" v-model="apiSettings.key" @input="onApiInput('api-key', $event.target.value)" placeholder="sk-..." style="width: 100%; padding-right: 44px;" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                            <div @click="showApiKey = !showApiKey" style="position: absolute; right: 0; top: 0; bottom: 0; width: 44px; cursor: pointer; display: flex; align-items: center; justify-content: center;">
                                <svg v-if="showApiKey" viewBox="0 0 24 24" style="width: 20px; height: 20px; fill: var(--text-gray);"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>
                                <svg v-else viewBox="0 0 24 24" style="width: 20px; height: 20px; fill: var(--text-gray);"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.82l2.92 2.92c1.51-1.39 2.72-3.12 3.44-5.04-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.35-3-3-3l-.17.01z"/></svg>
                            </div>
                        </div>
                    </div>
                    <div class="settings-item-checkbox">
                        <div class="settings-text-col">
                            <label>{{ t('label_stream') || 'Streaming response' }} <HelpTip term="streaming"/></label>
                            <div class="settings-desc">{{ t('desc_stream') || 'Show text as it is being generated' }}</div>
                        </div>
                        <input type="checkbox" v-model="apiSettings.stream" @change="onApiInput('gz_api_stream', $event.target.checked)" class="vk-switch">
                    </div>
                </div>

                <div class="menu-group">
                    <div class="section-header">{{ t('section_gen_params') || 'Generation Parameters' }} <HelpTip term="guided"/></div>
                    <div class="settings-item-range">
                        <div class="range-row">
                            <label data-i18n="label_temperature">Temperature</label>
                            <input type="number" v-model.number="apiSettings.temp" @input="onApiInput('gz_api_temp', $event.target.value)" class="range-input-val" step="0.01">
                        </div>
                        <input type="range" v-model.number="apiSettings.temp" @input="onApiInput('gz_api_temp', $event.target.value)" min="0" max="2" step="0.01">
                    </div>
                    <div class="settings-item-range">
                        <div class="range-row">
                            <label data-i18n="label_top_p">Top P</label>
                            <input type="number" v-model.number="apiSettings.topP" @input="onApiInput('gz_api_topp', $event.target.value)" class="range-input-val" step="0.01">
                        </div>
                        <input type="range" v-model.number="apiSettings.topP" @input="onApiInput('gz_api_topp', $event.target.value)" min="0" max="1" step="0.01">
                    </div>
                    <div class="settings-item">
                        <label data-i18n="label_max_tokens">Max Output Tokens</label>
                        <input type="number" v-model.number="apiSettings.maxTokens" @input="onApiInput('api-max-tokens', $event.target.value)">
                    </div>
                    <div class="settings-item">
                        <label data-i18n="label_context_size">Context Size</label>
                        <input type="number" v-model.number="apiSettings.contextSize" @input="onApiInput('api-context', $event.target.value)">
                    </div>

                    <div class="settings-item-checkbox">
                        <div class="settings-text-col">
                            <label>{{ t('label_auto_hide_images') || 'Auto-hide images' }} <HelpTip term="image-gen"/></label>
                            <div class="settings-desc">{{ t('desc_auto_hide_images') || 'Hide images after N assistant responses' }}</div>
                        </div>
                        <input type="checkbox" v-model="apiSettings.autoHideImages" @change="onApiInput('gz_api_auto_hide_images', $event.target.checked)" class="vk-switch">
                    </div>

                    <Transition name="fade-height">
                        <div v-if="apiSettings.autoHideImages" class="settings-item" style="margin-top: 0; padding-top: 0;">
                            <label>{{ t('label_auto_hide_images_n') || 'Responses count' }}</label>
                            <input type="number" v-model.number="apiSettings.autoHideImagesN" @input="onApiInput('gz_api_auto_hide_images_n', $event.target.value)" min="1">
                        </div>
                    </Transition>
                </div>

                <div class="menu-group">
                    <div class="section-header">{{ t('label_reasoning_settings') || 'Reasoning' }} <HelpTip term="preset-reasoning"/></div>
                    <div class="settings-item-checkbox">
                        <div class="settings-text-col">
                            <label>{{ t('label_show_reasoning') || 'Show Native Reasoning' }}</label>
                            <div class="settings-desc">{{ t('desc_show_reasoning') || "Shows reasoning_content. Doesn't affect model's reasoning." }}</div>
                        </div>
                        <input type="checkbox" v-model="apiSettings.reasoningEnabled" @change="onApiInput('gz_api_request_reasoning', $event.target.checked)" class="vk-switch">
                    </div>
                    <div class="settings-item" @click="openReasoningEffortSelector">
                        <label>{{ t('label_reasoning_effort') || 'Reasoning Effort' }}</label>
                        <div class="clickable-selector">
                            <span>{{ t('reasoning_effort_' + apiSettings.reasoningEffort) || apiSettings.reasoningEffort }}</span>
                            <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                        </div>
                    </div>
                </div>
        </div>
    </SheetView>

</template>

<style scoped>
.preset-selector {
  height: 32px;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  font-weight: 600;
  font-size: 13px;
  color: var(--vk-blue);
  padding: 0 14px;
  border-radius: 16px;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  overflow: hidden;
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.preset-selector svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.gen-sheet-header {
    height: 56px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 16px;
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
}

.header-title {
    font-weight: 600;
    font-size: 17px;
}

.gen-sheet-body { position: relative; }

.clickable-selector {
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--bg-item);
    border: 1px solid var(--border-color);
    padding: 0 16px;
    height: 48px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 15px;
    transition: background 0.2s;
}

.clickable-selector:active {
    background: var(--bg-item-active);
}

.clickable-selector svg {
    width: 24px;
    height: 24px;
    fill: var(--text-gray);
    opacity: 0.5;
}
</style>
