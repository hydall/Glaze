<script setup>
import { ref, computed, watch } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { getImageGenSettings, saveImageGenSettings, fetchImageModels, saveAdditionalReferences } from '@/core/services/imageGenService.js';

const sheet = ref(null);
const t = (key) => translations[currentLang.value]?.[key] || key;

const settings = ref(getImageGenSettings());
const models = ref([]);
const isFetchingModels = ref(false);
const fetchError = ref('');

// Additional references
const refImageInput = ref(null);
const pendingRefIndex = ref(-1);

const open = () => {
    settings.value = getImageGenSettings();
    models.value = [];
    fetchError.value = '';
    sheet.value?.open();
};

const save = () => {
    saveImageGenSettings(settings.value);
};

watch(settings, save, { deep: true });

const onFetchModels = async () => {
    isFetchingModels.value = true;
    fetchError.value = '';
    try {
        const list = await fetchImageModels();
        models.value = list;
        if (!list.length) fetchError.value = t('imggen_no_models') || 'No image models found';
    } catch (e) {
        fetchError.value = e.message || 'Failed to fetch models';
    } finally {
        isFetchingModels.value = false;
    }
};

const showGeminiOptions = computed(() => settings.value.apiType === 'gemini');
const showOpenAIOptions = computed(() => settings.value.apiType === 'openai');
const showNaisteraOptions = computed(() => settings.value.apiType === 'naistera');

// Dropdown selectors via bottom sheet
const openModelSelector = () => {
    const items = models.value.length > 0
        ? models.value.map(m => ({
            label: m,
            onClick: () => { settings.value.model = m; closeBottomSheet(); }
        }))
        : [{ label: t('imggen_no_models') || 'No models found — tap refresh', onClick: closeBottomSheet }];
    showBottomSheet({ title: t('imggen_model') || 'Model', items });
};

const openApiTypeSelector = () => {
    const options = [
        { label: 'OpenAI', value: 'openai' },
        { label: 'Gemini', value: 'gemini' },
        { label: 'Naistera', value: 'naistera' },
    ];
    showBottomSheet({
        title: t('imggen_api_type') || 'API Type',
        items: options.map(o => ({
            label: o.label,
            sublabel: settings.value.apiType === o.value ? (t('preset_active') || 'Active') : '',
            onClick: () => {
                settings.value.apiType = o.value;
                if (o.value === 'naistera' && !settings.value.endpoint) {
                    settings.value.endpoint = 'https://naistera.org';
                }
                closeBottomSheet();
            }
        }))
    });
};

const openSizeSelector = () => {
    const options = [
        { label: '1024×1024', value: '1024x1024' },
        { label: '1792×1024 (16:9)', value: '1792x1024' },
        { label: '1024×1792 (9:16)', value: '1024x1792' },
        { label: '512×512', value: '512x512' },
    ];
    showBottomSheet({
        title: t('imggen_size') || 'Image Size',
        items: options.map(o => ({
            label: o.label,
            sublabel: settings.value.size === o.value ? (t('preset_active') || 'Active') : '',
            onClick: () => { settings.value.size = o.value; closeBottomSheet(); }
        }))
    });
};

const openQualitySelector = () => {
    showBottomSheet({
        title: t('imggen_quality') || 'Quality',
        items: ['standard', 'hd'].map(v => ({
            label: v === 'hd' ? 'HD' : 'Standard',
            sublabel: settings.value.quality === v ? (t('preset_active') || 'Active') : '',
            onClick: () => { settings.value.quality = v; closeBottomSheet(); }
        }))
    });
};

const openAspectRatioSelector = (field, options) => {
    showBottomSheet({
        title: t('imggen_aspect_ratio') || 'Aspect Ratio',
        items: options.map(v => ({
            label: v,
            sublabel: settings.value[field] === v ? (t('preset_active') || 'Active') : '',
            onClick: () => { settings.value[field] = v; closeBottomSheet(); }
        }))
    });
};

const openResolutionSelector = () => {
    showBottomSheet({
        title: t('imggen_image_size') || 'Resolution',
        items: ['1K', '2K', '4K'].map(v => ({
            label: v,
            sublabel: settings.value.imageSize === v ? (t('preset_active') || 'Active') : '',
            onClick: () => { settings.value.imageSize = v; closeBottomSheet(); }
        }))
    });
};

const openNaisteraModelSelector = () => {
    const options = ['grok', 'nano banana'];
    showBottomSheet({
        title: t('imggen_model') || 'Model',
        items: options.map(v => ({
            label: v,
            sublabel: settings.value.naisteraModel === v ? (t('preset_active') || 'Active') : '',
            onClick: () => { settings.value.naisteraModel = v; closeBottomSheet(); }
        }))
    });
};

