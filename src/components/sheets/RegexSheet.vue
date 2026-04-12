<script setup>
import { ref, computed, watch } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { getEffectivePreset, getEffectivePresetId, savePresets } from '@/core/states/presetState.js';
import { exportSTRegex } from '@/core/services/regexService.js';
import { saveFile } from '@/core/services/fileSaver.js';
import HelpTip from '@/components/ui/HelpTip.vue';


const props = defineProps({
    activeChatChar: { type: Object, default: null },
    insidePreset: { type: Boolean, default: false },
    zIndex: { type: Number, default: 11000 }
});

const sheet = ref(null);
const t = (key) => translations[currentLang.value]?.[key] || key;

const currentView = ref('list'); // list, edit
const activeScript = ref(null);
const isPresetScript = ref(false);
const fileInput = ref(null);

const presetRegexes = computed(() => {
    const charId = props.activeChatChar?.id;
    const sessionId = props.activeChatChar?.sessionId;
    const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
    const preset = getEffectivePreset(charId, chatId);
    return preset?.regexes || [];
});

const effectivePresetName = computed(() => {
    const charId = props.activeChatChar?.id;
    const sessionId = props.activeChatChar?.sessionId;
    const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
    const preset = getEffectivePreset(charId, chatId);
    return preset?.name || 'Default';
});

// Global state
const scripts = ref([]);

// Load scripts from localStorage for persistence
const loadScripts = () => {
    try {
        const stored = localStorage.getItem('regex_scripts');
        if (stored) {
            scripts.value = JSON.parse(stored);
        }
    } catch (e) {
        console.error('Failed to load regex scripts', e);
    }
};
loadScripts();

const saveScripts = () => {
    if (activeScript.value && isPresetScript.value) {
        savePresets();
    } else {
        localStorage.setItem('regex_scripts', JSON.stringify(scripts.value));
    }
    window.dispatchEvent(new CustomEvent('regex-scripts-changed'));
};

let saveTimeout = null;
watch(() => activeScript.value, (newVal) => {
    if (newVal) {
        if (saveTimeout) clearTimeout(saveTimeout);
        saveTimeout = setTimeout(() => {
            saveScripts();
        }, 500);
    }
}, { deep: true });

function open() {
    if (!sheet.value?.isVisible) {
        currentView.value = 'list';
    }
    sheet.value?.open();
}

function close() {
    sheet.value?.close();
}

function handleSheetClose() {
    if (currentView.value === 'edit' && activeScript.value) {
        saveScripts();
        activeScript.value = null;
        isPresetScript.value = false;
    }
    currentView.value = 'list';
}

function goBack() {
    if (currentView.value === 'edit') {
        currentView.value = 'list';
        saveScripts();
        activeScript.value = null;
        isPresetScript.value = false;
    } else {
        close();
    }
}

function createNewScript(toPreset = false) {
    const newScript = {
        id: Date.now().toString(),
        name: t('action_create_new') || 'New Script',
        regex: '',
        replacement: '',
        trimOut: '',
        placement: [2], // Default AI Output
        disabled: false,
        runOnEdit: false,
        macroRules: '0',
        ephemerality: [1, 2],
        minDepth: null,
        maxDepth: null
    };
    if (toPreset) {
        const charId = props.activeChatChar?.id;
        const sessionId = props.activeChatChar?.sessionId;
        const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
        const preset = getEffectivePreset(charId, chatId);
        if (preset) {
            if (!preset.regexes) preset.regexes = [];
            preset.regexes.push(newScript);
        }
        selectScript(newScript, true);
        savePresets();
    } else {
        scripts.value.push(newScript);
        selectScript(newScript, false);
        saveScripts();
    }
}

const importTargetPreset = ref(false);

