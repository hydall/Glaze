import { ref, reactive, computed } from 'vue';
import { db } from '@/utils/db.js';

const STORAGE_KEY = 'gz_sync_settings';
export const SYNC_TOKENS_KEY = 'gz_sync_tokens';

const PROVIDERS = {
    DROPBOX: 'dropbox',
    GDRIVE: 'gdrive'
};

const SYNC_STATUS = {
    IDLE: 'idle',
    SYNCING: 'syncing',
    ERROR: 'error',
    CONFLICT: 'conflict'
};

export const syncStatus = ref(SYNC_STATUS.IDLE);
export const syncProvider = ref(null);
export const syncLastError = ref(null);
export const lastSyncTime = ref(0);
export const syncProgress = reactive({
    phase: '',
    current: 0,
    total: 0
});
export const syncConflicts = ref([]);

export const syncSettings = reactive({
    autoSyncEnabled: true,
    autoSyncMessageCount: 5,
    provider: null
});

let messagesSinceLastSync = 0;

export const accountInfo = ref(null);

export const isSyncConfigured = computed(() => syncProvider.value !== null);

export const autoSyncThreshold = computed({
    get() { return syncSettings.autoSyncMessageCount; },
    set(val) {
        syncSettings.autoSyncMessageCount = Math.max(1, Math.min(50, Number(val) || 5));
        saveSettings();
    }
});

export const autoSyncEnabled = computed({
    get() { return syncSettings.autoSyncEnabled; },
    set(val) {
        syncSettings.autoSyncEnabled = val;
        saveSettings();
    }
});

export function incrementMessageCounter() {
    messagesSinceLastSync++;
}

export function resetMessageCounter() {
    messagesSinceLastSync = 0;
}

export function shouldAutoSync() {
    return syncSettings.autoSyncEnabled
        && syncProvider.value !== null
        && messagesSinceLastSync >= syncSettings.autoSyncMessageCount;
}

export function setSyncProgress(phase, current, total) {
    syncProgress.phase = phase;
    syncProgress.current = current;
    syncProgress.total = total;
}

export function clearSyncProgress() {
    syncProgress.phase = '';
    syncProgress.current = 0;
    syncProgress.total = 0;
}

export function addConflict(conflict) {
    syncConflicts.value.push({
        id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
        timestamp: Date.now(),
        ...conflict
    });
}

export function removeConflict(id) {
    syncConflicts.value = syncConflicts.value.filter(c => c.id !== id);
}

export function clearConflicts() {
    syncConflicts.value = [];
}

export function setSyncError(message) {
    syncLastError.value = message;
    syncStatus.value = SYNC_STATUS.ERROR;
}

export function setProvider(provider) {
    syncProvider.value = provider;
    syncSettings.provider = provider;
    saveSettings();
}

export function clearProvider() {
    syncProvider.value = null;
    syncSettings.provider = null;
    lastSyncTime.value = 0;
    syncLastError.value = null;
    syncConflicts.value = [];
    saveSettings();
}

export function updateLastSyncTime() {
    lastSyncTime.value = Date.now();
    saveSettings();
}

export async function saveSettings() {
    const data = {
        autoSyncEnabled: syncSettings.autoSyncEnabled,
        autoSyncMessageCount: syncSettings.autoSyncMessageCount,
        provider: syncSettings.provider
    };
    localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
}

export async function initSyncState() {
    try {
        const saved = localStorage.getItem(STORAGE_KEY);
        if (saved) {
            const data = JSON.parse(saved);
            if (data.autoSyncEnabled !== undefined) syncSettings.autoSyncEnabled = data.autoSyncEnabled;
            if (data.autoSyncMessageCount !== undefined) syncSettings.autoSyncMessageCount = data.autoSyncMessageCount;
            if (data.provider) {
                syncSettings.provider = data.provider;
                syncProvider.value = data.provider;
            }
        }

        const tokens = await db.get(SYNC_TOKENS_KEY);
        if (tokens && syncProvider.value) {
            const providerTokens = tokens[syncProvider.value];
            if (!providerTokens || !providerTokens.access_token) {
                clearProvider();
            }
        } else if (syncProvider.value && !tokens) {
            clearProvider();
        }
    } catch (e) {
        console.warn('[syncState] Init error:', e);
    }
}

export { PROVIDERS, SYNC_STATUS };
