<script setup>
import { ref, watch, nextTick, onMounted, computed } from 'vue';
import { translations, pluralize } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { attachRipple } from '@/core/services/ui.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { lorebookState, initLorebookState } from '@/core/states/lorebookState.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { getEffectivePersona, personaConnections } from '@/core/states/personaState.js';
import { getEffectivePreset, presetState } from '@/core/states/presetState.js';
import { db } from '@/utils/db.js';
import { getLastPrompt } from '@/core/services/generationService.js';
import { getImageGenSettings } from '@/core/services/imageGenService.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import { getApiPresets } from '@/core/config/APISettings.js';
import PersonasSheet from '@/views/PersonasView.vue';

const personasSheet = ref(null);

const props = defineProps({
    visible: { type: Boolean, default: false },
    activeChar: { type: Object, default: null }
});

const emit = defineEmits([
    'close',
    'magic-notes',
    'magic-summary',
    'magic-sessions',
    'magic-stats',
    'magic-impersonate',
    'magic-char-card',
    'magic-api',
    'magic-presets',
    'magic-lorebooks',
    'magic-regex',
    'request-preview',
    'add-block',
    'magic-image-gen',
    'magic-glossary'
]);

const t = (key) => translations[currentLang.value]?.[key] || key;

const isEditing = ref(false);
const dragSrcIndex = ref(-1);
let longPressTimer = null;

const allAvailableItems = [
    { id: 'notes', i18n: 'magic_authors_notes', icon: 'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z', event: 'magic-notes' },
    { id: 'summary', i18n: 'magic_summary', icon: 'M14 17H4v2h10v-2zm6-8H4v2h16V9zM4 15h16v-2H4v2zM4 5v2h16V5H4z', event: 'magic-summary' },
    { id: 'sessions', i18n: 'history_title', fallback: 'Sessions', icon: 'M13 3a9 9 0 0 0-9 9H1l3.89 3.89.07.14L9 12H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.94-2.06l-1.42 1.42C8.27 19.99 10.51 21 13 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z', event: 'magic-sessions' },
    { id: 'stats', i18n: 'action_chat_stats', icon: 'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM9 17H7v-7h2v7zm4 0h-2V7h2v10zm4 0h-2v-4h2v4z', event: 'magic-stats' },
    { id: 'char-card', i18n: 'block_char_card', icon: 'M3 5v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2H5c-1.11 0-2 .9-2 2zm12 4c0 1.66-1.34 3-3 3s-3-1.34-3-3 1.34-3 3-3 3 1.34 3 3zm-9 8c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1H6v-1z', event: 'magic-char-card' },
    { id: 'lorebooks', i18n: 'menu_lorebooks', fallback: 'World Info', icon: 'M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z', event: 'magic-lorebooks' },
    { id: 'regex', i18n: 'menu_regex', fallback: 'Regex Scripts', icon: 'M20 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm-5 14H9v-2h6v2zm0-5H9v-2h6v2zm0-5H9V6h6v2z', event: 'magic-regex' },
    { id: 'api', i18n: 'tab_api', fallback: 'API', icon: 'M7.77 6.76L6.23 5.48.82 12l5.41 6.52 1.54-1.28L3.42 12l4.35-5.24zM7 13h2v-2H7v2zm10-2h-2v2h2v-2zm-6 2h2v-2h-2v2zm6.77-7.52l-1.54 1.28L20.58 12l-4.35 5.24 1.54 1.28L23.18 12l-5.41-6.52z', event: 'magic-api' },
    { id: 'presets', i18n: 'subtab_preset', fallback: 'Presets', icon: 'M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6h-6V2zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z', event: 'magic-presets' },
    { id: 'preview', i18n: 'magic_request_preview', icon: 'M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z', event: 'request-preview' },
    { id: 'personas', i18n: 'tab_personas', fallback: 'Personas', icon: 'M19 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm6 12H6v-1c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1z', event: 'magic-personas' },
    { id: 'connections', i18n: 'header_connections', fallback: 'Bindings', icon: 'M17 16l-4-4V8.82C14.16 8.4 15 7.3 15 6c0-1.66-1.34-3-3-3S9 4.34 9 6c0 1.3.84 2.4 2 2.82V12l-4 4H3v5h5v-3.05l4-4.2 4 4.2V21h5v-5h-4z', event: 'magic-connections' },
    { id: 'image-gen', i18n: 'imggen_title', fallback: 'Image Gen', icon: 'M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z', event: 'magic-image-gen' },
    { id: 'glossary', i18n: 'menu_glossary', fallback: 'Glossary', icon: 'M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z', event: 'magic-glossary' }
];

