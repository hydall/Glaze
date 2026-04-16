<script setup>
import { ref, computed, onMounted, onUnmounted, watch, nextTick } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { lorebookState, initLorebookState, createLorebook, deleteLorebook, deleteLorebookEmbeddings, deleteLorebookEntryEmbedding, importSTLorebook, exportSTLorebook, flushLorebookSave, indexLorebookEntries, indexLorebookEntry, getEmbeddingStatus, getEmbeddingRecord } from '@/core/states/lorebookState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import HelpTip from '@/components/ui/HelpTip.vue';
import { showToast } from '@/core/states/toastState.js';

const sheet = ref(null);
const t = (key) => translations[currentLang.value]?.[key] || key;

const currentView = ref('list'); // list, entries, edit_entry
const activeLorebook = ref(null);
const activeEntry = ref(null);
const activeEntryIndex = ref(-1);



const filteredEntries = computed(() => {
    if (!activeLorebook.value) return [];
    if (!searchQuery.value) return activeLorebook.value.entries;
    const q = searchQuery.value.toLowerCase();
    return activeLorebook.value.entries.filter(e => 
        e.keys.some(k => k.toLowerCase().includes(q)) || 
        e.content.toLowerCase().includes(q)
    );
});

function handleCreateEntry() {
    if (!activeLorebook.value) return;
    const newEntry = {
        id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
        keys: [],
        content: '',
        enabled: true,
        secondary_keys: [],
        comment: '',
        order: 100,
        caseSensitive: null,
        matchWholeWords: null,
        useGroupScoring: null,
        vectorSearch: false
    };
    activeLorebook.value.entries.push(newEntry);
    selectEntry(newEntry, activeLorebook.value.entries.length - 1);

}

function selectEntry(entry, index) {
    activeEntry.value = entry;
    activeEntryIndex.value = index;
    currentView.value = 'edit_entry';
    checkEntryEmbeddingStatus();
}

function handleDeleteEntry(index) {
    if (!activeLorebook.value) return;
    activeLorebook.value.entries.splice(index, 1);
}

function handleEntryMenu(entry, index) {
    const entryError = failedEntryMap.value.get(entry.id);
    showBottomSheet({
        title: entry.comment || t('unnamed_entry'),
        items: [
            ...(entryError ? [{
                label: t('vector_status_error') || 'Index error',
                description: getEmbeddingErrorMessage(entryError),
                icon: '<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                iconColor: '#ff9500',
                onClick: () => {
                    closeBottomSheet();
                }
            }] : []),
            {
                label: t('action_export') || 'Export',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 12v7H5v-7H3v7c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2v-7h-2zm-6 .67l2.59-2.58L17 11.5l-5 5-5-5 1.41-1.41L11 12.67V3h2v9.67z"/></svg>',
                onClick: async () => {
                    closeBottomSheet();
                    const stLb = exportSTLorebook({ entries: [entry] });
                    const filename = (entry.comment || 'entry') + '.json';
                    await saveFile(filename, JSON.stringify(stLb, null, 2), 'application/json', 'lorebooks');
                }
            },
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    handleDeleteEntry(index);
                    closeBottomSheet();
                }
            }
        ]
    });
}

function updateEntryKeys(val) {
    if (activeEntry.value) {
        activeEntry.value.keys = val.split(',').map(k => k.trim()).filter(k => k);
    }
}

function updateEntrySecondaryKeys(val) {
    if (activeEntry.value) {
        activeEntry.value.secondary_keys = val.split(',').map(k => k.trim()).filter(k => k);
    }
}

function updateCharacterFilter(val) {
    if (activeEntry.value) {
        if (!activeEntry.value.characterFilter) {
            activeEntry.value.characterFilter = { names: [], isExclude: false };
        }
        activeEntry.value.characterFilter.names = val.split(',').map(n => n.trim()).filter(n => n);
    }
}

const characterFilterExclude = computed({
    get: () => activeEntry.value?.characterFilter?.isExclude || false,
    set: (val) => {
        if (activeEntry.value) {
            if (!activeEntry.value.characterFilter) {
                activeEntry.value.characterFilter = { names: [], isExclude: false };
            }
            activeEntry.value.characterFilter.isExclude = val;
        }
    }
});

const searchQuery = ref('');
const isGlobalSettingsExpanded = ref(false);
const indexingEntry = ref(false);
const entryEmbeddingStatus = ref('none');
const indexProgress = ref(null);
const indexedEntryIds = ref(new Set());
const failedEntryMap = ref(new Map());
const needsVectorReindex = ref(false);
const missingVectorCount = ref(0);

const failedEntries = computed(() => {
    if (!activeLorebook.value) return [];
    return activeLorebook.value.entries
        .filter(entry => failedEntryMap.value.has(entry.id))
        .map(entry => ({ entry, error: failedEntryMap.value.get(entry.id) }));
});

function getEntryDisplayName(entry) {
    return entry.comment || entry.keys?.[0] || t('unnamed_entry');
}

function getEmbeddingErrorLabel(error) {
    if (!error?.type) return t('vector_error_unknown');
    return t(`vector_error_${error.type}`) || error.message || t('vector_error_unknown');
}

function getEmbeddingErrorMessage(error) {
    return error?.message || getEmbeddingErrorLabel(error);
}

const allVectorEnabled = computed(() => {
    if (!activeLorebook.value || activeLorebook.value.entries.length === 0) return false;
    return activeLorebook.value.entries.every(e => e.vectorSearch);
});

function toggleAllVector() {
    if (!activeLorebook.value) return;
    const enable = !allVectorEnabled.value;
    activeLorebook.value.entries.forEach(e => { e.vectorSearch = enable; });
}

function resetAllEntriesToGlobal() {
    if (!activeLorebook.value) return;
    let changedCount = 0;
    activeLorebook.value.entries.forEach(entry => {
        const didChange = entry.caseSensitive !== null
            || entry.matchWholeWords !== null
            || entry.useGroupScoring !== null
            || entry.position !== 'matchGlobal';
        entry.caseSensitive = null;
        entry.matchWholeWords = null;
        entry.useGroupScoring = null;
        entry.position = 'matchGlobal';
        if (didChange) changedCount += 1;
    });
    showToast(changedCount > 0
        ? `${changedCount} entries reset to ${t('match_global')}`
        : 'All entries already match global settings');
}

const currentContext = ref({ charId: null, chatId: null });

const allCharacters = ref([]);
const allSessions = ref([]);

import { db } from '@/utils/db.js';

async function loadPickerData() {
    const [chars, chatsData] = await Promise.all([
        db.getAll('characters'),
        db.getChats()
    ]);
    allCharacters.value = chars || [];
    
    const sessions = [];
    if (chatsData) {
        Object.keys(chatsData).forEach(charId => {
            const char = allCharacters.value.find(c => c.id === charId);
            const data = chatsData[charId];
            if (!data) return;
            const sess = data.sessions || (Array.isArray(data) ? { 1: data } : {});
            Object.keys(sess).forEach(sid => {
                sessions.push({
                    id: `${charId}_${sid}`,
                    charName: char?.name || charId,
                    sessionId: sid
                });
            });
        });
    }
    allSessions.value = sessions;
}

