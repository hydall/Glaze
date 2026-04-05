<script setup>
import { ref, reactive, computed, onMounted, onBeforeUnmount, watch, nextTick } from 'vue';
import { updateLanguage, translations, t } from '@/utils/i18n.js';
import { initRipple } from '@/core/services/ui.js';
import Editor from '@/components/editors/GenericEditor.vue';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import { getEffectivePersona } from '@/core/states/personaState.js';
import { convertSTPreset, exportSTPreset, mandatoryBlocks } from '@/core/services/presetImportService.js';
import { generateSummary } from '@/core/services/generationService.js';
import { presetState, initPresetState, setPresetConnection, getEffectivePresetId, DEFAULT_PRESETS, flushPresetSave } from '@/core/states/presetState.js';
import { Browser } from '@capacitor/browser';
import { Toast } from '@capacitor/toast';
import { saveFile } from '@/core/services/fileSaver.js';
import SheetView from '@/components/ui/SheetView.vue';
import HelpTip from '@/components/ui/HelpTip.vue';
import { logger } from '../utils/logger.js';

const emit = defineEmits(['open-fs']);

function handleOpenFs(field, isCurrentBase = true) {
    const val = isCurrentBase ? currentPreset.value[field] : field; // if field is the value itself
    const onSave = (newVal) => {
        if (isCurrentBase) {
            currentPreset.value[field] = newVal;
        }
    };
    window.dispatchEvent(new CustomEvent('open-fs-request', { detail: { value: val, onSave } }));
}

const sheet = ref(null);

const props = defineProps({
    activeChatChar: { type: Object, default: null },
    chatHistory: { type: Array, default: () => [] },
    isGenerating: { type: Boolean, default: false }
});

const effectivePersona = computed(() => getEffectivePersona(props.activeChatChar?.id, props.activeChatChar?.sessionId));

const showAdvancedSettings = ref(false);

const genSheetBodyRef = ref(null);
let savedScrollPos = 0;

const headerState = reactive({
    title: '',
    showBack: false,
    actions: []
});



async function open() {
    await initPresetState();
    await loadPresets();
    if (!sheet.value?.isVisible && !editingPresetId.value) {
        // If it's a completely fresh open and no preset is currently edited, make sure we don't open the editor.
        // However, if editingPresetId.value is set from a previous session, we leave it as is to restore the view.
    }
    sheet.value?.open();
    updateHeaderState();
}

function close() {
    sheet.value?.close();
}

async function openPreset(id) {
    await initPresetState();
    await loadPresets();
    editingPresetId.value = id;
    sheet.value?.open();
    updateHeaderState();
}

defineExpose({ open, close, openAuthorsNoteSheet, openSummarySheet, openPreset });



function openMergeRoleSelector() {
    const roles = ['system', 'user', 'assistant'];
    const items = roles.map(r => ({
        label: r.charAt(0).toUpperCase() + r.slice(1),
        icon: currentPreset.value.mergeRole === r ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
        onClick: () => {
            currentPreset.value.mergeRole = r;
            closeBottomSheet();
        }
    }));
    showBottomSheet({
        title: t('label_role') || 'Role',
        items: items
    });
}

function openSquashRoleSelector() {
    const options = ['user', 'system', 'assistant'];
    const items = options.map(r => ({
        label: r.charAt(0).toUpperCase() + r.slice(1),
        icon: currentPreset.value.squashRole === r ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
        onClick: () => {
            currentPreset.value.squashRole = r;
            closeBottomSheet();
        }
    }));
    showBottomSheet({
        title: t('label_squash_role') || 'Squash Role',
        items: items
    });
}

// --- Editor State ---
const isEditingBlock = ref(false);
const editingBlockId = ref(null);
const showStash = ref(false);

const activeBlocks = computed(() => {
    if (!currentPreset.value || !currentPreset.value.blocks) return [];
    return currentPreset.value.blocks.filter(b => !b.isStashed);
});

const stashedBlocks = computed(() => {
    if (!currentPreset.value || !currentPreset.value.blocks) return [];
    return currentPreset.value.blocks.filter(b => b.isStashed);
});

// --- Computed ---
const editingPresetId = ref(null);
const optimisticGlobalPresetId = ref(null);

const effectivePresetId = computed(() => {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    const resolved = getEffectivePresetId(charId, chatId);
    logger.debug('[GenerationView] effectivePresetId resolved to:', resolved);
    return resolved;
});

const currentPresetId = computed(() => {
    return editingPresetId.value || effectivePresetId.value;
});

const currentPreset = computed(() => {
    const id = currentPresetId.value;
    return presetState.presets[id] || presetState.presets['default'] || Object.values(presetState.presets)[0];
});

const activePresetName = computed(() => {
    const id = effectivePresetId.value;
    const name = presetState.presets[id]?.name || 'Default';
    logger.debug('[GenerationView] activePresetName resolved to:', name, 'for ID:', id);
    return name;
});

const activePresetType = computed(() => {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    
    if (chatId && presetState.connections.chat[chatId]) return 'chat';
    if (charId && presetState.connections.character[charId]) return 'character';
    return 'global';
});

const activePresetReason = computed(() => {
    switch(activePresetType.value) {
        case 'chat': return t('connection_chat') || 'Chat Connection';
        case 'character': return t('connection_character') || 'Character Connection';
        default: return t('connection_global') || 'Global Preset';
    }
});

const chatPresetName = computed(() => {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    const id = chatId ? presetState.connections.chat[chatId] : null;
    return id ? (presetState.presets[id]?.name || id) : null;
});

const charPresetName = computed(() => {
    const charId = props.activeChatChar?.id;
    const id = charId ? presetState.connections.character[charId] : null;
    return id ? (presetState.presets[id]?.name || id) : null;
});

const globalPresetName = computed(() => {
    const id = presetState.globalPresetId;
    return presetState.presets[id]?.name || 'Default';
});

function openLevelSelector(level) {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    
    let currentId = null;
    if (level === 'global') currentId = presetState.globalPresetId;
    else if (level === 'character') currentId = charId ? presetState.connections.character[charId] : null;
    else if (level === 'chat') currentId = chatId ? presetState.connections.chat[chatId] : null;

    const cardItems = [];
    
    if (level !== 'global') {
        cardItems.push({
            label: '(' + (t('label_none') || 'Default / None') + ')',
            icon: !currentId ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : '<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.42 0-8-3.58-8-8 0-1.85.63-3.55 1.69-4.9l11.21 11.21C15.55 19.37 13.85 20 12 20zm6.31-3.1L7.1 5.69C8.45 4.63 10.15 4 12 4c4.42 0 8 3.58 8 8 0 1.85-.63 3.55-1.69 4.9z"/></svg>',
            onClick: () => {
                if (level === 'character') setPresetConnection('character', charId, null);
                else if (level === 'chat') setPresetConnection('chat', chatId, null);
                editingPresetId.value = null;
                closeBottomSheet();
            }
        });
    }

    const entries = Object.entries(presetState.presets).sort((a, b) => {
        const wA = getPresetWeight(a[0], a[1]);
        const wB = getPresetWeight(b[0], b[1]);
        if (wA !== wB) return wA - wB;
        return a[1].name.localeCompare(b[1].name);
    });

    entries.forEach(([id, preset]) => {
        const tokens = getPresetTokens(preset);
        const subtitleParts = [];
        if (id === currentId) subtitleParts.push(t('preset_selected') || 'Selected');
        if (preset.author) subtitleParts.push(`by ${preset.author}`);
        if (preset.descriptionKey) subtitleParts.push(t(preset.descriptionKey));

        cardItems.push({
            label: preset.name,
            sublabel: subtitleParts.join(' • '),
            badge: `${tokens}`,
            isFeatured: preset.isFeatured,
            image: preset.image || null,
            icon: !preset.image ? '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>' : null,
            onClick: () => {
                if (level === 'global') setPresetConnection('global', null, id);
                else if (level === 'character') setPresetConnection('character', charId, id);
                else if (level === 'chat') setPresetConnection('chat', chatId, id);
                editingPresetId.value = id;
                closeBottomSheet();
            }
        });
    });

    const titleMap = {
        'global': t('level_global') || 'Global Preset',
        'character': t('level_character') || 'Character Preset',
        'chat': t('level_chat') || 'Chat Preset'
    };

    showBottomSheet({
        title: (t('action_select') || 'Select') + ': ' + titleMap[level],
        cardItems: cardItems
    });
}

function openPresetEditorSelector() {
    const entries = Object.entries(presetState.presets).sort((a, b) => {
        const wA = getPresetWeight(a[0], a[1]);
        const wB = getPresetWeight(b[0], b[1]);
        if (wA !== wB) return wA - wB;
        return a[1].name.localeCompare(b[1].name);
    });

    const cardItems = entries.map(([id, preset]) => {
        const tokens = getPresetTokens(preset);
        const subtitleParts = [];
        if (id === currentPresetId.value) subtitleParts.push(t('preset_selected') || 'Selected');
        if (preset.author) subtitleParts.push(`by ${preset.author}`);
        if (preset.descriptionKey) subtitleParts.push(t(preset.descriptionKey));

        const item = {
            label: preset.name,
            sublabel: subtitleParts.join(' • '),
            badge: `${tokens}`,
            isFeatured: preset.isFeatured,
            image: preset.image || null,
            icon: !preset.image ? '<svg viewBox="0 0 24 24" style="fill:currentColor;width:24px;height:24px;"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>' : null,
            onClick: () => {
                editingPresetId.value = id;
                closeBottomSheet();
                updateHeaderState();
            }
        };

        if (!DEFAULT_PRESETS[id]) {
            item.actions = [{
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                color: '#ff4444',
                onClick: (e) => {
                    e.stopPropagation();
                    closeBottomSheet();
                    confirmDeletePreset(id);
                }
            }];
        }

        return item;
    });

    cardItems.push({
        label: t('btn_add') || 'Add / Import',
        sublabel: t('preset_create_import_desc') || 'Create or import a new preset',
        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            openAddPresetSheet();
        }
    });

    showBottomSheet({
        title: t('sheet_title_presets') || 'Presets',
        cardItems: cardItems
    });
}

watch(() => props.activeChatChar?.id, () => {
    editingPresetId.value = null;
});

const activeEditBlock = computed(() => {
    if (!editingBlockId.value) return null;
    return currentPreset.value.blocks.find(b => b.id === editingBlockId.value);
});

const resolveBlockContent = (block) => {
    if (!block) return '';
    
    if (block.id === 'chat_history') {
        if (!props.chatHistory || props.chatHistory.length === 0) return '';
        return props.chatHistory.map(m => `${m.role === 'user' ? (m.persona?.name || 'User') : (props.activeChatChar?.name || 'Char')}: ${m.text}`).join('\n');
    }
    
    if (block.id === 'guided_generation') return block.content || '[System Note: {{guidance}}]';
    if (block.id === 'authors_note') return props.activeChatChar?.authors_note || '';
    if (block.id === 'summary') return props.activeChatChar?.summary || '';
    
    if (block.id === 'user_persona') return effectivePersona.value?.prompt || '';
    if (block.id === 'char_card') return props.activeChatChar?.description || '';
    if (block.id === 'char_personality' || block.id === 'char_persona') return props.activeChatChar?.personality || '';
    if (block.id === 'scenario') return props.activeChatChar?.scenario || '';
    if (block.id === 'example_dialogue') return props.activeChatChar?.mes_example || '';
    if (block.id === 'first_message') return props.activeChatChar?.first_mes || '';

    return block.content || '';
};

const extendedReplaceMacros = (text) => {
    if (!text) return '';
    let res = replaceMacros(text, props.activeChatChar, effectivePersona.value);
    
    if (props.activeChatChar) {
        res = res.replace(/{{scenario}}/gi, props.activeChatChar.scenario || '')
                 .replace(/{{personality}}/gi, props.activeChatChar.personality || '')
                 .replace(/{{description}}/gi, props.activeChatChar.description || '')
                 .replace(/{{char_description}}/gi, props.activeChatChar.description || '')
                 .replace(/{{char_personality}}/gi, props.activeChatChar.personality || '');
    }
    if (effectivePersona.value) {
        res = res.replace(/{{persona}}/gi, effectivePersona.value.prompt || '');
    }
    return res;
};

const getPresetTokens = (preset) => {
    if (!preset) return 0;
    let content = "";
    // Include Enabled Blocks
    if (preset.blocks) {
        preset.blocks.forEach(b => {
            if (b.enabled && !b.isStashed) {
                const blockContent = resolveBlockContent(b);
                if (blockContent) {
                    content += blockContent + "\n";
                }
            }
        });
    }
    return estimateTokens(extendedReplaceMacros(content));
};

const editingPresetTokens = computed(() => getPresetTokens(currentPreset.value));
const displayedEditingTokens = ref(0);

const activePresetTokens = computed(() => {
    const id = effectivePresetId.value;
    const preset = presetState.presets[id] || presetState.presets['default'];
    return getPresetTokens(preset);
});
const displayedActiveTokens = ref(0);

