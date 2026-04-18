<script setup>
import { ref, computed, watch } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { showToast } from '@/core/states/toastState.js';

const props = defineProps({
  memoryBook: {
    type: Object,
    required: true
  },
  currentMessages: {
    type: Array,
    default: () => []
  },
  characterName: {
    type: String,
    default: ''
  },
  sessionId: {
    type: String,
    default: ''
  },
  memoryDraftState: {
    type: Object,
    default: () => ({ active: false, startedAt: 0, elapsedMs: 0, label: '' })
  },
  pendingMemoryMessageIds: {
    type: Set,
    default: () => new Set()
  }
});

const emit = defineEmits([
  'close',
  'back',
  'open-settings',
  'open-maintenance',
  'open-preview',
  'update-key-mode',
  'toggle-vector-search',
  'reindex-all',
  'scan-chat',
  'batch-generate',
  'approve-draft',
  'delete-draft',
  'delete-entry',
  'cancel-draft'
]);

const sheet = ref(null);
const t = (key) => translations[currentLang.value]?.[key] || key;

// Computed properties
const vectorEnabled = computed(() => {
  return props.memoryBook?.settings?.vectorSearchEnabled !== false;
});

const entries = computed(() => {
  return Array.isArray(props.memoryBook?.entries) ? props.memoryBook.entries : [];
});

const pendingDrafts = computed(() => {
  return Array.isArray(props.memoryBook?.pendingDrafts) ? props.memoryBook.pendingDrafts : [];
});

const stableConversationCount = computed(() => {
  return props.currentMessages.filter(m => 
    m && !m.isTyping && !m.isHidden && !m.isError && (m.role === 'user' || m.role === 'char')
  ).length;
});

const generationSettingsSummary = computed(() => {
  const interval = normalizeAutoCreateInterval(props.memoryBook);
  const delayed = props.memoryBook.settings?.useDelayedAutomation !== false ? 'delayed' : 'immediate';
  const target = props.memoryBook.settings?.injectionTarget === 'summary_macro' ? '{{summary}}' : 'summary block';
  const maxEntries = Math.max(1, Math.min(20, Number(props.memoryBook.settings?.maxInjectedEntries || 3)));
  return `${interval} msgs • ${delayed} • ${target} • ${maxEntries} in prompt`;
});

const statusSummary = computed(() => {
  return entries.value.reduce((acc, entry) => {
    const status = entry?.status === 'needs_rebuild' ? 'needs_rebuild' : 'active';
    acc[status] = (acc[status] || 0) + 1;
    return acc;
  }, { active: 0, needs_rebuild: 0 });
});

const staleCoverageCount = computed(() => {
  return props.currentMessages.filter(msg => msg?.memoryCoverage?.stale).length;
});

const keyMatchMode = computed(() => {
  const mode = props.memoryBook?.settings?.keyMatchMode || 'glaze';
  if (mode === 'glaze') return 'Glaze boundaries';
  if (mode === 'both') return 'Plain + Glaze';
  return 'Plain contains';
});

const uncoveredSegments = computed(() => {
  const coveredIds = new Set();
  for (const entry of entries.value) {
    if (Array.isArray(entry.messageIds)) entry.messageIds.forEach(id => coveredIds.add(id));
  }
  for (const draft of pendingDrafts.value) {
    if (Array.isArray(draft.messageIds)) draft.messageIds.forEach(id => coveredIds.add(id));
  }
  
  const stableMessages = props.currentMessages.filter(m => 
    m && !m.isTyping && !m.isHidden && !m.isError && (m.role === 'user' || m.role === 'char')
  );
  const uncovered = stableMessages.filter(m => m.id && !coveredIds.has(m.id));
  const interval = normalizeAutoCreateInterval(props.memoryBook);
  const segmentsNeeded = Math.ceil(uncovered.length / interval);
  
  return {
    count: uncovered.length,
    segmentsNeeded,
    interval
  };
});

const shouldEnableVectorSearch = computed(() => {
  // This should check embedding config - for now return true
  // Will be passed from parent
  return true;
});

