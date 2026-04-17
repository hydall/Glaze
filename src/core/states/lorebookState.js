import { reactive, watch } from 'vue';
import { db } from '@/utils/db.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { findTopK, findTopKMulti, cosineSimilarity } from '@/utils/vectorMath.js';

function escapeRegex(string) {
    return string.replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

const GLAZE_BOUNDARIES = '[\\s.,!?;:"\'\\u201C\\u201D\\u2018\\u2019\\u00AB\\u00BB(){}\\[\\]—–]';

function normalizeHybridText(text = '') {
    return text
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\s-]+/gu, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}

function getHybridTokens(text = '') {
    return normalizeHybridText(text)
        .split(' ')
        .filter(token => token.length >= 3);
}

function getEntryDescriptorTexts(entry) {
    const descriptors = [];
    if (entry.comment) descriptors.push(String(entry.comment));
    if (Array.isArray(entry.keys)) descriptors.push(...entry.keys.map(v => String(v)));

    const content = String(entry.content || '');
    if (content) {
        const lines = content
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(Boolean)
            .slice(0, 4);
        descriptors.push(...lines);
    }

    return descriptors;
}

function uniqueStrings(values = [], limit = 32) {
    const seen = new Set();
    const result = [];
    for (const value of values) {
        const raw = String(value || '').trim();
        const normalized = normalizeHybridText(raw);
        if (!normalized || seen.has(normalized)) continue;
        seen.add(normalized);
        result.push(raw);
        if (result.length >= limit) break;
    }
    return result;
}

function extractRetrievalHints(entry) {
    const hints = [];

    if (entry.comment) hints.push(String(entry.comment));
    if (Array.isArray(entry.keys)) hints.push(...entry.keys.map(v => String(v)));

    const content = String(entry.content || '');
    if (content) {
        const lines = content
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(Boolean)
            .slice(0, 8);

        hints.push(...lines);

        for (const line of lines) {
            const colonIndex = line.indexOf(':');
            if (colonIndex > 0) {
                const label = line.slice(0, colonIndex).trim();
                const value = line.slice(colonIndex + 1).trim();
                if (label) hints.push(label);
                if (value) {
                    hints.push(value);
                    value.split(/[;,]|\band\b|\bи\b/iu)
                        .map(part => part.trim())
                        .filter(Boolean)
                        .forEach(part => hints.push(part));
                }
            }
        }
    }

    return uniqueStrings(hints, 32);
}

function buildEmbeddingRecord(entry, lorebookId, vectorsData, textHash) {
    return {
        id: entry.id,
        sourceType: 'lorebook_entry',
        sourceId: lorebookId,
        vectors: vectorsData,  // NEW: array of {text, vector} chunks
        vector: null,  // Legacy field set to null for new records
        textHash,
        retrievalHints: extractRetrievalHints(entry),
        updatedAt: Date.now()
    };
}

function buildEmbeddingErrorRecord(entry, lorebookId, textHash, error) {
    return {
        id: entry.id,
        sourceType: 'lorebook_entry',
        sourceId: lorebookId,
        vectors: null,  // NEW: null for error records
        vector: null,  // Legacy field
        textHash,
        retrievalHints: extractRetrievalHints(entry),
        error,
        updatedAt: Date.now()
    };
}

function getIndexingErrorDetails(type, message = '') {
    const safeMessage = String(message || '').trim();
    return {
        type,
        message: safeMessage,
        retryable: !['empty_text', 'missing_entry_id'].includes(type),
        updatedAt: Date.now()
    };
}

function classifyIndexingError(error) {
    const message = String(error?.message || error || '').trim();
    const lower = message.toLowerCase();

    if (lower.includes('timeout') || lower.includes('timed out') || lower.includes('abort')) {
        return getIndexingErrorDetails('timeout', message || 'Embedding request timed out');
    }
    if (lower.includes('endpoint not configured')) {
        return getIndexingErrorDetails('config_endpoint', message || 'Embedding endpoint not configured');
    }
    if (lower.includes('model not configured')) {
        return getIndexingErrorDetails('config_model', message || 'Embedding model not configured');
    }
    if (lower.includes('embedding api error')) {
        return getIndexingErrorDetails('api_error', message || 'Embedding API request failed');
    }
    if (lower.includes('failed to fetch') || lower.includes('networkerror') || lower.includes('network error')) {
        return getIndexingErrorDetails('network_error', message || 'Network error while requesting embeddings');
    }
    if (lower.includes('invalid embedding response')) {
        return getIndexingErrorDetails('invalid_response', message || 'Embedding API returned an invalid response');
    }

    return getIndexingErrorDetails('unknown', message || 'Unknown indexing error');
}

function getEntryIndexingText(entry, target) {
    return (target === 'keys'
        ? (entry.keys || []).join(', ')
        : (entry.content || '')).trim();
}

async function saveEmbeddingError(entry, lorebookId, textHash, error) {
    await db.saveEmbedding(buildEmbeddingErrorRecord(entry, lorebookId, textHash, error));
}

function buildEmbeddingFingerprint(entry, text) {
    return JSON.stringify({
        text,
        retrievalHints: extractRetrievalHints(entry)
    });
}

