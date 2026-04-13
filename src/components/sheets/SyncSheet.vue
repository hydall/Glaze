<script setup>
import { ref, computed, onMounted } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import {
    syncProvider, syncStatus, syncLastError, lastSyncTime,
    syncProgress, syncSettings, syncConflicts,
    autoSyncEnabled, autoSyncThreshold, isSyncConfigured,
    PROVIDERS, SYNC_STATUS,
    setProvider, clearProvider, setSyncError, setSyncProgress,
    clearSyncProgress, saveSettings, accountInfo
} from '@/core/states/syncState.js';
import * as dropboxAdapter from '@/core/services/adapters/dropboxAdapter.js';
import * as gdriveAdapter from '@/core/services/adapters/gdriveAdapter.js';
import { generateSyncKey, hasSyncKey, restoreKeyFromPhrase } from '@/core/services/crypto/keyManager.js';
import { fullPush, fullPull, fullSync, checkSyncReadiness } from '@/core/services/syncService.js';

const sheet = ref(null);
defineProps({ zIndex: { type: Number, default: 1005 } });

const t = (key) => translations[currentLang.value]?.[key] || key;

const isConnecting = ref(false);
const isConnectingGdrive = ref(false);
const isDisconnecting = ref(false);
const showRecoveryPhrase = ref(false);
const recoveryPhrase = ref('');
const showRestorePhrase = ref(false);
const restorePhraseInput = ref('');
const isRestoringKey = ref(false);
const localSyncStatus = ref('');
const syncResult = ref(null);
const isSyncing = ref(false);

const providerLabel = computed(() => {
    if (!syncProvider.value) return '';
    return syncProvider.value === PROVIDERS.DROPBOX ? 'Dropbox' : 'Google Drive';
});

const statusLabel = computed(() => {
    if (syncStatus.value === SYNC_STATUS.SYNCING) return t('sync_status_syncing') || 'Syncing...';
    if (syncStatus.value === SYNC_STATUS.ERROR) return t('sync_status_error') || 'Error';
    if (syncStatus.value === SYNC_STATUS.CONFLICT) return t('sync_status_conflict') || 'Conflict detected';
    if (lastSyncTime.value) {
        const ago = formatTimeAgo(lastSyncTime.value);
        return `${t('sync_last_sync') || 'Last sync'}: ${ago}`;
    }
    return t('sync_status_idle') || 'Ready';
});

const progressLabel = computed(() => {
    if (!syncProgress.phase) return '';
    const phaseKey = `sync_phase_${syncProgress.phase}`;
    const phase = t(phaseKey) || syncProgress.phase;
    if (syncProgress.total > 0) return `${phase} (${syncProgress.current}/${syncProgress.total})`;
    return phase;
});

