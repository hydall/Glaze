import { saveMemorySettings } from '@/core/services/memorySchema.js';
import {
    ensureSessionMemoryBook,
    setMemoryVectorSearchOnEntries,
    reindexAllMemoryEntries,
    deleteMemoryEntryIndexIfPresent
} from '@/core/services/memoryBooksService.js';

export function useMemoryIndexing({
    getChatData,
    showToast,
    showBottomSheet,
    closeBottomSheet,
    formatError,
    db,
    currentMemoryBookData,
    loadCurrentMemoryBook
}) {
    async function handleMemorySearchTypeUpdate(activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);

        showBottomSheet({
            title: 'Memory Search Type',
            items: [
                {
                    label: 'Keys',
                    onClick: async () => {
                        const newSettings = { vectorSearchEnabled: false, keyMatchMode: 'glaze' };
                        saveMemorySettings(newSettings);
                        await db.patchChatData(activeChatChar.id, (data) => {
                            const sid = activeChatChar.sessionId || data.currentId;
                            const mb = data.memoryBooks?.[sid];
                            if (mb) {
                                mb.settings.vectorSearchEnabled = false;
                                mb.settings.keyMatchMode = 'glaze';
                                mb.updatedAt = Date.now();
                            }
                        });
                        closeBottomSheet();
                        await loadCurrentMemoryBook(activeChatChar);
                        setTimeout(() => memoryBooksSheet.value?.open(), 50);
                    }
                },
                {
                    label: 'Vector',
                    onClick: async () => {
                        setMemoryVectorSearchOnEntries(memoryBook, true);
                        showToast('Reindexing memory entries...', 1500);
                        await reindexAllMemoryEntries(memoryBook, activeChatChar.id, sessionId);
                        const newSettings = { vectorSearchEnabled: true, keyMatchMode: 'plain' };
                        saveMemorySettings(newSettings);
                        await db.patchChatData(activeChatChar.id, (data) => {
                            const sid = activeChatChar.sessionId || data.currentId;
                            const mb = data.memoryBooks?.[sid];
                            if (mb) {
                                mb.settings.vectorSearchEnabled = true;
                                mb.settings.keyMatchMode = 'plain';
                                setMemoryVectorSearchOnEntries(mb, true);
                                mb.updatedAt = Date.now();
                            }
                        });
                        closeBottomSheet();
                        await loadCurrentMemoryBook(activeChatChar);
                        setTimeout(() => memoryBooksSheet.value?.open(), 50);
                    }
                },
                {
                    label: 'Combined',
                    onClick: async () => {
                        setMemoryVectorSearchOnEntries(memoryBook, true);
                        showToast('Reindexing memory entries...', 1500);
                        await reindexAllMemoryEntries(memoryBook, activeChatChar.id, sessionId);
                        const newSettings = { vectorSearchEnabled: true, keyMatchMode: 'both' };
                        saveMemorySettings(newSettings);
                        await db.patchChatData(activeChatChar.id, (data) => {
                            const sid = activeChatChar.sessionId || data.currentId;
                            const mb = data.memoryBooks?.[sid];
                            if (mb) {
                                mb.settings.vectorSearchEnabled = true;
                                mb.settings.keyMatchMode = 'both';
                                setMemoryVectorSearchOnEntries(mb, true);
                                mb.updatedAt = Date.now();
                            }
                        });
                        closeBottomSheet();
                        await loadCurrentMemoryBook(activeChatChar);
                        setTimeout(() => memoryBooksSheet.value?.open(), 50);
                    }
                }
            ]
        });
    }

    async function handleMemoryVectorToggle(enabled, activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);

        memoryBook.settings.vectorSearchEnabled = enabled;
        setMemoryVectorSearchOnEntries(memoryBook, enabled);
        memoryBook.updatedAt = Date.now();

        try {
            if (enabled) {
                showToast('Reindexing memory entries...', 1500);
                await reindexAllMemoryEntries(memoryBook, activeChatChar.id, sessionId);
                showToast('Memory vector search enabled');
            } else {
                const approvedEntries = Array.isArray(memoryBook.entries) ? memoryBook.entries : [];
                for (const entry of approvedEntries) {
                    await deleteMemoryEntryIndexIfPresent(entry.id);
                }
                showToast('Memory vector search disabled');
            }
            await db.patchChatData(activeChatChar.id, (data) => {
                const sid = activeChatChar.sessionId || data.currentId;
                const mb = data.memoryBooks?.[sid];
                if (mb) {
                    mb.settings.vectorSearchEnabled = enabled;
                    setMemoryVectorSearchOnEntries(mb, enabled);
                    mb.updatedAt = Date.now();
                }
            });
            saveMemorySettings({ vectorSearchEnabled: enabled });
            await loadCurrentMemoryBook(activeChatChar);
            setTimeout(() => memoryBooksSheet.value?.open(), 50);
        } catch (error) {
            console.error('Failed to toggle memory vector search:', error);
            showToast(`Vector toggle failed: ${formatError(error)}`);
        }
    }

    async function handleMemoryReindexAll(activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);

        try {
            showToast('Reindexing memory entries...', 1500);
            const result = await reindexAllMemoryEntries(memoryBook, activeChatChar.id, sessionId);
            if (result?.rateLimited) {
                showToast(`Rate limited — retry in ${result.retryAfter || 60}s`, (result.retryAfter || 60) * 1000);
                return result;
            }
            memoryBook.updatedAt = Date.now();
            await db.patchChatData(activeChatChar.id, (data) => {
                const sid = activeChatChar.sessionId || data.currentId;
                const mb = data.memoryBooks?.[sid];
                if (mb) mb.updatedAt = Date.now();
            });
            showToast('Memory entries reindexed');
            await loadCurrentMemoryBook(activeChatChar);
            setTimeout(() => memoryBooksSheet.value?.open(), 50);
            return result;
        } catch (error) {
            console.error('Failed to reindex memory entries:', error);
            showToast(`Reindex failed: ${formatError(error)}`);
        }
    }

    return {
        handleMemorySearchTypeUpdate,
        handleMemoryVectorToggle,
        handleMemoryReindexAll
    };
}