function scoreHybridBoost(entry, queryText) {
    const normalizedQuery = normalizeHybridText(queryText);
    if (!normalizedQuery) return 0;

    const queryTokens = new Set(getHybridTokens(queryText));
    if (queryTokens.size === 0) return 0;

    let boost = 0;
    const names = [entry.comment, ...(Array.isArray(entry.keys) ? entry.keys : [])]
        .filter(Boolean)
        .map(value => String(value));

    for (const name of names) {
        const normalizedName = normalizeHybridText(name);
        if (!normalizedName) continue;

        if (normalizedQuery.includes(normalizedName)) {
            boost = Math.max(boost, 0.18);
        }

        const nameTokens = getHybridTokens(name);
        let overlap = 0;
        for (const token of nameTokens) {
            if (queryTokens.has(token)) overlap++;
        }

        if (overlap > 0) {
            boost = Math.max(boost, Math.min(0.12, overlap * 0.04));
        }
    }

    return boost;
}

function scoreDescriptorBoost(entry, queryText) {
    const queryTokens = new Set(getHybridTokens(queryText));
    if (queryTokens.size === 0) return 0;

    let boost = 0;
    const descriptors = [
        ...getEntryDescriptorTexts(entry),
        ...(Array.isArray(entry.retrievalHints) ? entry.retrievalHints : [])
    ];

    for (const descriptor of descriptors) {
        const descriptorTokens = getHybridTokens(descriptor);
        if (descriptorTokens.length === 0) continue;

        let overlap = 0;
        for (const token of descriptorTokens) {
            if (queryTokens.has(token)) overlap++;
        }

        if (overlap > 0) {
            boost = Math.max(boost, Math.min(0.1, overlap * 0.025));
        }
    }

    return boost;
}

// --- State Definition ---
export const lorebookState = reactive({
    lorebooks: [],
    globalSettings: {
        scanDepth: 1000,
        contextPercent: 100,
        budgetCap: 0,
        reserveMode: 'percent',
        reserveValue: 10,
        minActivations: 0,
        maxDepth: 0,
        maxRecursionSteps: 0,
        insertionStrategy: 'character_first', // character_first, global_first
        injectionPosition: 'worldInfoBefore',
        includeNames: true,
        recursiveScan: true,
        caseSensitive: false,
        matchWholeWords: false,
        useGroupScoring: false,
        alertOnOverflow: false
    },
    activations: {
        character: {},
        chat: {}
    },
    initialized: false,
});

// --- Actions ---

export async function initLorebookState(force = false) {
    if (lorebookState.initialized && !force) return;
    try {
        const data = await db.get('gz_lorebooks');
        lorebookState.lorebooks = [];
        lorebookState.activations = { character: {}, chat: {} };
        if (data) {
            if (Array.isArray(data)) {
                lorebookState.lorebooks = data;
            } else if (data.lorebooks) {
                // New format with settings
                lorebookState.lorebooks = data.lorebooks;
                if (data.settings) {
                    if (data.settings.reserveMode === undefined) {
                        data.settings.reserveMode = 'percent';
                    }
                    if (data.settings.reserveValue === undefined) {
                        const legacyBudget = Number(data.settings.budgetCap || 0);
                        const legacyPercent = Number(data.settings.contextPercent || 0);
                        data.settings.reserveValue = legacyBudget > 0 ? legacyBudget : Math.max(legacyPercent, 10);
                        if (legacyBudget <= 0 && legacyPercent > 0) {
                            data.settings.reserveMode = 'percent';
                        }
                    }
                    if (!data.settings.injectionPosition) {
                        data.settings.injectionPosition = 'worldInfoBefore';
                    }
                    Object.assign(lorebookState.globalSettings, data.settings);
                }
                if (data.activations) {
                    lorebookState.activations = data.activations;
                }
            }

            // Ensure every entry has a stable ID (backfill for older data)
            lorebookState.lorebooks.forEach(lb => {
                if (!Array.isArray(lb.entries)) return;
                lb.entries.forEach(entry => {
                    if (!entry.id) {
                        entry.id = Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
                    }
                    if (entry.position === 0) entry.position = 'worldInfoBefore';
                    if (entry.position === 1) entry.position = 'worldInfoAfter';
                    if (!entry.position) entry.position = 'matchGlobal';
                });
            });
        }
    } catch (e) {
        console.error('Failed to load lorebooks', e);
    }
    lorebookState.initialized = true;
}

export async function saveLorebooks() {
    await db.queuedSet('gz_lorebooks', {
        lorebooks: JSON.parse(JSON.stringify(lorebookState.lorebooks)),
        settings: JSON.parse(JSON.stringify(lorebookState.globalSettings)),
        activations: JSON.parse(JSON.stringify(lorebookState.activations))
    });
}

// Auto-save on changes with debounce to prevent rapid IndexedDB writes on keystroke
let _lorebookSaveTimer = null;
watch(() => lorebookState, () => {
    if (_lorebookSaveTimer) clearTimeout(_lorebookSaveTimer);
    _lorebookSaveTimer = setTimeout(() => {
        saveLorebooks();
        _lorebookSaveTimer = null;
    }, 500);
}, { deep: true });

// Call when closing the lorebook editor to flush any pending debounced save
export function flushLorebookSave() {
    if (_lorebookSaveTimer) {
        clearTimeout(_lorebookSaveTimer);
        _lorebookSaveTimer = null;
    }
    return saveLorebooks();
}