const loadDeletedItems = () => {
    try {
        const stored = localStorage.getItem('magic_drawer_deleted_items');
        return stored ? JSON.parse(stored) : [];
    } catch (e) {
        return [];
    }
};

const deletedItems = ref(loadDeletedItems());

watch(deletedItems, (newVal) => {
    localStorage.setItem('magic_drawer_deleted_items', JSON.stringify(newVal));
}, { deep: true });

const loadItems = () => {
    const deleted = loadDeletedItems();
    try {
        const stored = localStorage.getItem('magic_drawer_items');
        if (stored) {
            const parsed = JSON.parse(stored);
            // Filter out items that are no longer available (e.g. impersonate moved to ChatInput)
            const currentItems = parsed.filter(p => allAvailableItems.some(a => a.id === p.id));
            
            // Find items in allAvailableItems that are NOT in currentItems AND NOT in deleted
            const newItems = allAvailableItems.filter(a => 
                !currentItems.some(c => c.id === a.id) && 
                !deleted.includes(a.id)
            );
            
            return [...currentItems, ...newItems];
        }
    } catch (e) {
        console.error('Failed to load magic drawer items', e);
    }
    return [...allAvailableItems];
};

const items = ref(loadItems());

const displayItems = computed(() => {
    const list = items.value.map((item, index) => ({ ...item, originalIndex: index }));
    if (isEditing.value && canAdd.value) {
        list.push({ isAddBtn: true, id: 'add-btn' });
    }
    return list;
});

const canAdd = computed(() => {
    return allAvailableItems.some(i => !items.value.some(existing => existing.id === i.id));
});

watch(items, (newVal) => {
    localStorage.setItem('magic_drawer_items', JSON.stringify(newVal));
}, { deep: true });

watch(() => props.visible, (val) => {
    if (val) {
        isEditing.value = false;
        initLorebookState();
        nextTick(() => {
            const items = document.querySelectorAll('.magic-item-content');
            items.forEach(attachRipple);
        });
    }
});

const handleAction = (item) => {
    if (isEditing.value) return;
    if (item.id === 'personas') {
        personasSheet.value?.open();
    } else if (item.id === 'connections') {
        window.dispatchEvent(new CustomEvent('open-connections'));
        emit('close');
    } else if (item.id === 'image-gen') {
        emit('magic-image-gen');
        emit('close');
    } else {
        emit(item.event);
        emit('close');
    }
};

const toggleEdit = () => {
    isEditing.value = !isEditing.value;
};

const removeItem = (index) => {
    const item = items.value[index];
    if (item && item.id) {
        if (!deletedItems.value.includes(item.id)) {
            deletedItems.value.push(item.id);
        }
    }
    items.value.splice(index, 1);
};

const addItem = () => {
    const available = allAvailableItems.filter(i => !items.value.some(existing => existing.id === i.id));
    
    if (available.length === 0) return;

    showBottomSheet({
        title: t('add_block') || 'Add Block',
        items: available.map(item => ({
            label: t(item.i18n) || item.fallback,
            icon: `<svg viewBox="0 0 24 24"><path d="${item.icon}"/></svg>`,
            onClick: () => {
                items.value.push(item);
                deletedItems.value = deletedItems.value.filter(id => id !== item.id);
                closeBottomSheet();
            }
        }))
    });
};

// Drag and Drop Logic
const onDragStart = (e, index) => {
    if (!isEditing.value) return;
    dragSrcIndex.value = index;
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.dropEffect = 'move';
};

const onDragEnter = (e, index) => {
    if (dragSrcIndex.value === -1 || dragSrcIndex.value === index) return;
    const item = items.value.splice(dragSrcIndex.value, 1)[0];
    items.value.splice(index, 0, item);
    dragSrcIndex.value = index;
};

const onDragEnd = (e) => {
    dragSrcIndex.value = -1;
};

