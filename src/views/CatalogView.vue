<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { t } from '@/utils/i18n.js';
import { janitorTagMap } from '@/core/services/catalog/janitorProvider.js';
import {
    catalogResults, catalogLoading, catalogError,
    catalogHasMore, catalogQuery, catalogTotal,
    searchCatalog, loadMore, importCharacter, catalogFilters
} from '@/core/states/catalogState.js';
import { createNewSession } from '@/utils/sessions.js';
import { datacatGetCharacter, datacatExtract, datacatExtractionStatus } from '@/core/services/catalog/datacatProvider.js';
import { janitorFetchCharacter, janitorSearch, janitorItemToPartialCharData } from '@/core/services/catalog/janitorProvider.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import FiltersBottomSheet from '@/components/sheets/FiltersBottomSheet.vue';
import CatalogCharacterSheet from '@/components/sheets/CatalogCharacterSheet.vue';

// ─── Search ───────────────────────────────────────────────────────────────────

let searchDebounce = null;

function onHeaderSearch(e) {
    // Only search if catalog tab is active, but since catalogQuery is global to catalogState it's safe to update
    catalogQuery.value = e.detail;
    clearTimeout(searchDebounce);
    searchDebounce = setTimeout(() => searchCatalog(true), 400);
}

// ─── Infinite Scroll ──────────────────────────────────────────────────────────

const scrollEl = ref(null);
const loadMoreSentinel = ref(null);
let scrollObserver = null;

function onScroll() {
    if (!scrollEl.value || catalogLoading.value || !catalogHasMore.value) return;
    const { scrollTop, scrollHeight, clientHeight } = scrollEl.value;
    if (scrollHeight - scrollTop - clientHeight < 600) {
        loadMore();
    }
}

// ─── Character Preview ────────────────────────────────────────────────────────

const previewLoading = ref(false);
const importingId = ref(null);
const showCharSheet = ref(false);
const previewItem = ref(null);
const previewCharData = ref(null);
const previewAvatarUrl = ref(null);

async function openPreview(item) {
    // Show loading sheet immediately
    showBottomSheet({ noDropdown: true,
        title: item.name,
        bigInfo: {
            icon: `<svg viewBox="0 0 24 24" style="width:100%;height:100%;fill:var(--vk-blue)"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 14H9V8h2v8zm4 0h-2V8h2v8z"/></svg>`,
            description: t('catalog_loading_char'),
            buttonText: t('btn_cancel'),
            onButtonClick: closeBottomSheet
        }
    });

    previewLoading.value = true;
    let charData = null;
    let avatarUrl = item.avatarUrl;

    try {
        if (item.source === 'datacat') {
            const result = await datacatGetCharacter(item.id);
            charData = result.charData;
            avatarUrl = result.avatarUrl || avatarUrl;
        } else {
            // Janitor source — try direct fetch first
            let loginRequired = false;
            try {
                charData = await janitorFetchCharacter(item.id, item.slug);
            } catch (e) {
                if (e.status === 401 || e.status === 403) {
                    loginRequired = true;
                } else {
                    throw e;
                }
            }

            if (loginRequired) {
                // 1. Try DataCat by the same UUID (DataCat indexes janitor chars with same ID)
                try {
                    const result = await datacatGetCharacter(item.id);
                    charData = result.charData;
                    avatarUrl = result.avatarUrl || avatarUrl;
                } catch { /* not on DataCat yet */ }

                // 2. Try jannyai MeiliSearch for partial public data
                if (!charData) {
                    try {
                        const jResult = await janitorSearch({ query: item.name, page: 1 });
                        const hit = jResult.characters.find(c => c.id === item.id);
                        if (hit) charData = janitorItemToPartialCharData(hit);
                    } catch { /* search failed */ }
                }

                // 3. Nothing found — offer DataCat extraction
                if (!charData) {
                    previewLoading.value = false;
                    startExtraction(item);
                    return;
                }
            }
        }
    } catch (e) {
        showBottomSheet({ noDropdown: true,
            title: t('title_error'),
            bigInfo: {
                icon: `<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>`,
                description: e.message || t('catalog_error_load'),
                buttonText: t('btn_ok'),
                onButtonClick: closeBottomSheet
            }
        });
        previewLoading.value = false;
        return;
    }

    previewLoading.value = false;
    closeBottomSheet();

    previewItem.value = item;
    previewCharData.value = charData;
    previewAvatarUrl.value = avatarUrl;
    showCharSheet.value = true;
}

