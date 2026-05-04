import {
    ensureSessionMemoryBook,
    normalizeEntryMessageIds,
    findConflictingMemoryEntry,
    normalizeMemoryEntryShape,
    reconcileSessionMemoryState,
    getMemoryVectorSearchEnabled,
    deleteMemoryEntryIndexIfPresent,
    indexMemoryEntryIfNeeded,
    runMemoryMaintenancePass
} from '@/core/services/memoryBooksService.js';

export function useMemoryCRUD({
    getChatData,
    showToast,
    showBottomSheet,
    closeBottomSheet,
    formatError,
    db,
    currentMemoryBookData,
    loadCurrentMemoryBook,
    updatePendingMemoryMessageIds,
    cancelMemoryDraft,
    memoryDraftState
}) {
    async function handleMemoryApproveDraft(draftId, activeChatChar, currentMessages, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const vectorEnabled = getMemoryVectorSearchEnabled(memoryBook);

        const draft = memoryBook.pendingDrafts.find(entry => entry.id === draftId);
        if (!draft) return;

        const draftIds = normalizeEntryMessageIds(draft);
        const conflictingApproved = findConflictingMemoryEntry(memoryBook, draftIds, {
            includeEntries: true,
            includeDrafts: false,
            overlapThreshold: 0.8
        });

        if (conflictingApproved) {
            showToast(conflictingApproved.reason === 'exact'
                ? 'An approved memory entry already exists for this segment'
                : 'An approved memory entry already overlaps most of this draft');
            return;
        }

        const approvedEntry = normalizeMemoryEntryShape({ ...draft, status: 'active', vectorSearch: vectorEnabled });
        memoryBook.entries.push(approvedEntry);
        memoryBook.pendingDrafts = memoryBook.pendingDrafts.filter(entry => entry.id !== draftId);
        memoryBook.updatedAt = Date.now();

        if (Array.isArray(approvedEntry.messageIds)) {
            for (const msg of currentMessages) {
                if (!msg || !msg.id) continue;
                if (approvedEntry.messageIds.includes(msg.id)) {
                    if (!msg.memoryCoverage || typeof msg.memoryCoverage !== 'object') {
                        msg.memoryCoverage = { entryIds: [], needsRebuild: false, stale: false };
                    }
                    if (!Array.isArray(msg.memoryCoverage.entryIds)) {
                        msg.memoryCoverage.entryIds = [];
                    }
                    if (!msg.memoryCoverage.entryIds.includes(approvedEntry.id)) {
                        msg.memoryCoverage.entryIds.push(approvedEntry.id);
                    }
                }
            }
        }

        reconcileSessionMemoryState(chatData, sessionId, currentMessages);
        chatData.sessions[sessionId] = currentMessages;
        await db.patchChatData(activeChatChar.id, (data) => {
            const sid = activeChatChar.sessionId || data.currentId;
            const mb = data.memoryBooks?.[sid];
            if (!mb) return;
            mb.entries.push(approvedEntry);
            mb.pendingDrafts = mb.pendingDrafts.filter(entry => entry.id !== draftId);
            mb.updatedAt = Date.now();
            reconcileSessionMemoryState(data, sid, currentMessages);
            data.sessions[sid] = currentMessages;
        });
        try {
            await indexMemoryEntryIfNeeded(approvedEntry, activeChatChar.id, sessionId);
        } catch (e) {
            console.warn('[memory] Embedding index failed for approved draft:', e?.message || e);
            if (approvedEntry.vectorSearch) {
                approvedEntry.vectorSearch = false;
                await db.patchChatData(activeChatChar.id, (data) => {
                    const mb = data.memoryBooks?.[sessionId];
                    const entry = mb?.entries?.find(en => en.id === approvedEntry.id);
                    if (entry) entry.vectorSearch = false;
                });
            }
        }

        await updatePendingMemoryMessageIds(activeChatChar);
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    async function handleMemoryDeleteDraft(draftId, activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        if (memoryDraftState.value?.activeDrafts?.[draftId]) {
            cancelMemoryDraft(draftId);
        }

        await db.patchChatData(activeChatChar.id, (data) => {
            const sessionId = activeChatChar.sessionId || data.currentId;
            const mb = data.memoryBooks?.[sessionId];
            if (!mb) return;
            mb.pendingDrafts = mb.pendingDrafts.filter(entry => entry.id !== draftId);
            mb.updatedAt = Date.now();
        });

        await updatePendingMemoryMessageIds(activeChatChar);
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    async function handleMemoryDeleteAllDrafts(activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        cancelMemoryDraft();
        await db.patchChatData(activeChatChar.id, (data) => {
            const sessionId = activeChatChar.sessionId || data.currentId;
            const mb = data.memoryBooks?.[sessionId];
            if (!mb) return;
            mb.pendingDrafts = [];
            mb.updatedAt = Date.now();
        });

        await updatePendingMemoryMessageIds(activeChatChar);
        await loadCurrentMemoryBook(activeChatChar);
        showToast('All pending drafts deleted');
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    async function handleMemoryDeleteEntry(entryId, activeChatChar, currentMessages, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        await deleteMemoryEntryIndexIfPresent(entryId);

        await db.patchChatData(activeChatChar.id, (data) => {
            const sessionId = activeChatChar.sessionId || data.currentId;
            const mb = data.memoryBooks?.[sessionId];
            if (!mb) return;
            mb.entries = mb.entries.filter(entry => entry.id !== entryId);
            mb.updatedAt = Date.now();
            reconcileSessionMemoryState(data, sessionId, currentMessages);
            data.sessions[sessionId] = currentMessages;
        });

        await updatePendingMemoryMessageIds(activeChatChar);
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    function handleMemoryCancelDraft(draftId = null) {
        cancelMemoryDraft(draftId);
    }

    function handleMemoryOpenMaintenance(activeChatChar, memoryBooksSheet) {
        showBottomSheet({
            title: 'Memory Maintenance',
            items: [
                {
                    label: 'Cleanup coverage and drafts',
                    onClick: async () => {
                        if (!activeChatChar) return;
                        const chatData = await getChatData(activeChatChar.id);
                        const sessionId = activeChatChar.sessionId || chatData.currentId;
                        try {
                            const result = await runMemoryMaintenancePass(chatData, sessionId, { reindex: false });
                            closeBottomSheet();
                            showToast(`Maintenance complete: ${result.removedEntries} entries removed, ${result.clearedDrafts} drafts cleared, ${result.rebuildEntries} entries need rebuild`);
                            await loadCurrentMemoryBook(activeChatChar);
                            setTimeout(() => memoryBooksSheet.value?.open(), 50);
                        } catch (error) {
                            console.error('Memory maintenance failed:', error);
                            showToast(`Maintenance failed: ${formatError(error)}`);
                        }
                    }
                },
                {
                    label: 'Cleanup and reindex',
                    onClick: async () => {
                        if (!activeChatChar) return;
                        const chatData = await getChatData(activeChatChar.id);
                        const sessionId = activeChatChar.sessionId || chatData.currentId;
                        try {
                            const result = await runMemoryMaintenancePass(chatData, sessionId, { reindex: true });
                            closeBottomSheet();
                            showToast(`Maintenance + reindex complete: ${result.removedEntries} entries removed, ${result.clearedDrafts} drafts cleared`);
                            await loadCurrentMemoryBook(activeChatChar);
                            setTimeout(() => memoryBooksSheet.value?.open(), 50);
                        } catch (error) {
                            console.error('Memory maintenance reindex failed:', error);
                            showToast(`Maintenance failed: ${formatError(error)}`);
                        }
                    }
                },
                {
                    label: 'Back to Memory Books',
                    onClick: async () => {
                        closeBottomSheet();
                        await loadCurrentMemoryBook(activeChatChar);
                        setTimeout(() => memoryBooksSheet.value?.open(), 50);
                    }
                }
            ]
        });
    }

    return {
        handleMemoryApproveDraft,
        handleMemoryDeleteDraft,
        handleMemoryDeleteAllDrafts,
        handleMemoryDeleteEntry,
        handleMemoryCancelDraft,
        handleMemoryOpenMaintenance
    };
}
