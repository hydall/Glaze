<script setup>
import { ref, computed, onMounted } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { lorebookState, setLorebookActivation } from '@/core/states/lorebookState.js';
import { presetState, setPresetConnection, DEFAULT_PRESETS } from '@/core/states/presetState.js';
import { personaConnections, setPersonaConnection, activePersona, allPersonas, loadPersonas } from '@/core/states/personaState.js';
import { db } from '@/utils/db.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const getPresetTokens = (preset) => {
    if (!preset) return 0;
    let content = "";
    if (preset.blocks) {
        preset.blocks.forEach(b => {
            if (b.enabled && !b.isStashed) {
                // Since ConnectionsSheet doesn't have all macro context, we just sum up the raw content length
                content += (b.content || "") + "\n";
            }
        });
    } else if (preset.prompts) {
        preset.prompts.forEach(p => {
            if (p.content) content += p.content + "\n";
        });
    }
    return Math.floor(content.length / 4);
};

const getPresetWeight = (id, preset) => {
    if (preset.isFeatured) return -3;
    if (id === 'default') return -2;
    if (DEFAULT_PRESETS[id]) return -1;
    return 0;
};

const sheet = ref(null);
const currentItemType = ref('lorebook');
const expandedItemId = ref('');
const temporarilyVisibleItems = ref(new Set());
const allCharacters = ref([]);
const allSessions = ref([]);

const activeCharContext = ref(null);

const contextChatId = computed(() => {
    if (!activeCharContext.value) return null;
    return `${activeCharContext.value.id}_${activeCharContext.value.sessionId || ''}`.replace(/_$/, '');
});

const contextCharId = computed(() => activeCharContext.value?.id || null);

function getItemPriority(itemId) {
    if (contextChatId.value && getChatConnections(itemId).some(c => c.id === contextChatId.value)) return 3;
    if (contextCharId.value && getCharConnections(itemId).some(c => c.id === contextCharId.value)) return 2;
    if (isGlobalActive(itemId)) return 1;
    return 0;
}

const getAvatarUrl = (avatar) => {
    if (!avatar) return '';
    if (avatar.startsWith('http') || avatar.startsWith('blob') || avatar.startsWith('data:')) return avatar;
    return `/characters/${avatar}`;
};

const t = (key) => translations[currentLang.value]?.[key] || key;

async function loadPickerData() {
    try {
        const [chars, chatsData] = await Promise.all([
            db.getAll('characters'),
            db.getChats()
        ]);
        allCharacters.value = chars || [];
        const charIds = new Set(allCharacters.value.map(c => c.id));

        const sessions = [];
        if (chatsData) {
            Object.keys(chatsData).forEach(charId => {
                if (!charIds.has(charId)) return;
                const char = allCharacters.value.find(c => c.id === charId);
                const data = chatsData[charId];
                if (!data) return;
                
                const sess = data.sessions || (Array.isArray(data) ? { 1: data } : {});
                Object.keys(sess).forEach(sid => {
                    sessions.push({
                        id: `${charId}_${sid}`,
                        charName: char?.name || charId,
                        sessionId: sid,
                        avatar: char?.avatar,
                        thumbnail: char?.thumbnail,
                        color: char?.color
                    });
                });
            });
        }
        allSessions.value = sessions;
        cleanupStaleConnections();
    } catch (err) {
        console.error('Failed to load connection picker data:', err);
    }
}

function cleanupStaleConnections() {
    if (!lorebookState.initialized || !presetState.initialized) return;
    const charIds = new Set(allCharacters.value.map(c => c.id));
    const sessionIds = new Set(allSessions.value.map(s => s.id));

    if (lorebookState.activations) {
        if (lorebookState.activations.character) Object.keys(lorebookState.activations.character).forEach(cid => { if (!charIds.has(cid)) delete lorebookState.activations.character[cid]; });
        if (lorebookState.activations.chat) Object.keys(lorebookState.activations.chat).forEach(sid => { if (!sessionIds.has(sid)) delete lorebookState.activations.chat[sid]; });
    }
    if (presetState.connections) {
        if (presetState.connections.character) Object.keys(presetState.connections.character).forEach(cid => { if (!charIds.has(cid)) delete presetState.connections.character[cid]; });
        if (presetState.connections.chat) Object.keys(presetState.connections.chat).forEach(sid => { if (!sessionIds.has(sid)) delete presetState.connections.chat[sid]; });
    }
    if (personaConnections) {
        if (personaConnections.character) Object.keys(personaConnections.character).forEach(cid => { if (!charIds.has(cid)) delete personaConnections.character[cid]; });
        if (personaConnections.chat) Object.keys(personaConnections.chat).forEach(sid => { if (!sessionIds.has(sid)) delete personaConnections.chat[sid]; });
    }
}

