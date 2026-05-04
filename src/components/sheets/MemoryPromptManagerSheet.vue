<script setup>
import { closeBottomSheet } from '@/core/states/bottomSheetState.js';

const props = defineProps({
    customPrompts: { type: Array, default: () => [] },
    onAdd: { type: Function, required: true },
    onEdit: { type: Function, required: true },
    onDelete: { type: Function, required: true },
    onPreview: { type: Function, required: true }
});
</script>

<template>
    <div class="context-sheet">
        <div class="context-sheet-actions" style="margin-top: 0; margin-bottom: 12px;">
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" @click="onAdd">Add Prompt</button>
            <button type="button" class="context-sheet-btn context-sheet-btn-secondary" @click="closeBottomSheet()">Close</button>
        </div>
        <div v-if="customPrompts.length" class="memory-entry-list">
            <div
                v-for="item in customPrompts"
                :key="item.id"
                class="memory-entry-card"
                @click="onPreview(item)"
            >
                <div class="memory-entry-head">
                    <div>
                        <div class="memory-entry-title">{{ item.name || 'Custom prompt' }}</div>
                        <div class="memory-entry-meta">custom prompt</div>
                    </div>
                    <div class="memory-draft-actions" @click.stop>
                        <button type="button" class="memory-entry-approve" @click="onEdit(item)">Edit</button>
                        <button type="button" class="memory-entry-delete" @click="onDelete(item)">Delete</button>
                    </div>
                </div>
                <div class="memory-entry-preview">{{ (item.prompt || '').slice(0, 180) }}</div>
            </div>
        </div>
        <div v-else class="context-sheet-note">No custom prompts yet.</div>
    </div>
</template>
