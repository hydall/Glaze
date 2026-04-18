<!-- src/components/sheets/TokenizerSheet.vue -->
<script setup>
import { ref, computed } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';

const props = defineProps({
    contextBreakdown: { type: Object, default: null },
    contextSegments: { type: Object, default: () => ({ used: [], reserve: null }) },
    contextBreakdownItems: { type: Array, default: () => [] },
    contextLegendItems: { type: Array, default: () => [] },
    historyUsagePercent: { type: Number, default: 0 },
    historyHidePreview: { type: Object, default: () => ({ count: 0, tokens: 0 }) },
    shouldRecommendHide: { type: Boolean, default: false },
    historyFillThreshold: { type: Number, default: 85 },
    historyHidePercent: { type: Number, default: 30 },
});

const emit = defineEmits(['hide-messages', 'save-settings']);

const sheet = ref(null);
const showSettings = ref(false);
const localFillThreshold = ref(85);
const localHidePercent = ref(30);

const usedWidth = computed(() => Math.max(0, 100 - (props.contextSegments.reserve?.percent || 0)));
const hideButtonLabel = computed(() =>
    props.historyHidePreview.count ? `Hide top ${props.historyHidePreview.count}` : 'Hide top messages'
);
const sheetTitle = computed(() => showSettings.value ? 'Context Settings' : 'Context');

function open() {
    showSettings.value = false;
    sheet.value?.open();
}

function close() {
    sheet.value?.close();
}

function openSettings() {
    localFillThreshold.value = props.historyFillThreshold;
    localHidePercent.value = props.historyHidePercent;
    showSettings.value = true;
}

function saveSettings() {
    emit('save-settings', { fillThreshold: localFillThreshold.value, hidePercent: localHidePercent.value });
    showSettings.value = false;
}

defineExpose({ open, close });
</script>

<template>
    <SheetView ref="sheet" :title="sheetTitle" :show-back="showSettings" @back="showSettings = false">
        <div class="ctx-body">
            <!-- Main view -->
            <template v-if="!showSettings">
                <div class="ctx-summary">
                    <div class="ctx-kpi">
                        <strong>{{ contextBreakdown?.totalUsed || 0 }}</strong>
                        <span>used / {{ contextBreakdown?.contextSize || contextBreakdown?.safeContext || 0 }}</span>
                    </div>
                    <div class="ctx-kpi">
                        <strong>{{ Math.max(0, contextBreakdown?.remaining || 0) }}</strong>
                        <span>remaining</span>
                    </div>
                    <div class="ctx-kpi">
                        <strong>{{ historyUsagePercent }}%</strong>
                        <span>history fill</span>
                    </div>
                </div>

                <div class="ctx-bar">
                    <div class="ctx-bar-used" :style="{ width: usedWidth + '%' }">
                        <div v-for="segment in contextSegments.used" :key="segment.className"
                             class="ctx-segment" :class="segment.className"
                             :style="{ width: segment.percent + '%' }"></div>
                    </div>
                    <div v-if="contextSegments.reserve" class="ctx-reserve-container"
                         :style="{ width: contextSegments.reserve.percent + '%' }">
                        <div v-for="seg in (contextSegments.reserve.used || [])" :key="seg.className"
                             class="ctx-segment" :class="seg.className"
                             :style="{ width: ((seg.value / contextSegments.reserve.value) * 100).toFixed(2) + '%' }"></div>
                        <div v-if="contextSegments.reserve.remaining > 0"
                             class="ctx-segment" :class="contextSegments.reserve.className"
                             :style="{ width: ((contextSegments.reserve.remaining / contextSegments.reserve.value) * 100).toFixed(2) + '%' }"></div>
                    </div>
                </div>

                <div class="ctx-legend">
                    <div v-for="seg in contextLegendItems" :key="seg.key" class="ctx-legend-item">
                        <span class="ctx-legend-swatch" :class="seg.className"></span>
                        <span>{{ seg.label }}</span>
                    </div>
                </div>

                <div class="ctx-breakdown">
                    <div v-for="item in contextBreakdownItems" :key="item.key" class="ctx-breakdown-row">
                        <span>{{ item.label }}</span>
                        <strong>{{ item.value }}</strong>
                    </div>
                </div>

                <div v-if="shouldRecommendHide" class="ctx-recommendation">
                    <div class="ctx-rec-title">History is near its limit</div>
                    <div class="ctx-note">Hide about {{ historyHidePreview.count }} top message{{ historyHidePreview.count === 1 ? '' : 's' }} to free about {{ historyHidePreview.tokens }} tokens.</div>
                </div>

                <div class="ctx-actions">
                    <button type="button" class="ctx-btn ctx-btn-primary" @click="$emit('hide-messages')">{{ hideButtonLabel }}</button>
                    <button type="button" class="ctx-btn ctx-btn-secondary" @click="openSettings">Settings</button>
                </div>
            </template>

            <!-- Settings sub-view -->
            <template v-else>
                <div class="ctx-settings-item">
                    <label>History fill threshold (%)</label>
                    <input type="number" min="1" max="100" v-model.number="localFillThreshold">
                </div>
                <div class="ctx-settings-item">
                    <label>Hide top messages (%)</label>
                    <input type="number" min="1" max="95" v-model.number="localHidePercent">
                </div>
                <p class="ctx-note">Hide top messages recommendation appears when visible history reaches the configured threshold.</p>
                <div class="ctx-actions">
                    <button type="button" class="ctx-btn ctx-btn-secondary" @click="showSettings = false">Back</button>
                    <button type="button" class="ctx-btn ctx-btn-primary" @click="saveSettings">Save</button>
                </div>
            </template>
        </div>
    </SheetView>
