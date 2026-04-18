/**
 * Memory Books Composable
 * 
 * Reactive state and UI interaction logic for Memory Books feature.
 * This composable manages:
 * - Reactive state (currentMemoryBookData, pendingMemoryMessageIds, etc.)
 * - Draft generation progress tracking
 * - UI event handlers for Memory Books Sheet
 * 
 * Depends on memoryBooksService for business logic.
 */

import { ref } from 'vue';
import {
    ensureSessionMemoryBook,
    normalizeAutoCreateInterval,
    normalizeEntryMessageIds,
    findConflictingMemoryEntry,
    normalizeMemoryEntryShape,
    reconcileSessionMemoryState,
    getMemoryVectorSearchEnabled,
    setMemoryVectorSearchOnEntries,
    reindexAllMemoryEntries,
    deleteMemoryEntryIndexIfPresent,
    indexMemoryEntryIfNeeded,
    runMemoryMaintenancePass
} from '@/core/services/memoryBooksService.js';

/**
 * Create Memory Books composable
 * @param {Object} deps - Dependencies
 * @param {Function} deps.getChatData - Function to get chat data by charId
 * @param {Function} deps.showToast - Function to show toast notification
 * @param {Function} deps.showBottomSheet - Function to show bottom sheet
 * @param {Function} deps.closeBottomSheet - Function to close bottom sheet
 * @param {Function} deps.formatError - Function to format error message
 * @param {Object} deps.db - Database instance
 * @returns {Object} Memory Books state and handlers
 */