// --- Items List ---
const itemsList = computed(() => {
    try {
        if (currentItemType.value === 'lorebook') {
            const list = lorebookState?.lorebooks || [];
            return list.map(l => ({ 
                id: l.id, 
                name: l.name || 'Unnamed', 
                enabled: l.enabled,
                icon: 'M18 2H6C4.9 2 4 2.9 4 4v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-2 14H8v-2h8v2zm1-4H7v-2h10v2zm0-4H7V6h10v2z'
            }));
        } else if (currentItemType.value === 'preset') {
            const presets = presetState?.presets || {};
            return Object.entries(presets)
                .sort((a, b) => {
                    const wA = getPresetWeight(a[0], a[1]);
                    const wB = getPresetWeight(b[0], b[1]);
                    if (wA !== wB) return wA - wB;
                    return a[1].name.localeCompare(b[1].name);
                })
                .map(([id, p]) => ({ 
                    id: id, 
                    name: p.name || id,
                    image: p.image || null,
                    sublabel: `${getPresetTokens(p)} t`,
                    icon: !p.image ? 'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z' : null
                }));
        } else if (currentItemType.value === 'persona') {
            const list = allPersonas.value || [];
            return list.map(p => ({ 
                id: p.id, 
                name: p.name || 'Unnamed',
                icon: 'M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z'
            }));
        }
    } catch (e) {
        console.error('Error computing itemsList:', e);
    }
    return [];
});

const activeItemsList = computed(() => {
    let list = itemsList.value.filter(item => 
        getTotalConnections(item.id) > 0 || 
        isGlobalActive(item.id) || 
        temporarilyVisibleItems.value.has(item.id)
    );
    list.sort((a, b) => getItemPriority(b.id) - getItemPriority(a.id));
    return list;
});

// --- Global Toggle ---
function isGlobalActive(itemId) {
    if (currentItemType.value === 'lorebook') {
        const lb = lorebookState.lorebooks.find(l => l.id === itemId);
        return lb?.enabled || false;
    } else if (currentItemType.value === 'preset') {
        return presetState.globalPresetId === itemId;
    } else if (currentItemType.value === 'persona') {
        return activePersona.value?.id === itemId;
    }
    return false;
}

function toggleGlobal(itemId) {
    const current = isGlobalActive(itemId);
    if (currentItemType.value === 'lorebook') {
        const lb = lorebookState.lorebooks.find(l => l.id === itemId);
        if (lb) lb.enabled = !current;
    } else if (currentItemType.value === 'preset') {
        if (!current) setPresetConnection('global', null, itemId);
        else if (presetState.globalPresetId === itemId) setPresetConnection('global', null, 'default');
    } else if (currentItemType.value === 'persona') {
        if (!current) setPersonaConnection('global', null, itemId);
    }
}

// --- Connections ---
function getCharConnections(itemId) {
    const connections = [];
    if (currentItemType.value === 'lorebook') {
        Object.entries(lorebookState.activations?.character || {}).forEach(([charId, lbIds]) => {
            if (lbIds.includes(itemId)) {
                const char = allCharacters.value.find(c => c.id === charId);
                connections.push({ id: charId, name: char?.name || charId });
            }
        });
    } else if (currentItemType.value === 'preset') {
        Object.entries(presetState.connections?.character || {}).forEach(([charId, presetId]) => {
            if (presetId === itemId) {
                const char = allCharacters.value.find(c => c.id === charId);
                connections.push({ id: charId, name: char?.name || charId });
            }
        });
    } else if (currentItemType.value === 'persona') {
        Object.entries(personaConnections?.character || {}).forEach(([charId, personaId]) => {
            if (personaId === itemId) {
                const char = allCharacters.value.find(c => c.id === charId);
                connections.push({ id: charId, name: char?.name || charId });
            }
        });
    }
    return connections;
}

function getChatConnections(itemId) {
    const connections = [];
    if (currentItemType.value === 'lorebook') {
        Object.entries(lorebookState.activations?.chat || {}).forEach(([sessId, lbIds]) => {
            if (lbIds.includes(itemId)) {
                const sess = allSessions.value.find(s => s.id === sessId);
                connections.push({ id: sessId, charName: sess?.charName || 'Chat', sessionId: sess?.sessionId || sessId.split('_').pop() });
            }
        });
    } else if (currentItemType.value === 'preset') {
        Object.entries(presetState.connections?.chat || {}).forEach(([chatId, presetId]) => {
            if (presetId === itemId) {
                const sess = allSessions.value.find(s => s.id === chatId);
                connections.push({ id: chatId, charName: sess?.charName || 'Chat', sessionId: sess?.sessionId || chatId.split('_').pop() });
            }
        });
    } else if (currentItemType.value === 'persona') {
        Object.entries(personaConnections?.chat || {}).forEach(([chatId, personaId]) => {
            if (personaId === itemId) {
                const sess = allSessions.value.find(s => s.id === chatId);
                connections.push({ id: chatId, charName: sess?.charName || 'Chat', sessionId: sess?.sessionId || chatId.split('_').pop() });
            }
        });
    }
    return connections;
}

