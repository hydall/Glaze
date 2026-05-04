import { nextTick } from 'vue';
import * as memoryBooksService from '@/core/services/memoryBooksService.js';
import { getMemoryPromptOptions, getMemoryPromptLabelByKey } from '@/core/services/memoryPromptPresets.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';
import { mountSheetComponent } from '@/core/utils/mountSheetComponent.js';
import MemoryPromptPreviewSheet from '@/components/sheets/MemoryPromptPreviewSheet.vue';
import MemoryEntryEditorSheet from '@/components/sheets/MemoryEntryEditorSheet.vue';
import MemoryTextPreviewSheet from '@/components/sheets/MemoryTextPreviewSheet.vue';
import MemoryPromptEditorSheet from '@/components/sheets/MemoryPromptEditorSheet.vue';
import MemoryCoverageSheet from '@/components/sheets/MemoryCoverageSheet.vue';
import MemoryPromptManagerSheet from '@/components/sheets/MemoryPromptManagerSheet.vue';
import MemoryGenerationSettingsSheet from '@/components/sheets/MemoryGenerationSettingsSheet.vue';
import { formatError } from '@/utils/errors.js';
import { db } from '@/utils/db.js';
import { getChatData } from '@/utils/sessions.js';
import { saveMemorySettings, getMemorySettings } from '@/core/services/memorySchema.js';

const {
    createEmptyMemoryCoverage,
    ensureSessionMemoryBook,
    normalizeEntryMessageIds,
    reconcileSessionMemoryState,
    genMemoryEntryId,
    genMemoryPromptId,
    normalizeMemoryEntryShape,
    parseMemoryKeyInput,
    buildMemoryKeysFromText,
    indexMemoryEntryIfNeeded,
    deleteMemoryEntryIndexIfPresent,
    reindexMemoryEntry,
    getMemoryVectorSearchEnabled
} = memoryBooksService;