const globalTokens = computed(() => getPresetTokens(presetState.presets[presetState.globalPresetId] || presetState.presets['default']));
const charTokens = computed(() => {
    const charId = props.activeChatChar?.id;
    const id = charId ? presetState.connections.character[charId] : null;
    return id ? getPresetTokens(presetState.presets[id]) : 0;
});
const chatTokens = computed(() => {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    const id = chatId ? presetState.connections.chat[chatId] : null;
    return id ? getPresetTokens(presetState.presets[id]) : 0;
});

function setupAnimateTokens(targetComputed, targetRef) {
    watch(targetComputed, (newVal, oldVal) => {
        if (props.isGenerating) return; // Pause recalculation animation during streaming
        if (oldVal === undefined) {
            targetRef.value = newVal;
            return;
        }
        const start = targetRef.value;
        const end = newVal;
        const duration = 300;
        const startTime = performance.now();
        const animate = (currentTime) => {
            const elapsed = currentTime - startTime;
            const progress = Math.min(elapsed / duration, 1);
            const ease = 1 - Math.pow(1 - progress, 3);
            targetRef.value = Math.round(start + (end - start) * ease);
            if (progress < 1) requestAnimationFrame(animate);
        };
        requestAnimationFrame(animate);
    }, { immediate: true });
}

setupAnimateTokens(activePresetTokens, displayedActiveTokens);
setupAnimateTokens(editingPresetTokens, displayedEditingTokens);

const getBlockTokens = (blockOrContent) => {
    // Handle direct content string (legacy)
    if (typeof blockOrContent === 'string') {
        return estimateTokens(extendedReplaceMacros(blockOrContent));
    }
    
    const block = blockOrContent;
    if (!block) return 0;

    const content = resolveBlockContent(block);
    if (!content) return 0;
    return estimateTokens(extendedReplaceMacros(content));
};

const getPresetWeight = (id, preset) => {
    if (preset.isFeatured) return -3;
    if (id === 'default') return -2;
    if (DEFAULT_PRESETS[id]) return -1;
    return 0;
};

// Sorted preset entries for the selector list
const sortedPresetEntries = computed(() => {
    return Object.entries(presetState.presets)
        .sort((a, b) => {
            const wA = getPresetWeight(a[0], a[1]);
            const wB = getPresetWeight(b[0], b[1]);
            if (wA !== wB) return wA - wB;
            return a[1].name.localeCompare(b[1].name);
        });
});

// Get connection type for a preset relative to current char/chat
function getPresetConnectionType(presetId) {
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    if (chatId && presetState.connections.chat[chatId] === presetId) return 'chat';
    if (charId && presetState.connections.character[charId] === presetId) return 'character';
    
    if (optimisticGlobalPresetId.value === presetId) return 'global';
    if (!optimisticGlobalPresetId.value && presetState.globalPresetId === presetId) return 'global';
    return null;
}

function openPresetConnections(presetId, event) {
    event.stopPropagation();
    const preset = presetState.presets[presetId];
    if (preset) {
        window.dispatchEvent(new CustomEvent('open-connections', { detail: { type: 'preset', id: presetId, name: preset.name } }));
    }
}

function activatePreset(presetId) {
    optimisticGlobalPresetId.value = presetId;
    setTimeout(() => {
        setPresetConnection('global', null, presetId);
        optimisticGlobalPresetId.value = null;
    }, 10);
}

// --- Helpers ---

// --- Methods ---
async function loadPresets() {
    await initPresetState();
    
    // Ensure ALL mandatory blocks exist for all presets
    logger.debug('[GenerationView] loadPresets: Checking commands for', Object.keys(presetState.presets).length, 'presets');
    for (const key in presetState.presets) {
        const preset = presetState.presets[key];
        if (preset.reasoningEnabled === undefined) preset.reasoningEnabled = false;
        if (preset.parseInlineReasoning === undefined) preset.parseInlineReasoning = false;
        if (preset.mergePrompts === undefined) preset.mergePrompts = false;
        if (preset.mergeRole === undefined) preset.mergeRole = 'system';
        if (preset.noAssistant === undefined) preset.noAssistant = false;
        if (preset.stopString === undefined) preset.stopString = '';
        if (preset.userPrefix === undefined) preset.userPrefix = '';
        if (preset.charPrefix === undefined) preset.charPrefix = '';
        if (preset.squashRole === undefined || preset.squashRole === '') preset.squashRole = 'assistant';
        if (preset.author === undefined) preset.author = '';
        if (preset.image === undefined) preset.image = '';
        if (preset.summaryPrompt === undefined) {
            preset.summaryPrompt = 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}\n\nSummary:';
        }
        if (preset.guidedGenerationPrompt === undefined) preset.guidedGenerationPrompt = '[Generate your next reply according to these instructions: {{guidance}}]';
        if (preset.guidedImpersonationPrompt === undefined) preset.guidedImpersonationPrompt = '[Instead of replying for {{char}}, impersonate {{user}} according to these instructions: {{guidance}}]';

        const blocks = preset.blocks;
        if (!blocks) continue;

        mandatoryBlocks.forEach(mb => {
            if (!blocks.find(b => b.id === mb.id)) {
                if (mb.id === 'chat_history') {
                     blocks.push({ ...mb });
                } else {
                     let insertIndex = blocks.length;
                     const myIndex = mandatoryBlocks.findIndex(m => m.id === mb.id);
                     if (myIndex > 0) {
                         const prevId = mandatoryBlocks[myIndex-1].id;
                         const prevIdxInPreset = blocks.findIndex(b => b.id === prevId);
                         if (prevIdxInPreset !== -1) insertIndex = prevIdxInPreset + 1;
                     } else {
                         // First mandatory block — find next existing mandatory and insert before it
                         for (let i = myIndex + 1; i < mandatoryBlocks.length; i++) {
                             const nextIdx = blocks.findIndex(b => b.id === mandatoryBlocks[i].id);
                             if (nextIdx !== -1) { insertIndex = nextIdx; break; }
                         }
                     }
                     blocks.splice(insertIndex, 0, { ...mb });
                }
            }
        });

        if (!blocks.find(b => b.id === 'summary')) {
            const historyIdx = blocks.findIndex(b => b.id === 'chat_history');
            const insertIdx = historyIdx !== -1 ? historyIdx : blocks.length;
            blocks.splice(insertIdx, 0, { id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_summary', depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' });
        }
        if (!blocks.find(b => b.id === 'authors_note')) {
            const historyIdx = blocks.findIndex(b => b.id === 'chat_history');
            const insertIdx = historyIdx !== -1 ? historyIdx + 1 : blocks.length;
            blocks.splice(insertIdx, 0, { id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_authors_notes', insertion_mode: 'relative' });
        }
        if (!blocks.find(b => b.id === 'guided_generation')) {
            const authorsIdx = blocks.findIndex(b => b.id === 'authors_note');
            const historyIdx = blocks.findIndex(b => b.id === 'chat_history');
            const insertIdx = authorsIdx !== -1 ? authorsIdx + 1 : (historyIdx !== -1 ? historyIdx + 1 : blocks.length);
            blocks.splice(insertIdx, 0, { id: 'guided_generation', name: 'Guided Generation', role: 'system', content: '[System Note: {{guidance}}]', enabled: true, isStatic: true, i18n: 'block_guided_generation', insertion_mode: 'relative' });
        }
    }
}

function savePresets() {
    // Logic moved to presetState.js auto-watcher, but we can keep trigger if needed
}

// Watch for changes to save automatically
watch(() => presetState, () => {}, { deep: true });

watch(() => currentPreset.value?.noAssistant, (val) => {
    if (val && currentPreset.value) {
        currentPreset.value.mergePrompts = true;
    }
});

watch(() => currentPreset.value?.reasoningEnabled, (val) => {
    localStorage.setItem('gz_api_request_reasoning', val);
});

function createNewPreset() {
    showBottomSheet({
        title: t('new_preset') || 'New Preset',
        input: {
            placeholder: t('placeholder_preset_name') || 'Enter preset name',
            value: '',
            confirmLabel: t('btn_create') || 'Create',
            onConfirm: (name) => {
                const id = Date.now().toString(36);
                presetState.presets[id] = {
                    id: id,
                    name: name,
                    blocks: [],
                    author: '',
                    image: '',
                    impersonationPrompt: '',
                    reasoningEnabled: false,
                    parseInlineReasoning: false,
                    reasoningStart: '<think>',
                    reasoningEnd: '</think>',
                    mergePrompts: false,
                    mergeRole: 'system',
                    noAssistant: false,
                    stopString: '',
                    userPrefix: '',
                    charPrefix: '',
                    squashRole: 'assistant',
                    summaryPrompt: 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}\n\nSummary:',
                    guidedGenerationPrompt: '[Generate your next reply according to these instructions: {{guidance}}]',
                    guidedImpersonationPrompt: '[Instead of replying for {{char}}, impersonate {{user}} according to these instructions: {{guidance}}]'
                };
                // Ensure mandatory blocks are present
                presetState.presets[id].blocks = [
                    { id: 'sys1', name: 'Main System', role: 'system', content: 'You are a helpful AI assistant.', enabled: true },
                    ...mandatoryBlocks.filter(b => b.id !== 'chat_history' && b.id !== 'guided_generation').map(b => ({...b})),
                    { id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_summary', depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' },
                    { id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_authors_notes', insertion_mode: 'relative' },
                    { ...mandatoryBlocks.find(b => b.id === 'chat_history') },
                    { ...mandatoryBlocks.find(b => b.id === 'guided_generation') },
                ];
                setPresetConnection('global', null, id);
                editingPresetId.value = id;
                closeBottomSheet();
                updateHeaderState();
            }
        }
    });
}

function openPresetSelector() {
    const cardItems = [];
    const charId = props.activeChatChar?.id;
    const chatId = charId && props.activeChatChar?.sessionId ? `${charId}_${props.activeChatChar.sessionId}` : null;
    
    const entries = Object.entries(presetState.presets).sort((a, b) => {
        const wA = getPresetWeight(a[0], a[1]);
        const wB = getPresetWeight(b[0], b[1]);
        if (wA !== wB) return wA - wB;
        return a[1].name.localeCompare(b[1].name);
    });

    entries.forEach(([id, preset]) => {
        const tokens = getPresetTokens(preset);
        const isGlobal = presetState.globalPresetId === id;
        const isChar = charId && presetState.connections.character[charId] === id;
        const isChat = chatId && presetState.connections.chat[chatId] === id;
        const isActive = currentPresetId.value === id;

        const subtitleParts = [];
        if (preset.author) subtitleParts.push(`by ${preset.author}`);
        if (preset.descriptionKey) subtitleParts.push(t(preset.descriptionKey));
        if (isActive) subtitleParts.push(t('preset_selected') || 'Selected');
        if (isChat) subtitleParts.push(t('preset_this_chat') || 'This Chat');
        if (isChar) subtitleParts.push(t('preset_this_char') || 'This Character');
        if (isGlobal) subtitleParts.push(t('preset_global_default') || 'Global Default');

        const item = {
            label: preset.name,
            sublabel: subtitleParts.join(' • ') || (t('preset_saved') || 'Saved Preset'),
            badge: `${tokens}`,
            isFeatured: preset.isFeatured,
            image: preset.image || null,
            icon: !preset.image ? '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>' : null,
            onClick: () => {
                editingPresetId.value = id;
                closeBottomSheet();
                updateHeaderState();
            }
        };

        cardItems.push(item);
    });

    cardItems.push({
        label: t('btn_add') || 'Add / Import',
        sublabel: t('preset_create_import_desc') || 'Create or import a new preset',
        icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:24px;height:24px;"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            openAddPresetSheet();
        }
    });

    showBottomSheet({
        title: t('sheet_title_presets') || 'Presets',
        cardItems: cardItems
    });
}

function openPresetConnectionManager() {
    const preset = currentPreset.value;
    if (preset) {
        window.dispatchEvent(new CustomEvent('open-connections', { detail: { type: 'preset', id: preset.id, name: preset.name } }));
    }
}