// Helper functions
function normalizeAutoCreateInterval(memoryBook) {
  return Math.max(1, Math.min(100, Number(memoryBook?.settings?.autoCreateInterval || 12)));
}

function formatElapsedSeconds(ms) {
  const sec = Math.floor(ms / 1000);
  return `${sec}s`;
}

function normalizeEntryMessageIds(entry) {
  return Array.isArray(entry?.messageIds) ? entry.messageIds : [];
}

// Event handlers
function open() {
  sheet.value?.open();
}

function close() {
  // Don't call sheet.value?.close() here - it creates infinite recursion!
  // This function is called when SheetView emits 'close', so SheetView is already closing
  emit('close');
}

function handleBack() {
  emit('back');
}

function handleOpenSettings() {
  emit('open-settings');
  // Don't close, just go back to magic drawer
  handleBack();
}

function handleOpenMaintenance() {
  emit('open-maintenance');
  // Don't close, just go back to magic drawer
  handleBack();
}

function handleReindexAll() {
  emit('reindex-all');
}

function handleScanChat() {
  emit('scan-chat');
}

function handleBatchGenerate() {
  emit('batch-generate');
}

function handleCancelDraft() {
  emit('cancel-draft');
}

function handleKeyModeClick() {
  emit('update-key-mode');
  close();
}

function handleVectorToggle(event) {
  emit('toggle-vector-search', event.target.checked);
}

function handleEntryClick(entry) {
  emit('open-preview', { entry, kind: 'Memory Entry' });
  close();
}

function handleDraftClick(draft) {
  emit('open-preview', { entry: draft, kind: 'Memory Draft' });
  close();
}

function handleApproveDraft(draftId) {
  emit('approve-draft', draftId);
}

function handleDeleteDraft(draftId) {
  emit('delete-draft', draftId);
}

function handleDeleteEntry(entryId) {
  emit('delete-entry', entryId);
}

defineExpose({ open, close });
</script>

