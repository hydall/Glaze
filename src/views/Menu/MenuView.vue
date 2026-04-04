<script setup>
import { onMounted, ref } from 'vue';
import { initRipple } from '@/core/services/ui.js';
import { updateLanguage, translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { db } from '@/utils/db.js';
import { loadPersonas } from '@/core/states/personaState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import AboutView from '@/views/Menu/AboutView.vue';

const aboutView = ref(null);
const openAbout = () => {
    aboutView.value?.open();
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

const openBackupOptions = () => {
    showBottomSheet({
        title: t('menu_backups') || 'Backups',
        items: [
            { 
                label: t('menu_export') || 'Export Data (.glz)', 
                icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    performBackup();
                } 
            },
            { 
                label: t('menu_import') || 'Import Data (.glz)', 
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    triggerRestore();
                } 
            }
        ]
    });
};

const performBackup = async () => {
    showBottomSheet({
        title: t('exporting_data') || "Exporting Data",
        bigInfo: {
            icon: '<div class="app-loader-spinner" style="margin: 0 auto; width: 48px; height: 48px;"></div>',
            description: t('please_wait') || "Please wait, gathering and saving application data...",
            buttonText: t('btn_wait') || "Wait...",
            onButtonClick: () => {}
        }
    });

    setTimeout(async () => {
        try {
            const dataString = await db.exportFullBackupAsync();
            const date = new Date();
            const formattedDate = `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}_${String(date.getHours()).padStart(2,'0')}-${String(date.getMinutes()).padStart(2,'0')}-${String(date.getSeconds()).padStart(2,'0')}`;
            const filename = `Glaze_backup_${formattedDate}.glz`;
            await saveFile(filename, dataString, 'application/json', 'backups');
            // Note: saveFile natively handles showing the success bottom sheet on mobile.
            // On web, it just downloads quietly.
            if (!window.Capacitor?.isNativePlatform()) {
                showBottomSheet({
                    title: "Export Complete",
                    bigInfo: {
                        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#4CAF50"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                        description: "File downloaded.",
                        buttonText: "OK",
                        onButtonClick: () => closeBottomSheet()
                    }
                });
            }
        } catch (e) {
            console.error("Export failed", e);
            showBottomSheet({
                title: t('title_error') || "Error",
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                    description: "Export failed: " + e.message,
                    buttonText: t('btn_ok') || "OK",
                    onButtonClick: () => closeBottomSheet()
                }
            });
        }
    }, 100);
};

const triggerRestore = () => {
    const input = document.getElementById('restore-input');
    if (input) input.click();
};

const handleRestoreFile = async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    
    if (!confirm(t('confirm_restore') || "This will overwrite current data. Continue?")) {
        event.target.value = '';
        return;
    }

    showBottomSheet({
        title: t('importing_data') || "Importing Data",
        bigInfo: {
            icon: '<div class="app-loader-spinner" style="margin: 0 auto; width: 48px; height: 48px;"></div>',
            description: t('please_wait') || "Please wait, reading and importing application data...",
            buttonText: t('btn_wait') || "Wait...",
            onButtonClick: () => {}
        }
    });

    setTimeout(() => {
        const reader = new FileReader();
        reader.onload = async (e) => {
            try {
                await db.importFullBackupAsync(e.target.result);
                
                showBottomSheet({
                    title: "Restore Complete",
                    bigInfo: {
                        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#4CAF50"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                        description: "Restore successful! The app will now reload to apply changes.",
                        buttonText: t('btn_ok') || "OK",
                        onButtonClick: () => window.location.reload()
                    }
                });
            } catch (err) {
                console.error("Restore failed", err);
                showBottomSheet({
                    title: t('title_error') || "Error",
                    bigInfo: {
                        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                        description: "Restore failed: " + err.message,
                        buttonText: t('btn_ok') || "OK",
                        onButtonClick: () => closeBottomSheet()
                    }
                });
            }
        };
        reader.readAsText(file);
    }, 100);
    
    event.target.value = '';
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
            
            <div class="menu-hint">
                <span data-i18n="hint_generation_settings">Looking for generation settings? You can find them in chat by tapping the icon</span>&nbsp;<svg viewBox="0 0 24 24" class="hint-icon"><path d="M19 9l1.25-2.75L23 5l-2.75-1.25L19 1l-1.25 2.75L15 5l2.75 1.25L19 9zm-7.5.5L9 4 6.5 9.5 1 12l5.5 2.5L9 20l2.5-5.5L17 12l-5.5-2.5zM19 15l-1.25 2.75L15 19l2.75 1.25L19 23l1.25-2.75L23 19l-2.75-1.25L19 15z"/></svg>
            </div>
            <div class="menu-item" @click="openBackupOptions">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M19.35 10.04A7.49 7.49 0 0 0 12 4C9.11 4 6.6 5.64 5.35 8.04A5.994 5.994 0 0 0 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM19 18H6c-2.21 0-4-1.79-4-4 0-2.05 1.53-3.76 3.56-3.97l1.07-.11.5-.95A5.469 5.469 0 0 1 12 6c2.62 0 4.88 1.86 5.39 4.43l.3 1.5 1.53.11A2.98 2.98 0 0 1 22 15c0 1.65-1.35 3-3 3zM8 13h2.55v3h2.9v-3H16l-4-4z"/></svg>
                <div class="menu-text" data-i18n="menu_backups">Backups</div>
            </div>
            <input type="file" id="restore-input" style="display: none" accept="*/*" @change="handleRestoreFile">
        </div>

        <div class="menu-group">
            <div class="section-header" data-i18n="section_info">Info</div>
            <div class="menu-item" @click="openAbout">
                <svg class="menu-icon" viewBox="0 0 24 24"><path d="M11 7h2v2h-2zm0 4h2v6h-2zm1-9C6.48 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z"/></svg>
                <div class="menu-text" data-i18n="menu_about">About Cradle</div>
            </div>
        </div>

        <AboutView ref="aboutView" />
    </div>
</template>

<style scoped>
.menu-hint {
    padding: 0px 20px 12px 20px;
    font-size: 13px;
    color: var(--text-gray, #8E8E93);
    line-height: 1.4;
    opacity: 0.9;
}

.hint-icon {
    width: 14px;
    height: 14px;
    fill: currentColor;
    display: inline-block;
    vertical-align: middle;
    margin-bottom: 2px;
}
</style>