function openPresetOptionsMenu() {
    const isDefault = !!DEFAULT_PRESETS[currentPresetId.value];
    const items = [];

    let authorLinkResolved = currentPreset.value.authorLink;
    if (!authorLinkResolved) {
        const authorName = (currentPreset.value.author || '').toLowerCase();
        if (authorName === 'microcot') authorLinkResolved = 'https://t.me/sillytavern1';
        else if (authorName === 'fawn1e' || authorName === 'fawnie') authorLinkResolved = 'https://t.me/dearfawwn';
    }

    if (authorLinkResolved) {
        items.push({
            label: t('author_link') || 'Author link',
            icon: '<svg viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>',
            onClick: async () => {
                closeBottomSheet();
                await Browser.open({ url: authorLinkResolved });
            }
        });
    }

    // Clone preset (available for all presets)
    items.push({
        label: t('action_clone') || 'Clone Preset',
        icon: '<svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            cloneCurrentPreset();
        }
    });

    items.push({
        label: t('action_export_st') || 'Export as ST Preset',
        icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
        onClick: () => {
            closeBottomSheet();
            triggerExportST();
        }
    });

    if (!isDefault) {
        items.push(
            {
                label: t('action_edit_name') || 'Change Name',
                icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
                onClick: () => {
                    renameCurrentPreset();
                }
            },
            {
                label: t('change_author') || 'Change Author',
                icon: '<svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>',
                onClick: () => {
                    editCurrentAuthor();
                }
            },
            {
                label: t('change_image') || 'Change Image',
                icon: '<svg viewBox="0 0 24 24"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    triggerImageUpload();
                }
            }
        );
    } else {
        items.push({
            label: t('action_reset') || 'Reset to Default',
            icon: '<svg viewBox="0 0 24 24"><path d="M12 5V1L7 6l5 5V7c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H4c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                confirmResetPreset(currentPresetId.value);
            }
        });
    }

    if (!isDefault) {
        items.push({
            label: t('btn_delete') || 'Delete Preset',
            icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
            iconColor: '#ff4444',
            isDestructive: true,
            onClick: () => {
                closeBottomSheet();
                confirmDeletePreset(currentPreset.value.id);
            }
        });
    }

    showBottomSheet({
        title: t('preset_options') || 'Preset Options',
        items
    });
}

function cloneCurrentPreset() {
    const source = currentPreset.value;
    const newId = Date.now().toString(36) + Math.random().toString(36).substr(2, 4);
    const clone = JSON.parse(JSON.stringify(source));
    clone.id = newId;
    clone.name = (source.name || 'Preset') + ' (copy)';
    clone.isFeatured = false;
    // Regenerate block IDs to avoid conflicts
    if (clone.blocks) {
        clone.blocks.forEach(b => {
            if (!b.isStatic && !mandatoryBlocks.find(mb => mb.id === b.id)) {
                b.id = Date.now().toString(36) + Math.random().toString(36).substr(2, 6);
            }
        });
    }
    presetState.presets[newId] = clone;
    setPresetConnection('global', null, newId);
    editingPresetId.value = newId;
    updateHeaderState();
}

function renameCurrentPreset() {
    showBottomSheet({
        title: t('action_edit_name') || 'Change Name',
        input: {
            placeholder: t('placeholder_preset_name') || 'Enter preset name',
            value: currentPreset.value.name,
            confirmLabel: t('btn_save') || 'Save',
            onConfirm: (newName) => {
                if (newName) currentPreset.value.name = newName;
                closeBottomSheet();
            }
        }
    });
}

async function triggerExportST() {
    try {
        const exportedData = exportSTPreset(currentPreset.value);
        const fileName = (currentPreset.value.name || 'Preset').replace(/[^a-z0-9а-яё]/gi, '_').toLowerCase();
        const filename = `${fileName}.json`;
        
        await saveFile(filename, JSON.stringify(exportedData, null, 4), 'application/json', 'presets');
    } catch (e) {
        console.error("Export ST Preset failed", e);
        alert("Export failed: " + e.message);
    }
}

function editCurrentAuthor() {
    showBottomSheet({
        title: t('change_author') || 'Change Author',
        input: {
            placeholder: t('placeholder_author_name') || 'Enter author name',
            value: currentPreset.value.author,
            confirmLabel: t('btn_save') || 'Save',
            onConfirm: (newAuthor) => {
                currentPreset.value.author = newAuthor;
                closeBottomSheet();
            }
        }
    });
}

function triggerImageUpload() {
    document.getElementById('preset-image-input').click();
}

async function compressImage(base64Str, maxWidth = 1200, maxHeight = 800, quality = 0.7) {
    return new Promise((resolve) => {
        const img = new Image();
        img.src = base64Str;
        img.onload = () => {
            const canvas = document.createElement('canvas');
            let width = img.width;
            let height = img.height;

            if (width > height) {
                if (width > maxWidth) {
                    height *= maxWidth / width;
                    width = maxWidth;
                }
            } else {
                if (height > maxHeight) {
                    width *= maxHeight / height;
                    height = maxHeight;
                }
            }

            canvas.width = width;
            canvas.height = height;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, width, height);
            resolve(canvas.toDataURL('image/jpeg', quality));
        };
    });
}

function onImageSelected(event) {
    const file = event.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = async (e) => {
        const compressed = await compressImage(e.target.result);
        currentPreset.value.image = compressed;
    };
    reader.readAsDataURL(file);
}

function openAddPresetSheet() {
    const items = [
        {
            label: t('action_create_new') || 'Create New',
            icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                createNewPreset();
            }
        },
        {
            label: t('action_import') || 'Import from file',
            icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                triggerImport();
            }
        }
    ];

    showBottomSheet({
        title: t('sheet_title_presets') || 'Presets',
        items: items
    });
}