export function useMemorySheetUI({
    getActiveChatChar,
    currentMessages,
    selectedMessages,
    clearSelection,
    memoryBooksSheet,
    loadCurrentMemoryBook,
    generateMemoryDraftForMessages,
    generateSingleDraft,
    cancelMemoryDraft,
    handleMemorySearchTypeUpdate_composable,
    handleMemoryReindexAll_composable,
    handleMemoryScanChat_composable,
    handleMemoryApproveDraft_composable,
    handleMemoryDeleteDraft_composable,
    handleMemoryDeleteAllDrafts_composable,
    handleMemoryDeleteEntry_composable,
    handleMemoryOpenMaintenance_composable,
    handleMemoryBatchGenerate_impl,
    handleMemoryQuickModelChange_impl,
    debouncedUpdateContextCutoff
}) {

    async function openMemoryEntryEditor(entryId) {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar || !entryId) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const entry = memoryBook.entries.find(item => item.id === entryId);
        if (!entry) return;

        async function handleSave({ title: nextTitle, content: nextContent, keys: nextKeys }) {
            const retrievalChanged = JSON.stringify(entry.keys || []) !== JSON.stringify(nextKeys)
                || String(entry.content || '') !== nextContent;

            if (getMemoryVectorSearchEnabled(memoryBook) && retrievalChanged) {
                entry.content = nextContent;
                entry.keys = nextKeys;
                await reindexMemoryEntry(entry, activeChatChar.id, sessionId);
            }
            await db.patchChatData(activeChatChar.id, (chatData) => {
                const sid = activeChatChar.sessionId || chatData.currentId;
                const mb = ensureSessionMemoryBook(chatData, sid);
                const e = mb.entries.find(item => item.id === entryId);
                if (!e) return;
                e.title = nextTitle;
                e.content = nextContent;
                e.keys = nextKeys;
                e.updatedAt = Date.now();
                normalizeMemoryEntryShape(e);
                mb.updatedAt = Date.now();
                reconcileSessionMemoryState(chatData, sid, currentMessages.value);
                chatData.sessions[sid] = currentMessages.value;
            });
            entry.title = nextTitle;
            entry.content = nextContent;
            entry.keys = nextKeys;
            entry.updatedAt = Date.now();
            closeBottomSheet();
            setTimeout(() => openMemoryTextPreview(entry, 'Memory Entry'), 50);
        }

        const { el } = mountSheetComponent(MemoryEntryEditorSheet, {
            entry: { title: entry.title, content: entry.content, keys: entry.keys },
            onSave: handleSave,
            onPreview: () => openMemoryTextPreview(entry, 'Memory Entry')
        });
        showBottomSheet({ title: 'Edit Memory Entry', content: el, isSolid: true });
    }

    function openMemoryPromptPreview(item, options = {}) {
        if (!item) return;
        const { onClose } = options;
        const { el } = mountSheetComponent(MemoryPromptPreviewSheet, {
            label: item.label || 'Prompt',
            prompt: item.prompt || '',
            onClose: onClose || null
        });
        showBottomSheet({ title: 'Generation Rule', content: el, isSolid: true });
    }

    async function createMemoryFromSelection() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar || selectedMessages.value.size === 0) return;

        const selected = currentMessages.value.filter(msg => msg && selectedMessages.value.has(msg.id));
        if (!selected.length) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const vectorEnabled = getMemoryVectorSearchEnabled(memoryBook);
        const selectedIds = selected.map(msg => msg.id);
        const firstMessage = selected[0];
        const lastMessage = selected[selected.length - 1];
        const previewLines = selected
            .map(msg => `${msg.role === 'user' ? (msg.persona?.name || 'User') : (activeChatChar?.name || 'Character')}: ${msg.text || ''}`.trim())
            .filter(Boolean)
            .slice(0, 6);
        const previewContent = previewLines.join('\n').slice(0, 2000);
        const personaNames = selected
            .map(msg => msg.role === 'user' ? (msg.persona?.name || 'User') : (activeChatChar?.name || 'Character'))
            .filter(Boolean);

        const createdEntry = normalizeMemoryEntryShape({
            id: genMemoryEntryId(),
            title: `Memory ${memoryBook.entries.length + 1}`,
            content: previewContent,
            keys: buildMemoryKeysFromText(previewContent, personaNames),
            glazeKeys: [],
            vectorSearch: vectorEnabled,
            messageIds: selectedIds,
            messageRange: {
                startMessageId: firstMessage.id,
                endMessageId: lastMessage.id
            },
            status: 'active',
            source: 'manual',
            createdAt: Date.now(),
            updatedAt: Date.now()
        });
        await db.patchChatData(activeChatChar.id, (chatData) => {
            const sid = activeChatChar.sessionId || chatData.currentId;
            const mb = ensureSessionMemoryBook(chatData, sid);
            mb.entries.push(createdEntry);
            mb.updatedAt = Date.now();
            reconcileSessionMemoryState(chatData, sid, currentMessages.value);
            chatData.sessions[sid] = currentMessages.value;
        });
        await indexMemoryEntryIfNeeded(createdEntry, activeChatChar.id, sessionId);
        clearSelection();
    }

    async function generateMemoryDraftFromSelection() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar || selectedMessages.value.size === 0) return;

        const selected = currentMessages.value.filter(msg => msg && selectedMessages.value.has(msg.id));
        if (!selected.length) return;
        clearSelection();
        await generateMemoryDraftForMessages(selected, { openSheet: true, source: 'manual_draft' });
    }

    function openMemoryTextPreview(entry, kind = 'Memory') {
        if (!entry) return;

        async function handleReindex() {
            const activeChatChar = getActiveChatChar();
            if (!activeChatChar) return;
            const chatData = await getChatData(activeChatChar.id);
            const sessionId = activeChatChar.sessionId || chatData.currentId;
            const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
            if (!getMemoryVectorSearchEnabled(memoryBook)) {
                showToast('Enable Memory Books vector search first');
                return;
            }
            try {
                showToast('Reindexing memory entry...', 1500);
                entry.vectorSearch = true;
                await reindexMemoryEntry(entry, activeChatChar.id, sessionId);
                await db.patchChatData(activeChatChar.id, (chatData) => {
                    const sid = activeChatChar.sessionId || chatData.currentId;
                    const mb = ensureSessionMemoryBook(chatData, sid);
                    const e = mb.entries.find(item => item.id === entry.id);
                    if (e) {
                        e.vectorSearch = true;
                        e.updatedAt = Date.now();
                    }
                    mb.updatedAt = Date.now();
                });
                showToast('Memory entry reindexed');
            } catch (error) {
                console.error('Failed to reindex memory entry:', error);
                showToast(`Reindex failed: ${formatError(error)}`);
            }
        }

        async function handleDelete() {
            const activeChatChar = getActiveChatChar();
            if (!activeChatChar) return;
            await deleteMemoryEntryIndexIfPresent(entry.id);
            await db.patchChatData(activeChatChar.id, (chatData) => {
                const sid = activeChatChar.sessionId || chatData.currentId;
                const mb = ensureSessionMemoryBook(chatData, sid);
                mb.entries = mb.entries.filter(item => item.id !== entry.id);
                mb.updatedAt = Date.now();
                reconcileSessionMemoryState(chatData, sid, currentMessages.value);
                chatData.sessions[sid] = currentMessages.value;
            });
            closeBottomSheet();
            setTimeout(() => openMemoryBooksSheet(), 50);
        }

        async function handleRegenerate() {
            const activeChatChar = getActiveChatChar();
            if (!activeChatChar || !entry.messageIds || !entry.messageIds.length) {
                showToast('Cannot regenerate: no message range');
                return;
            }
            const chatData = await getChatData(activeChatChar.id);
            const sessionId = activeChatChar.sessionId || chatData.currentId;
            const messages = chatData.sessions[sessionId] || [];
            const selMessages = messages.filter(msg => entry.messageIds.includes(msg.id));
            if (!selMessages.length) {
                showToast('Cannot regenerate: messages not found');
                return;
            }
            closeBottomSheet();
            try {
                await generateMemoryDraftForMessages(selMessages, { source: 'manual_regenerate' });
                showToast('Draft regenerated');
                setTimeout(() => openMemoryBooksSheet(), 50);
            } catch (error) {
                console.error('Failed to regenerate draft:', error);
                showToast(`Regeneration failed: ${formatError(error)}`);
            }
        }

        const { el } = mountSheetComponent(MemoryTextPreviewSheet, {
            entry,
            kind,
            vectorEnabled: entry.vectorSearch || false,
            onEdit: () => { closeBottomSheet(); setTimeout(() => openMemoryEntryEditor(entry.id), 50); },
            onReindex: handleReindex,
            onDelete: handleDelete,
            onRegenerate: handleRegenerate,
            onClose: () => openMemoryBooksSheet()
        });
        showBottomSheet({ title: kind, content: el, isSolid: true });
    }

    async function openMessageMemoryCoverage(message) {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar || !message) return;

        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const coverage = message.memoryCoverage && typeof message.memoryCoverage === 'object'
            ? message.memoryCoverage
            : createEmptyMemoryCoverage();
        const entryIds = Array.isArray(coverage.entryIds) ? coverage.entryIds : [];
        const matchedEntries = (Array.isArray(memoryBook.entries) ? memoryBook.entries : [])
            .filter(entry => entryIds.includes(entry.id));

        if (!matchedEntries.length) {
            if (coverage.needsRebuild) {
                showToast('This message is marked for memory rebuild');
            } else if (coverage.stale) {
                showToast('This message has stale memory coverage');
            } else {
                showToast('No linked memory entries for this message');
            }
            return;
        }

        function handleEntryClick(entry) {
            closeBottomSheet();
            setTimeout(() => openMemoryTextPreview(entry, 'Memory Entry'), 50);
        }

        const { el } = mountSheetComponent(MemoryCoverageSheet, {
            matchedEntries: matchedEntries.map(e => ({
                id: e.id,
                title: e.title,
                status: e.status,
                messageIds: normalizeEntryMessageIds(e)
            })),
            coverage,
            onEntryClick: handleEntryClick
        });
        showBottomSheet({ title: 'Message Memory Coverage', content: el, isSolid: true });
    }

    async function removeMemoryFromSelection() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar || selectedMessages.value.size === 0) return;

        const selectedIds = new Set(currentMessages.value.filter(msg => msg && selectedMessages.value.has(msg.id)).map(msg => msg.id));
        if (!selectedIds.size) return;

        await db.patchChatData(activeChatChar.id, (chatData) => {
            const sid = activeChatChar.sessionId || chatData.currentId;
            const mb = ensureSessionMemoryBook(chatData, sid);
            const removedEntryIds = mb.entries
                .filter(entry => normalizeEntryMessageIds(entry).some(id => selectedIds.has(id)))
                .map(entry => entry.id);
            if (!removedEntryIds.length) return;
            mb.entries = mb.entries.filter(entry => !removedEntryIds.includes(entry.id));
            mb.updatedAt = Date.now();
            for (const msg of currentMessages.value) {
                if (!msg?.memoryCoverage) msg.memoryCoverage = createEmptyMemoryCoverage();
                const wasCovered = Array.isArray(msg.memoryCoverage.entryIds) && msg.memoryCoverage.entryIds.some(id => removedEntryIds.includes(id));
                msg.memoryCoverage.entryIds = (msg.memoryCoverage.entryIds || []).filter(id => !removedEntryIds.includes(id));
                if (wasCovered) {
                    msg.memoryCoverage.needsRebuild = true;
                    msg.memoryCoverage.stale = false;
                }
            }
            chatData.sessions[sid] = currentMessages.value;
        });
        clearSelection();
    }

    async function openMemoryGenerationSettings(initialState = null) {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;

        const settings = getMemorySettings();

        function handleSelectPrompt(state) {
            closeBottomSheet();
            const promptItems = getMemoryPromptOptions(settings).map(item => ({
                label: item.label,
                onClick: () => {
                    state.promptPreset = item.key;
                    closeBottomSheet();
                }
            }));
            promptItems.push({
                label: `Preview: ${getMemoryPromptLabelByKey(settings, state.promptPreset)}`,
                onClick: () => {
                    const selected = getMemoryPromptOptions(settings).find(item => item.key === state.promptPreset);
                    closeBottomSheet();
                    setTimeout(() => openMemoryPromptPreview(selected, {
                        onClose: () => openMemoryGenerationSettings({ ...state })
                    }), 50);
                }
            });
            promptItems.push({
                label: 'Manage custom prompts',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => openMemoryPromptManager(), 50);
                }
            });
            showBottomSheet({ title: 'Generation Rules', items: promptItems });
        }

        function handlePreviewPrompt(state) {
            const options = getMemoryPromptOptions(settings);
            const selected = options.find(item => item.key === state.promptPreset) || options[0];
            closeBottomSheet();
            setTimeout(() => openMemoryPromptPreview(selected, {
                onClose: () => openMemoryGenerationSettings({ ...state })
            }), 50);
        }

        function handleManagePrompts() {
            closeBottomSheet();
            setTimeout(() => openMemoryPromptManager(), 50);
        }

        async function handleSave(state) {
            await db.patchChatData(activeChatChar.id, (chatData) => {
                const sid = activeChatChar.sessionId || chatData.currentId;
                const mb = ensureSessionMemoryBook(chatData, sid);
                if (!mb.settings) mb.settings = {};
                const s = mb.settings;
                s.generationSource = state.source;
                s.generationUseCurrentModelOverride = false;
                s.generationModel = state.model || '';
                s.generationTemperature = state.temperature === '' || state.temperature == null ? null : Number(state.temperature);
                s.generationMaxTokens = state.maxTokens === '' || state.maxTokens == null
                    ? null
                    : Math.max(200, Math.min(32000, Number.isFinite(Number(state.maxTokens)) ? Math.round(Number(state.maxTokens)) : 2000));
                s.autoCreateEnabled = !!state.autoCreateEnabled;
                s.autoGenerateEnabled = !!state.autoGenerateEnabled;
                s.autoCreateInterval = Number.isFinite(state.autoCreateInterval) && state.autoCreateInterval > 0 ? Math.max(1, Math.min(200, Math.round(state.autoCreateInterval))) : 15;
                s.batchSize = Number.isFinite(state.batchSize) && state.batchSize > 0 ? Math.max(1, Math.min(50, Math.round(state.batchSize))) : 3;
                s.useDelayedAutomation = !!state.useDelayedAutomation;
                s.maxInjectedEntries = Number.isFinite(state.maxInjectedEntries) && state.maxInjectedEntries > 0 ? Math.max(1, Math.min(20, Math.round(state.maxInjectedEntries))) : 7;
                s.injectionTarget = state.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block';
                s.promptPreset = state.promptPreset || 'detailed_beats';
                mb.updatedAt = Date.now();
                saveMemorySettings(s);
            });
            closeBottomSheet();
            setTimeout(() => openMemoryBooksSheet(), 50);
        }

        function handleCancel() {
            closeBottomSheet();
            setTimeout(() => openMemoryBooksSheet(), 50);
        }

        const { el } = mountSheetComponent(MemoryGenerationSettingsSheet, {
            settings,
            initialState: initialState || {},
            onSelectPrompt: handleSelectPrompt,
            onPreviewPrompt: handlePreviewPrompt,
            onManagePrompts: handleManagePrompts,
            onSave: handleSave,
            onCancel: handleCancel
        });
        showBottomSheet({ title: 'Memory Generation', content: el, isSolid: true });
    }

    async function openMemoryPromptManager() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;
        const settings = getMemorySettings();
        if (!Array.isArray(settings.customPrompts)) settings.customPrompts = [];

        async function handleDelete(item) {
            await db.patchChatData(activeChatChar.id, (chatData) => {
                const sid = activeChatChar.sessionId || chatData.currentId;
                const mb = ensureSessionMemoryBook(chatData, sid);
                if (!mb.settings) mb.settings = {};
                if (!Array.isArray(mb.settings.customPrompts)) mb.settings.customPrompts = [];
                mb.settings.customPrompts = mb.settings.customPrompts.filter(p => p.id !== item.id);
                if (mb.settings.promptPreset === item.id) mb.settings.promptPreset = 'detailed_beats';
                mb.updatedAt = Date.now();
                saveMemorySettings(mb.settings);
            });
            closeBottomSheet();
            setTimeout(() => openMemoryPromptManager(), 50);
        }

        function handleEdit(item) {
            closeBottomSheet();
            setTimeout(() => openMemoryPromptEditor(item), 50);
        }

        function handlePreview(item) {
            closeBottomSheet();
            setTimeout(() => openMemoryPromptPreview(
                { label: item.name || 'Custom prompt', prompt: item.prompt || '' },
                { onClose: openMemoryPromptManager }
            ), 50);
        }

        function handleAdd() {
            closeBottomSheet();
            setTimeout(() => openMemoryPromptEditor(), 50);
        }

        const { el } = mountSheetComponent(MemoryPromptManagerSheet, {
            customPrompts: settings.customPrompts.map(p => ({ id: p.id, name: p.name, prompt: p.prompt })),
            onAdd: handleAdd,
            onEdit: handleEdit,
            onDelete: handleDelete,
            onPreview: handlePreview
        });
        showBottomSheet({ title: 'Generation Rules', content: el, isSolid: true });
    }

    async function openMemoryPromptEditor(existing = null) {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;

        async function handleSave({ name, prompt }) {
            await db.patchChatData(activeChatChar.id, (chatData) => {
                const sid = activeChatChar.sessionId || chatData.currentId;
                const mb = ensureSessionMemoryBook(chatData, sid);
                if (!mb.settings) mb.settings = {};
                if (!Array.isArray(mb.settings.customPrompts)) mb.settings.customPrompts = [];
                if (existing) {
                    const target = mb.settings.customPrompts.find(item => item.id === existing.id);
                    if (target) {
                        target.name = name;
                        target.prompt = prompt;
                    }
                } else {
                    const created = { id: genMemoryPromptId(), name, prompt };
                    mb.settings.customPrompts.push(created);
                    mb.settings.promptPreset = created.id;
                }
                mb.updatedAt = Date.now();
                saveMemorySettings(mb.settings);
            });
            closeBottomSheet();
            setTimeout(() => openMemoryPromptManager(), 50);
        }

        const { el } = mountSheetComponent(MemoryPromptEditorSheet, {
            existing: existing ? { id: existing.id, name: existing.name, prompt: existing.prompt } : null,
            onSave: handleSave
        });
        showBottomSheet({ title: existing ? 'Edit Prompt' : 'Add Prompt', content: el, isSolid: true });
    }

    async function openMemoryBooksSheet() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;
        await loadCurrentMemoryBook(activeChatChar);
        nextTick(() => {
            memoryBooksSheet.value?.open();
        });
    }

    async function handleMemorySearchTypeUpdate() {
        const activeChatChar = getActiveChatChar();
        await handleMemorySearchTypeUpdate_composable(activeChatChar, memoryBooksSheet);
    }

    async function handleMemoryReindexAll() {
        const activeChatChar = getActiveChatChar();
        await handleMemoryReindexAll_composable(activeChatChar, memoryBooksSheet);
    }

    async function handleMemoryScanChat() {
        const activeChatChar = getActiveChatChar();
        await handleMemoryScanChat_composable(activeChatChar, currentMessages.value, memoryBooksSheet);
    }

    async function handleMemoryBatchGenerate() {
        await handleMemoryBatchGenerate_impl();
    }

    async function handleMemoryGenerateSingleDraft(draftId) {
        await generateSingleDraft(draftId);
    }

    async function handleMemoryApproveDraft(draftId) {
        const activeChatChar = getActiveChatChar();
        await handleMemoryApproveDraft_composable(draftId, activeChatChar, currentMessages.value, memoryBooksSheet);
    }

    async function handleMemoryDeleteDraft(draftId) {
        const activeChatChar = getActiveChatChar();
        await handleMemoryDeleteDraft_composable(draftId, activeChatChar, memoryBooksSheet);
    }

    async function handleMemoryDeleteAllDrafts() {
        const activeChatChar = getActiveChatChar();
        await handleMemoryDeleteAllDrafts_composable(activeChatChar, memoryBooksSheet);
    }

    async function handleMemoryDeleteEntry(entryId) {
        const activeChatChar = getActiveChatChar();
        await handleMemoryDeleteEntry_composable(entryId, activeChatChar, currentMessages.value, memoryBooksSheet);
    }

    function handleMemoryOpenMaintenance() {
        const activeChatChar = getActiveChatChar();
        handleMemoryOpenMaintenance_composable(activeChatChar, memoryBooksSheet);
    }

    function handleMemoryCancelDraft(draftId = null) {
        cancelMemoryDraft(draftId || null);
    }

    function handleMemoryPreview({ entry, kind }) {
        openMemoryTextPreview(entry, kind);
    }

    function handleMemoryOpenSettings() {
        openMemoryGenerationSettings();
    }

    function handleMemoryQuickModelChange(model) {
        handleMemoryQuickModelChange_impl(model);
    }

    return {
        openMemoryEntryEditor,
        openMemoryPromptPreview,
        createMemoryFromSelection,
        generateMemoryDraftFromSelection,
        openMemoryTextPreview,
        openMessageMemoryCoverage,
        removeMemoryFromSelection,
        openMemoryGenerationSettings,
        openMemoryPromptManager,
        openMemoryPromptEditor,
        openMemoryBooksSheet,
        handleMemorySearchTypeUpdate,
        handleMemoryReindexAll,
        handleMemoryScanChat,
        handleMemoryBatchGenerate,
        handleMemoryGenerateSingleDraft,
        handleMemoryApproveDraft,
        handleMemoryDeleteDraft,
        handleMemoryDeleteAllDrafts,
        handleMemoryDeleteEntry,
        handleMemoryOpenMaintenance,
        handleMemoryCancelDraft,
        handleMemoryPreview,
        handleMemoryOpenSettings,
        handleMemoryQuickModelChange
    };
}
