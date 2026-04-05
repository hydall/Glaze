import { reactive, watch } from 'vue';
import { db } from '@/utils/db.js';

function escapeRegex(string) {
    return string.replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

// --- State Definition ---
export const lorebookState = reactive({
    lorebooks: [],
    globalSettings: {
        scanDepth: 1000,
        contextPercent: 100,
        budgetCap: 0,
        minActivations: 0,
        maxDepth: 0,
        maxRecursionSteps: 0,
        insertionStrategy: 'character_first', // character_first, global_first
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

export async function initLorebookState() {
    if (lorebookState.initialized) return;
    try {
        const data = await db.get('gz_lorebooks');
        if (data) {
            if (Array.isArray(data)) {
                lorebookState.lorebooks = data;
            } else if (data.lorebooks) {
                // New format with settings
                lorebookState.lorebooks = data.lorebooks;
                if (data.settings) {
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
                // Character Filter check
                if (char && entry.characterFilter) {
                    const { isExclude, names } = entry.characterFilter;
                    if (names && names.length > 0) {
                        const charName = (char.name || "").toLowerCase();
                        const isInCategory = names.some(n => charName.includes(n.toLowerCase()));
                        if (isExclude && isInCategory) return; // Excluded
                        if (!isExclude && !isInCategory) return; // Not in allowed list
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
                let pattern = sourceKey;
                if (wholeWords) {
                    pattern = `\\b${pattern}\\b`;
                }
                const flags = caseSensitive ? '' : 'i';
                try {
                    const regex = new RegExp(pattern, flags);
                    return regex.test(sourceText);
                } catch (e) {
                    // Prevent crashes on invalid/pathological patterns by using literal fallback.
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

export async function importSTLorebook(json, fileName = 'Imported') {
    try {
        let normalizedEntries = [];
        const entriesRaw = json.entries || [];

        if (Array.isArray(entriesRaw)) {
            normalizedEntries = entriesRaw;
        } else if (typeof entriesRaw === 'object') {
            normalizedEntries = Object.values(entriesRaw);
        }

        const newLb = {
            id: Date.now().toString(36) + Math.random().toString(36).substr(2, 5),
            name: json.name || fileName.replace('.json', ''),
            enabled: true,
            entries: normalizedEntries.map(entry => ({
                id: entry.uid?.toString() || (Date.now() + Math.random()).toString(36),
                keys: Array.isArray(entry.key) ? entry.key : (entry.key || '').split(',').map(k => k.trim()).filter(k => k),
                content: entry.content || '',
                enabled: entry.enabled !== false && entry.disable !== true,
                secondary_keys: Array.isArray(entry.keysecondary) ? entry.keysecondary : (entry.keysecondary || '').split(',').map(k => k.trim()).filter(k => k),
                comment: entry.comment || '',
                order: entry.order !== undefined ? entry.order : 100,
                probability: entry.probability !== undefined ? entry.probability : 100,
                constant: entry.constant || false,
                selectiveLogic: entry.selectiveLogic ?? 0,
                matchWholeWords: entry.matchWholeWords ?? null,
                caseSensitive: entry.caseSensitive ?? null,
                useGroupScoring: entry.useGroupScoring ?? null,
                scanDepth: entry.scanDepth,
                position: (entry.position === 0) ? 'worldInfoBefore' : (entry.position === 1) ? 'worldInfoAfter' : (entry.position ?? 'worldInfoBefore'),
                characterFilter: entry.characterFilter,
                preventRecursion: entry.preventRecursion || false,
                delayUntilRecursion: entry.delayUntilRecursion || false,
                sticky: entry.sticky || 0,
                cooldown: entry.cooldown || 0,
                delay: entry.delay || 0,
                group: entry.group || '',
                groupProminence: entry.groupProminence || 100,
                ignoreBudget: entry.ignoreBudget || false
            }))
        };

        lorebookState.lorebooks.push(newLb);
        return newLb;
    } catch (err) {
        throw new Error('Invalid SillyTavern Lorebook format: ' + err.message);
    }
}

// Exports
export function exportSTLorebook(lorebook) {
    const entries = {};
    (lorebook.entries || []).forEach((entry, index) => {
        entries[index.toString()] = {
            uid: index,
            key: entry.keys || [],
            keysecondary: entry.secondary_keys || [],
            comment: entry.comment || '',
            content: entry.content || '',
            constant: entry.constant || false,
            selective: (entry.secondary_keys && entry.secondary_keys.length > 0),
            order: entry.order ?? 100,
            position: (entry.position === 'worldInfoBefore') ? 0 : (entry.position === 'worldInfoAfter') ? 1 : (entry.position ?? 0),
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
    });

    return { entries };
}
