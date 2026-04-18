/**
 * Context Service
 * 
 * Pure business logic for context/tokenizer management.
 * No Vue dependencies, no reactive state - just pure functions.
 * 
 * This service handles:
 * - History fill threshold clamping and validation
 * - History hide percent clamping and validation
 * - Context settings persistence helpers
 */

// ============================================================================
// CONSTANTS
// ============================================================================

export const HISTORY_FILL_THRESHOLD_KEY = 'gz_history_fill_threshold';
export const HISTORY_HIDE_PERCENT_KEY = 'gz_history_hide_percent';
export const DEFAULT_FILL_THRESHOLD = 85;
export const DEFAULT_HIDE_PERCENT = 30;

// ============================================================================
// VALIDATION & CLAMPING
// ============================================================================

/**
 * Clamp history fill threshold to valid range (1-100)
 * @param {number|string} value - Value to clamp
 * @returns {number} Clamped value (default: 85)
 */
export function clampHistoryFillThreshold(value) {
    const parsed = parseInt(value, 10);
    if (Number.isNaN(parsed)) return DEFAULT_FILL_THRESHOLD;
    return Math.max(1, Math.min(100, parsed));
}

/**
 * Clamp history hide percent to valid range (1-95)
 * @param {number|string} value - Value to clamp
 * @returns {number} Clamped value (default: 30)
 */
export function clampHistoryHidePercent(value) {
    const parsed = parseInt(value, 10);
    if (Number.isNaN(parsed)) return DEFAULT_HIDE_PERCENT;
    return Math.max(1, Math.min(95, parsed));
}

// ============================================================================
// SETTINGS HELPERS
// ============================================================================

/**
 * Load history context settings from localStorage
 * @returns {{fillThreshold: number, hidePercent: number}}
 */
export function loadHistoryContextSettings() {
    return {
        fillThreshold: clampHistoryFillThreshold(
            localStorage.getItem(HISTORY_FILL_THRESHOLD_KEY) || DEFAULT_FILL_THRESHOLD
        ),
        hidePercent: clampHistoryHidePercent(
            localStorage.getItem(HISTORY_HIDE_PERCENT_KEY) || DEFAULT_HIDE_PERCENT
        )
    };
}

/**
 * Persist history context settings to localStorage
 * @param {number} fillThreshold - Fill threshold (will be clamped)
 * @param {number} hidePercent - Hide percent (will be clamped)
 * @returns {{fillThreshold: number, hidePercent: number}} Clamped values
 */
export function persistHistoryContextSettings(fillThreshold, hidePercent) {
    const clampedFillThreshold = clampHistoryFillThreshold(fillThreshold);
    const clampedHidePercent = clampHistoryHidePercent(hidePercent);
    
    localStorage.setItem(HISTORY_FILL_THRESHOLD_KEY, String(clampedFillThreshold));
    localStorage.setItem(HISTORY_HIDE_PERCENT_KEY, String(clampedHidePercent));
    
    return {
        fillThreshold: clampedFillThreshold,
        hidePercent: clampedHidePercent
    };
}

// ============================================================================
// CONTEXT CALCULATION HELPERS
// ============================================================================

/**
 * Calculate if hide recommendation should be shown
 * @param {number} historyUsagePercent - Current history usage percent
 * @param {number} fillThreshold - Fill threshold percent
 * @returns {boolean} True if should recommend hide
 */
export function shouldRecommendHide(historyUsagePercent, fillThreshold) {
    return historyUsagePercent >= fillThreshold;
}

/**
 * Calculate history usage percentage
 * @param {number} historyTokens - Tokens used by history
 * @param {number} totalContextBudget - Total context budget
 * @returns {number} Usage percent (0-100)
 */
export function calculateHistoryUsagePercent(historyTokens, totalContextBudget) {
    if (!totalContextBudget || totalContextBudget <= 0) return 0;
    return Math.round((historyTokens / totalContextBudget) * 100);
}

/**
 * Calculate how many messages to hide based on percent
 * @param {number} totalMessages - Total visible messages
 * @param {number} hidePercent - Percent to hide (1-95)
 * @returns {number} Number of messages to hide
 */
export function calculateMessagesToHide(totalMessages, hidePercent) {
    const clampedPercent = clampHistoryHidePercent(hidePercent);
    return Math.max(1, Math.floor(totalMessages * (clampedPercent / 100)));
}