function getActivationState(lb) {
    const isGlobal = !!lb.enabled;
    const isChar = !!(currentContext.value.charId && lorebookState.activations?.character?.[currentContext.value.charId]?.includes(lb.id));
    const isChat = !!(currentContext.value.chatId && lorebookState.activations?.chat?.[currentContext.value.chatId]?.includes(lb.id));

    // Priority for "applies here": chat > character > global
    if (isChat) return 'chat';
    if (isChar) return 'character';
    if (isGlobal) return 'global';
    return 'disabled';
}

function openConnectionManager(lb) {
    window.dispatchEvent(new CustomEvent('open-connections', { detail: { type: 'lorebook', id: lb.id, name: lb.name } }));
}

function getLorebookConnectionCounts(lbId) {
    let chars = 0;
    let chats = 0;

    const charMap = lorebookState.activations?.character || {};
    Object.values(charMap).forEach((ids) => {
        if (Array.isArray(ids) && ids.includes(lbId)) chars++;
    });

    const chatMap = lorebookState.activations?.chat || {};
    Object.values(chatMap).forEach((ids) => {
        if (Array.isArray(ids) && ids.includes(lbId)) chats++;
    });

    return { chars, chats };
}

function getActivationLabel(scope) {
    if (scope === 'global') return t('label_global') || 'Global';
    if (scope === 'character') return t('header_characters') || 'Character';
    if (scope === 'chat') return t('tab_dialogs') || 'Chat';
    return t('off') || 'Off';
}

function getActivationContextHint(scope) {
    if (scope === 'character') {
        const c = allCharacters.value.find((x) => x.id === currentContext.value.charId);
        return c?.name || currentContext.value.charId || '';
    }
    if (scope === 'chat') {
        const s = allSessions.value.find((x) => x.id === currentContext.value.chatId);
        return s ? `${s.charName} #${s.sessionId}` : (currentContext.value.chatId || '');
    }
    return '';
}

function isCharActive(lbId, charId) {
    if (!charId) return false;
    return !!lorebookState.activations?.character?.[charId]?.includes(lbId);
}

function selectChat(chatId) {
    currentContext.value.chatId = chatId;
}

function openOptionSelector({ title, options, currentValue, onSelect }) {
    const items = options.map(opt => ({
        label: opt.label,
        icon: currentValue === opt.value ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
        onClick: () => {
            onSelect(opt.value);
            closeBottomSheet();
        }
    }));
    showBottomSheet({ title, items });
}

function getReserveModeLabel() {
    return lorebookState.globalSettings.reserveMode === 'tokens'
        ? (t('label_budget_cap') || 'Exact tokens')
        : (t('label_context_percent') || 'Percent');
}

// activation now managed via LorebookConnectionsSheet

// --- Lifecycle ---

async function handleIndexEntry() {
    if (!activeEntry.value || !activeLorebook.value) return;
    indexingEntry.value = true;
    try {
        await indexLorebookEntry(activeEntry.value, activeLorebook.value.id);
    } catch (e) {
        console.warn('Failed to index entry:', e);
    } finally {
        await loadIndexedStatuses();
        await checkEntryEmbeddingStatus();
        indexingEntry.value = false;
    }
}

async function handleIndexAllEntries() {
    if (!activeLorebook.value) return;
    indexingEntry.value = true;
    indexProgress.value = null;
    try {
        const result = await indexLorebookEntries(activeLorebook.value.id, (done, total) => {
            indexProgress.value = { done, total };
        });
        indexProgress.value = result;
        await loadIndexedStatuses();
    } catch (e) {
        console.warn('Failed to index lorebook:', e);
    } finally {
        indexingEntry.value = false;
    }
}

async function handleRetryFailedEntries() {
    if (!activeLorebook.value) return;
    indexingEntry.value = true;
    indexProgress.value = null;
    try {
        const result = await indexLorebookEntries(activeLorebook.value.id, (done, total) => {
            indexProgress.value = { done, total };
        }, { retryFailedOnly: true });
        indexProgress.value = result;
        await loadIndexedStatuses();
        await updateVectorReindexNotice();
    } catch (e) {
        console.warn('Failed to retry failed lorebook entries:', e);
    } finally {
        indexingEntry.value = false;
    }
}

async function handleDeleteAllIndexes() {
    if (!activeLorebook.value) return;
    indexingEntry.value = true;
    indexProgress.value = null;
    try {
        await deleteLorebookEmbeddings(activeLorebook.value.id);
        indexedEntryIds.value = new Set();
        entryEmbeddingStatus.value = 'none';
        await updateVectorReindexNotice();
    } catch (e) {
        console.warn('Failed to delete lorebook embeddings:', e);
    } finally {
        indexingEntry.value = false;
    }
}

async function handleConstantToggle(isEnabled) {
    if (!activeEntry.value?.id) return;
    if (!isEnabled) return;

    activeEntry.value.vectorSearch = false;
    await deleteLorebookEntryEmbedding(activeEntry.value.id);
    await loadIndexedStatuses();
    await checkEntryEmbeddingStatus();
    await updateVectorReindexNotice();
}

function openEntriesMenu() {
    if (!activeLorebook.value) return;
    const allVector = activeLorebook.value.entries.every(e => e.vectorSearch);
    showBottomSheet({
        title: t('section_entries_actions') || 'Entries Actions',
        items: [
            {
                label: allVector ? (t('action_disable_vector_all') || 'Disable Vector Search All') : (t('action_enable_vector_all') || 'Enable Vector Search All'),
                icon: '<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>',
                onClick: () => {
                    activeLorebook.value.entries.forEach(e => { e.vectorSearch = !allVector; });
                    closeBottomSheet();
                }
            },
            {
                label: t('action_index_all') || 'Index All Vector Entries',
                icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                onClick: async () => {
                    closeBottomSheet();
                    await handleIndexAllEntries();
                }
            },
            {
                label: t('action_delete_indexes') || 'Delete Vector Indexes',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    closeBottomSheet();
                    await handleDeleteAllIndexes();
                }
            }
        ]
    });
}

async function checkEntryEmbeddingStatus() {
    if (activeEntry.value?.vectorSearch && activeEntry.value?.id) {
        entryEmbeddingStatus.value = await getEmbeddingStatus(activeEntry.value.id);
    } else {
        entryEmbeddingStatus.value = 'none';
    }
}

async function updateVectorReindexNotice() {
    const vectorEntries = lorebookState.lorebooks.flatMap(lb =>
        (lb.entries || []).filter(entry => entry.enabled !== false && entry.vectorSearch && entry.id)
    );

    if (vectorEntries.length === 0) {
        missingVectorCount.value = 0;
        needsVectorReindex.value = false;
        return;
    }

    let missing = 0;
    for (const entry of vectorEntries) {
        const status = await getEmbeddingStatus(entry.id);
        if (status !== 'indexed') missing++;
    }

    missingVectorCount.value = missing;
    needsVectorReindex.value = missing > 0;
}

async function handleSyncDataRefreshed() {
    await updateVectorReindexNotice();
    if (activeLorebook.value) {
        await loadIndexedStatuses();
    }
}
onMounted(async () => {
    await initLorebookState();
    loadPickerData();
    await updateVectorReindexNotice();
    window.addEventListener('sync-data-refreshed', handleSyncDataRefreshed);
});

onUnmounted(() => {
    window.removeEventListener('sync-data-refreshed', handleSyncDataRefreshed);
});

// --- Navigation ---

function open(context = {}) {
    currentContext.value = {
        charId: context.charId || null,
        chatId: context.chatId || null
    };
    loadPickerData();
    if (!sheet.value?.isVisible) {
        currentView.value = 'list';
        searchQuery.value = '';
    }
    sheet.value?.open();
}