</template>

<style scoped>
.ctx-body {
    padding: 0 16px 16px;
}

.ctx-summary {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 10px;
    margin-bottom: 14px;
}

.ctx-kpi {
    padding: 12px;
    border-radius: 14px;
    background: rgba(255, 255, 255, 0.08);
    backdrop-filter: blur(var(--element-blur, 20px));
    text-align: center;
    color: var(--text-black);
    border: 1px solid rgba(255, 255, 255, 0.08);
}

.ctx-kpi strong {
    display: block;
    font-size: 18px;
    line-height: 1.2;
    color: var(--text-black);
}

.ctx-kpi span {
    display: block;
    margin-top: 4px;
    font-size: 12px;
    color: var(--text-gray);
}

.ctx-bar {
    position: relative;
    display: flex;
    width: 100%;
    height: 10px;
    overflow: hidden;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.06);
    margin-bottom: 14px;
}

.ctx-bar-used {
    display: flex;
    height: 100%;
    min-width: 0;
    flex: 0 0 auto;
}

.ctx-reserve-container {
    position: absolute;
    top: 0;
    right: 0;
    height: 100%;
    display: flex;
    box-shadow: inset 2px 0 0 rgba(0, 0, 0, 0.35);
}

.ctx-segment {
    height: 100%;
}

.segment-fixed { background: #8f8f95; }
.segment-character { background: #4f8cff; }
.segment-history { background: #d8b84a; }
.segment-summary { background: #1ec8ff; }
.segment-memory { background: #7ee787; }
.segment-authors-note { background: #7a6cff; }
.segment-lorebook { background: #ff8c42; }
.segment-vector-lore { background: #b06cf7; }
.segment-lorebook-reserve { background: #43b56f; }

.ctx-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 8px 12px;
    margin-bottom: 14px;
}

.ctx-legend-item {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: var(--text-gray);
}

.ctx-legend-swatch {
    width: 10px;
    height: 10px;
    border-radius: 999px;
    flex-shrink: 0;
}

.ctx-breakdown {
    display: grid;
    gap: 8px;
}

.ctx-breakdown-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border-radius: 12px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.06);
}

.ctx-breakdown-row span {
    color: var(--text-gray);
}

.ctx-breakdown-row strong {
    font-weight: 600;
    color: var(--text-black);
}

.ctx-recommendation {
    margin-top: 14px;
    padding: 12px;
    border-radius: 14px;
    background: rgba(216, 184, 74, 0.14);
    border: 1px solid rgba(216, 184, 74, 0.35);
}

.ctx-rec-title {
    font-weight: 600;
    margin-bottom: 4px;
}

.ctx-note {
    font-size: 13px;
    color: var(--text-gray);
    line-height: 1.45;
    margin: 0;
}

.ctx-actions {
    display: flex;
    gap: 10px;
    margin-top: 16px;
}

.ctx-btn {
    flex: 1;
    min-height: 42px;
    border: none;
    border-radius: 12px;
    padding: 0 14px;
    font-size: 14px;
    font-weight: 600;
    font-family: inherit;
    cursor: pointer;
}

.ctx-btn-primary {
    color: #fff;
    background: var(--vk-blue);
}

.ctx-btn-secondary {
    color: var(--text-black);
    background: rgba(255, 255, 255, 0.08);
}

.ctx-settings-item {
    display: flex;
    flex-direction: column;
    gap: 6px;
    margin-bottom: 14px;
}

.ctx-settings-item label {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-black);
}

.ctx-settings-item input {
    padding: 10px 12px;
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-black);
    font-size: 14px;
    font-family: inherit;
    outline: none;
}

@media (max-width: 480px) {
    .ctx-summary {
        grid-template-columns: 1fr;
    }
}
</style>