function formatTimeAgo(ts) {
    const diff = Math.floor((Date.now() - ts) / 1000);
    if (diff < 60) return t('sync_just_now') || 'just now';
    if (diff < 3600) return `${Math.floor(diff / 60)}m ${t('sync_ago') || 'ago'}`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ${t('sync_ago') || 'ago'}`;
    return `${Math.floor(diff / 86400)}d ${t('sync_ago') || 'ago'}`;
}

const connectDropbox = async () => {
    isConnecting.value = true;
    try {
        await dropboxAdapter.connect();
        setProvider(PROVIDERS.DROPBOX);
        const info = await dropboxAdapter.getAccountInfo();
        accountInfo.value = info;
        const ready = await checkSyncReadiness();
        localSyncStatus.value = ready.ready ? 'connected' : 'no_key';
    } catch (e) {
        console.error('[SyncSheet] Dropbox connect failed:', e);
        setSyncError(e.message);
        alert(e.message);
    } finally {
        isConnecting.value = false;
    }
};

const connectGdrive = async () => {
    isConnectingGdrive.value = true;
    try {
        await gdriveAdapter.connect();
        setProvider(PROVIDERS.GDRIVE);
        const info = await gdriveAdapter.getAccountInfo();
        accountInfo.value = info;
        const ready = await checkSyncReadiness();
        localSyncStatus.value = ready.ready ? 'connected' : 'no_key';
    } catch (e) {
        console.error('[SyncSheet] Google Drive connect failed:', e);
        setSyncError(e.message);
        alert(e.message);
    } finally {
        isConnectingGdrive.value = false;
    }
};

const disconnectProvider = async () => {
    if (!confirm(t('sync_confirm_disconnect') || 'Disconnect cloud sync? Your local data will remain intact.')) return;
    isDisconnecting.value = true;
    try {
        if (syncProvider.value === PROVIDERS.DROPBOX) {
            await dropboxAdapter.disconnect();
        } else if (syncProvider.value === PROVIDERS.GDRIVE) {
            await gdriveAdapter.disconnect();
        }
        clearProvider();
        accountInfo.value = null;
        localSyncStatus.value = '';
        syncResult.value = null;
    } catch (e) {
        console.error('[SyncSheet] Disconnect failed:', e);
    } finally {
        isDisconnecting.value = false;
    }
};

const setupEncryption = async () => {
    try {
        const result = await generateSyncKey();
        recoveryPhrase.value = result.recoveryPhrase;
        showRecoveryPhrase.value = true;
    } catch (e) {
        console.error('[SyncSheet] Key generation failed:', e);
        setSyncError(e.message);
    }
};

const confirmRecoveryPhrase = () => {
    showRecoveryPhrase.value = false;
    localSyncStatus.value = 'connected';
};

const startRestore = () => {
    restorePhraseInput.value = '';
    showRestorePhrase.value = true;
};

const doRestore = async () => {
    if (!restorePhraseInput.value.trim()) return;
    isRestoringKey.value = true;
    try {
        await restoreKeyFromPhrase(restorePhraseInput.value.trim());
        showRestorePhrase.value = false;
        localSyncStatus.value = 'connected';
    } catch (e) {
        alert(t('sync_invalid_phrase') || 'Invalid recovery phrase. Check your 12 words and try again.');
    } finally {
        isRestoringKey.value = false;
    }
};

const doPush = async () => {
    isSyncing.value = true;
    syncResult.value = null;
    try {
        const result = await fullPush();
        syncResult.value = { type: 'push', ...result };
    } catch (e) {
        console.error('[SyncSheet] Push failed:', e);
        showBottomSheet({
            title: t('title_error') || 'Error',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: e.message,
                buttonText: t('btn_ok') || 'OK',
                onButtonClick: () => closeBottomSheet()
            }
        });
    } finally {
        isSyncing.value = false;
    }
};

const doPull = async () => {
    if (!confirm(t('sync_confirm_pull') || 'Pull from cloud? Local data that is older will be overwritten.')) return;
    isSyncing.value = true;
    syncResult.value = null;
    try {
        const result = await fullPull();
        syncResult.value = { type: 'pull', ...result };
        if (syncConflicts.value.length > 0) {
            window.dispatchEvent(new CustomEvent('open-conflict-sheet'));
        }
    } catch (e) {
        console.error('[SyncSheet] Pull failed:', e);
        showBottomSheet({
            title: t('title_error') || 'Error',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: e.message,
                buttonText: t('btn_ok') || 'OK',
                onButtonClick: () => closeBottomSheet()
            }
        });
    } finally {
        isSyncing.value = false;
    }
};

const doFullSync = async () => {
    isSyncing.value = true;
    syncResult.value = null;
    try {
        await fullSync();
        syncResult.value = { type: 'full' };
    } catch (e) {
        console.error('[SyncSheet] Full sync failed:', e);
    } finally {
        isSyncing.value = false;
    }
};

const openConflictSheet = () => {
    window.dispatchEvent(new CustomEvent('open-conflict-sheet'));
};

const open = () => {
    localSyncStatus.value = '';
    syncResult.value = null;
    sheet.value?.open();
};
const close = () => sheet.value?.close();

defineExpose({ open, close });

onMounted(async () => {
    const hasKey = await hasSyncKey();
    if (!hasKey && syncProvider.value) {
        localSyncStatus.value = 'no_key';
    } else if (hasKey && syncProvider.value) {
        localSyncStatus.value = 'connected';
    }
});
</script>

<template>
    <SheetView ref="sheet" :z-index="zIndex" :title="t('menu_cloud_sync') || 'Cloud Sync'" :fit-content="true">
        <div class="bs-body">
            <!-- Not connected: provider selection -->
            <div v-if="!syncProvider" class="bs-sections">
                <div class="bs-section">
                    <div class="bs-section-title">{{ t('sync_connect_provider') || 'Connect a Cloud Provider' }}</div>
                    
                    <button class="bs-btn bs-connect-btn" @click="connectDropbox" :disabled="isConnecting">
                        <svg viewBox="0 0 24 24"><path d="M7.5 2L2 6l3.75 3L2 12l5.5 4 3.75-3 3.75 3 5.5-4-4.5-3L20.5 6 15 2l-3.75 3L7.5 2zm3.75 10L7.5 15l3.75 3 3.75-3-3.75-3zM7.5 16l-1.88 1.5L3 19l5.5 4 3.75-3-4.75-4zm9-4l1.88-1.5L21 8l-5.5-4-3.75 3L16.5 8l-1.88 1.5L11 12l5.5 4 3.75-3-4.75-4z"/></svg>
                        <span v-if="isConnecting">{{ t('sync_connecting') || 'Connecting...' }}</span>
                        <span v-else>Dropbox</span>
                    </button>

                    <button class="bs-btn bs-gdrive-btn" @click="connectGdrive" :disabled="isConnectingGdrive" style="margin-top:8px">
                        <svg viewBox="0 0 24 24"><path d="M7.71 3.5L1.15 15l4.58 7.5L12.29 11 7.71 3.5zm1.14 0L19.41 3.5 12.86 15H1.72l5.13-11.5zm10.01 0L13.72 15l4.58 7.5 5.55-11.5-5-7.5z"/></svg>
                        <span v-if="isConnectingGdrive">{{ t('sync_connecting') || 'Connecting...' }}</span>
                        <span v-else>Google Drive</span>
                    </button>

                    <div class="bs-hint">
                        {{ t('sync_hint_cloud') || 'Your data will be encrypted before upload. Only you can read it.' }}
                    </div>

                    <div v-if="syncLastError && !syncProvider" class="sync-error-msg">
                        {{ syncLastError }}
                    </div>
                </div>

                <div class="bs-separator"></div>

                <div class="bs-section">
                    <div class="bs-section-title">{{ t('sync_restore_key') || 'Restore from Recovery Phrase' }}</div>
                    <button class="bs-btn bs-secondary-btn" @click="startRestore">
                        <svg viewBox="0 0 24 24"><path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/></svg>
                        <span>{{ t('sync_enter_phrase') || 'Enter Recovery Phrase' }}</span>
                    </button>
                </div>
            </div>

            <!-- Connected: status and controls -->
            <div v-else class="bs-sections">
                <div class="bs-section">
                    <div class="sync-status-card">
                        <div class="sync-provider-badge">
                            <svg v-if="syncProvider === 'dropbox'" viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M7.5 2L2 6l3.75 3L2 12l5.5 4 3.75-3 3.75 3 5.5-4-4.5-3L20.5 6 15 2l-3.75 3L7.5 2zm3.75 10L7.5 15l3.75 3 3.75-3-3.75-3z"/></svg>
                            <svg v-else-if="syncProvider === 'gdrive'" viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M7.71 3.5L1.15 15l4.58 7.5L12.29 11 7.71 3.5zm1.14 0L19.41 3.5 12.86 15H1.72l5.13-11.5zm10.01 0L13.72 15l4.58 7.5 5.55-11.5-5-7.5z"/></svg>
                            <span class="sync-provider-name">{{ providerLabel }}</span>
                            <span class="sync-status-dot" :class="{ connected: localSyncStatus === 'connected' && syncStatus !== SYNC_STATUS.ERROR, error: syncStatus === SYNC_STATUS.ERROR, syncing: syncStatus === SYNC_STATUS.SYNCING }"></span>
                        </div>
                        <div class="sync-status-text" v-if="accountInfo">{{ accountInfo.email }}</div>
                        <div class="sync-status-text">{{ statusLabel }}</div>
                    <button v-if="syncConflicts.length > 0" class="sync-resolve-btn" @click="openConflictSheet">
                        <svg viewBox="0 0 24 24"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>
                        <span>{{ syncConflicts.length }} {{ t('sync_conflicts') || 'conflicts' }} — {{ t('sync_resolve') || 'Resolve' }}</span>
                    </button>
                    </div>

                    <!-- Sync result -->
                    <div v-if="syncResult" class="sync-result-card" :class="syncResult.type">
                        <span v-if="syncResult.type === 'push'">{{ t('sync_push_result') || 'Pushed' }}: {{ syncResult.pushed }} {{ t('sync_items') || 'items' }}</span>
                        <span v-else-if="syncResult.type === 'pull'">{{ t('sync_pull_result') || 'Pulled' }}: {{ syncResult.pulled }} {{ t('sync_items') || 'items' }}, {{ syncResult.conflicts.length }} {{ t('sync_conflicts') || 'conflicts' }}</span>
                        <span v-else>{{ t('sync_full_done') || 'Full sync complete' }}</span>
                    </div>
                </div>

                <!-- Progress bar -->
                <div v-if="syncStatus === SYNC_STATUS.SYNCING && progressLabel" class="sync-progress">
                    <div class="sync-progress-label">{{ progressLabel }}</div>
                    <div class="sync-progress-bar-container">
                        <div class="sync-progress-bar" :style="{ width: syncProgress.total > 0 ? (syncProgress.current / syncProgress.total * 100) + '%' : '0%' }"></div>
                    </div>
                </div>

                <!-- Encryption setup needed -->
                <div v-if="localSyncStatus === 'no_key'" class="bs-section">
                    <div class="bs-section-title">{{ t('sync_encryption') || 'Encryption' }}</div>
                    <div class="bs-hint">{{ t('sync_encryption_setup') || 'Set up encryption to protect your data in the cloud.' }}</div>
                    <button class="bs-btn bs-primary-btn" @click="setupEncryption">
                        <svg viewBox="0 0 24 24"><path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/></svg>
                        <span>{{ t('sync_setup_encryption') || 'Set Up Encryption' }}</span>
                    </button>
                </div>

                <!-- Push/Pull buttons -->
                <div v-if="localSyncStatus === 'connected'" class="bs-section">
                    <div class="bs-section-title">{{ t('sync_manual') || 'Manual Sync' }}</div>
                    <div class="sync-actions-row">
                        <button class="bs-btn bs-push-btn" @click="doPush" :disabled="isSyncing || syncStatus === SYNC_STATUS.SYNCING">
                            <svg viewBox="0 0 24 24"><path d="M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z"/></svg>
                            <span>{{ t('sync_push') || 'Push' }}</span>
                        </button>
                        <button class="bs-btn bs-pull-btn" @click="doPull" :disabled="isSyncing || syncStatus === SYNC_STATUS.SYNCING">
                            <svg viewBox="0 0 24 24"><path d="M11 4H5v6h2V7.41L14.59 15 16 13.59 8.41 6H11V4zm8 12h-6v2h6v-2zm-2-8H11v2h6V8z"/></svg>
                            <span>{{ t('sync_pull') || 'Pull' }}</span>
                        </button>
                    </div>
                </div>

                <!-- Auto-sync settings -->
                <div v-if="localSyncStatus === 'connected'" class="bs-section">
                    <div class="bs-section-title">{{ t('sync_auto_sync') || 'Auto-Sync' }}</div>
                    <div class="settings-item-checkbox" @click="autoSyncEnabled = !autoSyncEnabled" style="cursor: pointer; padding: 8px 0;">
                        <div class="settings-text-col">
                            <label style="cursor: pointer;">{{ t('sync_enable_auto') || 'Enable Auto-Sync' }}</label>
                            <div class="settings-desc">{{ t('sync_auto_desc') || 'Automatically sync after every N messages' }}</div>
                        </div>
                        <input type="checkbox" class="vk-switch" :checked="autoSyncEnabled" style="pointer-events: none;">
                    </div>
                    <div v-if="autoSyncEnabled" class="sync-threshold">
                        <label>{{ t('sync_every') || 'Every' }}</label>
                        <input type="number" v-model.number="autoSyncThreshold" min="1" max="50" class="sync-threshold-input">
                        <label>{{ t('sync_messages') || 'messages' }}</label>
                    </div>
                </div>

                <div class="bs-separator"></div>

                <div class="bs-section">
                    <button class="bs-btn bs-danger-btn" @click="disconnectProvider" :disabled="isDisconnecting">
                        <svg viewBox="0 0 24 24"><path d="M17 7l-1.41 1.41L18.17 11H8v2h10.17l-2.58 2.58L17 17l5-5zM4 5h8V3H4c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h8v-2H4V5z"/></svg>
                        <span>{{ t('sync_disconnect') || 'Disconnect' }}</span>
                    </button>
                </div>
            </div>

            <!-- Recovery phrase modal -->
            <div v-if="showRecoveryPhrase" class="bs-overlay" @click.self="confirmRecoveryPhrase">
                <div class="bs-modal">
                    <div class="bs-modal-title">{{ t('sync_recovery_title') || 'Save Your Recovery Phrase' }}</div>
                    <div class="bs-modal-desc">{{ t('sync_recovery_desc') || 'Write down these 12 words and keep them safe. You will need them to decrypt your data on a new device. This phrase will NOT be shown again.' }}</div>
                    <div class="recovery-phrase-box">
                        {{ recoveryPhrase }}
                    </div>
                    <button class="bs-btn bs-primary-btn" @click="confirmRecoveryPhrase" style="width:100%">
                        {{ t('sync_phrase_saved') || 'I Have Saved This Phrase' }}
                    </button>
                </div>
            </div>

            <!-- Restore phrase modal -->
            <div v-if="showRestorePhrase" class="bs-overlay" @click.self="showRestorePhrase = false">
                <div class="bs-modal">
                    <div class="bs-modal-title">{{ t('sync_restore_title') || 'Enter Recovery Phrase' }}</div>
                    <div class="bs-modal-desc">{{ t('sync_restore_desc') || 'Enter the 12-word recovery phrase from when you first set up encryption.' }}</div>
                    <textarea v-model="restorePhraseInput" class="restore-input" placeholder="word1 word2 word3..." rows="3"></textarea>
                    <button class="bs-btn bs-primary-btn" @click="doRestore" :disabled="isRestoringKey || !restorePhraseInput.trim()" style="width:100%">
                        {{ isRestoringKey ? (t('sync_restoring') || 'Restoring...') : (t('sync_restore_btn') || 'Restore Key') }}
                    </button>
                </div>
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

.bs-btn:disabled {
    opacity: 0.7;
    cursor: default;
}

.bs-primary-btn {
    background: var(--vk-blue);
    color: white;
    box-shadow: 0 4px 12px rgba(var(--vk-blue-rgb), 0.3);
}

.bs-primary-btn:active:not(:disabled) {
    transform: scale(0.98);
    box-shadow: 0 2px 6px rgba(var(--vk-blue-rgb), 0.2);
}

.bs-connect-btn {
    background: var(--vk-blue);
    color: white;
    box-shadow: 0 4px 12px rgba(var(--vk-blue-rgb), 0.3);
}

.bs-connect-btn:active:not(:disabled) {
    transform: scale(0.98);
}

.bs-gdrive-btn {
    background: #4285F4;
    color: white;
    box-shadow: 0 4px 12px rgba(66, 133, 244, 0.3);
}

.bs-gdrive-btn:active:not(:disabled) {
    transform: scale(0.98);
}

.bs-secondary-btn {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

.bs-secondary-btn:active:not(:disabled) {
    background: rgba(var(--vk-blue-rgb), 0.2);
    transform: scale(0.98);
}

.bs-danger-btn {
    background: rgba(255, 59, 48, 0.1);
    color: #ff3b30;
}

.bs-danger-btn:active:not(:disabled) {
    background: rgba(255, 59, 48, 0.2);
    transform: scale(0.98);
}

.bs-push-btn {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    flex: 1;
}

.bs-push-btn:active:not(:disabled) {
    background: rgba(var(--vk-blue-rgb), 0.2);
    transform: scale(0.98);
}

.bs-pull-btn {
    background: var(--vk-blue);
    color: white;
    box-shadow: 0 4px 12px rgba(var(--vk-blue-rgb), 0.3);
    flex: 1;
}

.bs-pull-btn:active:not(:disabled) {
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
    background: rgba(255, 255, 255, 0.1);
    margin: 8px 0;
}

.sync-status-card {
    background: rgba(var(--vk-blue-rgb), 0.05);
    border: 1px solid rgba(var(--vk-blue-rgb), 0.15);
    border-radius: 12px;
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.sync-provider-badge {
    display: flex;
    align-items: center;
    gap: 8px;
}

.sync-provider-name {
    font-weight: 600;
    font-size: 16px;
    color: var(--text-black);
}

.sync-status-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: var(--text-gray, #8e8e93);
    margin-left: auto;
    transition: background 0.3s;
}

.sync-status-dot.connected {
    background: #4CAF50;
}

.sync-status-dot.error {
    background: #ff3b30;
}

.sync-status-dot.syncing {
    background: #FF9800;
    animation: pulse 1.5s infinite;
}

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
}

.sync-status-text {
    font-size: 13px;
    color: var(--text-gray, #8e8e93);
}

.sync-resolve-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 12px;
    border-radius: 8px;
    background: rgba(255, 149, 0, 0.1);
    color: #FF9500;
    border: none;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    font-family: inherit;
    transition: all 0.2s;
    margin-top: 4px;
}

.sync-resolve-btn svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
}

.sync-resolve-btn:active {
    background: rgba(255, 149, 0, 0.2);
    transform: scale(0.98);
}

.sync-error-msg {
    font-size: 13px;
    color: #ff3b30;
    background: rgba(255, 59, 48, 0.08);
    border-radius: 8px;
    padding: 8px 12px;
    margin-top: 4px;
    line-height: 1.4;
}

.sync-result-card {
    font-size: 13px;
    padding: 8px 12px;
    border-radius: 8px;
    background: rgba(76, 175, 80, 0.1);
    color: #4CAF50;
}

.sync-result-card.pull {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

.sync-progress {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.sync-progress-label {
    font-size: 12px;
    color: var(--text-gray, #8e8e93);
}

.sync-progress-bar-container {
    width: 100%;
    height: 4px;
    background: rgba(255, 255, 255, 0.1);
    border-radius: 2px;
    overflow: hidden;
}

.sync-progress-bar {
    height: 100%;
    background: var(--vk-blue);
    border-radius: 2px;
    transition: width 0.3s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.sync-actions-row {
    display: flex;
    gap: 10px;
}

.settings-item-checkbox {
    display: flex;
    align-items: center;
    justify-content: space-between;
}

.settings-text-col {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex: 1;
}

.settings-text-col label {
    font-size: 15px;
    font-weight: 500;
    color: var(--text-black);
}

.settings-desc {
    font-size: 12px;
    color: var(--text-gray, #8e8e93);
    font-weight: normal;
}

.sync-threshold {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 14px;
    color: var(--text-gray, #8e8e93);
    margin-top: 4px;
}

.sync-threshold-input {
    width: 60px;
    padding: 6px 8px;
    border-radius: 8px;
    border: 1px solid rgba(var(--vk-blue-rgb), 0.3);
    background: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    color: var(--text-black);
    font-size: 14px;
    text-align: center;
    font-family: inherit;
}

.bs-overlay {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 20000;
    padding: 16px;
}

.bs-modal {
    background: var(--app-bg);
    border-radius: 16px;
    padding: 24px;
    max-width: 400px;
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.bs-modal-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-black);
}

.bs-modal-desc {
    font-size: 14px;
    color: var(--text-gray, #8e8e93);
    line-height: 1.5;
}

.recovery-phrase-box {
    background: rgba(var(--vk-blue-rgb), 0.08);
    border: 1px dashed rgba(var(--vk-blue-rgb), 0.4);
    border-radius: 10px;
    padding: 14px;
    font-size: 16px;
    font-weight: 600;
    color: var(--vk-blue);
    text-align: center;
    letter-spacing: 1px;
    word-spacing: 4px;
    line-height: 1.8;
    user-select: all;
}

.restore-input {
    width: 100%;
    padding: 10px 12px;
    border-radius: 10px;
    border: 1px solid rgba(var(--vk-blue-rgb), 0.3);
    background: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    color: var(--text-black);
    font-size: 14px;
    font-family: inherit;
    resize: none;
}

.restore-input:focus {
    outline: none;
    border-color: var(--vk-blue);
}
</style>