function openLorebook(id) {
    const lb = lorebookState.lorebooks.find(l => l.id === id);
    if (lb) {
        selectLorebook(lb);
        sheet.value?.open();
    }
}

function openEntry(lbId, entryId) {
    const lb = lorebookState.lorebooks.find(l => l.id === lbId);
    if (!lb) return;
    
    const entryIdx = lb.entries.findIndex(e => e.id === entryId);
    if (entryIdx === -1) return;
    
    currentContext.value = { charId: null, chatId: null };
    loadPickerData();
    sheet.value?.open();
    
    activeLorebook.value = lb;
    selectEntry(lb.entries[entryIdx], entryIdx);
}

function close() {
    sheet.value?.close();
}

function goBack() {
    if (currentView.value === 'edit_entry') {
        currentView.value = 'entries';
        activeEntry.value = null;
        activeEntryIndex.value = -1;
    } else if (currentView.value === 'entries') {
        currentView.value = 'list';
        activeLorebook.value = null;
    } else {
        close();
    }
}

// --- Lorebook Management ---

function handleCreateLorebook() {
    showBottomSheet({
        title: t('new_lorebook') || 'New World Info',
        input: {
            placeholder: t('placeholder_name') || 'Name',
            confirmLabel: t('btn_create') || 'Create',
            onConfirm: (name) => {
                const lb = createLorebook(name);
                closeBottomSheet();
                selectLorebook(lb);
            }
        }
    });
}

function handleImportLorebook() {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.json';
    input.onchange = async (e) => {
        const file = e.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = async (ev) => {
            try {
                const json = JSON.parse(ev.target.result);
                await importSTLorebook(json, file.name);
            } catch (err) {
                console.error(err);
                alert('Error importing lorebook: ' + err.message);
            }
        };
        reader.readAsText(file);
    };
    input.click();
}

function openLorebookMenu() {
    showBottomSheet({
        title: t('menu_lorebooks') || 'World Info',
        items: [
            {
                label: t('action_create_new') || 'Create New',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => { handleCreateLorebook(); }
            },
            {
                label: t('action_import') || 'Import',
                icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                onClick: () => { closeBottomSheet(); handleImportLorebook(); }
            }
        ]
    });
}


function selectLorebook(lb) {
    activeLorebook.value = lb;
    currentView.value = 'entries';
    searchQuery.value = '';
    indexProgress.value = null;
    loadIndexedStatuses();
    updateVectorReindexNotice();
}

watch(() => lorebookState.lorebooks, () => {
    updateVectorReindexNotice();
}, { deep: true });

watch(() => activeEntry.value?.constant, async (isConstant, wasConstant) => {
    if (!activeEntry.value || isConstant === wasConstant) return;
    await handleConstantToggle(isConstant);
});

async function loadIndexedStatuses() {
    if (!activeLorebook.value) return;
    const ids = new Set();
    const failed = new Map();
    for (const entry of activeLorebook.value.entries) {
        if (entry.vectorSearch && entry.id) {
            const status = await getEmbeddingStatus(entry.id);
            if (status === 'indexed') ids.add(entry.id);
            if (status === 'error') {
                const record = await getEmbeddingRecord(entry.id);
                if (record?.error) failed.set(entry.id, record.error);
            }
        }
    }
    indexedEntryIds.value = ids;
    failedEntryMap.value = failed;
}

function handleLorebookMenu(lb) {
    showBottomSheet({
        title: lb.name,
        items: [
            {
                label: t('action_export') || 'Export',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 12v7H5v-7H3v7c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2v-7h-2zm-6 .67l2.59-2.58L17 11.5l-5 5-5-5 1.41-1.41L11 12.67V3h2v9.67z"/></svg>',
                onClick: async () => {
                    closeBottomSheet();
                    const stLb = exportSTLorebook(lb);
                    const filename = (lb.name || 'lorebook') + '.json';
                    await saveFile(filename, JSON.stringify(stLb, null, 2), 'application/json', 'lorebooks');
                }
            },
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    deleteLorebook(lb.id);
                    closeBottomSheet();
                }
            }
        ]
    });
}



const sheetTitle = computed(() => {
    if (currentView.value === 'list') return t('menu_lorebooks');
    if (currentView.value === 'entries') return activeLorebook.value?.name;
    if (currentView.value === 'edit_entry') return activeEntry.value?.comment || t('unnamed_entry');
    return '';
});

const showBackBtn = computed(() => currentView.value !== 'list');

