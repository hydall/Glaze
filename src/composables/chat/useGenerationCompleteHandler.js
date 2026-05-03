import { finalizeGenerationState } from './useGenerationFinalization.js';

function applyCompletionToMessage({
    msg,
    response,
    finalReasoning,
    duration,
    meta,
    guidanceText,
    guidanceType,
    estimateTokens,
    char,
    sessionId,
    addMessageStats,
    addRegenerationStats,
    triggerAutoSyncCheck,
    includeInitialGuidanceMeta = true
}) {
    msg.text = response;
    msg.reasoning = finalReasoning;
    msg.genTime = duration;
    msg.tokens = estimateTokens(response);
    msg.isTyping = false;

    if (meta?.partialError) {
        msg.isPartial = true;
        msg.partialErrorMsg = meta.partialError;
    }

    if (meta?.allReasoning) {
        msg.isAllReasoning = true;
    }

    if (!msg.swipes) msg.swipes = [];
    if (!msg.swipesMeta) msg.swipesMeta = [];

    if (msg.swipes.length === 1 && msg.swipes[0] === '') {
        msg.swipes[0] = response;
        msg.swipesMeta[0] = includeInitialGuidanceMeta
            ? {
                genTime: duration,
                reasoning: finalReasoning,
                tokens: msg.tokens,
                guidanceText: msg.guidanceText,
                guidanceType: msg.guidanceType
            }
            : {
                genTime: duration,
                reasoning: finalReasoning,
                tokens: msg.tokens
            };
        addMessageStats(char.id, sessionId, msg.tokens, response.length, msg.timestamp);
        triggerAutoSyncCheck();
    } else {
        msg.swipes[msg.swipeId || 0] = response;
        if (!msg.swipesMeta[msg.swipeId || 0]) msg.swipesMeta[msg.swipeId || 0] = {};
        msg.swipesMeta[msg.swipeId || 0].genTime = duration;
        msg.swipesMeta[msg.swipeId || 0].reasoning = finalReasoning;
        msg.swipesMeta[msg.swipeId || 0].tokens = msg.tokens;
        msg.swipesMeta[msg.swipeId || 0].guidanceText = guidanceText;
        msg.swipesMeta[msg.swipeId || 0].guidanceType = guidanceType;
        addRegenerationStats(char.id, sessionId, msg.tokens, response.length);
    }
}

function resolveFinalResponse(cleanedResponse, existingText) {
    if (cleanedResponse && cleanedResponse.trim()) {
        return cleanedResponse;
    }

    if (existingText && existingText.trim()) {
        console.warn('[onComplete] Preserving streamed text because final response was empty');
        return existingText;
    }

    return cleanedResponse;
}

function normalizeCompletionText(text) {
    return typeof text === 'string' ? text : '';
}