let touchStartX = 0;
let touchStartY = 0;

const onTouchStart = (e, index) => {
    touchStartX = e.touches[0].clientX;
    touchStartY = e.touches[0].clientY;

    longPressTimer = setTimeout(() => {
        if (!isEditing.value) {
            isEditing.value = true;
        }
        dragSrcIndex.value = index;
        if (navigator.vibrate) navigator.vibrate(50);
        document.body.style.overflow = 'hidden';
    }, 300);
};

const onTouchMove = (e) => {
    if (dragSrcIndex.value === -1) {
        if (Math.abs(e.touches[0].clientX - touchStartX) > 10 || Math.abs(e.touches[0].clientY - touchStartY) > 10) {
             clearTimeout(longPressTimer);
        }
        return;
    }
    e.preventDefault();
    const touch = e.touches[0];
    
    const target = document.elementFromPoint(touch.clientX, touch.clientY);
    
    const el = target?.closest('.magic-item');
    if (el && el.dataset.index !== undefined) {
        const index = parseInt(el.dataset.index);
        if (!isNaN(index) && index !== -1 && index !== dragSrcIndex.value) {
             const item = items.value.splice(dragSrcIndex.value, 1)[0];
             items.value.splice(index, 0, item);
             dragSrcIndex.value = index;
        }
    }
};

const onTouchEnd = (e) => {
    clearTimeout(longPressTimer);
    if (dragSrcIndex.value !== -1) {
        dragSrcIndex.value = -1;
        document.body.style.overflow = '';
    }
};

const lorebookEntryCount = computed(() => {
    return lorebookState.lorebooks.reduce((acc, lb) => acc + (lb.entries?.length || 0), 0);
});

const sessionCount = ref(0);
const messageCount = ref(0);
const chatHistory = ref([]);

const globalRegexScripts = ref([]);
const activeApiPresetName = ref('');

const loadRegexScripts = () => {
    try {
        const stored = localStorage.getItem('regex_scripts');
        globalRegexScripts.value = stored ? JSON.parse(stored) : [];
    } catch (e) {
        console.error('Failed to load regex scripts', e);
    }
};

const loadApiPresetName = async () => {
    try {
        const apiPresets = await getApiPresets();
        const activeId = localStorage.getItem('gz_active_api_preset_id') || 'default';
        const activePreset = apiPresets.find(p => p.id === activeId) || apiPresets[0];
        if (activePreset) {
            activeApiPresetName.value = activePreset.name;
        }
    } catch (e) {
        console.error('Failed to load API presets', e);
    }
};

const loadStatsData = async () => {
    if (!props.activeChar?.id) return;
    const charData = await db.getChat(props.activeChar.id);
    if (charData && charData.sessions) {
        sessionCount.value = Object.keys(charData.sessions).length;
        const sessionId = props.activeChar.sessionId || charData.currentId;
        if (charData.sessions[sessionId]) {
            const history = charData.sessions[sessionId];
            messageCount.value = history.length;
            chatHistory.value = history;
        }
    }
};

const resolveBlockContent = (block, preset, activeChar, persona, history) => {
    if (!block) return '';
    if (block.id === 'chat_history') {
        if (!history || history.length === 0) return '';
        return history.map(m => `${m.role === 'user' ? (persona?.name || 'User') : (activeChar?.name || 'Char')}: ${m.text}`).join('\n');
    }
    if (block.id === 'authors_note') return activeChar?.authors_note || '';
    if (block.id === 'summary') return activeChar?.summary || '';
    if (block.id === 'user_persona') return persona?.prompt || '';
    if (block.id === 'char_card') return activeChar?.description || activeChar?.desc || '';
    if (block.id === 'char_personality' || block.id === 'char_persona') return activeChar?.personality || '';
    if (block.id === 'scenario') return activeChar?.scenario || '';
    if (block.id === 'example_dialogue') return activeChar?.mes_example || '';
    if (block.id === 'first_message') return activeChar?.first_mes || '';
    return block.content || '';
};