const sheetActions = computed(() => {
    const actions = [];
    if (currentView.value === 'list') {
        actions.push({ icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>', onClick: openLorebookMenu });
    } else if (currentView.value === 'entries') {
        actions.push({ icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>', onClick: handleCreateEntry });
        actions.push({ icon: '<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>', onClick: openEntriesMenu });
    }
    return actions;
});

defineExpose({ open, openEntry, close, openLorebook });
</script>

<template>
    <SheetView ref="sheet" :z-index="11000" :title="sheetTitle" :show-back="showBackBtn" :actions="sheetActions" @back="goBack" @close="flushLorebookSave">
        <template #header-title>
            <div v-if="currentView === 'list'" class="clickable-no-drag" style="display:flex; align-items:center;">
                <HelpTip term="lorebook" />
            </div>
        </template>
        <template #header-right>
            <div v-if="currentView === 'edit_entry'" class="header-toggle" style="align-items: center;">
                 <input type="checkbox" v-model="activeEntry.enabled" class="vk-switch">
            </div>
        </template>
        <template #header-bottom v-if="currentView === 'entries'">
            <div class="search-bar" style="margin: 0 16px 12px;">
                <svg viewBox="0 0 24 24" class="search-icon"><path d="M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>
                <input type="text" v-model="searchQuery" :placeholder="t('placeholder_search_lore')">
            </div>
        </template>
        
        <div class="lb-sheet-body">
            <!-- View: List -->
            <div v-if="currentView === 'list'" class="lb-list">
                
                <div class="menu-group global-settings-group first-group">
                    <div class="section-header clickable" @click="isGlobalSettingsExpanded = !isGlobalSettingsExpanded" style="display:flex; justify-content:space-between; align-items:center;">
                        <span>{{ t('section_global_settings') }}</span>
                        <svg :class="{ 'rotated': isGlobalSettingsExpanded }" style="width:20px; height:20px; transition: transform 0.3s;" viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z" fill="currentColor"/></svg>
                    </div>
                    
                    <div v-if="isGlobalSettingsExpanded" class="global-settings-content">
                        <div class="settings-row">
                            <div class="settings-col">
                                <label>{{ t('label_scan_depth_lore') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.scanDepth">
                            </div>
                             <div class="settings-col">
                                <label>{{ t('label_lorebook_reserve_mode') }}</label>
                                <div class="clickable-selector" @click="openOptionSelector({
                                    title: t('label_lorebook_reserve_mode'),
                                    options: [
                                        { value: 'percent', label: t('label_context_percent') || 'Percent' },
                                        { value: 'tokens', label: t('label_budget_cap') || 'Exact tokens' }
                                    ],
                                    currentValue: lorebookState.globalSettings.reserveMode,
                                    onSelect: (v) => lorebookState.globalSettings.reserveMode = v
                                })">
                                    <span>{{ getReserveModeLabel() }}</span>
                                    <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                                </div>
                            </div>
                        </div>
                        <div class="settings-row">
                            <div class="settings-col">
                                <label>{{ lorebookState.globalSettings.reserveMode === 'tokens' ? (t('label_budget_cap') || 'Exact tokens') : t('label_lorebook_reserve_percent') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.reserveValue" :min="lorebookState.globalSettings.reserveMode === 'tokens' ? 0 : 1" :max="lorebookState.globalSettings.reserveMode === 'tokens' ? undefined : 100">
                            </div>
                             <div class="settings-col">
                                <label>{{ t('label_min_activations') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.minActivations">
                            </div>
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_injection_position') }}</label>
                            <div class="clickable-selector" @click="openOptionSelector({
                                title: t('label_injection_position'),
                                options: [
                                    { value: 'worldInfoBefore', label: '@worldInfoBefore (' + t('pos_before_char') + ')' },
                                    { value: 'worldInfoAfter', label: '@worldInfoAfter (' + t('pos_after_char') + ')' },
                                    { value: 'lorebooksMacro', label: '{{lorebooks}}' }
                                ],
                                currentValue: lorebookState.globalSettings.injectionPosition,
                                onSelect: (v) => lorebookState.globalSettings.injectionPosition = v
                            })">
                                <span>{{ lorebookState.globalSettings.injectionPosition === 'worldInfoAfter' ? '@worldInfoAfter' : lorebookState.globalSettings.injectionPosition === 'lorebooksMacro' ? '{' + '{lorebooks}' + '}' : '@worldInfoBefore' }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                        <div class="settings-row">
                            <div class="settings-col">
                                <label>{{ t('label_max_depth') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.maxDepth">
                            </div>
                             <div class="settings-col">
                                <label>{{ t('label_max_recursion') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.maxRecursionSteps">
                            </div>
                        </div>

                         <div class="settings-item">
                            <label>{{ t('label_insertion_strategy') }}</label>
                            <div class="clickable-selector" @click="openOptionSelector({
                                title: t('label_insertion_strategy'),
                                options: [
                                    { value: 'character_first', label: t('strategy_char_first') },
                                    { value: 'global_first', label: t('strategy_global_first') }
                                ],
                                currentValue: lorebookState.globalSettings.insertionStrategy,
                                onSelect: (v) => lorebookState.globalSettings.insertionStrategy = v
                            })">
                                <span>{{ lorebookState.globalSettings.insertionStrategy === 'character_first' ? t('strategy_char_first') : t('strategy_global_first') }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>

                        <div class="settings-item-checkbox small-checkbox">
                             <label>{{ t('label_include_names') }}</label>
                             <input type="checkbox" v-model="lorebookState.globalSettings.includeNames" class="vk-switch small-switch">
                        </div>
                        <div class="settings-item-checkbox small-checkbox">
                             <label>{{ t('label_recursive_scan') }}</label>
                             <input type="checkbox" v-model="lorebookState.globalSettings.recursiveScan" class="vk-switch small-switch">
                        </div>
                        <div class="settings-item-checkbox small-checkbox">
                             <label>{{ t('label_case_sensitive_global') }}</label>
                             <input type="checkbox" v-model="lorebookState.globalSettings.caseSensitive" class="vk-switch small-switch">
                        </div>
                         <div class="settings-item">
                             <label>{{ t('label_match_whole_words_global') }}</label>
                             <div class="clickable-selector" @click="openOptionSelector({
                                 title: t('label_match_whole_words_global'),
                                 options: [
                                     { value: false, label: t('off') },
                                     { value: true, label: t('match_whole_words_st') },
                                     { value: 'glaze', label: t('match_whole_words_glaze') }
                                 ],
                                 currentValue: lorebookState.globalSettings.matchWholeWords,
                                 onSelect: (v) => lorebookState.globalSettings.matchWholeWords = v
                             })">
                                 <span>{{ lorebookState.globalSettings.matchWholeWords === 'glaze' ? t('match_whole_words_glaze') : (lorebookState.globalSettings.matchWholeWords ? t('match_whole_words_st') : t('off')) }}</span>
                                 <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                             </div>
                        </div>
                    </div>
                </div>

                <div v-if="lorebookState.lorebooks.length === 0" class="empty-state">
                    <svg class="empty-icon" viewBox="0 0 24 24"><path d="M18 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 4h5v8l-2.5-1.5L6 12V4z"/></svg>
                    <div class="empty-text">{{ t('no_lorebooks') }}</div>
                    <div class="empty-subtext">{{ t('empty_lorebooks_desc') }}</div>
                    <div class="empty-actions">
                        <button class="vk-btn-action" @click="handleCreateLorebook">{{ t('btn_create') }}</button>
                        <button class="vk-btn-action secondary" @click="handleImportLorebook">{{ t('action_import') }}</button>
                    </div>
                </div>
                
                <div v-else class="list-container">
                    <template v-for="lb in lorebookState.lorebooks" :key="lb.id">
                        <div class="lb-item-wrapper">
                            <div class="lb-item" @click="selectLorebook(lb)">
                                <div class="lb-info">
                                    <div class="lb-name">{{ lb.name }}</div>
                                    <div class="lb-meta">{{ lb.entries.length }} {{ t('label_entries') }}</div>
                                    <div class="lb-conn-badges" style="margin-top: 6px;">
                                        <span v-if="lb.enabled" class="conn-badge global">{{ t('label_global') || 'Global' }}</span>
                                        <span v-if="getLorebookConnectionCounts(lb.id).chars" class="conn-badge char">{{ getLorebookConnectionCounts(lb.id).chars }} {{ t('header_characters') || 'chars' }}</span>
                                        <span v-if="getLorebookConnectionCounts(lb.id).chats" class="conn-badge chat">{{ getLorebookConnectionCounts(lb.id).chats }} {{ t('tab_dialogs') || 'chats' }}</span>
                                    </div>
                                </div>
                                <div class="lb-actions">
                                    <button class="activation-btn" :class="getActivationState(lb)" @click.stop="openConnectionManager(lb)">
                                        <svg viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>
                                    </button>
                                    <div class="action-btn more" @click.stop="handleLorebookMenu(lb)">
                                        <svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </template>
                </div>
            </div>

            <!-- View: Entries -->
            <div v-else-if="currentView === 'entries'" class="view-wrapper">

                <div v-if="needsVectorReindex" class="vector-reindex-banner">
                    <div class="vector-reindex-copy">
                        <div class="vector-reindex-title">{{ t('vector_reindex_title') || 'Vector entries need reindexing' }}</div>
                        <div class="vector-reindex-text">{{ (t('vector_reindex_desc') || '{count} vector entries were restored from sync without local embeddings. Run Index All to rebuild them.').replace('{count}', missingVectorCount) }}</div>
                    </div>
                    <button class="vk-btn-action secondary" @click="handleIndexAllEntries" :disabled="indexingEntry">{{ t('btn_index_all') }}</button>
                </div>

                <div v-if="activeLorebook && activeLorebook.entries.length > 0" class="entries-toolbar-wrap">
                    <div class="entries-toolbar">
                        <button class="toolbar-btn" @click="toggleAllVector">
                            <svg viewBox="0 0 24 24" class="toolbar-icon"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>
                            <span>{{ allVectorEnabled ? t('btn_disable_vector_all') : t('btn_enable_vector_all') }}</span>
                        </button>
                        <button class="toolbar-btn secondary" @click="resetAllEntriesToGlobal">
                            <svg viewBox="0 0 24 24" class="toolbar-icon"><path d="M12 5V2L8 6l4 4V7c3.31 0 6 2.69 6 6a6 6 0 0 1-10.24 4.24l-1.42 1.42A8 8 0 1 0 12 5z"/></svg>
                            <span>{{ t('match_global') }}</span>
                        </button>
                        <button class="toolbar-btn" @click="handleIndexAllEntries" :disabled="indexingEntry">
                            <svg viewBox="0 0 24 24" class="toolbar-icon"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>
                            <span v-if="indexingEntry && indexProgress?.total">{{ t('index_progress').replace('{done}', indexProgress.done).replace('{total}', indexProgress.total) }}</span>
                            <span v-else-if="indexingEntry">{{ t('btn_indexing') }}</span>
                            <span v-else>{{ t('btn_index_all') }}</span>
                        </button>
                        <button v-if="failedEntries.length > 0" class="toolbar-btn secondary" @click="handleRetryFailedEntries" :disabled="indexingEntry">
                            <svg viewBox="0 0 24 24" class="toolbar-icon"><path d="M12 6V3L8 7l4 4V8c2.76 0 5 2.24 5 5a5 5 0 0 1-8.9 3.1l-1.42 1.42A7 7 0 1 0 12 6z"/></svg>
                            <span>{{ t('btn_retry_failed') }}</span>
                        </button>
                    </div>
                    <div v-if="!indexingEntry && indexProgress && indexProgress.indexed !== undefined" class="index-result-block">
                        <span class="index-result-line">{{ t('index_done').replace('{count}', indexProgress.indexed) }}</span>
                        <span v-if="indexProgress.skipped > 0" class="index-result-line">{{ t('index_skipped').replace('{skipped}', indexProgress.skipped) }}</span>
                        <span v-if="indexProgress.failed > 0" class="index-result-line index-result-error">{{ t('index_failed').replace('{failed}', indexProgress.failed) }}</span>
                    </div>
                    <div v-if="failedEntries.length > 0" class="failed-entries-block">
                        <div class="failed-entries-title">{{ t('vector_failed_entries_title').replace('{count}', failedEntries.length) }}</div>
                        <div v-for="item in failedEntries" :key="item.entry.id" class="failed-entry-row">
                            <div class="failed-entry-copy">
                                <div class="failed-entry-name">{{ getEntryDisplayName(item.entry) }}</div>
                                <div class="failed-entry-reason">{{ getEmbeddingErrorLabel(item.error) }}</div>
                                <div v-if="item.error?.message && item.error.message !== getEmbeddingErrorLabel(item.error)" class="failed-entry-message">{{ item.error.message }}</div>
                            </div>
                        </div>
                    </div>
                </div>

                <div v-if="filteredEntries.length === 0" class="empty-state">
                    <div class="empty-text">{{ t('no_entries_found') }}</div>
                </div>
                <div v-else class="list-container">
                    <div v-for="(entry, index) in filteredEntries" :key="index" class="lb-item" @click="selectEntry(entry, index)">
                        <div class="lb-info">
                             <div class="lb-name-row">
                                 <span class="lb-name">{{ entry.comment || t('unnamed_entry') }}</span>
                                 <span v-if="entry.vectorSearch" class="conn-badge vector">vec</span>
                                 <span v-if="entry.vectorSearch && indexedEntryIds.has(entry.id)" class="conn-badge indexed">idx</span>
                                 <span v-if="entry.vectorSearch && failedEntryMap.has(entry.id)" class="conn-badge errored">err</span>
                             </div>
                            <div class="lb-meta preview-text">{{ entry.keys.join(', ') || t('no_keys') }}</div>
                        </div>
                        <div class="lb-actions">
                            <input type="checkbox" class="vk-switch small-switch" v-model="entry.enabled" @click.stop>
                            <div class="action-btn more" @click.stop="handleEntryMenu(entry, index)">
                                <svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- View: Edit Entry -->
            <div v-else-if="currentView === 'edit_entry'" class="lb-editor">
                <div class="editor-scroll">
                    <div class="menu-group first-group">
                        <div class="section-header">{{ t('section_activation_logic') }} <HelpTip term="lorebook-keys"/></div>
                        <div v-if="activeEntry.vectorSearch" class="settings-desc" style="padding:8px 0;color:var(--text-gray);">{{ t('desc_vector_search_replaces_keys') }}</div>
                        <div v-if="!activeEntry.vectorSearch && !activeEntry.constant">
                        <div class="settings-item">
                                <label>{{ t('label_primary_keys') }} <span class="hint">{{ t('hint_comma_separated') }}</span></label>
                                <input type="text" :value="activeEntry.keys.join(', ')" @input="updateEntryKeys($event.target.value)" :placeholder="t('placeholder_keys')">
                            </div>
                            <div class="settings-item">
                                <label>{{ t('label_logic_mode') }}</label>
                                <div class="clickable-selector" @click="openOptionSelector({
                                    title: t('label_logic_mode'),
                                    options: [
                                        { value: 4, label: t('logic_primary_only') },
                                        { value: 0, label: t('logic_and_any') },
                                        { value: 1, label: t('logic_and_all') },
                                        { value: 2, label: t('logic_not_any') },
                                        { value: 3, label: t('logic_not_all') }
                                    ],
                                    currentValue: activeEntry.selectiveLogic,
                                    onSelect: (v) => activeEntry.selectiveLogic = v
                                })">
                                    <span>{{ [t('logic_and_any'), t('logic_and_all'), t('logic_not_any'), t('logic_not_all'), t('logic_primary_only')][activeEntry.selectiveLogic] }}</span>
                                    <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                                </div>
                            </div>
                            
                        <div class="settings-item">
                            <label>{{ t('label_case_sensitive') }}</label>
                            <div class="clickable-selector" @click="openOptionSelector({
                                title: t('label_case_sensitive'),
                                options: [
                                    { value: 'null', label: t('match_global') },
                                    { value: 'true', label: t('on') },
                                    { value: 'false', label: t('off') }
                                ],
                                currentValue: typeof activeEntry.caseSensitive !== 'boolean' ? 'null' : activeEntry.caseSensitive.toString(),
                                onSelect: (v) => activeEntry.caseSensitive = v === 'null' ? null : (v === 'true')
                            })">
                                <span>{{ typeof activeEntry.caseSensitive !== 'boolean' ? t('match_global') : (activeEntry.caseSensitive ? t('on') : t('off')) }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_match_whole_words') }}</label>
                            <div class="clickable-selector" @click="openOptionSelector({
                                title: t('label_match_whole_words'),
                                options: [
                                    { value: 'null', label: t('match_global') },
                                    { value: 'true', label: t('on') },
                                    { value: 'false', label: t('off') }
                                ],
                                currentValue: typeof activeEntry.matchWholeWords !== 'boolean' ? 'null' : activeEntry.matchWholeWords.toString(),
                                onSelect: (v) => activeEntry.matchWholeWords = v === 'null' ? null : (v === 'true')
                            })">
                                <span>{{ typeof activeEntry.matchWholeWords !== 'boolean' ? t('match_global') : (activeEntry.matchWholeWords ? t('on') : t('off')) }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_group_scoring') }}</label>
                            <div class="clickable-selector" @click="openOptionSelector({
                                title: t('label_group_scoring'),
                                options: [
                                    { value: 'null', label: t('match_global') },
                                    { value: 'true', label: t('on') },
                                    { value: 'false', label: t('off') }
                                ],
                                currentValue: typeof activeEntry.useGroupScoring !== 'boolean' ? 'null' : activeEntry.useGroupScoring.toString(),
                                onSelect: (v) => activeEntry.useGroupScoring = v === 'null' ? null : (v === 'true')
                            })">
                                <span>{{ typeof activeEntry.useGroupScoring !== 'boolean' ? t('match_global') : (activeEntry.useGroupScoring ? t('on') : t('off')) }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                        </div>

                        <div class="settings-item" v-if="activeEntry.selectiveLogic !== 4">
                            <label>{{ t('label_secondary_keys') }} <span class="hint">{{ t('hint_optional') }}</span></label>
                            <input type="text" :value="activeEntry.secondary_keys?.join(', ')" @input="updateEntrySecondaryKeys($event.target.value)" :placeholder="t('placeholder_filters')">
                        </div>
                        </div>
                        </div>

                    <div class="menu-group">
                    <div class="section-header">{{ t('section_content_properties') }}</div>
                        <div class="settings-item">
                            <label>{{ t('label_content') }}</label>
                            <textarea v-model="activeEntry.content" rows="12" :placeholder="t('placeholder_lore_content')"></textarea>
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_comment') }}</label>
                            <input type="text" v-model="activeEntry.comment" :placeholder="t('placeholder_comment')">
                        </div>
                </div>

                <div class="menu-group">
                    <div class="section-header">{{ t('section_injection_rules') }} <HelpTip term="lorebook-budget"/></div>
                         <div class="settings-item">
                            <label>{{ t('label_injection_position') }}</label>
                            <div class="clickable-selector" @click="openOptionSelector({
                                title: t('label_injection_position'),
                                options: [
                                    { value: 'matchGlobal', label: t('match_global') },
                                    { value: 'worldInfoBefore', label: '@worldInfoBefore (' + t('pos_before_char') + ')' },
                                    { value: 'worldInfoAfter', label: '@worldInfoAfter (' + t('pos_after_char') + ')' },
                                    { value: 'lorebooksMacro', label: '{{lorebooks}}' }
                                ],
                                currentValue: activeEntry.position,
                                onSelect: (v) => activeEntry.position = v
                            })">
                                <span>{{ activeEntry.position === 'worldInfoAfter' ? '@worldInfoAfter' : activeEntry.position === 'lorebooksMacro' ? '{' + '{lorebooks}' + '}' : activeEntry.position === 'matchGlobal' ? t('match_global') : '@worldInfoBefore' }}</span>
                                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                            </div>
                            <div class="settings-desc" style="margin-top: 6px;">{{ t('hint_lorebook_macro_override') }}</div>
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_order_priority') }} <span class="hint">{{ t('hint_lower_first') }}</span></label>
                            <input type="number" v-model="activeEntry.order" placeholder="100">
                        </div>
                </div>

                <div class="menu-group">
                    <div class="section-header">{{ t('section_scan_recursion') }} <HelpTip term="lorebook-recursion"/></div>
                        <div class="settings-item">
                            <label>{{ t('label_scan_depth_lore') }} <span class="hint">{{ t('hint_messages_back') }}</span></label>
                            <input type="number" v-model="activeEntry.scanDepth" placeholder="1">
                        </div>
                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('label_prevent_recursion') }}</label>
                            </div>
                            <input type="checkbox" v-model="activeEntry.preventRecursion" class="vk-switch">
                        </div>
                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('label_delay_until_recursion') }}</label>
                            </div>
                            <input type="checkbox" v-model="activeEntry.delayUntilRecursion" class="vk-switch">
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_probability') }} <HelpTip term="lorebook-probability"/></label>
                            <input type="number" v-model="activeEntry.probability" placeholder="100" min="0" max="100">
                        </div>
                </div>

                <div class="menu-group">
                    <div class="section-header">{{ t('section_vector_search') }}</div>
                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('label_constant') }} <span class="hint">{{ t('hint_always_active') }}</span></label>
                                <div class="settings-desc">{{ t('desc_constant_disables_vector') }}</div>
                            </div>
                            <input type="checkbox" v-model="activeEntry.constant" class="vk-switch">
                        </div>
                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('label_vector_search') }}</label>
                                <div class="settings-desc">{{ activeEntry.constant ? t('desc_vector_disabled_for_constant') : t('desc_vector_search_entry') }}</div>
                            </div>
                            <input type="checkbox" v-model="activeEntry.vectorSearch" class="vk-switch" :disabled="activeEntry.constant">
                        </div>
                        <div v-if="activeEntry.vectorSearch && !activeEntry.constant" class="settings-item">
                            <button class="vk-btn-action" style="width:100%;" @click="handleIndexEntry" :disabled="indexingEntry">
                                {{ indexingEntry ? t('btn_indexing') : t('btn_index_entry') }}
                            </button>
                            <div v-if="entryEmbeddingStatus === 'indexed'" class="settings-desc" style="margin-top:8px; color: #34c759;">{{ t('entry_indexed') }}</div>
                            <div v-if="entryEmbeddingStatus === 'none'" class="settings-desc" style="margin-top:8px; color: var(--text-gray);">{{ t('entry_not_indexed') }}</div>
                            <div v-if="entryEmbeddingStatus === 'error'" class="settings-desc" style="margin-top:8px; color: #ff9500;">{{ t('entry_index_error') }}: {{ getEmbeddingErrorLabel(failedEntryMap.get(activeEntry.id)) }}</div>
                            <div v-if="entryEmbeddingStatus === 'error' && failedEntryMap.get(activeEntry.id)?.message" class="settings-desc" style="margin-top:4px; color: var(--text-gray);">{{ failedEntryMap.get(activeEntry.id).message }}</div>
                        </div>
                </div>

                <div class="menu-group">
                    <div class="section-header">{{ t('section_temporal_logic') }} <HelpTip term="lorebook-temporal"/></div>
                        <div class="settings-item">
                            <label>{{ t('label_sticky') }} <span class="hint">{{ t('hint_sticky_turns') }}</span></label>
                            <input type="number" v-model="activeEntry.sticky" placeholder="0">
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_cooldown') }} <span class="hint">{{ t('hint_cooldown_turns') }}</span></label>
                            <input type="number" v-model="activeEntry.cooldown" placeholder="0">
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_delay_turns') }} <span class="hint">{{ t('hint_delay_turns') }}</span></label>
                            <input type="number" v-model="activeEntry.delay" placeholder="0">
                        </div>
                </div>

                <div class="menu-group">
                    <div class="section-header">{{ t('section_grouping_filter') }} <HelpTip term="lorebook-group"/></div>
                        <div class="settings-item">
                            <label>{{ t('label_group_name') }}</label>
                            <input type="text" v-model="activeEntry.group" :placeholder="t('placeholder_faction')">
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_group_weight') }}</label>
                            <input type="number" v-model="activeEntry.groupProminence" placeholder="100">
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_character_filter') }} <span class="hint">{{ t('hint_names') }}</span></label>
                            <input type="text" :value="activeEntry.characterFilter?.names.join(', ')" @input="updateCharacterFilter($event.target.value)" :placeholder="t('placeholder_char_names')">
                        </div>
                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('label_exclude_characters') }} <span class="hint">{{ t('hint_invert_filter') }}</span></label>
                            </div>
                            <input type="checkbox" v-model="characterFilterExclude" class="vk-switch">
                        </div>
                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('label_ignore_budget') }} <span class="hint">{{ t('hint_always_include') }}</span></label>
                            </div>
                            <input type="checkbox" v-model="activeEntry.ignoreBudget" class="vk-switch">
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.lb-sheet-header {
    height: 56px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 16px;
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
}