export async function handleGenerationComplete({
    response,
    finalReasoning,
    meta,
    char,
    sessionId,
    msgId,
    genId,
    startTime,
    controller,
    guidanceText,
    guidanceType,
    activeChatChar,
    isGenerating,
    currentMessages,
    displayMessages,
    getGenerationState,
    clearGenerationState,
    clearPersistedGeneration,
    clearBackgroundUpdateTimer,
    clearTypingStateForMessage,
    persistence,
    app,
    cleanText,
    estimateTokens,
    updateSessionMessage,
    processMessageImages,
    userAvatar,
    isItemVisible,
    scrollToIndex,
    smartScroll,
    sendMessageNotification,
    runMemoryAutomationAfterStableTurn,
    addMessageStats,
    addRegenerationStats,
    triggerAutoSyncCheck,
    addNotification
}) {
    const { db } = persistence;
    const { notifyGenerationEnded, notifyChatUpdated } = app;
    const ensureCleanup = () => {
        finalizeGenerationState({
            charId: char.id,
            sessionId,
            getGenerationState,
            clearGenerationState,
            clearPersistedGeneration,
            clearBackgroundUpdateTimer,
            isGenerating,
            activeChatChar
        });
    };

    const ensureStaleCleanup = () => {
        finalizeGenerationState({
            charId: char.id,
            sessionId,
            expectedGenId: genId,
            getGenerationState,
            clearGenerationState,
            clearPersistedGeneration,
            clearBackgroundUpdateTimer,
            isGenerating,
            activeChatChar
        });
    };

    try {
        const currentState = getGenerationState(char.id);
        if (typeof clearBackgroundUpdateTimer === 'function') {
            clearBackgroundUpdateTimer();
        }

        if (!currentState || currentState.genId !== genId) {
            // A newer generation can reuse the same message record (e.g. swipe regeneration).
            // In that case this stale completion must not mutate typing state for the active request.
            if (!currentState) {
                await clearTypingStateForMessage({ charId: char.id, sessionId, msgId });
                ensureStaleCleanup();
            }
            notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
            return;
        }

        if (currentState.timerId) clearTimeout(currentState.timerId);
        if (typeof currentState.clearStreamFlushTimer === 'function') {
            currentState.clearStreamFlushTimer();
        }
        if (typeof currentState.streamFlush === 'function') {
            currentState.streamFlush();
        }
        clearPersistedGeneration(char.id, sessionId);

        const hasCompletionPayload = !!(response || finalReasoning || meta?.partialError);
        if (controller.signal.aborted && !hasCompletionPayload) {
            await clearTypingStateForMessage({ charId: char.id, sessionId, msgId });
            ensureCleanup();
            notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
            return;
        }

        if (controller.signal.aborted && controller.userAborted) {
            await clearTypingStateForMessage({ charId: char.id, sessionId, msgId });
            ensureCleanup();
            notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
            return;
        }

        let wasVisible = false;
        let displayIndex = -1;
        const foundIndex = currentMessages.value.findIndex(m => m.id === currentState.msgId);

        if (foundIndex !== -1) {
            displayIndex = displayMessages.value.findIndex(m => m.type === 'message' && m.originalIndex === foundIndex);
            if (displayIndex !== -1) {
                wasVisible = isItemVisible(displayIndex);
            }
        }

        clearGenerationState(char.id);
        if (activeChatChar?.value && activeChatChar.value.id === char.id) isGenerating.value = false;

        const now = new Date();
        const cleanedResponse = cleanText(normalizeCompletionText(response));
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        const duration = ((Date.now() - startTime) / 1000).toFixed(2) + 's';

        if (activeChatChar?.value && activeChatChar.value.id === char.id && foundIndex !== -1) {
            const msg = currentMessages.value[foundIndex];
            const finalResponse = resolveFinalResponse(cleanedResponse, msg.text);
            msg.time = time;
            applyCompletionToMessage({
                msg,
                response: finalResponse,
                finalReasoning,
                duration,
                meta,
                guidanceText,
                guidanceType,
                estimateTokens,
                char,
                sessionId,
                addMessageStats,
                addRegenerationStats,
                triggerAutoSyncCheck,
                includeInitialGuidanceMeta: true
            });

            await updateSessionMessage(char, foundIndex, msg);

            processMessageImages(msg.text, (updatedText) => {
                msg.text = updatedText;
                msg.swipes[msg.swipeId || 0] = updatedText;
                if (!updatedText.includes('imggen-loading')) {
                    updateSessionMessage(char, foundIndex, msg);
                }
            }, {
                charAvatar: char.avatar || null,
                userAvatar,
                messages: currentMessages.value,
                currentMsgIndex: foundIndex,
                msgId: msg.id
            }).then(finalText => {
                if (finalText !== msg.text) {
                    msg.text = finalText;
                    msg.swipes[msg.swipeId || 0] = finalText;
                    updateSessionMessage(char, foundIndex, msg);
                }
            }).catch(e => console.error('[ImageGen] processMessageImages failed:', e));

            if (wasVisible) {
                scrollToIndex(displayIndex, 'smooth', 'top');
            } else {
                smartScroll();
            }

            sendMessageNotification(char.name, finalResponse, char.avatar, char.id, sessionId, msgId);

            if (guidanceType === 'GENERATION') {
                let autoData = null;
                let autoSessionId = sessionId;
                await db.patchChatData(char.id, (data) => {
                    autoData = data;
                    autoSessionId = char.sessionId || data.currentId;
                    data.sessions[autoSessionId] = currentMessages.value;
                });
                if (autoData) {
                    await runMemoryAutomationAfterStableTurn(autoData, autoSessionId, currentMessages.value, {
                        allowImmediate: true,
                        charId: char.id,
                        syncUi: true
                    });
                }
            }

            notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
            return;
        }

        let bgMessageFound = false;
        let bgFinalResponse = null;
        let bgMsgId = null;
        let bgBIdx = -1;
        let bgMessages = null;
        let bgDataSnapshot = null;

        await db.patchChatData(char.id, (data) => {
            if (!data || !data.sessions[sessionId]) return;
            const bIdx = data.sessions[sessionId].findIndex(m => m.id === msgId);
            if (bIdx === -1) return;
            bgMessageFound = true;
            bgDataSnapshot = data;
            const msg = data.sessions[sessionId][bIdx];
            bgFinalResponse = resolveFinalResponse(cleanedResponse, msg.text);
            msg.time = time;
            applyCompletionToMessage({
                msg,
                response: bgFinalResponse,
                finalReasoning,
                duration,
                meta,
                guidanceText,
                guidanceType,
                estimateTokens,
                char,
                sessionId,
                addMessageStats,
                addRegenerationStats,
                triggerAutoSyncCheck,
                includeInitialGuidanceMeta: false
            });
            bgMsgId = msg.id;
            bgBIdx = bIdx;
            bgMessages = data.sessions[sessionId];
        });

        if (!bgMessageFound) {
            ensureCleanup();
            notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
            return;
        }

        processMessageImages(bgFinalResponse, (updatedText) => {
            if (!updatedText.includes('imggen-loading')) {
                db.patchChatData(char.id, (data) => {
                    if (!data || !data.sessions[sessionId]) return;
                    const idx = data.sessions[sessionId].findIndex(m => m.id === msgId);
                    if (idx === -1) return;
                    const msg = data.sessions[sessionId][idx];
                    msg.text = updatedText;
                    const swipeIdx = msg.swipeId || 0;
                    if (msg.swipes) msg.swipes[swipeIdx] = updatedText;
                });
            }
        }, {
            charAvatar: char.avatar || null,
            userAvatar,
            messages: bgMessages,
            currentMsgIndex: bgBIdx,
            msgId: bgMsgId
        }).then(finalText => {
            db.patchChatData(char.id, (data) => {
                if (!data || !data.sessions[sessionId]) return;
                const idx = data.sessions[sessionId].findIndex(m => m.id === msgId);
                if (idx === -1) return;
                const msg = data.sessions[sessionId][idx];
                if (finalText !== msg.text) {
                    msg.text = finalText;
                    const swipeIdx = msg.swipeId || 0;
                    if (msg.swipes) msg.swipes[swipeIdx] = finalText;
                }
            });
        }).catch(e => console.error('[ImageGen] background processMessageImages failed:', e));

        if (guidanceType === 'GENERATION' && bgDataSnapshot) {
            await runMemoryAutomationAfterStableTurn(bgDataSnapshot, sessionId, bgMessages, {
                allowImmediate: true,
                charId: char.id,
                syncUi: false
            });
        }

        sendMessageNotification(char.name, bgFinalResponse, char.avatar, char.id, sessionId, msgId);

        if (meta?.allReasoning && addNotification) {
            addNotification('The entire response went into the reasoning block', 'warning');
        }

        db.get('gz_unread').then(unread => {
            const newUnread = unread || {};
            newUnread[char.id] = true;
            db.set('gz_unread', newUnread);
            notifyChatUpdated();
        });

        notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
        return;
    } catch (completeErr) {
        console.error('[onComplete] Completion handler failed:', completeErr);
        ensureCleanup();
        await clearTypingStateForMessage({
            charId: char.id,
            sessionId,
            msgId,
            errorLabel: '[onComplete]'
        });
        notifyGenerationEnded({ charId: char.id, sessionId, genId, type: 'chat' });
    }
}
