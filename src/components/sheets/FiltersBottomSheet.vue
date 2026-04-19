<script setup>
import { ref, watch, computed } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import { catalogFilters, activeProvider } from '@/core/states/catalogState.js';

// JanitorAI tag map (same tags used by both JanitorAI and DataCat)
const JANNY_TAG_MAP = {
    1: 'Male', 2: 'Female', 3: 'Non-binary', 4: 'Celebrity', 5: 'OC',
    6: 'Fictional', 7: 'Real', 8: 'Game', 9: 'Anime', 10: 'Historical',
    11: 'Royalty', 12: 'Detective', 13: 'Hero', 14: 'Villain', 15: 'Magical',
    16: 'Non-human', 17: 'Monster', 18: 'Monster Girl', 19: 'Alien', 20: 'Robot',
    21: 'Politics', 22: 'Vampire', 23: 'Giant', 24: 'OpenAI', 25: 'Elf',
    26: 'Multiple', 27: 'VTuber', 28: 'Dominant', 29: 'Submissive', 30: 'Scenario',
    31: 'Pokemon', 32: 'Assistant', 34: 'Non-English', 36: 'Philosophy',
    38: 'RPG', 39: 'Religion', 41: 'Books', 42: 'AnyPOV', 43: 'Angst',
    44: 'Demi-Human', 45: 'Enemies to Lovers', 46: 'Smut', 47: 'MLM',
    48: 'WLW', 49: 'Action', 50: 'Romance', 51: 'Horror', 52: 'Slice of Life',
    53: 'Fantasy', 54: 'Drama', 55: 'Comedy', 56: 'Mystery', 57: 'Sci-Fi',
    59: 'Yandere', 60: 'Furry', 61: 'Movies/TV'
};

const ALL_TAGS = Object.entries(JANNY_TAG_MAP)
    .map(([id, name]) => ({ id: Number(id), name }))
    .sort((a, b) => a.name.localeCompare(b.name));

const props = defineProps({ visible: Boolean });
const emit = defineEmits(['update:visible', 'apply']);

const nsfw = ref(true);
const minTokens = ref(29);
const maxTokens = ref(100000);
const selectedTagIds = ref(new Set());

const tagSearch = ref('');
const filteredTags = computed(() => {
    const q = tagSearch.value.toLowerCase();
    if (!q) return ALL_TAGS;
    return ALL_TAGS.filter(t => t.name.toLowerCase().includes(q));
});

// Update global state AND trigger search ONLY when closing
watch(() => props.visible, (newVal, oldVal) => {
    // When opening: copy global state to local refs
    if (newVal) {
        const f = catalogFilters.value;
        nsfw.value = f.nsfw !== false;
        minTokens.value = f.minTokens ?? 29;
        maxTokens.value = f.maxTokens ?? 100000;
        selectedTagIds.value = new Set(f.tagIds || []);
        tagSearch.value = '';
    } 
    // When closing: save local refs to global state and trigger search
    else if (oldVal === true) {
        catalogFilters.value = {
            ...catalogFilters.value,
            nsfw: nsfw.value,
            minTokens: minTokens.value,
            maxTokens: maxTokens.value,
            tagIds: [...selectedTagIds.value]
        };
        emit('apply');
    }
});

function toggleTag(id) {
    const s = new Set(selectedTagIds.value);
    if (s.has(id)) s.delete(id);
    else s.add(id);
    selectedTagIds.value = s;
}

function clearTags() {
    selectedTagIds.value = new Set();
}

function closeSheet() {
    emit('update:visible', false);
}

const selectedTags = computed(() => ALL_TAGS.filter(t => selectedTagIds.value.has(t.id)));
</script>

<template>
    <BottomSheet :visible="visible" title="Filters" @close="closeSheet">
        <div class="filters-content">

            <!-- Tokens -->
            <div class="filter-section">
                <div class="filter-label">Token Range</div>
                <div class="filter-row">
                    <div class="filter-input-wrap">
                        <span class="input-label">Min</span>
                        <input type="number" v-model.number="minTokens" class="filter-input" />
                    </div>
                    <div class="filter-range-dash">—</div>
                    <div class="filter-input-wrap">
                        <span class="input-label">Max</span>
                        <input type="number" v-model.number="maxTokens" class="filter-input" />
                    </div>
                </div>
            </div>

            <!-- NSFW Toggle -->
            <div class="filter-section nsfw-row" style="margin-bottom: 5px;">
                <div class="filter-label" style="margin: 0;">Show NSFW</div>
                <label class="toggle-switch">
                    <input type="checkbox" v-model="nsfw">
                    <span class="slider"></span>
                </label>
            </div>

            <!-- Tag chips -->
            <div class="filter-section">
                <div class="filter-label-row">
                    <div class="filter-label">Tags</div>
                    <button v-if="selectedTagIds.size > 0" class="clear-tags-btn" @click="clearTags">
                        Clear ({{ selectedTagIds.size }})
                    </button>
                </div>

                <!-- Selected chips preview -->
                <div v-if="selectedTags.length" class="selected-tags-preview">
                    <span v-for="tag in selectedTags" :key="tag.id" class="tag-chip active" @click="toggleTag(tag.id)">
                        {{ tag.name }} <span class="chip-x">✕</span>
                    </span>
                </div>

                <!-- Tag search input -->
                <input
                    type="text"
                    v-model="tagSearch"
                    placeholder="Search tags..."
                    class="filter-input tag-search"
                />

                <!-- Tags grid -->
                <div class="tags-grid">
                    <button
                        v-for="tag in filteredTags"
                        :key="tag.id"
                        class="tag-chip"
                        :class="{ active: selectedTagIds.has(tag.id) }"
                        @click="toggleTag(tag.id)"
                    >{{ tag.name }}</button>
                </div>
            </div>

        </div>
    </BottomSheet>