export function createLorebook(name = 'New World Info') {
    const newLb = {
        id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
        name,
        entries: [],
        enabled: true,
        insertion_order: 100, // SillyTavern default
    };
    lorebookState.lorebooks.push(newLb);
    return newLb;
}

export function deleteLorebook(id) {
    const idx = lorebookState.lorebooks.findIndex(lb => lb.id === id);
    if (idx !== -1) {
        lorebookState.lorebooks.splice(idx, 1);
    }
}

export function setLorebookActivation(lbId, scope, targetId) {
    if (scope === 'global') {
        const lb = lorebookState.lorebooks.find(l => l.id === lbId);
        if (lb) lb.enabled = !lb.enabled;
    } else if (scope === 'character') {
        if (!lorebookState.activations.character) lorebookState.activations.character = {};
        if (!lorebookState.activations.character[targetId]) lorebookState.activations.character[targetId] = [];

        const list = lorebookState.activations.character[targetId];
        const idx = list.indexOf(lbId);
        if (idx === -1) list.push(lbId);
        else list.splice(idx, 1);
    } else if (scope === 'chat') {
        if (!lorebookState.activations.chat) lorebookState.activations.chat = {};
        if (!lorebookState.activations.chat[targetId]) lorebookState.activations.chat[targetId] = [];

        const list = lorebookState.activations.chat[targetId];
        const idx = list.indexOf(lbId);
        if (idx === -1) list.push(lbId);
        else list.splice(idx, 1);
    }
    // Watcher handles saving
}

export function getActiveLorebooksForContext(charId, chatId) {
    return lorebookState.lorebooks
        .filter(lb => {
            if (lb.enabled) return true; // Global
            if (charId && lorebookState.activations?.character?.[charId]?.includes(lb.id)) return true; // Character
            if (chatId && lorebookState.activations?.chat?.[chatId]?.includes(lb.id)) return true; // Chat
            return false;
        })
        .map(lb => lb.name);
}

/**
 * Scans history for keywords in enabled lorebooks.
 * Handles recursion and advanced ST logic.
 */
