<script setup>
import { ref, computed } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { syncConflicts, removeConflict, clearConflicts, SYNC_STATUS } from '@/core/states/syncState.js';
import { resolveConflict } from '@/core/services/syncEngine.js';
import { fullPush } from '@/core/services/syncService.js';
import { syncStatus } from '@/core/states/syncState.js';

const sheet = ref(null);
defineProps({ zIndex: { type: Number, default: 11050 } });

const t = (key) => translations[currentLang.value]?.[key] || key;

const expandedConflictId = ref(null);
const isResolving = ref(false);
const resolvedIds = ref(new Set());

const unresolvedConflicts = computed(() =>
    syncConflicts.value.filter(c => !resolvedIds.value.has(c.id))
);

const hasConflicts = computed(() => unresolvedConflicts.value.length > 0);

const typeIcon = (type) => {
    if (type === 'character') return '<svg viewBox="0 0 24 24"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>';
    if (type === 'persona') return '<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm0 14.2c-2.5 0-4.71-1.28-6-3.22.03-1.99 4-3.08 6-3.08 1.99 0 5.97 1.09 6 3.08-1.29 1.94-3.5 3.22-6 3.22z"/></svg>';
    return '<svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-1.99.9-1.99 2L2 22l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-2 12H6v-2h12v2zm0-3H6V9h12v2zm0-3H6V6h12v2z"/></svg>';
};

const typeLabel = (type) => {
    if (type === 'character') return t('sync_type_character') || 'Character';
    if (type === 'persona') return t('sync_type_persona') || 'Persona';
    if (type === 'chat') return t('sync_type_chat') || 'Chat';
    return type;
};

const formatTimestamp = (ts) => {
    if (!ts) return '—';
    const d = new Date(ts);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
};

const entityFields = (entity, type) => {
    if (!entity) return [];
    const fields = [];
    if (type === 'character') {
        if (entity.name) fields.push({ key: 'name', label: t('label_name') || 'Name', value: entity.name });
        if (entity.description) fields.push({ key: 'description', label: t('label_description') || 'Description', value: truncate(entity.description, 200) });
        if (entity.personality) fields.push({ key: 'personality', label: t('label_personality') || 'Personality', value: truncate(entity.personality, 200) });
        if (entity.scenario) fields.push({ key: 'scenario', label: t('label_scenario') || 'Scenario', value: truncate(entity.scenario, 200) });
    } else if (type === 'persona') {
        if (entity.name) fields.push({ key: 'name', label: t('label_name') || 'Name', value: entity.name });
        if (entity.prompt) fields.push({ key: 'prompt', label: t('label_description') || 'Description', value: truncate(entity.prompt, 200) });
    } else if (type === 'chat') {
        const msgCount = entity.messages?.length || 0;
        fields.push({ key: 'messages', label: t('sync_msg_count') || 'Messages', value: String(msgCount) });
        if (msgCount > 0) {
            const last = entity.messages[msgCount - 1];
            const preview = (last.mes || last.content || '').substring(0, 100);
            if (preview) fields.push({ key: 'last_msg', label: t('sync_last_message') || 'Last message', value: truncate(preview, 100) });
        }
    }
    fields.push({ key: 'updatedAt', label: t('sync_modified') || 'Modified', value: formatTimestamp(entity.updatedAt) });
    return fields;
};

function truncate(str, max) {
    if (!str) return '';
    return str.length > max ? str.substring(0, max) + '...' : str;
}

function toggleExpand(id) {
    expandedConflictId.value = expandedConflictId.value === id ? null : id;
}

async function resolve(conflict, choice) {
    isResolving.value = true;
    try {
        await resolveConflict(conflict, choice);
        resolvedIds.value = new Set([...resolvedIds.value, conflict.id]);
        if (unresolvedConflicts.value.length === 0) {
            removeConflict(conflict.id);
            await pushResolvedAndClose();
        } else {
            removeConflict(conflict.id);
            expandedConflictId.value = null;
        }
    } catch (e) {
        console.error('[ConflictSheet] Resolve failed:', e);
    } finally {
        isResolving.value = false;
    }
}

async function resolveAllLocal() {
    isResolving.value = true;
    try {
        for (const conflict of unresolvedConflicts.value) {
            await resolveConflict(conflict, 'local');
            resolvedIds.value = new Set([...resolvedIds.value, conflict.id]);
            removeConflict(conflict.id);
        }
        await pushResolvedAndClose();
    } catch (e) {
        console.error('[ConflictSheet] Resolve all failed:', e);
    } finally {
        isResolving.value = false;
    }
}

async function resolveAllCloud() {
    isResolving.value = true;
    try {
        for (const conflict of unresolvedConflicts.value) {
            await resolveConflict(conflict, 'cloud');
            resolvedIds.value = new Set([...resolvedIds.value, conflict.id]);
            removeConflict(conflict.id);
        }
        await pushResolvedAndClose();
    } catch (e) {
        console.error('[ConflictSheet] Resolve all failed:', e);
    } finally {
        isResolving.value = false;
    }
}

