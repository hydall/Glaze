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

// ─── Token Management ─────────────────────────────────────────────────────────

async function fetchSearchToken() {
    try {
        const html = await catalogGetText(`${BASE_URL}/characters/search`, {
            'Origin': BASE_URL,
            'Referer': `${BASE_URL}/`
        });

        // Find client-config JS file
        const configMatch = html.match(/client-config\.[a-f0-9]+\.js/);
        if (!configMatch) return FALLBACK_TOKEN;

        const configJs = await catalogGetText(`${BASE_URL}/_astro/${configMatch[0]}`, {
            'Referer': `${BASE_URL}/`
        });

        // Extract 64-char hex token
        const tokenMatch = configJs.match(/["']([0-9a-f]{64})["']/);
        return tokenMatch ? tokenMatch[1] : FALLBACK_TOKEN;
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
    'Authorization': `Bearer ${token}`,
    'Origin': BASE_URL,
    'Referer': `${BASE_URL}/`,
    'x-meilisearch-client': 'Meilisearch instant-meilisearch (v0.19.0)'
});

/**
 * Search JanitorAI characters via MeiliSearch.
 * @param {{ query?: string, page?: number, sort?: string }} opts
 */
export async function janitorSearch({ query = '', page = 1, sort = 'createdAtStamp:desc' } = {}) {
    let token = await getSearchToken();

    const body = {
        queries: [{
            indexUid: 'janny-characters',
            q: query,
            facets: ['isLowQuality', 'tagIds', 'totalToken'],
            attributesToCrop: ['description:300'],
            cropMarker: '...',
            filter: ['totalToken <= 4101 AND totalToken >= 29'],
            attributesToHighlight: ['name', 'description'],
            hitsPerPage: 40,
            page,
            sort: [sort]
        }]
    };

    try {
        const data = await catalogPost(SEARCH_URL, body, JANNY_HEADERS(token));
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
            const data = await catalogPost(SEARCH_URL, body, JANNY_HEADERS(token));
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
 * Fallback: search via Hampter API (no auth needed).
 */
export async function janitorHampterSearch({ query = '', page = 1, sort = 'trending' } = {}) {
    const params = new URLSearchParams({ sort, page: String(page) });
    if (query) params.set('search', query);

    const data = await catalogGet(`${HAMPTER_URL}?${params}`, {
        'Origin': 'https://janitorai.com',
        'Referer': 'https://janitorai.com/'
    });

    const hits = Array.isArray(data) ? data : (data.characters || data.data || []);
    return {
        characters: hits.map(normalizeHampterHit),
        total: hits.length,
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
        // Object
        const obj = {};
        for (const [k, v] of Object.entries(data)) {
            obj[k] = decodeAstroValue(v);
        }
        return obj;
    }
    if (type === 1) {
        // Array
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

// Static JanitorAI tag ID → name map
const TAG_MAP = {
    1: 'Male', 2: 'Female', 3: 'Non-binary', 4: 'Human', 5: 'Anime', 6: 'Fantasy',
    7: 'Sci-Fi', 8: 'Action', 9: 'Adventure', 10: 'Romance', 11: 'Horror',
    12: 'Comedy', 13: 'Drama', 14: 'Slice of Life', 15: 'NSFW', 16: 'OC',
    17: 'Fictional', 18: 'Historical', 19: 'Realistic', 20: 'Games',
    21: 'Movies', 22: 'Vampire', 23: 'Werewolf', 24: 'Elf', 25: 'Robot',
    26: 'Animal', 27: 'Furry', 28: 'Magic', 29: 'Mythology', 30: 'Superhero',
    50: 'Villainess', 51: 'Tsundere', 52: 'Yandere', 53: 'Kuudere', 54: 'Dandere'
};

function tagIdsToNames(tagIds) {
    if (!Array.isArray(tagIds)) return [];
    return tagIds.map(id => TAG_MAP[id]).filter(Boolean);
}

function normalizeSearchHit(hit) {
    return {
        id: hit.id,
        name: hit.name || 'Unknown',
        avatarUrl: hit.avatar || null,
        tags: tagIdsToNames(hit.tagIds),
        tokens: hit.totalToken || 0,
        creator: hit.creatorUsername || '',
        nsfw: Boolean(hit.isNsfw),
        slug: hit.slug || hit.name?.toLowerCase().replace(/\s+/g, '-') || hit.id,
        source: 'janitor'
    };
}

function normalizeHampterHit(hit) {
    return {
        id: hit.id,
        name: hit.name || hit.bot_name || 'Unknown',
        avatarUrl: hit.avatar || hit.image || null,
        tags: tagIdsToNames(hit.tagIds || []),
        tokens: hit.totalToken || 0,
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