function confirmDeletePreset(id) {
    const presetName = presetState.presets[id]?.name;
    showBottomSheet({
        title: `${t('confirm_delete_preset')} "${presetName}"?`,
        items: [
            {
                label: t('btn_yes') || 'Yes',
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    if (id === 'default') return;
                    delete presetState.presets[id];
                    // Clean up connections
                    Object.keys(presetState.connections.character).forEach(k => {
                        if (presetState.connections.character[k] === id) delete presetState.connections.character[k];
                    });
                    Object.keys(presetState.connections.chat).forEach(k => {
                        if (presetState.connections.chat[k] === id) delete presetState.connections.chat[k];
                    });
                    if (presetState.globalPresetId === id) presetState.globalPresetId = 'default';
                    
                    closeBottomSheet();
                    if (editingPresetId.value === id) {
                        editingPresetId.value = null;
                        updateHeaderState();
                    }
                }
            },
            {
                label: t('btn_no') || 'No',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

function confirmResetPreset(id) {
    const presetName = presetState.presets[id]?.name;
    showBottomSheet({
        title: `${t('confirm_reset_preset') || 'Reset to default:'} "${presetName}"?`,
        items: [
            {
                label: t('btn_yes') || 'Yes',
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: 'var(--vk-blue)',
                onClick: () => {
                    if (!DEFAULT_PRESETS[id]) return;
                    presetState.presets[id] = JSON.parse(JSON.stringify(DEFAULT_PRESETS[id]));
                    closeBottomSheet();
                }
            },
            {
                label: t('btn_no') || 'No',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

// Block Management
function addNewBlock() {
    showBottomSheet({
        title: t('add_block') || 'Add Block',
        items: [
            {
                label: t('action_create_new') || 'Create New',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    const newBlock = {
                        id: Date.now().toString(36) + Math.random().toString(36).substr(2),
                        name: t('new_block') || 'New Block',
                        role: 'system',
                        content: '',
                        enabled: true,
                        insertion_mode: 'relative'
                    };
                    currentPreset.value.blocks.push(newBlock);
                    closeBottomSheet();
                }
            },
            {
                label: t('action_copy_from_preset') || 'Copy from Preset',
                icon: '<svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    openCopyBlockPresetPicker();
                }
            }
        ]
    });
}

function openCopyBlockPresetPicker() {
    const entries = Object.entries(presetState.presets).sort((a, b) => {
        const wA = getPresetWeight(a[0], a[1]);
        const wB = getPresetWeight(b[0], b[1]);
        if (wA !== wB) return wA - wB;
        return a[1].name.localeCompare(b[1].name);
    });

    const cardItems = entries.map(([id, preset]) => ({
        label: preset.name,
        sublabel: preset.author ? `by ${preset.author}` : '',
        image: preset.image || null,
        isFeatured: preset.isFeatured,
        icon: !preset.image ? '<svg viewBox="0 0 24 24" style="fill:currentColor;"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>' : null,
        onClick: () => {
            closeBottomSheet();
            openCopyBlockPicker(id, preset);
        }
    }));

    showBottomSheet({
        title: t('action_select_preset') || 'Select Preset',
        cardItems
    });
}

function openCopyBlockPicker(presetId, preset) {
    if (!preset.blocks || preset.blocks.length === 0) {
        showBottomSheet({
            title: preset.name,
            items: [{
                label: t('label_no_blocks') || 'No blocks available',
                onClick: () => closeBottomSheet()
            }]
        });
        return;
    }

    const items = preset.blocks
        .filter(b => !b.isStashed)
        .map(block => ({
            label: block.i18n ? t(block.i18n) : block.name,
            icon: '<svg viewBox="0 0 24 24">' + getBlockIcon(block) + '</svg>',
            onClick: () => {
                const clone = JSON.parse(JSON.stringify(block));
                clone.id = Date.now().toString(36) + Math.random().toString(36).substr(2, 6);
                clone.name = (block.i18n ? t(block.i18n) : block.name) + ' (copy)';
                clone.isStatic = false;
                clone.i18n = undefined;
                currentPreset.value.blocks.push(clone);
                closeBottomSheet();
            }
        }));

    showBottomSheet({
        title: preset.name + ' — ' + (t('label_blocks') || 'Blocks'),
        items
    });
}

function updateHeaderState() {
    if (isEditingBlock.value) {
        headerState.title = t('header_prompt_edit') || 'Edit Prompt';
        headerState.showBack = true;
        headerState.actions = [];
    } else if (editingPresetId.value) {
        headerState.title = currentPreset.value?.name || t('subtab_preset') || 'Preset';
        headerState.showBack = true;
        headerState.actions = [];
    } else {
        headerState.title = t('sheet_title_presets') || 'Presets';
        headerState.showBack = false;
        headerState.actions = [];
    }
}

function goBackFromEditor() {
    if (isEditingBlock.value) {
        closeBlockEditor();
    } else {
        editingPresetId.value = null;
        updateHeaderState();
    }
}

function stashActiveBlock() {
    if (activeEditBlock.value) {
        activeEditBlock.value.isStashed = true;
        activeEditBlock.value.enabled = false;
        closeBlockEditor();
    }
}

function unstashBlock(blockId) {
    const block = currentPreset.value.blocks.find(b => b.id === blockId);
    if (block) {
        block.isStashed = false;
        block.enabled = true;
    }
}

function openStashSheet() {
    if (stashedBlocks.value.length === 0) return;

    const items = stashedBlocks.value.map(block => ({
        label: block.i18n ? t(block.i18n) : block.name,
        icon: getBlockIcon(block),
        onClick: null, // Click on the item does nothing now
        actions: [
            {
                // Restore icon (unarchive)
                icon: '<svg viewBox="0 0 24 24"><path d="M20.55 5.22l-1.39-1.68C18.88 3.21 18.47 3 18 3H6c-.47 0-.88.21-1.15.55L3.46 5.22C3.17 5.57 3 6.01 3 6.5V19c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V6.5c0-.49-.17-.93-.45-1.28zM5.12 5l.82-1h12.11l.83 1H5.12zM12 17.5L6.5 12H10v-4h4v4h3.5L12 17.5z"/></svg>',
                color: 'var(--vk-blue)',
                onClick: (e) => {
                    e.stopPropagation();
                    unstashBlock(block.id);
                    if (stashedBlocks.value.length > 0) {
                        openStashSheet();
                    } else {
                        closeBottomSheet();
                    }
                }
            },
            {
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                color: '#ff4444',
                onClick: (e) => {
                    e.stopPropagation();
                    confirmDeleteStashedBlock(block.id);
                }
            }
        ]
    }));

    showBottomSheet({
        title: t('stash') || 'Stash',
        items: items
    });
}

function openBlockEditor(blockId) {
    logger.debug('[GenerationView] openBlockEditor', blockId);
    
    // Save scroll pos before opening
    if (genSheetBodyRef.value) {
        savedScrollPos = genSheetBodyRef.value.scrollTop;
    }

    editingBlockId.value = blockId;
    
    const block = currentPreset.value.blocks.find(b => b.id === blockId);
    if (block && block.id !== 'authors_note' && block.id !== 'summary' && !block.insertion_mode) {
        block.insertion_mode = 'relative';
    }

    isEditingBlock.value = true;
    
    nextTick(() => {
        updateHeaderState();
    });
}

function closeBlockEditor() {
    logger.debug('[GenerationView] closeBlockEditor');
    isEditingBlock.value = false;
    editingBlockId.value = null;
    // Restore Generation Header
    nextTick(() => {
        updateHeaderState();
        if (genSheetBodyRef.value) {
            genSheetBodyRef.value.scrollTop = savedScrollPos;
        }
    });
}

function deleteActiveBlock() {
    if (activeEditBlock.value && activeEditBlock.value.isStatic) {
        alert(t('msg_cannot_delete_static') || 'Cannot delete static block');
        return;
    }
    if (editingBlockId.value) {
        showBottomSheet({
            title: t('confirm_delete_block') || 'Delete block?',
            items: [
                {
                    label: t('btn_delete') || 'Delete',
                    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: () => {
                        const idx = currentPreset.value.blocks.findIndex(b => b.id === editingBlockId.value);
                        if (idx !== -1) {
                            currentPreset.value.blocks.splice(idx, 1);
                        }
                        closeBottomSheet();
                        closeBlockEditor();
                    }
                },
                {
                    label: t('btn_cancel') || 'Cancel',
                    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                    onClick: closeBottomSheet
                }
            ]
        });
    }
}

function updateActiveBlock(newVal) {
    const block = activeEditBlock.value;
    if (block) {
        if (block.id === 'authors_note' || block.id === 'summary') {
            if (props.activeChatChar) {
                Object.assign(props.activeChatChar, newVal);
            }
            // Sync settings back to preset block
            const prefix = block.id === 'authors_note' ? 'authors_note_' : 'summary_';
            if (newVal[prefix + 'role']) block.role = newVal[prefix + 'role'];
            if (newVal[prefix + 'depth'] !== undefined) block.depth = newVal[prefix + 'depth'];
            if (newVal[prefix + 'insertion_mode']) block.insertion_mode = newVal[prefix + 'insertion_mode'];
            if (block.id === 'summary' && newVal['summary_prefix'] !== undefined) block.prefix = newVal['summary_prefix'];
        } else {
            Object.assign(block, newVal);
        }
    }
}

// Drag and Drop
const dragSrcIndex = ref(-1);

function onDragStart(event, blockId) {
    const index = currentPreset.value.blocks.findIndex(b => b.id === blockId);
    if (index === -1) return;
    dragSrcIndex.value = index;
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.dropEffect = 'move';
    
    // Hide default ghost image
    const img = new Image();
    img.src = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
    event.dataTransfer.setDragImage(img, 0, 0);
    
    event.target.classList.add('dragging');
}

function onDragEnter(event, blockId) {
    const index = currentPreset.value.blocks.findIndex(b => b.id === blockId);
    if (index === -1) return;
    if (dragSrcIndex.value !== -1 && dragSrcIndex.value !== index) {
        const blocks = currentPreset.value.blocks;
        const item = blocks.splice(dragSrcIndex.value, 1)[0];
        blocks.splice(index, 0, item);
        dragSrcIndex.value = index;
    }
}

function onDragEnd(event) {
    event.target.classList.remove('dragging');
    dragSrcIndex.value = -1;
}

function onTouchStart(event, blockId) {
    const index = currentPreset.value.blocks.findIndex(b => b.id === blockId);
    if (index === -1) return;
    dragSrcIndex.value = index;
    const block = event.target.closest('.prompt-block');
    if (block) block.classList.add('dragging');
    document.body.style.overflow = 'hidden';
}

function onTouchMove(event) {
    if (dragSrcIndex.value === -1) return;
    event.preventDefault();
    const touch = event.touches[0];
    const target = document.elementFromPoint(touch.clientX, touch.clientY);
    const block = target?.closest('.prompt-block');
    
    if (block && block.dataset.id !== undefined) {
        const targetId = block.dataset.id;
        const targetIndex = currentPreset.value.blocks.findIndex(b => b.id === targetId);
        if (targetIndex !== -1 && targetIndex !== dragSrcIndex.value) {
            const blocks = currentPreset.value.blocks;
            const item = blocks.splice(dragSrcIndex.value, 1)[0];
            blocks.splice(targetIndex, 0, item);
            dragSrcIndex.value = targetIndex;
        }
    }
}

function onTouchEnd(event) {
    const block = event.target.closest('.prompt-block');
    if (block) block.classList.remove('dragging');
    document.querySelectorAll('.prompt-block.dragging').forEach(el => el.classList.remove('dragging'));
    dragSrcIndex.value = -1;
    document.body.style.overflow = '';
}

// --- Import Logic ---
function triggerImport() {
    document.getElementById('preset-file-input').click();
}

function onFileSelected(event) {
    const file = event.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (e) => {
        try {
            const json = JSON.parse(e.target.result);
            processImportedPreset(json, file.name.replace(/\.json$/i, ''));
        } catch (err) {
            console.error("Error parsing JSON:", err);
            alert("Invalid JSON file");
        }
        event.target.value = '';
    };
    reader.readAsText(file);
}

function processImportedPreset(data, defaultName) {
    if (!data.prompts || !Array.isArray(data.prompts)) {
        alert("Invalid ST format: 'prompts' array missing.");
        return;
    }

    const preset = convertSTPreset(data, defaultName);
    
    // Ensure insertion_mode for all blocks
    preset.blocks.forEach(b => {
        if (b.id !== 'authors_note' && b.id !== 'summary' && !b.insertion_mode) {
            b.insertion_mode = 'relative';
        }
    });
    
    // Ensure static blocks
    if (!preset.blocks.find(b => b.id === 'summary')) {
         const historyIdx = preset.blocks.findIndex(b => b.id === 'chat_history');
         const insertIdx = historyIdx !== -1 ? historyIdx : preset.blocks.length;
         preset.blocks.splice(insertIdx, 0, { id: 'summary', name: 'Summary', role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_summary', depth: 4, insertion_mode: 'relative', prefix: 'Summary: ' });
    }
    if (!preset.blocks.find(b => b.id === 'authors_note')) {
         const historyIdx = preset.blocks.findIndex(b => b.id === 'chat_history');
         const insertIdx = historyIdx !== -1 ? historyIdx + 1 : preset.blocks.length;
         preset.blocks.splice(insertIdx, 0, { id: 'authors_note', name: "Author's Note", role: 'system', content: '', enabled: true, isStatic: true, i18n: 'magic_authors_notes', insertion_mode: 'relative' });
    }
    if (!preset.blocks.find(b => b.id === 'guided_generation')) {
         const authorsIdx = preset.blocks.findIndex(b => b.id === 'authors_note');
         const historyIdx = preset.blocks.findIndex(b => b.id === 'chat_history');
         const insertIdx = authorsIdx !== -1 ? authorsIdx + 1 : (historyIdx !== -1 ? historyIdx + 1 : preset.blocks.length);
         preset.blocks.splice(insertIdx, 0, { id: 'guided_generation', name: 'Guided Generation', role: 'system', content: '[System Note: {{guidance}}]', enabled: true, isStatic: true, i18n: 'block_guided_generation', insertion_mode: 'relative' });
    }
    if (!preset.guidedGenerationPrompt) preset.guidedGenerationPrompt = '[Generate your next reply according to these instructions: {{guidance}}]';
    if (!preset.guidedImpersonationPrompt) preset.guidedImpersonationPrompt = '[Instead of replying for {{char}}, impersonate {{user}} according to these instructions: {{guidance}}]';
    if (!preset.summaryPrompt) {
        preset.summaryPrompt = 'Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}\n\nSummary:';
    }

    const newId = Date.now().toString();
    preset.id = newId;
    presetState.presets[newId] = preset;
    editingPresetId.value = newId;
    updateHeaderState();
}

// Helper to generate fields for magic blocks (Author's Note, Summary)
function getMagicBlockFields(blockId) {
    const block = currentPreset.value.blocks.find(b => b.id === blockId);
    if (!block) return [];

    const fields = [];
    const mode = block.insertion_mode || 'relative';

    fields.push({ 
        key: 'role', label: 'label_role', type: 'select', 
        options: [
            { value: 'system', label: 'role_system' },
            { value: 'user', label: 'role_user' },
            { value: 'assistant', label: 'role_assistant' }
        ]
    });

    fields.push({
        key: 'insertion_mode', label: 'label_injection_point', type: 'select',
        options: [
            { value: 'relative', label: 'injection_relative' },
            { value: 'depth', label: 'injection_depth' }
        ]
    });
    
    if (mode === 'depth') {
        fields.push({ key: 'depth', label: t('label_depth') || 'Depth', type: 'number', placeholder: '4' });
    }

    if (blockId === 'summary') {
        fields.push({ key: 'prefix', label: t('label_prefix') || 'Prefix', type: 'text', placeholder: 'Summary: ' });
    }
    
    if (blockId === 'authors_note') {
        fields.push({ key: 'info', label: '', type: 'info', text: t('unique_for_chat') || 'Content is unique for each chat' });
    }
    
    fields.push({ key: 'content', label: t('label_content') || 'Content', type: 'textarea', rows: 5, expandable: true });

    return fields;
}

// --- Editor Config ---
const editorConfig = computed(() => {
    if (activeEditBlock.value?.id === 'authors_note') {
        const fields = getMagicBlockFields('authors_note');
        return [{
            title: t('magic_authors_notes') || "Author's Note",
            fields: fields
        }];
    }
    if (activeEditBlock.value?.id === 'summary') {
        const fields = getMagicBlockFields('summary');
        return [{
            title: t('magic_summary') || "Summary",
            fields: fields
        }];
    }
    if (activeEditBlock.value?.id === 'guided_generation') {
        const block = activeEditBlock.value;
        const mode = block.insertion_mode || 'relative';
        const fields = [
            { key: 'role', label: 'label_role', type: 'select', options: [
                { value: 'system', label: 'role_system' },
                { value: 'user', label: 'role_user' },
                { value: 'assistant', label: 'role_assistant' }
            ]},
            { key: 'insertion_mode', label: 'label_injection_point', type: 'select', options: [
                { value: 'relative', label: 'injection_relative' },
                { value: 'depth', label: 'injection_depth' }
            ]},
            ...(mode === 'depth' ? [{ key: 'depth', label: t('label_depth') || 'Depth', type: 'number', placeholder: '0' }] : []),
            { key: 'info', label: '', type: 'info', text: t('guided_generation_block_hint') || 'This prompt is sent only when Guided Generation is active.\n{{guidance}} — user instruction.' },
            { key: 'guidedGenerationPrompt', label: t('label_guided_generation_prompt') || 'Generation Prompt', type: 'textarea', rows: 2, expandable: true },
            { key: 'guidedImpersonationPrompt', label: t('label_guided_impersonation_prompt') || 'Impersonation Prompt', type: 'textarea', rows: 2, expandable: true }
        ];
        return [{ title: t('block_guided_generation') || 'Guided Generation', fields }];
    }

    if (activeEditBlock.value?.isStatic) {
        const blockName = activeEditBlock.value.i18n ? t(activeEditBlock.value.i18n) : activeEditBlock.value.name;
        const fields = [];
        
        if (activeEditBlock.value.id !== 'chat_history') {
            fields.push({ 
                key: 'role', label: 'label_role', type: 'select', 
                options: [
                    { value: 'system', label: 'role_system' },
                    { value: 'user', label: 'role_user' },
                    { value: 'assistant', label: 'role_assistant' }
                ]
            });
        }

        fields.push({
            key: 'insertion_mode', label: 'label_injection_point', type: 'select',
            options: [
                { value: 'relative', label: 'injection_relative' },
                { value: 'depth', label: 'injection_depth' }
            ]
        });
        if (activeEditBlock.value.insertion_mode === 'depth') {
            fields.push({ key: 'depth', label: 'label_depth', type: 'number', placeholder: '4' });
        }
        
        fields.push({ 
            key: 'content', label: '', type: 'info', 
            text: `${t('msg_block_managed_by')} "${blockName}"`
        });

        return [
            {
                title: '',
                fields: fields
            }
        ];
    }

    const genericFields = [
        { key: 'name', label: 'label_block_name', type: 'text' },
        { 
            key: 'role', label: 'label_role', type: 'select', 
            options: [
                { value: 'system', label: 'role_system' },
                { value: 'user', label: 'role_user' },
                { value: 'assistant', label: 'role_assistant' }
            ]
        },
        {
            key: 'insertion_mode', label: 'label_injection_point', type: 'select',
            options: [
                { value: 'relative', label: 'injection_relative' },
                { value: 'depth', label: 'injection_depth' }
            ]
        }
    ];

    if (activeEditBlock.value?.insertion_mode === 'depth') {
        genericFields.push({ key: 'depth', label: 'label_depth', type: 'number', placeholder: '4' });
    }

    genericFields.push({ key: 'content', label: 'label_content', type: 'textarea', rows: 10, expandable: true });

    return [
        {
            title: '',
            fields: genericFields
        }
    ];
});

const editorProxy = computed({
    get() {
        if (!activeEditBlock.value) return null;
        
        if (activeEditBlock.value.id === 'authors_note') {
            return {
                content: props.activeChatChar?.authors_note || '',
                depth: activeEditBlock.value.depth !== undefined ? activeEditBlock.value.depth : 0,
                role: activeEditBlock.value.role || 'system',
                insertion_mode: activeEditBlock.value.insertion_mode || 'relative'
            };
        }
        if (activeEditBlock.value.id === 'summary') {
            return {
                content: props.activeChatChar?.summary || '',
                depth: activeEditBlock.value.depth !== undefined ? activeEditBlock.value.depth : 4,
                role: activeEditBlock.value.role || 'system',
                insertion_mode: activeEditBlock.value.insertion_mode || 'relative',
                prefix: activeEditBlock.value.prefix || 'Summary: '
            };
        }
        if (activeEditBlock.value.id === 'guided_generation') {
            return {
                role: activeEditBlock.value.role || 'system',
                insertion_mode: activeEditBlock.value.insertion_mode || 'relative',
                depth: activeEditBlock.value.depth !== undefined ? activeEditBlock.value.depth : 0,
                guidedGenerationPrompt: currentPreset.value.guidedGenerationPrompt || '',
                guidedImpersonationPrompt: currentPreset.value.guidedImpersonationPrompt || ''
            };
        }

        return activeEditBlock.value;
    },
    set(newVal) {
        if (!activeEditBlock.value || !newVal) return;

        if (activeEditBlock.value.id === 'authors_note') {
            if (props.activeChatChar) props.activeChatChar.authors_note = newVal.content;
            activeEditBlock.value.depth = newVal.depth;
            activeEditBlock.value.role = newVal.role;
            activeEditBlock.value.insertion_mode = newVal.insertion_mode;
        } else if (activeEditBlock.value.id === 'summary') {
            if (props.activeChatChar) props.activeChatChar.summary = newVal.content;
            activeEditBlock.value.depth = newVal.depth;
            activeEditBlock.value.role = newVal.role;
            activeEditBlock.value.insertion_mode = newVal.insertion_mode;
            activeEditBlock.value.prefix = newVal.prefix;
        } else if (activeEditBlock.value.id === 'guided_generation') {
            activeEditBlock.value.role = newVal.role;
            activeEditBlock.value.insertion_mode = newVal.insertion_mode;
            activeEditBlock.value.depth = newVal.depth;
            currentPreset.value.guidedGenerationPrompt = newVal.guidedGenerationPrompt;
            currentPreset.value.guidedImpersonationPrompt = newVal.guidedImpersonationPrompt;
        } else {
            // Standard block - manual copy to maintain reference or replace properties
            Object.assign(activeEditBlock.value, newVal);
        }
    }
});

function getBlockIcon(block) {
    if (block.id === 'chat_history') {
        return '<path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/>';
    }
    return getRoleIcon(block.role);
}

function hasMacro(block, macroName) {
    let content = "";
    if (block.id === 'authors_note') {
        content = props.activeChatChar?.authors_note || "";
    } else if (block.id === 'summary') {
        content = props.activeChatChar?.summary || "";
    } else {
        content = block.content || "";
    }
    
    if (macroName === 'setvar') return content.includes('{{setvar::');
    if (macroName === 'getvar') return content.includes('{{getvar::');
    return false;
}

function getRoleIcon(role) {
    switch(role) {
        case 'user': return '<path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/>';
        case 'assistant': return '<path d="M20 9V7c0-1.1-.9-2-2-2h-3c0-1.66-1.34-3-3-3S9 3.34 9 5H6c-1.1 0-2 .9-2 2v2c-1.66 0-3 1.34-3 3s1.34 3 3 3v4c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2v-4c1.66 0 3-1.34 3-3s-1.34-3-3-3zM7.5 11.5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5S9.83 13 9 13s-1.5-.67-1.5-1.5zM16 17H8v-2h8v2zm-1.5-4c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/>';
        case 'system': 
        default: return '<path d="M20 13H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1v-6c0-.55-.45-1-1-1zM7 19c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zM20 3H4c-.55 0-1 .45-1 1v6c0 .55.45 1 1 1h16c.55 0 1-.45 1-1V4c0-.55-.45-1-1-1zM7 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z"/>';
    }
}

function isBlockLocked(block) {
    return false; // Blocks are fundamentally no longer locked by depth
}

function openAuthorsNoteSheet() {
    if (!props.activeChatChar) return;
    const char = props.activeChatChar;
    const block = currentPreset.value.blocks.find(b => b.id === 'authors_note');
    if (!block) return;
    
    const data = {
        enabled: block.enabled !== undefined ? block.enabled : true,
        role: block.role || 'system',
        insertion_mode: block.insertion_mode || 'relative',
        depth: block.depth !== undefined ? block.depth : 0,
        content: char.authors_note || ''
    };

    const getToggleIcon = (enabled) => {
        return `<input type="checkbox" class="vk-switch" ${enabled ? 'checked' : ''} style="pointer-events: none;">`;
    };

    const helpTipHtml = (term) => `
        <button class="help-tip" data-term="${term}" type="button" tabindex="-1" style="width:20px;height:20px;padding:0;border:none;background:none;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0;opacity:0.4;color:var(--text-gray);vertical-align:middle;margin-left:4px;">
            <svg viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17h-2v-2h2v2zm2.07-7.75l-.9.92C13.45 12.9 13 13.5 13 15h-2v-.5c0-1.1.45-2.1 1.17-2.83l1.24-1.26c.37-.36.59-.86.59-1.41 0-1.1-.9-2-2-2s-2 .9-2 2H8c0-2.21 1.79-4 4-4s4 1.79 4 4c0 .88-.36 1.68-.93 2.25z"/></svg>
        </button>
    `;

    const content = document.createElement('div');
    content.innerHTML = `
        <div class="settings-item">
            <label>${t('label_role')}${helpTipHtml('preset-role')}</label>
            <select id="an-role" class="settings-select">
                <option value="system" ${data.role === 'system' ? 'selected' : ''}>${t('role_system')}</option>
                <option value="user" ${data.role === 'user' ? 'selected' : ''}>${t('role_user')}</option>
                <option value="assistant" ${data.role === 'assistant' ? 'selected' : ''}>${t('role_assistant')}</option>
            </select>
        </div>
        <div class="settings-item">
            <label>${t('label_injection_point')}${helpTipHtml('preset-injection')}</label>
            <select id="an-mode" class="settings-select">
                <option value="relative" ${data.insertion_mode === 'relative' ? 'selected' : ''}>${t('injection_relative')}</option>
                <option value="depth" ${data.insertion_mode === 'depth' ? 'selected' : ''}>${t('injection_depth')}</option>
            </select>
        </div>
        <div class="settings-item" id="an-depth-container" style="${data.insertion_mode === 'depth' ? '' : 'display:none'}">
            <label>${t('label_depth')}</label>
            <input type="number" id="an-depth" value="${data.depth}" placeholder="${t('placeholder_depth')}">
        </div>
        <div class="settings-item" style="color: var(--text-gray); font-size: 12px; text-align: center; justify-content: center; opacity: 0.8; margin-top: -4px;">
            ${t('unique_for_chat') || 'Content is unique for each chat'}
        </div>
        <div class="settings-item">
            <label>${t('label_content')}</label>
            <textarea id="an-content" rows="5">${data.content}</textarea>
        </div>
    `;

    content.querySelectorAll('.help-tip').forEach(btn => {
        btn.onclick = (e) => {
            e.stopPropagation();
            window.dispatchEvent(new CustomEvent('open-glossary', { detail: { term: btn.dataset.term } }));
        };
    });

    let debounceTimer = null;
    const save = () => {
        block.enabled = data.enabled;
        block.role = content.querySelector('#an-role').value;
        block.insertion_mode = content.querySelector('#an-mode').value;
        let parsedDepth = parseInt(content.querySelector('#an-depth').value);
        block.depth = isNaN(parsedDepth) ? 0 : parsedDepth;
        char.authors_note = content.querySelector('#an-content').value;
    };

    const debouncedSave = () => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(save, 500);
    };

    content.querySelector('#an-role').addEventListener('change', save);
    content.querySelector('#an-mode').addEventListener('change', (e) => {
        const depthContainer = content.querySelector('#an-depth-container');
        depthContainer.style.display = e.target.value === 'depth' ? 'block' : 'none';
        save();
    });
    content.querySelector('#an-depth').addEventListener('input', save);
    content.querySelector('#an-content').addEventListener('input', debouncedSave);

    const toggleAction = (e) => {
        data.enabled = !data.enabled;
        save();
        if (e && e.currentTarget) {
            const input = e.currentTarget.querySelector('input');
            if (input) input.checked = data.enabled;
        }
    };

    showBottomSheet({
        title: t('magic_authors_notes'),
        helpTip: 'authornote',
        content: content,
        headerAction: { icon: getToggleIcon(data.enabled), onClick: toggleAction },
        onClose: () => {
            if (debounceTimer) clearTimeout(debounceTimer);
            save();
        }
    });
}

function openSummarySheet() {
    if (!props.activeChatChar) return;
    const char = props.activeChatChar;
    const block = currentPreset.value.blocks.find(b => b.id === 'summary');
    if (!block) return;
    
    const data = {
        role: block.role || 'system',
        insertion_mode: block.insertion_mode || 'relative',
        depth: block.depth !== undefined ? block.depth : 4,
        content: char.summary || '',
        prefix: block.prefix || 'Summary: '
    };
    
    const helpTipHtml = (term) => `
        <button class="help-tip" data-term="${term}" type="button" tabindex="-1" style="width:20px;height:20px;padding:0;border:none;background:none;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;flex-shrink:0;opacity:0.4;color:var(--text-gray);vertical-align:middle;margin-left:4px;">
            <svg viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17h-2v-2h2v2zm2.07-7.75l-.9.92C13.45 12.9 13 13.5 13 15h-2v-.5c0-1.1.45-2.1 1.17-2.83l1.24-1.26c.37-.36.59-.86.59-1.41 0-1.1-.9-2-2-2s-2 .9-2 2H8c0-2.21 1.79-4 4-4s4 1.79 4 4c0 .88-.36 1.68-.93 2.25z"/></svg>
        </button>
    `;

    const content = document.createElement('div');
    content.innerHTML = `
        <div class="settings-item"><label>${t('label_role')}${helpTipHtml('preset-role')}</label><select id="summary-role" class="settings-select"><option value="system" ${data.role === 'system' ? 'selected' : ''}>${t('role_system') || 'System'}</option><option value="user" ${data.role === 'user' ? 'selected' : ''}>${t('role_user') || 'User'}</option><option value="assistant" ${data.role === 'assistant' ? 'selected' : ''}>${t('role_assistant') || 'Assistant'}</option></select></div>
        <div class="settings-item"><label>${t('label_injection_point')}${helpTipHtml('preset-injection')}</label><select id="summary-mode" class="settings-select"><option value="relative" ${data.insertion_mode === 'relative' ? 'selected' : ''}>${t('injection_relative')}</option><option value="depth" ${data.insertion_mode === 'depth' ? 'selected' : ''}>${t('injection_depth')}</option></select></div>
        <div class="settings-item" id="summary-depth-container" style="${data.insertion_mode === 'depth' ? '' : 'display:none'}"><label>${t('label_depth')}</label><input type="number" id="summary-depth" value="${data.depth}" placeholder="${t('placeholder_depth')}"></div>
        <div class="settings-item"><label>${t('label_prefix') || 'Prefix'}</label><input type="text" id="summary-prefix" value="${data.prefix}" placeholder="Summary: "></div>
        <div class="settings-item"><label>${t('label_content')}</label><textarea id="summary-content" rows="8" placeholder="${t('summary_placeholder')}">${data.content}</textarea></div>
        <div class="settings-item"><button id="btn-auto-summary" class="btn-save" style="width: 100%; display: flex; align-items: center; justify-content: center; gap: 8px;"><svg viewBox="0 0 24 24" style="width:20px;height:20px;fill:currentColor"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 14l-5-5 1.41-1.41L10 12.17l7.59-7.59L19 6l-9 11z"/></svg>${t('btn_auto_summary')}</button></div>
    `;

    content.querySelectorAll('.help-tip').forEach(btn => {
        btn.onclick = (e) => {
            e.stopPropagation();
            window.dispatchEvent(new CustomEvent('open-glossary', { detail: { term: btn.dataset.term } }));
        };
    });

    let debounceTimer = null;
    const save = () => {
        block.role = content.querySelector('#summary-role').value;
        block.insertion_mode = content.querySelector('#summary-mode').value;
        let parsedDepth = parseInt(content.querySelector('#summary-depth').value);
        block.depth = isNaN(parsedDepth) ? 0 : parsedDepth;
        block.prefix = content.querySelector('#summary-prefix').value;
        char.summary = content.querySelector('#summary-content').value;
    };

    const debouncedSave = () => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(save, 500);
    };

    content.querySelector('#summary-role').addEventListener('change', save);
    content.querySelector('#summary-mode').addEventListener('change', (e) => {
        content.querySelector('#summary-depth-container').style.display = e.target.value === 'depth' ? 'block' : 'none';
        save();
    });
    content.querySelector('#summary-depth').addEventListener('input', save);
    content.querySelector('#summary-prefix').addEventListener('input', save);
    content.querySelector('#summary-content').addEventListener('input', debouncedSave);

    content.querySelector('#btn-auto-summary').addEventListener('click', async (e) => {
        const btn = e.currentTarget;
        btn.disabled = true;
        const originalHtml = btn.innerHTML;
        btn.innerHTML = `<div class="app-loader-spinner" style="width:20px;height:20px;border-width:2px;"></div>`;
        try {
            const historyText = props.chatHistory.filter(m => !m.isHidden && !m.isTyping).slice(-50).map(m => `${m.role === 'user' ? (m.persona?.name || 'User') : char.name}: ${m.text}`).join('\n');
            const summary = await generateSummary({
                history: historyText,
                prompt: currentPreset.value.summaryPrompt
            });
            content.querySelector('#summary-content').value = summary;
            save();
        } catch (e) { console.error(e); } finally {
            btn.disabled = false;
            btn.innerHTML = originalHtml;
        }
    });

    showBottomSheet({ 
        title: t('magic_summary'), 
        helpTip: 'summary',
        content: content,
        onClose: () => {
            if (debounceTimer) clearTimeout(debounceTimer);
            save();
        }
    });
}

// Depths are no longer visually enforced

const onFsEditorClosed = () => {
    if (isEditingBlock.value) {
        setTimeout(() => updateHeaderState(), 50);
    }
};

onMounted(async () => {
    initRipple();
    await loadPresets();
    if (currentPreset.value) {
        localStorage.setItem('gz_api_request_reasoning', currentPreset.value.reasoningEnabled);
    }

    updateLanguage();

    window.addEventListener('fs-editor-closed', onFsEditorClosed);
    updateHeaderState();
});

// Watchers for enforcing depth visually have been removed
function confirmDeleteStashedBlock(blockId) {
    const block = currentPreset.value.blocks.find(b => b.id === blockId);
    if (!block) return;

    showBottomSheet({
        title: `${t('confirm_delete_block') || 'Delete block?'} "${block.name}"`,
        items: [
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    const idx = currentPreset.value.blocks.findIndex(b => b.id === blockId);
                    if (idx !== -1) {
                        currentPreset.value.blocks.splice(idx, 1);
                    }
                    closeBottomSheet();
                }
            },
            {
                label: t('btn_cancel') || 'Cancel',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

onBeforeUnmount(() => {
    window.removeEventListener('fs-editor-closed', onFsEditorClosed);
});
</script>

<template>
    <SheetView ref="sheet" :title="headerState.title" :show-back="headerState.showBack" :actions="headerState.actions" @back="goBackFromEditor" @close="flushPresetSave">
        <div class="gen-sheet-body" ref="genSheetBodyRef">
        <!-- ═══ SELECTOR LIST VIEW ═══ -->
        <div class="preset-selector-list" v-if="!isEditingBlock && !editingPresetId">
            <div class="ps-list">
                <div v-for="[id, preset] in sortedPresetEntries" :key="id"
                     class="ps-card"
                     :class="{ 'ps-active': (optimisticGlobalPresetId || presetState.globalPresetId) === id, 'ps-has-bg': !!preset.image }"
                     :style="preset.image ? { backgroundImage: 'url(' + preset.image + ')' } : {}"
                     @click="activatePreset(id)">
                    <!-- Overlay for image cards -->
                    <div class="ps-card-overlay" v-if="preset.image"></div>
                    <!-- Featured badge -->
                    <div v-if="preset.isFeatured" class="ps-featured-badge">
                        {{ t('label_featured_preset') || 'FEATURED PRESET' }}
                    </div>
                    <!-- Icon only for non-image cards -->
                    <div class="ps-card-icon" v-if="!preset.image">
                        <svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>
                    </div>
                    <!-- Info -->
                    <div class="ps-card-info">
                        <div class="ps-card-name" :class="{ 'ps-with-bg': !!preset.image }">{{ preset.name || 'Default' }}</div>
                        <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-top: 4px;">
                            <div class="ps-card-badge" :class="{ 'ps-with-bg': !!preset.image }">
                                <svg viewBox="0 0 24 24" class="ps-badge-icon"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                {{ getPresetTokens(preset) }}
                            </div>
                            <div class="ps-card-meta" :class="{ 'ps-with-bg': !!preset.image }">
                                <span v-if="preset.author">by {{ preset.author }}</span>
                                <span v-if="preset.descriptionKey">{{ t(preset.descriptionKey) }}</span>
                            </div>
                        </div>
                    </div>
                    <!-- Card Actions (Top Right) -->
                    <div class="ps-card-actions">
                        <!-- Connection badge -->
                        <div class="ps-badge-area">
                            <div class="ps-conn-badge"
                                 :class="['ps-conn-' + (getPresetConnectionType(id) || 'none'), { 'ps-with-bg': !!preset.image }]"
                                 @click="openPresetConnections(id, $event)"
                                 :title="t('header_connections') || 'Connections'">
                                <svg v-if="getPresetConnectionType(id) === 'chat'" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                                <svg v-else-if="getPresetConnectionType(id) === 'character'" viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
                                <svg v-else-if="getPresetConnectionType(id) === 'global'" viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
                                <svg v-else viewBox="0 0 24 24"><path d="M17 16l-4-4V8.82C14.16 8.4 15 7.3 15 6c0-1.66-1.34-3-3-3S9 4.34 9 6c0 1.3.84 2.4 2 2.82V12l-4 4H3v5h5v-3.05l4-4.2 4 4.2V21h5v-5h-4z"/></svg>
                            </div>
                        </div>
                        <!-- Edit pencil -->
                        <div class="ps-edit-btn" :class="{ 'ps-with-bg': !!preset.image }" @click.stop="editingPresetId = id; updateHeaderState();">
                            <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                        </div>
                    </div>
                </div>

                <!-- Add / Import Button -->
                <div class="ps-add-btn" @click="openAddPresetSheet">
                    <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                    <span>{{ t('btn_add') || 'Add / Import' }}</span>
                </div>
            </div>
        </div>

        <!-- ═══ EDITOR VIEW (existing dashboard) ═══ -->
        <div class="prompt-builder-wrapper" v-if="!isEditingBlock && editingPresetId">

                <!-- Consolidated Dashboard and Blocks Container -->
                <div class="preset-dashboard" :class="{ 'has-background': !!currentPreset.image }" :style="currentPreset.image ? { 'background-image': 'url(' + currentPreset.image + ')' } : {}">
                    <div class="dashboard-edit-header">
                        <div class="active-row-content">
                            <div class="active-name-group">
                                <div class="active-preset-name-wrapper">
                                    <div class="active-preset-name">{{ currentPreset.name || 'Default' }}</div>
                                </div>
                                <div v-if="currentPreset.author" class="active-preset-author">by {{ currentPreset.author }}</div>
                            </div>
                            
                            <!-- Consolidate Actions Top Right -->
                            <div class="action-icons-corner">
                                <div class="header-dots-btn" @click.stop="openPresetOptionsMenu">
                                    <svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="dashboard-utils-row">
                        <div class="utils-left">
                            <div v-if="stashedBlocks.length > 0" 
                                 class="header-stash-btn" 
                                 @click.stop="openStashSheet"
                                 :title="t('stash') || 'Stash'">
                                <svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-6 10H6v-2h8v2zm4-4H6v-2h12v2z"/></svg>
                                <span class="stash-count-dot">{{ stashedBlocks.length }}</span>
                            </div>
                        </div>
                        <div class="utils-right">
                            <div class="active-tokens">
                                <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                <span>{{ displayedEditingTokens }}</span>
                            </div>
                        </div>
                    </div>

                    <!-- Integrated Block List directly below hierarchy -->
                    <div class="prompt-blocks-area">
                    <TransitionGroup name="block-list" tag="div">
                        <div v-for="block in activeBlocks" :key="block.id" 
                             class="prompt-block"
                             :class="{ 'disabled': !block.enabled }"
                             :data-id="block.id"
                             draggable="true"
                             @dragstart="!isBlockLocked(block) && onDragStart($event, block.id)"
                             @dragenter.prevent="!isBlockLocked(block) && onDragEnter($event, block.id)"
                             @dragover.prevent
                             @dragend="onDragEnd">
                            <div class="block-handle"
                                 @touchstart="!isBlockLocked(block) && onTouchStart($event, block.id)"
                                 @touchmove="!isBlockLocked(block) && onTouchMove($event)"
                                 @touchend="!isBlockLocked(block) && onTouchEnd($event)">
                                 <svg v-if="isBlockLocked(block)" viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor;opacity:0.5"><path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/></svg>
                                 <span v-else>≡</span>
                            </div>
                            <div class="block-content">
                                <svg viewBox="0 0 24 24" class="block-role-icon" v-html="getBlockIcon(block)"></svg>
                                <div class="block-name">
                                    {{ block.i18n ? t(block.i18n) : block.name }}
                                    <span v-if="hasMacro(block, 'setvar')" class="macro-badge setvar">set</span>
                                    <span v-if="hasMacro(block, 'getvar')" class="macro-badge getvar">get</span>
                                </div>
                                <div class="block-tokens" :title="t('label_tokens') || 'Tokens'">
                                    {{ getBlockTokens(block) }}
                                </div>
                            </div>
                            <div class="block-actions">
                                <div class="block-edit" @click.stop="openBlockEditor(block.id)">
                                    <svg viewBox="0 0 24 24"><path d="M3 17.46v3.04h3.04l11.12-11.12-3.04-3.04L3 17.46zm16.48-9.71c.39-.39.39-1.02 0-1.41l-1.63-1.63c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.04 3.04 1.83-1.83z"/></svg>
                                </div>
                                <div v-if="block.id === 'guided_generation'" class="block-lock-wrap">
                                    <svg viewBox="0 0 24 24" class="block-lock-icon"><path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/></svg>
                                </div>
                                <input v-else type="checkbox" class="vk-switch block-toggle small-switch" v-model="block.enabled">
                            </div>
                        </div>
                    </TransitionGroup>
                    
                    <div class="add-block-btn prompt-block" @click="addNewBlock">
                        <div class="block-handle" style="opacity: 0">≡</div>
                        <div class="block-content">
                            <svg viewBox="0 0 24 24" class="block-role-icon"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                            <div class="block-name" data-i18n="add_block">Add Block</div>
                        </div>
                    </div>
                    </div> <!-- End prompt-blocks-area -->
                </div> <!-- End preset-dashboard -->

                <!-- Advanced Settings Section -->
                <div class="advanced-settings-toggle" @click="showAdvancedSettings = !showAdvancedSettings">
                    <span>{{ t('section_advanced_settings') || 'Advanced Settings' }}</span>
                    <svg :class="{ rotated: showAdvancedSettings }" viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                </div>

                <Transition name="expand">
                    <div v-if="showAdvancedSettings" class="advanced-settings-panel">
                        <div class="menu-group">
                            <div class="section-header">{{ t('section_postprocessing') || 'Prompt Postprocessing' }} <HelpTip term="preset-merge"/></div>
                            <div class="settings-item-checkbox" @click.capture="currentPreset.noAssistant ? Toast.show({ text: t('hint_merge_locked') || 'Required by NoAssistant mode — single block', duration: 'short', position: 'bottom' }) : null">
                                <div class="settings-text-col">
                                    <label>{{ t('label_merge_prompts') || 'Merge Prompts' }}</label>
                                    <div class="settings-desc">{{ t('desc_merge_prompts') || 'Combine adjacent blocks into one message' }}</div>
                                </div>
                                <input type="checkbox" v-model="currentPreset.mergePrompts" class="vk-switch" :disabled="currentPreset.noAssistant">
                            </div>
                            <div class="settings-item" v-if="currentPreset.mergePrompts" @click="openMergeRoleSelector">
                                <label>{{ t('label_merge_role') || 'Merge Role' }}</label>
                                <div class="settings-desc">{{ currentPreset.mergeRole }}</div>
                            </div>
                            <div class="settings-item-checkbox">
                                <div class="settings-text-col">
                                    <label>{{ t('label_no_assistant') || 'NoAssistant' }} <HelpTip term="preset-noassistant"/></label>
                                    <div class="settings-desc">{{ t('desc_no_assistant') || 'Send all chat history in a single block with role prefixes' }}</div>
                                </div>
                                <input type="checkbox" v-model="currentPreset.noAssistant" class="vk-switch">
                            </div>
                            <template v-if="currentPreset.noAssistant">
                                <div class="settings-item">
                                    <label>{{ t('label_stop_string') || 'Stop String' }}</label>
                                    <div class="settings-desc">{{ t('desc_stop_string') || 'Sent as stop parameter to the model. Leave empty to omit.' }}</div>
                                    <input type="text" v-model="currentPreset.stopString" placeholder="e.g. User:">
                                </div>
                                <div class="settings-item">
                                    <label>{{ t('label_user_prefix') || 'User Prefix' }}</label>
                                    <div class="settings-desc">{{ t('desc_user_prefix') || 'Prefix prepended to user messages in history block' }}</div>
                                    <input type="text" v-model="currentPreset.userPrefix" placeholder="e.g. User: ">
                                </div>
                                <div class="settings-item">
                                    <label>{{ t('label_char_prefix') || 'Char Prefix' }}</label>
                                    <div class="settings-desc">{{ t('desc_char_prefix') || 'Prefix prepended to character messages in history block' }}</div>
                                    <input type="text" v-model="currentPreset.charPrefix" placeholder="e.g. Assistant: ">
                                </div>
                                <div class="settings-item" @click="openSquashRoleSelector">
                                    <label>{{ t('label_squash_role') || 'Squash Role' }}</label>
                                    <div class="settings-desc">{{ t('desc_squash_role') || 'Consecutive messages from this role will be merged' }}: {{ currentPreset.squashRole }}</div>
                                </div>
                            </template>
                        </div>

                        <div class="menu-group">
                            <div class="section-header">{{ t('label_reasoning_settings') || 'Reasoning' }} <HelpTip term="preset-reasoning"/></div>
                            <div class="settings-item-checkbox">
                                <div class="settings-text-col">
                                <label>{{ t('label_reasoning') || 'Request Native Reasoning' }}</label>
                                <div class="settings-desc">{{ t('desc_reasoning') || 'Shows model native reasoning' }}</div>
                                </div>
                                <input type="checkbox" v-model="currentPreset.reasoningEnabled" class="vk-switch">
                            </div>
                            <div class="settings-item-checkbox">
                                <div class="settings-text-col">
                                <label>{{ t('label_parse_inline_reasoning') || 'Parse Inline Reasoning' }}</label>
                                <div class="settings-desc">{{ t('desc_parse_inline_reasoning') || 'Extracts reasoning from the message body and inserts it into the reasoning block' }}</div>
                                </div>
                                <input type="checkbox" v-model="currentPreset.parseInlineReasoning" class="vk-switch">
                            </div>
                            <div class="settings-item" v-if="currentPreset.parseInlineReasoning">
                            <label>{{ t('label_reasoning_tags') || 'Reasoning Tags (Outer CoT)' }}</label>
                                <input type="text" v-model="currentPreset.reasoningStart" placeholder="<think>" style="margin-bottom: 5px;">
                                <input type="text" v-model="currentPreset.reasoningEnd" placeholder="</think>">
                            </div>
                        </div>

                        <!-- Function Prompts -->
                        <div class="menu-group">
                            <div class="section-header">{{ t('label_preset_prompts') || 'Function Prompts' }}</div>
                            <div class="settings-item">
                                <div class="label-row">
                                    <label>{{ t('label_summary_prompt') || 'Summary Prompt' }}</label>
                                    <div class="expand-btn" @click="handleOpenFs('summaryPrompt')"><svg viewBox="0 0 24 24"><path d="M15 3l2.3 2.3-2.89 2.87 1.42 1.42L18.7 6.7 21 9V3zM3 9l2.3-2.3 2.87 2.89 1.42-1.42L6.7 5.3 9 3H3zm6 12l-2.3-2.3 2.89-2.87-1.42-1.42L5.3 17.3 3 15v6zm12-6l-2.3 2.3-2.87-2.89-1.42 1.42 2.89 2.87L15 21h6z"/></svg></div>
                                </div>
                                <textarea v-model="currentPreset.summaryPrompt" rows="3" placeholder="Summarize the following roleplay conversation... (use {{history}})"></textarea>
                            </div>
                        </div>

                    </div>
                </Transition>
            </div>

        <!-- Block Editor View -->
        <div v-if="isEditingBlock" class="block-editor-view editor-fixed-overlay" style="position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 10; background: var(--app-bg);">
            <div class="block-editor-scroll">
                <Editor v-model="editorProxy" :config="editorConfig" @open-fs="(data) => emit('open-fs', data)">
                    <template #footer>
                        <div class="block-editor-inline-actions settings-item" v-if="activeEditBlock && !activeEditBlock.isStatic" style="border-top: 1px solid rgba(127,127,127,0.1); border-bottom: none;">
                            <button class="editor-btn stash-btn" @click="stashActiveBlock">
                                <svg viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-6 10H6v-2h8v2zm4-4H6v-2h12v2z"/></svg>
                                <span>{{ t('action_stash') || 'Move to stash' }}</span>
                            </button>
                            <button class="editor-btn delete-btn" @click="deleteActiveBlock">
                                <svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                                <span>{{ t('btn_delete') || 'Delete' }}</span>
                            </button>
                        </div>
                    </template>
                </Editor>
            </div>
        </div>
            </div>
    </SheetView>

    <input 
        type="file" 
        id="preset-file-input" 
        style="display: none" 
        accept=".json" 
        @change="onFileSelected"
    >
    <input 
        type="file" 
        id="preset-image-input" 
        style="display: none" 
        accept="image/*" 
        @change="onImageSelected"
    >
</template>

<style scoped>
/* API Status Base Style (moved from inline) */
.api-status {
    display: flex; 
    align-items: center; 
    font-size: 0.75em; 
    cursor: pointer; 
    padding: 4px 8px; 
    border-radius: 12px; 
    font-weight: normal; 
    text-transform: none;
    transition: all 0.3s ease;
}

#api-status-text {
    transition: opacity 0.2s ease, color 0.3s ease;
}

.status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background-color: orange;
    margin-right: 6px;
    transition: background-color 0.3s ease;
}
.status-dot.connecting { background-color: orange; }
.status-dot.connected { background-color: #4CAF50; }
.status-dot.failed { background-color: #ff4444; }

/* Prompt Preset Editor Styles */
.prompt-container {
    padding: 0 !important;
    overflow: hidden;
}

.prompt-block {
    background-color: transparent;
    border: none;
    border-radius: 0;
    border-bottom: 1px solid rgba(127, 127, 127, 0.2);
    margin-bottom: 0;
    display: flex;
    overflow: hidden;
    box-shadow: none;
    transition: box-shadow 0.2s, opacity 0.3s ease, background-color 0.3s ease;
    align-items: center;
    padding-right: 12px;
    position: relative;
    z-index: 1;
    width: 100%;
}

.prompt-block:last-child {
    border-bottom: none;
}

.prompt-block.dragging {
    opacity: 0.5;
    transform: scale(0.98);
    box-shadow: 0 5px 15px rgba(0,0,0,0.1);
}

.prompt-block.disabled {
    opacity: 0.5;
}

.preset-selector {
  height: 32px;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  font-weight: 600;
  font-size: 13px;
  color: var(--vk-blue);
  padding: 0 14px;
  border-radius: 16px;
  background-color: var(--white);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  overflow: hidden;
}

:global(body.dark-theme) .preset-selector {
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.token-count-badge {
    display: flex;
    align-items: center;
    font-size: 12px;
    color: var(--text-gray);
    background-color: rgba(0,0,0,0.05);
    padding: 4px 8px;
    border-radius: 12px;
    margin-left: auto;
}
.token-count-badge svg {
    width: 14px;
    height: 14px;
    margin-right: 4px;
    fill: currentColor;
    opacity: 0.7;
}

.preset-selector svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.block-handle {
    width: 30px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: grab;
    color: var(--text-gray);
    font-size: 20px;
    line-height: 1;
    user-select: none;
    padding: 0 4px;
    touch-action: none;
}

.block-content {
    flex: 1;
    padding: 10px 5px;
    display: flex;
    align-items: center;
    overflow: hidden;
}

.block-name {
    font-weight: 500;
    font-size: 15px;
    color: var(--text-black);
    flex: 1;
    white-space: normal;
    word-break: break-word;
    display: flex;
    align-items: center;
}

.macro-badge {
    font-size: 9px;
    padding: 1px 4px;
    border-radius: 4px;
    margin-left: 4px;
    margin-bottom: 2px;
    text-transform: uppercase;
    font-weight: bold;
    color: white;
    line-height: 1;
    flex-shrink: 0;
}
.macro-badge.setvar {
    background-color: var(--vk-blue);
}
.macro-badge.getvar {
    background-color: #4CAF50;
}

.block-role-icon {
    width: 16px;
    height: 16px;
    opacity: 0.6;
    fill: currentColor;
    margin-right: 8px;
}

.block-tokens {
    font-size: 11px;
    color: var(--text-gray);
    background-color: rgba(0,0,0,0.05);
    padding: 2px 5px;
    border-radius: 8px;
    flex-shrink: 0;
}

.block-actions {
    display: flex;
    align-items: center;
}

.block-edit {
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: var(--text-gray);
    opacity: 0.6;
    transition: opacity 0.2s;
}

.block-edit:active {
    opacity: 1;
}

.block-edit svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.small-switch {
    transform: scale(0.8);
    transform-origin: right center;
}

.block-lock-wrap {
    width: 44px;
    height: 24px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
}

.block-lock-icon {
    width: 18px;
    height: 18px;
    fill: var(--text-gray, rgba(127,127,127,0.5));
}

.preset-connection-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;
}

.preset-connection-btn:hover {
    background: rgba(var(--vk-blue-rgb), 0.2);
    transform: scale(1.05);
}

.preset-connection-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.block-list-enter-active,
.block-list-leave-active {
  transition: all 0.3s ease;
}
.block-list-enter-from,
.block-list-leave-to {
  opacity: 0;
  transform: translateY(-10px);
}

.block-list-move {
  transition: none !important;
}

.status-fade-enter-active,
.status-fade-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}
.status-fade-enter-from,
.status-fade-leave-to {
  opacity: 0;
  transform: translateY(5px);
}

/* Slide Transitions */
.slide-left-enter-active,
.slide-left-leave-active,
.slide-right-enter-active,
.slide-right-leave-active {
  transition: transform 0.15s ease, opacity 0.15s ease;
}

.slide-left-enter-from {
  transform: translateX(20px);
  opacity: 0;
}
.slide-left-leave-to {
  transform: translateX(-20px);
  opacity: 0;
}

.slide-right-enter-from {
  transform: translateX(-20px);
  opacity: 0;
}
.slide-right-leave-to {
  transform: translateX(20px);
  opacity: 0;
}

.noise-bg::before {
    content: "";
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='1'/%3E%3C/svg%3E");
    opacity: 0.025;
    background-size: 300px 300px;
    pointer-events: none;
    z-index: 0;
}

.gen-sheet-header {
    height: 56px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 16px;
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
}

.header-title {
    font-weight: 600;
    font-size: 17px;
}

.header-btn {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: var(--vk-blue);
}
.header-btn svg { width: 24px; height: 24px; fill: currentColor; }

.gen-sheet-tabs { padding: 10px 16px; flex-shrink: 0; }
.gen-sheet-body { flex: 1; overflow-y: auto; position: relative;}

.preset-overview-block {
    margin: 8px 16px 0;
    padding: 12px;
    background: rgba(var(--vk-blue-rgb), 0.05);
    border: 1px solid var(--border-color);
    border-radius: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.preset-dashboard {
    /* Base styling for when no image is present */
    margin: 8px 16px;
    padding: 12px 12px 0;
    background: rgba(var(--vk-blue-rgb), 0.05);
    border: 1px solid var(--border-color);
    border-radius: 16px;
    background-clip: padding-box;
    display: flex;
    flex-direction: column;
    gap: 12px;
    transition: background 0.2s, transform 0.1s;
    position: relative;
    overflow: hidden;
}

.preset-dashboard.has-background {
    background-size: 100% auto;
    background-position: top center;
    background-repeat: no-repeat;
    background-color: transparent;
    padding: 12px 12px 0;
    min-height: auto;
    justify-content: flex-start;
}

.preset-dashboard.has-background::before {
    content: "";
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    /* Fade from dark at top to app background color at bottom */
    background: linear-gradient(to bottom, rgba(0,0,0,0.7) 0%, rgba(0,0,0,0.4) 80px, var(--app-bg) 200px);
    z-index: 0;
}

.preset-dashboard.has-background > * {
    position: relative;
    z-index: 1;
}

body.dark-theme .preset-dashboard.has-background::before {
    background: linear-gradient(to bottom, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.6) 80px, var(--app-bg) 200px);
}

.preset-dashboard.has-background .active-preset-name,
.preset-dashboard.has-background .active-label,
.preset-dashboard.has-background .level-pill,
.preset-dashboard.has-background .level-name,
.preset-dashboard.has-background .active-preset-author {
    color: white;
    text-shadow: 0 1px 4px rgba(0,0,0,0.5);
}

.preset-dashboard.has-background .active-preset-author {
    opacity: 0.7;
}

.preset-dashboard.has-background .hierarchy-item.active {
    background: rgba(255, 255, 255, 0.2);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255, 255, 255, 0.1);
}

.action-icons-corner {
    position: absolute;
    top: 16px;
    right: 12px;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    z-index: 5;
}

.preset-dashboard.has-background .active-tokens {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255,255,255,0.1);
}

.preset-dashboard.has-background .header-stash-btn {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255,255,255,0.1);
}

.preset-dashboard.has-background .header-stash-btn:hover {
    background: rgba(255, 255, 255, 0.3);
}

.dashboard-utils-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0 4px;
    margin-top: 24px;
}

.utils-left, .utils-right {
    display: flex;
    align-items: center;
}

.header-dots-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 50%;
    cursor: pointer;
    color: var(--vk-blue);
    transition: all 0.2s;
}

.preset-dashboard.has-background .header-dots-btn {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255,255,255,0.1);
}

.header-dots-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
    opacity: 0.8;
}

.prompt-blocks-area {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    margin-left: -12px;
    margin-right: -12px;
}

/* Removed active scaling for the whole dashboard since it contains interactive elements now */

.dashboard-active-row {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    cursor: pointer;
    padding: 8px;
    border-radius: 12px;
    transition: background 0.2s;
}

.dashboard-edit-header {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    padding: 0 8px;
}

.active-row-content {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
}

.dashboard-active-row:hover {
    background: rgba(0,0,0,0.03);
}

.active-label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    color: var(--vk-blue);
    letter-spacing: 0.05em;
    opacity: 0.7;
}

.active-preset-name-wrapper {
    display: flex;
    align-items: center;
    gap: 4px;
    min-width: 0;
}

.active-preset-name {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-black);
    line-height: 1.2;
    word-break: break-word; /* Allow wrapping */
}

