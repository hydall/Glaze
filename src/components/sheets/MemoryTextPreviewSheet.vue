<script setup>
import { closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';
import { formatError } from '@/utils/errors.js';

const props = defineProps({
    entry: { type: Object, required: true },
    kind: { type: String, default: 'Memory' },
    vectorEnabled: { type: Boolean, default: false },
    onEdit: { type: Function, default: null },
    onReindex: { type: Function, default: null },
    onDelete: { type: Function, default: null },
    onRegenerate: { type: Function, default: null },
    onClose: { type: Function, default: null }
});

const isApproved = props.kind === 'Memory Entry';
const reindexing = defineModel('reindexing', { default: false });

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
            <label>{{ kind }}</label>
            <div class="context-sheet-note">{{ entry.title || kind }}</div>
        </div>
        <div class="settings-item">
            <label>Retrieval</label>
            <div class="context-sheet-note">Vector search: {{ entry.vectorSearch ? 'enabled' : 'disabled' }}</div>
            <div class="memory-chip-list">
                <template v-if="entry.keys && entry.keys.length">
                    <span v-for="key in entry.keys" :key="key" class="memory-chip">{{ key }}</span>
                </template>
                <span v-else class="context-sheet-note">No keys yet</span>
            </div>
        </div>
        <div class="memory-entry-fulltext">{{ entry.content || '' }}</div>
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-secondary" @click="onRegenerate">Regenerate</button>
            <button v-if="isApproved" type="button" class="context-sheet-btn context-sheet-btn-secondary" @click="onEdit">Edit</button>
            <button v-if="isApproved" type="button" class="context-sheet-btn context-sheet-btn-secondary" :disabled="reindexing" @click="onReindex">
                {{ reindexing ? 'Reindexing...' : 'Reindex' }}
            </button>
            <button v-if="isApproved" type="button" class="context-sheet-btn context-sheet-btn-secondary memory-preview-delete" @click="onDelete">Delete</button>
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" @click="handleClose">
                {{ isApproved ? 'Close' : 'Back' }}
            </button>
        </div>
    </div>
</template>