function getTotalConnections(itemId) {
    return getCharConnections(itemId).length + getChatConnections(itemId).length;
}

// --- Modify Connections ---
function addCharConnection(itemId) {
    showBottomSheet({
        title: t('sheet_title_select_char'),
        cardItems: allCharacters.value.map(c => ({
            label: c.name,
            sublabel: c.scenario || c.description || '',
            icon: (c.thumbnail || c.avatar)
                ? `<img src="${getAvatarUrl(c.thumbnail || c.avatar)}" style="width:100%;height:100%;border-radius:inherit;object-fit:cover;">`
                : `<div style="width:100%;height:100%;border-radius:inherit;background:${c.color || 'var(--vk-blue)'};display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;">${(c.name && c.name[0]) ? c.name[0].toUpperCase() : '?'}</div>`,
            onClick: () => {
                if (currentItemType.value === 'lorebook') setLorebookActivation(itemId, 'character', c.id);
                else if (currentItemType.value === 'preset') setPresetConnection('character', c.id, itemId);
                else if (currentItemType.value === 'persona') setPersonaConnection('character', c.id, itemId);
                closeBottomSheet();
            }
        }))
    });
}

function addChatConnection(itemId) {
    showBottomSheet({
        title: t('sheet_title_select_chat'),
        cardItems: allSessions.value.map(s => ({
            label: s.charName,
            sublabel: `#${s.sessionId}`,
            icon: (s.thumbnail || s.avatar)
                ? `<img src="${getAvatarUrl(s.thumbnail || s.avatar)}" style="width:100%;height:100%;border-radius:inherit;object-fit:cover;">`
                : `<div style="width:100%;height:100%;border-radius:inherit;background:${s.color || 'var(--vk-blue)'};display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;">${(s.charName && s.charName[0]) ? s.charName[0].toUpperCase() : '?'}</div>`,
            onClick: () => {
                if (currentItemType.value === 'lorebook') setLorebookActivation(itemId, 'chat', s.id);
                else if (currentItemType.value === 'preset') setPresetConnection('chat', s.id, itemId);
                else if (currentItemType.value === 'persona') setPersonaConnection('chat', s.id, itemId);
                closeBottomSheet();
            }
        }))
    });
}

function removeCharConnection(itemId, charId) {
    if (currentItemType.value === 'lorebook') setLorebookActivation(itemId, 'character', charId);
    else if (currentItemType.value === 'preset') setPresetConnection('character', charId, null);
    else if (currentItemType.value === 'persona') setPersonaConnection('character', charId, null);
}

function removeChatConnection(itemId, chatId) {
    if (currentItemType.value === 'lorebook') setLorebookActivation(itemId, 'chat', chatId);
    else if (currentItemType.value === 'preset') setPresetConnection('chat', chatId, null);
    else if (currentItemType.value === 'persona') setPersonaConnection('chat', chatId, null);
}

function removeAllConnections(itemId) {
    if (currentItemType.value === 'lorebook') {
        const lb = lorebookState.lorebooks.find(l => l.id === itemId);
        if (lb && lb.enabled) lb.enabled = false;
        if (lorebookState.activations?.character) {
            Object.keys(lorebookState.activations.character).forEach(charId => {
                if (lorebookState.activations.character[charId].includes(itemId)) setLorebookActivation(itemId, 'character', charId);
            });
        }
        if (lorebookState.activations?.chat) {
            Object.keys(lorebookState.activations.chat).forEach(chatId => {
                if (lorebookState.activations.chat[chatId].includes(itemId)) setLorebookActivation(itemId, 'chat', chatId);
            });
        }
    } else if (currentItemType.value === 'preset') {
        if (presetState.globalPresetId === itemId) setPresetConnection('global', null, 'default');
        if (presetState.connections?.character) {
            Object.keys(presetState.connections.character).forEach(charId => {
                if (presetState.connections.character[charId] === itemId) setPresetConnection('character', charId, null);
            });
        }
        if (presetState.connections?.chat) {
            Object.keys(presetState.connections.chat).forEach(chatId => {
                if (presetState.connections.chat[chatId] === itemId) setPresetConnection('chat', chatId, null);
            });
        }
    } else if (currentItemType.value === 'persona') {
        if (activePersona.value?.id === itemId) setPersonaConnection('global', null, null);
        if (personaConnections?.character) {
            Object.keys(personaConnections.character).forEach(charId => {
                if (personaConnections.character[charId] === itemId) setPersonaConnection('character', charId, null);
            });
        }
        if (personaConnections?.chat) {
            Object.keys(personaConnections.chat).forEach(chatId => {
                if (personaConnections.chat[chatId] === itemId) setPersonaConnection('chat', chatId, null);
            });
        }
    }
}

