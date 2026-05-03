import { getChatData } from '@/utils/sessions.js';
import { db } from '@/utils/db.js';
import { generateMemoryDraft } from '@/core/llm/usecases/generateMemoryDraft.js';
import { showToast } from '@/core/states/toastState.js';
import { formatError } from '@/utils/errors.js';
import {
    ensureSessionMemoryBook,
    ensureMemoryAutomationState,
    getStableVisibleMessages,
    countStableConversationMessages,
    getLastStableConversationRole,
    computeDelayedWaitExchanges,
    countCompletedExchangesSince,
    normalizeAutoCreateInterval,
    resolvePendingTriggerMessages,
    buildBootstrapSegments,
    arraysEqual,
    findConflictingMemoryEntry,
    normalizeEntryMessageIds,
    normalizeMemoryEntryShape,
    genMemoryEntryId,
    getMemoryVectorSearchEnabled,
    buildMemoryKeysFromText,
    parseMemoryDraftResponse
} from '@/core/services/memoryBooksService.js';
import {
    resolveMemoryPrompt
} from '@/core/services/memoryPromptPresets.js';

function buildMemoryContinuityContext(memoryBook, selected) {
    const selectedIds = new Set(selected.map(msg => msg.id));
    const activeEntries = Array.isArray(memoryBook.entries) ? memoryBook.entries : [];
    return activeEntries
        .filter(entry => {
            const ids = Array.isArray(entry.messageIds) ? entry.messageIds : [];
            return ids.length && ids.every(id => !selectedIds.has(id));
        })
        .slice(-2)
        .map(entry => `${entry.title || 'Memory'}: ${entry.content || ''}`.trim())
        .filter(Boolean)
        .join('\n\n');
}

function buildMemoryDraftLoreContext(selected) {
    const historicalLabels = new Map();
    selected.forEach(msg => {
        (Array.isArray(msg?.contextRefs) ? msg.contextRefs : []).forEach(ref => {
            if (ref?.type === 'lorebook' && ref?.id) {
                const key = ref.id;
                const existing = historicalLabels.get(key) || { label: ref.label || 'Entry', count: 0 };
                existing.count += 1;
                historicalLabels.set(key, existing);
            }
        });
    });

    const historicalLines = [...historicalLabels.values()]
        .sort((a, b) => b.count - a.count)
        .slice(0, 3)
        .map(item => `- ${item.label}${item.count > 1 ? ` x${item.count}` : ''}`);

    const liveCandidates = [...new Set(selected.flatMap(msg =>
        (Array.isArray(msg?.triggeredLorebooks) ? msg.triggeredLorebooks : [])
            .map(entry => entry?.name || entry?.label || '')
            .filter(Boolean)
    ))]
        .slice(0, 2)
        .map(label => `- ${label}`);

    const sections = [];
    if (historicalLines.length) {
        sections.push(['Historical triggers:', ...historicalLines].join('\n'));
    }
    if (liveCandidates.length) {
        sections.push(['Current live candidates:', ...liveCandidates].join('\n'));
    }
    return sections.join('\n\n');
}

function buildMemoryDraftSummaryExcerpt(summary) {
    if (!summary) return '';
    if (typeof summary === 'string') return summary.trim().slice(0, 800);
    if (typeof summary === 'object') {
        if (typeof summary.content === 'string') return summary.content.trim().slice(0, 800);
        return ['timeline', 'characterArcs', 'conflictsThreads', 'notHappenedYet', 'notes']
            .map(key => summary[key])
            .filter(value => typeof value === 'string' && value.trim())
            .join('\n\n')
            .slice(0, 800);
    }
    return '';
}

