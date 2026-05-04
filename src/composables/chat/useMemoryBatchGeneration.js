import { getChatData } from '@/utils/sessions.js';
import { showToast } from '@/core/states/toastState.js';
import { formatError } from '@/utils/errors.js';
import { ensureSessionMemoryBook } from '@/core/services/memoryBooksService.js';

export function useMemoryBatchGeneration({
    getActiveChatChar,
    currentMessages,
    memoryDraftState,
    currentMemoryBookData,
    loadCurrentMemoryBook,
    updatePendingMemoryMessageIds,
    openMemoryBooksSheet,
    generateMemoryDraftForMessages
}) {
    async function runBatchDraftGeneration(chatData, sessionId, memoryBook, segments, count) {
        const toGenerate = segments.slice(0, count);
        const results = await Promise.all(toGenerate.map(async (segmentIds) => {
            const messages = currentMessages.value.filter(m => m && segmentIds.includes(m.id));
            if (!messages.length) return false;

            const success = await generateMemoryDraftForMessages(messages, {
                openSheet: false,
                source: 'manual_draft'
            });

            if (success && memoryBook.automation?.plannedSegments) {
                memoryBook.automation.plannedSegments = memoryBook.automation.plannedSegments.filter(
                    seg => JSON.stringify(seg) !== JSON.stringify(segmentIds)
                );
            }

            return success;
        }));

        const generated = results.filter(Boolean).length;
        const failed = results.length - generated;

        await updatePendingMemoryMessageIds(getActiveChatChar());
        await loadCurrentMemoryBook(getActiveChatChar());

        const msg = failed > 0
            ? `Batch complete: ${generated} generated, ${failed} failed`
            : `Batch complete: ${generated} draft${generated > 1 ? 's' : ''} generated`;
        showToast(msg, 3000);

        setTimeout(() => openMemoryBooksSheet(), 100);
    }

    async function runBatchDraftGenerationFromIds(chatData, sessionId, memoryBook, drafts, count) {
        const toGenerate = drafts.slice(0, count);
        const batchJobs = toGenerate.map(async (draft) => {
            const messages = currentMessages.value.filter(m => m && draft.messageIds.includes(m.id));
            if (!messages.length) {
                return false;
            }

            try {
                return await generateMemoryDraftForMessages(messages, {
                    openSheet: false,
                    source: 'manual_draft',
                    existingDraftId: draft.id
                });
            } catch (error) {
                console.error('Failed to generate draft:', error);
                return false;
            }
        });

        const results = await Promise.all(batchJobs);
        const generated = results.filter(Boolean).length;
        const failed = results.length - generated;

        await updatePendingMemoryMessageIds(getActiveChatChar());
        await loadCurrentMemoryBook(getActiveChatChar());

        const msg = failed > 0
            ? `Batch complete: ${generated} generated, ${failed} failed`
            : `Batch complete: ${generated} draft${generated > 1 ? 's' : ''} generated`;
        showToast(msg, 3000);

        setTimeout(() => openMemoryBooksSheet(), 100);
    }

    async function generateSingleDraft(draftId) {
        if (!getActiveChatChar() || !currentMemoryBookData) return;

        if (memoryDraftState.value?.activeDrafts?.[draftId]) {
            showToast('This draft is already generating');
            return;
        }

        const chatData = await getChatData(getActiveChatChar().id);
        const sessionId = getActiveChatChar().sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);

        const draft = (Array.isArray(memoryBook.pendingDrafts) ? memoryBook.pendingDrafts : [])
            .find(d => d.id === draftId);

        if (!draft) {
            showToast('Draft not found');
            return;
        }

        if (draft.content) {
            showToast('Draft already has content. Use regenerate.');
            return;
        }

        const messages = currentMessages.value.filter(m => m && draft.messageIds.includes(m.id));
        if (!messages.length) {
            showToast('Messages not found for this draft');
            return;
        }

        try {
            const success = await generateMemoryDraftForMessages(messages, {
                openSheet: true,
                source: 'manual_draft',
                existingDraftId: draft.id
            });
            if (success) {
                showToast('Draft generated');
            }
        } catch (error) {
            console.error('Failed to generate draft:', error);
            showToast(`Generation failed: ${formatError(error)}`);
        }
    }

    async function handleMemoryBatchGenerate() {
        if (!getActiveChatChar() || !currentMemoryBookData) return;

        const chatData = await getChatData(getActiveChatChar().id);
        const sessionId = getActiveChatChar().sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);

        const draftsNeedingGeneration = (Array.isArray(memoryBook.pendingDrafts) ? memoryBook.pendingDrafts : [])
            .filter(d => !d.content && d.status === 'pending_generation' && !memoryDraftState.value?.activeDrafts?.[d.id]);
        const maxBatchSize = Math.max(1, Math.min(50, Number(memoryBook.settings?.batchSize) || 3));

        if (!draftsNeedingGeneration.length) {
            showToast(memoryDraftState.value?.activeCount ? 'All remaining drafts are already generating' : 'No drafts need generation');
            return;
        }

        await runBatchDraftGenerationFromIds(
            chatData,
            sessionId,
            memoryBook,
            draftsNeedingGeneration,
            Math.min(draftsNeedingGeneration.length, maxBatchSize)
        );
    }

    return {
        runBatchDraftGeneration,
        runBatchDraftGenerationFromIds,
        generateSingleDraft,
        handleMemoryBatchGenerate
    };
}