async function pushResolvedAndClose() {
    clearConflicts();
    syncStatus.value = SYNC_STATUS.IDLE;
    try {
        await fullPush();
    } catch (e) {
        console.warn('[ConflictSheet] Post-resolve push failed:', e);
    }
    close();
}

const open = () => {
    expandedConflictId.value = null;
    resolvedIds.value = new Set();
    sheet.value?.open();
};
const close = () => sheet.value?.close();

defineExpose({ open, close });
</script>

<template>
    <SheetView ref="sheet" :z-index="zIndex" :title="t('sync_conflicts_title') || 'Sync Conflicts'" :fit-content="false">
        <div class="cs-body">
            <div class="cs-header-info" v-if="hasConflicts">
                <div class="cs-count">{{ unresolvedConflicts.length }} {{ t('sync_conflicts_pending') || 'unresolved conflict(s)' }}</div>
                <div class="cs-hint">{{ t('sync_conflicts_hint') || 'Choose which version to keep for each item.' }}</div>
            </div>

            <div class="cs-empty" v-if="!hasConflicts">
                <svg viewBox="0 0 24 24" style="width:48px;height:48px;fill:currentColor;color:#4CAF50"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                <div>{{ t('sync_conflicts_resolved') || 'All conflicts resolved!' }}</div>
            </div>

            <div v-if="hasConflicts && unresolvedConflicts.length > 1" class="cs-bulk-actions">
                <button class="cs-bulk-btn cs-bulk-local" @click="resolveAllLocal" :disabled="isResolving">
                    <svg viewBox="0 0 24 24"><path d="M20 6h-4V4c0-1.11-.89-2-2-2h-4c-1.11 0-2 .89-2 2v2H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-6 0h-4V4h4v2z"/></svg>
                    <span>{{ t('sync_keep_all_local') || 'Keep All Local' }}</span>
                </button>
                <button class="cs-bulk-btn cs-bulk-cloud" @click="resolveAllCloud" :disabled="isResolving">
                    <svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z"/></svg>
                    <span>{{ t('sync_keep_all_cloud') || 'Keep All Cloud' }}</span>
                </button>
            </div>

            <div class="cs-list" v-if="hasConflicts">
                <div
                    v-for="conflict in unresolvedConflicts"
                    :key="conflict.id"
                    class="cs-item"
                    :class="{ expanded: expandedConflictId === conflict.id }"
                >
                    <div class="cs-item-header" @click="toggleExpand(conflict.id)">
                        <div class="cs-item-icon" v-html="typeIcon(conflict.type)"></div>
                        <div class="cs-item-info">
                            <div class="cs-item-name">{{ conflict.name }}</div>
                            <div class="cs-item-type">{{ typeLabel(conflict.type) }}</div>
                        </div>
                        <svg class="cs-chevron" viewBox="0 0 24 24" :class="{ rotated: expandedConflictId === conflict.id }"><path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6 1.41-1.41z"/></svg>
                    </div>

                    <div class="cs-item-detail" v-if="expandedConflictId === conflict.id">
                        <div class="cs-compare">
                            <div class="cs-side cs-local">
                                <div class="cs-side-label">
                                    <svg viewBox="0 0 24 24"><path d="M20 6h-4V4c0-1.11-.89-2-2-2h-4c-1.11 0-2 .89-2 2v2H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-6 0h-4V4h4v2z"/></svg>
                                    {{ t('sync_version_local') || 'Local' }}
                                </div>
                                <div class="cs-fields">
                                    <div v-for="field in entityFields(conflict.local, conflict.type)" :key="field.key" class="cs-field">
                                        <span class="cs-field-label">{{ field.label }}</span>
                                        <span class="cs-field-value">{{ field.value }}</span>
                                    </div>
                                </div>
                            </div>
                            <div class="cs-vs">VS</div>
                            <div class="cs-side cs-cloud">
                                <div class="cs-side-label">
                                    <svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z"/></svg>
                                    {{ t('sync_version_cloud') || 'Cloud' }}
                                </div>
                                <div class="cs-fields">
                                    <div v-for="field in entityFields(conflict.cloud, conflict.type)" :key="field.key" class="cs-field">
                                        <span class="cs-field-label">{{ field.label }}</span>
                                        <span class="cs-field-value">{{ field.value }}</span>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <div class="cs-actions">
                            <button class="cs-action-btn cs-keep-local" @click.stop="resolve(conflict, 'local')" :disabled="isResolving">
                                <svg viewBox="0 0 24 24"><path d="M20 6h-4V4c0-1.11-.89-2-2-2h-4c-1.11 0-2 .89-2 2v2H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-6 0h-4V4h4v2z"/></svg>
                                <span>{{ t('sync_keep_local') || 'Keep Local' }}</span>
                            </button>
                            <button class="cs-action-btn cs-keep-cloud" @click.stop="resolve(conflict, 'cloud')" :disabled="isResolving">
                                <svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z"/></svg>
                                <span>{{ t('sync_keep_cloud') || 'Keep Cloud' }}</span>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.cs-body {
    padding: 12px 16px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.cs-header-info {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.cs-count {
    font-size: 16px;
    font-weight: 700;
    color: var(--text-black);
}

.cs-hint {
    font-size: 13px;
    color: var(--text-gray, #8e8e93);
    line-height: 1.4;
}

.cs-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    padding: 40px 0;
    font-size: 16px;
    font-weight: 600;
    color: #4CAF50;
}

.cs-bulk-actions {
    display: flex;
    gap: 8px;
}

.cs-bulk-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 10px 12px;
    border-radius: 10px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    border: none;
    font-family: inherit;
    transition: all 0.2s;
}

.cs-bulk-btn:disabled {
    opacity: 0.5;
    cursor: default;
}

.cs-bulk-btn svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.cs-bulk-local {
    background: rgba(255, 149, 0, 0.1);
    color: #FF9500;
}

.cs-bulk-local:active:not(:disabled) {
    background: rgba(255, 149, 0, 0.2);
}

.cs-bulk-cloud {
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
}

.cs-bulk-cloud:active:not(:disabled) {
    background: rgba(var(--vk-blue-rgb), 0.2);
}

.cs-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.cs-item {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 14px;
    overflow: hidden;
    transition: border-color 0.2s;
}

.cs-item.expanded {
    border-color: rgba(var(--vk-blue-rgb), 0.3);
}

.cs-item-header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px;
    cursor: pointer;
}