const openRefMatchModeSelector = (i) => {
    showBottomSheet({
        title: 'Match Mode',
        items: ['match', 'always'].map(v => ({
            label: v,
            sublabel: settings.value.additionalReferences[i]?.matchMode === v ? (t('preset_active') || 'Active') : '',
            onClick: () => { settings.value.additionalReferences[i].matchMode = v; closeBottomSheet(); }
        }))
    });
};

// Additional references helpers
const addRef = () => {
    if (settings.value.additionalReferences.length >= 8) return;
    settings.value.additionalReferences.push({ name: '', imageData: '', matchMode: 'match' });
};

const removeRef = (i) => {
    settings.value.additionalReferences.splice(i, 1);
};

const pickRefImage = (i) => {
    pendingRefIndex.value = i;
    refImageInput.value?.click();
};

const onRefImageSelected = (e) => {
    const file = e.target.files?.[0];
    if (!file || pendingRefIndex.value < 0) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
        const idx = pendingRefIndex.value;
        if (idx >= 0 && idx < settings.value.additionalReferences.length) {
            settings.value.additionalReferences[idx].imageData = ev.target.result;
            saveAdditionalReferences(settings.value.additionalReferences);
        }
        pendingRefIndex.value = -1;
    };
    reader.readAsDataURL(file);
    e.target.value = '';
};

defineExpose({ open });
</script>

