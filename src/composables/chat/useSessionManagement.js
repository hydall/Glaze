import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { db } from '@/utils/db.js';
import { getChatData, createNewSession as dbCreateSession, deleteSession as dbDeleteSession, switchSession as dbSwitchSession } from '@/utils/sessions.js';
import { addDeletedStats } from '@/core/services/statsService.js';
import { triggerChatImport } from '@/core/services/chatImporter.js';
import { publishAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { updateAppColors } from '@/core/services/ui.js';
import { formatDate } from '@/utils/dateFormatter.js';
import { ensureSessionMemoryBook, ensureMemoryAutomationState, getStableVisibleMessages } from '@/core/services/memoryBooksService.js';

export function useSessionManagement(deps) {
    const {
        activeChar,
        getActiveChatChar,
        setActiveChatChar,
        currentMessages,
        inputValue,
        isGenerating,
        hasGenerationState,
        getGenerationState,
        clearGenerationState,
        abortActiveChatGeneration,
        getChatGenerationServices,
        loadChats,
        openChat,
        asyncSaveCurrentSessionState,
        getCleanupScroll,
        setCleanupScroll,
        t
    } = deps;

    async function deleteSession(sessionId, targetChar) {
        const char = targetChar || getActiveChatChar();

        if (char && hasGenerationState(char.id)) {
            const state = getGenerationState(char.id);
            if (state?.type === 'impersonation') {
                if (state.controller) state.controller.abort();
                clearGenerationState(char.id);
                if (getActiveChatChar() && getActiveChatChar().id === char.id) {
                    isGenerating.value = false;
                }
            } else {
                await abortActiveChatGeneration(char.id);
            }
        }

        if (char) {
            const data = await getChatData(char.id);
            let isLast = false;
            if (data) {
                if (data.sessions) {
                    if (Object.keys(data.sessions).length <= 1 && data.sessions[sessionId]) isLast = true;
                } else if (Array.isArray(data)) {
                    isLast = true;
                }
            }

            if (isLast) {
                let deletedCount = 0;
                if (Array.isArray(data)) {
                    deletedCount = data.length;
                    await db.saveChat(char.id, { currentId: 1, sessions: {} });
                } else if (data.sessions) {
                    if (data.sessions[sessionId]) deletedCount = data.sessions[sessionId].length;
                    await db.patchChatData(char.id, (d) => {
                        delete d.sessions[sessionId];
                    });
                }
                if (deletedCount > 0) addDeletedStats(char.id, sessionId, deletedCount);
            } else {
                let deletedCount = 0;
                if (data.sessions && data.sessions[sessionId]) deletedCount = data.sessions[sessionId].length;
                await dbDeleteSession(char.id, sessionId);
                if (deletedCount > 0) addDeletedStats(char.id, sessionId, deletedCount);
            }

            await loadChats();

            if (getActiveChatChar() && getActiveChatChar().id === char.id) {
                const currentData = await db.get(`gz_chat_${char.id}`);
                if (!currentData || !currentData.sessions || Object.keys(currentData.sessions).length === 0) {
                    updateAppColors(true);
                    const cleanupScroll = getCleanupScroll();
                    if (cleanupScroll) {
                        cleanupScroll();
                        setCleanupScroll(null);
                    }
                    publishAppEvent(APP_EVENTS.ui.header.reset);
                    setActiveChatChar(null);
                    activeChar.value = null;
                    currentMessages.value = [];
                    inputValue.value = '';
                } else {
                    const charObj = { ...getActiveChatChar() };
                    delete charObj.sessionId;
                    openChat(charObj, null, true);
                }
            }

            getChatGenerationServices().app.notifyChatUpdated();
        }
    }

    async function openSessionsSheet(char) {
        const data = await getChatData(char.id);
        if (!data) return;
        const sessions = data.sessions || {};

        const ids = Object.keys(sessions).map(Number).sort((a, b) => {
            const lastA = sessions[a][sessions[a].length - 1]?.timestamp || data.sessionDates?.[a] || 0;
            const lastB = sessions[b][sessions[b].length - 1]?.timestamp || data.sessionDates?.[b] || 0;
            return lastB - lastA;
        });

        const currentSessionId = data.currentId;

        const cardItems = ids.map(sid => {
            const msgs = sessions[sid] || [];
            const lastMsg = msgs[msgs.length - 1];
            const preview = lastMsg ? (lastMsg.text.length > 40 ? lastMsg.text.substring(0, 40) + '...' : lastMsg.text) : 'Empty session';
            const dateFormatted = lastMsg ? formatDate(lastMsg.timestamp, 'short') : '';
            const isCurrent = sid === currentSessionId;

            return {
                label: `Session #${sid}`,
                sublabel: preview,
                badge: `${msgs.length} msgs${dateFormatted ? ' · ' + dateFormatted : ''}`,
                isActive: isCurrent,
                onClick: async () => {
                    if (sid !== currentSessionId) {
                        await asyncSaveCurrentSessionState();
                        await dbSwitchSession(char.id, sid);
                        await loadChats();
                        openChat({ ...char, sessionId: sid }, null, true);
                    }
                    closeBottomSheet();
                },
                actions: [
                    {
                        icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                        color: '#ff4444',
                        onClick: () => {
                            openDeleteSessionConfirm(char, sid, true);
                        }
                    }
                ]
            };
        });

        showBottomSheet({
            title: t('history_title') + ' ',
            helpTip: 'sessions',
            cardItems: cardItems,
            isSolid: true,
            headerAction: {
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => {
                        showBottomSheet({
                            title: t('history_title') + ' ',
                            helpTip: 'sessions',
                            items: [
                                {
                                    label: t('action_create_new') || 'Create New',
                                    icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                    onClick: () => {
                                        closeBottomSheet();
                                        createNewSession(char);
                                    }
                                },
                                {
                                    label: t('action_import') || 'Import from file',
                                    icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                    onClick: () => {
                                        closeBottomSheet();
                                        triggerChatImport(char.id, null, async (result) => {
                                            await loadChats();
                                            if (result?.sessionId) {
                                                await db.patchChatData(char.id, (importedData) => {
                                                    if (importedData?.sessions?.[result.sessionId]) {
                                                        const mb = ensureSessionMemoryBook(importedData, result.sessionId);
                                                        const auto = ensureMemoryAutomationState(mb);
                                                        const stableCount = getStableVisibleMessages(importedData.sessions[result.sessionId])
                                                            .filter(m => m.role === 'user' || m.role === 'char').length;
                                                        auto.lastProcessedMessageCount = stableCount;
                                                        auto.pendingTrigger = null;
                                                        mb.updatedAt = Date.now();
                                                    }
                                                });
                                            }
                                            const charObj = { ...char, sessionId: result?.sessionId || char.sessionId };
                                            openChat(charObj, null, true);
                                        });
                                    }
                                }
                            ]
                        });
                    }, 300);
                }
            }
        });
    }

    function openDeleteSessionConfirm(char, sessionId, returnToSessions = false) {
        showBottomSheet({
            title: t('confirm_delete_session'),
            items: [
                {
                    label: t('btn_yes'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: async () => {
                        await deleteSession(sessionId, char);
                        closeBottomSheet();
                        if (returnToSessions) {
                            const currentData = await db.get(`gz_chat_${char.id}`);
                            if (currentData && currentData.sessions && Object.keys(currentData.sessions).length > 0) {
                                setTimeout(() => openSessionsSheet(char), 300);
                            }
                        }
                    }
                },
                {
                    label: t('btn_no'),
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        if (returnToSessions) setTimeout(() => openSessionsSheet(char), 300);
                    }
                }
            ]
        });
    }

    async function createNewSession(char) {
        await asyncSaveCurrentSessionState();
        await dbCreateSession(char.id);
        await loadChats();

        const charObj = { ...char };
        delete charObj.sessionId;
        openChat(charObj, null, true);
    }

    return {
        deleteSession,
        openSessionsSheet,
        openDeleteSessionConfirm,
        createNewSession
    };
}
