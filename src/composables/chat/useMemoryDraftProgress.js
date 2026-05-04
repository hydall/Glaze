import { ref } from 'vue';

export function useMemoryDraftProgress({ showToast }) {
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

    return {
        memoryDraftState,
        setMemoryDraftAbortController,
        getMemoryDraftAbortController,
        startMemoryDraftProgress,
        stopMemoryDraftProgress,
        cancelMemoryDraft
    };
}
