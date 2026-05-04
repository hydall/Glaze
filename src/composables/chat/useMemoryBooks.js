import { ref } from 'vue';
import { saveMemorySettings } from '@/core/services/memorySchema.js';
import {
    ensureSessionMemoryBook,
    normalizeAutoCreateInterval,
    normalizeEntryMessageIds,
    reconcileSessionMemoryState
} from '@/core/services/memoryBooksService.js';
import { useMemoryDraftProgress } from '@/composables/chat/useMemoryDraftProgress.js';
import { useMemoryIndexing } from '@/composables/chat/useMemoryIndexing.js';
import { useMemoryCRUD } from '@/composables/chat/useMemoryCRUD.js';

export function useMemoryBooks(deps) {
    const {
        getChatData,
        showToast,
        showBottomSheet,
        closeBottomSheet,
        formatError,
        db
    } = deps;

    const currentMemoryBookData = ref(null);
    const pendingMemoryMessageIds = ref(new Set());
    const draftMemoryMessageIds = ref(new Set());

    const {
        memoryDraftState,
        setMemoryDraftAbortController,
        getMemoryDraftAbortController,
        startMemoryDraftProgress,
        stopMemoryDraftProgress,
        cancelMemoryDraft
    } = useMemoryDraftProgress({ showToast });

    async function loadCurrentMemoryBook(activeChatChar) {
        if (!activeChatChar) return;
        try {
            const chatData = await getChatData(activeChatChar.id);
            const sessionId = activeChatChar.sessionId || chatData.currentId;
            const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
            currentMemoryBookData.value = memoryBook;
        } catch (e) {
            console.error('[memory] Failed to load memory book:', e);
            currentMemoryBookData.value = null;
        }
    }

    async function updatePendingMemoryMessageIds(activeChatChar) {
        if (!activeChatChar) return;
        try {
            const chatData = await getChatData(activeChatChar.id);
            const sessionId = activeChatChar.sessionId || chatData.currentId;
            const memoryBook = ensureSessionMemoryBook(chatData, sessionId);

            const pendingIds = new Set();
            const draftIds = new Set();

            if (Array.isArray(memoryBook.entries)) {
                for (const entry of memoryBook.entries) {
                    if (entry.status === 'pending_generation') {
                        normalizeEntryMessageIds(entry).forEach(id => pendingIds.add(id));
                    }
                }
            }
            if (Array.isArray(memoryBook.pendingDrafts)) {
                for (const draft of memoryBook.pendingDrafts) {
                    normalizeEntryMessageIds(draft).forEach(id => draftIds.add(id));
                }
            }

            pendingMemoryMessageIds.value = pendingIds;
            draftMemoryMessageIds.value = draftIds;
        } catch (e) {
            console.error('[memory] Failed to update pending message IDs:', e);
        }
    }

    const sharedDeps = {
        getChatData,
        showToast,
        showBottomSheet,
        closeBottomSheet,
        formatError,
        db,
        currentMemoryBookData,
        loadCurrentMemoryBook,
        updatePendingMemoryMessageIds
    };

    const {
        handleMemorySearchTypeUpdate,
        handleMemoryVectorToggle,
        handleMemoryReindexAll
    } = useMemoryIndexing(sharedDeps);

    const {
        handleMemoryApproveDraft,
        handleMemoryDeleteDraft,
        handleMemoryDeleteAllDrafts,
        handleMemoryDeleteEntry,
        handleMemoryCancelDraft,
        handleMemoryOpenMaintenance
    } = useMemoryCRUD({
        ...sharedDeps,
        cancelMemoryDraft,
        memoryDraftState
    });

    async function handleMemoryScanChat(activeChatChar, currentMessages, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);

        const entries = Array.isArray(memoryBook.entries) ? memoryBook.entries : [];
        const pendingDrafts = Array.isArray(memoryBook.pendingDrafts) ? memoryBook.pendingDrafts : [];

        const coveredIds = new Set();
        for (const entry of entries) {
            if (Array.isArray(entry.messageIds)) entry.messageIds.forEach(id => coveredIds.add(id));
        }
        for (const draft of pendingDrafts) {
            if (Array.isArray(draft.messageIds)) draft.messageIds.forEach(id => coveredIds.add(id));
        }

        const allMessages = currentMessages.filter(m => m && !m.isTyping && !m.isError && (m.role === 'user' || m.role === 'char'));
        const uncovered = allMessages.filter(m => m.id && !coveredIds.has(m.id));

        if (!uncovered.length) {
            showToast('All messages are already covered');
            return;
        }

        const interval = normalizeAutoCreateInterval(memoryBook);
        const segments = [];
        for (let i = 0; i + interval <= uncovered.length; i += interval) {
            segments.push(uncovered.slice(i, i + interval));
        }

        if (!segments.length) {
            showToast(`Need ${interval} uncovered messages before creating a draft segment`);
            return;
        }

        if (!Array.isArray(memoryBook.pendingDrafts)) memoryBook.pendingDrafts = [];

        for (let i = 0; i < segments.length; i++) {
            const segment = segments[i];
            const segmentIds = segment.map(m => m.id);
            const firstMsg = segment[0];
            const lastMsg = segment[segment.length - 1];

            const firstIdx = allMessages.findIndex(m => m.id === firstMsg.id);
            const lastIdx = allMessages.findIndex(m => m.id === lastMsg.id);
            const rangeDisplay = firstIdx >= 0 && lastIdx >= 0 ? `${firstIdx + 1}-${lastIdx + 1}` : `${i * interval + 1}-${Math.min((i + 1) * interval, uncovered.length)}`;

            const existingDraft = memoryBook.pendingDrafts.find(d =>
                d.messageIds && JSON.stringify(d.messageIds.sort()) === JSON.stringify(segmentIds.sort())
            );
            if (existingDraft) continue;

            memoryBook.pendingDrafts.push({
                id: `draft_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`,
                title: rangeDisplay,
                content: '',
                keys: [],
                glazeKeys: [],
                vectorSearch: false,
                messageIds: segmentIds,
                messageRange: {
                    start: firstIdx >= 0 ? firstIdx + 1 : i * interval + 1,
                    end: lastIdx >= 0 ? lastIdx + 1 : Math.min((i + 1) * interval, uncovered.length)
                },
                status: 'pending_generation',
                source: 'scan_chat',
                createdAt: Date.now(),
                updatedAt: Date.now(),
                generatedAt: null
            });
        }

        await db.patchChatData(activeChatChar.id, (data) => {
            const sid = activeChatChar.sessionId || data.currentId;
            const mb = ensureSessionMemoryBook(data, sid);
            if (!Array.isArray(mb.pendingDrafts)) mb.pendingDrafts = [];

            for (let i = 0; i < segments.length; i++) {
                const segment = segments[i];
                const segmentIds = segment.map(m => m.id);
                const firstMsg = segment[0];
                const lastMsg = segment[segment.length - 1];

                const firstIdx = allMessages.findIndex(m => m.id === firstMsg.id);
                const lastIdx = allMessages.findIndex(m => m.id === lastMsg.id);
                const rangeDisplay = firstIdx >= 0 && lastIdx >= 0 ? `${firstIdx + 1}-${lastIdx + 1}` : `${i * interval + 1}-${Math.min((i + 1) * interval, uncovered.length)}`;

                const existingDraft = mb.pendingDrafts.find(d =>
                    d.messageIds && JSON.stringify(d.messageIds.sort()) === JSON.stringify(segmentIds.sort())
                );
                if (existingDraft) continue;

                mb.pendingDrafts.push({
                    id: `draft_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`,
                    title: rangeDisplay,
                    content: '',
                    keys: [],
                    glazeKeys: [],
                    vectorSearch: false,
                    messageIds: segmentIds,
                    messageRange: {
                        start: firstIdx >= 0 ? firstIdx + 1 : i * interval + 1,
                        end: lastIdx >= 0 ? lastIdx + 1 : Math.min((i + 1) * interval, uncovered.length)
                    },
                    status: 'pending_generation',
                    source: 'scan_chat',
                    createdAt: Date.now(),
                    updatedAt: Date.now(),
                    generatedAt: null
                });
            }

            if (!mb.automation) mb.automation = {};
            mb.automation.plannedSegments = [];
            mb.updatedAt = Date.now();
        });

        showToast(`${segments.length} draft placeholders created (${uncovered.length} messages)`);
        await updatePendingMemoryMessageIds(activeChatChar);
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    return {
        currentMemoryBookData,
        pendingMemoryMessageIds,
        draftMemoryMessageIds,
        memoryDraftState,

        loadCurrentMemoryBook,
        updatePendingMemoryMessageIds,

        startMemoryDraftProgress,
        stopMemoryDraftProgress,
        cancelMemoryDraft,
        setMemoryDraftAbortController,
        getMemoryDraftAbortController,

        handleMemorySearchTypeUpdate,
        handleMemoryVectorToggle,
        handleMemoryReindexAll,
        handleMemoryScanChat,
        handleMemoryApproveDraft,
        handleMemoryDeleteDraft,
        handleMemoryDeleteAllDrafts,
        handleMemoryDeleteEntry,
        handleMemoryCancelDraft,
        handleMemoryOpenMaintenance
    };
}
