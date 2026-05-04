import { nextTick } from 'vue';
import * as memoryBooksService from '@/core/services/memoryBooksService.js';
import { getMemoryPromptOptions, getMemoryPromptLabelByKey, getNormalizedMemoryGenerationState } from '@/core/services/memoryPromptPresets.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';
import { mountSheetComponent } from '@/core/utils/mountSheetComponent.js';
import MemoryPromptPreviewSheet from '@/components/sheets/MemoryPromptPreviewSheet.vue';
import MemoryEntryEditorSheet from '@/components/sheets/MemoryEntryEditorSheet.vue';
import MemoryTextPreviewSheet from '@/components/sheets/MemoryTextPreviewSheet.vue';
import { formatError } from '@/utils/errors.js';
import { db } from '@/utils/db.js';
import { getChatData } from '@/utils/sessions.js';
import { addDeletedStats } from '@/core/services/statsService.js';
import { getApiConfig } from '@/core/config/APISettings.js';
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

        const content = document.createElement('div');
        content.className = 'context-sheet';
        content.innerHTML = `
            <div class="settings-item">
                <label>Message Memory Coverage</label>
                <div class="context-sheet-note">This message is linked to ${matchedEntries.length} memory ${matchedEntries.length === 1 ? 'entry' : 'entries'}.</div>
                ${coverage.needsRebuild ? '<div class="context-sheet-note" style="color: var(--warning-color, #ffb84d);">Coverage needs rebuild.</div>' : ''}
                ${coverage.stale ? '<div class="context-sheet-note" style="color: var(--danger-color, #ff6b6b);">Coverage is marked stale.</div>' : ''}
            </div>
            <div class="memory-entry-list">
                ${matchedEntries.map(entry => `
                    <button type="button" class="memory-entry-card" data-coverage-entry-id="${entry.id}">
                        <div class="memory-entry-title-row">
                            <strong>${String(entry.title || 'Memory Entry').replace(/</g, '&lt;').replace(/>/g, '&gt;')}</strong>
                            <span class="context-sheet-note">${String(entry.status || 'active').replace(/</g, '&lt;').replace(/>/g, '&gt;')}</span>
                        </div>
                        <div class="context-sheet-note">${normalizeEntryMessageIds(entry).length} linked message${normalizeEntryMessageIds(entry).length === 1 ? '' : 's'}</div>
                    </button>
                `).join('')}
            </div>
            <div class="context-sheet-actions">
                <button type="button" class="context-sheet-btn context-sheet-btn-primary" id="memory-coverage-close">Close</button>
            </div>
        `;

        content.querySelectorAll('[data-coverage-entry-id]').forEach(btn => {
            btn.addEventListener('click', () => {
                const entryId = btn.getAttribute('data-coverage-entry-id');
                const entry = matchedEntries.find(item => item.id === entryId);
                if (!entry) return;
                closeBottomSheet();
                setTimeout(() => openMemoryTextPreview(entry, 'Memory Entry'), 50);
            });
        });
        content.querySelector('#memory-coverage-close')?.addEventListener('click', () => closeBottomSheet());
        showBottomSheet({ title: 'Message Memory Coverage', content, isSolid: true });
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
        const currentApiConfig = getApiConfig();
        const state = getNormalizedMemoryGenerationState(settings, initialState || {});

        const renderSheet = () => {
            const content = document.createElement('div');
            content.className = 'context-sheet';
            content.innerHTML = `
                <div class="settings-item">
                    <label>Generation Rules</label>
                    <div class="clickable-selector" id="memory-prompt-selector">
                        <span>${getMemoryPromptLabelByKey(settings, state.promptPreset)}</span>
                        <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                    </div>
                    <button type="button" class="memory-inline-link" id="memory-prompt-preview-btn">Preview Rule</button>
                </div>
                <div class="settings-item">
                    <label>Temperature Override</label>
                    <input id="memory-temperature-input" type="number" min="0" max="2" step="0.05" value="${state.temperature ?? ''}" placeholder="Use current API temperature">
                </div>
                <div class="settings-item">
                    <label>Output Token Limit</label>
                    <input id="memory-max-tokens-input" type="number" min="200" max="32000" step="100" value="${state.maxTokens ?? ''}" placeholder="Auto (recommended 2000-4000 for large batches)">
                    <div class="context-sheet-note">Optional max completion tokens for memory draft generation. Leave blank to use the provider default with a safety floor.</div>
                </div>
                <div class="settings-item-checkbox">
                    <div class="settings-text-col">
                        <label>Auto-Create Drafts</label>
                        <div class="settings-desc">Automatically create Memory Book drafts after enough stable messages accumulate.</div>
                    </div>
                    <input id="memory-auto-create-toggle" type="checkbox" class="vk-switch" ${state.autoCreateEnabled ? 'checked' : ''}>
                </div>
                <div class="settings-item-checkbox">
                    <div class="settings-text-col">
                        <label>Auto-Generate Draft Text</label>
                        <div class="settings-desc">When enabled, newly auto-created draft placeholders immediately generate text. When disabled, auto mode only marks segments and leaves text generation manual.</div>
                    </div>
                    <input id="memory-auto-generate-toggle" type="checkbox" class="vk-switch" ${state.autoGenerateEnabled ? 'checked' : ''}>
                </div>
                <div class="settings-item">
                    <label>Create Memory Every N Messages</label>
                    <input id="memory-auto-interval-input" type="number" min="1" max="200" step="1" value="${state.autoCreateInterval}" placeholder="15">
                    <div class="context-sheet-note">User-facing interval for future automatic memory creation and import bootstrap segmentation.</div>
                </div>
                <div class="settings-item">
                    <label>Max Generate Batch</label>
                    <input id="memory-batch-size-input" type="number" min="1" max="50" step="1" value="${state.batchSize}" placeholder="3">
                    <div class="context-sheet-note">Limits how many pending drafts the batch generate button starts at once.</div>
                </div>
                <div class="settings-item-checkbox">
                    <div class="settings-text-col">
                        <label>Work With Delay</label>
                        <div class="settings-desc">Wait for extra turns before auto-creating a memory draft, so the last user message and latest assistant reply can still be edited or regenerated safely.</div>
                    </div>
                    <input id="memory-delayed-automation-toggle" type="checkbox" class="vk-switch" ${state.useDelayedAutomation ? 'checked' : ''}>
                </div>
                <div class="settings-item">
                    <label>Memory Entries In Prompt</label>
                    <input id="memory-max-injected-input" type="number" min="1" max="20" step="1" value="${state.maxInjectedEntries}" placeholder="7">
                    <div class="context-sheet-note">How many retrieved memory entries can be injected into the prompt at once.</div>
                </div>
                <div class="settings-item">
                    <label>Injection Target</label>
                    <div class="clickable-selector" id="memory-injection-target-selector">
                        <span>${state.injectionTarget === 'summary_macro' ? '{{summary}} macro' : 'Chat summary block'}</span>
                        <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                    </div>
                    <div class="context-sheet-note">Choose whether retrieved memory context follows the dedicated summary block path or the {{summary}} macro location.</div>
                </div>
                <div class="context-sheet-actions">
                    <button type="button" class="context-sheet-btn context-sheet-btn-secondary" id="memory-settings-cancel">Cancel</button>
                    <button type="button" class="context-sheet-btn context-sheet-btn-primary" id="memory-settings-save">Save</button>
                </div>
            `;

            content.querySelector('#memory-prompt-selector')?.addEventListener('click', () => {
                closeBottomSheet();
                const promptItems = getMemoryPromptOptions(settings).map(item => ({
                    label: item.label,
                    onClick: () => {
                        state.promptPreset = item.key;
                        closeBottomSheet();
                        setTimeout(() => showBottomSheet({ title: 'Memory Generation', content: renderSheet(), isSolid: true }), 50);
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
            });

            content.querySelector('#memory-prompt-preview-btn')?.addEventListener('click', () => {
                const options = getMemoryPromptOptions(settings);
                const selected = options.find(item => item.key === state.promptPreset) || options[0];
                closeBottomSheet();
                setTimeout(() => openMemoryPromptPreview(selected, {
                    onClose: () => openMemoryGenerationSettings({ ...state })
                }), 50);
            });

            content.querySelector('#memory-injection-target-selector')?.addEventListener('click', () => {
                closeBottomSheet();
                showBottomSheet({
                    title: 'Memory Injection Target',
                    items: [
                        {
                            label: 'Chat summary block',
                            onClick: () => {
                                state.injectionTarget = 'summary_block';
                                closeBottomSheet();
                                setTimeout(() => showBottomSheet({ title: 'Memory Generation', content: renderSheet(), isSolid: true }), 50);
                            }
                        },
                        {
                            label: '{{summary}} macro',
                            onClick: () => {
                                state.injectionTarget = 'summary_macro';
                                closeBottomSheet();
                                setTimeout(() => showBottomSheet({ title: 'Memory Generation', content: renderSheet(), isSolid: true }), 50);
                            }
                        }
                    ]
                });
            });

            content.querySelector('#memory-settings-cancel')?.addEventListener('click', () => {
                closeBottomSheet();
                setTimeout(() => openMemoryBooksSheet(), 50);
            });
            content.querySelector('#memory-settings-save')?.addEventListener('click', async () => {
                const endpointValue = content.querySelector('#memory-endpoint-input')?.value?.trim() || '';
                const apiKeyValue = content.querySelector('#memory-apikey-input')?.value || '';
                const tempValue = content.querySelector('#memory-temperature-input')?.value?.trim();
                const maxTokensValue = content.querySelector('#memory-max-tokens-input')?.value?.trim();
                const autoCreateEnabled = !!content.querySelector('#memory-auto-create-toggle')?.checked;
                const autoGenerateEnabled = !!content.querySelector('#memory-auto-generate-toggle')?.checked;
                const autoIntervalRaw = content.querySelector('#memory-auto-interval-input')?.value?.trim();
                const batchSizeRaw = content.querySelector('#memory-batch-size-input')?.value?.trim();
                const useDelayedAutomation = !!content.querySelector('#memory-delayed-automation-toggle')?.checked;
                const maxInjectedRaw = content.querySelector('#memory-max-injected-input')?.value?.trim();
                const autoIntervalValue = autoIntervalRaw !== '' ? Number(autoIntervalRaw) : 15;
                const batchSizeValue = batchSizeRaw !== '' ? Number(batchSizeRaw) : 3;
                const maxInjectedValue = maxInjectedRaw !== '' ? Number(maxInjectedRaw) : 7;
                await db.patchChatData(activeChatChar.id, (chatData) => {
                    const sid = activeChatChar.sessionId || chatData.currentId;
                    const mb = ensureSessionMemoryBook(chatData, sid);
                    if (!mb.settings) mb.settings = {};
                    const s = mb.settings;
                    s.generationSource = state.source;
                    s.generationUseCurrentModelOverride = false;
                    s.generationModel = state.model || '';
                    s.generationEndpoint = state.source === 'custom' ? endpointValue : '';
                    s.generationApiKey = state.source === 'custom' ? apiKeyValue : '';
                    s.generationTemperature = tempValue === '' ? null : Number(tempValue);
                    s.generationMaxTokens = maxTokensValue === ''
                        ? null
                        : Math.max(200, Math.min(32000, Number.isFinite(Number(maxTokensValue)) ? Math.round(Number(maxTokensValue)) : 2000));
                    s.autoCreateEnabled = autoCreateEnabled;
                    s.autoGenerateEnabled = autoGenerateEnabled;
                    s.autoCreateInterval = Number.isFinite(autoIntervalValue) && autoIntervalValue > 0 ? Math.max(1, Math.min(200, Math.round(autoIntervalValue))) : 15;
                    s.batchSize = Number.isFinite(batchSizeValue) && batchSizeValue > 0 ? Math.max(1, Math.min(50, Math.round(batchSizeValue))) : 3;
                    s.useDelayedAutomation = useDelayedAutomation;
                    s.maxInjectedEntries = Number.isFinite(maxInjectedValue) && maxInjectedValue > 0 ? Math.max(1, Math.min(20, Math.round(maxInjectedValue))) : 7;
                    s.injectionTarget = state.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block';
                    s.promptPreset = state.promptPreset || 'detailed_beats';
                    mb.updatedAt = Date.now();
                    saveMemorySettings(s);
                });
                closeBottomSheet();
                setTimeout(() => openMemoryBooksSheet(), 50);
            });

            return content;
        };

        showBottomSheet({
            title: 'Memory Generation',
            content: renderSheet(),
            isSolid: true
        });
    }

    async function openMemoryPromptManager() {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;
        const settings = getMemorySettings();
        if (!Array.isArray(settings.customPrompts)) settings.customPrompts = [];

        const content = document.createElement('div');
        content.className = 'context-sheet';
        const promptCards = settings.customPrompts.length
            ? settings.customPrompts.map(item => `
                <div class="memory-entry-card" data-prompt-id="${item.id}">
                    <div class="memory-entry-head">
                        <div>
                            <div class="memory-entry-title">${(item.name || 'Custom prompt').replace(/</g, '&lt;').replace(/>/g, '&gt;')}</div>
                            <div class="memory-entry-meta">custom prompt</div>
                        </div>
                        <div class="memory-draft-actions">
                            <button type="button" class="memory-entry-approve" data-prompt-edit="${item.id}">Edit</button>
                            <button type="button" class="memory-entry-delete" data-prompt-delete="${item.id}">Delete</button>
                        </div>
                    </div>
                    <div class="memory-entry-preview">${(item.prompt || '').replace(/</g, '&lt;').replace(/>/g, '&gt;').slice(0, 180)}</div>
                </div>
            `).join('')
            : '<div class="context-sheet-note">No custom prompts yet.</div>';

        content.innerHTML = `
            <div class="context-sheet-actions" style="margin-top: 0; margin-bottom: 12px;">
                <button type="button" class="context-sheet-btn context-sheet-btn-primary" id="memory-prompt-add">Add Prompt</button>
                <button type="button" class="context-sheet-btn context-sheet-btn-secondary" id="memory-prompt-close">Close</button>
            </div>
            <div class="memory-entry-list">${promptCards}</div>
        `;

        content.querySelector('#memory-prompt-add')?.addEventListener('click', () => {
            closeBottomSheet();
            setTimeout(() => openMemoryPromptEditor(), 50);
        });
        content.querySelector('#memory-prompt-close')?.addEventListener('click', () => closeBottomSheet());
        content.querySelectorAll('[data-prompt-id]').forEach(card => {
            card.addEventListener('click', (event) => {
                if (event.target.closest('button')) return;
                const promptId = card.getAttribute('data-prompt-id');
                const prompt = settings.customPrompts.find(item => item.id === promptId);
                if (!prompt) return;
                closeBottomSheet();
                setTimeout(() => openMemoryPromptPreview(
                    { label: prompt.name || 'Custom prompt', prompt: prompt.prompt || '' },
                    { onClose: openMemoryPromptManager }
                ), 50);
            });
        });
        content.querySelectorAll('[data-prompt-delete]').forEach(btn => {
            btn.addEventListener('click', async () => {
                const promptId = btn.getAttribute('data-prompt-delete');
                await db.patchChatData(activeChatChar.id, (chatData) => {
                    const sid = activeChatChar.sessionId || chatData.currentId;
                    const mb = ensureSessionMemoryBook(chatData, sid);
                    if (!mb.settings) mb.settings = {};
                    if (!Array.isArray(mb.settings.customPrompts)) mb.settings.customPrompts = [];
                    mb.settings.customPrompts = mb.settings.customPrompts.filter(item => item.id !== promptId);
                    if (mb.settings.promptPreset === promptId) mb.settings.promptPreset = 'detailed_beats';
                    mb.updatedAt = Date.now();
                    saveMemorySettings(mb.settings);
                });
                closeBottomSheet();
                setTimeout(() => openMemoryPromptManager(), 50);
            });
        });
        content.querySelectorAll('[data-prompt-edit]').forEach(btn => {
            btn.addEventListener('click', () => {
                const promptId = btn.getAttribute('data-prompt-edit');
                const prompt = settings.customPrompts.find(item => item.id === promptId);
                if (!prompt) return;
                closeBottomSheet();
                setTimeout(() => openMemoryPromptEditor(prompt), 50);
            });
        });

        showBottomSheet({ title: 'Generation Rules', content, isSolid: true });
    }

    async function openMemoryPromptEditor(existing = null) {
        const activeChatChar = getActiveChatChar();
        if (!activeChatChar) return;
        const chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
        const settings = memoryBook.settings || {};
        if (!Array.isArray(settings.customPrompts)) settings.customPrompts = [];

        const content = document.createElement('div');
        content.className = 'context-sheet';
        content.innerHTML = `
            <div class="settings-item">
                <label>Name</label>
                <input id="memory-prompt-name" type="text" value="${(existing?.name || '').replace(/"/g, '&quot;')}" placeholder="Prompt name">
            </div>
            <div class="settings-item">
                <label>Prompt</label>
                <textarea id="memory-prompt-text" rows="10" placeholder="Use {{history}}, {{user}}, {{char}}">${(existing?.prompt || '').replace(/</g, '&lt;').replace(/>/g, '&gt;')}</textarea>
            </div>
            <div class="context-sheet-actions">
                <button type="button" class="context-sheet-btn context-sheet-btn-secondary" id="memory-prompt-cancel">Cancel</button>
                <button type="button" class="context-sheet-btn context-sheet-btn-primary" id="memory-prompt-save">Save</button>
            </div>
        `;

        content.querySelector('#memory-prompt-cancel')?.addEventListener('click', () => closeBottomSheet());
        content.querySelector('#memory-prompt-save')?.addEventListener('click', async () => {
            const name = content.querySelector('#memory-prompt-name')?.value?.trim() || 'Custom prompt';
            const prompt = content.querySelector('#memory-prompt-text')?.value?.trim() || '';
            if (!prompt) {
                showToast('Prompt text is required');
                return;
            }
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
        });

        showBottomSheet({ title: existing ? 'Edit Prompt' : 'Add Prompt', content, isSolid: true });
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