.preset-name-arrow {
    width: 20px;
    height: 20px;
    fill: currentColor;
    opacity: 0.5;
}

.preset-dashboard.has-background .preset-name-arrow {
    filter: drop-shadow(0 1px 4px rgba(0,0,0,0.5));
}

.active-name-group {
    display: flex;
    flex-direction: column;
    gap: 0px;
    flex: 1;
    cursor: pointer;
    min-width: 0;
    padding-right: 40px;
}

.active-preset-author {
    font-size: 12px;
    font-weight: 500;
    color: var(--vk-blue);
    opacity: 0.8;
    word-break: break-word; /* Allow wrapping */
}

.active-tokens {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 12px;
    font-weight: 600;
    color: var(--text-gray);
    background: rgba(0,0,0,0.05);
    padding: 4px 8px;
    border-radius: 20px;
}

.active-tokens svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
    opacity: 0.7;
}

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
    gap: 2px;
    padding: 6px 8px;
    border-radius: 8px;
    transition: all 0.2s;
    min-width: 0;
}

.hierarchy-item.active {
    background: white;
    box-shadow: 0 2px 8px rgba(0,0,0,0.05);
}

body.dark-theme .hierarchy-item.active {
    background: #2c2c2e;
}

.hierarchy-item.empty {
    opacity: 0.4;
}