<template>
    <SheetView ref="sheet" :title="t('imggen_title') || 'Image Generation'">
        <div class="gen-sheet-body">

            <!-- Enable toggle -->
            <div class="menu-group">
                <div class="settings-item-checkbox">
                    <div class="settings-text-col">
                        <label>{{ t('imggen_enabled') || 'Enable image generation' }}</label>
                        <div class="settings-desc">{{ t('imggen_enabled_desc') || 'Auto-generate images from AI tags' }}</div>
                    </div>
                    <input type="checkbox" v-model="settings.enabled" class="vk-switch">
                </div>
            </div>

            <template v-if="settings.enabled">

                <!-- Connection -->
                <div class="menu-group">
                    <div class="section-header">{{ t('section_connection') || 'Connection' }}</div>

                    <!-- API Type selector row -->
                    <div class="settings-item selector-row" @click="openApiTypeSelector">
                        <label>{{ t('imggen_api_type') || 'API Type' }}</label>
                        <div class="selector-value">
                            <span>{{ settings.apiType === 'openai' ? 'OpenAI' : settings.apiType === 'gemini' ? 'Gemini' : 'Naistera' }}</span>
                            <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                        </div>
                    </div>

                    <!-- Endpoint -->
                    <div class="settings-item">
                        <label>{{ t('imggen_endpoint') || 'Endpoint URL' }}</label>
                        <input
                            type="text"
                            v-model="settings.endpoint"
                            :placeholder="showGeminiOptions ? 'https://generativelanguage.googleapis.com' : showNaisteraOptions ? 'https://naistera.org' : 'https://api.openai.com'"
                            autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
                        >
                    </div>

                    <!-- API Key -->
                    <div class="settings-item">
                        <label>{{ t('imggen_api_key') || 'API Key' }}</label>
                        <input
                            type="password"
                            v-model="settings.apiKey"
                            :placeholder="showNaisteraOptions ? 'Telegram bot token' : 'sk-...'"
                            autocomplete="off"
                        >
                    </div>

                    <!-- Naistera hint -->
                    <div v-if="showNaisteraOptions" class="settings-item naistera-hint">
                        Получите токен в Telegram боте Naistera и выберите модель.
                    </div>
                </div>

                <!-- Model & Parameters -->
                <div class="menu-group">
                    <div class="section-header">{{ t('imggen_model') || 'Model' }}</div>

                    <!-- Naistera model selector row -->
                    <div v-if="showNaisteraOptions" class="settings-item selector-row" @click="openNaisteraModelSelector">
                        <label>{{ t('imggen_model') || 'Model' }}</label>
                        <div class="selector-value">
                            <span>{{ settings.naisteraModel || 'grok' }}</span>
                            <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                        </div>
                    </div>

                    <!-- Model (OpenAI) — text input + fetch + dropdown -->
                    <div v-if="showOpenAIOptions" class="settings-item">
                        <label>{{ t('imggen_model') || 'Model' }}</label>
                        <div class="model-row">
                            <input
                                type="text"
                                v-model="settings.model"
                                :placeholder="t('imggen_model_placeholder') || 'dall-e-3'"
                                style="width: 100%; padding-right: 44px;"
                                autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
                            >
                            <div class="model-dropdown-btn" @click="openModelSelector">
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                            <button class="fetch-btn" @click="onFetchModels" :disabled="isFetchingModels">
                                <svg v-if="!isFetchingModels" viewBox="0 0 24 24"><path d="M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                                <span v-else class="mini-spinner"></span>
                            </button>
                        </div>
                        <span v-if="fetchError" class="error-hint">{{ fetchError }}</span>
                    </div>

                    <!-- Model (Gemini) -->
                    <div v-if="showGeminiOptions" class="settings-item">
                        <label>{{ t('imggen_model') || 'Model' }}</label>
                        <input
                            type="text"
                            v-model="settings.model"
                            placeholder="imagen-3.0-generate-002"
                            autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
                        >
                    </div>

                    <!-- OpenAI size & quality -->
                    <template v-if="showOpenAIOptions">
                        <div class="settings-item selector-row" @click="openSizeSelector">
                            <label>{{ t('imggen_size') || 'Image Size' }}</label>
                            <div class="selector-value">
                                <span>{{ settings.size || '1024×1024' }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                        <div class="settings-item selector-row" @click="openQualitySelector">
                            <label>{{ t('imggen_quality') || 'Quality' }}</label>
                            <div class="selector-value">
                                <span>{{ settings.quality === 'hd' ? 'HD' : 'Standard' }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                    </template>

                    <!-- Gemini aspect ratio & resolution -->
                    <template v-if="showGeminiOptions">
                        <div class="settings-item selector-row" @click="openAspectRatioSelector('aspectRatio', ['1:1','9:16','16:9','3:4','4:3','2:3','3:2'])">
                            <label>{{ t('imggen_aspect_ratio') || 'Aspect Ratio' }}</label>
                            <div class="selector-value">
                                <span>{{ settings.aspectRatio || '1:1' }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                        <div class="settings-item selector-row" @click="openResolutionSelector">
                            <label>{{ t('imggen_image_size') || 'Resolution' }}</label>
                            <div class="selector-value">
                                <span>{{ settings.imageSize || '1K' }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                    </template>

                    <!-- Naistera aspect ratio -->
                    <div v-if="showNaisteraOptions" class="settings-item selector-row" @click="openAspectRatioSelector('naisteraAspectRatio', ['1:1','16:9','9:16','3:2','2:3'])">
                        <label>{{ t('imggen_aspect_ratio') || 'Aspect Ratio' }}</label>
                        <div class="selector-value">
                            <span>{{ settings.naisteraAspectRatio || '1:1' }}</span>
                            <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                        </div>
                    </div>
                </div>

                <!-- Naistera references -->
                <template v-if="showNaisteraOptions">
                    <div class="menu-group">
                        <div class="section-header">{{ t('imggen_refs') || 'Reference Images' }}</div>

                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('imggen_send_char_avatar') || 'Send character avatar' }}</label>
                                <div class="settings-desc">{{ t('imggen_send_char_avatar_desc') || 'Use character\'s avatar as visual reference' }}</div>
                            </div>
                            <input type="checkbox" v-model="settings.naisteraSendCharAvatar" class="vk-switch">
                        </div>

                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('imggen_send_user_avatar') || 'Send persona avatar' }}</label>
                                <div class="settings-desc">{{ t('imggen_send_user_avatar_desc') || 'Use active persona\'s avatar as visual reference' }}</div>
                            </div>
                            <input type="checkbox" v-model="settings.naisteraSendUserAvatar" class="vk-switch">
                        </div>
                    </div>

                    <div class="menu-group">
                        <div class="section-header section-header-flex">
                            <span>{{ t('imggen_additional_refs') || 'Additional References' }}</span>
                            <span class="refs-count">{{ settings.additionalReferences.length }}/8</span>
                        </div>

                        <div v-for="(ref, i) in settings.additionalReferences" :key="i" class="settings-item ref-row">
                            <button
                                class="ref-img-btn"
                                :class="{ 'has-image': !!ref.imageData }"
                                @click="pickRefImage(i)"
                            >
                                <img v-if="ref.imageData" :src="ref.imageData" class="ref-thumb">
                                <svg v-else viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>
                            </button>
                            <input
                                class="ref-name-input"
                                type="text"
                                v-model="ref.name"
                                placeholder="keyword"
                            >
                            <div class="ref-mode-btn" @click="openRefMatchModeSelector(i)">
                                <span>{{ ref.matchMode || 'match' }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                            <button class="remove-ref-btn" @click="removeRef(i)">
                                <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                            </button>
                        </div>

                        <button
                            v-if="settings.additionalReferences.length < 8"
                            class="add-ref-btn"
                            @click="addRef"
                        >+ {{ t('imggen_add_ref') || 'Add reference' }}</button>

                        <input
                            ref="refImageInput"
                            type="file"
                            accept="image/*"
                            style="display: none"
                            @change="onRefImageSelected"
                        >
                    </div>
                </template>

                <!-- Tag format hint -->
                <div class="hint-block">
                    <p class="hint-text">{{ t('imggen_tag_hint') || 'AI must include image tags to trigger generation:' }}</p>
                    <code class="hint-code">[IMG:GEN:{"prompt":"...","style":"anime"}]</code>
                </div>

            </template>
        </div>
    </SheetView>
</template>

<style scoped>
.gen-sheet-body {
    flex: 1;
    overflow-y: auto;
    position: relative;
    padding-top: 8px;
}

.naistera-hint {
    font-size: 13px;
    color: var(--text-gray);
    opacity: 0.8;
}

/* Selector row — replaces <select> */
.selector-row {
    cursor: pointer;
    user-select: none;
}

.selector-row label {
    pointer-events: none;
}

.selector-value {
    display: flex;
    align-items: center;
    gap: 2px;
    color: var(--vk-blue);
    font-size: 14px;
    font-weight: 500;
    flex-shrink: 0;
}

.selector-value svg {
    width: 22px;
    height: 22px;
    fill: var(--vk-blue);
    margin-right: -4px;
}

/* Model row */
.model-row {
    display: flex;
    gap: 8px;
    align-items: center;
    margin-top: 4px;
    position: relative;
}

.model-row input[type="text"] {
    flex: 1;
    min-width: 0;
    padding-right: 44px;
}

.model-dropdown-btn {
    position: absolute;
    right: 88px;
    top: 0;
    bottom: 0;
    width: 44px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
}

.model-dropdown-btn svg {
    width: 24px;
    height: 24px;
    fill: var(--text-gray);
}

.fetch-btn {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    border: 1px solid var(--border-color, rgba(0,0,0,0.12));
    background: var(--bg-gray);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
}

.fetch-btn svg {
    width: 18px;
    height: 18px;
    fill: var(--vk-blue);
}

.fetch-btn:disabled { opacity: 0.5; cursor: not-allowed; }

.mini-spinner {
    width: 16px;
    height: 16px;
    border: 2px solid var(--border-color, rgba(0,0,0,0.15));
    border-top-color: var(--vk-blue);
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
    display: inline-block;
}

@keyframes spin { to { transform: rotate(360deg); } }

.error-hint {
    font-size: 12px;
    color: #FF3B30;
    margin-top: 4px;
    display: block;
}

.refs-count {
    font-size: 13px;
    font-weight: 400;
    opacity: 0.5;
    letter-spacing: 0;
    text-transform: none;
}

/* Reference rows */
.ref-row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding-top: 8px;
    padding-bottom: 8px;
}

