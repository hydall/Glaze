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
        activeCount: 0,
        label: '',
        draftId: null,
        activeDrafts: {}
    });

    let memoryDraftTimer = null;
    const memoryDraftAbortControllers = new Map();
    const memoryDraftProgressEntries = new Map();

    function syncMemoryDraftState() {
        const activeDrafts = {};
        let firstDraftId = null;

        for (const [draftId, entry] of memoryDraftProgressEntries.entries()) {
            activeDrafts[draftId] = {
                draftId,
                startedAt: entry.startedAt,
                elapsedMs: entry.elapsedMs,
                label: entry.label
            };
            if (!firstDraftId) firstDraftId = draftId;
        }

        const activeCount = memoryDraftProgressEntries.size;
        const primaryEntry = firstDraftId ? activeDrafts[firstDraftId] : null;
        memoryDraftState.value = {
            active: activeCount > 0,
            activeCount,
            label: activeCount > 1 ? `${activeCount} drafts` : (primaryEntry?.label || ''),
            draftId: activeCount === 1 ? firstDraftId : null,
            activeDrafts
        };

        if (!activeCount && memoryDraftTimer) {
            clearInterval(memoryDraftTimer);
            memoryDraftTimer = null;
        }
    }

    function ensureMemoryDraftTimer() {
        if (memoryDraftTimer || !memoryDraftProgressEntries.size) return;
        memoryDraftTimer = setInterval(() => {
            const now = Date.now();
            for (const entry of memoryDraftProgressEntries.values()) {
                entry.elapsedMs = now - entry.startedAt;
            }
            syncMemoryDraftState();
        }, 100);
    }

    function setMemoryDraftAbortController(controller, draftId = null) {
        const key = draftId || '__global__';
        if (controller) {
            memoryDraftAbortControllers.set(key, controller);
        } else {
            memoryDraftAbortControllers.delete(key);
        }
    }

    function getMemoryDraftAbortController(draftId = null) {
        const key = draftId || '__global__';
        return memoryDraftAbortControllers.get(key) || null;
    }

    // ========================================================================
    // DRAFT PROGRESS TRACKING
    // ========================================================================

    function stopMemoryDraftProgress(draftId = null) {
        if (draftId) {
            memoryDraftProgressEntries.delete(draftId);
            memoryDraftAbortControllers.delete(draftId);
        } else {
            memoryDraftProgressEntries.clear();
            memoryDraftAbortControllers.clear();
        }
        syncMemoryDraftState();
    }

    function cancelMemoryDraft(draftId = null) {
        if (draftId) {
            memoryDraftAbortControllers.get(draftId)?.abort();
            stopMemoryDraftProgress(draftId);
        } else {
            for (const controller of memoryDraftAbortControllers.values()) {
                controller?.abort?.();
            }
            stopMemoryDraftProgress();
        }
        showToast('Memory draft generation cancelled');
    }

    function startMemoryDraftProgress(label = 'Generating memory draft', draftId = null) {
        const progressId = draftId || `memory_draft_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
        const startedAt = Date.now();
        memoryDraftProgressEntries.set(progressId, {
            startedAt,
            elapsedMs: 0,
            label
        });
        ensureMemoryDraftTimer();
        syncMemoryDraftState();
        return progressId;
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
            stopMemoryDraftProgress();
            return;
        }
        const chatData = await getChatData(activeChatChar.id);
        if (!chatData) {
            currentMemoryBookData.value = null;
            stopMemoryDraftProgress();
            return;
        }
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        let shouldPersistReset = false;
        if (memoryBook.automation?.isGeneratingDraft && !memoryDraftState.value.active) {
            memoryBook.automation.isGeneratingDraft = false;
            shouldPersistReset = true;
        }
        if (shouldPersistReset) {
            memoryBook.automation.isGeneratingDraft = false;
            memoryBook.updatedAt = Date.now();
            await db.patchChatData(activeChatChar.id, (data) => {
                const sid = activeChatChar.sessionId || data.currentId;
                const mb = data.memoryBooks?.[sid];
                if (mb?.automation) mb.automation.isGeneratingDraft = false;
                if (mb) mb.updatedAt = Date.now();
            });
        }
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
            await db.patchChatData(activeChatChar.id, (data) => {
                const sid = activeChatChar.sessionId || data.currentId;
                const mb = data.memoryBooks?.[sid];
                if (mb) {
                    mb.settings.vectorSearchEnabled = enabled;
                    setMemoryVectorSearchOnEntries(mb, enabled);
                    mb.updatedAt = Date.now();
                }
            });
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

    /**
     * Handle memory scan chat - creates draft placeholders without auto-generating
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

        // Scan ALL messages including hidden for memory book purposes
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

        // Create pending draft entries with empty content so scan/automation share the same placeholder-first model.
        if (!Array.isArray(memoryBook.pendingDrafts)) memoryBook.pendingDrafts = [];

        for (let i = 0; i < segments.length; i++) {
            const segment = segments[i];
            const segmentIds = segment.map(m => m.id);
            const firstMsg = segment[0];
            const lastMsg = segment[segment.length - 1];

            // Find message indices for display
            const firstIdx = allMessages.findIndex(m => m.id === firstMsg.id);
            const lastIdx = allMessages.findIndex(m => m.id === lastMsg.id);
            const rangeDisplay = firstIdx >= 0 && lastIdx >= 0 ? `${firstIdx + 1}-${lastIdx + 1}` : `${i * interval + 1}-${Math.min((i + 1) * interval, uncovered.length)}`;

            // Check if draft already exists for these messages
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

        // Update memoryCoverage on messages covered by this entry
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

    /**
     * Handle memory delete draft
     * @param {string} draftId - Draft ID to delete
     * @param {Object} activeChatChar - Active character object
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
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

    /**
     * Handle memory delete entry
     * @param {string} entryId - Entry ID to delete
     * @param {Object} activeChatChar - Active character object
     * @param {Array} currentMessages - Current messages array
     * @param {Object} memoryBooksSheet - Memory books sheet ref
     */
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

    /**
     * Handle memory cancel draft
     */
    function handleMemoryCancelDraft(draftId = null) {
        cancelMemoryDraft(draftId);
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
        setMemoryDraftAbortController,
        getMemoryDraftAbortController,
        
        // UI handlers
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