function promptRemove(item) {
    showBottomSheet({
        title: t('confirm_remove_connections') || 'Remove all connections?',
        items: [
            {
                label: t('action_delete') || 'Remove',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                isDestructive: true,
                onClick: () => {
                    removeAllConnections(item.id);
                    temporarilyVisibleItems.value.delete(item.id);
                    if (expandedItemId.value === item.id) expandedItemId.value = '';
                    closeBottomSheet();
                }
            },
            {
                label: t('action_cancel') || 'Cancel',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

function addNewConnection() {
    const availableItems = itemsList.value.filter(item => 
        getTotalConnections(item.id) === 0 && 
        !isGlobalActive(item.id) &&
        !temporarilyVisibleItems.value.has(item.id)
    );
    showBottomSheet({
        title: t('action_add') || 'Add',
        cardItems: availableItems.map(item => ({
            label: item.name,
            sublabel: item.sublabel,
            image: item.image,
            icon: item.icon,
            onClick: () => {
                temporarilyVisibleItems.value.add(item.id);
                expandedItemId.value = item.id;
                closeBottomSheet();
            }
        }))
    });
}

function toggleExpand(itemId) {
    expandedItemId.value = expandedItemId.value === itemId ? '' : itemId;
}

function setType(type) {
    currentItemType.value = type;
    expandedItemId.value = '';
}

async function open(type = 'lorebook', itemId = '', itemName = '', contextChar = null) {
    currentItemType.value = type;
    expandedItemId.value = itemId || '';
    activeCharContext.value = contextChar;
    await loadPickerData();
    sheet.value?.open();
}

function close() {
    sheet.value?.close();
}

function openEditor(item) {
    close();
    window.dispatchEvent(new CustomEvent('open-item-editor', {
        detail: {
            type: currentItemType.value,
            id: item.id
        }
    }));
}

onMounted(() => {
    loadPickerData();
    loadPersonas();
});

const connectionsTabs = computed(() => [
    { key: 'lorebook', label: t('menu_lorebooks') || 'Lorebooks', icon: 'M18 2H6C4.9 2 4 2.9 4 4v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-2 14H8v-2h8v2zm1-4H7v-2h10v2zm0-4H7V6h10v2z' },
    { key: 'preset', label: t('tab_generation') || 'Presets', icon: 'M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z' },
    { key: 'persona', label: t('tab_personas') || 'Personas', icon: 'M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z' }
]);

const overviewTitle = computed(() => {
    switch(currentItemType.value) {
        case 'preset': return t('tab_presets') || 'Presets';
        case 'persona': return t('tab_personas') || 'Personas';
        case 'lorebook': return t('menu_lorebooks') || 'Lorebooks';
        default: return 'Connections';
    }
});

defineExpose({ open, close });
</script>

<template>
    <SheetView ref="sheet" :z-index="1005" :title="t('header_connections') || 'Connections'" :tabs="connectionsTabs" :active-tab="currentItemType" @update:activeTab="setType">
        <div class="cs-body">
            <!-- Full Preset Overview Block for Priority -->
            <!-- Empty state -->
            <div v-if="itemsList.length === 0" class="cs-empty">
                <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 15v-4H7l5-8v4h4l-5 8z"/></svg>
                <p>{{ t('no_items_found') || 'No items available' }}</p>
            </div>

            <!-- Item Cards -->
            <div v-else class="cs-list-wrapper">
                <div class="cs-list">
                    <div v-if="activeItemsList.length === 0" class="cs-empty-hint" style="text-align:center; padding: 20px 0;">
                        {{ t('no_active_connections') || 'No active connections' }}
                    </div>
                    <div
                        v-for="item in activeItemsList"
                        :key="item.id"
                    class="cs-card"
                    :class="{ expanded: expandedItemId === item.id }"
                >
                    <!-- Card Header Row -->
                    <div class="cs-card-header" @click="toggleExpand(item.id)" :style="item.image ? { backgroundImage: `url(${item.image})` } : {}" :class="{ 'with-bg': item.image }">
                        <div v-if="item.image" class="card-overlay"></div>
                        <div class="item-icon" v-if="!item.image">
                            <svg viewBox="0 0 24 24"><path :d="item.icon"/></svg>
                        </div>
                        <div class="cs-card-info">
                            <span class="cs-card-name" :class="{ 'with-bg': item.image }">{{ item.name }}</span>
                            <div class="cs-card-sublabel" v-if="item.sublabel" :class="{ 'with-bg': item.image }">
                                {{ item.sublabel }}
                            </div>
                            <div class="cs-card-badges">
                                <!-- Priority specific badges -->
                                <span v-if="getItemPriority(item.id) === 3" class="cs-badge priority-chat" :class="{ 'with-bg': item.image }">
                                    <svg viewBox="0 0 24 24" class="badge-icon"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                                    {{ t('context_applied_chat') || 'Current Chat' }}
                                </span>
                                <span v-else-if="getItemPriority(item.id) === 2" class="cs-badge priority-char" :class="{ 'with-bg': item.image }">
                                    <svg viewBox="0 0 24 24" class="badge-icon"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
                                    {{ t('context_applied_char') || 'Current Character' }}
                                </span>
                                <span v-else-if="getItemPriority(item.id) === 1" class="cs-badge global" :class="{ 'with-bg': item.image }">
                                    <svg viewBox="0 0 24 24" class="badge-icon"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
                                    {{ t('label_global') || 'Global' }}
                                </span>

                                <!-- Regular count badges for non-priority items -->
                                <span v-if="getItemPriority(item.id) !== 2 && getCharConnections(item.id).length > 0" class="cs-badge char-badge" :class="{ 'with-bg': item.image }">
                                    <svg viewBox="0 0 24 24" class="badge-icon"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
                                    {{ getCharConnections(item.id).length }}
                                </span>
                                <span v-if="getItemPriority(item.id) !== 3 && getChatConnections(item.id).length > 0" class="cs-badge chat-badge" :class="{ 'with-bg': item.image }">
                                    <svg viewBox="0 0 24 24" class="badge-icon"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                                    {{ getChatConnections(item.id).length }}
                                </span>
                            </div>
                        </div>
                        <button class="cs-edit-item-btn" @click.stop="openEditor(item)" :class="{ 'with-bg': item.image }">
                            <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                        </button>
                        <button class="cs-delete-item-btn" @click.stop="promptRemove(item)" :class="{ 'with-bg': item.image }">
                            <svg viewBox="0 0 24 24"><path d="M17 7h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1 0 1.43-.98 2.63-2.31 2.98l1.46 1.46C20.88 15.61 22 13.95 22 12c0-2.76-2.24-5-5-5zm-3.13 1.9l-1.9-1.9H10V5h1.9L2 2.27 3.27 1 22.73 20.46 21.46 21.73l-3.32-3.32c-.36.06-.74.09-1.14.09H13v-1.9h2.24l-3.24-3.24L10 12h2.24l-4.11-4.1zM5 12c0-1.71 1.39-3.1 3.1-3.1H9V7H8c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H8c-1.71 0-3.1-1.39-3.1-3.1z"/></svg>
                        </button>
                        <svg class="cs-chevron" viewBox="0 0 24 24" :class="{ 'with-bg': item.image }"><path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6z"/></svg>
                    </div>

                    <!-- Expanded details -->
                    <Transition name="cs-expand">
                        <div v-if="expandedItemId === item.id" class="cs-card-body">
                            <!-- Global toggle -->
                            <div v-if="currentItemType !== 'persona'" class="cs-row global-row">
                                <div class="cs-row-label">
                                    <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
                                    {{ t('label_global_enabled') || 'Global default' }}
                                </div>
                                <div class="cs-toggle" :class="{ active: isGlobalActive(item.id) }" @click.stop="toggleGlobal(item.id)">
                                    <div class="cs-toggle-thumb"></div>
                                </div>
                            </div>

                            <!-- Character connections -->
                            <div class="cs-conn-section">
                                <div class="cs-conn-label">
                                    <svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
                                    <span>{{ t('header_characters') || 'Characters' }}</span>
                                    <button class="cs-add-btn" @click.stop="addCharConnection(item.id)">
                                        <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                                    </button>
                                </div>
                                <div class="cs-chips">
                                    <div
                                        v-for="conn in getCharConnections(item.id)"
                                        :key="conn.id"
                                        class="cs-chip char"
                                    >
                                        <span>{{ conn.name }}</span>
                                        <button class="cs-chip-remove" @click.stop="removeCharConnection(item.id, conn.id)">
                                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                                        </button>
                                    </div>
                                    <div v-if="getCharConnections(item.id).length === 0" class="cs-empty-hint">
                                        {{ t('no_char_connections') || 'None' }}
                                    </div>
                                </div>
                            </div>

                            <!-- Chat connections -->
                            <div class="cs-conn-section">
                                <div class="cs-conn-label">
                                    <svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                                    <span>{{ t('tab_dialogs') || 'Chats' }}</span>
                                    <button class="cs-add-btn" @click.stop="addChatConnection(item.id)">
                                        <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                                    </button>
                                </div>
                                <div class="cs-chips">
                                    <div
                                        v-for="conn in getChatConnections(item.id)"
                                        :key="conn.id"
                                        class="cs-chip chat"
                                    >
                                        <span>{{ conn.charName }} #{{ conn.sessionId }}</span>
                                        <button class="cs-chip-remove" @click.stop="removeChatConnection(item.id, conn.id)">
                                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                                        </button>
                                    </div>
                                    <div v-if="getChatConnections(item.id).length === 0" class="cs-empty-hint">
                                        {{ t('no_chat_connections') || 'None' }}
                                    </div>
                                </div>
                            </div>
                        </div>
                    </Transition>
                </div>
                <button v-if="activeItemsList.length < itemsList.length" class="cs-add-new-btn" @click="addNewConnection">
                    <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                    {{ t('action_add') || 'Add' }}
                </button>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>


/* ── Body ─────────────────────────────────────────────────  */
.cs-body {
    padding: 10px 12px 20px;
    display: flex;
    flex-direction: column;
    gap: 8px;
}

/* ── Empty State ──────────────────────────────────────────  */
.cs-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
    padding: 48px 16px;
    color: var(--text-gray);
    opacity: 0.5;
}
.cs-empty svg {
    width: 40px;
    height: 40px;
    fill: currentColor;
}
.cs-empty p {
    font-size: 14px;
    margin: 0;
}

/* ── List ─────────────────────────────────────────────────  */
.cs-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

/* ── Card ─────────────────────────────────────────────────  */
.cs-card {
    background: rgba(255, 255, 255, var(--element-opacity, 0.7));
    backdrop-filter: blur(var(--element-blur, 10px));
    border: 1px solid var(--border-color, rgba(0,0,0,.08));
    border-radius: 16px;
    overflow: hidden;
    transition: border-color 0.2s;
}

body.dark-theme .cs-card {
    background: rgba(30, 30, 32, var(--element-opacity, 0.7));
    border-color: rgba(255, 255, 255, 0.07);
}

.cs-card.expanded {
    border-color: rgba(var(--vk-blue-rgb), 0.3);
}

.cs-card-header {
    display: flex;
    align-items: center;
    padding: 10px 12px;
    cursor: pointer;
    gap: 12px;
    user-select: none;
}

.item-icon {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    border-radius: 8px;
    flex-shrink: 0;
}

.item-icon svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.cs-card-header:active {
    opacity: 0.7;
}

.cs-card-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 2px;
    min-width: 0;
}

.cs-card-name {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-black);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.cs-card-name.with-bg {
    color: white;
    text-shadow: 0 1px 3px rgba(0,0,0,0.8);
    font-size: 16px;
}

.cs-card-sublabel {
    font-size: 12px;
    color: var(--text-light-gray);
    margin-top: -2px;
}

.cs-card-sublabel.with-bg {
    color: rgba(255, 255, 255, 0.85);
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.cs-card-badges {
    display: flex;
    gap: 5px;
    flex-shrink: 0;
}

.cs-badge {
    font-size: 11px;
    font-weight: 600;
    padding: 2px 7px;
    border-radius: 20px;
}

.cs-badge.char-badge {
    background: rgba(175, 82, 222, 0.12);
    color: #af52de;
    display: inline-flex;
    align-items: center;
    gap: 3px;
}

.cs-badge.chat-badge {
    background: rgba(255, 149, 0, 0.12);
    color: #ff9500;
    display: inline-flex;
    align-items: center;
    gap: 3px;
}

.cs-badge.priority-chat {
    background: #ff9500;
    color: white;
    display: inline-flex;
    align-items: center;
    gap: 3px;
    box-shadow: 0 2px 6px rgba(255, 149, 0, 0.3);
}

.cs-badge.priority-char {
    background: #af52de;
    color: white;
    display: inline-flex;
    align-items: center;
    gap: 3px;
    box-shadow: 0 2px 6px rgba(175, 82, 222, 0.3);
}

.badge-icon {
    width: 10px;
    height: 10px;
    fill: currentColor;
}

.cs-badge.global {
    background: rgba(52, 199, 89, 0.12);
    color: #34c759;
    display: inline-flex;
    align-items: center;
    gap: 3px;
}

.cs-chevron {
    width: 20px;
    height: 20px;
    fill: var(--text-gray);
    flex-shrink: 0;
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}

.cs-card.expanded .cs-chevron {
    transform: rotate(180deg);
}

.cs-card-header.with-bg {
    background-size: cover;
    background-position: center;
    min-height: 80px;
    position: relative;
    align-items: flex-end;
    padding: 12px 16px;
}

.card-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.2) 100%);
    z-index: 1;
}

.cs-card-header.with-bg > *:not(.card-overlay) {
    position: relative;
    z-index: 2;
}

.cs-chevron.with-bg {
    fill: white;
    filter: drop-shadow(0 1px 2px rgba(0,0,0,0.5));
}

.cs-badge.with-bg {
    box-shadow: 0 1px 2px rgba(0,0,0,0.5);
}

.cs-badge.priority-chat.with-bg,
.cs-badge.priority-char.with-bg,
.cs-badge.char-badge.with-bg,
.cs-badge.chat-badge.with-bg {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(4px);
    box-shadow: none;
}

/* ── Card Body (expanded) ─────────────────────────────────  */
.cs-card-body {
    padding: 0 16px 14px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    border-top: 1px solid var(--border-color, rgba(0,0,0,.06));
    padding-top: 12px;
}

/* Expand animation */
.cs-expand-enter-active,
.cs-expand-leave-active {
    transition: opacity 0.22s ease, max-height 0.28s cubic-bezier(0.4, 0, 0.2, 1);
    max-height: 400px;
    overflow: hidden;
}
.cs-expand-enter-from,
.cs-expand-leave-to {
    opacity: 0;
    max-height: 0;
}

/* ── Global Row ───────────────────────────────────────────  */
.cs-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
}