async function onSheetImport() {
    const item = previewItem.value;
    const charData = previewCharData.value;
    const avatarUrl = previewAvatarUrl.value;
    showCharSheet.value = false;
    if (!item || !charData) return;

    if (item.source === 'datacat') {
        doImport(item, charData, avatarUrl);
    } else {
        startExtraction(item);
    }
}

async function doImport(item, charData, avatarUrl) {
    importingId.value = item.id;
    closeBottomSheet();

    try {
        const charId = await importCharacter(charData, avatarUrl);
        showBottomSheet({ noDropdown: true,
            title: t('catalog_imported'),
            bigInfo: {
                icon: `<svg viewBox="0 0 24 24" style="fill:#4caf50;width:100%;height:100%"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>`,
                description: t('catalog_imported_desc', { name: charData.name }),
                buttonText: t('catalog_open_chat'),
                onButtonClick: async () => {
                    closeBottomSheet();
                    await createNewSession(charId);
                    window.dispatchEvent(new CustomEvent('open-chat', { detail: { charId } }));
                }
            }
        });
    } catch (e) {
        showBottomSheet({ noDropdown: true,
            title: t('title_error'),
            bigInfo: {
                icon: `<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>`,
                description: e.message || t('catalog_error_import'),
                buttonText: t('btn_ok'),
                onButtonClick: closeBottomSheet
            }
        });
    } finally {
        importingId.value = null;
    }
}

// ─── JanitorAI Extraction via DataCat ────────────────────────────────────────

const extractionItemId = ref(null);
const extractionPhase = ref('');
let pollInterval = null;

async function startExtraction(item) {
    closeBottomSheet();
    const url = `https://janitorai.com/characters/${item.id}`;
    extractionItemId.value = item.id;
    extractionPhase.value = 'queued';

    showBottomSheet({ noDropdown: true,
        title: t('catalog_extracting'),
        bigInfo: {
            icon: `<svg viewBox="0 0 24 24" style="fill:var(--vk-blue);width:100%;height:100%"><path d="M12 4V1L8 5l4 4V6c3.31 0 6 2.69 6 6 0 1.01-.25 1.97-.7 2.8l1.46 1.46C19.54 15.03 20 13.57 20 12c0-4.42-3.58-8-8-8zm0 14c-3.31 0-6-2.69-6-6 0-1.01.25-1.97.7-2.8L5.24 7.74C4.46 8.97 4 10.43 4 12c0 4.42 3.58 8 8 8v3l4-4-4-4v3z"/></svg>`,
            description: t('catalog_extract_progress'),
            buttonText: t('btn_cancel'),
            onButtonClick: cancelExtraction
        }
    });

    try {
        await datacatExtract(url, true);
        startPolling(item);
    } catch (e) {
        extractionItemId.value = null;
        showBottomSheet({ noDropdown: true,
            title: t('title_error'),
            bigInfo: {
                icon: `<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>`,
                description: e.message || t('catalog_error_extract'),
                buttonText: t('btn_ok'),
                onButtonClick: closeBottomSheet
            }
        });
    }
}

