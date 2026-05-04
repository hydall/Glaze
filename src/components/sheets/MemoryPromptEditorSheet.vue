<script setup>
import { ref } from 'vue';
import { closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';

const props = defineProps({
    existing: { type: Object, default: null },
    onSave: { type: Function, required: true }
});

const name = ref(props.existing?.name || '');
const prompt = ref(props.existing?.prompt || '');

function handleCancel() {
    closeBottomSheet();
}

async function handleSave() {
    const nextName = name.value.trim() || 'Custom prompt';
    const nextPrompt = prompt.value.trim();
    if (!nextPrompt) {
        showToast('Prompt text is required');
        return;
    }
    await props.onSave({ name: nextName, prompt: nextPrompt });
}
</script>

<template>
    <div class="context-sheet">
        <div class="settings-item">
            <label>Name</label>
            <input v-model="name" type="text" placeholder="Prompt name">
        </div>
        <div class="settings-item">
            <label>Prompt</label>
            <textarea v-model="prompt" rows="10" placeholder="Use {{history}}, {{user}}, {{char}}"></textarea>
        </div>
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-secondary" @click="handleCancel">Cancel</button>
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" @click="handleSave">Save</button>
        </div>
    </div>
</template>