.level-pill {
    font-size: 9px;
    font-weight: 700;
    text-transform: uppercase;
    color: var(--text-gray);
    opacity: 0.6;
}

.hierarchy-item.active .level-pill {
    color: var(--vk-blue);
    opacity: 1;
}

.level-name {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-black);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* Tiny token chips removed from hierarchy */

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

.add-block-btn {
    border-top: 1px solid rgba(127, 127, 127, 0.2);
    cursor: pointer;
    transition: background 0.2s;
    background: transparent;
}

.add-block-btn .block-name {
    color: var(--vk-blue);
    font-weight: 600;
}

.add-block-btn .block-role-icon {
    color: var(--vk-blue);
    opacity: 0.8;
}

.add-block-btn:active {
    background: rgba(var(--vk-blue-rgb), 0.05);
}

/* Old Card Styles removed */
.preset-card-bottom {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.preset-display-name {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-black);
}

.preset-chevron {
    color: var(--text-gray);
    display: flex;
    align-items: center;
}

.preset-chevron svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

/* Advanced Settings Toggle */
.advanced-settings-toggle {
    margin: 16px;
    padding: 12px;
    border-radius: 12px;
    background: var(--bg-gray);
    display: flex;
    justify-content: space-between;
    align-items: center;
    cursor: pointer;
    font-weight: 600;
    font-size: 14px;
    color: var(--text-gray);
    transition: all 0.2s;
}

