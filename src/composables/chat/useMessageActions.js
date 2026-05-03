import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { db } from '@/utils/db.js';
import { getChatData, createNewSession as dbCreateSession } from '@/utils/sessions.js';
import { prepareEditText, restoreEditText } from '@/core/utils/messageEditHelpers.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { cleanText } from '@/utils/textFormatter.js';
import { processMessageImages, makeResultHtml } from '@/core/services/imageGenService.js';
import { showToast } from '@/core/states/toastState.js';
import { getApiReasoningTags } from '@/core/config/APISettings.js';
import { getEffectivePreset } from '@/core/states/presetState.js';
import { reconcileSessionMemoryState } from '@/core/services/memoryBooksService.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { abortImageGenForMessage } from '@/core/states/imageGenState.js';

export function useMessageActions(deps) {
    const {
        getActiveChatChar,
        currentMessages,
        isGenerating,
        hasGenerationState,
        getGenerationState,
        clearGenerationState,
        abortActiveChatGeneration,
        startGeneration,
        updateSessionMessage,
        updateContextCutoff,
        unhideAllMessages,
        toggleSelection,
        loadChats,
        openChat,
        t
    } = deps;

    async function persistCurrentSessionMessages(chatChar) {
        if (!chatChar?.id) return;
        const snapshot = JSON.parse(JSON.stringify(currentMessages.value));
        await db.patchChatData(chatChar.id, (data) => {
            const sessionId = chatChar.sessionId || data.currentId;
            if (!sessionId) return;
            data.sessions[sessionId] = snapshot;
        });
        const sessionId = chatChar.sessionId;
        try { localStorage.removeItem(`gz_chat_recovery_${chatChar.id}_${sessionId}`); } catch (_e) {}
        publishAppEvent(APP_EVENTS.domain.chat.updated);
    }

    function getReasoningTags() {
        let { start, end } = getApiReasoningTags();

        try {
            const activeChatChar = getActiveChatChar();
            const charId = activeChatChar?.id;
            const chatId = charId && activeChatChar?.sessionId ? `${charId}_${activeChatChar.sessionId}` : null;
            const activePreset = getEffectivePreset(charId, chatId);
            if (activePreset) {
                if (activePreset.reasoningStart) start = activePreset.reasoningStart;
                if (activePreset.reasoningEnd) end = activePreset.reasoningEnd;
            }
        } catch (_e) {}

        return { start, end };
    }

    function regenerateMessage(msgIndex, mode = 'normal', guidanceText = null) {
        if (msgIndex === -1) return;
        const activeChatChar = getActiveChatChar();
        const msg = currentMessages.value[msgIndex];
        const isUser = msg.role === 'user';
        const isLast = msgIndex === currentMessages.value.length - 1;

        if (msg.isError) {
            msg.isError = false;
            msg.text = "";
            msg.reasoning = null;
            msg.isTyping = true;
            if (msg.swipes && msg.swipes.length > 0) {
                msg.swipes[msg.swipeId || 0] = "";
            }
            updateSessionMessage(activeChatChar, msgIndex, msg);
            startGeneration(activeChatChar, null, msgIndex, null, guidanceText, 'SWIPE');
            return;
        }

        if (mode === 'magic' && isUser) {
            startGeneration(activeChatChar, null, -1, null, msg.guidanceText, 'GENERATION');
            return;
        }

        if (!isUser && isLast && mode === 'normal') {
            mode = 'new_variant';
        }

        if ((mode === 'new_variant' || mode === 'guided') && !isUser) {
            const newSwipeIndex = (msg.swipes?.length || 0);
            if (!msg.swipes) msg.swipes = [msg.text];
            msg.swipes.push("");
            if (Array.isArray(msg.swipesMeta)) {
                msg.swipesMeta[newSwipeIndex] = {
                    guidanceText: null,
                    guidanceType: null,
                    reasoning: null,
                    genTime: null,
                    tokens: null
                };
            }
            msg.swipeId = newSwipeIndex;
            msg.text = "";
            msg.reasoning = null;
            msg.genTime = null;
            msg.isAllReasoning = false;
            msg.isPartial = false;
            msg.partialErrorMsg = null;
            msg.isTyping = true;

            let effectiveGuidance = null;
            let effectiveType = 'GENERATION';

            if (mode === 'guided') {
                effectiveGuidance = guidanceText;
                effectiveType = 'SWIPE';
            }

            startGeneration(activeChatChar, null, msgIndex, null, effectiveGuidance, effectiveType);
        } else {
            currentMessages.value.splice(msgIndex);
            persistCurrentSessionMessages(activeChatChar);

            startGeneration(activeChatChar, null, -1, null, guidanceText, 'GENERATION');
        }
    }

    async function branchSession(msgIndex) {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;

        if (isGenerating.value && hasGenerationState(activeChatChar.id)) {
            const state = getGenerationState(activeChatChar.id);
            if (state?.type === 'impersonation') {
                if (state.controller) state.controller.abort();
                clearGenerationState(activeChatChar.id);
                isGenerating.value = false;
            } else {
                await abortActiveChatGeneration(activeChatChar.id);
            }
        }

        const data = await getChatData(activeChatChar.id);
        const currentMsgs = data.sessions[data.currentId] || [];
        const newHistory = JSON.parse(JSON.stringify(currentMsgs.slice(0, msgIndex + 1)));

        const oldSessionId = data.currentId;
        const oldAuthorsNote = data.authorsNotes?.[oldSessionId] ? JSON.parse(JSON.stringify(data.authorsNotes[oldSessionId])) : null;
        const oldMemoryBook = data.memoryBooks?.[oldSessionId]
            ? JSON.parse(JSON.stringify(data.memoryBooks[oldSessionId]))
            : null;

        await dbCreateSession(activeChatChar.id);
        await loadChats();

        await db.patchChatData(activeChatChar.id, (newData) => {
            const newSessionId = newData.currentId;
            newData.sessions[newSessionId] = newHistory;
            if (oldMemoryBook) {
                if (!newData.memoryBooks) newData.memoryBooks = {};
                newData.memoryBooks[newSessionId] = oldMemoryBook;
            }
            reconcileSessionMemoryState(newData, newSessionId, newHistory);
            if (oldAuthorsNote) {
                if (!newData.authorsNotes) newData.authorsNotes = {};
                newData.authorsNotes[newSessionId] = oldAuthorsNote;
            }
            const oldVarsKey = `gz_vars_${activeChatChar.id}_${oldSessionId}`;
            const oldVars = localStorage.getItem(oldVarsKey);
            if (oldVars) {
                const newVarsKey = `gz_vars_${activeChatChar.id}_${newSessionId}`;
                localStorage.setItem(newVarsKey, oldVars);
            }
        });

        const charObj = { ...activeChatChar };
        delete charObj.sessionId;
        await openChat(charObj, null, true);
    }

    function openMessageActions(msg, index) {
        const activeChatChar = getActiveChatChar();
        if (msg.isTyping) {
            showBottomSheet({
                title: t('sheet_title_msg_actions'),
                items: [{
                    label: "Stop generation",
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 6h12v12H6z"/></svg>',
                    iconColor: '#ff4444',
                    onClick: () => {
                        if (activeChatChar && hasGenerationState(activeChatChar.id)) {
                            const state = getGenerationState(activeChatChar.id);
                            if (state?.type === 'impersonation') {
                                if (state.controller) state.controller.abort();
                                clearGenerationState(activeChatChar.id);
                                isGenerating.value = false;
                            } else {
                                abortActiveChatGeneration(activeChatChar.id);
                            }
} else {
                            msg.isTyping = false;
                            persistCurrentSessionMessages(activeChatChar);
                          }
                        closeBottomSheet();
                    }
                }]
            });
            return;
        }

        const items = [];

        if ((msg.role === 'char' && index > 0) || msg.isError) {
            items.push({
                label: t('action_regenerate'),
                icon: '<svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    regenerateMessage(index);
                }
            });
        }

        if (!msg.isError) {
            items.push({
                label: t('action_edit'),
                icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    enterEditMode(msg);
                }
            });
        }

        items.push({
            label: t('action_copy'),
            icon: '<svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>',
            onClick: () => {
                let text = msg.text;
                if (msg.isError) {
                    const div = document.createElement('div');
                    div.innerHTML = text.replace(/<br\s*\/?>/gi, '\n');
                    text = div.textContent || div.innerText || text;
                    text = text.trim();
                }
                navigator.clipboard.writeText(text);
                closeBottomSheet();
            }
        });

        items.push({
            label: t('action_select') || 'Select',
            icon: '<svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-9 14l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>',
            onClick: () => {
                toggleSelection(msg.id);
                closeBottomSheet();
            }
        });

        if (!msg.isError) {
            items.push({
                label: t('action_branch'),
                icon: '<svg viewBox="0 0 24 24"><path d="M17.5 4C15.57 4 14 5.57 14 7.5C14 8.55 14.46 9.49 15.2 10.15L11.2 14.15C10.46 13.46 9.55 13 8.5 13C7.57 13 6.72 13.36 6.08 13.96L6 6.5C6.55 6.23 7 5.69 7 5C7 3.9 6.1 3 5 3C3.9 3 3 3.9 3 5C3 5.69 3.45 6.23 4 6.5L4.08 16.04C3.44 16.64 3 17.43 3 18.5C3 20.43 4.57 22 6.5 22C8.43 22 10 20.43 10 18.5C10 17.55 9.54 16.71 8.8 16.05L12.8 12.05C13.54 12.74 14.45 13.2 15.5 13.2C17.43 13.2 19 11.63 19 9.7C19 7.77 17.43 6.2 15.5 6.2C15.5 6.2 15.5 6.2 15.5 6.2L17.5 4Z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    branchSession(index);
                }
            });
        }

        items.push({
            label: msg.isHidden ? (t('action_unhide_msg') || 'Unhide') : (t('action_hide_msg') || 'Hide'),
            icon: msg.isHidden
                ? '<svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>'
                : '<svg viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>',
            onClick: () => {
                msg.isHidden = !msg.isHidden;
                updateSessionMessage(activeChatChar, index, msg);
                updateContextCutoff();
                closeBottomSheet();
            }
        });

        const hiddenCount = currentMessages.value.filter(m => m && !m.isTyping && m.isHidden).length;
        if (hiddenCount > 0) {
            items.push({
                label: `Unhide All (${hiddenCount})`,
                icon: '<svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5 2.29 0 4.42-.65 6.22-1.78l-1.46-1.46A9.44 9.44 0 0 1 12 17.5c-3.73 0-6.96-2.1-8.56-5.5C5.04 8.6 8.27 6.5 12 6.5c1.41 0 2.75.3 3.96.85l1.53-1.53A11.4 11.4 0 0 0 12 4.5zm8.78 1.72-17 17 1.41 1.41 2.68-2.68A11.79 11.79 0 0 0 12 19.5c5 0 9.27-3.11 11-7.5a11.81 11.81 0 0 0-3.09-4.47l2.28-2.28-1.41-1.41z"/></svg>',
                onClick: () => {
                    unhideAllMessages();
                }
            });
        }

        if (index === currentMessages.value.length - 1) {
            items.push({
                label: t('action_delete_msg'),
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    const msg = currentMessages.value[index];
                    if (msg.isError && msg.swipes && msg.swipes.length > 1) {
                        const currentSwipeId = msg.swipeId || 0;
                        msg.swipes.splice(currentSwipeId, 1);
                        if (msg.swipesMeta) msg.swipesMeta.splice(currentSwipeId, 1);

                        let newSwipeId = currentSwipeId - 1;
                        if (newSwipeId < 0) newSwipeId = 0;

                        msg.swipeId = newSwipeId;
                        msg.text = msg.swipes[newSwipeId] || "";
                        msg.isError = false;

                        if (msg.swipesMeta && msg.swipesMeta[newSwipeId]) {
                            msg.reasoning = msg.swipesMeta[newSwipeId].reasoning;
                            msg.genTime = msg.swipesMeta[newSwipeId].genTime;
                        } else {
                            msg.reasoning = null;
                            msg.genTime = null;
                        }
                        updateSessionMessage(getActiveChatChar(), index, msg);
                    } else {
                        currentMessages.value.splice(index, 1);
                        const chatChar = getActiveChatChar();
                        if (chatChar) {
                            const sid = chatChar.sessionId || '1';
                            const cDel = parseInt(localStorage.getItem(`gz_deleted_char_${chatChar.id}`) || '0', 10);
                            localStorage.setItem(`gz_deleted_char_${chatChar.id}`, cDel + 1);
                            const sDel = parseInt(localStorage.getItem(`gz_deleted_chat_${chatChar.id}_${sid}`) || '0', 10);
                            localStorage.setItem(`gz_deleted_chat_${chatChar.id}_${sid}`, sDel + 1);
                            persistCurrentSessionMessages(chatChar);
                        }
                    }
                    closeBottomSheet();
                }
            });
        }

        showBottomSheet({ title: t('sheet_title_msg_actions'), items });
    }

    function getReasoningTagsForEdit() {
        const tags = getReasoningTags();
        if (tags.start && tags.end) return tags;
        return getApiReasoningTags();
    }

    function enterEditMode(msg) {
        abortImageGenForMessage(msg.id);
        msg._iigMap = msg._iigMap || {};
        const { text, map } = prepareEditText(msg?.text || '', msg._iigMap);
        msg._base64Map = map;

        let editBody = text;
        if (msg.reasoning) {
            const { start: tagStart, end: tagEnd } = getReasoningTagsForEdit();
            editBody = tagStart + msg.reasoning + tagEnd + '\n' + text;
        }

        msg.editText = editBody;
        msg.isEditing = true;
    }

    function saveEdit(msg, index) {
        let newText = restoreEditText(msg.editText || "", msg._base64Map);
        delete msg._base64Map;

        const iigMap = msg._iigMap || {};
        newText = newText.replace(
            /<img\b[^>]*?(?:data-iig-instruction='([^']*)'[^>]*?src="\[IMG:GEN\]"|src="\[IMG:GEN\]"[^>]*?data-iig-instruction='([^']*?)')[^>]*?>/g,
            (match, inst1, inst2) => {
                const raw = inst1 ?? inst2 ?? '{}';
                if (iigMap[raw]) {
                    const { dataUrl, id } = iigMap[raw];
                    let instrObj = {};
                    try {
                        instrObj = JSON.parse(raw.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&'));
                    } catch (_e) {}
                    return makeResultHtml(instrObj, id, dataUrl);
                }
                return match;
            }
        );
        delete msg._iigMap;

        let newReasoning = null;

        const { start: tagStart, end: tagEnd } = getReasoningTagsForEdit();

        if (tagStart && tagEnd) {
            const startIndex = newText.indexOf(tagStart);
            if (startIndex !== -1) {
                const endIndex = newText.indexOf(tagEnd, startIndex);
                if (endIndex !== -1) {
                    newReasoning = newText.substring(startIndex + tagStart.length, endIndex).trim();
                    newText = newText.substring(0, startIndex) + newText.substring(endIndex + tagEnd.length);
                }
            }
        }

        newText = cleanText(newText);
        msg.text = newText;
        msg.reasoning = newReasoning || null;
        msg.isAllReasoning = !newText?.trim() && !!newReasoning;
        msg.tokens = estimateTokens(newText);
        if (msg.swipes) msg.swipes[msg.swipeId || 0] = newText;
        if (msg.swipesMeta && msg.swipesMeta[msg.swipeId || 0]) {
            msg.swipesMeta[msg.swipeId || 0].reasoning = newReasoning || null;
            msg.swipesMeta[msg.swipeId || 0].tokens = msg.tokens;
        }
        msg.isEditing = false;
        updateSessionMessage(getActiveChatChar(), index, msg);
        delete msg.editText;

        if (newText.includes('[IMG:GEN]')) {
            abortImageGenForMessage(msg.id);
            processMessageImages(msg.text, (updatedText) => {
                const mIdx = currentMessages.value.findIndex(m => m.id === msg.id);
                if (mIdx !== -1) {
                    const currentMsg = currentMessages.value[mIdx];
                    currentMsg.text = updatedText;
                    if (currentMsg.swipes) currentMsg.swipes[currentMsg.swipeId || 0] = updatedText;
                    updateSessionMessage(getActiveChatChar(), mIdx, currentMsg);
                }
            }, {
                messages: currentMessages.value,
                currentMsgIndex: index,
                msgId: msg.id
            }).catch(e => console.error('[ImageGen] processMessageImages failed:', e));
        }
    }

    function cancelEdit(msg) {
        msg.isEditing = false;
        delete msg.editText;
        delete msg._base64Map;
        delete msg._iigMap;
    }

    function saveGuidance(msg, index, newGuidance) {
        if (msg.role === 'char') {
            if (msg.swipesMeta && msg.swipesMeta[msg.swipeId || 0] && msg.swipesMeta[msg.swipeId || 0].guidanceType === 'SWIPE') {
                msg.swipesMeta[msg.swipeId || 0].guidanceText = newGuidance;
            }
            if (msg.guidanceType === 'SWIPE') {
                msg.guidanceText = newGuidance;
            }
        } else if (msg.role === 'user') {
            msg.guidanceText = newGuidance;
        }
        updateSessionMessage(getActiveChatChar(), index, msg);
    }

    function toggleImageHidden(msg, index) {
        msg.imageHidden = !msg.imageHidden;
        updateSessionMessage(getActiveChatChar(), index, msg);
        showToast(msg.imageHidden ? 'Изображение скрыто из контекста' : 'Изображение добавлено в контекст');
    }

    return {
        openMessageActions,
        regenerateMessage,
        branchSession,
        enterEditMode,
        saveEdit,
        cancelEdit,
        saveGuidance,
        toggleImageHidden
    };
}