export function useMemoryAutomation({
    getActiveChatChar,
    currentMessages,
    activePersona,
    getGenerationState,
    memoryDraftState,
    currentMemoryBookData,
    loadCurrentMemoryBook,
    updatePendingMemoryMessageIds,
    startMemoryDraftProgress,
    stopMemoryDraftProgress,
    setMemoryDraftAbortController,
    openMemoryBooksSheet
}) {
    function createPendingMemoryDraft(memoryBook, selectedMessages, { source = 'scan_chat', vectorSearch = false } = {}) {
        const selected = (Array.isArray(selectedMessages) ? selectedMessages : []).filter(Boolean);
        if (!memoryBook || !selected.length) return null;

        const selectedIds = selected.map(msg => msg.id).filter(Boolean);
        if (!selectedIds.length) return null;

        const existingDrafts = Array.isArray(memoryBook.pendingDrafts) ? memoryBook.pendingDrafts : [];
        const existingDraft = existingDrafts.find(draft => arraysEqual(normalizeEntryMessageIds(draft), selectedIds));
        if (existingDraft) {
            if (!existingDraft.content) existingDraft.status = 'pending_generation';
            existingDraft.source = source;
            existingDraft.updatedAt = Date.now();
            return existingDraft;
        }

        const stableMessages = currentMessages.value.filter(m => m && !m.isTyping && !m.isError && (m.role === 'user' || m.role === 'char'));
        const firstMessage = selected[0];
        const lastMessage = selected[selected.length - 1];
        const firstIdx = stableMessages.findIndex(m => m.id === firstMessage.id);
        const lastIdx = stableMessages.findIndex(m => m.id === lastMessage.id);
        const rangeDisplay = firstIdx >= 0 && lastIdx >= 0
            ? `${firstIdx + 1}-${lastIdx + 1}`
            : `Draft ${(Array.isArray(memoryBook.pendingDrafts) ? memoryBook.pendingDrafts.length : 0) + 1}`;
        const createdAt = Date.now();
        const draft = normalizeMemoryEntryShape({
            id: genMemoryEntryId(),
            title: rangeDisplay,
            content: '',
            rawContent: '',
            keys: [],
            glazeKeys: [],
            vectorSearch,
            messageIds: selectedIds,
            messageRange: {
                startMessageId: firstMessage.id,
                endMessageId: lastMessage.id,
                start: firstIdx >= 0 ? firstIdx + 1 : null,
                end: lastIdx >= 0 ? lastIdx + 1 : null
            },
            status: 'pending_generation',
            source,
            createdAt,
            updatedAt: createdAt,
            generatedAt: null
        });

        if (!Array.isArray(memoryBook.pendingDrafts)) memoryBook.pendingDrafts = [];
        memoryBook.pendingDrafts.push(draft);
        return draft;
    }

    async function generateMemoryDraftForMessages(selectedMessages, { openSheet = false, source = 'auto_delayed', existingDraftId = null } = {}) {
        if (!getActiveChatChar() || !Array.isArray(selectedMessages) || !selectedMessages.length) return false;
        console.debug('[MemoryBooks] generateMemoryDraftForMessages:start', { source, existingDraftId, inputCount: selectedMessages.length });

        const activeGeneration = getGenerationState(getActiveChatChar().id);
        if (activeGeneration && activeGeneration.type !== 'impersonation') {
            showToast('Stop the current response generation before starting a memory draft');
            return false;
        }

        const selected = selectedMessages.filter(msg => msg && !msg.isTyping && !msg.isError);
        console.debug('[MemoryBooks] generateMemoryDraftForMessages:filtered', { source, existingDraftId, filteredCount: selected.length });
        if (!selected.length) {
            showToast('No valid messages found for memory draft generation');
            return false;
        }

        const chatData = await getChatData(getActiveChatChar().id);
        const sessionId = getActiveChatChar().sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const automation = ensureMemoryAutomationState(memoryBook);
        const isManualDraftRequest = source === 'manual_draft' || source === 'manual_regenerate';

        if (automation.isGeneratingDraft && !isManualDraftRequest) {
            showToast('Already generating a draft. Please wait...');
            return false;
        }

        const vectorEnabled = getMemoryVectorSearchEnabled(memoryBook);
        const settings = memoryBook.settings || {};
        const generationMaxTokens = Number.isFinite(Number(settings.generationMaxTokens)) && Number(settings.generationMaxTokens) > 0
            ? Math.round(Number(settings.generationMaxTokens))
            : null;
        const summary = chatData?.summaries?.[sessionId] || null;
        const playerName = selected.find(msg => msg?.role === 'user')?.persona?.name || activePersona.value?.name || 'User';
        const history = selected
            .map(msg => `${msg.role === 'user' ? (msg.persona?.name || playerName) : (getActiveChatChar()?.name || 'Character')}: ${msg.text || ''}`.trim())
            .filter(Boolean)
            .join('\n');

        const continuity = buildMemoryContinuityContext(memoryBook, selected);
        const loreContext = buildMemoryDraftLoreContext(selected);
        const summaryExcerpt = buildMemoryDraftSummaryExcerpt(summary);
        const apiConfigOverride = settings.generationSource === 'custom'
            ? {
                apiUrl: settings.generationEndpoint,
                apiKey: settings.generationApiKey,
                model: settings.generationModel,
                temp: settings.generationTemperature ?? undefined,
                ...(generationMaxTokens ? { maxTokens: generationMaxTokens } : {})
            }
            : {
                ...(settings.generationModel
                    ? { model: settings.generationModel }
                    : {}),
                ...(settings.generationTemperature != null // eslint-disable-line eqeqeq
                    ? { temp: settings.generationTemperature }
                    : {}),
                ...(generationMaxTokens ? { maxTokens: generationMaxTokens } : {})
            };
        const prompt = resolveMemoryPrompt(settings)
            .replaceAll('{{user}}', playerName)
            .replaceAll('{{char}}', getActiveChatChar()?.name || 'Character');
        const finalPrompt = [
            prompt,
            continuity ? `Previous approved memory context:\n${continuity}` : '',
            loreContext ? `Historical lore trigger candidates:\n${loreContext}` : '',
            summaryExcerpt ? `Summary excerpt:\n${summaryExcerpt}` : ''
        ].filter(Boolean).join('\n\n');

        const firstMessage = selected[0];
        const lastMessage = selected[selected.length - 1];
        const selectedIds = selected.map(msg => msg.id).filter(Boolean);
        if (!selectedIds.length) return false;
        const progressDraftId = existingDraftId || `memory_draft_${selectedIds[0]}`;
        const generatedAt = Date.now();

        if (existingDraftId && memoryDraftState.value?.activeDrafts?.[progressDraftId]) {
            showToast('This draft is already generating');
            return false;
        }

        let existingDraft = null;
        if (existingDraftId) {
            existingDraft = (Array.isArray(memoryBook.pendingDrafts) ? memoryBook.pendingDrafts : [])
                .find(d => d.id === existingDraftId);
        }

        if (source !== 'manual_draft' && source !== 'manual_regenerate') {
            const conflictingEntry = findConflictingMemoryEntry(memoryBook, selectedIds, {
                includeEntries: true,
                includeDrafts: true,
                overlapThreshold: 0.8
            });
            if (conflictingEntry) {
                return false;
            }
        }

        try {
            await db.patchChatData(getActiveChatChar().id, (chatData) => {
                const sessionId = getActiveChatChar().sessionId || chatData.currentId;
                const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
                const automation = ensureMemoryAutomationState(memoryBook);
                automation.isGeneratingDraft = true;
                memoryBook.updatedAt = Date.now();
            });

            const progressLabel = existingDraftId
                ? `Draft ${existingDraft?.title || 'generation'}`
                : (source === 'manual_draft' ? 'Generating selected memory draft' : 'Generating memory draft');
            startMemoryDraftProgress(progressLabel, progressDraftId);
            if (!existingDraftId || source !== 'manual_draft') {
                showToast('Generating memory draft...', 2000);
            }
            const memoryDraftAbortController = new AbortController();
            setMemoryDraftAbortController(memoryDraftAbortController, progressDraftId);
            const draftText = await generateMemoryDraft({
                history,
                prompt: finalPrompt,
                debugKey: `memory_draft:${getActiveChatChar().id}:${getActiveChatChar().sessionId || 'default'}:${progressDraftId}`,
                controller: memoryDraftAbortController,
                apiConfigOverride
            });
            console.debug('[MemoryBooks] generateMemoryDraftForMessages:request-complete', { existingDraftId, textLength: draftText?.length || 0 });
            const parsedDraft = parseMemoryDraftResponse(draftText || '', [playerName, getActiveChatChar()?.name || 'Character']);

            let wasExistingDraft = false;
            await db.patchChatData(getActiveChatChar().id, (latestChatData) => {
                const latestSessionId = getActiveChatChar().sessionId || latestChatData.currentId;
                const latestMemoryBook = ensureSessionMemoryBook(latestChatData, latestSessionId);
                const latestAutomation = ensureMemoryAutomationState(latestMemoryBook);

                if (!Array.isArray(latestMemoryBook.pendingDrafts)) latestMemoryBook.pendingDrafts = [];

                const latestExistingDraft = existingDraftId
                    ? latestMemoryBook.pendingDrafts.find(d => d.id === existingDraftId)
                    : null;
                wasExistingDraft = !!latestExistingDraft;

                if (latestExistingDraft) {
                    latestExistingDraft.content = (parsedDraft.content || parsedDraft.raw || '').trim();
                    latestExistingDraft.rawContent = (parsedDraft.raw || parsedDraft.content || '').trim();
                    latestExistingDraft.keys = parsedDraft.keys || [];
                    latestExistingDraft.glazeKeys = [];
                    latestExistingDraft.vectorSearch = vectorEnabled;
                    latestExistingDraft.status = 'pending_approval';
                    latestExistingDraft.source = source;
                    latestExistingDraft.updatedAt = generatedAt;
                    latestExistingDraft.generatedAt = generatedAt;
                } else {
                    const createdDraft = createPendingMemoryDraft(latestMemoryBook, selected, { source, vectorSearch: vectorEnabled });
                    if (createdDraft) {
                        createdDraft.content = (parsedDraft.content || parsedDraft.raw || '').trim();
                        createdDraft.rawContent = (parsedDraft.raw || parsedDraft.content || '').trim();
                        createdDraft.keys = parsedDraft.keys || [];
                        createdDraft.glazeKeys = [];
                        createdDraft.vectorSearch = vectorEnabled;
                        createdDraft.status = 'pending_approval';
                        createdDraft.source = source;
                        createdDraft.updatedAt = generatedAt;
                        createdDraft.generatedAt = generatedAt;
                    }
                }
                latestAutomation.isGeneratingDraft = true;
                latestMemoryBook.updatedAt = generatedAt;
            });
            stopMemoryDraftProgress(progressDraftId);
            await db.patchChatData(getActiveChatChar().id, (postSaveChatData) => {
                const postSaveSessionId = getActiveChatChar().sessionId || postSaveChatData.currentId;
                const postSaveMemoryBook = ensureSessionMemoryBook(postSaveChatData, postSaveSessionId);
                const postSaveAutomation = ensureMemoryAutomationState(postSaveMemoryBook);
                postSaveAutomation.isGeneratingDraft = Object.keys(memoryDraftState.value.activeDrafts || {}).length > 0;
                postSaveMemoryBook.updatedAt = Date.now();
            });
            await updatePendingMemoryMessageIds(getActiveChatChar());
            await loadCurrentMemoryBook(getActiveChatChar());
            showToast(wasExistingDraft ? 'Draft updated' : 'Memory draft created');
            if (openSheet) {
                openMemoryBooksSheet();
            }
            return true;
        } catch (error) {
            stopMemoryDraftProgress(progressDraftId);
            await db.patchChatData(getActiveChatChar().id, (latestChatData) => {
                const latestSessionId = getActiveChatChar().sessionId || latestChatData.currentId;
                const latestMemoryBook = ensureSessionMemoryBook(latestChatData, latestSessionId);
                const latestAutomation = ensureMemoryAutomationState(latestMemoryBook);
                latestAutomation.isGeneratingDraft = Object.keys(memoryDraftState.value.activeDrafts || {}).length > 0;
                latestMemoryBook.updatedAt = Date.now();
            });
            await loadCurrentMemoryBook(getActiveChatChar());
            console.error('Failed to generate memory draft:', error);
            showToast(`Memory draft failed: ${formatError(error)}`, 5000);
            return false;
        }
    }

    async function runMemoryAutomationAfterStableTurn(chatData, sessionId, messages, { allowImmediate = true, charId = null, syncUi = true } = {}) {
        const targetCharId = charId || getActiveChatChar()?.id;
        if (!targetCharId) return false;

        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const automation = ensureMemoryAutomationState(memoryBook);
        const autoCreateEnabled = memoryBook.settings?.autoCreateEnabled !== false;
        const autoGenerateEnabled = memoryBook.settings?.autoGenerateEnabled === true;
        const stableMessages = getStableVisibleMessages(messages).filter(msg => msg.role === 'user' || msg.role === 'char');
        const stableCount = stableMessages.length;
        const interval = normalizeAutoCreateInterval(memoryBook);
        const delayed = memoryBook.settings?.useDelayedAutomation !== false;
        const lastRole = getLastStableConversationRole(stableMessages);
        const shouldSyncUi = syncUi && getActiveChatChar()?.id === targetCharId;

        if (!autoCreateEnabled) {
            await db.patchChatData(targetCharId, (chatData) => {
                const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
                const automation = ensureMemoryAutomationState(memoryBook);
                automation.pendingTrigger = null;
                automation.lastProcessedMessageCount = Math.max(automation.lastProcessedMessageCount || 0, stableCount);
                memoryBook.updatedAt = Date.now();
            });
            return false;
        }

        if (!stableCount || !lastRole) {
            automation.lastProcessedMessageCount = stableCount;
            automation.pendingTrigger = null;
            return false;
        }

        if (automation.pendingTrigger) {
            const completedExchanges = countCompletedExchangesSince(automation.pendingTrigger.triggerCount, stableCount);
            if (completedExchanges >= automation.pendingTrigger.waitExchanges) {
                let pendingDraft = null;
                const selected = resolvePendingTriggerMessages(stableMessages, automation.pendingTrigger);
                await db.patchChatData(targetCharId, (chatData) => {
                    const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
                    const automation = ensureMemoryAutomationState(memoryBook);
                    pendingDraft = createPendingMemoryDraft(memoryBook, selected, { source: 'auto_delayed' });
                    automation.lastProcessedMessageCount = stableCount;
                    automation.pendingTrigger = null;
                    memoryBook.updatedAt = Date.now();
                });
                if (shouldSyncUi) {
                    await updatePendingMemoryMessageIds(getActiveChatChar());
                }
                if (!pendingDraft) return false;
                if (!autoGenerateEnabled) return true;
                return await generateMemoryDraftForMessages(selected, {
                    source: 'auto_delayed',
                    existingDraftId: pendingDraft.id
                });
            }
            await db.patchChatData(targetCharId, (chatData) => {
                const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
                memoryBook.updatedAt = Date.now();
            });
            return false;
        }

        if (!allowImmediate || automation.isGeneratingDraft || stableCount < interval) {
            await db.patchChatData(targetCharId, (chatData) => {
                const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
                const automation = ensureMemoryAutomationState(memoryBook);
                automation.lastProcessedMessageCount = Math.max(automation.lastProcessedMessageCount, stableCount);
                memoryBook.updatedAt = Date.now();
            });
            return false;
        }

        const nextThreshold = Math.floor(stableCount / interval) * interval;
        if (nextThreshold <= 0 || nextThreshold <= automation.lastProcessedMessageCount) {
            await db.patchChatData(targetCharId, (chatData) => {
                const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
                const automation = ensureMemoryAutomationState(memoryBook);
                automation.lastProcessedMessageCount = Math.max(automation.lastProcessedMessageCount, stableCount);
                memoryBook.updatedAt = Date.now();
            });
            return false;
        }

        if (delayed) {
            const windowEndExclusive = nextThreshold;
            const windowStartIndex = Math.max(0, windowEndExclusive - interval);
            const windowMessages = stableMessages.slice(windowStartIndex, windowEndExclusive);
            await db.patchChatData(targetCharId, (chatData) => {
                const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
                const automation = ensureMemoryAutomationState(memoryBook);
                automation.pendingTrigger = {
                    triggerCount: stableCount,
                    triggerRole: lastRole,
                    waitExchanges: computeDelayedWaitExchanges(lastRole),
                    windowStartIndex,
                    windowEndIndex: Math.max(windowStartIndex, windowEndExclusive - 1),
                    messageIds: windowMessages.map(msg => msg.id).filter(Boolean),
                    createdAt: Date.now()
                };
                memoryBook.updatedAt = Date.now();
            });
            return false;
        }

        const selected = stableMessages.slice(Math.max(0, stableCount - interval), stableCount);
        let pendingDraft = null;
        await db.patchChatData(targetCharId, (chatData) => {
            const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
            const automation = ensureMemoryAutomationState(memoryBook);
            pendingDraft = createPendingMemoryDraft(memoryBook, selected, { source: 'auto_immediate' });
            automation.lastProcessedMessageCount = stableCount;
            memoryBook.updatedAt = Date.now();
        });
        if (shouldSyncUi) {
            await updatePendingMemoryMessageIds(getActiveChatChar());
        }
        if (!pendingDraft) return false;
        if (!autoGenerateEnabled) return true;
        return await generateMemoryDraftForMessages(selected, {
            source: 'auto_immediate',
            existingDraftId: pendingDraft.id
        });
    }

    async function bootstrapImportedMemoryDrafts(charId, sessionId) {
        const chatData = await getChatData(charId);
        if (!chatData?.sessions?.[sessionId]) return 0;

        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const automation = ensureMemoryAutomationState(memoryBook);
        const existingEntries = Array.isArray(memoryBook.entries) ? memoryBook.entries.length : 0;
        const existingDrafts = Array.isArray(memoryBook.pendingDrafts) ? memoryBook.pendingDrafts.length : 0;
        if (existingEntries > 0 || existingDrafts > 0) return 0;

        const interval = normalizeAutoCreateInterval(memoryBook);
        const segments = buildBootstrapSegments(chatData.sessions[sessionId], interval);
        if (!segments.length) return 0;

        let createdCount = 0;
        await db.patchChatData(charId, (chatData) => {
            if (!chatData?.sessions?.[sessionId]) return;
            const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
            const automation = ensureMemoryAutomationState(memoryBook);
            automation.pendingTrigger = null;
            for (const segment of segments) {
                const created = createPendingMemoryDraft(memoryBook, segment, { source: 'import_bootstrap' });
                if (created) createdCount += 1;
            }
            memoryBook.updatedAt = Date.now();
        });

        await db.patchChatData(charId, (latestData) => {
            if (!latestData?.sessions?.[sessionId]) return;
            const latestMemoryBook = ensureSessionMemoryBook(latestData, sessionId);
            const latestAutomation = ensureMemoryAutomationState(latestMemoryBook);
            latestAutomation.lastProcessedMessageCount = countStableConversationMessages(latestData.sessions[sessionId]);
            latestAutomation.pendingTrigger = null;
            latestMemoryBook.updatedAt = Date.now();
        });
        return createdCount;
    }

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
        console.debug('[MemoryBooks] generateSingleDraft:start', { draftId });

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
            console.debug('[MemoryBooks] generateSingleDraft:draft-not-found', { draftId });
            showToast('Draft not found');
            return;
        }

        if (draft.content) {
            showToast('Draft already has content. Use regenerate.');
            return;
        }

        const messages = currentMessages.value.filter(m => m && draft.messageIds.includes(m.id));
        console.debug('[MemoryBooks] generateSingleDraft:resolved-messages', {
            draftId,
            messageIds: draft.messageIds,
            resolvedCount: messages.length,
            hiddenCount: messages.filter(m => m?.isHidden).length
        });
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

    function handleMemoryQuickModelChange(model) {
        if (!getActiveChatChar() || !currentMemoryBookData) return;
        const settings = currentMemoryBookData.settings || {};
        settings.generationModel = model || '';
        settings.generationUseCurrentModelOverride = false;
        currentMemoryBookData.updatedAt = Date.now();
        db.patchChatData(getActiveChatChar().id, (chatData) => {
            const sessionId = getActiveChatChar().sessionId || chatData.currentId;
            const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
            if (memoryBook.settings) {
                memoryBook.settings.generationModel = model || '';
                memoryBook.settings.generationUseCurrentModelOverride = false;
            }
            memoryBook.updatedAt = Date.now();
        });
        showToast('Memory generation model updated');
    }

    return {
        createPendingMemoryDraft,
        generateMemoryDraftForMessages,
        runMemoryAutomationAfterStableTurn,
        bootstrapImportedMemoryDrafts,
        buildMemoryContinuityContext,
        buildMemoryDraftLoreContext,
        buildMemoryDraftSummaryExcerpt,
        parseMemoryDraftResponse,
        runBatchDraftGeneration,
        runBatchDraftGenerationFromIds,
        generateSingleDraft,
        handleMemoryBatchGenerate,
        handleMemoryQuickModelChange
    };
}
