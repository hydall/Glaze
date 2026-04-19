/**
 * DataCat (datacat.run) provider.
 * Anonymous session via deviceToken → sessionToken.
 * All API calls go through catalogHttp (CapacitorHttp on native, corsproxy on web).
 */
import { catalogGet, catalogPost } from './catalogHttp.js';
import { janitorHampterSearch } from './janitorProvider.js';

const BASE = 'https://datacat.run';
const KEY_DEVICE = 'gz_dc_device';
const KEY_TOKEN = 'gz_dc_token';

// ─── Session ──────────────────────────────────────────────────────────────────

function getDeviceToken() {
    let token = localStorage.getItem(KEY_DEVICE);
    if (!token) {
        // Generate a UUID v4
        token = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
            const r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        });
        localStorage.setItem(KEY_DEVICE, token);
    }
    return token;
}

function getSessionToken() {
    return localStorage.getItem(KEY_TOKEN);
}

function setSessionToken(token) {
    localStorage.setItem(KEY_TOKEN, token);
}

/**
 * Initialize anonymous DataCat session. Stores sessionToken in localStorage.
 * @returns {Promise<string>} sessionToken
 */
export async function datacatInit() {
    const deviceToken = getDeviceToken();
    const data = await catalogPost(`${BASE}/api/liberator/identify`, { deviceToken }, {
        'Origin': 'https://datacat.run',
        'Referer': 'https://datacat.run/'
    });
    if (!data?.sessionToken) throw new Error('DataCat: no sessionToken in response');
    setSessionToken(data.sessionToken);
    return data.sessionToken;
}

/**
 * Returns a valid sessionToken, initializing if needed.
 */
async function getToken() {
    let token = getSessionToken();
    if (!token) token = await datacatInit();
    return token;
}

function authHeaders(token) {
    return {
        'X-Session-Token': token,
        'Origin': 'https://datacat.run',
        'Referer': 'https://datacat.run/'
    };
}

/**
 * Validate current session token.
 * @returns {Promise<boolean>}
 */
export async function datacatValidate() {
    const token = getSessionToken();
    if (!token) return false;
    try {
        await catalogGet(`${BASE}/api/characters/recent-public?limit=1&summary=1`, authHeaders(token));
        return true;
    } catch (e) {
        if (e.status === 401 || e.status === 403) {
            localStorage.removeItem(KEY_TOKEN);
            return false;
        }
        return true; // network error — assume still valid
    }
}

/**
 * Ensure session is valid; re-init if not.
 */
export async function datacatEnsureSession() {
    const valid = await datacatValidate();
    if (!valid) await datacatInit();
}

// ─── Browse / Search ──────────────────────────────────────────────────────────

const MIN_TOKENS = 889;

/**
 * Browse recent public characters.
 *
 * NOTE: /api/characters/recent-public does NOT support sortBy.
 * For 'popular', 'trending_week', or 'trending_24h', use datacatFresh() directly.
 *
 * @param {{ page?: number, limit?: number, tagIds?: number[], nsfw?: boolean, filters?: object }} opts
 */
export async function datacatBrowse({ page = 1, limit = 24, tagIds = [], nsfw = false, filters = {} } = {}) {
    const activeSort = filters.sort;

    // popular / trending sorts are served by JanitorAI hampter to support pagination
    if (activeSort === 'popular' || activeSort === 'trending_week' || activeSort === 'trending_24h') {
        const res = await janitorHampterSearch({ query: '', page, sort: activeSort, filters });
        res.characters.forEach(c => c.source = 'datacat');
        return res;
    }

    const token = await getToken();
    const offset = (page - 1) * limit;
    const minTok = filters.minTokens ?? MIN_TOKENS;
    const isNsfw = filters.nsfw !== undefined ? filters.nsfw : nsfw;
    const filterTagIds = filters.tagIds?.length ? filters.tagIds : tagIds;

    const params = new URLSearchParams({
        limit: String(limit),
        offset: String(offset),
        summary: '1',
        minTotalTokens: String(minTok)
    });
    if (filters.maxTokens) params.set('maxTotalTokens', String(filters.maxTokens));
    if (filterTagIds.length) params.set('tagIds', filterTagIds.join(','));
    if (!isNsfw) params.set('nsfw', '0');

    const data = await catalogGet(`${BASE}/api/characters/recent-public?${params}`, authHeaders(token));
    return {
        characters: (data.characters || []).map(normalizeListItem),
        total: data.totalCount || 0
    };
}