function startPolling(item) {
    let attempts = 0;
    const MAX = 60;

    pollInterval = setInterval(async () => {
        attempts++;
        if (attempts > MAX) {
            cancelExtraction();
            return;
        }

        try {
            const status = await datacatExtractionStatus();
            if (status.inProgress) {
                extractionPhase.value = status.inProgress.phase || 'extracting';
                return;
            }

            // Check history for completed extraction matching our item
            const done = status.history?.find(h => h.url?.includes(item.id));
            if (done && done.characterId) {
                clearInterval(pollInterval);
                pollInterval = null;
                extractionItemId.value = null;
                closeBottomSheet();

                // Fetch extracted data and import directly — no second preview step
                try {
                    const result = await datacatGetCharacter(done.characterId);
                    const fakeItem = { id: done.characterId, source: 'datacat', avatarUrl: null, tags: [], tokens: 0, slug: '' };
                    doImport(fakeItem, result.charData, result.avatarUrl || item.avatarUrl);
                } catch (e) {
                    showBottomSheet({ noDropdown: true,
                        title: t('title_error'),
                        bigInfo: {
                            icon: `<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>`,
                            description: e.message || t('catalog_error_import'),
                            buttonText: t('btn_ok'),
                            onButtonClick: closeBottomSheet
                        }
                    });
                }
            }
        } catch {
            // Network error — keep polling
        }
    }, 3000);
}

function cancelExtraction() {
    if (pollInterval) {
        clearInterval(pollInterval);
        pollInterval = null;
    }
    extractionItemId.value = null;
    closeBottomSheet();
}

// ─── Controls ─────────────────────────────────────────────────────────────────

const showFiltersSheet = ref(false);

const openFilters = () => {
    showFiltersSheet.value = true;
};

const onFiltersApply = () => {
    searchCatalog(true);
};

const SORT_OPTIONS = [
    { value: 'popular',       label: 'sort_popular',      hint: 'sort_popular_hint' },
    { value: 'trending_week', label: 'sort_trending',     hint: 'sort_trending_hint' },
    { value: 'trending_24h',  label: 'sort_trending_24h', hint: 'sort_trending_24h_hint' },
    { value: 'latest',        label: 'sort_latest',       hint: 'sort_latest_hint' }
];

const currentSortLabel = () => {
    const cur = catalogFilters.value?.sort || 'latest';
    const key = SORT_OPTIONS.find(o => o.value === cur)?.label || 'sort_latest';
    return t(key);
};

const activeTagItems = computed(() => {
    const res = [];
    // Standard tags
    (catalogFilters.value.tagIds || []).forEach(id => {
        const label = janitorTagMap.value[id];
        if (label) res.push({ id, label });
    });
    // Custom tags
    (catalogFilters.value.tagNames || []).forEach(name => {
        res.push({ name, label: '#' + name });
    });
    return res;
});

function removeTag(tag) {
    if (tag.id) {
        catalogFilters.value.tagIds = catalogFilters.value.tagIds.filter(tid => tid !== tag.id);
    } else {
        catalogFilters.value.tagNames = catalogFilters.value.tagNames.filter(tn => tn !== tag.name);
    }
    searchCatalog(true);
}

