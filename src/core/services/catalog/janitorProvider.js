/**
 * JanitorAI (jannyai.com) provider.
 * Search via MeiliSearch API. Character details via HTML scrape (Astro island props).
 * Fallback search via Hampter API.
 */
import { catalogGet, catalogGetText, catalogPost } from './catalogHttp.js';

const SEARCH_URL = 'https://search.jannyai.com/multi-search';
const BASE_URL = 'https://jannyai.com';
const HAMPTER_URL = 'https://janitorai.com/hampter/characters';
const TOKEN_KEY = 'gz_janny_token';

// Hardcoded fallback token (changes rarely)
const FALLBACK_TOKEN = '88a6463b66e04fb07ba87ee3db06af337f492ce511d93df6e2d2968cb2ff2b30';

// ─── CORS Note ────────────────────────────────────────────────────────────────
// MeiliSearch (search.jannyai.com) and Hampter (janitorai.com/hampter) both
// respond with Access-Control-Allow-Origin: * — they can be called directly
// from the browser. Using a CORS proxy would strip the Authorization header
// and cause 401 errors. All calls below use useProxy=false.

// ─── Token Management ─────────────────────────────────────────────────────────

async function fetchSearchToken() {
    try {
        const html = await catalogGetText(`${BASE_URL}/characters/search`, {
            'Origin': BASE_URL,
            'Referer': `${BASE_URL}/`
        });

        // Try client-config JS file first
        let configPath = null;
        const configMatch = html.match(/client-config\.[a-zA-Z0-9_-]+\.js/);
        if (configMatch) {
            configPath = `/_astro/${configMatch[0]}`;
        } else {
            // Fallback: look for SearchPage bundle which imports client-config
            const spMatch = html.match(/SearchPage\.[a-zA-Z0-9_-]+\.js/);
            if (spMatch) {
                const spJs = await catalogGetText(`${BASE_URL}/_astro/${spMatch[0]}`, {
                    'Referer': `${BASE_URL}/`
                });
                const impMatch = spJs.match(/client-config\.[a-zA-Z0-9_-]+\.js/);
                if (impMatch) configPath = `/_astro/${impMatch[0]}`;
            }
        }

        if (configPath) {
            const configJs = await catalogGetText(`${BASE_URL}${configPath}`, {
                'Referer': `${BASE_URL}/`
            });
            // Extract 64-char hex token
            const tokenMatch = configJs.match(/"([a-f0-9]{64})"/);
            if (tokenMatch) return tokenMatch[1];
        }

        return FALLBACK_TOKEN;
    } catch {
        return FALLBACK_TOKEN;
    }
}

async function getSearchToken() {
    const cached = localStorage.getItem(TOKEN_KEY);
    if (cached) return cached;

    const token = await fetchSearchToken();
    localStorage.setItem(TOKEN_KEY, token);
    return token;
}

function clearSearchToken() {
    localStorage.removeItem(TOKEN_KEY);
}

// ─── Search ───────────────────────────────────────────────────────────────────

const JANNY_HEADERS = (token) => ({
    'Accept': '*/*',
    'Authorization': `Bearer ${token}`,
    'Origin': BASE_URL,
    'Referer': `${BASE_URL}/`,
    'x-meilisearch-client': 'Meilisearch instant-meilisearch (v0.19.0) ; Meilisearch JavaScript (v0.41.0)'
});

/**
 * Search JanitorAI characters via MeiliSearch.
 *
 * CORS: search.jannyai.com returns Access-Control-Allow-Origin: *
 * so the request goes DIRECTLY (useProxy=false). Using a proxy would
 * strip the Authorization header and cause 401 errors.
 *
 * Sort values supported by MeiliSearch:
 *   newest       → createdAtStamp:desc (default)
 *   oldest       → createdAtStamp:asc
 *   tokens_desc  → totalToken:desc
 *   tokens_asc   → totalToken:asc
 *   relevant     → no sort (MeiliSearch relevance ranking)
 *   popular      → NOT supported here; use janitorHampterSearch instead
 *   trending     → NOT supported here; use janitorHampterSearch instead
 *
 * @param {{ query?: string, page?: number, sort?: string, filters?: object }} opts
 */
