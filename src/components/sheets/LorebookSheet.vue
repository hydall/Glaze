<script setup>
import { ref, computed, onMounted, watch, nextTick } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { lorebookState, initLorebookState, createLorebook, deleteLorebook, importSTLorebook, exportSTLorebook, setLorebookActivation, flushLorebookSave } from '@/core/states/lorebookState.js';
import { saveFile } from '@/core/services/fileSaver.js';
import HelpTip from '@/components/ui/HelpTip.vue';

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
        useGroupScoring: null
    };
    activeLorebook.value.entries.push(newEntry);
    selectEntry(newEntry, activeLorebook.value.entries.length - 1);

}

function selectEntry(entry, index) {
    activeEntry.value = entry;
    activeEntryIndex.value = index;
    currentView.value = 'edit_entry';
}

function handleDeleteEntry(index) {
    if (!activeLorebook.value) return;
    activeLorebook.value.entries.splice(index, 1);
}

function handleEntryMenu(entry, index) {
    showBottomSheet({
        title: entry.comment || t('unnamed_entry'),
        items: [
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
    const isGlobal = lb.enabled;
    const isChar = currentContext.value.charId && lorebookState.activations?.character?.[currentContext.value.charId]?.includes(lb.id);
    const isChat = currentContext.value.chatId && lorebookState.activations?.chat?.[currentContext.value.chatId]?.includes(lb.id);
    
    if (isGlobal) return 'global';
    if (isChar) return 'character';
    if (isChat) return 'chat';
    return 'disabled';
}

function openConnectionManager(lb) {
    window.dispatchEvent(new CustomEvent('open-connections', { detail: { type: 'lorebook', id: lb.id, name: lb.name } }));
}

// --- Lifecycle ---

onMounted(async () => {
    await initLorebookState();
    loadPickerData();
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
    }
    return actions;
});

defineExpose({ open, openEntry, close, openLorebook });
</script>

<template>
    <SheetView ref="sheet" :title="sheetTitle" :show-back="showBackBtn" :actions="sheetActions" @back="goBack" @close="flushLorebookSave">
        <template #header-right>
            <div v-if="currentView === 'edit_entry'" class="header-toggle" style="align-items: center;">
                 <input type="checkbox" v-model="activeEntry.enabled" class="vk-switch">
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
                                <label>{{ t('label_context_percent') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.contextPercent">
                            </div>
                        </div>
                         <div class="settings-row">
                            <div class="settings-col">
                                <label>{{ t('label_budget_cap') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.budgetCap">
                            </div>
                             <div class="settings-col">
                                <label>{{ t('label_min_activations') }}</label>
                                <input type="number" v-model="lorebookState.globalSettings.minActivations">
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
                            <select v-model="lorebookState.globalSettings.insertionStrategy" class="vk-select">
                                <option value="character_first">{{ t('strategy_char_first') }}</option>
                                <option value="global_first">{{ t('strategy_global_first') }}</option>
                            </select>
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
                         <div class="settings-item-checkbox small-checkbox">
                             <label>{{ t('label_match_whole_words_global') }}</label>
                             <input type="checkbox" v-model="lorebookState.globalSettings.matchWholeWords" class="vk-switch small-switch">
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
                                </div>
                                <div class="lb-actions">
                                    <div class="activation-btn" :class="getActivationState(lb)" @click.stop="openConnectionManager(lb)">
                                        <svg v-if="getActivationState(lb) === 'global'" viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
                                        <svg v-else-if="getActivationState(lb) === 'character'" viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
                                        <svg v-else-if="getActivationState(lb) === 'chat'" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-1.99.9-1.99 2L2 22l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 9h12v2H6V9zm8 5H6v-2h8v2zm4-6H6V6h12v2z"/></svg>
                                        <svg v-else viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm3.59-13L12 10.59 8.41 7 7 8.41 10.59 12 7 15.59 8.41 17 12 13.41 15.59 17 17 15.59 13.41 12 17 8.41z"/></svg>
                                    </div>
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
                


                <div class="search-bar">
                    <svg viewBox="0 0 24 24" class="search-icon"><path d="M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>
                    <input type="text" v-model="searchQuery" :placeholder="t('placeholder_search_lore')">
                </div>

                <div v-if="filteredEntries.length === 0" class="empty-state">
                    <div class="empty-text">{{ t('no_entries_found') }}</div>
                </div>
                <div v-else class="list-container">
                    <div v-for="(entry, index) in filteredEntries" :key="index" class="lb-item" @click="selectEntry(entry, index)">
                        <div class="lb-info">
                            <div class="lb-name">{{ entry.comment || t('unnamed_entry') }}</div>
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
                        <div class="settings-item-checkbox">
                            <div class="settings-text-col">
                                <label>{{ t('label_constant') }} <span class="hint">{{ t('hint_always_active') }}</span></label>
                            </div>
                            <input type="checkbox" v-model="activeEntry.constant" class="vk-switch">
                        </div>

                        <div v-if="!activeEntry.constant">
                            <div class="settings-item">
                                <label>{{ t('label_primary_keys') }} <span class="hint">{{ t('hint_comma_separated') }}</span></label>
                                <input type="text" :value="activeEntry.keys.join(', ')" @input="updateEntryKeys($event.target.value)" :placeholder="t('placeholder_keys')">
                            </div>
                            <div class="settings-item">
                                <label>{{ t('label_logic_mode') }}</label>
                                <select v-model="activeEntry.selectiveLogic" class="vk-select">
                                    <option :value="4">{{ t('logic_primary_only') }}</option>
                                    <option :value="0">{{ t('logic_and_any') }}</option>
                                    <option :value="1">{{ t('logic_and_all') }}</option>
                                    <option :value="2">{{ t('logic_not_any') }}</option>
                                    <option :value="3">{{ t('logic_not_all') }}</option>
                                </select>
                            </div>
                            
                        <div class="settings-item">
                            <label>{{ t('label_case_sensitive') }}</label>
                            <select :value="typeof activeEntry.caseSensitive !== 'boolean' ? 'null' : activeEntry.caseSensitive.toString()" 
                                    @change="activeEntry.caseSensitive = $event.target.value === 'null' ? null : ($event.target.value === 'true')" class="vk-select">
                                <option value="null">{{ t('match_global') }}</option>
                                <option value="true">{{ t('on') }}</option>
                                <option value="false">{{ t('off') }}</option>
                            </select>
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_match_whole_words') }}</label>
                            <select :value="typeof activeEntry.matchWholeWords !== 'boolean' ? 'null' : activeEntry.matchWholeWords.toString()" 
                                    @change="activeEntry.matchWholeWords = $event.target.value === 'null' ? null : ($event.target.value === 'true')" class="vk-select">
                                <option value="null">{{ t('match_global') }}</option>
                                <option value="true">{{ t('on') }}</option>
                                <option value="false">{{ t('off') }}</option>
                            </select>
                        </div>
                        <div class="settings-item">
                            <label>{{ t('label_group_scoring') }}</label>
                            <select :value="typeof activeEntry.useGroupScoring !== 'boolean' ? 'null' : activeEntry.useGroupScoring.toString()" 
                                    @change="activeEntry.useGroupScoring = $event.target.value === 'null' ? null : ($event.target.value === 'true')" class="vk-select">
                                <option value="null">{{ t('match_global') }}</option>
                                <option value="true">{{ t('on') }}</option>
                                <option value="false">{{ t('off') }}</option>
                            </select>
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
                            <select v-model="activeEntry.position">
                                <option :value="4">{{ t('pos_top') }}</option>
                                <option value="worldInfoBefore">@worldInfoBefore ({{ t('pos_before_char') }})</option>
                                <option value="worldInfoAfter">@worldInfoAfter ({{ t('pos_after_char') }})</option>
                                <option :value="2">{{ t('pos_before_examples') }}</option>
                                <option :value="3">{{ t('pos_after_examples') }}</option>
                            </select>
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
    overflow-y: hidden; /* Child will scroll */
    width: 100%;
}

.lb-list, .view-wrapper {
    width: 100%;
    height: 100%;
    overflow-y: auto;
    -webkit-overflow-scrolling: touch;
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
    font-weight: 600;
    border: none;
    background: var(--vk-blue);
    color: white;
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
    background: rgba(255, 255, 255, var(--element-opacity, 0.7));
    backdrop-filter: blur(var(--element-blur, 10px));
    border: 1px solid rgba(var(--vk-blue-rgb), 0.1);
    overflow: hidden;
    transition: all 0.2s;
}

body.dark-theme .lb-item-wrapper {
    background: rgba(30, 30, 32, var(--element-opacity, 0.7));
    border: 1px solid rgba(255, 255, 255, 0.05);
}

.lb-item-wrapper.expanded {
    background: rgba(255, 255, 255, 0.9);
}

body.dark-theme .lb-item-wrapper.expanded {
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
    border-top: 1px solid rgba(0,0,0,0.05);
    background: rgba(0,0,0,0.01);
}

body.dark-theme .lb-activation-inline {
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

.action-btn svg { width: 22px; height: 22px; fill: currentColor; }

.activation-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    color: var(--text-gray);
    background: rgba(0, 0, 0, 0.05);
    transition: all 0.2s;
}

body.dark-theme .activation-btn {
    background: rgba(255, 255, 255, 0.05);
}

.activation-btn svg {
    width: 22px;
    height: 22px;
    fill: currentColor;
}

.activation-btn.global {
    color: #007aff;
    background: rgba(0, 122, 255, 0.1);
}

.activation-btn.character {
    color: #af52de;
    background: rgba(175, 82, 222, 0.1);
}

.activation-btn.chat {
    color: #ff9500;
    background: rgba(255, 149, 0, 0.1);
}

.activation-btn.disabled {
    opacity: 0.5;
}

/* Search Bar */
.search-bar {
    padding: 12px 16px;
    background: rgba(255, 255, 255, 0.3);
    backdrop-filter: blur(8px);
    position: sticky;
    top: 0;
    z-index: 10;
    width: auto;
    display: flex;
    align-items: center;
    border-bottom: 1px solid rgba(var(--vk-blue-rgb), 0.1);
    margin: 8px 16px;
    border-radius: 12px;
    box-sizing: border-box;
}

body.dark-theme .search-bar {
    background: rgba(0, 0, 0, 0.2);
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
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
    background: rgba(255, 255, 255, var(--element-opacity, 0.7));
    backdrop-filter: blur(var(--element-blur, 10px));
    border-radius: 20px;
    margin: 0 16px 16px;
    border: 1px solid rgba(var(--vk-blue-rgb), 0.1);
    overflow: hidden;
}
.menu-group.first-group {
    margin-top: 16px;
}

body.dark-theme .menu-group {
    background: rgba(30, 30, 32, var(--element-opacity, 0.7));
    border: 1px solid rgba(255, 255, 255, 0.05);
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
    border: 1px solid rgba(0,0,0,0.08);
    border-radius: 12px;
    padding: 12px;
    font-size: 15px;
    font-family: inherit;
    background: rgba(255, 255, 255, 0.4);
    outline: none;
    width: 100%;
    color: var(--text-black);
    transition: border-color 0.2s, background-color 0.2s;
}

body.dark-theme .settings-item input, 
body.dark-theme .settings-item textarea, 
body.dark-theme .settings-item select {
    background: rgba(0, 0, 0, 0.2);
    border: 1px solid rgba(255, 255, 255, 0.05);
}

.settings-item input:focus, 
.settings-item textarea:focus, 
.settings-item select:focus {
    border-color: var(--vk-blue);
    background: rgba(255, 255, 255, 0.7);
}

body.dark-theme .settings-item input:focus, 
body.dark-theme .settings-item textarea:focus, 
body.dark-theme .settings-item select:focus {
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
    border: 1px solid rgba(0,0,0,0.06);
    background: rgba(255,255,255,0.4);
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

body.dark-theme .vk-select {
    background: rgba(0,0,0,0.2);
    border-color: rgba(255,255,255,0.05);
    color: white;
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
    border: 1px solid rgba(0,0,0,0.06);
    background: rgba(255,255,255,0.4);
    color: var(--text-black);
    font-family: inherit;
    font-size: 15px;
    font-weight: 600;
    outline: none;
    transition: all 0.2s;
    box-sizing: border-box;
}
body.dark-theme .settings-col input {
     background: rgba(0,0,0,0.2);
     border: 1px solid rgba(255,255,255,0.05);
     color: white;
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