export function scanLorebooks(history = [], char = null, textToScan = "", chatId = null) {
    const charId = char?.id;

    const activeLorebooks = lorebookState.lorebooks.filter(lb => {
        if (lb.enabled) return true; // Global
        if (charId && lorebookState.activations?.character?.[charId]?.includes(lb.id)) return true; // Character
        if (chatId && lorebookState.activations?.chat?.[chatId]?.includes(lb.id)) return true; // Chat
        return false;
    });

    if (activeLorebooks.length === 0) return [];

    let allRelevantEntries = [];

    // 1. Get all entries from active lorebooks
    let candidates = [];
    activeLorebooks.forEach(lb => {
        lb.entries.forEach(entry => {
            if (entry.enabled !== false) {
                if (char && entry.characterFilter) {
                    const { isExclude, names } = entry.characterFilter;
                    if (names && names.length > 0) {
                        const charName = (char.name || "").toLowerCase();
                        const isInCategory = names.some(n => charName.includes(n.toLowerCase()));
                        if (isExclude && isInCategory) return;
                        if (!isExclude && !isInCategory) return;
                    }
                }
                candidates.push({ ...entry, lorebookName: lb.name, lorebookId: lb.id });
            }
        });
    });

    // 2. Add Constant entries immediately
    candidates.filter(e => e.constant).forEach(entry => {
        if (!allRelevantEntries.some(e => e.id === entry.id)) {
            allRelevantEntries.push(entry);
        }
    });

    // 3. Scan Logic (with recursion support)
    let changed = true;
    let iteration = 0;
    const maxIterations = (lorebookState.globalSettings.recursiveScan === false) ? 1 : 5;

    while (changed && iteration < maxIterations) {
        changed = false;
        iteration++;

        for (const entry of candidates) {
            if (allRelevantEntries.some(e => e === entry)) continue;
            if (entry.constant) continue; // Already added

            const primaryKeys = entry.keys || [];
            const secondaryKeys = (entry.secondary_keys || entry.keysecondary) || [];
            const logic = entry.selectiveLogic ?? 5; // Default to Primary Only (5)

            // Match settings
            const caseSensitive = entry.caseSensitive ?? lorebookState.globalSettings.caseSensitive ?? false;
            const wholeWords = entry.matchWholeWords ?? lorebookState.globalSettings.matchWholeWords ?? false;

            const checkMatch = (key, text) => {
                if (!key) return false;
                const sourceText = `${text ?? ''}`;
                const sourceKey = `${key}`;
                const flags = caseSensitive ? '' : 'i';

                if (wholeWords === 'glaze') {
                    const escaped = escapeRegex(sourceKey);
                    const pattern = `(?:^|${GLAZE_BOUNDARIES})${escaped}(?:$|${GLAZE_BOUNDARIES})`;
                    try {
                        return new RegExp(pattern, flags).test(sourceText);
                    } catch (e) {
                        const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
                        const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
                        if (!needle) return false;
                        const escapedNeedle = escapeRegex(needle);
                        try {
                            return new RegExp(`(?:^|${GLAZE_BOUNDARIES})${escapedNeedle}(?:$|${GLAZE_BOUNDARIES})`, caseSensitive ? '' : 'i').test(haystack);
                        } catch (e2) {
                            return false;
                        }
                    }
                }

                let pattern = sourceKey;
                if (wholeWords) {
                    pattern = `\\b${pattern}\\b`;
                }
                try {
                    const regex = new RegExp(pattern, flags);
                    return regex.test(sourceText);
                } catch (e) {
                    const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
                    const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
                    if (!needle) return false;

                    if (wholeWords) {
                        const escaped = escapeRegex(needle);
                        const wordRegex = new RegExp(`\\b${escaped}\\b`, caseSensitive ? '' : 'i');
                        return wordRegex.test(haystack);
                    }

                    return haystack.includes(needle);
                }
            };

            const scanDepth = entry.scanDepth ?? 1;
            const messagesToScan = history.slice(-scanDepth).map(m => m.content).join("\n");

            // Only scan generated text (textToScan) if recursive scan is enabled OR it's the first iteration (static scan)
            // Wait, iteration 1 SHOULD scan textToScan (the current user input/last assistant message).
            const scanSource = caseSensitive ?
                (messagesToScan + textToScan) :
                (messagesToScan.toLowerCase() + textToScan.toLowerCase());

            // If recursiveScan is disabled, iteration 1 is enough. 
            // In iteration 1, textToScan contains ONLY what was passed to scanLorebooks initially.
            // In iteration 2+, textToScan contains added entry content.

            // Temporal Logic (Simplified history-based check)
            let isStickyActive = false;
            let isOnCooldown = false;

            if (entry.sticky > 0 || entry.cooldown > 0) {
                // Scan history
                for (let i = 1; i <= Math.max(entry.sticky || 0, entry.cooldown || 0); i++) {
                    const histMsg = history[history.length - i];
                    if (!histMsg) break;

                    const histSource = caseSensitive ? histMsg.content : histMsg.content.toLowerCase();
                    const wasMatched = primaryKeys.some(key => checkMatch(key, histSource));

                    if (wasMatched) {
                        if (i <= (entry.sticky || 0)) isStickyActive = true;
                        if (i <= (entry.cooldown || 0)) isOnCooldown = true;
                        break;
                    }
                }
            }

            if (isOnCooldown) continue;

            // 1. Primary Keywords check (OR between keys)
            const matchedPrimary = isStickyActive || primaryKeys.some(key => checkMatch(key, scanSource));

            if (matchedPrimary) {
                // 2. Secondary Keywords / Selective Logic
                let secondaryMatches = true;

                // Logic Mapping:
                // 0: AND Any (At least one secondary must match)
                // 1: AND All (ALL secondary must match)
                // 2: NOT Any (None of secondary must match)
                // 3: NOT All (Not ALL of secondary must match - i.e. at least one mismatch? Or NOT (ALL match))
                // 4: Primary Only (Ignore secondary)

                // If no secondary keys, AND/NOT logic behavior:
                // ST behavior: if Logic is AND and no keys, usually it matches (vacuously true or fails? usually fails if requires match).
                // Let's assume standard behavior:
                // If input is empty, ignore logic unless strictly required?
                // Actually, "Primary Only" means we skip this check.

                if (logic === 4 || secondaryKeys.length === 0) {
                    // Primary Only or no secondary keys - Always pass this stage
                    secondaryMatches = true;
                } else if (secondaryKeys.length > 0) {
                    const matches = secondaryKeys.map(key => checkMatch(key, scanSource));
                    const anyMatch = matches.some(m => m);
                    const allMatch = matches.every(m => m);

                    if (logic === 0) { // AND Any
                        secondaryMatches = anyMatch;
                    } else if (logic === 1) { // AND All
                        secondaryMatches = allMatch;
                    } else if (logic === 2) { // NOT Any (fail if ANY match)
                        secondaryMatches = !anyMatch;
                    } else if (logic === 3) { // NOT All (fail if ALL match)
                        secondaryMatches = !allMatch;
                    }
                }

                if (secondaryMatches) {
                    // 3. Probability check
                    if (entry.probability !== undefined && entry.probability < 100) {
                        if (Math.random() * 100 > entry.probability) continue;
                    }

                    allRelevantEntries.push(entry);

                    if (!entry.preventRecursion && iteration < maxIterations) {
                        textToScan += "\n" + (entry.content || "").toLowerCase();
                        changed = true;
                    }
                }
            }
        }
    }

    return allRelevantEntries.sort((a, b) => (a.order ?? 100) - (b.order ?? 100));
}

