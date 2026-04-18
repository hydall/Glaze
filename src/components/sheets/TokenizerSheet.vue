<script setup>
import { ref, computed } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const props = defineProps({
  breakdown: { type: Object, default: null },
  historyHidePreview: { type: Object, default: () => ({ count: 0, tokens: 0 }) },
  contextSegments: { type: Object, default: () => ({ used: [], reserve: null }) },
  contextLegendItems: { type: Array, default: () => [] },
  contextBreakdownItems: { type: Array, default: () => [] },
  shouldRecommendHide: { type: Boolean, default: false },
  historyUsagePercent: { type: Number, default: 0 },
  historyFillThreshold: { type: Number, default: 85 },
  historyHidePercent: { type: Number, default: 30 },
  isCalculating: { type: Boolean, default: false }
});

const emit = defineEmits(['close', 'back', 'hide-messages', 'save-settings']);
const t = (key) => translations[currentLang.value]?.[key] || key;

const sheet = ref(null);
const showSettings = ref(false);
const localFillThreshold = ref(85);
const localHidePercent = ref(30);

const used = computed(() => props.breakdown?.totalUsed || 0);
const safeContext = computed(() => props.breakdown?.safeContext || 0);
const remaining = computed(() => Math.max(0, props.breakdown?.remaining || 0));
const contextSize = computed(() => props.breakdown?.contextSize || safeContext.value);

const usedWidth = computed(() => Math.max(0, 100 - (props.contextSegments.reserve?.percent || 0)));

const hideButtonLabel = computed(() => {
  const count = props.historyHidePreview.count;
  return count ? `Hide top ${count}` : 'Hide top messages';
});

const sheetTitle = computed(() => showSettings.value ? 'Context Settings' : 'Context');

const reserveSegments = computed(() => {
  if (!props.contextSegments.reserve) return null;
  const reserve = props.contextSegments.reserve;
  const innerSegments = reserve.used?.map(seg => ({
    className: seg.className,
    widthPercent: (seg.value / reserve.value * 100).toFixed(2)
  })) || [];
  const remainingPercent = reserve.remaining > 0 
    ? ((reserve.remaining / reserve.value) * 100).toFixed(2) 
    : 0;
  return {
    widthPercent: reserve.percent,
    innerSegments,
    remainingPercent,
    remainingClassName: reserve.className,
    hasRemaining: reserve.remaining > 0
  };
});

function open() {
    showSettings.value = false;
    sheet.value?.open();
}

function onSheetClose() {
    emit('close');
}

