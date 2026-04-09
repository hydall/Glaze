<script setup>
import { ref, computed, reactive, onMounted } from 'vue';
import { importFullBackupAsync } from '@/core/services/backupService.js';
import { addPersona, allPersonas, deletePersona } from '@/core/states/personaState.js';
import { normalizeEndpoint, fetchRemoteModels, getApiPresets, saveApiPresets } from '@/core/config/APISettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import BackupSheet from '@/components/sheets/BackupSheet.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { convertSTPreset } from '@/core/services/presetImportService.js';
import { requestNotificationPermission } from '@/core/services/notificationService.js';
import { presetState, initPresetState, savePresets, setPresetConnection } from '@/core/states/presetState.js';
import { isKeyboardOpen as globalKeyboardOpen } from '@/core/services/keyboardHandler.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

const emit = defineEmits(['finish']);



const currentSlide = ref(0);

const backupSheet = ref(null);

const triggerRestore = () => {
    if (backupSheet.value) backupSheet.value.open();
};

// Form Data
const apiSettings = reactive({
    endpoint: '',
    key: '',
    model: ''
});

const apiStatus = ref('idle');
let debounceTimer = null;

const apiStatusText = computed(() => {
    const map = {
        'idle': t('onboarding_status_idle'),
        'connecting': t('onboarding_status_connecting'),
        'connected': t('onboarding_status_connected'),
        'failed': t('onboarding_status_failed')
    };
    return map[apiStatus.value] || apiStatus.value;
});

const personaConfig = reactive({
    name: '',
    desc: '',
    avatar: null
});

const avatarInput = ref(null);

function triggerAvatarUpload() {
    if (avatarInput.value) avatarInput.value.click();
}

function handleAvatarChange(e) {
    const file = e.target.files[0];
    if (file) {
        const reader = new FileReader();
        reader.onload = (ev) => {
            personaConfig.avatar = ev.target.result;
        };
        reader.readAsDataURL(file);
    }
}