.header-left, .header-right {
    width: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
}

.header-btn {
    width: 40px;
    .header-toggle {
    display: flex;
    align-items: center;
    justify-content: center;
    margin-right: 8px;
}
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: var(--vk-blue);
}
.header-btn svg { width: 24px; height: 24px; fill: currentColor; }

.header-title {
    font-weight: 700;
    font-size: 18px;
    flex: 1;
    text-align: center;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    padding: 0 8px;
    color: var(--text-black);
}

.lb-sheet-body {
    flex: 1;
    display: flex;
    flex-direction: column;
    color: var(--text-gray);
    overflow-y: auto;
    -webkit-overflow-scrolling: touch;
    width: 100%;
}

.lb-list, .view-wrapper {
    width: 100%;
    background: transparent;
}

.empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 60px 40px;
    text-align: center;
}

.empty-icon { width: 64px; height: 64px; fill: var(--text-gray); opacity: 0.2; margin-bottom: 24px; }
.empty-text { font-size: 18px; font-weight: 600; color: var(--text-black); margin-bottom: 8px; }
.empty-subtext { font-size: 14px; opacity: 0.6; margin-bottom: 24px; line-height: 1.5; }

.empty-actions {
    display: flex;
    gap: 12px;
}

.vk-btn-action {
    padding: 8px 16px;
    border-radius: 8px;
    font-size: 14px;
}

