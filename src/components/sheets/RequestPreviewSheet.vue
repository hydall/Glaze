<script setup>
import { ref } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { getLastPrompt } from '@/core/services/generationService.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import HelpTip from '@/components/ui/HelpTip.vue';

const t = (key) => translations[currentLang.value]?.[key] || key;

const sheet = ref(null);
const previewData = ref(null);
const previewTab = ref('formatted');
const expandedMessages = ref(new Set());

const open = () => {
    const prompt = getLastPrompt();
    previewData.value = prompt;
    expandedMessages.value.clear();
    if (sheet.value) sheet.value.open();
};

const toggleMessage = (index) => {
    if (expandedMessages.value.has(index)) {
        expandedMessages.value.delete(index);
    } else {
        expandedMessages.value.add(index);
    }
};

const getParams = (data) => {
    if (!data) return {};
    const { messages, ...rest } = data;
    return rest;
};

const formatParamValue = (val) => {
    if (val === null || val === undefined) return '';
    if (typeof val === 'object') return JSON.stringify(val);
    return val;
};

const getMessageContent = (msg) => {
    if (typeof msg.content === 'string') return msg.content;
    return JSON.stringify(msg.content, null, 2);
};

const getRawJson = () => {
    if (!previewData.value) return '';
    const clean = JSON.parse(JSON.stringify(previewData.value));
    if (clean.messages) {
        clean.messages = clean.messages.map(({ blockName, chatId, ...rest }) => rest);
    }
    return JSON.stringify(clean, null, 2);
};

defineExpose({ open });
</script>

<template>
    <SheetView ref="sheet" :title="t('magic_request_preview')">
        <template #header-title>
            <HelpTip term="request-preview" />
        </template>
        <template #header-bottom>
            <div class="gen-sheet-tabs">
                <div class="segmented-control">
                    <div class="sub-tab-btn" :class="{ active: previewTab === 'formatted' }" @click="previewTab = 'formatted'">{{ t('label_formatted') || 'Formatted' }}</div>
                    <div class="sub-tab-btn" :class="{ active: previewTab === 'raw' }" @click="previewTab = 'raw'">{{ t('label_raw_json') || 'Raw JSON' }}</div>
                    <div class="tab-glider" :style="{ width: 'calc((100% - 8px) / 2)', transform: `translateX(${previewTab === 'formatted' ? '0%' : '100%'})` }"></div>
                </div>
            </div>
        </template>
        <div class="preview-container" v-if="previewData">
            <div v-if="previewTab === 'formatted'">
                <div class="preview-section-title">{{ t('section_gen_params') || 'Parameters' }}</div>
                <div class="params-grid">
                    <div v-for="(value, key) in getParams(previewData)" :key="key" class="param-item">
                        <div class="param-label">{{ key }}</div>
                        <div class="param-value">{{ formatParamValue(value) }}</div>
                    </div>
                </div>
                <div class="preview-section-title">{{ t('stat_messages') }} ({{ previewData.messages ? previewData.messages.length : 0 }})</div>
                <div class="messages-list">
                    <div v-for="(msg, index) in previewData.messages" :key="index" class="message-card">
                        <div class="message-header" @click="toggleMessage(index)">
                            <div class="message-header-content">
                                <div class="message-meta-row">
                                    <div class="message-role" :class="msg.role">{{ msg.role }}</div>
                                    <div class="message-block-name" v-if="msg.blockName">{{ msg.blockName }}</div>
                                </div>
                                <div class="message-preview-text" v-if="!expandedMessages.has(index)">
                                    {{ typeof msg.content === 'string' ? (msg.content.slice(0, 60) + (msg.content.length > 60 ? '...' : '')) : '[Complex Content]' }}
                                </div>
                            </div>
                            <div class="message-toggle-icon" :class="{ rotated: expandedMessages.has(index) }">
                                <svg viewBox="0 0 24 24"><path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6 1.41-1.41z"/></svg>
                            </div>
                        </div>
                        <div class="message-body" v-if="expandedMessages.has(index)">
                            <pre>{{ getMessageContent(msg) }}</pre>
                        </div>
                    </div>
                </div>
            </div>
            <div v-else class="raw-block">
                <pre>{{ getRawJson() }}</pre>
            </div>
        </div>
        <div class="empty-state" v-else>
            <svg class="empty-state-icon" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
            <div class="empty-state-text">{{ t('no_preview_available') || 'No preview available' }}</div>
        </div>
    </SheetView>