const introContent = computed(() => [
    {
        title: t('onboarding_slide1_subtitle'),
        desc: t('onboarding_slide1_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>'
    },
    {
        title: t('onboarding_slide2_title'),
        desc: t('onboarding_slide2_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>'
    },
    {
        title: t('onboarding_slide5_title'),
        desc: t('onboarding_slide5_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>'
    }
]);

const featuresContent = computed(() => [
    {
        title: t('onboarding_feature_imggen_title'),
        desc: t('onboarding_feature_imggen_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>'
    },
    {
        title: t('onboarding_feature_glossary_title'),
        desc: t('onboarding_feature_glossary_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg>'
    },
    {
        title: t('onboarding_feature_custom_title'),
        desc: t('onboarding_feature_custom_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>'
    },
    {
        title: t('onboarding_feature_st_title'),
        desc: t('onboarding_feature_st_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><path d="M9 15l2 2 4-4"/></svg>'
    }
]);

const slides = computed(() => [
    {
        type: 'welcome',
        title: t('onboarding_slide1_title'),
    },
    {
        type: 'features',
        title: t('onboarding_features_title'),
    },
    {
        type: 'data_import',
        title: t('onboarding_slide_import_title'),
        desc: t('onboarding_slide_import_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>'
    },
    {
        type: 'api',
        title: t('onboarding_slide3_title'),
        desc: t('onboarding_slide3_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2" width="20" height="8" rx="2" ry="2"></rect><rect x="2" y="14" width="20" height="8" rx="2" ry="2"></rect><line x1="6" y1="6" x2="6.01" y2="6"></line><line x1="6" y1="18" x2="6.01" y2="18"></line></svg>'
    },
    {
        type: 'persona',
        title: t('onboarding_slide4_title'),
        desc: t('onboarding_slide4_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>'
    },
    {
        type: 'preset_import',
        title: t('onboarding_slide_preset_title'),
        desc: t('onboarding_slide_preset_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="12" y1="18" x2="12" y2="12"></line><line x1="9" y1="15" x2="15" y2="15"></line></svg>'
    },
    {
        type: 'notifications',
        title: t('notification_permission_title'),
        desc: t('notification_permission_desc'),
        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M12 22c1.1 0 2-.9 2-2h-4c0 1.1.9 2 2 2zm6-6v-5c0-3.07-1.63-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.64 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2zm-2 1H8v-6c0-2.48 1.51-4.5 4-4.5s4 2.02 4 4.5v6z"/></svg>'
    },
    {
        type: 'all-set',
        title: t('onboarding_slide_all_set_title'),
        desc: t('onboarding_slide_all_set_desc'),
        icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>'
    }
]);

const isLastSlide = computed(() => currentSlide.value === slides.value.length - 1);
const mainButtonLabel = computed(() => {
    if (isLastSlide.value) return t('onboarding_btn_start');
    
    const slide = slides.value[currentSlide.value];
    if (slide.type === 'preset_import' || slide.type === 'data_import') {
        return t('onboarding_btn_skip');
    }
    if (slide.type === 'api') {
        return apiSettings.endpoint ? t('onboarding_btn_save') : t('onboarding_btn_skip');
    }
    if (slide.type === 'persona') {
        return personaConfig.name ? t('onboarding_btn_create') : t('onboarding_btn_skip');
    }
    if (slide.type === 'notifications') {
        return t('btn_allow') || "Allow";
    }
    return t('onboarding_btn_next');
});

async function next() {
    if (slides.value[currentSlide.value].type === 'api' && apiSettings.endpoint) {
        await savePreset();
    }

    if (slides.value[currentSlide.value].type === 'notifications') {
        localStorage.setItem('gz_notification_requested', 'true');
        await requestNotificationPermission();
    }

    if (isLastSlide.value) {
        finish();
    } else {
        currentSlide.value++;
    }
}

function prev() {
    if (currentSlide.value > 0) {
        currentSlide.value--;
    }
}

function skipNotifications() {
    localStorage.setItem('gz_notification_requested', 'true');
    currentSlide.value++;
}

async function openModelSelector() {
    if (!apiSettings.endpoint) return;
    
    try {
        const normalized = normalizeEndpoint(apiSettings.endpoint);
        const models = await fetchRemoteModels(normalized, apiSettings.key);
        
        const items = models.map(m => ({
            label: m,
            onClick: () => {
                apiSettings.model = m;
                closeBottomSheet();
            }
        }));
        
        showBottomSheet({ title: t('onboarding_select_model'), items });
    } catch (e) {
        alert(t('onboarding_error_models') + ": " + e.message);
    }
}

async function checkConnection() {
    if (!apiSettings.endpoint) {
        apiStatus.value = 'idle';
        return;
    }
    
    apiStatus.value = 'connecting';
    try {
        const normalized = normalizeEndpoint(apiSettings.endpoint);
        await fetchRemoteModels(normalized, apiSettings.key);
        apiStatus.value = 'connected';
    } catch (e) {
        console.warn(e);
        apiStatus.value = 'failed';
    }
}

function onApiInput() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(checkConnection, 1000);
}

async function savePreset() {
    if (!apiSettings.endpoint) return;
    
    const normalized = normalizeEndpoint(apiSettings.endpoint);
    const presets = await getApiPresets();
    
    const newPreset = {
        id: Date.now().toString(36),
        name: 'Onboarding Setup',
        endpoint: normalized,
        key: apiSettings.key,
        model: apiSettings.model,
        max_tokens: 8000,
        context: 32000,
        temp: 0.7,
        topp: 0.9,
        stream: true
    };
    
    presets.push(newPreset);
    await saveApiPresets(presets);
    localStorage.setItem('gz_active_api_preset_id', newPreset.id);

    // Also save legacy globals for immediate use
    localStorage.setItem('api-endpoint', normalized);
    localStorage.setItem('gz_api_endpoint_normalized', normalized);
    if (apiSettings.key) localStorage.setItem('api-key', apiSettings.key);
    if (apiSettings.model) localStorage.setItem('api-model', apiSettings.model);
}

function triggerPresetImport() {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.json';
    input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;
        
        try {
            const text = await file.text();
            const data = JSON.parse(text);
            
            initPresetState();

            // Logic to handle ST format or internal format
            if (data.prompts && Array.isArray(data.prompts)) {
                // ST Format conversion
                const preset = convertSTPreset(data, file.name.replace(/\.json$/i, ''));
                const newId = Date.now().toString();
                presetState.presets[newId] = preset;
                setPresetConnection('global', null, newId);
            } else {
                // Assume internal format (dictionary or single object)
                if (data.blocks) {
                     const id = Date.now().toString();
                     presetState.presets[id] = data;
                     setPresetConnection('global', null, id);
                } else {
                     Object.assign(presetState.presets, data);
                }
            }
            
            savePresets();
            next();
        } catch (err) {
            alert(t('onboarding_import_error') + err.message);
        }
    };
    input.click();
}

async function finish() {
    // Create First Persona
    if (personaConfig.name) {
        const newPersona = await addPersona({
            name: personaConfig.name,
            prompt: personaConfig.desc || t('onboarding_default_persona_desc'),
            avatar: personaConfig.avatar || null
        });

        if (newPersona && newPersona.id) {
            localStorage.setItem('gz_active_persona_id', newPersona.id);
            
            // Remove default "user" persona ONLY if it exists and this is the first onboarding
            if (localStorage.getItem('glaze_onboarding_completed') !== 'true') {
                const defaultIndex = allPersonas.value.findIndex(p => p.name === 'user');
                if (defaultIndex !== -1) {
                    await deletePersona(defaultIndex);
                }
            }
        }
    }

    emit('finish');
}
</script>

<template>
    <div class="onboarding-overlay">
        <!-- Stories Progress Bar -->
        <div class="stories-nav">
            <div 
                v-for="(_, index) in slides" 
                :key="index" 
                class="story-bar"
                :class="{ active: index === currentSlide, passed: index < currentSlide }"
            >
                <div class="story-fill"></div>
            </div>
        </div>

        <button v-if="currentSlide > 0" class="nav-back-btn" @click="prev">
            <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
        </button>

        <div class="onboarding-card" :class="{ 'keyboard-open': globalKeyboardOpen }">
            <div class="slides-container">
                <Transition name="slide-fade" mode="out-in">
                    <div :key="currentSlide" class="slide" :class="{ 'welcome-align': ['welcome', 'features'].includes(slides[currentSlide].type) }">
                        
                        <!-- Welcome / Features Slide -->
                        <div v-if="slides[currentSlide].type === 'welcome' || slides[currentSlide].type === 'features'" class="welcome-slide">
                            <div class="welcome-header">
                                <h1 class="welcome-title">{{ slides[currentSlide].title }}</h1>
                            </div>
                            
                            <div class="intro-blocks-container">
                                <div v-for="(item, index) in (slides[currentSlide].type === 'welcome' ? introContent : featuresContent)" :key="index" class="intro-block">
                                    <div class="intro-icon" v-html="item.icon"></div>
                                    <div class="intro-text">
                                        <h3>{{ item.title }}</h3>
                                        <p>{{ item.desc }}</p>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <!-- Standard Slides -->
                        <div v-else class="standard-slide">
                            <div class="icon-wrapper" v-if="slides[currentSlide].icon && slides[currentSlide].type !== 'persona'" v-html="slides[currentSlide].icon"></div>
                            <h1 class="title">{{ slides[currentSlide].title }}</h1>
                            <p class="description">{{ slides[currentSlide].desc }}</p>
                        </div>

                        <!-- API Setup Slide -->
                        <div v-if="slides[currentSlide].type === 'api'" class="setup-form-container">
                            <div class="menu-group" style="margin: 0; width: 100%; text-align: left;">
                                <div class="section-header section-header-flex">
                                    <span>{{ t('onboarding_connection') }}</span>
                                    <div class="api-status-badge" @click="checkConnection">
                                        <div class="status-dot" :class="apiStatus"></div>
                                        <Transition name="status-fade" mode="out-in">
                                            <span class="status-text" :key="apiStatus">{{ apiStatusText }}</span>
                                        </Transition>
                                    </div>
                                </div>
                                <div class="settings-item">
                                    <label>{{ t('onboarding_label_endpoint') }}</label>
                                    <input type="text" v-model="apiSettings.endpoint" @input="onApiInput" placeholder="http://127.0.0.1:5000/v1" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                </div>
                                <div class="settings-item">
                                    <label>{{ t('onboarding_label_model') }}</label>
                                    <div style="position: relative;">
                                        <input type="text" v-model="apiSettings.model" placeholder="gemini-3-pro-preview" style="width: 100%; padding-right: 44px;" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                        <div @click="openModelSelector" style="position: absolute; right: 0; top: 0; bottom: 0; width: 44px; cursor: pointer; display: flex; align-items: center; justify-content: center;">
                                            <svg viewBox="0 0 24 24" style="width: 24px; height: 24px; fill: #818C99;"><path d="M7 10l5 5 5-5z"/></svg>
                                        </div>
                                    </div>
                                </div>
                                <div class="settings-item">
                                    <label>{{ t('onboarding_label_key') }}</label>
                                    <input type="password" v-model="apiSettings.key" @input="onApiInput" placeholder="sk-..." autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false">
                                </div>
                            </div>
                        </div>

                        <!-- Persona Setup Slide -->
                        <div v-if="slides[currentSlide].type === 'persona'" class="setup-form-container">
                            <div class="menu-group" style="margin: 0; width: 100%; text-align: left;">
                                <!-- Avatar Card inside menu-group -->
                                <div class="avatar-card" @click="triggerAvatarUpload">
                                    <div class="avatar-wrapper">
                                        <div class="avatar-header-overlay">{{ t('avatar') || 'Avatar' }}</div>
                                        <img v-if="personaConfig.avatar" :src="personaConfig.avatar" class="avatar-img">
                                        <div v-else class="avatar-placeholder">
                                            {{ personaConfig.name ? personaConfig.name[0].toUpperCase() : '?' }}
                                        </div>
                                        <div class="avatar-overlay-hint">{{ t('hint_change_avatar') || 'Tap to change' }}</div>
                                    </div>
                                    <input type="file" ref="avatarInput" accept="image/*" style="display: none;" @change="handleAvatarChange">
                                </div>
                                <div class="settings-item"><label>{{ t('onboarding_label_name') }}</label><input type="text" v-model="personaConfig.name" :placeholder="t('onboarding_placeholder_name')"></div>
                                <div class="settings-item" style="border-bottom: none;"><label>{{ t('onboarding_label_desc') }}</label><textarea v-model="personaConfig.desc" :placeholder="t('onboarding_placeholder_desc')" rows="3"></textarea></div>
                            </div>
                        </div>

                        <!-- Preset Import Slide -->
                        <div v-if="slides[currentSlide].type === 'preset_import'" class="intro-blocks-container" style="margin-top: 24px;">
                            <div class="intro-block clickable" @click="triggerPresetImport">
                                <div class="intro-icon">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                                </div>
                                <div class="intro-text">
                                    <h3>{{ t('onboarding_btn_import_preset') }}</h3>
                                    <p>JSON</p>
                                </div>
                            </div>
                        </div>

                        <!-- Data Import Slide -->
                        <div v-if="slides[currentSlide].type === 'data_import'" class="intro-blocks-container" style="margin-top: 24px;">
                            <div class="intro-block clickable" @click="triggerRestore">
                                <div class="intro-icon">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
                                </div>
                                <div class="intro-text">
                                    <h3>{{ t('onboarding_btn_import_backup') }}</h3>
                                    <p>{{ t('menu_backups') }}</p>
                                </div>
                            </div>
                        </div>

                    </div>
                </Transition>
            </div>

            <div class="controls">
                <button class="btn-primary full-width" @click="next">
                    {{ mainButtonLabel }}
                </button>
                <button 
                    v-if="slides[currentSlide].type === 'notifications'" 
                    class="btn-secondary full-width" 
                    style="margin-top: 12px; width: 100%;" 
                    @click="skipNotifications"
                >
                    {{ t('btn_later') || "Later" }}
                </button>
            </div>
        </div>
        <BackupSheet ref="backupSheet" :z-index="10000" />
    </div>
</template>

<style scoped>
.onboarding-overlay {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: var(--app-bg);
    z-index: 9999;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    font-family: -apple-system, BlinkMacSystemFont, Roboto, sans-serif;
}

/* Stories Navigation */
.stories-nav {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    padding: 16px 20px;
    padding-top: calc(16px + var(--sat));
    display: flex;
    gap: 6px;
    z-index: 10;
    box-sizing: border-box;
}

.story-bar {
    flex: 1;
    height: 4px;
    background: rgba(128, 128, 128, 0.2);
    border-radius: 2px;
    overflow: hidden;
}

.story-fill {
    height: 100%;
    background: var(--vk-blue, #7996ce);
    width: 0%;
    transition: width 0.3s ease;
}

.story-bar.active .story-fill,
.story-bar.passed .story-fill {
    width: 100%;
}

.onboarding-card {
    position: relative;
    width: 100%;
    height: 100%;
    background: rgba(255, 255, 255, 0.05);
    backdrop-filter: blur(50px);
    -webkit-backdrop-filter: blur(50px);
    padding: 24px;
    padding-top: calc(44px + var(--sat));
    padding-bottom: calc(24px + var(--sab));
    display: flex;
    flex-direction: column;
    z-index: 2;
    box-sizing: border-box;
}

.onboarding-card.keyboard-open {
    padding-bottom: calc(var(--keyboard-overlap, 0px) + 10px) !important;
}

.slides-container {
    flex: 1;
    display: grid;
    place-items: start;
    width: 100%;
    max-width: 500px;
    margin: 0 auto;
    overflow-y: auto;
    overflow-x: hidden;
    min-height: 0;
}

.slide, .standard-slide {
    text-align: center;
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    margin: auto 0;
}
.slide.welcome-align {
    margin: 0;
}

.welcome-slide {
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: stretch;
}

.icon-wrapper {
    width: 100px;
    height: 100px;
    margin: 0 auto 24px;
    color: var(--vk-blue, #7996ce);
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 50%;
    padding: 24px;
    box-sizing: border-box;
}

.title {
    font-size: 28px;
    font-weight: 800;
    margin-bottom: 12px;
    color: var(--text-black, #000);
    line-height: 1.3;
    padding: 4px 0;
    white-space: pre-line;
}

.welcome-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    width: 100%;
    margin-bottom: 16px;
}

.welcome-title {
    font-size: 32px;
    font-weight: 800;
    color: var(--text-black, #000);
    line-height: 1.2;
    white-space: pre-line;
    text-align: left;
    margin-top: 0;
    margin-bottom: 0;
}

.backup-fab-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    background: rgba(121, 150, 206, 0.15);
    color: var(--vk-blue, #7996ce);
    border: none;
    border-radius: 20px;
    padding: 8px 14px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: transform 0.2s, background 0.2s;
    margin-top: 8px; /* Alignment with title */
}

.backup-fab-pill svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
}

.backup-fab-pill:active {
    transform: scale(0.95);
    background: rgba(121, 150, 206, 0.25);
}

.intro-blocks-container {
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.intro-block {
    background: rgba(128, 128, 128, 0.08);
    border-radius: 20px;
    padding: 16px;
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    text-align: left;
    gap: 8px;
}

.intro-block.clickable {
    cursor: pointer;
    transition: background-color 0.2s, transform 0.1s;
}
.intro-block.clickable:active {
    background: rgba(128, 128, 128, 0.15);
    transform: scale(0.98);
}

.intro-icon {
    width: 48px;
    height: 48px;
    color: var(--vk-blue);
}

.intro-text h3 {
    font-size: 20px;
    font-weight: 700;
    margin-bottom: 4px;
    color: var(--text-black);
}

.intro-text p {
    font-size: 15px;
    line-height: 1.5;
    color: #818C99;
}

.description {
    font-size: 16px;
    line-height: 1.5;
    color: #818C99;
    white-space: pre-line;
    max-width: 320px;
    margin: 0 auto;
}

/* Forms */
.setup-form-container {
    width: 100%;
    margin-top: 24px;
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.controls {
    width: 100%;
    max-width: 500px;
    margin: 0 auto;
    padding-top: 20px;
    flex-shrink: 0;
}

.btn-primary {
    background-color: var(--vk-blue, #7996ce);
    color: white;
    border: none;
    border-radius: 20px;
    padding: 16px 32px;
    font-size: 17px;
    font-weight: 600;
    cursor: pointer;
    transition: transform 0.2s;
    width: 100%;
    box-shadow: none;
}

.btn-secondary {
    background-color: rgba(128, 128, 128, 0.1);
    color: var(--text-black);
    border: none;
    border-radius: 12px;
    padding: 12px 24px;
    font-size: 15px;
    font-weight: 500;
    cursor: pointer;
}

.btn-primary:active {
    transform: scale(0.96);
}

/* Dark Theme Support */
:global(body.dark-theme) .onboarding-overlay {
    background-color: #000;
}
:global(body.dark-theme) .title {
    color: #fff;
}
:global(body.dark-theme) .welcome-title,
:global(body.dark-theme) .intro-text h3 {
    color: #fff;
}
:global(body.dark-theme) .onboarding-card {
    background: rgba(0, 0, 0, 0.2);
}

/* Transitions */
.slide-fade-enter-active,
.slide-fade-leave-active {
    transition: all 0.3s ease;
}

.slide-fade-enter-from {
    opacity: 0;
    transform: translateX(20px);
}

.slide-fade-leave-to {
    opacity: 0;
    transform: translateX(-20px);
}

/* API Status Styles */
.section-header-flex {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.api-status-badge {
    display: flex; 
    align-items: center; 
    font-size: 13px; 
    cursor: pointer; 
    padding: 4px 8px; 
    border-radius: 12px; 
    background: rgba(128, 128, 128, 0.1);
    font-weight: normal;
}

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background-color: orange;
    margin-right: 6px;
}
.status-dot.connecting { background-color: orange; }
.status-dot.connected { background-color: #4CAF50; }
.status-dot.failed { background-color: #ff4444; }

.status-fade-enter-active,
.status-fade-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}
.status-fade-enter-from,
.status-fade-leave-to {
  opacity: 0;
  transform: translateY(5px);
}

.nav-back-btn {
    position: absolute;
    top: calc(40px + var(--sat));
    left: 16px;
    z-index: 20;
    background: none;
    border: none;
    color: var(--text-black, #000);
    padding: 8px;
    cursor: pointer;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
}
.nav-back-btn svg {
    width: 28px;
    height: 28px;
    fill: currentColor;
}
:global(body.dark-theme) .nav-back-btn {
    color: #fff;
}

/* Avatar Card (matches GenericEditor style) */
.avatar-card {
    display: flex;
    flex-direction: column;
    cursor: pointer;
}

.avatar-wrapper {
    width: 100%;
    aspect-ratio: 1 / 1;
    max-height: 300px;
    position: relative;
    background-color: var(--bg-gray, rgba(128,128,128,0.1));
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

.avatar-overlay-hint {
    position: absolute;
    bottom: 0;
    left: 0;
    width: 100%;
    text-align: center;
    color: rgba(255, 255, 255, 0.9);
    font-size: 14px;
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    pointer-events: none;
    z-index: 2;
    background: linear-gradient(to top, rgba(0,0,0,0.5), transparent);
    padding-bottom: 20px;
    padding-top: 20px;
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
    background: linear-gradient(to bottom, rgba(0,0,0,0.5), transparent);
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    pointer-events: none;
}
</style>