.clickable-selector {
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: var(--bg-item);
    border: 1px solid var(--border-color);
    padding: 0 16px;
    height: 44px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 14px;
    transition: background 0.2s;
    margin-top: 4px;
}

.clickable-selector:active {
    background: var(--bg-item-active);
}

.clickable-selector svg {
    width: 20px;
    height: 20px;
    fill: var(--text-gray);
    opacity: 0.5;
}
.vk-btn-action.secondary {
    background: rgba(0,0,0,0.05);
    color: var(--text-black);
}

.list-container {
    width: 100%;
    display: flex;
    flex-direction: column;
    padding: 12px;
    padding-bottom: 80px;
    gap: 8px;
}

.lb-item-wrapper {
    display: flex;
    flex-direction: column;
    border-radius: 16px;
    background: rgba(30, 30, 32, var(--element-opacity, 0.7));
    backdrop-filter: blur(var(--element-blur, 10px));
    border: 1px solid rgba(255, 255, 255, 0.05);
    overflow: hidden;
    transition: all 0.2s;
}

.lb-item-wrapper.expanded {
    background: rgba(40, 40, 42, 0.9);
}

.lb-item {
    display: flex;
    align-items: center;
    padding: 16px;
    cursor: pointer;
    transition: background-color 0.2s;
}

