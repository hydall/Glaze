/**
 * Context Service
 * 
 * Business logic for context/tokenizer management and history operations.
 * Pure functions without Vue reactivity dependencies.
 */

// ============================================================================
// HISTORY CONTEXT SETTINGS
// ============================================================================

export function clampHistoryFillThreshold(value) {
    const num = Number(value);
    if (!Number.isFinite(num)) return 70;
    return Math.max(50, Math.min(95, Math.round(num)));
}

export function clampHistoryHidePercent(value) {
    const num = Number(value);
    if (!Number.isFinite(num)) return 25;
    return Math.max(10, Math.min(50, Math.round(num)));
}

export function persistHistoryContextSettings(fillThreshold, hidePercent) {
    const settings = {
        historyFillThreshold: clampHistoryFillThreshold(fillThreshold),
        historyHidePercent: clampHistoryHidePercent(hidePercent)
    };
    
    try {
        localStorage.setItem('glaze_history_context_settings', JSON.stringify(settings));
    } catch (error) {
        console.warn('Failed to persist history context settings:', error);
    }
    
    return settings;
}

export function loadHistoryContextSettings() {
    try {
        const stored = localStorage.getItem('glaze_history_context_settings');
        if (stored) {
            const parsed = JSON.parse(stored);
            return {
                historyFillThreshold: clampHistoryFillThreshold(parsed.historyFillThreshold),
                historyHidePercent: clampHistoryHidePercent(parsed.historyHidePercent)
            };
        }
    } catch (error) {
        console.warn('Failed to load history context settings:', error);
    }
    
    // Defaults
    return {
        historyFillThreshold: 70,
        historyHidePercent: 25
    };
}

// ============================================================================
// CONTEXT CALCULATION HELPERS
// ============================================================================

/**
 * Calculate how many messages to hide based on current history usage
 * @param {number} historyTokens - current history token count
 * @param {number} historyLimit - max history tokens allowed
 * @param {number} hidePercent - percentage to free (10-50)
 * @param {Array} messages - array of messages
 * @returns {{ count: number, tokens: number }} - messages to hide and tokens to free
 */
export function calculateHideRecommendation(historyTokens, historyLimit, hidePercent, messages) {
    if (!messages || !messages.length || historyTokens <= 0 || historyLimit <= 0) {
        return { count: 0, tokens: 0 };
    }
    
    const targetToFree = Math.ceil((historyTokens * hidePercent) / 100);
    
    // Estimate average tokens per message
    const avgTokensPerMessage = historyTokens / messages.length;
    
    // Estimate how many messages to hide
    const estimatedCount = Math.max(1, Math.ceil(targetToFree / avgTokensPerMessage));
    
    return {
        count: estimatedCount,
        tokens: targetToFree
    };
}

/**
 * Calculate history usage percentage
 * @param {number} historyTokens - current history token usage
 * @param {number} historyLimit - max history limit
 * @returns {number} - percentage (0-100)
 */
export function calculateHistoryUsagePercent(historyTokens, historyLimit) {
    if (historyLimit <= 0) return 0;
    return Math.min(100, Math.round((historyTokens / historyLimit) * 100));
}

/**
 * Check if hide recommendation should be shown
 * @param {number} usagePercent - current usage percentage
 * @param {number} fillThreshold - threshold to trigger recommendation
 * @returns {boolean}
 */
export function shouldRecommendHide(usagePercent, fillThreshold) {
    return usagePercent >= fillThreshold;
}

// ============================================================================
// CONTEXT SEGMENT UTILITIES
// ============================================================================

/**
 * Build context segments for visualization
 * @param {Object} breakdown - context breakdown from worker
 * @returns {Object} - segments for UI rendering
 */
