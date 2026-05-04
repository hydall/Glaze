<script setup>
import { closeBottomSheet } from '@/core/states/bottomSheetState.js';

const props = defineProps({
    matchedEntries: { type: Array, required: true },
    coverage: { type: Object, required: true },
    onEntryClick: { type: Function, required: true }
});

function pluralize(count, singular, plural) {
    return count === 1 ? singular : plural;
}
</script>

<template>
    <div class="context-sheet">
        <div class="settings-item">
            <label>Message Memory Coverage</label>
            <div class="context-sheet-note">This message is linked to {{ matchedEntries.length }} memory {{ pluralize(matchedEntries.length, 'entry', 'entries') }}.</div>
            <div v-if="coverage.needsRebuild" class="context-sheet-note" style="color: var(--warning-color, #ffb84d);">Coverage needs rebuild.</div>
            <div v-if="coverage.stale" class="context-sheet-note" style="color: var(--danger-color, #ff6b6b);">Coverage is marked stale.</div>
        </div>
        <div class="memory-entry-list">
            <button
                v-for="entry in matchedEntries"
                :key="entry.id"
                type="button"
                class="memory-entry-card"
                @click="onEntryClick(entry)"
            >
                <div class="memory-entry-title-row">
                    <strong>{{ entry.title || 'Memory Entry' }}</strong>
                    <span class="context-sheet-note">{{ entry.status || 'active' }}</span>
                </div>
                <div class="context-sheet-note">{{ (entry.messageIds || []).length }} linked {{ pluralize((entry.messageIds || []).length, 'message', 'messages') }}</div>
            </button>
        </div>
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" @click="closeBottomSheet()">Close</button>
        </div>
    </div>
</template>
