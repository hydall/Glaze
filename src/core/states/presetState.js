import { reactive, watch } from 'vue';

import { userDefaultPresets } from './defaultPresets.js';
import { logger } from '../../utils/logger.js';

export const DEFAULT_PRESETS = {
    'default': {
        id: 'default',
        name: 'Default',
        blocks: [
            { id: 'sys1', name: 'Main System', role: 'system', content: 'You are a helpful AI assistant.', enabled: true },
            { id: 'user_persona', name: 'User Persona', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'block_user_persona' },
            { id: 'char_card', name: 'Character Card', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'block_char_card' },
            { id: 'scenario', name: 'Scenario', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'block_scenario' },
            { id: 'example_dialogue', name: 'Dialogue Examples', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'block_example_dialogue' },
            { id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_summary', depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' },
            { id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_authors_notes', depth: 4, insertion_mode: 'relative' },
            { id: 'chat_history', name: 'Chat History', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'block_chat_history' }
        ],
        author: '',
        image: '',
        reasoningEnabled: false,
        impersonationPrompt: '',
        reasoningStart: '<think>',
        reasoningEnd: '</think>',
        mergePrompts: false,
        mergeRole: 'system',
        summaryPrompt: 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}\n\nSummary:'
    }
};

Object.assign(DEFAULT_PRESETS, userDefaultPresets);

export const presetState = reactive({
    presets: JSON.parse(JSON.stringify(DEFAULT_PRESETS)),
    connections: {
        character: {}, // charId -> presetId
        chat: {}       // chatId -> presetId
    },
    globalPresetId: 'default',
    initialized: false
});

export async function initPresetState() {
    if (presetState.initialized) return;
    logger.debug('[presetState] Initializing...');

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

        const savedId = localStorage.getItem('silly_cradle_current_preset_id');
        if (savedId && savedId !== 'undefined' && presetState.presets[savedId]) {
            presetState.globalPresetId = savedId;
            logger.debug('[presetState] Loaded globalPresetId:', savedId);
        } else {
            presetState.globalPresetId = 'default';
            logger.debug('[presetState] Global preset fallback to default (reason: missing or invalid savedId)');
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
        const newId = presetId || 'default';
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
    return presetState.presets[id] || presetState.presets['default'] || Object.values(presetState.presets)[0];
}