function handleBack() {
    emit('back');
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
  <SheetView
    ref="sheet"
    :title="sheetTitle"
    :show-back="showSettings"
    :fit-content="false"
    @close="onSheetClose"
    @back="showSettings ? (showSettings = false) : handleBack()"
  >
    <!-- Loading/Error State -->
    <div v-if="isCalculating || !breakdown" class="tokenizer-loading">
      <div class="tokenizer-loading-icon">
        <svg viewBox="0 0 24 24"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>
      </div>
      <p class="tokenizer-loading-text">
        Context calculation is taking longer than expected. Please check that your API settings are configured correctly and try again.
      </p>
    </div>

    <!-- Main Content -->
    <div v-else class="tokenizer-content">
      <template v-if="!showSettings">
        <!-- Summary KPIs -->
        <div class="tokenizer-summary">
          <div class="tokenizer-kpi">
            <strong>{{ used }}</strong>
            <span>used / {{ contextSize }}</span>
          </div>
          <div class="tokenizer-kpi">
            <strong>{{ remaining }}</strong>
            <span>remaining</span>
          </div>
          <div class="tokenizer-kpi">
            <strong>{{ historyUsagePercent }}%</strong>
            <span>history fill</span>
          </div>
        </div>

        <!-- Context Bar -->
        <div class="tokenizer-bar-container">
          <div class="tokenizer-bar">
            <!-- Used segments -->
            <div class="tokenizer-bar-used" :style="{ width: `${usedWidth}%` }">
              <div
                v-for="(segment, idx) in contextSegments.used"
                :key="idx"
                class="tokenizer-segment"
                :class="segment.className"
                :style="{ width: `${segment.percent}%` }"
              />
            </div>

            <!-- Reserve container with nested segments -->
            <div
              v-if="reserveSegments"
              class="tokenizer-reserve-container"
              :style="{ width: `${reserveSegments.widthPercent}%` }"
            >
              <div
                v-for="(seg, idx) in reserveSegments.innerSegments"
                :key="idx"
                class="tokenizer-segment"
                :class="seg.className"
                :style="{ width: `${seg.widthPercent}%` }"
              />
              <div
                v-if="reserveSegments.hasRemaining"
                class="tokenizer-segment"
                :class="reserveSegments.remainingClassName"
                :style="{ width: `${reserveSegments.remainingPercent}%` }"
              />
            </div>
          </div>
        </div>

        <!-- Legend -->
        <div class="tokenizer-legend">
          <div
            v-for="(item, idx) in contextLegendItems"
            :key="idx"
            class="tokenizer-legend-item"
          >
            <span class="tokenizer-legend-swatch" :class="item.className" />
            <span>{{ item.label }}</span>
          </div>
        </div>

        <!-- Breakdown -->
        <div class="tokenizer-breakdown">
          <div
            v-for="(item, idx) in contextBreakdownItems"
            :key="idx"
            class="tokenizer-breakdown-row"
          >
            <span>{{ item.label }}</span>
            <strong>{{ item.value }}</strong>
          </div>
        </div>

        <!-- Recommendation -->
        <div v-if="shouldRecommendHide" class="tokenizer-recommendation">
          <div class="tokenizer-recommendation-title">History is near its limit</div>
          <div class="tokenizer-recommendation-text">
            Hide about {{ historyHidePreview.count }} top message{{ historyHidePreview.count === 1 ? '' : 's' }} to free about {{ historyHidePreview.tokens }} tokens.
          </div>
        </div>

        <!-- Actions -->
        <div class="tokenizer-actions">
          <button
            type="button"
            class="tokenizer-btn tokenizer-btn-primary"
            @click="$emit('hide-messages')"
          >
            {{ hideButtonLabel }}
          </button>
          <button
            type="button"
            class="tokenizer-btn tokenizer-btn-secondary"
            @click="openSettings"
          >
            Settings
          </button>
        </div>
      </template>

      <!-- Settings sub-view -->
      <template v-else>
        <div class="tokenizer-settings-item">
          <label>History fill threshold (%)</label>
          <input type="number" min="1" max="100" v-model.number="localFillThreshold">
        </div>
        <div class="tokenizer-settings-item">
          <label>Hide top messages (%)</label>
          <input type="number" min="1" max="95" v-model.number="localHidePercent">
        </div>
        <p class="tokenizer-recommendation-text">Hide top messages recommendation appears when visible history reaches the configured threshold.</p>
        <div class="tokenizer-actions">
          <button type="button" class="tokenizer-btn tokenizer-btn-secondary" @click="showSettings = false">Back</button>
          <button type="button" class="tokenizer-btn tokenizer-btn-primary" @click="saveSettings">Save</button>
        </div>
      </template>
    </div>
  </SheetView>
</template>

<style scoped>
/* Loading State */
.tokenizer-loading {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 40px 20px;
  text-align: center;
}

.tokenizer-loading-icon {
  width: 64px;
  height: 64px;
  color: var(--warning-color, #ffb84d);
  margin-bottom: 16px;
}

.tokenizer-loading-icon svg {
  width: 100%;
  height: 100%;
  fill: currentColor;
}

.tokenizer-loading-text {
  color: var(--text-gray);
  font-size: 14px;
  line-height: 1.5;
  max-width: 400px;
}

/* Main Content */
.tokenizer-content {
  display: flex;
  flex-direction: column;
  padding: 20px;
  gap: 20px;
}

/* Summary KPIs */
.tokenizer-summary {
  display: flex;
  gap: 16px;
  justify-content: space-around;
  padding: 16px;
  background: rgba(var(--ui-bg-rgb), 0.5);
  border-radius: 12px;
}

.tokenizer-kpi {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}

.tokenizer-kpi strong {
  font-size: 24px;
  font-weight: 700;
  color: var(--text-black);
  line-height: 1;
}

.tokenizer-kpi span {
  font-size: 12px;
  color: var(--text-gray);
  text-align: center;
}

/* Context Bar */
.tokenizer-bar-container {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.tokenizer-bar {
  height: 32px;
  display: flex;
  border-radius: 8px;
  overflow: hidden;
  background: rgba(var(--ui-bg-rgb), 0.3);
}

.tokenizer-bar-used {
  display: flex;
  height: 100%;
}

.tokenizer-segment {
  height: 100%;
  transition: width 0.3s ease;
}

.tokenizer-reserve-container {
  display: flex;
  height: 100%;
}

/* Segment colors - match ChatView.vue */
.tokenizer-segment.chat-context-character { background-color: #ff6b6b; }
.tokenizer-segment.chat-context-preset { background-color: #4ecdc4; }
.tokenizer-segment.chat-context-summary { background-color: #95e1d3; }
.tokenizer-segment.chat-context-memory { background-color: #a8e6cf; }
.tokenizer-segment.chat-context-authors-note { background-color: #ffd93d; }
.tokenizer-segment.chat-context-history { background-color: #6c5ce7; }
.tokenizer-segment.chat-context-reserve { background-color: #a8dadc; }
.tokenizer-segment.chat-context-lorebook { background-color: #f4a261; }
.tokenizer-segment.chat-context-vector-lore { background-color: #e76f51; }

/* Legend */
.tokenizer-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  padding: 12px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 8px;
}

.tokenizer-legend-item {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: var(--text-gray);
}

.tokenizer-legend-swatch {
  width: 16px;
  height: 16px;
  border-radius: 4px;
}

/* Breakdown */
.tokenizer-breakdown {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.tokenizer-breakdown-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 8px 12px;
  background: rgba(var(--ui-bg-rgb), 0.3);
  border-radius: 8px;
  font-size: 14px;
}

.tokenizer-breakdown-row span {
  color: var(--text-gray);
}

.tokenizer-breakdown-row strong {
  color: var(--text-black);
  font-weight: 600;
}

/* Recommendation */
.tokenizer-recommendation {
  padding: 16px;
  background: rgba(255, 184, 77, 0.1);
  border: 1px solid rgba(255, 184, 77, 0.3);
  border-radius: 12px;
}

.tokenizer-recommendation-title {
  font-weight: 600;
  color: var(--warning-color, #ffb84d);
  margin-bottom: 4px;
}

.tokenizer-recommendation-text {
  font-size: 14px;
  color: var(--text-gray);
}

/* Actions & Settings */
.tokenizer-actions {
  display: flex;
  gap: 12px;
  margin-top: 8px;
}

.tokenizer-btn {
  flex: 1;
  padding: 12px 16px;
  border: none;
  border-radius: 12px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  font-family: inherit;
}

.tokenizer-btn-primary {
  background: var(--accent-color, var(--vk-blue));
  color: white;
}

.tokenizer-btn-primary:active {
  opacity: 0.8;
}

.tokenizer-btn-secondary {
  background: rgba(var(--ui-bg-rgb), 0.5);
  color: var(--text-black);
  border: 1px solid rgba(255, 255, 255, 0.1);
}

.tokenizer-btn-secondary:active {
  opacity: 0.7;
}

.tokenizer-settings-item {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 14px;
}

.tokenizer-settings-item label {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-black);
}

.tokenizer-settings-item input {
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(var(--ui-bg-rgb), 0.3);
  color: var(--text-black);
  font-size: 14px;
  font-family: inherit;
  outline: none;
}

@media (max-width: 600px) {
  .tokenizer-summary {
    gap: 12px;
  }

  .tokenizer-actions {
    flex-direction: column;
  }
}
</style>