.cs-row-label {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 13px;
    font-weight: 600;
    color: var(--text-black);
}

.cs-row-label svg {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
}

.cs-row.action-row {
    cursor: pointer;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--border-color, rgba(0,0,0,.06));
}
.cs-row.action-row:active {
    opacity: 0.6;
}
.cs-link-arrow {
    width: 18px;
    height: 18px;
    fill: var(--text-gray);
    opacity: 0.5;
}

/* ── Connection sections ──────────────────────────────────  */
.cs-conn-section {
    display: flex;
    flex-direction: column;
    gap: 7px;
}

.cs-conn-label {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    color: var(--text-gray);
}

.cs-conn-label svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.cs-conn-label span {
    flex: 1;
}

/* ── Add Button ───────────────────────────────────────────  */
.cs-add-btn {
    width: 22px;
    height: 22px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--vk-blue-rgb), 0.12);
    color: var(--vk-blue);
    border: none;
    border-radius: 6px;
    cursor: pointer;
    transition: opacity 0.15s;
    padding: 0;
}
.cs-add-btn:active { opacity: 0.5; }
.cs-add-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

/* ── Chips ────────────────────────────────────────────────  */
.cs-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    min-height: 26px;
}

.cs-chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 4px 8px 4px 10px;
    border-radius: 20px;
    font-size: 12px;
    font-weight: 500;
}

