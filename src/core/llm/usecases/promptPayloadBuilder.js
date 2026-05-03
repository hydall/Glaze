import { lorebookState } from '@/core/states/lorebookState.js';
import { getEffectivePersona } from '@/core/states/personaState.js';
import { db } from '@/utils/db.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { getMemorySettings } from '@/core/services/memorySchema.js';

function loadGlobalVars() {
    try {
        return JSON.parse(localStorage.getItem('gz_global_vars') || '{}');
    } catch (e) {
        return {};
    }
}

export function getPromptWorkerOptions(char, activePreset) {
    return {
        mergePrompts: activePreset?.mergePrompts || false,
        mergeRole: activePreset?.mergeRole || 'system',
        noAssistant: activePreset?.noAssistant || false,
        userPrefix: activePreset?.userPrefix || '',
        charPrefix: activePreset?.charPrefix || '',
        squashRole: activePreset?.squashRole || 'assistant',
        personaObj: getEffectivePersona(char?.id, char?.sessionId) || { name: 'User', prompt: '' }
    };
}

export function buildPromptWorkerPayload({
    char,
    history,
    summary,
    activePreset,
    promptOptions,
    authorsNote,
    guidanceText,
    guidanceType,
    globalRegexes,
    sessionVars,
    apiConfig,
    memoryReserve = 0
}) {
    return JSON.parse(JSON.stringify({
        char,
        history,
        summary,
        activePreset,
        mergePrompts: promptOptions.mergePrompts,
        mergeRole: promptOptions.mergeRole,
        noAssistant: promptOptions.noAssistant,
        userPrefix: promptOptions.userPrefix,
        charPrefix: promptOptions.charPrefix,
        squashRole: promptOptions.squashRole,
        personaObj: promptOptions.personaObj,
        authorsNote: (authorsNote && authorsNote.enabled) ? authorsNote : null,
        guidanceText,
        guidanceType,
        lorebooks: lorebookState.lorebooks,
        globalSettings: lorebookState.globalSettings,
        activations: lorebookState.activations,
        globalRegexes,
        sessionVars,
        globalVars: loadGlobalVars(),
        apiConfig,
        memoryReserve
    }));
}

export async function getMemoryReserveEstimate(char, safeContext) {
    const charId = char?.id;
    const sessionId = char?.sessionId;
    if (!charId || !sessionId) return 0;
    try {
        const chatData = await db.getChat(charId);
        const memoryBook = chatData?.memoryBooks?.[sessionId];
        const settings = getMemorySettings();
        const activeEntries = (Array.isArray(memoryBook?.entries) ? memoryBook.entries : [])
            .filter(e => e && (e.status || 'active') === 'active' && (e.content || '').trim());
        if (!settings.enabled || !activeEntries.length) return 0;
        const maxInjected = Math.max(1, Math.min(20, settings.maxInjectedEntries || 7));
        let totalContentLen = 0;
        for (const entry of activeEntries.slice(0, maxInjected)) {
            totalContentLen += (entry.content || '').trim().length;
        }
        const estimatedTokens = estimateTokens('M'.repeat(totalContentLen));
        return Math.min(estimatedTokens, Math.floor(safeContext * 0.35));
    } catch (e) {
        return 0;
    }
}