.ref-img-btn {
    width: 40px;
    height: 40px;
    border-radius: 8px;
    border: 1px solid var(--border-color, rgba(0,0,0,0.12));
    background: var(--bg-gray);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
    overflow: hidden;
    padding: 0;
}

.ref-img-btn svg {
    width: 20px;
    height: 20px;
    fill: var(--text-gray);
    opacity: 0.5;
}

.ref-img-btn.has-image {
    border-color: var(--vk-blue);
}

.ref-thumb {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.ref-name-input {
    flex: 1;
    min-width: 0;
}

.ref-mode-btn {
    display: flex;
    align-items: center;
    gap: 2px;
    cursor: pointer;
    color: var(--vk-blue);
    font-size: 13px;
    font-weight: 500;
    flex-shrink: 0;
    padding: 4px 2px;
}

.ref-mode-btn svg {
    width: 18px;
    height: 18px;
    fill: var(--vk-blue);
}

.remove-ref-btn {
    width: 32px;
    height: 32px;
    border-radius: 6px;
    border: none;
    background: transparent;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    flex-shrink: 0;
    opacity: 0.4;
}

.remove-ref-btn:active { opacity: 1; }

.remove-ref-btn svg {
    width: 18px;
    height: 18px;
    fill: var(--text-gray);
}

.add-ref-btn {
    display: block;
    width: calc(100% - 32px);
    margin: 4px 16px 12px;
    padding: 10px 14px;
    border-radius: 10px;
    border: 1px dashed rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
    background: transparent;
    color: var(--vk-blue);
    font-size: 14px;
    font-weight: 500;
    cursor: pointer;
    text-align: center;
}

.hint-block {
    margin: 0 16px 16px;
    padding: 12px 14px;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0,0,0,0.06));
    border-radius: 14px;
}

.hint-text {
    font-size: 13px;
    color: var(--text-gray);
    margin: 0 0 6px;
    opacity: 0.8;
}

.hint-code {
    display: block;
    font-family: monospace;
    font-size: 11px;
    color: var(--vk-blue);
    word-break: break-all;
}
</style>