</template>

<style scoped>
.filters-content {
    padding: 0 16px 24px;
    display: flex;
    flex-direction: column;
    gap: 20px;
}

.filter-section {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.filter-row {
    display: flex;
    align-items: center;
    gap: 12px;
}

.filter-input-wrap {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 4px;
}

.filter-range-dash {
    color: rgba(255,255,255,0.3);
    padding-top: 20px;
    font-size: 18px;
}

.input-label {
    font-size: 11px;
    color: rgba(255,255,255,0.4);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.filter-label {
    font-size: 12px;
    font-weight: 600;
    color: rgba(255,255,255,0.5);
    text-transform: uppercase;
    letter-spacing: 0.6px;
}

.filter-label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.filter-input {
    width: 100%;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    padding: 9px 12px;
    color: #fff;
    font-size: 14px;
    outline: none;
    transition: border-color 0.2s, background 0.2s;
    box-sizing: border-box;
}

.filter-input:focus {
    border-color: var(--vk-blue, #4080ff);
    background: rgba(255, 255, 255, 0.12);
}

.tag-search {
    margin-bottom: 6px;
}

.nsfw-row {
    flex-direction: row;
    justify-content: space-between;
    align-items: center;
    padding: 4px 0;
}

.toggle-switch {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
}

.toggle-switch input {
    opacity: 0;
    width: 0;
    height: 0;
}

.slider {
    position: absolute;
    cursor: pointer;
    inset: 0;
    background: rgba(255, 255, 255, 0.15);
    transition: 0.3s;
    border-radius: 24px;
}

.slider:before {
    position: absolute;
    content: "";
    height: 18px;
    width: 18px;
    left: 3px;
    bottom: 3px;
    background: #fff;
    transition: 0.3s;
    border-radius: 50%;
}

input:checked + .slider {
    background: var(--vk-blue, #4080ff);
}

input:checked + .slider:before {
    transform: translateX(20px);
}

/* Sort chips */
.sort-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
}

.sort-chip {
    padding: 7px 14px;
    border-radius: 20px;
    border: 1px solid rgba(255,255,255,0.15);
    background: rgba(255,255,255,0.05);
    color: rgba(255,255,255,0.7);
    font-size: 13px;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
    font-family: inherit;
}

.sort-chip.active {
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.2);
    border-color: var(--vk-blue, #4080ff);
    color: #fff;
}

/* Tag chips */
.selected-tags-preview {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding: 4px 0;
    border-bottom: 1px solid rgba(255,255,255,0.06);
    padding-bottom: 10px;
}

.tags-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    max-height: 200px;
    overflow-y: auto;
    overscroll-behavior: contain;
    padding: 2px 0;
}

.tags-grid::-webkit-scrollbar {
    width: 3px;
}

.tags-grid::-webkit-scrollbar-thumb {
    background: rgba(255,255,255,0.15);
    border-radius: 3px;
}

.tag-chip {
    padding: 6px 12px;
    border-radius: 20px;
    border: 1px solid rgba(255,255,255,0.12);
    background: rgba(255,255,255,0.05);
    color: rgba(255,255,255,0.65);
    font-size: 12px;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
    font-family: inherit;
    white-space: nowrap;
    display: flex;
    align-items: center;
    gap: 5px;
}

.tag-chip.active {
    background: rgba(var(--vk-blue-rgb, 64, 128, 255), 0.2);
    border-color: var(--vk-blue, #4080ff);
    color: #fff;
}

.chip-x {
    font-size: 10px;
    opacity: 0.7;
}

.clear-tags-btn {
    background: none;
    border: none;
    color: var(--vk-blue, #4080ff);
    font-size: 13px;
    cursor: pointer;
    padding: 0;
    font-family: inherit;
}

.filter-actions {
    margin-top: 4px;
}

.apply-btn {
    width: 100%;
    background: var(--vk-blue, #4080ff);
    color: #fff;
    border: none;
    border-radius: 12px;
    padding: 13px;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    font-family: inherit;
    transition: opacity 0.2s, transform 0.1s;
}

.apply-btn:active {
    transform: scale(0.98);
    opacity: 0.9;
}
</style>
