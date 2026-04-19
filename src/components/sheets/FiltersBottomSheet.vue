<script setup>
import { ref, watch, computed, onMounted } from 'vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import { catalogFilters } from '@/core/states/catalogState.js';
import { fetchJanitorTags, janitorTags, fetchJanitorTopTags } from '@/core/services/catalog/janitorProvider.js';

const ALL_TAGS = computed(() => {
    return [...janitorTags.value]
        .map(t => ({ id: Number(t.id), name: t.name }))
        .sort((a, b) => a.name.localeCompare(b.name));
});

onMounted(() => {
    fetchJanitorTags();
});

const props = defineProps({ visible: Boolean });
const emit = defineEmits(['update:visible', 'apply']);

const nsfw = ref(true);
const minTokens = ref(29);
const maxTokens = ref(100000);
const selectedTagIds = ref(new Set());
const selectedTagNames = ref(new Set());
const tagSearch = ref('');

const customTags = ref([]);
const isFetchingTags = ref(false);
let searchTimeout = null;

watch(tagSearch, (newVal) => {
    clearTimeout(searchTimeout);
    if (!newVal) {
        customTags.value = [];
        return;
    }
    searchTimeout = setTimeout(async () => {
        isFetchingTags.value = true;
        try {
            customTags.value = await fetchJanitorTopTags(newVal);
        } finally {
            isFetchingTags.value = false;
        }
    }, 400);
});

const filteredTags = computed(() => {
    const q = tagSearch.value.toLowerCase();
    
    // Get custom tags from API search
    const results = customTags.value.map(name => ({ name, isCustom: true }));
    
    // Get matching standard tags
    const standard = q 
        ? ALL_TAGS.value.filter(t => t.name.toLowerCase().includes(q))
        : ALL_TAGS.value;

    // Filter out standard tags that are already covered by custom names to avoid duplicates
    const filteredStandard = standard.filter(st => !results.some(ct => ct.name.toLowerCase() === st.name.toLowerCase()));

    // Custom first, then standard matching
    return [...results, ...filteredStandard];
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
        selectedTagNames.value = new Set(f.tagNames || []);
        tagSearch.value = '';
        customTags.value = [];
    } 
    // When closing: save local refs to global state and trigger search
    else if (oldVal === true) {
        catalogFilters.value = {
            ...catalogFilters.value,
            nsfw: nsfw.value,
            minTokens: minTokens.value,
            maxTokens: maxTokens.value,
            tagIds: [...selectedTagIds.value],
            tagNames: [...selectedTagNames.value]
        };
        emit('apply');
    }
});

function toggleTag(tag) {
    if (tag.id) {
        const s = new Set(selectedTagIds.value);
        if (s.has(tag.id)) s.delete(tag.id);
        else s.add(tag.id);
        selectedTagIds.value = s;
    } else {
        const s = new Set(selectedTagNames.value);
        if (s.has(tag.name)) s.delete(tag.name);
        else s.add(tag.name);
        selectedTagNames.value = s;
    }
}

function isTagActive(tag) {
    if (tag.id) return selectedTagIds.value.has(tag.id);
    return selectedTagNames.value.has(tag.name);
}

function clearTags() {
    selectedTagIds.value = new Set();
    selectedTagNames.value = new Set();
}

function closeSheet() {
    emit('update:visible', false);
}

const selectedTags = computed(() => {
    const res = [];
    // Add standard tags
    ALL_TAGS.value.forEach(t => {
        if (selectedTagIds.value.has(t.id)) res.push(t);
    });
    // Add custom tags
    selectedTagNames.value.forEach(name => {
        res.push({ name, isCustom: true });
    });
    return res;
});

const totalSelectedCount = computed(() => selectedTagIds.value.size + selectedTagNames.value.size);
</script>

<template>
    <BottomSheet :visible="visible" title="Filters" @close="closeSheet">
        <div class="filters-content">

            <!-- NSFW Toggle -->
            <div class="filter-section nsfw-row" style="margin-bottom: 5px;">
                <div class="filter-label" style="margin: 0;">Show NSFW</div>
                <label class="toggle-switch">
                    <input type="checkbox" v-model="nsfw">
                    <span class="slider"></span>
                </label>
            </div>

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

            <!-- Tag chips -->
            <div class="filter-section">
                <div class="filter-label-row">
                    <div class="filter-label">Tags</div>
                    <button v-if="totalSelectedCount > 0" class="clear-tags-btn" @click="clearTags">
                        Clear ({{ totalSelectedCount }})
                    </button>
                </div>

                <!-- Selected chips preview -->
                <TransitionGroup name="tag-list" tag="div" v-if="selectedTags.length" class="selected-tags-preview">
                    <span v-for="tag in selectedTags" :key="tag.id || tag.name" class="tag-chip active" @click="toggleTag(tag)">
                        {{ tag.name }} <span class="chip-x">✕</span>
                    </span>
                </TransitionGroup>

                <!-- Tag search input -->
                <input
                    type="text"
                    v-model="tagSearch"
                    placeholder="Search tags..."
                    class="filter-input tag-search"
                />

                <!-- Tags grid -->
                <TransitionGroup name="tag-list" tag="div" class="tags-grid">
                    <button
                        v-for="tag in filteredTags"
                        :key="tag.id || tag.name"
                        class="tag-chip"
                        :class="{ active: isTagActive(tag), 'custom-tag': tag.isCustom }"
                        @click="toggleTag(tag)"
                    >
                        <span v-if="tag.isCustom" class="custom-tag-prefix">#</span>
                        {{ tag.name }}
                    </button>
                </TransitionGroup>
                <div v-if="isFetchingTags" class="fetching-tags-loader">Searching tags...</div>
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
    padding: 2px 0;
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

.custom-tag {
    border-style: dashed;
}

.custom-tag-prefix {
    opacity: 0.5;
    font-weight: 400;
}

.fetching-tags-loader {
    font-size: 11px;
    color: rgba(255,255,255,0.4);
    padding: 4px 0;
    font-style: italic;
}

/* Transitions */
.tag-list-enter-active,
.tag-list-leave-active {
    transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}

.tag-list-enter-from,
.tag-list-leave-to {
    opacity: 0;
    transform: scale(0.8);
}

/* Ensure smooth moving when others are added/removed */
.tag-list-move {
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1);
}
</style>