export function useMemoryBooks(deps) {
    const {
        getChatData,
        showToast,
        showBottomSheet,
        closeBottomSheet,
        formatError,
        db
    } = deps;

    // ========================================================================
    // REACTIVE STATE
    // ========================================================================

    const currentMemoryBookData = ref(null);
    const pendingMemoryMessageIds = ref(new Set());
    const draftMemoryMessageIds = ref(new Set());
    const memoryDraftState = ref({
        active: false,
        startedAt: 0,
        elapsedMs: 0,
        label: ''
    });

    let memoryDraftTimer = null;
    let memoryDraftAbortController = null;

    // ========================================================================
    // DRAFT PROGRESS TRACKING
    // ========================================================================

    function stopMemoryDraftProgress() {
        if (memoryDraftTimer) {
            clearInterval(memoryDraftTimer);
            memoryDraftTimer = null;
        }
        memoryDraftAbortController = null;
        memoryDraftState.value = {
            active: false,
            startedAt: 0,
            elapsedMs: 0,
            label: ''
        };
    }

    function cancelMemoryDraft() {
        if (memoryDraftAbortController) {
            memoryDraftAbortController.abort();
        }
        stopMemoryDraftProgress();
        showToast('Memory draft generation cancelled');
    }

    function startMemoryDraftProgress(label = 'Generating memory draft') {
        if (memoryDraftTimer) clearInterval(memoryDraftTimer);
        const startedAt = Date.now();
        memoryDraftState.value = {
            active: true,
            startedAt,
            elapsedMs: 0,
            label
        };
        memoryDraftTimer = setInterval(() => {
            memoryDraftState.value = {
                ...memoryDraftState.value,
                active: true,
                elapsedMs: Date.now() - startedAt
            };
        }, 100);
    }

    // ========================================================================
    // DATA LOADING
    // ========================================================================

    /**
     * Load current session memory book into reactive state
     * @param {Object} activeChatChar - Active character object
     */
    async function loadCurrentMemoryBook(activeChatChar) {
        if (!activeChatChar) {
            currentMemoryBookData.value = null;
            return;
        }
        const chatData = await getChatData(activeChatChar.id);
        if (!chatData) {
            currentMemoryBookData.value = null;
            return;
        }
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        currentMemoryBookData.value = memoryBook;
    }

    /**
     * Update pending and draft memory message IDs
     * @param {Object} activeChatChar - Active character object
     */
    async function updatePendingMemoryMessageIds(activeChatChar) {
        if (!activeChatChar) {
            pendingMemoryMessageIds.value = new Set();
            draftMemoryMessageIds.value = new Set();
            return;
        }
        const chatData = await getChatData(activeChatChar.id);
        if (!chatData) {
            pendingMemoryMessageIds.value = new Set();
            draftMemoryMessageIds.value = new Set();
            return;
        }
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = chatData.memoryBooks?.[sessionId];
        
        // Pending trigger (automation queued but not yet generated)
        const pendingIds = memoryBook?.automation?.pendingTrigger?.messageIds || [];
        pendingMemoryMessageIds.value = new Set(pendingIds.filter(Boolean));
        
        // Draft coverage (drafts generated, awaiting approval)
        const drafts = Array.isArray(memoryBook?.pendingDrafts) ? memoryBook.pendingDrafts : [];
        const draftIds = new Set();
        for (const draft of drafts) {
            if (Array.isArray(draft.messageIds)) {
                for (const id of draft.messageIds) {
                    if (id) draftIds.add(id);
                }
            }
        }
        draftMemoryMessageIds.value = draftIds;
    }

    // ========================================================================
    // UI EVENT HANDLERS
    // ========================================================================

    /**
     * Handle memory key match mode update
     * @param {Object} activeChatChar - Active character object
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
    async function handleMemoryKeyModeUpdate(activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;
        
        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        
        showBottomSheet({
            title: 'Memory Key Match Mode',
            items: [
                {
                    label: 'Plain contains',
                    onClick: async () => {
                        memoryBook.settings.keyMatchMode = 'plain';
                        memoryBook.updatedAt = Date.now();
                        await db.saveChat(activeChatChar.id, chatData);
                        closeBottomSheet();
                        await loadCurrentMemoryBook(activeChatChar);
                        setTimeout(() => memoryBooksSheet.value?.open(), 50);
                    }
                },
                {
                    label: 'Glaze boundaries',
                    onClick: async () => {
                        memoryBook.settings.keyMatchMode = 'glaze';
                        memoryBook.updatedAt = Date.now();
                        await db.saveChat(activeChatChar.id, chatData);
                        closeBottomSheet();
                        await loadCurrentMemoryBook(activeChatChar);
                        setTimeout(() => memoryBooksSheet.value?.open(), 50);
                    }
                },
                {
                    label: 'Plain + Glaze',
                    onClick: async () => {
                        memoryBook.settings.keyMatchMode = 'both';
                        memoryBook.updatedAt = Date.now();
                        await db.saveChat(activeChatChar.id, chatData);
                        closeBottomSheet();
                        await loadCurrentMemoryBook(activeChatChar);
                        setTimeout(() => memoryBooksSheet.value?.open(), 50);
                    }
                }
            ]
        });
    }

    /**
     * Handle memory vector search toggle
     * @param {boolean} enabled - Enable or disable vector search
     * @param {Object} activeChatChar - Active character object
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
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
            await db.saveChat(activeChatChar.id, chatData);
            await loadCurrentMemoryBook(activeChatChar);
            setTimeout(() => memoryBooksSheet.value?.open(), 50);
        } catch (error) {
            console.error('Failed to toggle memory vector search:', error);
            showToast(`Vector toggle failed: ${formatError(error)}`);
        }
    }

    /**
     * Handle memory reindex all
     * @param {Object} activeChatChar - Active character object
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
    async function handleMemoryReindexAll(activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;
        
        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        
        try {
            showToast('Reindexing memory entries...', 1500);
            await reindexAllMemoryEntries(memoryBook, activeChatChar.id, sessionId);
            memoryBook.updatedAt = Date.now();
            await db.saveChat(activeChatChar.id, chatData);
            showToast('Memory entries reindexed');
            await loadCurrentMemoryBook(activeChatChar);
            setTimeout(() => memoryBooksSheet.value?.open(), 50);
        } catch (error) {
            console.error('Failed to reindex memory entries:', error);
            showToast(`Reindex failed: ${formatError(error)}`);
        }
    }

    /**
     * Handle memory scan chat
     * @param {Object} activeChatChar - Active character object
     * @param {Array} currentMessages - Current messages array
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
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
        
        const stableMessages = currentMessages.filter(m => m && !m.isTyping && !m.isHidden && !m.isError && (m.role === 'user' || m.role === 'char'));
        const uncovered = stableMessages.filter(m => m.id && !coveredIds.has(m.id));
        
        if (!uncovered.length) {
            showToast('All messages are already covered');
            return;
        }
        
        const interval = normalizeAutoCreateInterval(memoryBook);
        const segments = [];
        for (let i = 0; i < uncovered.length; i += interval) {
            segments.push(uncovered.slice(i, i + interval));
        }
        
        // Store planned segments
        if (!memoryBook.automation) memoryBook.automation = {};
        memoryBook.automation.plannedSegments = segments.map(seg => seg.map(m => m.id));
        memoryBook.updatedAt = Date.now();
        await db.saveChat(activeChatChar.id, chatData);
        
        // Mark all uncovered as pending
        const allUncoveredIds = new Set(uncovered.map(m => m.id));
        pendingMemoryMessageIds.value = allUncoveredIds;
        
        showToast(`Scanned: ${segments.length} segments planned (${uncovered.length} messages)`);
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }



    /**
     * Handle memory approve draft
     * @param {string} draftId - Draft ID to approve
     * @param {Object} activeChatChar - Active character object
     * @param {Array} currentMessages - Current messages array
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
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
        reconcileSessionMemoryState(chatData, sessionId, currentMessages);
        chatData.sessions[sessionId] = currentMessages;
        await db.saveChat(activeChatChar.id, chatData);
        await indexMemoryEntryIfNeeded(approvedEntry, activeChatChar.id, sessionId);
        
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    /**
     * Handle memory delete draft
     * @param {string} draftId - Draft ID to delete
     * @param {Object} activeChatChar - Active character object
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
    async function handleMemoryDeleteDraft(draftId, activeChatChar, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;
        
        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        
        memoryBook.pendingDrafts = memoryBook.pendingDrafts.filter(entry => entry.id !== draftId);
        memoryBook.updatedAt = Date.now();
        await db.saveChat(activeChatChar.id, chatData);
        
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    /**
     * Handle memory delete entry
     * @param {string} entryId - Entry ID to delete
     * @param {Object} activeChatChar - Active character object
     * @param {Array} currentMessages - Current messages array
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
    async function handleMemoryDeleteEntry(entryId, activeChatChar, currentMessages, memoryBooksSheet) {
        if (!activeChatChar || !currentMemoryBookData.value) return;
        
        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        
        await deleteMemoryEntryIndexIfPresent(entryId);
        memoryBook.entries = memoryBook.entries.filter(entry => entry.id !== entryId);
        memoryBook.updatedAt = Date.now();
        reconcileSessionMemoryState(chatData, sessionId, currentMessages);
        chatData.sessions[sessionId] = currentMessages;
        await db.saveChat(activeChatChar.id, chatData);
        
        await loadCurrentMemoryBook(activeChatChar);
        setTimeout(() => memoryBooksSheet.value?.open(), 50);
    }

    /**
     * Handle memory cancel draft
     */
    function handleMemoryCancelDraft() {
        cancelMemoryDraft();
    }

    /**
     * Handle memory open maintenance
     * @param {Object} activeChatChar - Active character object
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
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

    // ========================================================================
    // RETURN PUBLIC API
    // ========================================================================

    return {
        // Reactive state
        currentMemoryBookData,
        pendingMemoryMessageIds,
        draftMemoryMessageIds,
        memoryDraftState,
        
        // Data loading
        loadCurrentMemoryBook,
        updatePendingMemoryMessageIds,
        
        // Draft progress
        startMemoryDraftProgress,
        stopMemoryDraftProgress,
        cancelMemoryDraft,
        
        // UI handlers
        handleMemoryKeyModeUpdate,
        handleMemoryVectorToggle,
        handleMemoryReindexAll,
        handleMemoryScanChat,
        handleMemoryApproveDraft,
        handleMemoryDeleteDraft,
        handleMemoryDeleteEntry,
        handleMemoryCancelDraft,
        handleMemoryOpenMaintenance
    };
}
