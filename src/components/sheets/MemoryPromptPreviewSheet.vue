<script setup>
import { closeBottomSheet } from '@/core/states/bottomSheetState.js';

const props = defineProps({
    label: { type: String, default: 'Prompt' },
    prompt: { type: String, default: '' },
    onClose: { type: Function, default: null }
});

function handleClose() {
    closeBottomSheet();
    if (props.onClose) {
        setTimeout(() => props.onClose(), 50);
    }
}
</script>

<template>
    <div class="context-sheet">
        <div class="settings-item">
            <label>Rule</label>
            <div class="context-sheet-note">{{ label }}</div>
        </div>
        <div class="memory-entry-fulltext">{{ prompt }}</div>
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" @click="handleClose">
                {{ onClose ? 'Back' : 'Close' }}
            </button>
        </div>
    </div>
</template>