<template>
  <SheetView
    ref="sheet"
    title="Memory Books"
    :show-back="true"
    :fit-content="false"
    @close="close"
    @back="handleBack"
  >
    <div class="memory-books-content">
      <!-- Session Overview -->
      <div class="memory-session-overview">
        <div class="memory-session-overview-head">
          <div>
            <div class="memory-session-title">{{ characterName }}</div>
            <div class="memory-session-note">Session {{ sessionId }}</div>
          </div>
          <div class="memory-session-chip">{{ stableConversationCount }} stable msgs</div>
        </div>
        <div class="memory-session-overview-meta">{{ generationSettingsSummary }}</div>
      </div>

      <!-- Key Match Mode (only when vector search is disabled) -->
      <div v-if="!vectorEnabled" class="memory-settings-item">
        <label>Key Match Mode</label>
        <div class="memory-clickable-selector" @click="handleKeyModeClick">
          <span>{{ keyMatchMode }}</span>
          <svg viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
        </div>
        <div class="memory-note">Keyword retrieval uses only the entry Keys field.</div>
      </div>

      <!-- Vector Search Toggle -->
      <div class="memory-settings-item-checkbox">
        <div class="memory-settings-text-col">
          <label>Vector Search</label>
          <div class="memory-settings-desc">One shared retrieval mode for all memory entries in this session.</div>
        </div>
        <input
          type="checkbox"
          class="vk-switch"
          :checked="vectorEnabled"
          :disabled="!shouldEnableVectorSearch"
          @change="handleVectorToggle"
        />
      </div>
      <div v-if="!shouldEnableVectorSearch" class="memory-note">
        Embeddings are not configured, so vector search is unavailable.
      </div>

      <!-- Status Summary -->
      <div class="memory-status-summary">
        <div class="memory-status-summary-item ok">
          <strong>{{ statusSummary.active || 0 }}</strong>
          <span>active</span>
        </div>
        <div class="memory-status-summary-item warning">
          <strong>{{ statusSummary.needs_rebuild || 0 }}</strong>
          <span>needs rebuild</span>
        </div>
        <div class="memory-status-summary-item danger">
          <strong>{{ staleCoverageCount || 0 }}</strong>
          <span>stale messages</span>
        </div>
        <div class="memory-status-summary-item draft">
          <strong>{{ pendingDrafts.length || 0 }}</strong>
          <span>drafts</span>
        </div>
      </div>

      <!-- Action Buttons -->
      <div class="memory-actions">
        <button type="button" class="memory-btn memory-btn-secondary" @click="handleOpenSettings">
          Generation Settings
        </button>
        <button type="button" class="memory-btn memory-btn-secondary" @click="handleOpenMaintenance">
          Maintenance
        </button>
        <button
          type="button"
          class="memory-btn memory-btn-secondary"
          :disabled="!vectorEnabled"
          @click="handleReindexAll"
        >
          Reindex All
        </button>
        <button type="button" class="memory-btn memory-btn-primary" @click="close">
          Close
        </button>
      </div>

      <!-- Batch Actions (Scan & Generate) -->
      <div v-if="uncoveredSegments.count > 0" class="memory-batch-actions">
        <div class="memory-batch-info">
          <strong>{{ uncoveredSegments.count }}</strong> uncovered messages ({{ uncoveredSegments.segmentsNeeded }} segments of {{ uncoveredSegments.interval }})
        </div>
        <div class="memory-batch-buttons">
          <button type="button" class="memory-btn memory-btn-secondary" @click="handleScanChat">
            Scan Chat
          </button>
          <button
            type="button"
            class="memory-btn memory-btn-primary"
            :disabled="memoryDraftState.active"
            @click="handleBatchGenerate"
          >
            Generate Drafts
          </button>
        </div>
      </div>

      <!-- Draft Generation Progress -->
      <div v-if="memoryDraftState.active" class="memory-generation-status-card">
        <div class="memory-generation-status-row">
          <strong>{{ memoryDraftState.label || 'Generating memory draft' }}</strong>
          <span>{{ formatElapsedSeconds(memoryDraftState.elapsedMs) }}</span>
        </div>
        <div class="memory-generation-status-row" style="margin-top: 6px;">
          <div class="memory-note" style="margin: 0;">Timer updates automatically.</div>
          <button type="button" class="memory-btn memory-btn-destructive memory-btn-sm" @click="handleCancelDraft">
            Stop
          </button>
        </div>
      </div>

      <!-- Pending Drafts Section -->
      <div v-if="pendingDrafts.length > 0" class="memory-sheet-section">
        <div class="memory-sheet-section-head">
          <label>Pending Drafts</label>
          <span>{{ pendingDrafts.length }}</span>
        </div>
        <div class="memory-entry-list">
          <div
            v-for="draft in pendingDrafts"
            :key="draft.id"
            class="memory-entry-card"
            @click="handleDraftClick(draft)"
          >
            <div class="memory-entry-head">
              <div>
                <div class="memory-entry-title">{{ draft.title || 'Untitled draft' }}</div>
                <div class="memory-entry-meta">
                  {{ draft.content && !memoryDraftState.active ? 'pending approval' : 'generating' }}
                  {{ vectorEnabled ? ' • hybrid' : ' • keys' }}
                  <template v-if="draft.keys && draft.keys.length">
                    • {{ draft.keys.slice(0, 3).join(', ') }}
                  </template>
                </div>
              </div>
              <div class="memory-draft-actions" @click.stop>
                <span class="memory-status-badge draft">draft</span>
                <span v-if="vectorEnabled" class="memory-status-badge vector">vec</span>
                <button
                  type="button"
                  class="memory-entry-approve"
                  :disabled="!draft.content || memoryDraftState.active"
                  @click="handleApproveDraft(draft.id)"
                >
                  Approve
                </button>
                <button
                  type="button"
                  class="memory-entry-delete"
                  @click="handleDeleteDraft(draft.id)"
                >
                  Delete
                </button>
              </div>
            </div>
            <div class="memory-entry-preview">
              <template v-if="draft.content">
                {{ draft.content.slice(0, 180) }}
              </template>
              <span v-else-if="memoryDraftState.active" style="color:#ffd700;">⏳ Generating...</span>
              <span v-else style="color:var(--text-gray);">No content yet</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Approved Memories Section -->
      <div class="memory-sheet-section">
        <div class="memory-sheet-section-head">
          <label>Approved Memories</label>
          <span>{{ entries.length }}</span>
        </div>
        <div v-if="entries.length > 0" class="memory-entry-list">
          <div
            v-for="entry in entries"
            :key="entry.id"
            class="memory-entry-card"
            :class="{ 'is-warning': entry.status === 'needs_rebuild' }"
            @click="handleEntryClick(entry)"
          >
            <div class="memory-entry-head">
              <div>
                <div class="memory-entry-title">{{ entry.title || 'Untitled memory' }}</div>
                <div class="memory-entry-meta">
                  {{ entry.status || 'active' }} • {{ normalizeEntryMessageIds(entry).length }} messages
                  {{ vectorEnabled ? ' • hybrid' : ' • keys' }}
                  <template v-if="entry.keys && entry.keys.length">
                    • {{ entry.keys.slice(0, 3).join(', ') }}
                  </template>
                </div>
              </div>
              <div class="memory-status-badges">
                <span
                  class="memory-status-badge"
                  :class="entry.status === 'needs_rebuild' ? 'warning' : 'ok'"
                >
                  {{ entry.status === 'needs_rebuild' ? 'needs rebuild' : 'active' }}
                </span>
                <span v-if="vectorEnabled" class="memory-status-badge vector">vec</span>
                <span v-if="entry.id" class="memory-status-badge indexed">idx</span>
              </div>
            </div>
            <div class="memory-entry-preview">
              {{ entry.content ? entry.content.slice(0, 180) : 'No content yet' }}
            </div>
          </div>
        </div>
        <div v-else class="memory-note">
          No memory entries in this session yet.
        </div>
      </div>
    </div>
  </SheetView>