export async function importSTLorebook(json, fileName = 'Imported', options = {}) {
    try {
        const { enabled = true, activationScope = null, activationTargetId = null } = options;
        let normalizedEntries = [];
        const entriesRaw = json.entries || [];
        const glazeMetaEntries = json?.glazeMetadata?.entries || {};

        if (Array.isArray(entriesRaw)) {
            normalizedEntries = entriesRaw;
        } else if (typeof entriesRaw === 'object') {
            normalizedEntries = Object.values(entriesRaw);
        }

        const newLb = {
            id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
            name: json.name || fileName.replace('.json', ''),
            enabled,
            entries: normalizedEntries.map((entry, index) => {
                const rawKeys = entry.keys || entry.key || [];
                const rawSecondary = entry.secondary_keys || entry.keysecondary || [];
                const metadataPosition = glazeMetaEntries?.[index]?.position;
                const restoredPosition = (metadataPosition === 'worldInfoBefore' || metadataPosition === 'worldInfoAfter' || metadataPosition === 'lorebooksMacro' || metadataPosition === 'matchGlobal')
                    ? metadataPosition
                    : null;
                return {
                    id: entry.uid?.toString() || (Date.now() + Math.random()).toString(36),
                    keys: Array.isArray(rawKeys) ? rawKeys : String(rawKeys || '').split(',').map(k => k.trim()).filter(k => k),
                    content: entry.content || '',
                    enabled: entry.enabled !== false && entry.disable !== true,
                    secondary_keys: Array.isArray(rawSecondary) ? rawSecondary : String(rawSecondary || '').split(',').map(k => k.trim()).filter(k => k),
                    comment: entry.comment || '',
                    order: entry.order !== undefined ? entry.order : 100,
                    probability: entry.probability !== undefined ? entry.probability : 100,
                    constant: entry.constant || false,
                    selectiveLogic: entry.selectiveLogic ?? 0,
                    matchWholeWords: entry.matchWholeWords ?? null,
                    caseSensitive: entry.caseSensitive ?? null,
                    useGroupScoring: entry.useGroupScoring ?? null,
                    scanDepth: entry.scanDepth,
                    position: restoredPosition || ((entry.position === 0)
                        ? 'worldInfoBefore'
                        : (entry.position === 1)
                            ? 'worldInfoAfter'
                            : ((entry.position === 'worldInfoBefore' || entry.position === 'worldInfoAfter' || entry.position === 'lorebooksMacro' || entry.position === 'matchGlobal') ? entry.position : 'matchGlobal')),
                    characterFilter: entry.characterFilter,
                    preventRecursion: entry.preventRecursion || false,
                    delayUntilRecursion: entry.delayUntilRecursion || false,
                    sticky: entry.sticky || 0,
                    cooldown: entry.cooldown || 0,
                    delay: entry.delay || 0,
                    group: entry.group || '',
                    groupProminence: entry.groupProminence || 100,
                    ignoreBudget: entry.ignoreBudget || false
                };
            })
        };

        lorebookState.lorebooks.push(newLb);
        if (activationScope === 'character' && activationTargetId) {
            if (!lorebookState.activations.character) lorebookState.activations.character = {};
            if (!lorebookState.activations.character[activationTargetId]) {
                lorebookState.activations.character[activationTargetId] = [];
            }
            if (!lorebookState.activations.character[activationTargetId].includes(newLb.id)) {
                lorebookState.activations.character[activationTargetId].push(newLb.id);
            }
        }
        return newLb;
    } catch (err) {
        throw new Error('Invalid SillyTavern Lorebook format: ' + err.message);
    }
}

// Exports
export function exportSTLorebook(lorebook) {
    const entries = {};
    const glazeMetadata = { entries: {} };
    const globalInjectionPosition = lorebookState.globalSettings?.injectionPosition || 'worldInfoBefore';
    (lorebook.entries || []).forEach((entry, index) => {
        const rawPosition = entry.position || 'matchGlobal';
        const resolvedPosition = rawPosition === 'matchGlobal' ? globalInjectionPosition : rawPosition;
        const stPosition = resolvedPosition === 'worldInfoAfter' ? 1 : 0;

        entries[index.toString()] = {
            uid: index,
            key: entry.keys || [],
            keysecondary: entry.secondary_keys || [],
            comment: entry.comment || '',
            content: entry.content || '',
            constant: entry.constant || false,
            selective: (entry.secondary_keys && entry.secondary_keys.length > 0),
            order: entry.order ?? 100,
            position: stPosition,
            disable: entry.enabled === false,
            displayIndex: index,
            addMemo: true,
            group: entry.group || '',
            groupOverride: false,
            groupWeight: entry.groupProminence || 100,
            sticky: entry.sticky || 0,
            cooldown: entry.cooldown || 0,
            delay: entry.delay || 0,
            probability: entry.probability ?? 100,
            depth: 4,
            useProbability: (entry.probability !== undefined && entry.probability < 100),
            role: null,
            vectorized: false,
            excludeRecursion: false,
            preventRecursion: entry.preventRecursion || false,
            delayUntilRecursion: entry.delayUntilRecursion || false,
            scanDepth: entry.scanDepth ?? null,
            caseSensitive: entry.caseSensitive ?? null,
            matchWholeWords: entry.matchWholeWords ?? null,
            useGroupScoring: entry.useGroupScoring ?? null,
            automationId: '',
            selectiveLogic: entry.selectiveLogic ?? 0,
            ignoreBudget: entry.ignoreBudget || false,
            matchPersonaDescription: false,
            matchCharacterDescription: false,
            matchCharacterPersonality: false,
            matchCharacterDepthPrompt: false,
            matchScenario: false,
            matchCreatorNotes: false,
            outletName: '',
            triggers: [],
            ...(entry.characterFilter ? { characterFilter: entry.characterFilter } : {})
        };

        glazeMetadata.entries[index.toString()] = {
            position: rawPosition
        };
    });

    return { entries, glazeMetadata };
}