.cs-chip.char {
    background: rgba(175, 82, 222, 0.12);
    color: #af52de;
}

.cs-chip.chat {
    background: rgba(255, 149, 0, 0.12);
    color: #ff9500;
}

.cs-chip-remove {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    cursor: pointer;
    color: currentColor;
    opacity: 0.55;
    padding: 0;
    transition: opacity 0.15s;
}
.cs-chip-remove:active { opacity: 1; }
.cs-chip-remove svg {
    width: 11px;
    height: 11px;
    fill: currentColor;
}

/* ── Empty hint ───────────────────────────────────────────  */
.cs-empty-hint {
    font-size: 12px;
    color: var(--text-gray);
    opacity: 0.5;
    font-style: italic;
    line-height: 26px;
}
/* ── Override hint ────────────────────────────────────────  */
.cs-override-hint {
    font-size: 11px;
    color: var(--text-gray);
    opacity: 0.55;
    text-align: center;
    padding: 2px 16px 8px;
    line-height: 1.3;
}

.cs-edit-item-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    border: none;
    border-radius: 8px;
    cursor: pointer;
    flex-shrink: 0;
    transition: opacity 0.15s, background 0.15s;
    padding: 0;
}
.cs-edit-item-btn:active { background: rgba(var(--vk-blue-rgb), 0.2); }
.cs-edit-item-btn svg { width: 16px; height: 16px; fill: currentColor; }
.cs-edit-item-btn.with-bg { background: rgba(255, 255, 255, 0.2); color: white; backdrop-filter: blur(4px); }
.cs-edit-item-btn.with-bg:active { background: rgba(255, 255, 255, 0.3); }