/**
 * Get trending/fresh characters.
 *
 * @param {{ sortBy?: 'score'|'fresh'|'chat_count', window?: 'all'|'last24h'|'thisWeek', limit24?: number, limitWeek?: number }} opts
 *   sortBy='score'      → DataCat AI scoring (trending)
 *   sortBy='chat_count' → most chatted (popular)
 *   sortBy='fresh'      → newest within each window
 *   window='all'        → merge both windows (default)
 *   window='last24h'    → only last 24h characters
 *   window='thisWeek'   → only this week characters
 * @returns {{ characters: CatalogItem[], total: number }}
 */
export async function datacatFresh({ sortBy = 'score', window = 'all', limit24 = 80, limitWeek = 40 } = {}) {
    const token = await getToken();
    const data = await catalogGet(
        `${BASE}/api/characters/fresh?summary=1&sortBy=${sortBy}&limit24=${limit24}&limitWeek=${limitWeek}`,
        authHeaders(token)
    );

    const last24h = (data.windows?.last24h?.characters || []).map(normalizeListItem);
    const thisWeek = (data.windows?.thisWeek?.characters || []).map(normalizeListItem);

    if (window === 'last24h') {
        return { characters: last24h, total: last24h.length };
    } else if (window === 'thisWeek') {
        return { characters: thisWeek, total: thisWeek.length };
    } else {
        // 'all': merge both, dedupe by id, sort by the requested criterion
        const seen = new Set();
        const merged = [];
        for (const c of [...thisWeek, ...last24h]) {
            if (!seen.has(c.id)) { seen.add(c.id); merged.push(c); }
        }
        return { characters: merged, total: merged.length };
    }
}

/**
 * Search characters by query.
 */
export async function datacatSearch({ query, page = 1, limit = 24, filters = {} } = {}) {
    const token = await getToken();
    const offset = (page - 1) * limit;
    const minTok = filters.minTokens ?? MIN_TOKENS;
    const isNsfw = filters.nsfw !== undefined ? filters.nsfw : false;
    const filterTagIds = filters.tagIds || [];

    const params = new URLSearchParams({
        limit: String(limit),
        offset: String(offset),
        summary: '1',
        minTotalTokens: String(minTok)
    });
    if (filters.maxTokens) params.set('maxTotalTokens', String(filters.maxTokens));
    if (!isNsfw) params.set('nsfw', '0');
    if (filterTagIds.length) params.set('tagIds', filterTagIds.join(','));
    if (query) params.set('search', query);

    const data = await catalogGet(`${BASE}/api/characters/recent-public?${params}`, authHeaders(token));
    return {
        characters: (data.characters || []).map(normalizeListItem),
        total: data.totalCount || 0
    };
}

// ─── Character Download ───────────────────────────────────────────────────────

/**
 * Download a character card in V2-like format and convert to Glaze schema.
 * @param {string} uuid
 * @returns {Promise<{ charData: object, avatarUrl: string }>}
 */
export async function datacatGetCharacter(uuid) {
    const token = await getToken();
    const ts = Date.now();
    const data = await catalogGet(
        `${BASE}/api/characters/${uuid}/download?t=${ts}`,
        authHeaders(token)
    );

    const raw = data.data || data;
    const meta = data.metadata || {};
    return {
        charData: convertToGlaze(raw, meta),
        avatarUrl: resolveAvatarUrl(raw.avatar)
    };
}

// ─── JanitorAI Extraction ─────────────────────────────────────────────────────

const IDEMPOTENCY_KEY = () => 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
});