</template>

<style scoped>
.sheet-title {
    font-size: 18px;
    font-weight: 600;
    text-align: left;
    padding: 10px 16px;
    color: var(--text-black);
}

.gen-sheet-tabs {
    padding: 10px 16px;
    flex-shrink: 0;
}

.segmented-control {
    display: flex;
    background-color: rgba(255,255,255,0.1);
    border-radius: 10px;
    padding: 4px;
    position: relative;
    isolation: isolate;
}

.sub-tab-btn {
    flex: 1;
    text-align: center;
    padding: 6px 12px;
    border-radius: 8px;
    font-size: 13px;
    font-weight: 500;
    color: var(--text-gray);
    cursor: pointer;
    transition: color 0.2s ease;
    position: relative;
    z-index: 2;
}

.sub-tab-btn.active {
    background-color: transparent;
    color: var(--text-black);
    box-shadow: none;
}

.tab-glider {
    position: absolute;
    top: 4px;
    bottom: 4px;
    left: 4px;
    background-color: var(--vk-blue);
    border-radius: 8px;
    z-index: 1;
    transition: transform 0.25s cubic-bezier(0.2, 0, 0.2, 1);
    box-shadow: 0 2px 5px rgba(0,0,0,0.1);
}

.preview-container {
    padding: 16px;
    overflow-x: auto;
    font-family: monospace;
    font-size: 12px;
    color: var(--text-black);
    padding-bottom: 40px;
}

.preview-section-title {
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
    color: var(--text-gray);
    margin-bottom: 10px;
    margin-top: 20px;
}
.preview-section-title:first-child {
    margin-top: 0;
}

.params-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 8px;
}

.param-item {
    background-color: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 12px;
    padding: 10px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.param-label {
    font-size: 11px;
    color: var(--text-gray);
    margin-bottom: 4px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.param-value {
    font-size: 14px;
    font-weight: 500;
    word-break: break-word;
}

.messages-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.message-card {
    background-color: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 12px;
    overflow: hidden;
}

.message-header {
    padding: 10px 12px;
    display: flex;
    align-items: center;
    gap: 10px;
    cursor: pointer;
    background-color: rgba(255,255,255,0.02);
    user-select: none;
}

.message-header-content {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1;
    min-width: 0;
}

.message-meta-row {
    display: flex;
    align-items: center;
    gap: 8px;
}

.message-role {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    padding: 2px 6px;
    border-radius: 4px;
    background-color: #424242;
    color: #e0e0e0;
    flex-shrink: 0;
    align-self: flex-start;
}

.message-role.system { background-color: #1565c0; color: #e3f2fd; }
.message-role.user { background-color: #7b1fa2; color: #f3e5f5; }
.message-role.assistant { background-color: #2e7d32; color: #e8f5e9; }

.message-block-name {
    font-size: 11px;
    color: var(--text-gray);
    font-weight: 500;
    white-space: nowrap;
}

.message-preview-text {
    font-size: 13px;
    color: var(--text-gray);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.message-toggle-icon {
    width: 20px;
    height: 20px;
    fill: var(--text-gray);
    transition: transform 0.2s;
    flex-shrink: 0;
}

.message-toggle-icon.rotated {
    transform: rotate(180deg);
}

.message-body {
    padding: 12px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    background-color: rgba(0, 0, 0, 0.2);
}

.message-body pre {
    margin: 0;
    white-space: pre-wrap;
    word-break: break-word;
    font-family: monospace;
    font-size: 12px;
    color: var(--text-black);
}

.raw-block pre {
    white-space: pre-wrap;
    word-break: break-all;
}
</style>