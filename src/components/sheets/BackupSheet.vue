<!-- src/components/sheets/BackupSheet.vue -->
<script setup>
import { ref } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { exportFullBackupAsync, importFullBackupAsync, importTavoBackupFromZip } from '@/core/services/backupService.js';
import { importSTBackupFromZip } from '@/core/services/stBackupImporter.js';
import { saveFile } from '@/core/services/fileSaver.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';

const sheet = ref(null);
const fileInput = ref(null);

defineProps({
    zIndex: {
        type: Number,
        default: 1005
    }
});

const t = (key) => translations[currentLang.value]?.[key] || key;

const isExporting = ref(false);
const isImporting = ref(false);
const importProgressText = ref('');
const importProgressStage = ref(0);
const importTotalStages = ref(5);
const importComplete = ref(false);

const performExport = async () => {
    isExporting.value = true;
    try {
        const dataString = await exportFullBackupAsync();
        const date = new Date();
        const formattedDate = `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}_${String(date.getHours()).padStart(2,'0')}-${String(date.getMinutes()).padStart(2,'0')}-${String(date.getSeconds()).padStart(2,'0')}`;
        const filename = `Glaze_backup_${formattedDate}.glz`;
        await saveFile(filename, dataString, 'application/json', 'backups');
        
        if (!window.Capacitor?.isNativePlatform()) {
            showBottomSheet({
                title: t('backup_export_complete') || "Export Complete",
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#4CAF50"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    description: t('backup_file_downloaded') || "File downloaded.",
                    buttonText: t('btn_ok') || "OK",
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
    } finally {
        isExporting.value = false;
    }
};

const triggerImport = () => {
    if (fileInput.value) {
        fileInput.value.click();
    }
};

const stageMap = {
    'clearing': { stage: 1, text: t('backup_progress_clearing') || 'Clearing old data...' },
    'reading DB': { stage: 2, text: t('backup_progress_reading') || 'Reading database...' },
    'characters': { stage: 3, text: t('backup_progress_characters') || 'Importing characters...' },
    'lorebooks': { stage: 4, text: t('backup_progress_lorebooks') || 'Importing lorebooks...' },
    'presets': { stage: 4, text: t('backup_progress_presets') || 'Importing presets...' },
    'chats': { stage: 5, text: t('backup_progress_chats') || 'Importing chats...' },
    'personas': { stage: 5, text: t('backup_progress_personas') || 'Importing personas...' },
    'apis': { stage: 5, text: t('backup_progress_apis') || 'Importing API endpoints...' },
    'regexes': { stage: 5, text: t('backup_progress_regex') || 'Importing Regex scripts...' }
};

const updateProgress = (msg) => {
    if (stageMap[msg]) {
        importProgressStage.value = stageMap[msg].stage;
        importProgressText.value = stageMap[msg].text;
    } else {
        importProgressText.value = msg;
    }
};

const handleRestoreFile = async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    
    if (!confirm(t('confirm_restore') || "This will overwrite current data. Continue?")) {
        event.target.value = '';
        return;
    }

    isImporting.value = true;
    importComplete.value = false;
    importProgressStage.value = 0;
    importProgressText.value = t('backup_progress_preparing') || "Preparing import...";
    
    const ext = file.name.split('.').pop().toLowerCase();
    
    try {
        if (ext === 'glz') {
            const reader = new FileReader();
            reader.onload = async (e) => {
                try {
                    importProgressStage.value = 3;
                    importProgressText.value = t('backup_progress_glaze') || "Importing Glaze data...";
                    await importFullBackupAsync(e.target.result);
                    importProgressStage.value = 5;
                    importComplete.value = true;
                } catch (err) {
                    showError(err);
                }
            };
            reader.readAsText(file);
        } else if (ext === 'zip') {
             await importSTBackupFromZip(file, updateProgress);
             importProgressStage.value = 5;
             importComplete.value = true;
        } else if (ext === 'tbk') {
             await importTavoBackupFromZip(file, updateProgress);
             importProgressStage.value = 5;
             importComplete.value = true;
        } else {
             throw new Error("Unsupported file format: ." + ext);
        }
    } catch (err) {
        showError(err);
    }
    
    event.target.value = '';
};

const showError = (err) => {
    isImporting.value = false;
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
};

const open = () => {
    isImporting.value = false;
    importComplete.value = false;
    sheet.value?.open();
};

const close = () => {
    sheet.value?.close();
};

const reloadApp = () => {
    window.location.reload();
};

defineExpose({ open, close });
</script>

<template>
    <SheetView ref="sheet" :z-index="zIndex" :title="t('menu_backups') || 'Backups'" :fit-content="true">
        <div class="bs-body">
            <!-- Normal View -->
            <div v-if="!isImporting && !importComplete" class="bs-sections">
                <div class="bs-section">
                    <div class="bs-section-title">Import</div>
                    <button class="bs-btn bs-import-btn" @click="triggerImport">
                        <svg viewBox="0 0 24 24"><path d="M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z"/></svg>
                        <span>{{ t('menu_import') || 'Import Backup' }}</span>
                    </button>
                    <div class="bs-hint" style="margin-top: 4px;">
                        <div v-html="t('backup_hint_import_tavo') || '<b>Tavo (.tbk):</b> characters, presets, chats'"></div>
                        <div v-html="t('backup_hint_import_st') || '<b>SillyTavern (.zip):</b> characters, lorebooks, presets, chats, personas'"></div>
                        <div v-html="t('backup_hint_import_glaze') || '<b>Glaze (.glz):</b> full application state'"></div>
                    </div>
                </div>

                <div class="bs-separator"></div>

                <div class="bs-section">
                    <div class="bs-section-title">Export</div>
                    <button class="bs-btn bs-export-btn" @click="performExport" :disabled="isExporting">
                        <div v-if="isExporting" class="app-loader-spinner small" style="width: 22px; height: 22px;"></div>
                        <svg v-else viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>
                        <span>{{ isExporting ? (t('exporting_data') || 'Exporting...') : (t('menu_export') || 'Export Data (.glz)') }}</span>
                    </button>
                    <div class="bs-hint">{{ t('backup_hint_export') || 'Create a full backup of your current application state.' }}</div>
                </div>
                
                <input type="file" ref="fileInput" style="display: none" accept="*/*" @change="handleRestoreFile">
            </div>

            <!-- Importing View -->
            <div v-else-if="isImporting && !importComplete" class="bs-progress-view">
                <div class="progress-icon">
                    <div class="app-loader-spinner" style="width: 48px; height: 48px;"></div>
                </div>
                <div class="progress-title">{{ t('importing_data') || 'Importing Data' }}</div>
                <div class="progress-subtitle">{{ importProgressText }}</div>
                
                <div class="progress-bar-container">
                    <div class="progress-bar" :style="{ width: (importProgressStage / importTotalStages) * 100 + '%' }"></div>
                </div>
            </div>

            <!-- Import Complete -->
            <div v-else-if="importComplete" class="bs-success-view">
                <div class="success-icon">
                    <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                </div>
                <div class="success-title">{{ t('backup_success_title') || 'Restore Complete' }}</div>
                <div class="success-subtitle">{{ t('backup_success_desc') || 'Restore successful! The app will now reload to apply changes.' }}</div>
                <button class="bs-btn bs-success-btn" @click="reloadApp">
                    <span>{{ t('btn_reload') || 'Reload App' }}</span>
                </button>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.bs-body {
    padding: 12px 16px 16px;
    display: flex;
    flex-direction: column;
}

.bs-sections {
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.bs-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.bs-section-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-gray, #8e8e93);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-left: 4px;
}

.bs-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 14px 20px;
    border-radius: 14px;
    font-size: 16px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
    border: none;
    font-family: inherit;
}

.bs-btn svg {
    width: 22px;
    height: 22px;
    fill: currentColor;
}

.bs-export-btn {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

.bs-export-btn:active:not(:disabled) {
    background: rgba(var(--vk-blue-rgb), 0.2);
    transform: scale(0.98);
}

.bs-export-btn:disabled {
    opacity: 0.7;
    cursor: default;
}

.bs-import-btn {
    background: var(--vk-blue);
    color: white;
    box-shadow: 0 4px 12px rgba(var(--vk-blue-rgb), 0.3);
}

.bs-import-btn:active {
    transform: scale(0.98);
    box-shadow: 0 2px 6px rgba(var(--vk-blue-rgb), 0.2);
}

.bs-hint {
    font-size: 13px;
    color: var(--text-gray, #8e8e93);
    line-height: 1.5;
    margin-left: 4px;
    opacity: 0.9;
}

.bs-separator {
    height: 1px;
    background: var(--border-color, rgba(0,0,0,0.08));
    margin: 8px 0;
}

body.dark-theme .bs-separator {
    background: rgba(255, 255, 255, 0.1);
}

/* Progress View Layout */
.bs-progress-view, .bs-success-view {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    padding: 16px 16px;
    gap: 16px;
}

.progress-icon {
    margin-bottom: 8px;
}

.progress-title, .success-title {
    font-size: 20px;
    font-weight: 700;
    color: var(--text-black);
}

.progress-subtitle, .success-subtitle {
    font-size: 15px;
    color: var(--text-gray, #8e8e93);
    line-height: 1.5;
}

.progress-bar-container {
    width: 100%;
    height: 8px;
    background: var(--border-color, rgba(0,0,0,0.08));
    border-radius: 4px;
    margin-top: 16px;
    overflow: hidden;
}

body.dark-theme .progress-bar-container {
    background: rgba(255, 255, 255, 0.1);
}

.progress-bar {
    height: 100%;
    background: var(--vk-blue);
    border-radius: 4px;
    transition: width 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
}

/* Success View Layout */
.success-icon {
    width: 64px;
    height: 64px;
    color: var(--vk-blue);
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-bottom: 8px;
}

.success-icon svg {
    width: 32px;
    height: 32px;
    fill: currentColor;
}

.bs-success-btn {
    background: var(--vk-blue);
    color: white;
    width: 100%;
    margin-top: 16px;
    box-shadow: 0 4px 12px rgba(var(--vk-blue-rgb), 0.3);
}

.bs-success-btn:active {
    transform: scale(0.98);
    box-shadow: 0 2px 6px rgba(var(--vk-blue-rgb), 0.2);
}
</style>