/**
 * Submit a JanitorAI character URL for cloud-browser extraction via DataCat.
 * @param {string} janitorUrl e.g. https://janitorai.com/characters/{uuid}
 * @param {boolean} publicFeed Whether to appear on DataCat public feed
 * @returns {Promise<{ queued: boolean, started: boolean, queuePosition: number }>}
 */
export async function datacatExtract(janitorUrl, publicFeed = true) {
    const token = await getToken();
    return catalogPost(
        `${BASE}/api/character/smart-extract-v2`,
        {
            url: janitorUrl,
            appearOnPublicFeed: publicFeed,
            useSeparateWorkerServer: true,
            inlinePostExtractCreatorProfile: true,
            idempotencyKey: IDEMPOTENCY_KEY()
        },
        authHeaders(token)
    );
}

/**
 * Poll extraction status.
 * @returns {Promise<{ inProgress: object|null, queue: object[], history: object[] }>}
 */
export async function datacatExtractionStatus() {
    const token = await getToken();
    const ts = Date.now();
    const data = await catalogGet(`${BASE}/api/extraction/status?t=${ts}`, authHeaders(token));
    return {
        inProgress: data.inProgress || null,
        queue: data.queue || [],
        history: data.history || []
    };
}

// ─── Normalization ────────────────────────────────────────────────────────────

function stripEmoji(str) {
    if (!str) return str;
    return str.replace(/[\u{1F300}-\u{1FFFF}\u{2600}-\u{27BF}\uFE0F\u200D\s]+/gu, '').trim();
}

const IMAGE_BASE = 'https://ella.janitorai.com/bot-avatars/';

function resolveAvatarUrl(url) {
    if (!url) return null;
    if (url.startsWith('http')) return url;
    return IMAGE_BASE + url;
}

function normalizeListItem(c) {
    const stdTags = (c.tags || []).map(t => (typeof t === 'string' ? stripEmoji(t) : stripEmoji(t.name))).filter(Boolean);
    const tags = [c.is_nsfw ? 'NSFW' : 'SFW', ...stdTags];

    return {
        // API returns character_id (UUID) as the primary identifier
        id: c.character_id || c.characterId || c.uuid || c.id,
        name: c.chat_name || c.chatName || c.name || 'Unknown',
        avatarUrl: resolveAvatarUrl(c.avatar),
        tags: [...new Set(tags)],
        tokens: c.total_tokens || c.totalTokens || 0,
        stats: { chat: c.chat_count || 0, message: c.message_count || 0 },
        creator: c.creator_name || c.creatorName || '',
        creator_id: c.creator_id || c.creatorId || '',
        nsfw: Boolean(c.is_nsfw),
        source: 'datacat'
    };
}

function convertToGlaze(raw, meta = {}) {
    const stdTags = (raw.tags || [])
        .map(t => (typeof t === 'string' ? stripEmoji(t) : stripEmoji(t?.name)))
        .filter(Boolean);

    const tags = [raw.is_nsfw ? 'NSFW' : 'SFW', ...stdTags];

    return {
        name: raw.name || raw.chatName || raw.chat_name || 'Unknown',
        description: raw.personality || raw.description || '',
        personality: '',
        scenario: raw.scenario || '',
        first_mes: raw.first_mes || raw.first_message || '',
        mes_example: raw.mes_example || '',
        creator_notes: meta.raw_description_html || raw.creator_notes || raw.description || '',
        system_prompt: raw.system_prompt || '',
        post_history_instructions: raw.post_history_instructions || '',
        alternate_greetings: Array.isArray(raw.alternate_greetings) ? raw.alternate_greetings : [],
        tags: [...new Set(tags)],
        creator: meta.janitor_creator_name || raw.creator || '',
        creator_id: meta.janitor_creator_id || raw.creator_id || raw.creatorId || '',
        character_book: raw.character_book || null,
        extensions: { datacat: { id: raw.characterId || raw.character_id || raw.uuid || raw.id } }
    };
}
