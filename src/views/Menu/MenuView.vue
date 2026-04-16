<script setup>
import { onMounted, ref } from 'vue';
import { initRipple } from '@/core/services/ui.js';
import { updateLanguage, translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { loadPersonas } from '@/core/states/personaState.js';
import AboutView from '@/views/Menu/AboutView.vue';

const aboutView = ref(null);
const openAbout = () => {
    aboutView.value?.open();
};

const openGlossary = () => {
    window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-glossary' }));
};

onMounted(() => {
    // Initialize ripple effects and toggles now that elements are in the DOM
    initRipple();
    
    // Load personas
    loadPersonas();

    // Apply translations to the freshly mounted view
    updateLanguage();
});

const t = (key) => translations[currentLang.value]?.[key] || key;

const openBackupSheet = () => {
    window.dispatchEvent(new CustomEvent('open-backup-sheet'));
};

const openSyncSheet = () => {
    window.dispatchEvent(new CustomEvent('open-sync-sheet'));
};

const openSettings = () => {
    window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-settings' }));
};

const replayOnboarding = () => {
    window.dispatchEvent(new CustomEvent('open-onboarding'));
};
</script>

<template>
    <div id="view-menu" class="view active-view">
      <!-- Main Menu -->
      <!-- Persona Header -->

        <div class="menu-group">
            <div class="section-header" data-i18n="section_settings">Settings</div>
            <div class="menu-item" @click="openSettings">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.488.488 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>
                <div class="menu-text" data-i18n="menu_app_settings">App Settings</div>
            </div>
            
            <div class="menu-item" @click="replayOnboarding">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M12 4V1L8 5l4 4V6c3.31 0 6 2.69 6 6 0 1.01-.25 1.97-.7 2.8l1.46 1.46C19.54 15.03 20 13.57 20 12c0-4.42-3.58-8-8-8zm0 14c-3.31 0-6-2.69-6-6 0-1.01.25-1.97.7-2.8L5.24 7.74C4.46 8.97 4 10.43 4 12c0 4.42 3.58 8 8 8v3l4-4-4-4v3z"/></svg>
                <div class="menu-text">{{ t('onboarding_replay') }}</div>
            </div>
            

            <div class="menu-item" @click="openBackupSheet">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M19.35 10.04A7.49 7.49 0 0 0 12 4C9.11 4 6.6 5.64 5.35 8.04A5.994 5.994 0 0 0 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM19 18H6c-2.21 0-4-1.79-4-4 0-2.05 1.53-3.76 3.56-3.97l1.07-.11.5-.95A5.469 5.469 0 0 1 12 6c2.62 0 4.88 1.86 5.39 4.43l.3 1.5 1.53.11A2.98 2.98 0 0 1 22 15c0 1.65-1.35 3-3 3zM8 13h2.55v3h2.9v-3H16l-4-4z"/></svg>
                <div class="menu-text" data-i18n="menu_backups">Backups</div>
            </div>

            <div class="menu-item" @click="openSyncSheet">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M19 12h-2v3h-3v2h5v-5zM7 9h3V7H5v5h2V9zm14-6H3c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16.01H3V4.99h18v14.02z"/></svg>
                <div class="menu-text">{{ t('menu_cloud_sync') || 'Cloud Sync' }}</div>
            </div>
        </div>

        <div class="menu-group">
            <div class="section-header" data-i18n="section_info">Info</div>
            <div class="menu-item" @click="openGlossary">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20M4 19.5A2.5 2.5 0 0 0 6.5 22H20V2H6.5A2.5 2.5 0 0 0 4 4.5v15z"/></svg>
                <div class="menu-text" data-i18n="menu_glossary">Glossary</div>
            </div>
            <div class="menu-item" @click="openAbout">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M11 7h2v2h-2zm0 4h2v6h-2zm1-9C6.48 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z"/></svg>
                <div class="menu-text" data-i18n="menu_about">About Cradle</div>
            </div>
        </div>

        <AboutView ref="aboutView" />
    </div>
</template>

<style scoped>

</style>