.cs-delete-item-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(255, 59, 48, 0.1);
    color: #ff3b30;
    border: none;
    border-radius: 8px;
    cursor: pointer;
    flex-shrink: 0;
    transition: opacity 0.15s, background 0.15s;
    padding: 0;
}
.cs-delete-item-btn:active { background: rgba(255, 59, 48, 0.2); }
.cs-delete-item-btn svg { width: 16px; height: 16px; fill: currentColor; }
.cs-delete-item-btn.with-bg { background: rgba(255, 255, 255, 0.2); color: white; backdrop-filter: blur(4px); }
.cs-delete-item-btn.with-bg:active { background: rgba(255, 255, 255, 0.3); }

.cs-list-wrapper {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.cs-add-new-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 12px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    border: 1px dashed rgba(var(--vk-blue-rgb), 0.3);
    border-radius: 12px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
    width: 100%;
}
.cs-add-new-btn:active { background: rgba(var(--vk-blue-rgb), 0.15); }
.cs-add-new-btn svg { width: 18px; height: 18px; fill: currentColor; }

.hierarchy-stack {
    display: flex;
    align-items: center;
    gap: 4px;
    background: rgba(0,0,0,0.03);
    padding: 4px;
    border-radius: 12px;
}

.hierarchy-item {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 2px;
    padding: 6px 8px;
    border-radius: 8px;
    transition: all 0.2s;
    min-width: 0;
}

