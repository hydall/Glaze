<script setup>
import { reactive, computed } from 'vue';
import { closeBottomSheet, showBottomSheet } from '@/core/states/bottomSheetState.js';
import { getMemoryPromptOptions, getMemoryPromptLabelByKey } from '@/core/services/memoryPromptPresets.js';

const props = defineProps({
    settings: { type: Object, required: true },
    initialState: { type: Object, default: () => ({}) },
    onSelectPrompt: { type: Function, required: true },
    onPreviewPrompt: { type: Function, required: true },
    onManagePrompts: { type: Function, required: true },
    onSave: { type: Function, required: true },
    onCancel: { type: Function, required: true }
});

const state = reactive({
    promptPreset: props.initialState.promptPreset || props.settings.promptPreset || 'detailed_beats',
    source: props.initialState.source || props.settings.generationSource || 'current',
    model: props.initialState.model || props.settings.generationModel || '',
    temperature: props.initialState.temperature ?? props.settings.generationTemperature ?? '',
    maxTokens: props.initialState.maxTokens ?? props.settings.generationMaxTokens ?? '',
    autoCreateEnabled: props.initialState.autoCreateEnabled ?? props.settings.autoCreateEnabled ?? true,
    autoGenerateEnabled: props.initialState.autoGenerateEnabled ?? props.settings.autoGenerateEnabled ?? false,
    autoCreateInterval: props.initialState.autoCreateInterval ?? props.settings.autoCreateInterval ?? 15,
    batchSize: props.initialState.batchSize ?? props.settings.batchSize ?? 3,
    useDelayedAutomation: props.initialState.useDelayedAutomation ?? props.settings.useDelayedAutomation ?? true,
    maxInjectedEntries: props.initialState.maxInjectedEntries ?? props.settings.maxInjectedEntries ?? 7,
    injectionTarget: props.initialState.injectionTarget ?? props.settings.injectionTarget ?? 'summary_block'
});

const promptLabel = computed(() => getMemoryPromptLabelByKey(props.settings, state.promptPreset));
const injectionTargetLabel = computed(() =>
    state.injectionTarget === 'summary_macro' ? '{{summary}} macro' : 'Chat summary block'
);

function handlePromptSelector() {
    props.onSelectPrompt(state);
}

function handlePromptPreview() {
    props.onPreviewPrompt(state);
}

function handleInjectionTargetSelector() {
    closeBottomSheet();
    showBottomSheet({
        title: 'Memory Injection Target',
        items: [
            {
                label: 'Chat summary block',
                onClick: () => {
                    state.injectionTarget = 'summary_block';
                    closeBottomSheet();
                }
            },
            {
                label: '{{summary}} macro',
                onClick: () => {
                    state.injectionTarget = 'summary_macro';
                    closeBottomSheet();
                }
            }
        ]
    });
}

async function handleSave() {
    await props.onSave(state);
}

function handleCancel() {
    props.onCancel();
}
</script>

<template>
    <div class="context-sheet">
        <div class="settings-item">
            <label>Generation Rules</label>
            <div class="clickable-selector" @click="handlePromptSelector">
                <span>{{ promptLabel }}</span>
                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
            </div>
            <button type="button" class="memory-inline-link" @click="handlePromptPreview">Preview Rule</button>
        </div>
        <div class="settings-item">
            <label>Temperature Override</label>
            <input v-model.number="state.temperature" type="number" min="0" max="2" step="0.05" placeholder="Use current API temperature">
        </div>
        <div class="settings-item">
            <label>Output Token Limit</label>
            <input v-model.number="state.maxTokens" type="number" min="200" max="32000" step="100" placeholder="Auto (recommended 2000-4000 for large batches)">
            <div class="context-sheet-note">Optional max completion tokens for memory draft generation. Leave blank to use the provider default with a safety floor.</div>
        </div>
        <div class="settings-item-checkbox">
            <div class="settings-text-col">
                <label>Auto-Create Drafts</label>
                <div class="settings-desc">Automatically create Memory Book drafts after enough stable messages accumulate.</div>
            </div>
            <input v-model="state.autoCreateEnabled" type="checkbox" class="vk-switch">
        </div>
        <div class="settings-item-checkbox">
            <div class="settings-text-col">
                <label>Auto-Generate Draft Text</label>
                <div class="settings-desc">When enabled, newly auto-created draft placeholders immediately generate text. When disabled, auto mode only marks segments and leaves text generation manual.</div>
            </div>
            <input v-model="state.autoGenerateEnabled" type="checkbox" class="vk-switch">
        </div>
        <div class="settings-item">
            <label>Create Memory Every N Messages</label>
            <input v-model.number="state.autoCreateInterval" type="number" min="1" max="200" step="1" placeholder="15">
            <div class="context-sheet-note">User-facing interval for future automatic memory creation and import bootstrap segmentation.</div>
        </div>
        <div class="settings-item">
            <label>Max Generate Batch</label>
            <input v-model.number="state.batchSize" type="number" min="1" max="50" step="1" placeholder="3">
            <div class="context-sheet-note">Limits how many pending drafts the batch generate button starts at once.</div>
        </div>
        <div class="settings-item-checkbox">
            <div class="settings-text-col">
                <label>Work With Delay</label>
                <div class="settings-desc">Wait for extra turns before auto-creating a memory draft, so the last user message and latest assistant reply can still be edited or regenerated safely.</div>
            </div>
            <input v-model="state.useDelayedAutomation" type="checkbox" class="vk-switch">
        </div>
        <div class="settings-item">
            <label>Memory Entries In Prompt</label>
            <input v-model.number="state.maxInjectedEntries" type="number" min="1" max="20" step="1" placeholder="7">
            <div class="context-sheet-note">How many retrieved memory entries can be injected into the prompt at once.</div>
        </div>
        <div class="settings-item">
            <label>Injection Target</label>
            <div class="clickable-selector" @click="handleInjectionTargetSelector">
                <span>{{ injectionTargetLabel }}</span>
                <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
            </div>
            <div class="context-sheet-note">Choose whether retrieved memory context follows the dedicated summary block path or the {{summary}} macro location.</div>
        </div>
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-secondary" @click="handleCancel">Cancel</button>
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" @click="handleSave">Save</button>
        </div>
    </div>
</template>