const extendedReplaceMacros = (text, activeChar, persona) => {
    if (!text) return '';
    let res = replaceMacros(text, activeChar, persona);
    if (activeChar) {
        res = res.replace(/{{scenario}}/gi, activeChar.scenario || '')
                 .replace(/{{personality}}/gi, activeChar.personality || '')
                 .replace(/{{description}}/gi, activeChar.description || activeChar.desc || '')
                 .replace(/{{char_description}}/gi, activeChar.description || activeChar.desc || '')
                 .replace(/{{char_personality}}/gi, activeChar.personality || '');
    }
    if (persona) {
        res = res.replace(/{{persona}}/gi, persona.prompt || '');
    }
    return res;
};

const activePreset = computed(() => {
    const charId = props.activeChar?.id;
    const chatId = charId && props.activeChar?.sessionId ? `${charId}_${props.activeChar.sessionId}` : null;
    return getEffectivePreset(charId, chatId);
});

const activePresetName = computed(() => activePreset.value?.name || t('label_default'));

const activePresetTokens = computed(() => {
    const preset = activePreset.value;
    if (!preset) return 0;

    const charId = props.activeChar?.id;
    const chatId = charId && props.activeChar?.sessionId ? `${charId}_${props.activeChar.sessionId}` : null;
    const persona = getEffectivePersona(charId, chatId);
    let content = "";
    if (preset.impersonationPrompt) content += preset.impersonationPrompt + "\n";
    if (preset.blocks) {
        preset.blocks.forEach(b => {
            if (b.enabled && !b.isStashed) {
                const blockContent = resolveBlockContent(b, preset, props.activeChar, persona, chatHistory.value);
                if (blockContent) content += blockContent + "\n";
            }
        });
    }
    return estimateTokens(extendedReplaceMacros(content, props.activeChar, persona));
});

const activeRegexCount = computed(() => {
    let presetRegexes = [];
    if (props.activeChar?.id) {
        const chatId = props.activeChar.sessionId ? `${props.activeChar.id}_${props.activeChar.sessionId}` : null;
        const preset = getEffectivePreset(props.activeChar.id, chatId);
        if (preset && preset.regexes) {
            presetRegexes = preset.regexes;
        }
    }
    
    const all = [...presetRegexes, ...globalRegexScripts.value];
    return all.filter(s => !s.disabled).length;
});

const notesTokens = computed(() => estimateTokens(props.activeChar?.authors_note));
const summaryTokens = computed(() => estimateTokens(props.activeChar?.summary));
const cardTokens = computed(() => estimateTokens((props.activeChar?.name || '') + '\n' + (props.activeChar?.description || props.activeChar?.desc || '')));

const personaTokens = computed(() => {
    const persona = getEffectivePersona(props.activeChar?.id, props.activeChar?.sessionId ? `${props.activeChar.id}_${props.activeChar.sessionId}` : null);
    return estimateTokens((persona?.name || '') + '\n' + (persona?.prompt || ''));
});

const generationTokens = computed(() => {
    const prompt = getLastPrompt();
    if (!prompt || !prompt.messages) return 0;
    return prompt.messages.reduce((acc, m) => acc + estimateTokens(m.content), 0);
});

const imageGenEnabled = computed(() => getImageGenSettings().enabled);

const activeConnectionsCount = computed(() => {
    let count = 0;
    if (props.activeChar?.id) {
        // Preset connections
        if (presetState.connections.character[props.activeChar.id]) count++;
        const chatId = props.activeChar.sessionId ? `${props.activeChar.id}_${props.activeChar.sessionId}` : null;
        if (chatId && presetState.connections.chat[chatId]) count++;
        
        // Persona connections
        if (personaConnections.character[props.activeChar.id]) count++;
        if (chatId && personaConnections.chat[chatId]) count++;
    }
    return count;
});

watch(() => props.visible, (val) => {
    if (val) {
        loadStatsData();
        loadRegexScripts();
        loadApiPresetName();
    }
});

defineExpose({
    openPersonas: () => {
        personasSheet.value?.open();
    }
});
</script>

