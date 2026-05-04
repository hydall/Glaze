<script setup>
import { ref } from 'vue';
import { closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';
import { formatError } from '@/utils/errors.js';

const props = defineProps({
    entry: { type: Object, required: true },
    onSave: { type: Function, required: true },
    onPreview: { type: Function, required: true }
});

const title = ref(props.entry.title || '');
const content = ref(props.entry.content || '');
const keys = ref(Array.isArray(props.entry.keys) ? props.entry.keys.join(', ') : '');

function handleCancel() {
    closeBottomSheet();
    setTimeout(() => props.onPreview(), 50);
}

async function handleSave() {
    const nextTitle = title.value.trim() || 'Untitled memory';
    const nextContent = content.value.trim();
    const nextKeys = parseMemoryKeyInput(keys.value);

    if (!nextContent) {
        showToast('Memory content is required');
        return;
    }

    try {
        await props.onSave({ title: nextTitle, content: nextContent, keys: nextKeys });
    } catch (error) {
        console.error('Failed to save memory entry:', error);
        showToast(`Memory save failed: ${formatError(error)}`);
    }
}

function parseMemoryKeyInput(input) {
    if (!input || !input.trim()) return [];
    return input.split(/[,;]+/).map(k => k.trim().toLowerCase()).filter(Boolean);
}
</script>

<template>
    <div class="context-sheet">
        <div class="settings-item">
            <label>Title</label>
            <input v-model="title" type="text" placeholder="Memory title">
        </div>
        <div class="settings-item">
            <label>Content</label>
            <textarea v-model="content" rows="8" placeholder="Memory text"></textarea>
        </div>
        <div class="settings-item">
            <label>Keys</label>
            <input v-model="keys" type="text" placeholder="key one, key two">
            <div class="context-sheet-note">Only this field is used for keyword retrieval.</div>
        </div>
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-secondary" @click="handleCancel">Cancel</button>
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" @click="handleSave">Save</button>
        </div>
    </div>
</template>