function openSortSelector() {
    showBottomSheet({
        title: t('sort_by'),
        items: SORT_OPTIONS.map(opt => ({
            label: t(opt.label),
            hint: t(opt.hint),
            isActive: (catalogFilters.value?.sort || 'latest') === opt.value,
            onClick: () => {
                catalogFilters.value = { ...catalogFilters.value, sort: opt.value };
                searchCatalog(true);
                closeBottomSheet();
            }
        }))
    });
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function snippetText(html, max = 250) {
    if (!html) return '';
    // Strip images but keep other formatting tags
    const clean = html.replace(/<img[^>]*>/gi, '');
    if (clean.length > max + 50) {
      // Very basic truncation that doesn't break tags perfectly but we use line-clamp anyway
      return clean.slice(0, max) + '…';
    }
    return clean;
}

function formatNumber(n) {
    if (!n) return '';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'kk';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return String(n);
}

// ─── Mount ────────────────────────────────────────────────────────────────────

onMounted(() => {
    if (catalogResults.value.length === 0) {
        searchCatalog(true);
    }
    window.addEventListener('header-search', onHeaderSearch);
    
    scrollObserver = new IntersectionObserver((entries) => {
        if (entries[0].isIntersecting && !catalogLoading.value && catalogHasMore.value) {
            loadMore();
        }
    }, { rootMargin: '600px' });
    
    if (loadMoreSentinel.value) {
        scrollObserver.observe(loadMoreSentinel.value);
    }
});

onUnmounted(() => {
    window.removeEventListener('header-search', onHeaderSearch);
    if (scrollObserver) {
        scrollObserver.disconnect();
    }
});


</script>

<template>
    <div class="catalog-view">
        <!-- Catalog Controls -->
        <div class="catalog-controls">
            <div class="active-filters-container">
                <div class="active-filters" v-if="activeTagItems.length">
                    <div v-for="tag in activeTagItems" :key="tag.id || tag.name" class="active-tag-chip" @click="removeTag(tag)">
                        {{ tag.label }}
                        <svg viewBox="0 0 24 24" class="chip-remove-icon"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                    </div>
                </div>
            </div>

            <div class="sort-controls">
                <div class="filter-icon-btn" @click="openFilters">
                    <svg viewBox="0 0 24 24"><path d="M10 18h4v-2h-4v2zM3 6v2h18V6H3zm3 7h12v-2H6v2z"/></svg>
                    <span v-if="(catalogFilters.tagIds?.length || 0) + (catalogFilters.tagNames?.length || 0) > 0" class="filter-badge">
                        {{ (catalogFilters.tagIds?.length || 0) + (catalogFilters.tagNames?.length || 0) }}
                    </span>
                </div>
                <div class="preset-selector" @click="openSortSelector">
                    <span>{{ currentSortLabel() }}</span>
                    <svg viewBox="0 0 24 24" class="selector-chevron"><path d="M7 10l5 5 5-5z"/></svg>
                </div>
            </div>
        </div>

        <FiltersBottomSheet v-model:visible="showFiltersSheet" @apply="onFiltersApply" />
        <CatalogCharacterSheet
            v-model:visible="showCharSheet"
            :item="previewItem"
            :charData="previewCharData"
            :avatarUrl="previewAvatarUrl"
            @import="onSheetImport"
        />



        <!-- Results Count -->
        <div v-if="catalogTotal > 0 && !catalogLoading" class="catalog-total">
            {{ t('catalog_total', { count: catalogTotal }) }}
        </div>

        <!-- Error State -->
        <div v-if="catalogError && catalogResults.length === 0" class="catalog-empty">
            <svg viewBox="0 0 24 24" class="empty-icon"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>
            <p>{{ catalogError }}</p>
            <button class="retry-btn" @click="searchCatalog(true)">{{ t('btn_retry') }}</button>
        </div>

        <!-- Empty State -->
        <div v-else-if="!catalogLoading && catalogResults.length === 0 && !catalogError" class="catalog-empty">
            <svg viewBox="0 0 24 24" class="empty-icon"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
            <p>{{ t('catalog_empty') }}</p>
        </div>

        <!-- Character Grid -->
        <div class="catalog-scroll" ref="scrollEl" @scroll.passive="onScroll">
            <div class="character-grid" style="padding: 0; padding-bottom: calc(90px + var(--sab));">
                <div
                    v-for="item in catalogResults"
                    :key="item.source + item.id"
                    class="character-card"
                    @click="openPreview(item)"
                >
                    <!-- Avatar Image and Overlay Headers -->
                    <div class="card-image-wrapper">
                        <img
                            v-if="item.avatarUrl"
                            :src="item.avatarUrl"
                            class="card-image"
                            loading="lazy"
                            :alt="item.name"
                        />
                        <div v-else class="card-placeholder" style="background-color: #66ccff;">
                            {{ item.name?.[0]?.toUpperCase() || '?' }}
                        </div>
                        
                        <!-- Top Content (Message Badge) -->
                        <div class="card-header-top">
                            <div style="flex: 1;"></div>
                            
                            <!-- Card Badge (Messages only) -->
                            <div class="card-badge" v-if="item.stats && item.stats.message > 0">
                              <svg viewBox="0 0 24 24" class="msg-icon"><path d="M20 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 14H4V8l8 5 8-5v10zm-8-7L4 6h16l-8 5z"/></svg>
                              <span>{{ formatNumber(item.stats.message) }}</span>
                            </div>
                        </div>
                    </div>

                    <!-- Bottom Info & Tags -->
                    <div class="card-info-bottom">
                        <div class="card-name-col">
                            <div class="card-name">{{ item.name }}</div>
                            <div class="card-desc" v-if="item.creator">
                                <a 
                                    v-if="item.creator_id" 
                                    :href="'https://janitorai.com/profiles/' + item.creator_id" 
                                    target="_blank" 
                                    @click.stop
                                    class="creator-link"
                                >@{{ item.creator }}</a>
                                <span v-else>@{{ item.creator }}</span>
                            </div>
                            <div class="card-tokens" v-if="item.tokens">{{ formatNumber(item.tokens) }} tokens</div>
                        </div>

                        <div class="card-actions" v-if="item.tags?.length || item.nsfw !== undefined">
                            <span v-for="tag in item.tags" :key="tag" class="card-tag" :class="{ 
                                'card-tag-custom': tag.startsWith('#'),
                                'nsfw-indicator': tag === 'NSFW',
                                'sfw-indicator': tag === 'SFW'
                            }">{{ tag }}</span>
                        </div>

                        <div class="card-snippet" v-if="item.description" v-html="snippetText(item.description)"></div>
                    </div>

                    <!-- Import spinner overlay -->
                    <div v-if="importingId === item.id" class="card-importing">
                        <div class="spinner"></div>
                    </div>
                </div>
            </div>

            <!-- Loading more -->
            <div v-if="catalogLoading" class="catalog-loading">
                <div class="spinner"></div>
            </div>

            <!-- Sentinel to trigger next page load using IntersectionObserver -->
            <div ref="loadMoreSentinel" class="scroll-sentinel" style="height: 1px;"></div>

            <!-- End of results -->
            <div v-if="!catalogHasMore && catalogResults.length > 0" class="catalog-end">
                {{ t('catalog_end') }}
            </div>
        </div>
    </div>