export function buildContextSegments(breakdown) {
    if (!breakdown || !breakdown.contextSize) {
        return {
            used: [],
            reserve: null
        };
    }

    const { contextSize, totalUsed, reserve } = breakdown;
    const safeContext = contextSize - (reserve?.value || 0);
    
    const segments = {
        used: [],
        reserve: null
    };

    // Build used segments (excluding reserve)
    const sources = [
        { key: 'character', className: 'chat-context-character', label: 'Character' },
        { key: 'preset', className: 'chat-context-preset', label: 'Preset' },
        { key: 'summary', className: 'chat-context-summary', label: 'Summary' },
        { key: 'memory', className: 'chat-context-memory', label: 'Memory' },
        { key: 'authorsNote', className: 'chat-context-authors-note', label: "Author's Note" },
        { key: 'history', className: 'chat-context-history', label: 'History' }
    ];

    for (const source of sources) {
        const value = breakdown[source.key] || 0;
        if (value > 0) {
            segments.used.push({
                key: source.key,
                className: source.className,
                label: source.label,
                value,
                percent: ((value / contextSize) * 100).toFixed(2)
            });
        }
    }

    // Build reserve segment if present
    if (reserve && reserve.value > 0) {
        const reserveUsed = [];
        
        // Keyword lorebook
        if (breakdown.lorebook > 0) {
            reserveUsed.push({
                key: 'lorebook',
                className: 'chat-context-lorebook',
                label: 'Keyword Lorebook',
                value: breakdown.lorebook
            });
        }
        
        // Vector lorebook
        if (breakdown.vectorLore > 0) {
            reserveUsed.push({
                key: 'vectorLore',
                className: 'chat-context-vector-lore',
                label: 'Vector Lorebook',
                value: breakdown.vectorLore
            });
        }

        segments.reserve = {
            className: 'chat-context-reserve',
            label: 'Reserve',
            value: reserve.value,
            percent: ((reserve.value / contextSize) * 100).toFixed(2),
            used: reserveUsed,
            remaining: reserve.remaining || 0
        };
    }

    return segments;
}

/**
 * Build context breakdown items for display
 * @param {Object} breakdown - context breakdown from worker
 * @returns {Array} - breakdown items
 */
export function buildContextBreakdownItems(breakdown) {
    if (!breakdown) return [];

    const items = [
        { label: 'Character', value: breakdown.character || 0 },
        { label: 'Preset', value: breakdown.preset || 0 },
        { label: 'Summary', value: breakdown.summary || 0 },
        { label: 'Memory', value: breakdown.memory || 0 },
        { label: "Author's Note", value: breakdown.authorsNote || 0 },
        { label: 'History', value: breakdown.history || 0 }
    ];

    if (breakdown.lorebook > 0 || breakdown.vectorLore > 0) {
        items.push({ label: 'Lorebook Total', value: (breakdown.lorebook || 0) + (breakdown.vectorLore || 0) });
        if (breakdown.lorebook > 0) {
            items.push({ label: '  └ Keyword', value: breakdown.lorebook });
        }
        if (breakdown.vectorLore > 0) {
            items.push({ label: '  └ Vector', value: breakdown.vectorLore });
        }
    }

    return items.filter(item => item.value > 0);
}

/**
 * Build context legend items for visualization
 * @param {Object} breakdown - context breakdown from worker
 * @returns {Array} - legend items
 */
export function buildContextLegendItems(breakdown) {
    if (!breakdown) return [];

    const items = [
        { className: 'chat-context-character', label: 'Character' },
        { className: 'chat-context-preset', label: 'Preset' },
        { className: 'chat-context-summary', label: 'Summary' },
        { className: 'chat-context-memory', label: 'Memory' },
        { className: 'chat-context-authors-note', label: "Author's Note" },
        { className: 'chat-context-history', label: 'History' }
    ];

    if (breakdown.lorebook > 0 || breakdown.vectorLore > 0) {
        items.push({ className: 'chat-context-reserve', label: 'Reserve' });
    }

    return items;
}

// ============================================================================
// EXPORTS
// ============================================================================

export default {
    clampHistoryFillThreshold,
    clampHistoryHidePercent,
    persistHistoryContextSettings,
    loadHistoryContextSettings,
    calculateHideRecommendation,
    calculateHistoryUsagePercent,
    shouldRecommendHide,
    buildContextSegments,
    buildContextBreakdownItems,
    buildContextLegendItems
};