.lb-item:active { 
    background-color: rgba(var(--vk-blue-rgb), 0.05); 
}

.lb-activation-inline {
    padding: 0 16px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    border-top: 1px solid rgba(255,255,255,0.05);
    background: rgba(255,255,255,0.01);
}

.inline-settings-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 0;
}

.inline-settings-row label {
    font-size: 14px;
    font-weight: 600;
}

.inline-activation-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.inline-section-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 12px;
    font-weight: 600;
    color: var(--text-gray);
    text-transform: uppercase;
    letter-spacing: 0.02em;
}

.add-btn-tiny {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 4px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    cursor: pointer;
}

.add-btn-tiny svg { width: 14px; height: 14px; fill: currentColor; }

.tag-list.mini {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}

.activation-tag.mini {
    padding: 3px 8px;
    font-size: 11px;
    border-radius: 6px;
}

.tag-close.tiny {
    width: 14px;
    height: 14px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    opacity: 0.6;
}

.tag-close.tiny svg { width: 10px; height: 10px; fill: currentColor; }

.lb-info { flex: 1; overflow: hidden; margin-right: 12px; }
.lb-name { font-weight: 600; font-size: 16px; color: var(--text-black); margin-bottom: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.lb-meta { font-size: 13px; color: var(--text-gray); line-height: 1.4; }
.preview-text { 
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
    white-space: normal;
    opacity: 0.7;
}

.icon-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    color: var(--text-gray);
}
.icon-btn.delete { color: #ff3b30; }
.icon-btn svg { width: 22px; height: 22px; fill: currentColor; }

.lb-actions {
    display: flex;
    align-items: center;
    gap: 12px;
}

.activation-pill {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 7px 10px;
    border-radius: 999px;
    border: 1px solid rgba(255,255,255,0.09);
    background: rgba(255,255,255,0.05);
    color: var(--text-black);
    cursor: pointer;
    font-family: inherit;
    max-width: 190px;
}

.activation-pill.global {
    background: rgba(0, 122, 255, 0.12);
    border-color: rgba(0, 122, 255, 0.18);
}
.activation-pill.character {
    background: rgba(175, 82, 222, 0.12);
    border-color: rgba(175, 82, 222, 0.18);
}
.activation-pill.chat {
    background: rgba(255, 149, 0, 0.12);
    border-color: rgba(255, 149, 0, 0.18);
}
.activation-pill.disabled {
    opacity: 0.7;
}

.pill-scope {
    font-size: 12px;
    font-weight: 800;
    letter-spacing: 0.02em;
    text-transform: uppercase;
    color: var(--text-gray);
}
.activation-pill.global .pill-scope { color: #007aff; }
.activation-pill.character .pill-scope { color: #af52de; }
.activation-pill.chat .pill-scope { color: #ff9500; }

.pill-hint {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-black);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 120px;
}

.lb-conn-badges {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
    align-items: center;
}

.conn-badge {
    font-size: 11px;
    font-weight: 700;
    padding: 2px 8px;
    border-radius: 999px;
    background: rgba(255,255,255,0.06);
    color: var(--text-gray);
    white-space: nowrap;
}

.conn-badge.global { color: #34c759; background: rgba(52, 199, 89, 0.12); }
.conn-badge.char { color: #af52de; background: rgba(175, 82, 222, 0.12); }
.conn-badge.chat { color: #ff9500; background: rgba(255, 149, 0, 0.12); }
.conn-badge.vector { color: #5ac8fa; background: rgba(90, 200, 250, 0.12); font-size: 10px; padding: 1px 6px; }
.conn-badge.indexed { color: #34c759; background: rgba(52, 199, 89, 0.12); font-size: 10px; padding: 1px 6px; }
.conn-badge.errored { color: #ff9500; background: rgba(255, 149, 0, 0.12); font-size: 10px; padding: 1px 6px; }

.vector-reindex-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin: 0 12px 12px;
    padding: 12px 14px;
    border: 1px solid rgba(255, 204, 0, 0.28);
    background: rgba(255, 204, 0, 0.08);
    border-radius: 14px;
}

.vector-reindex-copy {
    min-width: 0;
}

.vector-reindex-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 4px;
}

.vector-reindex-text {
    font-size: 12px;
    color: var(--text-secondary);
    line-height: 1.4;
}

.entries-toolbar-wrap {
    display: flex;
    flex-direction: column;
    gap: 6px;
}
.entries-toolbar {
    display: flex;
    gap: 8px;
    padding: 8px 16px;
    overflow-x: auto;
}

.toolbar-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-gray);
    font-size: 12px;
    font-weight: 600;
    white-space: nowrap;
    cursor: pointer;
    transition: background 0.2s;
}

.toolbar-btn:active { background: rgba(255, 255, 255, 0.12); }
.toolbar-btn:disabled { opacity: 0.4; cursor: default; }
.toolbar-icon { width: 16px; height: 16px; fill: currentColor; }
.toolbar-btn.secondary { color: #ff9500; }

.index-result-block {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 0 16px 4px;
    font-size: 12px;
    font-weight: 600;
    color: #34c759;
}

.index-result-line {
    line-height: 1.35;
}

.index-result-error {
    color: #ff3b30;
}

.failed-entries-block {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin: 0 16px 8px;
    padding: 12px;
    border-radius: 12px;
    background: rgba(255, 149, 0, 0.08);
    border: 1px solid rgba(255, 149, 0, 0.18);
}

.failed-entries-title {
    font-size: 13px;
    font-weight: 700;
    color: #ff9500;
}

.failed-entry-row {
    display: flex;
    min-width: 0;
}

.failed-entry-copy {
    min-width: 0;
}

.failed-entry-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-black);
}

.failed-entry-reason,
.failed-entry-message {
    font-size: 12px;
    line-height: 1.4;
}

.failed-entry-reason {
    color: #ff9500;
}

.failed-entry-message {
    color: var(--text-gray);
}

.lb-name-row {
    display: flex;
    align-items: center;
    gap: 6px;
}

.action-btn svg { width: 22px; height: 22px; fill: currentColor; }

.activation-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    color: var(--text-gray);
    background: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
    transition: all 0.2s;
}

.activation-btn:active {
    transform: scale(0.9);
    opacity: 0.8;
}

.activation-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.activation-btn.global {
    color: #34c759;
}

.activation-btn.character {
    color: #af52de;
}

.activation-btn.chat {
    color: #ff9500;
}

.activation-btn.disabled {
    opacity: 0.5;
}

/* Search Bar */
.search-bar {
    padding: 12px 16px;
    background: rgba(0, 0, 0, 0.2);
    backdrop-filter: blur(8px);
    position: sticky;
    top: 0;
    z-index: 10;
    width: auto;
    display: flex;
    align-items: center;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    margin: 8px 16px;
    border-radius: 12px;
    box-sizing: border-box;
}
.search-icon { width: 20px; height: 20px; fill: var(--text-gray); margin-right: 12px; }
.search-bar input {
    flex: 1;
    border: none;
    font-size: 16px;
    outline: none;
    background: transparent;
}

/* Editor Styling */
.lb-editor {
    width: 100%;
    height: 100%;
    overflow-y: auto;
}

.editor-scroll {
    padding-bottom: 40px;
}



.menu-group {
    background: rgba(30, 30, 32, var(--element-opacity, 0.7));
    backdrop-filter: blur(var(--element-blur, 10px));
    border-radius: 20px;
    margin: 0 16px 16px;
    border: 1px solid rgba(255, 255, 255, 0.05);
    overflow: hidden;
}

.settings-item {
    padding: 12px 20px;
    display: flex;
    flex-direction: column;
    border-bottom: 1px solid var(--border-color);
}
.settings-item:last-child { border-bottom: none; }

.settings-item label {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-gray);
    margin-bottom: 8px;
    opacity: 0.9;
}

.settings-item input, .settings-item textarea, .settings-item select {
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 12px;
    padding: 12px;
    font-size: 15px;
    font-family: inherit;
    background: rgba(0, 0, 0, 0.2);
    outline: none;
    width: 100%;
    color: var(--text-black);
    transition: border-color 0.2s, background-color 0.2s;
}

.settings-item input:focus, 
.settings-item textarea:focus, 
.settings-item select:focus {
    border-color: var(--vk-blue);
    background: rgba(0, 0, 0, 0.4);
}

.settings-item select {
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath d='M7 10l5 5 5-5z'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 12px center;
    background-size: 24px;
    padding-right: 40px;
}

.settings-item textarea {
    resize: none;
    line-height: 1.5;
}

.settings-item-checkbox {
    padding: 16px 20px;
    display: flex;
    align-items: center;
    justify-content: space-between;
}

.settings-text-col label {
    font-size: 16px;
    font-weight: 500;
    color: var(--text-black);
}

.hint {
    font-weight: 400;
    font-size: 12px;
    opacity: 0.5;
    margin-left: 4px;
}

/* Switch styling - assuming global vk-switch exists */
.vk-switch {
    appearance: none;
    width: 44px;
    height: 24px;
    background: #e9e9ea;
    border-radius: 12px;
    position: relative;
    cursor: pointer;
    transition: background 0.3s;
}
.vk-switch:checked { background: var(--vk-blue); }
.vk-switch::after {
    content: '';
    position: absolute;
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    top: 2px;
    left: 2px;
    transition: transform 0.3s;
    box-shadow: 0 1px 3px rgba(0,0,0,0.2);
}
.vk-switch:checked::after { transform: translateX(20px); }

.small-switch {
    width: 36px;
    height: 20px;
}
.small-switch::after {
    width: 16px;
    height: 16px;
}
.small-switch:checked::after { transform: translateX(16px); }

.vk-select {
    width: 100%;
    padding: 10px 12px;
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(0, 0, 0, 0.2);
    color: var(--text-black);
    font-family: inherit;
    font-size: 15px;
    font-weight: 600;
    outline: none;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath d='M7 10l5 5 5-5z' fill='%2399a2ad'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 12px center;
    background-size: 20px;
    transition: all 0.2s;
}

.global-settings-group {
    margin-top: 12px;
}

.clickable {
    cursor: pointer;
}

.rotated {
    transform: rotate(180deg) !important;
}

.settings-row {
    display: flex;
    gap: 12px;
    padding: 12px 20px;
    border-bottom: 1px solid var(--border-color);
}
.settings-col {
    flex: 1;
    display: flex;
    flex-direction: column;
}
.settings-col label {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--text-gray);
    margin-bottom: 6px;
    opacity: 0.8;
}
.settings-col input {
    width: 100%;
    padding: 10px 12px;
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(0, 0, 0, 0.2);
    color: var(--text-black);
    font-family: inherit;
    font-size: 15px;
    font-weight: 600;
    outline: none;
    transition: all 0.2s;
    box-sizing: border-box;
}

.small-checkbox {
    padding: 10px 20px;
}

.activation-section {
    padding: 12px 20px;
    border-bottom: 1px solid var(--border-color);
}
.activation-section:last-child { border-bottom: none; }

.activation-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
    font-size: 13px;
    font-weight: 600;
    color: var(--text-gray);
}

.add-btn-mini {
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 4px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    cursor: pointer;
}
.add-btn-mini svg { width: 16px; height: 16px; fill: currentColor; }

.tag-list {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
}

.activation-tag {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 8px;
    font-size: 13px;
    font-weight: 500;
}

.activation-tag.character {
    background: rgba(175, 82, 222, 0.1);
    color: #af52de;
}

.activation-tag.chat {
    background: rgba(255, 149, 0, 0.1);
    color: #ff9500;
}

.tag-close {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    opacity: 0.6;
}
.tag-close svg { width: 14px; height: 14px; fill: currentColor; }
</style>