function handleAddScript() {
    showBottomSheet({
        title: t('menu_regex') || 'Regex Scripts',
        items: [
            {
                label: t('regex_add_to_preset') || `Add to Preset`,
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    showBottomSheet({
                        title: effectivePresetName.value,
                        items: [
                            {
                                label: t('action_create_new') || 'Create New',
                                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                onClick: () => { closeBottomSheet(); createNewScript(true); }
                            },
                            {
                                label: t('action_import') || 'Import from file',
                                icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                                onClick: () => { closeBottomSheet(); importTargetPreset.value = true; fileInput.value?.click(); }
                            }
                        ]
                    });
                }
            },
            {
                label: t('regex_add_globally') || 'Add Globally',
                icon: '<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    showBottomSheet({
                        title: t('regex_global_scripts') || 'Global Regexes',
                        items: [
                            {
                                label: t('action_create_new') || 'Create New',
                                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                onClick: () => { closeBottomSheet(); createNewScript(false); }
                            },
                            {
                                label: t('action_import') || 'Import from file',
                                icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                                onClick: () => { closeBottomSheet(); importTargetPreset.value = false; fileInput.value?.click(); }
                            }
                        ]
                    });
                }
            }
        ]
    });
}

async function handleFileSelect(event) {
    const file = event.target.files?.[0];
    if (!file) return;

    try {
        const text = await file.text();
        const json = JSON.parse(text);
        const scriptsToImport = Array.isArray(json) ? json : [json];

        scriptsToImport.forEach(item => {
            const name = item.scriptName || item.name || t('regex_imported_script') || 'Imported Script';
            const regex = item.findRegex || item.regex || '';
            const replacement = item.replaceString || item.replacement || '';
            const trimOut = Array.isArray(item.trimStrings) ? item.trimStrings.join('\n') : (item.trimOut || '');
            const placement = item.placement || [2];
            
            // Ephemerality: ST's promptOnly means it's ONLY for prompt (2)
            // If promptOnly is false, it's for both display (1) and prompt (2)
            let ephemerality = item.ephemerality;
            if (!ephemerality) {
                if (item.markdownOnly === true && item.promptOnly === false) ephemerality = [1];
                else if (item.markdownOnly === false && item.promptOnly === true) ephemerality = [2];
                else if (item.markdownOnly === true && item.promptOnly === true) ephemerality = [1, 2];
                else ephemerality = [1, 2];
            }

            const script = {
                id: Date.now().toString() + Math.random(),
                name,
                regex,
                replacement,
                trimOut,
                placement,
                disabled: item.disabled ?? false,
                markdownOnly: item.markdownOnly ?? false,
                promptOnly: item.promptOnly ?? false,
                runOnEdit: item.runOnEdit ?? false,
                macroRules: (item.substituteRegex ?? 0).toString(),
                ephemerality,
                minDepth: item.minDepth ?? null,
                maxDepth: item.maxDepth ?? null
            };
            if (importTargetPreset.value) {
                const charId = props.activeChatChar?.id;
                const sessionId = props.activeChatChar?.sessionId;
                const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
                const preset = getEffectivePreset(charId, chatId);
                if (preset) {
                    if (!preset.regexes) preset.regexes = [];
                    preset.regexes.push(script);
                }
            } else {
                scripts.value.push(script);
            }
        });

        if (importTargetPreset.value) {
            savePresets();
        } else {
            saveScripts();
        }
        importTargetPreset.value = false;
        // Clear input to allow re-importing the same file
        event.target.value = '';
    } catch (e) {
        console.error('Failed to import regex scripts', e);
    }
}

function selectScript(script, isPreset = false) {
    if (script.trimOut === undefined) script.trimOut = '';
    if (script.placement === undefined) script.placement = [1];
    if (script.macroRules === undefined) script.macroRules = '0';
    if (script.ephemerality === undefined) script.ephemerality = [1, 2];
    if (script.minDepth === undefined) script.minDepth = null;
    if (script.maxDepth === undefined) script.maxDepth = null;

    
    activeScript.value = script;
    isPresetScript.value = isPreset;
    currentView.value = 'edit';
}