</template>

<style scoped>
.memory-books-content {
  display: flex;
  flex-direction: column;
  padding: 20px;
  gap: 16px;
}

/* Session Overview */
.memory-session-overview {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
}

.memory-session-overview-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}

.memory-session-title {
  font-size: 16px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-session-note {
  font-size: 12px;
  color: var(--text-gray);
  margin-top: 2px;
}

.memory-session-chip {
  padding: 4px 10px;
  background: rgba(var(--vk-blue-rgb), 0.1);
  color: var(--vk-blue);
  border-radius: 12px;
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
}

.memory-session-overview-meta {
  font-size: 12px;
  color: var(--text-gray);
}

/* Settings Items */
.memory-settings-item {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.memory-settings-item label {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-black);
}

.memory-clickable-selector {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.2s;
}

.memory-clickable-selector:active {
  opacity: 0.7;
}

.memory-clickable-selector svg {
  width: 20px;
  height: 20px;
  fill: var(--text-gray);
}

.memory-settings-item-checkbox {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
}

.memory-settings-text-col {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.memory-settings-text-col label {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-black);
}

.memory-settings-desc {
  font-size: 12px;
  color: var(--text-gray);
}

.memory-note {
  font-size: 12px;
  color: var(--text-gray);
  padding: 8px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 8px;
}

/* Status Summary */
.memory-status-summary {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
}

.memory-status-summary-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  padding: 12px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
  border: 1px solid transparent;
}

.memory-status-summary-item.ok {
  border-color: rgba(76, 175, 80, 0.3);
}

.memory-status-summary-item.warning {
  border-color: rgba(255, 184, 77, 0.3);
}

.memory-status-summary-item.danger {
  border-color: rgba(255, 107, 107, 0.3);
}

.memory-status-summary-item.draft {
  border-color: rgba(255, 215, 0, 0.3);
}