.cs-item-icon {
    width: 36px;
    height: 36px;
    border-radius: 10px;
    background: rgba(var(--vk-blue-rgb), 0.1);
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
}

.cs-item-icon :deep(svg) {
    width: 20px;
    height: 20px;
    fill: var(--vk-blue);
}

.cs-item-info {
    flex: 1;
    min-width: 0;
}

.cs-item-name {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-black);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.cs-item-type {
    font-size: 12px;
    color: var(--text-gray, #8e8e93);
    text-transform: capitalize;
}

.cs-chevron {
    width: 20px;
    height: 20px;
    fill: var(--text-gray, #8e8e93);
    transition: transform 0.3s;
    flex-shrink: 0;
}

.cs-chevron.rotated {
    transform: rotate(180deg);
}

.cs-item-detail {
    padding: 0 12px 12px;
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.cs-compare {
    display: flex;
    gap: 6px;
    align-items: stretch;
}

.cs-side {
    flex: 1;
    background: rgba(255, 255, 255, 0.03);
    border-radius: 10px;
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
}

.cs-local {
    border: 1px solid rgba(255, 149, 0, 0.2);
}

.cs-cloud {
    border: 1px solid rgba(var(--vk-blue-rgb), 0.2);
}

.cs-vs {
    align-self: center;
    font-size: 11px;
    font-weight: 800;
    color: var(--text-gray, #8e8e93);
    flex-shrink: 0;
}

.cs-side-label {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.cs-local .cs-side-label {
    color: #FF9500;
}

.cs.cloud .cs-side-label {
    color: var(--vk-blue);
}

.cs-side-label svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.cs-fields {
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.cs-field {
    display: flex;
    flex-direction: column;
    gap: 1px;
}

.cs-field-label {
    font-size: 10px;
    font-weight: 600;
    color: var(--text-gray, #8e8e93);
    text-transform: uppercase;
    letter-spacing: 0.3px;
}

.cs-field-value {
    font-size: 12px;
    color: var(--text-black);
    line-height: 1.4;
    word-break: break-word;
    max-height: 60px;
    overflow: hidden;
}

.cs-actions {
    display: flex;
    gap: 8px;
}

.cs-action-btn {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 10px;
    border-radius: 10px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    border: none;
    font-family: inherit;
    transition: all 0.2s;
}

.cs-action-btn:disabled {
    opacity: 0.5;
    cursor: default;
}

.cs-action-btn svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
}

.cs-keep-local {
    background: rgba(255, 149, 0, 0.1);
    color: #FF9500;
}

.cs-keep-local:active:not(:disabled) {
    background: rgba(255, 149, 0, 0.2);
    transform: scale(0.98);
}

.cs-keep-cloud {
    background: var(--vk-blue);
    color: white;
    box-shadow: 0 2px 8px rgba(var(--vk-blue-rgb), 0.3);
}

.cs-keep-cloud:active:not(:disabled) {
    transform: scale(0.98);
    box-shadow: 0 1px 4px rgba(var(--vk-blue-rgb), 0.2);
}
</style>