export async function janitorSearch({ query = '', page = 1, sort = 'newest', filters = {} } = {}) {
    let token = await getSearchToken();

    const meiliFilters = [];
    const minTok = filters.minTokens !== undefined ? filters.minTokens : 29;
    meiliFilters.push(`totalToken >= ${minTok}`);
    if (filters.maxTokens !== undefined) meiliFilters.push(`totalToken <= ${filters.maxTokens}`);
    if (filters.nsfw === false) meiliFilters.push('isNsfw = false');
    if (filters.tagIds?.length) {
        const tagClauses = filters.tagIds.map(id => `tagIds = ${id}`);
        meiliFilters.push(tagClauses.join(' AND '));
    }

    const activeSort = filters.sort || sort;
    const sortMap = {
        newest: ['createdAtStamp:desc'],
        oldest: ['createdAtStamp:asc'],
        tokens_desc: ['totalToken:desc'],
        tokens_asc: ['totalToken:asc'],
        relevant: [] // empty = MeiliSearch relevance ranking
    };
    const sortArr = sortMap[activeSort] ?? sortMap.newest;

    const body = {
        queries: [{
            indexUid: 'janny-characters',
            q: query,
            facets: ['isLowQuality', 'isNsfw', 'tagIds', 'totalToken'],
            attributesToCrop: ['description:300'],
            cropMarker: '...',
            filter: meiliFilters.length > 0 ? meiliFilters : undefined,
            attributesToHighlight: ['name', 'description'],
            hitsPerPage: 40,
            page
        }]
    };
    // Only attach sort when we have a non-empty array (relevant mode omits it)
    if (sortArr.length > 0) body.queries[0].sort = sortArr;

    try {
        // useProxy=false: ACAO:* means direct fetch works; proxy strips Authorization
        const data = await catalogPost(SEARCH_URL, body, JANNY_HEADERS(token), false);
        const result = data.results?.[0] || {};
        return {
            characters: (result.hits || []).map(normalizeSearchHit),
            total: result.totalHits || 0,
            totalPages: result.totalPages || 1
        };
    } catch (e) {
        if (e.status === 401 || e.status === 403) {
            // Token expired — clear and retry with fallback
            clearSearchToken();
            token = FALLBACK_TOKEN;
            const data = await catalogPost(SEARCH_URL, body, JANNY_HEADERS(token), false);
            const result = data.results?.[0] || {};
            return {
                characters: (result.hits || []).map(normalizeSearchHit),
                total: result.totalHits || 0,
                totalPages: result.totalPages || 1
            };
        }
        throw e;
    }
}

/**
 * Browse via Hampter API — used for 'trending' and 'popular' sort modes.
 *
 * CORS: janitorai.com/hampter returns Access-Control-Allow-Origin: *
 * so the request goes DIRECTLY (useProxy=false).
 *
 * @param {{ query?: string, page?: number, sort?: 'trending'|'popular', filters?: object }} opts
 */
