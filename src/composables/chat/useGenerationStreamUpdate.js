import { Capacitor } from '@capacitor/core';
import { shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';

export function createGenerationStreamUpdater({
    char,
    sessionId,
    msgId,
    genId,
    getGenerationState,
    isGenerationStateCurrent,
    persistence,
    onRawText
}) {
    const { db } = persistence;
    let backgroundUpdateTimer = null;
    let backgroundPendingText = null;
    let backgroundPendingReasoning = null;
    const backgroundPersistDelay = Capacitor.isNativePlatform() ? 5000 : (shouldUseBatterySaverUI() ? 3500 : 2000);

    const clearBackgroundUpdateTimer = () => {
        if (backgroundUpdateTimer) {
            clearTimeout(backgroundUpdateTimer);
            backgroundUpdateTimer = null;
        }
    };

    const onUpdate = async (chunk, reasoningChunk, effectiveText, effectiveReasoning, textDelta) => {
        if (typeof onRawText === 'function') {
            onRawText(effectiveText, chunk);
        }

        const state = getGenerationState(char.id);
        if (isGenerationStateCurrent(char.id, { genId, sessionId, type: 'chat' }) && state?.onUIUpdate) {
            state.onUIUpdate(effectiveText, effectiveReasoning, true, textDelta);
            return;
        }

        if (!isGenerationStateCurrent(char.id, { genId, sessionId, type: 'chat' })) {
            return;
        }

        backgroundPendingText = effectiveText;
        backgroundPendingReasoning = effectiveReasoning;
        if (backgroundUpdateTimer) {
            return;
        }

        backgroundUpdateTimer = setTimeout(async () => {
            backgroundUpdateTimer = null;
            if (backgroundPendingText === null) return;

            if (!isGenerationStateCurrent(char.id, { genId, sessionId, type: 'chat' })) return;

            const pendingText = backgroundPendingText;
            const pendingReasoning = backgroundPendingReasoning;
            await db.patchChatData(char.id, (data) => {
                if (data.sessions[sessionId]) {
                    const dbMsg = data.sessions[sessionId].find(m => m.id === msgId);
                    if (dbMsg) {
                        dbMsg.text = pendingText;
                        dbMsg.reasoning = pendingReasoning;
                    }
                }
            });
        }, backgroundPersistDelay);
    };

    return {
        onUpdate,
        clearBackgroundUpdateTimer
    };
}