.advanced-settings-toggle:active {
    background: rgba(0,0,0,0.05);
}

.advanced-settings-toggle svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
    transition: transform 0.3s cubic-bezier(0.16, 1, 0.3, 1);
}

.advanced-settings-toggle svg.rotated {
    transform: rotate(180deg);
}

.advanced-settings-panel {
    overflow: hidden;
}

/* Transitions */
.expand-enter-active,
.expand-leave-active {
  transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
  max-height: 1000px;
  opacity: 1;
}

.expand-enter-from,
.expand-leave-to {
  max-height: 0;
  opacity: 0;
  transform: translateY(-10px);
}

.stash-section {
    margin-top: 16px;
    padding-top: 16px;
    border-top: 1px solid rgba(0,0,0,0.05);
}

body.dark-theme .stash-section {
    border-top: 1px solid rgba(255,255,255,0.05);
}

.stash-toggle {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: rgba(var(--vk-blue-rgb), 0.05);
    border-radius: 10px;
    cursor: pointer;
    font-size: 14px;
    font-weight: 600;
    color: var(--vk-blue);
    transition: background 0.2s;
}

.stash-toggle:hover {
    background: rgba(var(--vk-blue-rgb), 0.1);
}

.stash-icon {
    width: 20px;
    height: 20px;
    fill: currentColor;
    opacity: 0.8;
}