body.dark-theme .hierarchy-stack {
    background: rgba(255,255,255,0.03);
}

.level-pill {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    color: var(--text-gray);
    letter-spacing: 0.5px;
}

.hierarchy-arrow {
    display: flex;
    align-items: center;
    color: var(--text-gray);
    opacity: 0.3;
}

.hierarchy-arrow svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.preset-overview-block {
    margin: 8px 16px 20px;
    padding: 16px;
    background: linear-gradient(135deg, rgba(var(--vk-blue-rgb), 0.05), rgba(var(--vk-blue-rgb), 0.01));
    border: 1px solid rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 20px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    position: relative;
    overflow: hidden;
}

body.dark-theme .preset-overview-block {
    background: linear-gradient(135deg, rgba(var(--vk-blue-rgb), 0.1), rgba(var(--vk-blue-rgb), 0.03));
}

.preset-overview-block::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0; height: 1px;
    background: linear-gradient(90deg, transparent, rgba(var(--vk-blue-rgb), 0.3), transparent);
}

.overview-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding-bottom: 4px;
}

.overview-icon {
    width: 20px;
    height: 20px;
    fill: var(--vk-blue);
}

.overview-title {
    font-size: 13px;
    font-weight: 700;
    color: var(--text-black);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    opacity: 0.8;
}

.priority-flow {
    display: flex;
    flex-direction: column;
    gap: 4px;
    position: relative;
}

.priority-flow::before {
    content: '';
    position: absolute;
    left: 19px;
    top: 16px;
    bottom: 16px;
    width: 2px;
    background: rgba(var(--vk-blue-rgb), 0.15);
    border-radius: 2px;
}

.flow-node {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 8px;
    border-radius: 12px;
    background: transparent;
    transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
    position: relative;
}

.flow-node.active {
    background: rgba(255,255,255,0.7);
    box-shadow: 0 4px 12px rgba(0,0,0,0.03);
}

body.dark-theme .flow-node.active {
    background: rgba(255,255,255,0.05);
}

.node-indicator {
    width: 24px;
    height: 24px;
    border-radius: 12px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1;
    color: var(--vk-blue);
    transition: all 0.3s;
}

.flow-node.active .node-indicator {
    background: var(--vk-blue);
    color: white;
    box-shadow: 0 0 10px rgba(var(--vk-blue-rgb), 0.4);
}

.node-indicator svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.node-content {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
}

.node-level {
    font-size: 11px;
    font-weight: 700;
    color: var(--text-gray);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.flow-node.active .node-level {
    color: var(--vk-blue);
}

.node-value {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-black);
}

.flow-node:not(.active) .node-value {
    opacity: 0.5;
    font-weight: 500;
}

.flow-arrow {
    margin-left: 12px;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
    color: var(--vk-blue);
    opacity: 0.6;
    background: transparent;
    z-index: 1;
}

.flow-arrow svg {
    width: 16px; 
    height: 16px; 
    fill: currentColor;
}

/* ── Global Row & Toggle ──────────────────────────────────  */
.cs-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--border-color, rgba(0,0,0,0.06));
    margin-bottom: 4px;
}

.cs-row-label {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 13px;
    font-weight: 600;
    color: var(--text-black);
}

.cs-row-label svg {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
}

.cs-toggle {
    width: 44px;
    height: 24px;
    background: var(--border-color, rgba(0,0,0,0.1));
    border-radius: 12px;
    position: relative;
    cursor: pointer;
    transition: background 0.3s;
}

.cs-toggle.active {
    background: var(--vk-green, #34c759);
}

.cs-toggle-thumb {
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    position: absolute;
    top: 2px;
    left: 2px;
    transition: transform 0.3s;
    box-shadow: 0 1px 3px rgba(0,0,0,0.2);
}

.cs-toggle.active .cs-toggle-thumb {
    transform: translateX(20px);
}
</style>
