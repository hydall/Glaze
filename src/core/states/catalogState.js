/**
 * Reactive state for the Character Catalog feature.
 * Manages provider selection, search results, pagination, and character import.
 */
import { ref } from 'vue';
import { db } from '@/utils/db.js';
import { extractCharacterBook, generateThumbnail } from '@/utils/characterIO.js';
import { datacatBrowse, datacatSearch, datacatGetCharacter, datacatEnsureSession, datacatFresh } from '@/core/services/catalog/datacatProvider.js';
import { janitorSearch, janitorHampterSearch } from '@/core/services/catalog/janitorProvider.js';
import { Capacitor } from '@capacitor/core';

// ─── State ────────────────────────────────────────────────────────────────────

export const activeProvider = ref('datacat'); // 'datacat' | 'janitor'
export const catalogResults = ref([]);
export const catalogLoading = ref(false);
export const catalogError = ref(null);
export const catalogPage = ref(1);
export const catalogHasMore = ref(true);
export const catalogQuery = ref('');
export const catalogTotal = ref(0);

// Filters state
export const catalogFilters = ref({
    sort: 'newest', // newest, oldest, popular, tokens_desc, tokens_asc
    nsfw: true,
    tagIds: [],
    minTokens: 29,
    maxTokens: 100000
});

// Extraction state (JanitorAI via DataCat)
export const extractionStatus = ref(null); // { inProgress, queuePosition, phase } | null
export const extractionLoading = ref(false);

// ─── Search / Browse ──────────────────────────────────────────────────────────

const PAGE_SIZE = 24;

/**
 * Load (or reload) the catalog. Pass reset=true to go back to page 1.
 */
export async function searchCatalog(reset = false) {
    if (catalogLoading.value) return;

    if (reset) {
        catalogPage.value = 1;
        catalogResults.value = [];
        catalogHasMore.value = true;
        catalogError.value = null;
    }

    if (!catalogHasMore.value) return;

    catalogLoading.value = true;
    catalogError.value = null;

    try {
        const query = catalogQuery.value.trim();
        const page = catalogPage.value;
        let result;

        if (activeProvider.value === 'datacat') {
            await datacatEnsureSession();
            if (query) {
                result = await datacatSearch({ query, page, limit: PAGE_SIZE, filters: catalogFilters.value });
            } else {
                result = await datacatBrowse({ page, limit: PAGE_SIZE, filters: catalogFilters.value });
            }
        } else {
            // JanitorAI: prefer Hampter for popular/trending sort ONLY on native (bypass CORS)
            // On web, Hampter blocks proxies (403), so we fallback to MeiliSearch
            const canUseHampter = Capacitor.isNativePlatform();

            if (catalogFilters.value.sort === 'popular' && !query && canUseHampter) {
                result = await janitorHampterSearch({ query, page, filters: catalogFilters.value });
            } else {
                try {
                    result = await janitorSearch({ query, page, filters: catalogFilters.value });
                } catch (e) {
                    if (canUseHampter) {
                        result = await janitorHampterSearch({ query, page, filters: catalogFilters.value });
                    } else {
                        throw e;
                    }
                }
            }
        }

        const items = result.characters || [];
        catalogResults.value = reset ? items : [...catalogResults.value, ...items];
        catalogTotal.value = result.total || 0;
        catalogHasMore.value = items.length === PAGE_SIZE && catalogResults.value.length < (result.total || Infinity);
        catalogPage.value = page + 1;
    } catch (e) {
        catalogError.value = e.message || 'Failed to load catalog';
    } finally {
        catalogLoading.value = false;
    }
}

export async function loadMore() {
    await searchCatalog(false);
}

// ─── Character Import ─────────────────────────────────────────────────────────

/**
 * Import a character from catalog data into the app.
 * Downloads avatar, generates thumbnail, saves to IndexedDB.
 *
 * @param {object} charData - Glaze-compatible character object (from provider)
 * @param {string|null} avatarUrl - Remote avatar URL
 * @returns {Promise<string>} The saved character's id
 */
export async function importCharacter(charData, avatarUrl) {
    // Download and embed avatar
    if (avatarUrl) {
        try {
            const avatarBase64 = await fetchImageAsBase64(avatarUrl);
            charData.avatar = avatarBase64;
            charData.thumbnail = await generateThumbnail(avatarBase64);
        } catch (e) {
            console.warn('[catalog] Failed to download avatar:', e.message);
            charData.avatar = null;
            charData.thumbnail = null;
        }
    }

    // Assign placeholder color if no avatar
    if (!charData.avatar) {
        charData.color = randomColor();
    }

    // Extract lorebook if present
    await extractCharacterBook(charData);

    // Save to IndexedDB
    await db.saveCharacter(charData, -1);

    // Notify CharacterList to refresh
    window.dispatchEvent(new Event('character-updated'));

    return charData.id;
}

async function fetchImageAsBase64(url) {
    // Try direct fetch first (works on native due to CapacitorHttp... but for images
    // we use standard fetch since it returns a blob, not JSON)
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Failed to fetch image: ${res.status}`);
    const blob = await res.blob();
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(blob);
    });
}

const COLORS = ['#66ccff', '#ff7eb3', '#a78bfa', '#34d399', '#fbbf24', '#f87171', '#60a5fa'];
function randomColor() {
    return COLORS[Math.floor(Math.random() * COLORS.length)];
}

// ─── Provider Switch ──────────────────────────────────────────────────────────

export function setProvider(provider) {
    if (activeProvider.value === provider) return;
    activeProvider.value = provider;
    catalogQuery.value = '';
    searchCatalog(true);
}
