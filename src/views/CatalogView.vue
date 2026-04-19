<script setup>
import { ref, watch, onMounted, onUnmounted } from 'vue';
import { currentLang } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import {
    activeProvider, catalogResults, catalogLoading, catalogError,
    catalogHasMore, catalogQuery, catalogTotal,
    searchCatalog, loadMore, setProvider, importCharacter, catalogFilters
} from '@/core/states/catalogState.js';
import { datacatGetCharacter, datacatExtract, datacatExtractionStatus } from '@/core/services/catalog/datacatProvider.js';
import { janitorFetchCharacter } from '@/core/services/catalog/janitorProvider.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import FiltersBottomSheet from '@/components/sheets/FiltersBottomSheet.vue';

const t = (key, vars) => {
    let str = translations[currentLang.value]?.[key] || key;
    if (vars) for (const [k, v] of Object.entries(vars)) str = str.replace(`{${k}}`, v);
    return str;
};

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

function onScroll() {
    if (!scrollEl.value || catalogLoading.value || !catalogHasMore.value) return;
    const { scrollTop, scrollHeight, clientHeight } = scrollEl.value;
    if (scrollHeight - scrollTop - clientHeight < 300) {
        loadMore();
    }
}

// ─── Character Preview ────────────────────────────────────────────────────────

const previewLoading = ref(false);
const importingId = ref(null);

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
            // JanitorAI: scrape page
            charData = await janitorFetchCharacter(item.id, item.slug);
            avatarUrl = item.avatarUrl;
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

    // Build description preview (first 300 chars)
    const desc = charData.description || charData.creator_notes || '';
    const preview = desc.length > 300 ? desc.slice(0, 300) + '…' : desc;
    const tagsStr = item.tags?.slice(0, 5).join(', ') || '';
    const tokenStr = item.tokens ? `${item.tokens} tokens` : '';
    const meta = [tagsStr, tokenStr].filter(Boolean).join(' · ');

    showBottomSheet({ noDropdown: true,
        title: charData.name || item.name,
        items: [
            {
                label: t('catalog_import'),
                icon: `<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>`,
                onClick: () => doImport(item, charData, avatarUrl)
            },
            ...(item.source === 'janitor' ? [{
                label: t('catalog_extract_via_dc'),
                icon: `<svg viewBox="0 0 24 24"><path d="M17 12h-5v5h5v-5zM16 1v2H8V1H6v2H5c-1.11 0-1.99.9-1.99 2L3 19c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2h-1V1h-2zm3 18H5V8h14v11z"/></svg>`,
                onClick: () => startExtraction(item)
            }] : []),
            {
                label: t('btn_cancel'),
                icon: `<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>`,
                onClick: closeBottomSheet
            }
        ],
        bigInfo: meta || preview ? {
            icon: avatarUrl
                ? `<img src="${avatarUrl}" style="width:100%;height:100%;object-fit:cover;border-radius:12px" onerror="this.style.display='none'">`
                : `<svg viewBox="0 0 24 24" style="fill:var(--vk-blue);width:100%;height:100%"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>`,
            description: [meta, preview].filter(Boolean).join('\n\n'),
            buttonText: null
        } : undefined
    });
}