<template>
    <Transition name="drawer">
        <div v-if="visible" class="magic-drawer" @click.stop>
            <div class="drawer-header">
                <div class="drawer-title">{{ t('sheet_title_magic_drawer') || 'Magic Drawer' }}</div>
                <div class="edit-toggle" @click="toggleEdit">
                    <svg v-if="!isEditing" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    <svg v-else viewBox="0 0 24 24"><path d="M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4L9 16.2z"/></svg>
                    <span>{{ isEditing ? t('btn_save') : t('action_edit') }}</span>
                </div>
            </div>
            
            <div class="drawer-content">
                <template v-for="(item) in displayItems" :key="item.id">
                    <div v-if="!item.isAddBtn"
                            class="magic-item" 
                            :data-index="item.originalIndex"
                            :class="{ 'editing': isEditing, 'dragging': item.originalIndex === dragSrcIndex }"
                            :draggable="isEditing"
                            @click="handleAction(item)"
                            @dragstart="onDragStart($event, item.originalIndex)"
                            @dragenter.prevent="onDragEnter($event, item.originalIndex)"
                            @dragover.prevent
                            @dragend="onDragEnd"
                            @touchstart="onTouchStart($event, item.originalIndex)"
                            @touchmove="onTouchMove($event)"
                            @touchend="onTouchEnd($event)">
                        <div class="magic-item-content">
                            <div class="card-icon">
                                <svg viewBox="0 0 24 24"><path :d="item.icon"/></svg>
                            </div>
                            <div class="card-info">
                                <span class="item-label">{{ t(item.i18n) }}</span>
                                <span class="item-status" v-if="item.id === 'lorebooks'"><span>{{ lorebookEntryCount }} {{ pluralize(lorebookEntryCount, 'count_entries') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'notes'"><span>{{ notesTokens }} {{ pluralize(notesTokens, 'count_tokens') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'presets'"><span>{{ activePresetName }} · {{ activePresetTokens }} {{ pluralize(activePresetTokens, 'count_tokens') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'summary'"><span>{{ summaryTokens }} {{ pluralize(summaryTokens, 'count_tokens') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'char-card'"><span>{{ cardTokens }} {{ pluralize(cardTokens, 'count_tokens') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'personas'"><span>{{ personaTokens }} {{ pluralize(personaTokens, 'count_tokens') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'sessions'"><span>{{ sessionCount }} {{ pluralize(sessionCount, 'count_sessions') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'stats'"><span>{{ messageCount }} {{ pluralize(messageCount, 'count_messages') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'regex'"><span>{{ activeRegexCount }} {{ pluralize(activeRegexCount, 'count_scripts') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'api'"><span>{{ activeApiPresetName }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'connections'"><span>{{ activeConnectionsCount }} {{ pluralize(activeConnectionsCount, 'count_bindings') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'image-gen'"><span>{{ imageGenEnabled ? (t('imggen_status_on') || 'On') : (t('imggen_status_off') || 'Off') }}</span></span>
                                <span class="item-status" v-else-if="item.id === 'preview' && generationTokens > 0"><span>{{ generationTokens }} {{ pluralize(generationTokens, 'count_tokens') }}</span></span>
                            </div>
                        </div>
                        
                        <div v-if="isEditing" class="delete-btn" @click.stop="removeItem(item.originalIndex)">
                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                        </div>
                    </div>

                    <div v-else class="magic-item add-btn" @click="addItem">
                        <div class="magic-item-content">
                            <div class="card-icon add-icon">
                                <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                            </div>
                            <div class="card-info">
                                <span class="item-label">{{ t('btn_add') }}</span>
                            </div>
                        </div>
                    </div>
                </template>
            </div>
        </div>
    </Transition>
    <PersonasSheet ref="personasSheet" />
</template>

<style scoped>
/* Magic Drawer */
.magic-drawer {
    position: absolute;
    bottom: 0px;
    left: 0px;
    right: 0px;
    width: auto;
    height: calc(var(--keyboard-height, 300px));
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.95));
    backdrop-filter: blur(var(--element-blur, 30px));
    -webkit-backdrop-filter: blur(var(--element-blur, 30px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 24px 24px 0 0;
    display: flex;
    flex-direction: column;
    padding: 0;
    overflow: hidden;
    z-index: 1000;
    box-shadow: 0 -10px 40px rgba(0,0,0,0.2);
}

.drawer-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 20px;
    flex-shrink: 0;
}

.drawer-title {
    font-size: 17px;
    font-weight: 700;
    color: var(--text-black, #000);
    letter-spacing: -0.2px;
}

.drawer-content {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    scrollbar-gutter: stable;
    padding: 4px 10px calc(30px + var(--sab)) 10px;
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 8px 6px;
    align-content: start;
}

.drawer-enter-active,
.drawer-leave-active {
  transition: transform 0.4s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.3s ease;
  overflow: hidden !important;
}

.drawer-enter-from,
.drawer-leave-to {
  transform: translateY(100%);
  opacity: 0;
}

.magic-item {
    position: relative;
    width: 100%;
    min-width: 0;
    min-height: 48px;
    cursor: pointer;
    background-color: rgba(var(--ui-bg-rgb), 0.3);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.06));
    border-radius: 14px;
    padding: 6px 8px;
    transition: transform 0.2s cubic-bezier(0.2, 0, 0.2, 1), background-color 0.2s ease, border-color 0.2s ease;
    display: flex;
    align-items: center;
    overflow: hidden;
}

.magic-item:active {
    transform: scale(0.96);
    background-color: rgba(var(--ui-bg-rgb), 0.5);
}

.magic-item-content {
    width: 100%;
    display: flex;
    flex-direction: row;
    align-items: center;
    gap: 6px;
}

.card-icon {
    width: 28px;
    height: 28px;
    flex-shrink: 0;
    padding: 5px;
    background-color: var(--accent-color, rgba(var(--ui-bg-rgb), 0.1));
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
}

.card-icon svg {
    width: 100%;
    height: 100%;
    fill: var(--text-black);
    opacity: 0.8;
}

.add-icon {
    background-color: rgba(var(--ui-bg-rgb), 0.05);
}

.card-info {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
}

.item-label {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-black);
    line-height: 1;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
}

.item-status {
    font-size: 9px;
    font-weight: 400;
    color: var(--text-gray);
    opacity: 0.7;
    margin-top: 1px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    display: block;
    width: 100%;
}

.magic-item:hover .item-status,
.magic-item:active .item-status {
    text-overflow: clip;
}

.magic-item:hover .item-status span,
.magic-item:active .item-status span {
    display: inline-block !important;
    min-width: max-content;
    animation: marquee-scroll 10s linear infinite !important;
    padding-left: 20px;
}

@keyframes marquee-scroll {
    0% { transform: translateX(0); }
    100% { transform: translateX(-100%); }
}

.edit-toggle {
    height: 34px;
    padding: 0 14px;
    background-color: rgba(var(--ui-bg-rgb), 0.08);
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 17px;
    display: flex;
    align-items: center;
    gap: 8px;
    cursor: pointer;
    transition: all 0.2s ease;
}

.edit-toggle:active {
    transform: scale(0.95);
    background-color: rgba(var(--ui-bg-rgb), 0.15);
}

.edit-toggle svg {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
}

.edit-toggle span {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-gray);
}

.magic-item.editing {
    border-style: dashed;
    border-color: var(--accent-color, #4facfe);
    box-shadow: 0 0 0 2px rgba(var(--ui-bg-rgb), 0.1);
}

.delete-btn {
    position: absolute;
    top: -8px;
    right: -8px;
    width: 24px;
    height: 24px;
    background: #FF3B30;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    box-shadow: 0 4px 8px rgba(255,59,48,0.3);
    z-index: 10;
}

.delete-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

/* Dark Theme Support */
:global(body.dark-theme) .magic-drawer { 
    background-color: rgba(20, 20, 22, 0.85); 
    border-color: rgba(255,255,255,0.08); 
}
:global(body.dark-theme) .drawer-title { color: #ffffff; }
:global(body.dark-theme) .magic-item { 
    background-color: rgba(255, 255, 255, 0.04); 
    border-color: rgba(255, 255, 255, 0.06); 
}
:global(body.dark-theme) .magic-item:active { background-color: rgba(255, 255, 255, 0.08); }
:global(body.dark-theme) .item-label { color: #f0f0f0; }
:global(body.dark-theme) .card-icon svg { fill: #ffffff; }
:global(body.dark-theme) .edit-toggle { background-color: rgba(255, 255, 255, 0.06); color: #aaaaaa; }
:global(body.dark-theme) .edit-toggle span { color: #aaaaaa; }
:global(body.dark-theme) .item-status { color: #8a8a8e; }
</style>
