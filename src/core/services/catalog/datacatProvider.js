/**
 * DataCat (datacat.run) provider.
 * Anonymous session via deviceToken → sessionToken.
 * All API calls go through catalogHttp (CapacitorHttp on native, corsproxy on web).
 */
import { catalogGet, catalogPost } from './catalogHttp.js';

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
 * @param {{ page?: number, limit?: number, tagIds?: number[], nsfw?: boolean }} opts
 */
export async function datacatBrowse({ page = 1, limit = 24, tagIds = [], nsfw = false } = {}) {
    const token = await getToken();
    const offset = (page - 1) * limit;
    const params = new URLSearchParams({
        limit: String(limit),
        offset: String(offset),
        summary: '1',
        minTotalTokens: String(MIN_TOKENS)
    });
    if (tagIds.length) params.set('tagIds', tagIds.join(','));
    if (!nsfw) params.set('nsfw', '0');

    const data = await catalogGet(`${BASE}/api/characters/recent-public?${params}`, authHeaders(token));
    return {
        characters: (data.characters || []).map(normalizeListItem),
        total: data.totalCount || 0
    };
}

/**
 * Get trending/fresh characters.
 * @returns {{ last24h: CatalogItem[], thisWeek: CatalogItem[] }}
 */
export async function datacatFresh() {
    const token = await getToken();
    const data = await catalogGet(
        `${BASE}/api/characters/fresh?summary=1&sortBy=score&limit24=20&limitWeek=20`,
        authHeaders(token)
    );
    return {
        last24h: (data.windows?.last24h?.characters || []).map(normalizeListItem),
        thisWeek: (data.windows?.thisWeek?.characters || []).map(normalizeListItem)
    };
}

/**
 * Search characters by query.
 */
export async function datacatSearch({ query, page = 1, limit = 24 } = {}) {
    const token = await getToken();
    const offset = (page - 1) * limit;
    const params = new URLSearchParams({
        limit: String(limit),
        offset: String(offset),
        summary: '1',
        minTotalTokens: String(MIN_TOKENS)
    });
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
    return {
        charData: convertToGlaze(raw),
        avatarUrl: raw.avatar || null
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
    const data = await catalogGet(`${BASE}/api/extraction/status`, authHeaders(token));
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

function normalizeListItem(c) {
    return {
        id: c.character_id || c.id,
        name: c.name || 'Unknown',
        avatarUrl: c.avatar || null,
        tags: (c.tags || []).map(t => (typeof t === 'string' ? stripEmoji(t) : stripEmoji(t.name))).filter(Boolean),
        tokens: c.total_tokens || 0,
        creator: c.creator_name || '',
        nsfw: Boolean(c.is_nsfw),
        source: 'datacat'
    };
}

function convertToGlaze(raw) {
    const tags = (raw.tags || [])
        .map(t => (typeof t === 'string' ? stripEmoji(t) : stripEmoji(t?.name)))
        .filter(Boolean);

    return {
        name: raw.name || 'Unknown',
        description: raw.description || '',
        personality: raw.personality || '',
        scenario: raw.scenario || '',
        first_mes: raw.first_mes || raw.first_message || '',
        mes_example: raw.mes_example || '',
        creator_notes: raw.creator_notes || '',
        system_prompt: raw.system_prompt || '',
        post_history_instructions: raw.post_history_instructions || '',
        alternate_greetings: Array.isArray(raw.alternate_greetings) ? raw.alternate_greetings : [],
        tags,
        creator: raw.creator || '',
        character_book: raw.character_book || null,
        extensions: { datacat: { id: raw.character_id || raw.id } }
    };
}