async function doImport(item, charData, avatarUrl) {
    importingId.value = item.id;
    closeBottomSheet();

    try {
        await importCharacter(charData, avatarUrl);
        showBottomSheet({ noDropdown: true,
            title: t('catalog_imported'),
            bigInfo: {
                icon: `<svg viewBox="0 0 24 24" style="fill:#4caf50;width:100%;height:100%"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>`,
                description: t('catalog_imported_desc', { name: charData.name }),
                buttonText: t('btn_ok'),
                onButtonClick: closeBottomSheet
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

                // Fetch the extracted character and open preview
                const fakeItem = { id: done.characterId, source: 'datacat', avatarUrl: null, tags: [], tokens: 0, slug: '' };
                await openPreview(fakeItem);
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

const openProviderSelector = () => {
    showBottomSheet({
        title: t('catalog_source') === 'catalog_source' ? 'Source' : t('catalog_source'),
        items: [
            {
                label: 'DataCat',
                isActive: activeProvider.value === 'datacat',
                onClick: () => {
                    setProvider('datacat');
                    closeBottomSheet();
                }
            },
            {
                label: 'JanitorAI',
                isActive: activeProvider.value === 'janitor',
                onClick: () => {
                    setProvider('janitor');
                    closeBottomSheet();
                }
            }
        ]
    });
};

const showFiltersSheet = ref(false);

const openFilters = () => {
    showFiltersSheet.value = true;
};

const onFiltersApply = () => {
    searchCatalog(true);
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatTokens(n) {
    if (!n) return '';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return String(n);
}

// ─── Mount ────────────────────────────────────────────────────────────────────

onMounted(() => {
    if (catalogResults.value.length === 0) {
        searchCatalog(true);
    }
    window.addEventListener('header-search', onHeaderSearch);
});

onUnmounted(() => {
    window.removeEventListener('header-search', onHeaderSearch);
});

watch(activeProvider, () => searchCatalog(true));
</script>

<template>
    <div class="catalog-view">
        <!-- Catalog Controls -->
        <div class="catalog-controls">
            <div class="preset-selector" @click="openProviderSelector">
                <span>{{ activeProvider === 'datacat' ? 'DataCat' : 'JanitorAI' }}</span>
                <svg viewBox="0 0 24 24" class="selector-chevron"><path d="M7 10l5 5 5-5z"/></svg>
            </div>
            
            <div class="preset-selector" @click="openFilters">
                <span>{{ t('filters') === 'filters' ? 'Filters' : t('filters') }}</span>
                <svg viewBox="0 0 24 24" class="selector-chevron"><path d="M10 18h4v-2h-4v2zM3 6v2h18V6H3zm3 7h12v-2H6v2z"/></svg>
            </div>
        </div>

        <FiltersBottomSheet v-model:visible="showFiltersSheet" @apply="onFiltersApply" />



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
            <div class="character-grid" style="padding: 4px 0; padding-bottom: calc(90px + var(--sab));">
                <div
                    v-for="item in catalogResults"
                    :key="item.source + item.id"
                    class="character-card"
                    @click="openPreview(item)"
                >
                    <!-- Token badge -->
                    <div class="card-token-badge" v-if="item.tokens">
                      <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                      <span>{{ formatTokens(item.tokens) }}</span>
                    </div>

                    <!-- Avatar Image -->
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
                        <div class="card-gradient"></div>
                    </div>

                    <!-- Info -->
                    <div class="card-info">
                        <div class="card-header-row">
                            <div class="card-name">{{ item.name }}</div>
                        </div>
                        <div class="card-desc" v-if="item.creator">@{{ item.creator }}</div>
                        
                        <div class="card-actions" v-if="item.tags?.length">
                            <span v-for="tag in item.tags.slice(0, 3)" :key="tag" class="card-tag">{{ tag }}</span>
                        </div>
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
    overflow: hidden;
    padding: 0 16px;
    box-sizing: border-box;
}

/* Controls */
.catalog-controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0px 0 12px;
  flex-shrink: 0;
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

/* Total count */
.catalog-total {
    font-size: 11px;
    color: var(--text-secondary, rgba(255,255,255,0.45));
    padding: 2px 2px 6px;
    flex-shrink: 0;
}

/* Scroll container */
.catalog-scroll {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding-bottom: 20px;
}

/* Grid */
.character-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 12px;
}

.character-card {
  position: relative;
  border-radius: 16px;
  overflow: hidden;
  aspect-ratio: 2 / 3;
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
  
  .character-card:hover .card-token-badge {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.4);
  }
}

.card-image-wrapper {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  z-index: 0;
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

.card-gradient {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  height: 70%;
  background: linear-gradient(to top, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.6) 50%, transparent 100%);
  pointer-events: none;
}

.card-info {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  padding: 12px;
  box-sizing: border-box;
  z-index: 1;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.card-header-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
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
  color: rgba(255,255,255,0.8);
  display: -webkit-box;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  text-shadow: 0 1px 2px rgba(0,0,0,0.8);
  line-height: 1.3;
}

.card-actions {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 4px;
  flex-wrap: wrap;
  gap: 4px;
}

.card-tag {
    font-size: 10px;
    padding: 1px 6px;
    border-radius: 6px;
    background: rgba(64, 128, 255, 0.2);
    color: var(--vk-blue, #4080ff);
    white-space: nowrap;
}

.card-token-badge {
  position: absolute;
  top: 8px;
  left: 8px;
  z-index: 10;
  display: flex;
  align-items: center;
  font-size: 11px;
  font-weight: 600;
  color: #fff;
  background-color: rgba(0,0,0,0.6);
  backdrop-filter: blur(4px);
  padding: 4px 8px;
  border-radius: 12px;
  pointer-events: none;
  transition: background-color 0.3s ease, box-shadow 0.3s ease;
}

.card-token-badge svg {
  width: 12px;
  height: 12px;
  margin-right: 4px;
  fill: currentColor;
  opacity: 0.9;
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