.chevron-icon {
    width: 20px;
    height: 20px;
    fill: currentColor;
    margin-left: auto;
    transition: transform 0.3s;
}

.chevron-icon.rotated {
    transform: rotate(180deg);
}

.stash-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 8px;
    padding: 4px;
}

.stashed-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: rgba(0,0,0,0.03);
    border: 1px solid rgba(0,0,0,0.05);
    border-radius: 10px;
    gap: 12px;
}

body.dark-theme .stashed-item {
    background: rgba(255,255,255,0.03);
    border-color: rgba(255,255,255,0.05);
}

.stashed-info {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
}

.stashed-role-icon {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
    flex-shrink: 0;
}

.stashed-name {
    font-size: 13px;
    color: var(--text-black);
    font-weight: 500;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.stashed-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
}

.unstash-btn {
    background: var(--vk-blue);
    color: white;
    border: none;
    padding: 4px 10px;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
}

.stashed-delete {
    color: #ff4444;
    cursor: pointer;
    display: flex;
    padding: 4px;
    opacity: 0.7;
    transition: opacity 0.2s;
}

.stashed-delete:hover {
    opacity: 1;
}

.stashed-delete svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.header-stash-btn {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 6px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 20px;
    cursor: pointer;
    color: var(--vk-blue);
    transition: all 0.2s;
}

.header-stash-btn:hover {
    background: rgba(var(--vk-blue-rgb), 0.2);
}

.header-stash-btn.active {
    background: var(--vk-blue);
    color: white;
}

.header-stash-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
    opacity: 0.7;
}

.stash-count-dot {
    position: absolute;
    top: -4px;
    right: -4px;
    background: #ff4444;
    color: white;
    font-size: 9px;
    font-weight: 700;
    min-width: 12px;
    height: 12px;
    border-radius: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0 3px;
    border: 1px solid var(--app-bg);
}

.small-header {
    margin-bottom: 8px;
    font-size: 12px !important;
    opacity: 0.6;
}

/* Block Editor Rework */
.block-editor-view {
    display: flex;
    flex-direction: column;
}

.block-editor-scroll {
    flex: 1;
    overflow-y: auto;
}

.block-editor-inline-actions {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px;
}

.editor-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    width: 100%;
    padding: 14px;
    border-radius: 12px;
    border: none;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    transition: transform 0.1s, opacity 0.2s;
}

.editor-btn:active {
    transform: scale(0.98);
}

.stash-btn {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

.delete-btn {
    background: rgba(255, 68, 68, 0.1);
    color: #ff4444;
}

.editor-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

/* ═══ Preset Selector List ═══ */
.preset-selector-list {
    padding: 8px 16px 20px;
}

.ps-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.ps-card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    background: var(--menu-group-bg, rgba(0,0,0,0.02));
    border: 2px solid var(--border-color, rgba(0,0,0,.08));
    border-radius: 12px;
    cursor: pointer;
    transition: all 0.2s ease;
    user-select: none;
    position: relative;
    overflow: hidden;
    background-size: cover;
    background-position: center top;
}

.ps-card.ps-has-bg {
    min-height: 160px;
    align-items: flex-end;
    padding: 12px 16px;
}

.ps-card:active {
    transform: scale(0.98);
}

.ps-card.ps-has-bg:active .ps-card-overlay {
    background: linear-gradient(to top, rgba(0,0,0,0.9) 0%, rgba(0,0,0,0.4) 100%);
}

.ps-card.ps-active {
    border-color: var(--accent-color, var(--vk-blue));
}

/* Overlay for image cards */
.ps-card-overlay {
    position: absolute;
    top: 0; left: 0; width: 100%; height: 100%;
    background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, rgba(0,0,0,0.3) 100%);
    z-index: 1;
}

.ps-card > *:not(.ps-card-overlay):not(.ps-featured-badge):not(.ps-card-actions) {
    position: relative;
    z-index: 2;
}

/* Featured badge */
.ps-featured-badge {
    position: absolute;
    top: 10px;
    left: 12px;
    background: transparent;
    color: rgba(255, 255, 255, 0.5);
    font-size: 9px;
    font-weight: 700;
    padding: 0;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    z-index: 3;
    text-shadow: 0 1px 2px rgba(0,0,0,0.5);
}

.ps-card-icon {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: rgba(var(--vk-blue-rgb), 0.1);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    color: var(--vk-blue);
    box-shadow: 0 2px 5px rgba(0,0,0,0.1);
}

.ps-card.ps-has-bg .ps-card-icon {
    display: none;
}

.ps-card-icon svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.ps-card-info {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    padding-right: 80px;
}

.ps-card-label-row {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    margin-bottom: 2px;
}

.ps-card-name {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-black);
    white-space: normal;
    word-break: break-word;
}

.ps-card-name.ps-with-bg {
    color: #ffffff;
    text-shadow: 0 1px 3px rgba(0,0,0,0.8);
    font-size: 16px;
    white-space: normal;
    word-break: break-word;
}

.ps-card-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 10px;
    font-weight: 700;
    padding: 2px 6px;
    border-radius: 12px;
    background: rgba(0, 0, 0, 0.05);
    color: var(--text-gray);
    flex-shrink: 0;
}

.ps-card-badge.ps-with-bg {
    background: rgba(255, 255, 255, 0.2);
    color: white;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255, 255, 255, 0.1);
}

.ps-badge-icon {
    width: 12px;
    height: 12px;
    fill: currentColor;
    opacity: 0.7;
}

.ps-card-meta {
    font-size: 12px;
    color: var(--text-light-gray);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
}

.ps-card-meta.ps-with-bg {
    color: rgba(255,255,255,0.7);
    text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.ps-card-meta > span:not(:last-child)::after {
    content: ' · ';
    opacity: 0.5;
}

.ps-badge-area {
    flex-shrink: 0;
}

.ps-conn-badge {
    width: 30px;
    height: 30px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.2s;
    cursor: pointer;
}

.ps-conn-badge:active {
    transform: scale(0.9);
}

.ps-conn-badge svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
}

.ps-conn-none {
    background: rgba(0,0,0,0.04);
    color: var(--text-gray);
    opacity: 0.5;
}

.ps-conn-badge.ps-with-bg.ps-conn-none {
    background: rgba(255,255,255,0.15);
    color: white;
    opacity: 0.6;
}

.ps-conn-global {
    background: rgba(52, 199, 89, 0.12);
    color: #34c759;
}

.ps-conn-character {
    background: rgba(175, 82, 222, 0.12);
    color: #af52de;
}

.ps-conn-chat {
    background: rgba(255, 149, 0, 0.12);
    color: #ff9500;
}

.ps-conn-badge.ps-with-bg.ps-conn-global,
.ps-conn-badge.ps-with-bg.ps-conn-character,
.ps-conn-badge.ps-with-bg.ps-conn-chat {
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    border: 1px solid rgba(255,255,255,0.1);
}

.ps-edit-btn {
    width: 34px;
    height: 34px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-gray);
    opacity: 0.6;
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;
}

.ps-edit-btn:active {
    opacity: 1;
    background: rgba(var(--vk-blue-rgb), 0.08);
    color: var(--vk-blue);
}

.ps-edit-btn.ps-with-bg {
    color: white;
    opacity: 0.8;
    background: rgba(0,0,0,0.4);
    border-radius: 50%;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
}

.ps-edit-btn.ps-with-bg:active {
    opacity: 1;
    background: rgba(0,0,0,0.6);
    color: white;
}

.ps-card-actions {
    position: absolute;
    top: 10px;
    right: 12px;
    display: flex;
    align-items: center;
    gap: 8px;
    z-index: 5;
}

.ps-edit-btn svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.ps-add-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 14px;
    border-radius: 14px;
    background: var(--accent-color, var(--vk-blue));
    color: white;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
    user-select: none;
    margin-top: 4px;
}

.ps-add-btn:active {
    transform: scale(0.97);
    opacity: 0.85;
}

.ps-add-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}
/* Expand Buttons */
.label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
}

.label-row label {
    margin-bottom: 0 !important;
}

.expand-btn {
    cursor: pointer;
    color: var(--vk-blue);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 6px;
    margin: -6px;
    border-radius: 50%;
    transition: background-color 0.2s;
}

.expand-btn:hover {
    background-color: rgba(81, 129, 184, 0.1);
}

.expand-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}
</style>