function handleDeleteScript(index, isPreset = false) {
    showBottomSheet({
        title: t('confirm_delete_block') || 'Delete Script?',
        items: [
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    if (isPreset) {
                        presetRegexes.value.splice(index, 1);
                        savePresets();
                    } else {
                        scripts.value.splice(index, 1);
                        saveScripts();
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

const placementOptions = computed(() => [
    { value: 1, label: t('regex_user_input') || 'User Input' },
    { value: 2, label: t('regex_ai_output') || 'AI Output' },
    { value: 4, label: t('regex_world_info') || 'World Info' },
    { value: 5, label: t('regex_reasoning') || 'Reasoning' }
]);

const macroOptions = computed(() => [
    { value: '0', label: t('regex_macro_none') || "Don't substitute" },
    { value: '1', label: t('regex_macro_raw') || "Substitute raw" },
    { value: '2', label: t('regex_macro_escaped') || "Substitute escaped" }
]);

const ephemeralityOptions = computed(() => [
    { value: 1, label: t('regex_alter_display') || 'Alter Chat Display' },
    { value: 2, label: t('regex_alter_prompt') || 'Alter Outgoing Prompt' }
]);



const sheetTitle = computed(() => currentView.value === 'list' ? (t('menu_regex') || 'Regex Scripts') : (t('regex_editor') || 'Regex Editor'));
const showBackBtn = computed(() => currentView.value !== 'list');
const sheetActions = computed(() => {
    if (currentView.value === 'list') {
        return [{ icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>', onClick: handleAddScript, title: t('action_add_script') || 'Add Script' }];
    }
    return [];
});

function handleScriptMenu(script, index, isPreset = false) {
    showBottomSheet({
        title: script.name || t('regex_imported_script') || 'Script',
        items: [
            {
                label: t('action_export') || 'Export',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 12v7H5v-7H3v7c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2v-7h-2zm-6 .67l2.59-2.58L17 11.5l-5 5-5-5 1.41-1.41L11 12.67V3h2v9.67z"/></svg>',
                onClick: async () => {
                    closeBottomSheet();
                    const stRegex = exportSTRegex(script);
                    const filename = 'regex-' + (script.name || 'script').replace(/\s+/g, '_') + '.json';
                    await saveFile(filename, JSON.stringify(stRegex, null, 2), 'application/json', 'regexes');
                }
            },
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    if (isPreset) {
                        presetRegexes.value.splice(index, 1);
                        savePresets();
                    } else {
                        scripts.value.splice(index, 1);
                        saveScripts();
                    }
                    closeBottomSheet();
                }
            }
        ]
    });
}

function openMacroSelector() {
    const items = macroOptions.value.map(opt => ({
        label: opt.label,
        icon: activeScript.value.macroRules === opt.value ? '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : null,
        onClick: () => {
            activeScript.value.macroRules = opt.value;
            closeBottomSheet();
        }
    }));
    showBottomSheet({
        title: t('regex_macros_find') || 'Macros',
        items: items
    });
}


function openPresetSheet() {
    if (props.insidePreset) {
        close();
    } else {
        const charId = props.activeChatChar?.id;
        const sessionId = props.activeChatChar?.sessionId;
        const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
        const presetId = getEffectivePresetId(charId, chatId);
        window.dispatchEvent(new CustomEvent('open-preset-sheet', { detail: { presetId } }));
    }
}

defineExpose({ open, close });
</script>

<template>
    <SheetView ref="sheet" :title="sheetTitle" :show-back="showBackBtn" :actions="sheetActions" :z-index="zIndex" @back="goBack" @close="handleSheetClose">
        <template #header-title>
            <HelpTip term="regex" />
        </template>
        <template #header>
            <input type="file" ref="fileInput" accept=".json" style="display: none;" @change="handleFileSelect">
        </template>

        <div class="sheet-body">
            <div v-if="currentView === 'list'" class="list-view">

                <!-- Preset Regexes -->
                <div class="list-section" v-if="presetRegexes.length > 0">
                    <div class="section-title">{{ t('regex_preset_scripts') || 'Preset Regexes' }}</div>
                    <div class="preset-chip" @click="openPresetSheet()">
                        <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                        <span>{{ effectivePresetName }}</span>
                        <svg class="chip-arrow" viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>
                    </div>
                    <div class="list-container">
                        <div v-for="(script, index) in presetRegexes" :key="script.id || index" class="list-item" @click="selectScript(script, true)">
                            <div class="item-info">
                                <div class="item-name">{{ script.name }}</div>
                                <div class="item-meta">{{ script.regex }}</div>
                            </div>
                            <div class="item-actions">
                                <input type="checkbox" class="vk-switch small-switch" :checked="!script.disabled" @change="script.disabled = !$event.target.checked; savePresets()" @click.stop>
                                <div class="action-btn more" @click.stop="handleScriptMenu(script, index, true)">
                                    <svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Global Regexes -->
                <div class="list-section">
                    <div class="section-title">{{ t('regex_global_scripts') || 'Global Regexes' }}</div>
                    <div v-if="scripts.length === 0" class="empty-state">
                        <div class="empty-text">{{ t('no_entries_found') || 'No scripts' }}</div>
                    </div>
                    <div v-else class="list-container">
                        <div v-for="(script, index) in scripts" :key="script.id" class="list-item" @click="selectScript(script, false)">
                            <div class="item-info">
                                <div class="item-name">{{ script.name }}</div>
                                <div class="item-meta">{{ script.regex }}</div>
                            </div>
                            <div class="item-actions">
                                <input type="checkbox" class="vk-switch small-switch" :checked="!script.disabled" @change="script.disabled = !$event.target.checked; saveScripts()" @click.stop>
                                <div class="action-btn more" @click.stop="handleScriptMenu(script, index, false)">
                                    <svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div v-else class="edit-view">

                <div class="menu-group">
                    <div class="section-header">{{ t('regex_script_settings') || 'Script Settings' }}</div>
                    <div class="settings-item">
                        <label>{{ t('regex_script_name') || 'Script Name' }}</label>
                        <input type="text" v-model="activeScript.name" :placeholder="t('regex_script_name') || 'Script Name'">
                    </div>
                    <div class="settings-item">
                        <label>{{ t('regex_find') || 'Find Regex' }}</label>
                        <input type="text" v-model="activeScript.regex" :placeholder="t('regex_pattern_placeholder') || 'pattern'">
                    </div>

                    <div class="settings-item">
                        <label>{{ t('regex_replace_with') || 'Replace With' }}</label>
                        <textarea v-model="activeScript.replacement" rows="3" :placeholder="t('regex_replacement_placeholder') || 'Replacement string...'"></textarea>
                    </div>
                    <div class="settings-item">
                        <label>{{ t('regex_trim_out') || 'Trim Out' }} <HelpTip term="regex-trimout"/></label>
                        <textarea v-model="activeScript.trimOut" rows="2" :placeholder="t('regex_trim_out_placeholder') || 'Globally trims any unwanted parts from a regex match before replacement. Separate each element by an enter.'"></textarea>
                    </div>
                </div>

                <div class="options-grid">
                    <div class="options-col">
                        <div class="menu-group compact">
                            <div class="section-header">{{ t('regex_affects') || 'Affects' }} <HelpTip term="regex-placement"/></div>
                            <label class="settings-item-checkbox compact" v-for="opt in placementOptions" :key="opt.value">
                                <div class="checkbox-container">
                                    <input type="checkbox" :value="opt.value" v-model="activeScript.placement" class="native-checkbox">
                                    <span class="settings-text-col">{{ opt.label }}</span>
                                </div>
                            </label>
                        </div>
                        
                        <div class="depth-row">
                            <div class="settings-item compact depth-item">
                                <label>{{ t('regex_min_depth') || 'Min Depth' }}</label>
                                <input type="number" v-model="activeScript.minDepth" :placeholder="t('regex_unlimited_placeholder') || 'Unlimited'">
                            </div>
                            <div class="settings-item compact depth-item">
                                <label>{{ t('regex_max_depth') || 'Max Depth' }}</label>
                                <input type="number" v-model="activeScript.maxDepth" :placeholder="t('regex_unlimited_placeholder') || 'Unlimited'">
                            </div>
                        </div>
                    </div>

                    <div class="options-col">
                        <div class="menu-group compact">
                            <div class="section-header">{{ t('regex_other_options') || 'Other Options' }}</div>
                            <label class="settings-item-checkbox compact">
                                <div class="checkbox-container">
                                    <input type="checkbox" v-model="activeScript.runOnEdit" class="native-checkbox">
                                    <span class="settings-text-col">{{ t('regex_run_on_edit') || 'Run On Edit' }}</span>
                                </div>
                            </label>
                        </div>

                        <div class="menu-group compact">
                            <div class="section-header">{{ t('regex_macros_find') || 'Macros in Find Regex' }} <HelpTip term="regex-macros"/></div>
                            <div class="settings-item select-item" @click="openMacroSelector">
                                <div class="clickable-selector">
                                    <span>{{ macroOptions.find(o => o.value === activeScript.macroRules)?.label || activeScript.macroRules }}</span>
                                    <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
                                </div>
                            </div>
                        </div>

                        <div class="menu-group compact">
                            <div class="section-header">{{ t('regex_ephemerality') || 'Ephemerality' }} <HelpTip term="regex-ephemerality"/></div>
                            <label class="settings-item-checkbox compact" v-for="opt in ephemeralityOptions" :key="opt.value">
                                <div class="checkbox-container">
                                    <input type="checkbox" :value="opt.value" v-model="activeScript.ephemerality" class="native-checkbox">
                                    <span class="settings-text-col">{{ opt.label }}</span>
                                </div>
                            </label>
                        </div>
                    </div>
                </div>


            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.sheet-header { height: 56px; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; border-bottom: 1px solid var(--border-color); flex-shrink: 0; }
.header-left, .header-right { width: 40px; display: flex; justify-content: center; }
.header-title { font-weight: 700; font-size: 18px; flex: 1; text-align: center; color: var(--text-black); }
.header-btn { width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; cursor: pointer; color: var(--vk-blue); }
.header-btn svg { width: 24px; height: 24px; fill: currentColor; }
.header-toggle { display: flex; align-items: center; justify-content: center; }
.sheet-body { flex: 1; overflow-y: auto; background: transparent; display: flex; flex-direction: column; }
.list-view { width: 100%; padding-bottom: 40px; }
.edit-view { width: 100%; padding-bottom: 40px; padding-top: 16px; }
.list-section { margin-top: 12px; margin-bottom: 8px; }
.section-title { padding: 0 16px 4px; font-weight: 600; font-size: 13px; color: var(--text-gray); text-transform: uppercase; }
.empty-state { padding: 40px; text-align: center; color: var(--text-gray); }
.list-container { padding: 12px; display: flex; flex-direction: column; gap: 8px; }
.list-item { display: flex; align-items: center; padding: 16px; background: rgba(30, 30, 32, var(--element-opacity, 0.7)); backdrop-filter: blur(10px); border-radius: 16px; border: 1px solid rgba(255,255,255,0.05); cursor: pointer; }
.item-info { flex: 1; overflow: hidden; margin-right: 12px; }
.item-name { font-weight: 600; font-size: 16px; color: var(--text-black); }
.item-meta { font-size: 13px; color: var(--text-gray); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.item-actions { display: flex; align-items: center; gap: 12px; }
.action-btn.delete { color: #ff3b30; width: 32px; height: 32px; display: flex; align-items: center; justify-content: center; }
.action-btn.more { color: var(--text-gray); width: 32px; height: 32px; display: flex; align-items: center; justify-content: center; }
.action-btn svg { width: 20px; height: 20px; fill: currentColor; }

.preset-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin: 4px 16px 8px;
    padding: 6px 12px 6px 10px;
    background: rgba(var(--vk-blue-rgb), 0.12);
    border: 1px solid rgba(var(--vk-blue-rgb), 0.25);
    border-radius: 20px;
    cursor: pointer;
    color: var(--vk-blue);
    font-size: 13px;
    font-weight: 600;
    transition: background 0.2s;
    max-width: calc(100% - 32px);
}
.preset-chip:active { background: rgba(var(--vk-blue-rgb), 0.22); }
.preset-chip > svg:first-child { width: 14px; height: 14px; fill: currentColor; flex-shrink: 0; }
.preset-chip > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.preset-chip .chip-arrow { width: 16px; height: 16px; fill: currentColor; opacity: 0.7; flex-shrink: 0; }

.hint-banner { background: linear-gradient(to right, rgba(40, 60, 90, 0.8), rgba(40, 60, 90, 0.6)); border: 1px solid rgba(100, 150, 200, 0.3); border-radius: 8px; padding: 10px 16px; margin: 12px 16px; display: flex; align-items: center; justify-content: space-between; color: white; font-size: 14px; font-weight: 500;}
.hint-banner .info-icon { width: 20px; height: 20px; border-radius: 50%; background: #ff9800; color: white; display: flex; align-items: center; justify-content: center; font-weight: bold; font-size: 12px; }

.options-grid { display: grid; grid-template-columns: 1fr; gap: 12px; }
@media (min-width: 600px) { .options-grid { grid-template-columns: 1fr 1fr; padding: 0 16px; } }
.options-col .menu-group { margin: 0 16px 16px; }
@media (min-width: 600px) { .options-col .menu-group { margin: 0 0 16px; } }

.menu-group.compact { padding: 4px 0; }
.menu-group.compact .section-header { border-bottom: none; margin-bottom: -4px; padding-bottom: 4px; padding-top: 8px; }

.settings-item.compact { padding: 12px; border: none; }
.settings-item label { display: flex; align-items: center; justify-content: space-between; font-weight: 600; }
.settings-item label .help-icon { color: rgba(255,255,255,0.6); font-size: 12px; background: rgba(255,255,255,0.1); width: 16px; height: 16px; display: flex; align-items: center; justify-content: center; border-radius: 50%; font-weight: bold; }

.settings-item-checkbox.compact { padding: 10px 20px; border-bottom: none; }
.checkbox-container { display: flex; align-items: center; gap: 12px; width: 100%; }
.settings-text-col { font-size: 15px; font-weight: 500; color: var(--text-black); }
.native-checkbox { width: 22px; height: 22px; cursor: pointer; margin: 0; }

.depth-row { display: flex; gap: 12px; margin: 0 16px; }
@media (min-width: 600px) { .depth-row { margin: 0; } }
.depth-item { flex: 1; background: rgba(30, 30, 32, var(--element-opacity, 0.7)); backdrop-filter: blur(10px); border-radius: 20px; border: 1px solid rgba(255,255,255,0.05); }

.select-item { padding: 8px 20px; border: none; }
.vk-select { width: 100%; padding: 10px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); background: rgba(0,0,0,0.2); color: var(--text-black); font-family: inherit; font-size: 14px; outline: none; }

.vk-switch { appearance: none; width: 44px; height: 24px; background: #e9e9ea; border-radius: 12px; position: relative; transition: 0.3s; cursor: pointer; }
.vk-switch:checked { background: var(--vk-blue); }
.vk-switch::after { content: ''; position: absolute; width: 20px; height: 20px; background: white; border-radius: 50%; top: 2px; left: 2px; transition: 0.3s; box-shadow: 0 1px 3px rgba(0,0,0,0.2); }
.vk-switch:checked::after { transform: translateX(20px); }
.small-switch { width: 36px; height: 20px; }
.small-switch::after { width: 16px; height: 16px; }
.small-switch:checked::after { transform: translateX(16px); }

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



</style>