</template>

<style scoped>
.catalog-view {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: visible;
    box-sizing: border-box;
}

/* Controls */
.catalog-controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 12px 16px;
  flex-shrink: 0;
  overflow: visible;
}

@media (min-width: 600px) {
  .catalog-controls {
    justify-content: flex-start;
    gap: 20px;
  }
  .catalog-controls .sort-controls {
    order: 1;
  }
  .catalog-controls .active-filters-container {
    order: 2;
  }
  .catalog-controls .filter-icon-btn {
    order: 2;
  }
}

.preset-selector {
  height: 32px;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  font-weight: 600;
  font-size: 13px;
  color: var(--vk-blue, #4080ff);
  padding: 0 14px;
  border-radius: 16px;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  transition: transform 0.1s ease, background-color 0.2s, border-color 0.2s, opacity 0.2s;
  overflow: hidden;
  user-select: none;
  flex-shrink: 0;
}

@media (hover: hover) {
  .preset-selector:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
    border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
    transform: translateY(-1px);
  }
}

.preset-selector:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.preset-selector .selector-chevron {
  width: 20px;
  height: 20px;
  fill: currentColor;
}

/* Sort controls */
.sort-controls {
  display: flex;
  align-items: center;
  gap: 8px;
}

.filter-icon-btn {
  position: relative;
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15);
  backdrop-filter: blur(var(--element-blur, 12px));
  -webkit-backdrop-filter: blur(var(--element-blur, 12px));
  border: 1px solid rgba(var(--vk-blue-rgb, 82, 139, 204), 0.2);
  cursor: pointer;
  color: var(--vk-blue, #4080ff);
  flex-shrink: 0;
  transition: transform 0.1s ease, background-color 0.2s, opacity 0.2s;
  user-select: none;
}

.filter-icon-btn svg {
  width: 18px;
  height: 18px;
  fill: currentColor;
}

@media (hover: hover) {
  .filter-icon-btn:hover {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.25);
    border-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.4);
    transform: translateY(-1px);
  }
}

.filter-icon-btn:active {
  transform: scale(0.95);
  opacity: 0.8;
}

.active-filters-container {
  flex: 1;
  min-width: 0;
  display: flex;
  align-items: center;
  overflow: hidden;
}

