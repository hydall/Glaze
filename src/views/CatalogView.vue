<script setup>
import { ref, watch, onMounted } from 'vue';
import { currentLang } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import {
    activeProvider, catalogResults, catalogLoading, catalogError,
    catalogHasMore, catalogQuery, catalogTotal,
    searchCatalog, loadMore, setProvider, importCharacter
} from '@/core/states/catalogState.js';
import { datacatGetCharacter, datacatExtract, datacatExtractionStatus } from '@/core/services/catalog/datacatProvider.js';
import { janitorFetchCharacter } from '@/core/services/catalog/janitorProvider.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';

const t = (key, vars) => {
    let str = translations[currentLang.value]?.[key] || key;
    if (vars) for (const [k, v] of Object.entries(vars)) str = str.replace(`{${k}}`, v);
    return str;
};

// ─── Search ───────────────────────────────────────────────────────────────────

const searchInput = ref(null);
let searchDebounce = null;

function onSearchInput() {
    clearTimeout(searchDebounce);
    searchDebounce = setTimeout(() => searchCatalog(true), 400);
}

function clearSearch() {
    catalogQuery.value = '';
    searchCatalog(true);
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
    showBottomSheet({
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
        showBottomSheet({
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

    showBottomSheet({
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
        showBottomSheet({
            title: t('catalog_imported'),
            bigInfo: {
                icon: `<svg viewBox="0 0 24 24" style="fill:#4caf50;width:100%;height:100%"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>`,
                description: t('catalog_imported_desc', { name: charData.name }),
                buttonText: t('btn_ok'),
                onButtonClick: closeBottomSheet
            }
        });
    } catch (e) {
        showBottomSheet({
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

    showBottomSheet({
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
        showBottomSheet({
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
});

watch(activeProvider, () => searchCatalog(true));
</script>

<template>
    <div class="catalog-view">
        <!-- Provider Toggle -->
        <div class="catalog-providers">
            <button
                class="provider-btn"
                :class="{ active: activeProvider === 'datacat' }"
                @click="setProvider('datacat')"
            >
                DataCat
            </button>
            <button
                class="provider-btn"
                :class="{ active: activeProvider === 'janitor' }"
                @click="setProvider('janitor')"
            >
                JanitorAI
            </button>
        </div>

        <!-- Search Bar -->
        <div class="catalog-search-bar">
            <svg class="search-icon" viewBox="0 0 24 24">
                <path d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/>
            </svg>
            <input
                ref="searchInput"
                v-model="catalogQuery"
                class="catalog-search-input"
                :placeholder="t('catalog_search_placeholder')"
                @input="onSearchInput"
                type="search"
            />
            <button v-if="catalogQuery" class="search-clear" @click="clearSearch">
                <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
            </button>
        </div>

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
            <div class="catalog-grid">
                <div
                    v-for="item in catalogResults"
                    :key="item.source + item.id"
                    class="catalog-card"
                    @click="openPreview(item)"
                >
                    <!-- Avatar -->
                    <div class="card-avatar-wrap">
                        <img
                            v-if="item.avatarUrl"
                            :src="item.avatarUrl"
                            class="card-avatar"
                            loading="lazy"
                            :alt="item.name"
                        />
                        <div v-else class="card-avatar-placeholder">
                            {{ item.name?.[0]?.toUpperCase() || '?' }}
                        </div>
                        <!-- Token badge -->
                        <span v-if="item.tokens" class="card-token-badge">{{ formatTokens(item.tokens) }}</span>
                    </div>

                    <!-- Info -->
                    <div class="card-info">
                        <div class="card-name">{{ item.name }}</div>
                        <div v-if="item.creator" class="card-creator">@{{ item.creator }}</div>
                        <div v-if="item.tags?.length" class="card-tags">
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
    padding: 0 12px;
    box-sizing: border-box;
}

/* Provider Toggle */
.catalog-providers {
    display: flex;
    gap: 8px;
    padding: 10px 0 6px;
    flex-shrink: 0;
}

.provider-btn {
    flex: 1;
    padding: 8px 0;
    border-radius: 12px;
    border: 1px solid var(--border-color, rgba(255,255,255,0.1));
    background: rgba(255,255,255,0.05);
    color: var(--text-color, #fff);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.2s, color 0.2s;
}

.provider-btn.active {
    background: var(--vk-blue, #4080ff);
    border-color: var(--vk-blue, #4080ff);
    color: #fff;
}

/* Search Bar */
.catalog-search-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    background: rgba(255,255,255, var(--element-opacity, 0.08));
    border: 1px solid var(--border-color, rgba(255,255,255,0.1));
    border-radius: 14px;
    padding: 0 12px;
    margin: 6px 0;
    flex-shrink: 0;
}

.search-icon {
    width: 18px;
    height: 18px;
    fill: var(--text-secondary, rgba(255,255,255,0.5));
    flex-shrink: 0;
}

.catalog-search-input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-color, #fff);
    font-size: 14px;
    padding: 10px 0;
    min-width: 0;
}

.catalog-search-input::placeholder {
    color: var(--text-secondary, rgba(255,255,255,0.4));
}

.search-clear {
    background: none;
    border: none;
    padding: 4px;
    cursor: pointer;
    display: flex;
    align-items: center;
    color: var(--text-secondary, rgba(255,255,255,0.5));
}

.search-clear svg {
    width: 16px;
    height: 16px;
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
.catalog-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
    gap: 10px;
    padding: 4px 0;
}

/* Card */
.catalog-card {
    background: rgba(255,255,255, var(--element-opacity, 0.05));
    border: 1px solid var(--border-color, rgba(255,255,255,0.08));
    border-radius: 14px;
    overflow: hidden;
    cursor: pointer;
    transition: transform 0.15s, border-color 0.15s;
    position: relative;
}

.catalog-card:active {
    transform: scale(0.97);
}

.card-avatar-wrap {
    position: relative;
    width: 100%;
    aspect-ratio: 3/4;
    background: rgba(255,255,255,0.05);
    overflow: hidden;
}

.card-avatar {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
}

.card-avatar-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 40px;
    font-weight: 700;
    color: rgba(255,255,255,0.4);
    background: rgba(255,255,255,0.04);
}

.card-token-badge {
    position: absolute;
    bottom: 6px;
    right: 6px;
    background: rgba(0,0,0,0.6);
    backdrop-filter: blur(4px);
    color: rgba(255,255,255,0.85);
    font-size: 10px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: 8px;
}

.card-info {
    padding: 8px 8px 10px;
}

.card-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-color, #fff);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-bottom: 2px;
}

.card-creator {
    font-size: 11px;
    color: var(--text-secondary, rgba(255,255,255,0.45));
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-bottom: 4px;
}

.card-tags {
    display: flex;
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
