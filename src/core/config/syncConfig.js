import { PROVIDERS } from '@/core/states/syncState.js';

function env(value) {
    return typeof value === 'string' ? value.trim() : '';
}

export const DROPBOX_APP_KEY = env(import.meta.env.VITE_DROPBOX_APP_KEY);
export const GDRIVE_CLIENT_ID = env(import.meta.env.VITE_GDRIVE_CLIENT_ID);

export function canStartSyncAuth(provider) {
    switch (provider) {
        case PROVIDERS.DROPBOX:
            return Boolean(DROPBOX_APP_KEY);
        case PROVIDERS.GDRIVE:
            return Boolean(GDRIVE_CLIENT_ID);
        default:
            return false;
    }
}

export function hasAnySyncProviderConfigured() {
    return canStartSyncAuth(PROVIDERS.DROPBOX) || canStartSyncAuth(PROVIDERS.GDRIVE);
}