.active-filters {
  display: flex;
  gap: 6px;
  overflow-x: auto;
  width: 100%;
  scrollbar-width: none;
  padding: 4px 0;
  mask-image: linear-gradient(to right, black 85%, transparent 100%);
  -webkit-mask-image: linear-gradient(to right, black 85%, transparent 100%);
}

.active-filters::-webkit-scrollbar {
  display: none;
}

.active-tag-chip {
  font-size: 11px;
  font-weight: 600;
  color: #fff;
  background-color: var(--vk-blue, #4080ff);
  padding: 4px 10px;
  border-radius: 12px;
  white-space: nowrap;
  box-shadow: 0 2px 6px rgba(var(--vk-blue-rgb, 64, 128, 255), 0.3);
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 4px;
  transition: transform 0.1s, opacity 0.2s;
}

.active-tag-chip:active {
  transform: scale(0.92);
  opacity: 0.8;
}

.chip-remove-icon {
  width: 12px;
  height: 12px;
  fill: currentColor;
  opacity: 0.8;
}

.filter-badge {
  position: absolute;
  top: -4px;
  right: -4px;
  min-width: 16px;
  height: 16px;
  padding: 0 4px;
  border-radius: 8px;
  background: var(--vk-blue, #4080ff);
  color: #fff;
  font-size: 10px;
  font-weight: 700;
  line-height: 16px;
  text-align: center;
  pointer-events: none;
  box-sizing: border-box;
}

/* Total count */
.catalog-total {
    font-size: 11px;
    color: var(--text-secondary, rgba(255,255,255,0.45));
    padding: 2px 16px 6px;
    flex-shrink: 0;
}

/* Scroll container */
.catalog-scroll {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 0 16px 20px;
}

/* Grid */
.character-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
  gap: 12px;
}

@media (min-width: 600px) {
  .character-grid {
    grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 16px;
  }
}

.character-card {
  position: relative;
  border-radius: 16px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  background-color: var(--bg-color-light, #2a2a2a);
  box-shadow: 0 4px 6px rgba(0,0,0,0.1);
  transition: transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 0.3s ease, border-color 0.3s ease;
  cursor: pointer;
  border: 1px solid rgba(255,255,255,0.05);
}

.character-card:active {
  transform: scale(0.96);
}

@media (hover: hover) {
  .character-card:hover {
    transform: translateY(-4px) scale(1.01);
    box-shadow: 0 12px 24px rgba(0,0,0,0.3);
  }

  .character-card:hover .card-image {
    transform: scale(1.05);
  }
}

.card-image-wrapper {
  position: relative;
  width: 100%;
  aspect-ratio: 2 / 3;
  flex-shrink: 0;
  z-index: 0;
  overflow: hidden;
}

.card-image-wrapper::after {
  content: '';
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 50%;
  background: linear-gradient(to top, var(--bg-color-light, #2a2a2a) 0%, rgba(0,0,0,0) 100%);
  pointer-events: none;
  z-index: 1;
}

.card-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  transition: transform 0.5s ease;
}

.card-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 3em;
  color: rgba(255,255,255,0.8);
  font-weight: bold;
}

.card-header-top {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  padding: 12px;
  box-sizing: border-box;
  z-index: 2;
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 8px;
  pointer-events: none; /* Let clicks pass to card, except maybe badge */
}

.card-info-bottom {
  position: relative;
  z-index: 3;
  padding: 6px 10px 12px;
  margin-top: -4px;
  background-color: var(--bg-color-light, #2a2a2a);
  display: flex;
  flex-direction: column;
  gap: 8px;
}  

.card-name-col {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.card-name {
  font-weight: 700;
  font-size: 1.1em;
  color: #fff;
  text-shadow: 0 2px 4px rgba(0,0,0,0.8);
  line-height: 1.2;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.card-desc {
  font-size: 0.8em;
  color: rgba(255,255,255,0.7);
  display: -webkit-box;
  -webkit-line-clamp: 1;
  line-clamp: 1;
  -webkit-box-orient: vertical;
  overflow: hidden;
  text-shadow: 0 1px 2px rgba(0,0,0,0.8);
}

.creator-link {
    color: inherit;
    text-decoration: none;
    transition: color 0.2s;
}

@media (hover: hover) {
    .creator-link:hover {
        color: var(--vk-blue, #4080ff);
        text-decoration: underline;
    }
}

.card-snippet {
  font-size: 0.75em;
  color: rgba(255,255,255,0.55);
  text-shadow: 0 1px 2px rgba(0,0,0,0.8);
  line-height: 1.4;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  word-break: break-word;
}

.card-snippet :deep(p) { margin: 0; }
.card-snippet :deep(br) { display: none; } /* Hide line breaks to save space in snippet */



.card-tokens {
  font-size: 0.8em;
  font-weight: 600;
  color: rgba(255,255,255,0.5);
}

.card-actions {
  display: flex;
  justify-content: flex-start;
  align-items: center;
  margin-top: 4px;
  flex-wrap: wrap;
  gap: 4px;
}

.card-tag {
    font-size: 10px;
    padding: 2px 8px;
    border-radius: 8px;
    background: rgba(64, 128, 255, 0.15);
    color: var(--vk-blue, #4080ff);
    white-space: nowrap;
    border: 1px solid rgba(64, 128, 255, 0.2);
    font-weight: 600;
}

.nsfw-indicator {
    background: rgba(255, 68, 68, 0.2) !important;
    color: #ff4444 !important;
    border-color: rgba(255, 68, 68, 0.3) !important;
}

.sfw-indicator {
    background: rgba(76, 175, 80, 0.2) !important;
    color: #4caf50 !important;
    border-color: rgba(76, 175, 80, 0.3) !important;
}

.card-tag-custom {
    background: rgba(0, 255, 255, 0.1) !important;
    color: #00cccc !important;
    border-color: rgba(0, 255, 255, 0.2) !important;
}

/* Alternate custom tag color for variety like in screenshot */
.card-tag-custom:nth-child(3n) {
    background: rgba(255, 0, 255, 0.1) !important;
    color: #cc00cc !important;
    border-color: rgba(255, 0, 255, 0.2) !important;
}

.card-badge {
  flex-shrink: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  font-size: 10px;
  font-weight: 600;
  color: #fff;
  background-color: rgba(0,0,0,0.6);
  backdrop-filter: blur(4px);
  -webkit-backdrop-filter: blur(4px);
  padding: 4px 6px;
  border-radius: 10px;
  transition: background-color 0.3s ease, box-shadow 0.3s ease;
}

.card-badge svg {
  width: 12px;
  height: 12px;
  margin-right: 4px;
  fill: currentColor;
  opacity: 0.9;
}

.badge-sep {
  margin: 0 6px;
  opacity: 0.4;
  font-weight: normal;
}

.msg-icon {
  margin-right: 3px !important;
}

/* Import overlay */
.card-importing {
    position: absolute;
    inset: 0;
    background: rgba(0,0,0,0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 14px;
}

/* Empty / Error */
.catalog-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 60px 20px;
    gap: 12px;
    color: var(--text-secondary, rgba(255,255,255,0.5));
    text-align: center;
}

.empty-icon {
    width: 48px;
    height: 48px;
    fill: currentColor;
    opacity: 0.4;
}

.catalog-empty p {
    font-size: 14px;
    margin: 0;
}

.retry-btn {
    background: var(--vk-blue, #4080ff);
    color: #fff;
    border: none;
    border-radius: 12px;
    padding: 8px 20px;
    font-size: 13px;
    cursor: pointer;
}

/* Loading */
.catalog-loading {
    display: flex;
    justify-content: center;
    padding: 24px;
}

.catalog-end {
    text-align: center;
    font-size: 12px;
    color: var(--text-secondary, rgba(255,255,255,0.3));
    padding: 16px;
}

/* Spinner */
.spinner {
    width: 24px;
    height: 24px;
    border: 2px solid rgba(255,255,255,0.15);
    border-top-color: var(--vk-blue, #4080ff);
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
}

@keyframes spin {
    to { transform: rotate(360deg); }
}
</style>