async function computeTextHash(text) {
    const encoder = new TextEncoder();
    const data = encoder.encode(text);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

export async function indexLorebookEntry(entry, lorebookId) {
    if (!isEmbeddingConfigured()) return;
    if (!entry.id) {
        throw new Error('Entry ID is missing');
    }

    const config = getEmbeddingConfig();
    const text = getEntryIndexingText(entry, config.target);

    const textHash = await computeTextHash(buildEmbeddingFingerprint(entry, text));

    if (!text) {
        const error = getIndexingErrorDetails('empty_text', 'Entry text is empty for current embedding target');
        await saveEmbeddingError(entry, lorebookId, textHash, error);
        throw new Error(error.message);
    }

    const existing = await db.getEmbedding(entry.id);
    if (existing && existing.textHash === textHash) return;

    const vectorsData = await getEmbeddings([text]);
    console.log('[indexLorebookEntry] embedding result', {
        entryId: entry.id,
        entryName: entry.comment || entry.keys?.[0],
        textLength: text.length,
        vectorsData,
        hasVectorsData: !!vectorsData,
        firstChunk: vectorsData?.[0]?.[0]
    });
    
    if (!vectorsData || !vectorsData[0] || vectorsData[0].length === 0) {
        const error = getIndexingErrorDetails('empty_embedding', 'Embedding API returned no vector');
        await saveEmbeddingError(entry, lorebookId, textHash, error);
        throw new Error(error.message);
    }

    await db.saveEmbedding(buildEmbeddingRecord(entry, lorebookId, vectorsData[0], textHash));
}

export async function indexLorebookEntries(lorebookId, onProgress, options = {}) {
    const lb = lorebookState.lorebooks.find(l => l.id === lorebookId);
    if (!lb) return { indexed: 0, skipped: 0, failed: 0, total: 0 };

    const retryFailedOnly = options.retryFailedOnly === true;
    const entries = lb.entries.filter(e => e.enabled !== false && e.vectorSearch);
    if (entries.length === 0) return { indexed: 0, skipped: 0, failed: 0, total: 0, failures: [], retriedFailedOnly: retryFailedOnly };

    const config = getEmbeddingConfig();
    let indexed = 0;
    let skipped = 0;
    let failed = 0;
    const failures = [];
    const processedEntries = [];

    for (const entry of entries) {
        if (!retryFailedOnly) {
            processedEntries.push(entry);
            continue;
        }

        const existing = await db.getEmbedding(entry.id);
        if (existing?.error) {
            processedEntries.push(entry);
        }
    }

    if (processedEntries.length === 0) {
        return { indexed: 0, skipped: 0, failed: 0, total: 0, failures: [], retriedFailedOnly: retryFailedOnly };
    }

    for (let i = 0; i < processedEntries.length; i++) {
        const entry = processedEntries[i];
        const text = getEntryIndexingText(entry, config.target);
        const textHash = await computeTextHash(buildEmbeddingFingerprint(entry, text));

        if (!text) {
            const error = getIndexingErrorDetails('empty_text', 'Entry text is empty for current embedding target');
            await saveEmbeddingError(entry, lb.id, textHash, error);
            failures.push({ entryId: entry.id, comment: entry.comment || '', keys: entry.keys || [], error });
            failed++;
            if (onProgress) onProgress(i + 1, processedEntries.length);
            continue;
        }

        const existing = await db.getEmbedding(entry.id);
        // Skip if already indexed with same text AND already using multi-vector format
        const isLegacyFormat = existing && existing.vector && !existing.vectors;
        if (existing && existing.textHash === textHash && !isLegacyFormat) {
            console.log('[indexLorebookEntries] skipping (already indexed)', {
                entryId: entry.id,
                comment: entry.comment?.substring(0, 50),
                hasVectors: !!existing.vectors,
                hasVector: !!existing.vector
            });
            skipped++;
            if (onProgress) onProgress(i + 1, processedEntries.length);
            continue;
        }
        
        // Force reindex legacy format entries
        if (isLegacyFormat) {
            console.log('[indexLorebookEntries] reindexing legacy entry', {
                entryId: entry.id,
                comment: entry.comment?.substring(0, 50)
            });
        }

        try {
            const vectors = await getEmbeddings([text]);
            console.log('[indexLorebookEntry] embedding result', {
                entryId: entry.id,
                entryName: entry.comment?.substring(0, 50),
                textLength: text.length,
                vectorsData: vectors?.[0],
                hasVectorsData: !!vectors?.[0],
                firstChunk: vectors?.[0]?.[0]
            });
            if (vectors && vectors[0]) {
                await db.saveEmbedding(buildEmbeddingRecord(entry, lorebookId, vectors[0], textHash));
                indexed++;
            } else {
                const error = getIndexingErrorDetails('empty_embedding', 'Embedding API returned no vector');
                await saveEmbeddingError(entry, lb.id, textHash, error);
                failures.push({ entryId: entry.id, comment: entry.comment || '', keys: entry.keys || [], error });
                failed++;
            }
        } catch (e) {
            console.warn('[indexLorebookEntries] Failed for entry', entry.id, e);
            const error = classifyIndexingError(e);
            await saveEmbeddingError(entry, lb.id, textHash, error);
            failures.push({ entryId: entry.id, comment: entry.comment || '', keys: entry.keys || [], error });
            failed++;
        }

        if (onProgress) onProgress(i + 1, processedEntries.length);
    }

    return { indexed, skipped, failed, total: processedEntries.length, failures, retriedFailedOnly: retryFailedOnly };
}

export async function getEmbeddingStatus(entryId) {
    const record = await db.getEmbedding(entryId);
    if (!record) return 'none';
    if (record.error) return 'error';
    return 'indexed';
}

export async function getEmbeddingRecord(entryId) {
    return db.getEmbedding(entryId);
}

export async function deleteLorebookEntryEmbedding(entryId) {
    if (!entryId) return;
    await db.deleteEmbedding(entryId);
}

export async function deleteLorebookEmbeddings(lorebookId) {
    const allEmbeddings = await db.getEmbeddingsBySource('lorebook_entry');
    const targets = allEmbeddings.filter(record => record.sourceId === lorebookId);
    for (const record of targets) {
        await db.deleteEmbedding(record.id);
    }
}

export async function vectorSearchLorebooks(history = [], currentText = '', char = null, chatId = null) {
    const config = getEmbeddingConfig();
    if (!config.enabled) {
        console.info('[vectorSearchLorebooks] skipped: vector search disabled');
        return [];
    }
    if (!isEmbeddingConfigured()) {
        console.info('[vectorSearchLorebooks] skipped: embedding config incomplete');
        return [];
    }

    const charId = char?.id;

    const activeLorebooks = lorebookState.lorebooks.filter(lb => {
        if (lb.enabled) return true;
        if (charId && lorebookState.activations?.character?.[charId]?.includes(lb.id)) return true;
        if (chatId && lorebookState.activations?.chat?.[chatId]?.includes(lb.id)) return true;
        return false;
    });

    if (activeLorebooks.length === 0) {
        console.info('[vectorSearchLorebooks] skipped: no active lorebooks for context', {
            charId,
            chatId,
            totalLorebooks: lorebookState.lorebooks.length
        });
        return [];
    }

    const vectorEntries = [];
    activeLorebooks.forEach(lb => {
        lb.entries.forEach(entry => {
            if (entry.enabled !== false && entry.vectorSearch) {
                vectorEntries.push({ ...entry, lorebookName: lb.name, lorebookId: lb.id });
            }
        });
    });

    if (vectorEntries.length === 0) {
        console.info('[vectorSearchLorebooks] skipped: no vector-enabled entries', {
            activeLorebooks: activeLorebooks.length
        });
        return [];
    }

    const allEmbeddings = await db.getEmbeddingsBySource('lorebook_entry');
    const embeddingMap = new Map(allEmbeddings.map(e => [e.id, e]));

    const candidates = [];
    const missingEmbeddings = [];
    for (const entry of vectorEntries) {
        const emb = embeddingMap.get(entry.id);
        // NEW: Support both multi-vector (vectors) and legacy (vector)
        if (emb && (emb.vectors || emb.vector)) {
            const candidate = { ...entry, retrievalHints: emb.retrievalHints || [] };
            if (emb.vectors) {
                candidate.vectors = emb.vectors;  // Multi-vector
            } else if (emb.vector) {
                candidate.vector = emb.vector;  // Legacy single vector
            }
            candidates.push(candidate);
        } else {
            missingEmbeddings.push({
                id: entry.id,
                comment: entry.comment,
                hasEmb: !!emb,
                hasVectors: emb?.vectors ? true : false,
                hasVector: emb?.vector ? true : false
            });
        }
    }
    
    if (missingEmbeddings.length > 0) {
        console.warn('[vectorSearchLorebooks] entries missing embeddings', {
            count: missingEmbeddings.length,
            entries: missingEmbeddings
        });
    }

    if (candidates.length === 0) {
        console.info('[vectorSearchLorebooks] skipped: no indexed vector candidates', {
            vectorEntries: vectorEntries.length,
            storedEmbeddings: allEmbeddings.length
        });
        return [];
    }

    const scanDepth = config.scanDepth || 5;
    const recentHistory = history.slice(-scanDepth);
    const recentUserParts = recentHistory
        .filter(m => m.role === 'user')
        .map(m => m.content)
        .filter(Boolean);
    const currentTextTrimmed = currentText && currentText.trim() ? currentText.trim() : '';
    const focusedQueryParts = recentUserParts.length > 0 ? [...recentUserParts] : [];
    if (currentTextTrimmed) {
        focusedQueryParts.push(currentTextTrimmed);
    }
    const fallbackQueryParts = recentHistory.map(m => m.content).filter(Boolean);
    if (currentTextTrimmed) {
        fallbackQueryParts.push(currentTextTrimmed);
    }

    const focusedQueryText = focusedQueryParts.join('\n');
    const fallbackQueryText = fallbackQueryParts.join('\n');
    const queryText = (focusedQueryParts.length > 0 ? focusedQueryParts : fallbackQueryParts).join('\n');
    if (!queryText.trim()) {
        console.info('[vectorSearchLorebooks] skipped: empty query text', {
            historyMessages: history.length,
            hasCurrentText: !!(currentText && currentText.trim())
        });
        return [];
    }

    console.info('[vectorSearchLorebooks] querying embeddings', {
        charId,
        chatId,
        activeLorebooks: activeLorebooks.length,
        vectorEntries: vectorEntries.length,
        indexedCandidates: candidates.length,
        historyMessages: history.length,
        userMessagesUsed: recentUserParts.length,
        focusedQueryLength: focusedQueryText.length,
        fallbackQueryLength: fallbackQueryText.length,
        hasCurrentText: !!(currentText && currentText.trim()),
        queryLength: queryText.length,
        threshold: config.threshold || 0.6,
        topK: config.topK || 5
    });

    try {
        const hybridQueryText = focusedQueryText || fallbackQueryText;

        function stripOOC(text) {
            return text.replace(/\[OOC:\s*/gi, '').replace(/\(OOC:\s*/gi, '').replace(/\s*\]\s*/g, ' ').replace(/\s*\)\s*/g, ' ').trim();
        }

        const runSearch = async (text, label) => {
            if (!text || !text.trim()) return [];
            const cleanText = stripOOC(text);
            console.info('[vectorSearchLorebooks] embedding query', {
                label,
                queryLength: cleanText.length,
                queryPreview: cleanText.substring(0, 200),
                originalPreview: text.substring(0, 200)
            });
            const queryVectorsData = await getEmbeddings([cleanText]);
            if (!queryVectorsData || !queryVectorsData[0] || !queryVectorsData[0][0]?.vector) {
                console.info('[vectorSearchLorebooks] skipped: embedding API returned no query vector', { label });
                return [];
            }

            const queryChunks = queryVectorsData[0];
            console.info('[vectorSearchLorebooks] query chunks', {
                label,
                chunksCount: queryChunks.length,
                chunks: queryChunks.map(c => ({
                    textPreview: c.text?.substring(0, 80),
                    vectorLength: c.vector?.length
                }))
            });

            // Use all query chunks for MaxSim (query-chunk x candidate-chunk)
            const vectorResults = findTopKMulti(queryChunks, candidates, candidates.length, 0);
            
            // Debug Asei specifically
            const aseiResult = vectorResults.find(r => r.comment?.includes('Asei'));
            if (aseiResult) {
                const queryChunksForDebug = queryChunks || [];
                console.warn('[DEBUG] Asei vector details', {
                    id: aseiResult.id,
                    comment: aseiResult.comment,
                    score: aseiResult.score,
                    bestQueryChunk: aseiResult._bestQueryChunk,
                    bestCandidateChunk: aseiResult._bestCandidateChunk,
                    hasVectors: !!aseiResult.vectors,
                    chunksCount: aseiResult.vectors?.length,
                    queryChunksCount: queryChunksForDebug.length,
                    bestQueryText: queryChunksForDebug[aseiResult._bestQueryChunk]?.text?.substring(0, 120),
                    bestCandidateText: aseiResult.vectors?.[aseiResult._bestCandidateChunk]?.text?.substring(0, 120),
                    allChunkScores: (() => {
                        const scores = [];
                        if (!aseiResult.vectors) return 'no vectors';
                        for (let qi = 0; qi < queryChunksForDebug.length; qi++) {
                            const qVec = queryChunksForDebug[qi]?.vector;
                            if (!qVec) continue;
                            for (let ci = 0; ci < aseiResult.vectors.length; ci++) {
                                const cVec = aseiResult.vectors[ci]?.vector;
                                if (!cVec) continue;
                                const s = cosineSimilarity(qVec, cVec);
                                scores.push({ qi, ci, score: s.toFixed(4), queryPreview: queryChunksForDebug[qi]?.text?.substring(0, 50), candidatePreview: aseiResult.vectors[ci]?.text?.substring(0, 50) });
                            }
                        }
                        return scores.sort((a, b) => b.score - a.score);
                    })()
                });
            }
            
            console.info('[vectorSearchLorebooks] raw similarity scores', {
                label,
                totalResults: vectorResults.length,
                top15: vectorResults.slice(0, 15).map(r => ({
                    id: r.id,
                    comment: r.comment,
                    rawScore: r.score.toFixed(4),
                    hasVectors: !!r.vectors,
                    hasVector: !!r.vector,
                    chunksCount: r.vectors?.length || 1
                }))
            });
            
            return vectorResults.map(result => {
                const hybridBoost = scoreHybridBoost(result, hybridQueryText);
                const descriptorBoost = scoreDescriptorBoost(result, hybridQueryText);
                return {
                    ...result,
                    score: Math.min(1, result.score + hybridBoost + descriptorBoost),
                    hybridBoost,
                    descriptorBoost,
                    searchLabel: label
                };
            });
        };

        const focusedResults = await runSearch(focusedQueryText, 'focused');
        let fallbackResults = [];
        if (fallbackQueryParts.length > focusedQueryParts.length) {
            console.info('[vectorSearchLorebooks] retrying with fallback query');
            fallbackResults = await runSearch(fallbackQueryText, 'fallback');
        }

        const combined = new Map();
        for (const result of [...focusedResults, ...fallbackResults]) {
            const existing = combined.get(result.id);
            if (!existing || result.score > existing.score) {
                combined.set(result.id, result);
            }
        }

        const results = Array.from(combined.values())
            .sort((a, b) => b.score - a.score)
            .filter(result => result.score >= (config.threshold || 0.55))
            .slice(0, config.topK || 5);

        console.info('[vectorSearchLorebooks] results ready', {
            matches: results.length,
            topScores: results.slice(0, 15).map(r => ({
                id: r.id,
                name: r.comment || r.keys?.[0] || 'Entry',
                lorebookName: r.lorebookName,
                score: Number(r.score?.toFixed?.(4) || r.score),
                hybridBoost: Number(r.hybridBoost?.toFixed?.(4) || r.hybridBoost || 0),
                descriptorBoost: Number(r.descriptorBoost?.toFixed?.(4) || r.descriptorBoost || 0),
                source: r.searchLabel
            }))
        });
        return results.map(r => ({
            ...r,
            vectorScore: r.score,
            vector: undefined
        }));
    } catch (e) {
        console.warn('[vectorSearchLorebooks] Error:', e);
        throw e;
    }
}