.memory-status-summary-item strong {
  font-size: 20px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-status-summary-item span {
  font-size: 11px;
  color: var(--text-gray);
  text-align: center;
}

/* Action Buttons */
.memory-actions {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
}

.memory-btn {
  padding: 12px 16px;
  border: none;
  border-radius: 12px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  font-family: inherit;
}

.memory-btn-primary {
  background: var(--accent-color, var(--vk-blue));
  color: white;
}

.memory-btn-primary:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.memory-btn-secondary {
  background: rgba(var(--ui-bg-rgb), 0.5);
  color: var(--text-black);
  border: 1px solid rgba(255, 255, 255, 0.1);
}

.memory-btn-secondary:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.memory-btn-destructive {
  background: rgba(255, 68, 68, 0.1);
  color: #ff4444;
  border: 1px solid rgba(255, 68, 68, 0.3);
}

.memory-btn-sm {
  padding: 4px 12px;
  font-size: 12px;
}

.memory-btn:active:not(:disabled) {
  opacity: 0.7;
}

/* Batch Actions */
.memory-batch-actions {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 12px;
  border: 1px solid rgba(var(--vk-blue-rgb), 0.2);
}

.memory-batch-info {
  font-size: 14px;
  color: var(--text-gray);
}

.memory-batch-info strong {
  color: var(--text-black);
  font-weight: 700;
}

.memory-batch-buttons {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 12px;
}

/* Generation Status */
.memory-generation-status-card {
  padding: 16px;
  background: rgba(255, 215, 0, 0.1);
  border: 1px solid rgba(255, 215, 0, 0.3);
  border-radius: 12px;
}

.memory-generation-status-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.memory-generation-status-row strong {
  font-size: 14px;
  color: var(--text-black);
}

.memory-generation-status-row span {
  font-size: 12px;
  color: var(--text-gray);
  font-weight: 600;
}

/* Sections */
.memory-sheet-section {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.memory-sheet-section-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.memory-sheet-section-head label {
  font-size: 16px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-sheet-section-head span {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-gray);
  padding: 4px 10px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
}

/* Entry List */
.memory-entry-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.memory-entry-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.2s;
}

.memory-entry-card:active {
  opacity: 0.7;
}

.memory-entry-card.is-warning {
  border-color: rgba(255, 184, 77, 0.3);
  background: rgba(255, 184, 77, 0.05);
}

.memory-entry-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
}

.memory-entry-title {
  font-size: 14px;
  font-weight: 700;
  color: var(--text-black);
}

.memory-entry-meta {
  font-size: 12px;
  color: var(--text-gray);
  margin-top: 2px;
}

.memory-entry-preview {
  font-size: 13px;
  color: var(--text-gray);
  line-height: 1.4;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Status Badges */
.memory-status-badges {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.memory-status-badge {
  padding: 4px 8px;
  border-radius: 8px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  white-space: nowrap;
}

.memory-status-badge.ok {
  background: rgba(76, 175, 80, 0.1);
  color: #4caf50;
}

.memory-status-badge.warning {
  background: rgba(255, 184, 77, 0.1);
  color: #ffb84d;
}

.memory-status-badge.draft {
  background: rgba(255, 215, 0, 0.1);
  color: #ffd700;
}

.memory-status-badge.vector {
  background: rgba(139, 92, 246, 0.1);
  color: #8b5cf6;
}

.memory-status-badge.indexed {
  background: rgba(59, 130, 246, 0.1);
  color: #3b82f6;
}

/* Draft Actions */
.memory-draft-actions {
  display: flex;
  gap: 8px;
  align-items: center;
}

.memory-entry-approve,
.memory-entry-delete {
  padding: 6px 12px;
  border: none;
  border-radius: 8px;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  font-family: inherit;
}

.memory-entry-approve {
  background: rgba(76, 175, 80, 0.1);
  color: #4caf50;
}

.memory-entry-approve:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.memory-entry-delete {
  background: rgba(255, 68, 68, 0.1);
  color: #ff4444;
}

.memory-entry-approve:active:not(:disabled),
.memory-entry-delete:active {
  opacity: 0.7;
}

@media (max-width: 600px) {
  .memory-status-summary {
    grid-template-columns: repeat(2, 1fr);
  }
  
  .memory-actions {
    grid-template-columns: 1fr;
  }
}
</style>