export async function janitorHampterSearch({ query = '', page = 1, sort = 'trending', filters = {} } = {}) {
    let sortMode = 'trending';
    const activeSort = filters.sort || sort;

    if (activeSort === 'popular') sortMode = 'popular';
    else if (activeSort === 'trending_week') sortMode = 'trending';
    else if (activeSort === 'trending_24h') sortMode = 'trending24';
    else sortMode = activeSort; // fallback to generic

    const params = new URLSearchParams({ sort: sortMode, page: String(page) });
    if (query) params.set('search', query);
    if (filters.nsfw === false) params.set('mode', 'sfw');

    // Add tags
    if (filters.tagIds && filters.tagIds.length > 0) {
        const tagNames = tagIdsToNames(filters.tagIds);
        for (const tagName of tagNames) {
            // Janitor tags in URL are generally lowercase representation of the string
            // e.g. "Science Fiction" -> "science-fiction", or just lowercase the name.
            // Often it's simple lowercasing and trimming spaces/slashes depending on their format.
            // Janitor uses the exact tag slug
            let slug = tagName.toLowerCase().replace(/\s+/g, '').replace(/[/_]/g, '');
            if (tagName === 'Sci-Fi') slug = 'scifi';
            else if (tagName === 'Slice of Life') slug = 'sliceoflife';
            else if (tagName === 'Movies/TV') slug = 'moviestv';
            else if (tagName === 'Demi-Human') slug = 'demihuman';
            else if (tagName === 'Non-binary') slug = 'nonbinary';
            else if (tagName === 'Non-human') slug = 'nonhuman';
            else if (tagName === 'Non-English') slug = 'nonenglish';
            else if (tagName === 'Monster Girl') slug = 'monstergirl';
            else if (tagName === 'Enemies to Lovers') slug = 'enemiestolovers';

            params.append('custom_tags[]', slug);
        }
    }

    // useProxy=false: ACAO:* means direct fetch works fine
    const data = await catalogGet(`${HAMPTER_URL}?${params}`, {
        'Origin': 'https://janitorai.com',
        'Referer': 'https://janitorai.com/'
    }, false);

    const hits = Array.isArray(data) ? data : (data.characters || data.data || []);
    return {
        characters: hits.map(normalizeHampterHit),
        total: data.total || hits.length,
        totalPages: 1
    };
}

// ─── Character Details (HTML scrape) ─────────────────────────────────────────

/**
 * Fetch full character details from JanitorAI page.
 * Returns Glaze-compatible character data.
 * @param {string} id Character UUID
 * @param {string} slug Character slug
 */
export async function janitorFetchCharacter(id, slug) {
    const url = `${BASE_URL}/characters/${id}_${slug}`;
    const html = await catalogGetText(url, {
        'Accept': 'text/html,application/xhtml+xml',
        'Origin': BASE_URL,
        'Referer': `${BASE_URL}/`
    });
    return parseAstroCharacter(html);
}

// ─── Astro Island Parser ──────────────────────────────────────────────────────

/**
 * Decode Astro's custom [type, data] encoding.
 * type 0 = object, 1 = array, others = raw value
 */
function decodeAstroValue(val) {
    if (!Array.isArray(val) || val.length < 2) return val;
    const [type, data] = val;
    if (type === 0) {
        if (!data || typeof data !== 'object') return data;
        const keys = Object.keys(data);
        // Compact string: all-numeric keys → reconstruct string from char map
        if (keys.length > 0 && keys.every(k => /^\d+$/.test(k))) {
            const maxIdx = Math.max(...keys.map(Number));
            const arr = new Array(maxIdx + 1).fill('');
            for (const k of keys) arr[Number(k)] = data[k];
            return arr.join('');
        }
        const obj = {};
        for (const [k, v] of Object.entries(data)) {
            obj[k] = decodeAstroValue(v);
        }
        return obj;
    }
    if (type === 1) {
        return data.map(decodeAstroValue);
    }
    return data;
}

function parseAstroCharacter(html) {
    // Find astro-island elements with props
    const islandRegex = /<astro-island[^>]+props="([^"]+)"[^>]*>/g;
    let match;

    while ((match = islandRegex.exec(html)) !== null) {
        try {
            const propsJson = match[1].replace(/&quot;/g, '"').replace(/&#34;/g, '"').replace(/&amp;/g, '&');
            const props = JSON.parse(propsJson);
            const decoded = decodeAstroValue([0, props]);

            // Look for character data in decoded props
            const char = findCharacterInProps(decoded);
            if (char) return convertJanitorToGlaze(char);
        } catch {
            // Try next island
        }
    }

    throw new Error('Could not parse character data from JanitorAI page');
}

