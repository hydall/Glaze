import { reactive, watch } from 'vue';

import { userDefaultPresets } from './defaultPresets.js';
import { logger } from '../../utils/logger.js';

export const DEFAULT_PRESETS = {};

Object.assign(DEFAULT_PRESETS, userDefaultPresets);

export const presetState = reactive({
    presets: JSON.parse(JSON.stringify(DEFAULT_PRESETS)),
    connections: {
        character: {}, // charId -> presetId
        chat: {}       // chatId -> presetId
    },
    globalPresetId: 'default_shino',
    initialized: false
});

export async function initPresetState(force = false) {
    if (presetState.initialized && !force) return;
    logger.debug('[presetState] Initializing...');

    presetState.presets = JSON.parse(JSON.stringify(DEFAULT_PRESETS));
    presetState.connections = { character: {}, chat: {} };
    presetState.globalPresetId = 'default_shino';

    let didBackfillCreatedAt = false;

    try {
        const savedPresets = localStorage.getItem('silly_cradle_presets');
        if (savedPresets) {
            presetState.presets = JSON.parse(savedPresets);
            // Backfill IDs if missing
            for (const key in DEFAULT_PRESETS) {
                if (presetState.presets[key]) {
                    // Sync immutable default properties (id, descriptionKey, author if it's a default, etc.)
                    // but don't overwrite user-editable content blocks (they have reset buttons anyway)
                    presetState.presets[key].descriptionKey = DEFAULT_PRESETS[key].descriptionKey;
                    if (DEFAULT_PRESETS[key].author) presetState.presets[key].author = DEFAULT_PRESETS[key].author;
                    if (DEFAULT_PRESETS[key].authorLink) presetState.presets[key].authorLink = DEFAULT_PRESETS[key].authorLink;
                    if (DEFAULT_PRESETS[key].image) presetState.presets[key].image = DEFAULT_PRESETS[key].image;
                    if (DEFAULT_PRESETS[key].isFeatured) presetState.presets[key].isFeatured = DEFAULT_PRESETS[key].isFeatured;
                } else {
                    presetState.presets[key] = JSON.parse(JSON.stringify(DEFAULT_PRESETS[key]));
                }
            }
        }

        // Backfill createdAt for stable sorting by "date added"
        const now = Date.now();
        for (const id in presetState.presets) {
            const preset = presetState.presets[id];
            if (!preset || preset.createdAt !== undefined) continue;

            // Try to derive from our historical id scheme: Date.now().toString(36)
            const derived = Number.parseInt(String(id), 36);
            if (Number.isFinite(derived) && derived > 0 && derived <= now + 1000) {
                preset.createdAt = derived;
            } else {
                preset.createdAt = 0;
            }
            didBackfillCreatedAt = true;
        }

        const savedId = localStorage.getItem('silly_cradle_current_preset_id');
        if (savedId && savedId !== 'undefined' && presetState.presets[savedId]) {
            presetState.globalPresetId = savedId;
            logger.debug('[presetState] Loaded globalPresetId:', savedId);
        } else {
            presetState.globalPresetId = 'default_shino';
            logger.debug('[presetState] Global preset fallback to default_shino (reason: missing or invalid savedId)');
        }

        const savedConnections = localStorage.getItem('gz_preset_connections');
        if (savedConnections) {
            const parsed = JSON.parse(savedConnections);
            presetState.connections = {
                character: parsed.character || {},
                chat: parsed.chat || {}
            };
        }
    } catch (e) {
        console.error('Failed to initPresetState:', e);
    }

    presetState.initialized = true;
    logger.debug('[presetState] Initialized');

    // Persist one-time migrations
    if (didBackfillCreatedAt) {
        savePresets();
    }
}

export function savePresets() {
    try {
        localStorage.setItem('silly_cradle_presets', JSON.stringify(presetState.presets));
        localStorage.setItem('silly_cradle_current_preset_id', presetState.globalPresetId);
        localStorage.setItem('gz_preset_connections', JSON.stringify(presetState.connections));
    } catch (e) {
        if (e.name === 'QuotaExceededError' || e.name === 'NS_ERROR_DOM_QUOTA_REACHED') {
            console.error('[presetState] LocalStorage quota exceeded!', e);
            // Optional: alert user or handle cleaning up
        } else {
            console.error('[presetState] Failed to save presets:', e);
        }
    }
}

// Auto-save on changes with debounce
let saveTimer = null;
watch(() => presetState, () => {
    if (presetState.initialized) {
        if (saveTimer) clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            savePresets();
            saveTimer = null;
        }, 1000);
    }
}, { deep: true });

// Call when closing the preset editor to flush any pending debounced save
export function flushPresetSave() {
    if (saveTimer) {
        clearTimeout(saveTimer);
        saveTimer = null;
    }
    savePresets();
}

export function setPresetConnection(type, targetId, presetId) {
    if (type === 'global') {
        const newId = presetId || 'default_shino';
        presetState.globalPresetId = newId;
        logger.debug('[presetState] Global preset set to:', newId);
    } else if (type === 'character' || type === 'chat') {
        if (presetId === null) {
            delete presetState.connections[type][targetId];
        } else {
            presetState.connections[type][targetId] = presetId;
        }
    }
}

export function getEffectivePresetId(charId, chatId) {
    logger.debug('[presetState] Resolving effective preset for', { charId, chatId });
    // Priority: Chat > Character > Global
    if (chatId && presetState.connections.chat[chatId]) {
        const id = presetState.connections.chat[chatId];
        logger.debug('[presetState] Found chat connection:', id);
        return id;
    }
    if (charId && presetState.connections.character[charId]) {
        const id = presetState.connections.character[charId];
        logger.debug('[presetState] Found character connection:', id);
        return id;
    }
    logger.debug('[presetState] Falling back to globalPresetId:', presetState.globalPresetId);
    return presetState.globalPresetId;
}

export function getEffectivePreset(charId, chatId) {
    const id = getEffectivePresetId(charId, chatId);
    return presetState.presets[id] || presetState.presets['default_shino'] || Object.values(presetState.presets)[0];
}
