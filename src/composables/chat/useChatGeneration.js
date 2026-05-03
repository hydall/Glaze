import { ref, nextTick } from 'vue';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { db } from '@/utils/db.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { getApiRuntimeStorage } from '@/core/config/APISettings.js';
import { executeChatGenerationUseCase } from '@/core/llm/usecases/generateChat.js';
import { executeImpersonationUseCase } from '@/core/llm/usecases/impersonationRequest.js';
import { resolveGenerationSessionContext } from '@/composables/chat/useGenerationPreparation.js';
import { activePersona } from '@/core/states/personaState.js';
import { addMessageStats } from '@/core/services/statsService.js';
import { generateImage, makeLoadingHtml, makeErrorHtml, makeResultHtml } from '@/core/services/imageGenService.js';
import { startGenerationNotification, stopGenerationNotification } from '@/core/services/notificationService.js';
import { addNotification } from '@/core/states/notificationsState.js';
import { showToast } from '@/core/states/toastState.js';

export function useChatGeneration(deps) {
    const {
        getActiveChatChar,
        currentMessages,
        inputValue,
        isGenerating,
        pendingGuidance,
        getGenerationState,
        abortAnyActiveGeneration,
        getChatGenerationServices,
        genMsgId,
        createBaseMessageMeta,
        nextGenerationId,
        createGenerationRequestToken,
        buildGenerationOwnerKey,
        updateSessionMessage,
        scrollToBottom,
        openApiView,
        memoryDraftState,
        isImpersonating,
        setGenerationState,
        clearGenerationState,
        cleanText,
        activeChar,
        t
    } = deps;

    async function sendMessage(attachedImage = null, guidanceText = null) {
        if (isGenerating.value && getActiveChatChar()) {
            await abortAnyActiveGeneration(getActiveChatChar().id);
            return;
        }

        let effectiveGuidance = guidanceText;
        let effectiveGuidanceType = 'GENERATION';

        if (!effectiveGuidance && pendingGuidance.value) {
            effectiveGuidance = pendingGuidance.value.text;
            effectiveGuidanceType = pendingGuidance.value.type;
            pendingGuidance.value = null;
        }

        const text = inputValue.value.trim();
        const hasImage = typeof attachedImage === 'string';
        if (text || hasImage || effectiveGuidance) {
            const now = new Date();
            const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');

            const persona = activePersona.value;
            const activeChatChar = getActiveChatChar();
            const processedText = replaceMacros(text, activeChatChar, persona);

            inputValue.value = '';

            const msgData = {
                id: genMsgId(),
                role: 'user',
                text: processedText,
                time: time,
                timestamp: now.getTime(),
                image: attachedImage,
                tokens: estimateTokens(processedText),
                persona: { id: activePersona.value?.id, name: activePersona.value?.name },
                guidanceText: effectiveGuidance,
                guidanceType: effectiveGuidanceType,
                ...createBaseMessageMeta()
            };
            currentMessages.value.push(msgData);
            if (activeChatChar) {
                const currentSessionId = activeChatChar.sessionId || (await db.getChat(activeChatChar.id))?.currentId;
                addMessageStats(activeChatChar.id, currentSessionId, msgData.tokens, processedText.length, msgData.timestamp);
                const snapshot = JSON.parse(JSON.stringify(currentMessages.value));
                await db.patchChatData(activeChatChar.id, (data) => {
                    if (currentSessionId && data.sessions?.[currentSessionId]) {
                        data.sessions[currentSessionId] = snapshot;
                    }
                });
            }

            nextTick(() => {
                scrollToBottom(false);
                if (window.forceScrollToBottom) {
                    setTimeout(window.forceScrollToBottom, 100);
                }
            });

            if (activeChatChar) {
                startGeneration(activeChatChar, null, -1, null, effectiveGuidance, effectiveGuidanceType);
            }
        }
    }

    function startGeneration(char, text, existingMsgIndex = -1, onAbort = null, guidanceText = null, guidanceType = 'GENERATION') {
        const runtime = getApiRuntimeStorage();
        const model = runtime.model;
        const endpoint = runtime.normalizedEndpoint;
        const existingState = getGenerationState(char.id);

        if (existingState && existingState.type !== 'impersonation') {
            if (existingState.controller?.signal?.aborted) {
                clearGenerationState(char.id, existingState.genId);
            } else {
            console.warn('[generation] Ignoring overlapping startGeneration call for active chat request', {
                charId: char.id,
                existingGenId: existingState.genId
            });
            return;
            }
        }

        const activeChatChar = getActiveChatChar();
        if (memoryDraftState.value?.active && char.id === activeChatChar?.id) {
            console.warn('[generation] Ignoring startGeneration while memory draft is active', {
                charId: char.id
            });
            showToast(t('stop_memory_draft_first') || 'Stop the memory draft before generating a response');
            return;
        }

        if (!model || !endpoint) {
            showBottomSheet({
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                    description: t('api_not_configured') || "API Not Configured",
                    buttonText: t('btn_configure') || "Configure",
                    onButtonClick: () => {
                        closeBottomSheet();
                        openApiView();
                    }
                }
            });
            return;
        }

        const genId = nextGenerationId();
        const controller = new AbortController();
        const startTime = Date.now();
        const rawStreamRef = ref(text || '');

        setGenerationState(char.id, {
            genId,
            type: 'chat',
            controller,
            startTime,
            pending: true
        });

        resolveGenerationSessionContext({ char, db }).then(context => {
            const pendingState = getGenerationState(char.id);
            if (!pendingState || pendingState.genId !== genId || controller.signal.aborted) {
                return;
            }
            continueGeneration(context);
        }).catch(e => {
            console.error('Failed to load chat for generation:', e);
            const pendingState = getGenerationState(char.id);
            if (pendingState?.genId === genId) {
                clearGenerationState(char.id, genId);
                isGenerating.value = false;
            }
        });

        async function continueGeneration({ sessionId, summary, anContent }) {
            const ownerKey = buildGenerationOwnerKey(char.id, sessionId, 'chat');
            const requestToken = createGenerationRequestToken(ownerKey, genId);

            await executeChatGenerationUseCase({
                char,
                text,
                existingMsgIndex,
                guidanceText,
                guidanceType,
                onAbort,
                resolvedContext: { sessionId, summary, anContent },
                request: {
                    genId,
                    controller,
                    startTime,
                    ownerKey,
                    requestToken,
                    rawStreamRef
                },
                services: getChatGenerationServices()
            });
        }
    }

    async function handleImageRegenerate(msgIndex, { instruction, id }) {
        const char = getActiveChatChar();
        if (!char || !currentMessages.value[msgIndex]) return;
        const msg = currentMessages.value[msgIndex];

        const idEsc = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const loadingHtml = makeLoadingHtml(instruction, id);
        const toLoading = (text) => text
            .replace(new RegExp(`<span[^>]+class="[^"]*imggen-error[^"]*"[^>]+data-iig-id="${idEsc}"[^>]*>[\\s\\S]*?<\\/button><\\/span>`, 'g'), loadingHtml)
            .replace(new RegExp(`<span[^>]+class="[^"]*imggen-result-wrapper[^"]*"[^>]*>[\\s\\S]*?data-iig-id="${idEsc}"[\\s\\S]*?<\\/span>`, 'g'), loadingHtml);

        msg.text = toLoading(msg.text);
        msg.swipes[msg.swipeId || 0] = msg.text;
        updateSessionMessage(char, msgIndex, msg);

        const loadingRe = new RegExp(`<span[^>]+class="[^"]*imggen-loading[^"]*"[^>]+data-iig-id="${idEsc}"[^>]*>(?:<span[^>]*>[\\s\\S]*?<\\/span>)*<\\/span>`, 'g');
        const context = { charAvatar: char.avatar || null, userAvatar: activePersona.value?.avatar || null };

        startGenerationNotification(t('imggen_notification_title') || 'Glaze', t('imggen_notification_body') || 'Generating image...');
        addNotification(t('imggen_notification_body') || 'Generating image...', 'info');

        try {
            const dataUrl = await generateImage(instruction, context);
            const latest = currentMessages.value[msgIndex]?.text || msg.text;
            msg.text = latest.replace(loadingRe, makeResultHtml(instruction, id, dataUrl));
            msg.swipes[msg.swipeId || 0] = msg.text;
            updateSessionMessage(char, msgIndex, msg);
        } catch (err) {
            const latest = currentMessages.value[msgIndex]?.text || msg.text;
            msg.text = latest.replace(loadingRe, makeErrorHtml(instruction, id, err.message));
            msg.swipes[msg.swipeId || 0] = msg.text;
            updateSessionMessage(char, msgIndex, msg);
        } finally {
            stopGenerationNotification();
        }
    }

    async function startImpersonation(guidanceText = null) {
        if (guidanceText) {
            pendingGuidance.value = { text: guidanceText, type: 'IMPERSONATION' };
        } else {
            pendingGuidance.value = null;
        }
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;

        const controller = new AbortController();

        return executeImpersonationUseCase({
            char: activeChatChar,
            guidanceText,
            controller,
            services: {
                app: getChatGenerationServices().app,
                lifecycle: {
                    setGenerationState,
                    clearGenerationState,
                    nextGenerationId,
                    buildGenerationHistory: () => currentMessages.value
                        .map((m, i) => ({ ...m, originalIndex: i }))
                        .filter(m => !m.isTyping && !m.isHidden)
                        .map(m => ({ role: m.role === 'user' ? 'user' : 'assistant', content: m.text, chatId: m.originalIndex })),
                    cleanText
                },
                state: {
                    inputValue,
                    isImpersonating,
                    isGenerating,
                    currentMessages,
                    activeChatChar: activeChar,
                    showBottomSheet,
                    closeBottomSheet,
                    openApiView,
                    t
                }
            }
        });
    }

    return {
        sendMessage,
        startGeneration,
        handleImageRegenerate,
        startImpersonation
    };
}