function findCharacterInProps(obj, depth = 0) {
    if (depth > 6) return null;
    if (!obj || typeof obj !== 'object') return null;

    // Check if this object looks like a character
    if (obj.name && (obj.personality !== undefined || obj.description !== undefined) && obj.id) {
        return obj;
    }

    for (const val of Object.values(obj)) {
        const found = findCharacterInProps(val, depth + 1);
        if (found) return found;
    }
    return null;
}

// ─── Normalization ────────────────────────────────────────────────────────────

function resolveJanitorAvatar(url) {
    if (!url) return null;
    if (url.startsWith('http')) return url;
    if (url.startsWith('/')) return `https://image.jannyai.com${url}`;
    // Filename (no slashes) → bot-avatars CDN path
    if (!url.includes('/')) return `https://image.jannyai.com/bot-avatars/${url}`;
    return `https://image.jannyai.com/${url}`;
}

// Static JanitorAI tag ID → name map (source: janny-api.js from SillyTavern-CharacterLibrary)
const TAG_MAP = {
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

function tagIdsToNames(tagIds) {
    if (!Array.isArray(tagIds)) return [];
    return tagIds.map(id => TAG_MAP[id]).filter(Boolean);
}

function normalizeSearchHit(hit) {
    return {
        id: hit.id,
        name: hit.name || 'Unknown',
        avatarUrl: resolveJanitorAvatar(hit.avatar),
        tags: tagIdsToNames(hit.tagIds),
        tokens: hit.totalToken || 0,
        creator: hit.creatorUsername || '',
        nsfw: Boolean(hit.isNsfw),
        slug: hit.slug || hit.name?.toLowerCase().replace(/\s+/g, '-') || hit.id,
        source: 'janitor'
    };
}

function normalizeHampterHit(hit) {
    let rawTags = [];
    if (Array.isArray(hit.tags)) {
        rawTags = hit.tags.map(t => typeof t === 'string' ? t : (t.name || t.slug))
            .map(t => String(t).replace(/[\u{1F300}-\u{1FFFF}\u{2600}-\u{27BF}\uFE0F\u200D]+/gu, '').trim())
            .filter(Boolean);
    } else {
        rawTags = tagIdsToNames(hit.tagIds || []);
    }

    const chatCount = hit.stats?.chat || hit.public_chat_count || 0;
    const msgCount = hit.stats?.message || hit.public_message_count || 0;

    return {
        id: hit.id,
        name: hit.name || hit.bot_name || 'Unknown',
        avatarUrl: resolveJanitorAvatar(hit.avatar || hit.image),
        tags: rawTags,
        tokens: hit.totalToken || hit.total_tokens || 0,
        stats: { chat: chatCount, message: msgCount },
        creator: hit.creatorUsername || hit.creator || '',
        nsfw: Boolean(hit.isNsfw),
        slug: hit.slug || hit.id,
        source: 'janitor'
    };
}

function convertJanitorToGlaze(char) {
    // JanitorAI field mapping (differs from V2 spec):
    // char.personality → description (the actual character definition)
    // char.description → creator_notes (the "about" blurb shown on page)
    return {
        name: char.name || 'Unknown',
        description: char.personality || char.description || '',
        personality: '',
        scenario: char.scenario || '',
        first_mes: char.firstMessage || char.first_mes || '',
        mes_example: char.exampleDialogs || char.mes_example || '',
        creator_notes: char.description || '',
        system_prompt: '',
        post_history_instructions: '',
        alternate_greetings: [],
        tags: tagIdsToNames(char.tagIds || []),
        creator: char.creatorUsername || '',
        character_book: null,
        extensions: { janitor: { id: char.id } }
    };
}
