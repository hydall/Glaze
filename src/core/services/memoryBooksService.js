/**
 * Memory Books Service
 * 
 * Pure business logic for Memory Books functionality.
 * No Vue dependencies, no reactive state - just pure functions.
 * 
 * This service handles:
 * - Memory book initialization and management
 * - Memory entry operations (CRUD, normalization, conflict detection)
 * - Draft generation and automation
 * - Vector/embedding operations
 * - Prompt management
 * - Coverage reconciliation
 */

import { generateMemoryDraft } from './generationService.js';
import { db } from '@/utils/db.js';

// ============================================================================
// INITIALIZATION & STATE CREATION
// ============================================================================

export function createEmptyMemoryCoverage() {
    return {
        entryIds: [],
        needsRebuild: false,
        stale: false
    };
}

export function createBaseMessageMeta() {
    return {
        contextRefs: [],
        memoryCoverage: createEmptyMemoryCoverage()
    };
}

export function createMemoryAutomationState() {
    return {
        lastProcessedMessageCount: 0,
        pendingTrigger: null,
        isGeneratingDraft: false
    };
}

export function memoryBooksHasAutomationState(memoryBook) {
    return !!(memoryBook && typeof memoryBook.automation === 'object');
}

export function ensureMemoryAutomationState(memoryBook) {
    if (!memoryBooksHasAutomationState(memoryBook)) {
        memoryBook.automation = createMemoryAutomationState();
    }
    if (!Number.isFinite(Number(memoryBook.automation.lastProcessedMessageCount)) || Number(memoryBook.automation.lastProcessedMessageCount) < 0) {
        memoryBook.automation.lastProcessedMessageCount = 0;
    }
    if (typeof memoryBook.automation.isGeneratingDraft !== 'boolean') {
        memoryBook.automation.isGeneratingDraft = false;
    }
    if (memoryBook.automation.pendingTrigger && typeof memoryBook.automation.pendingTrigger !== 'object') {
        memoryBook.automation.pendingTrigger = null;
    }
    return memoryBook.automation;
}

export function ensureSessionMemoryBook(chatData, sessionId) {
    if (!chatData.memoryBooks) chatData.memoryBooks = {};
    if (!chatData.memoryBooks[sessionId]) {
        chatData.memoryBooks[sessionId] = {
            id: `memorybook_${sessionId}`,
            entries: [],
            pendingDrafts: [],
            settings: {
                enabled: true,
                maxInjectedEntries: 3,
                autoCreateInterval: 12,
                useDelayedAutomation: true,
                injectionTarget: 'summary_block',
                batchSize: 1,
                parallelJobs: 1,
                generationSource: 'current',
                generationModel: '',
                generationUseCurrentModelOverride: false,
                generationEndpoint: '',
                generationApiKey: '',
                generationTemperature: null,
                generationMaxTokens: null,
                promptPreset: 'detailed_beats',
                customPrompts: []
            },
            updatedAt: 0
        };
    }
    if (!memoryBooksHasAutomationState(chatData.memoryBooks[sessionId])) {
        chatData.memoryBooks[sessionId].automation = createMemoryAutomationState();
    }
    return chatData.memoryBooks[sessionId];
}

// ============================================================================
// MESSAGE UTILITIES
// ============================================================================

export function getStableVisibleMessages(messages) {
    return (Array.isArray(messages) ? messages : []).filter(msg => msg && !msg.isTyping && !msg.isHidden && !msg.isError);
}

export function countStableConversationMessages(messages) {
    return getStableVisibleMessages(messages).filter(msg => msg.role === 'user' || msg.role === 'char').length;
}

export function getLastStableConversationRole(messages) {
    const visible = getStableVisibleMessages(messages).filter(msg => msg.role === 'user' || msg.role === 'char');
    return visible.length ? visible[visible.length - 1].role : null;
}

export function computeDelayedWaitExchanges(triggerRole) {
    return triggerRole === 'user' ? 2 : 1;
}

export function countCompletedExchangesSince(startCount, currentCount) {
    return Math.max(0, Math.floor(Math.max(0, currentCount - startCount) / 2));
}

export function normalizeAutoCreateInterval(memoryBook) {
    const raw = Number(memoryBook?.settings?.autoCreateInterval || 12);
    return Math.max(1, Math.min(200, Number.isFinite(raw) ? Math.round(raw) : 12));
}

// ============================================================================
// TRIGGER & SEGMENT MANAGEMENT
// ============================================================================

export function resolvePendingTriggerMessages(stableMessages, pendingTrigger) {
    if (!pendingTrigger || !Array.isArray(stableMessages) || !stableMessages.length) return [];

    const storedIds = Array.isArray(pendingTrigger.messageIds)
        ? pendingTrigger.messageIds.filter(Boolean)
        : [];
    if (storedIds.length) {
        const idSet = new Set(storedIds);
        const matched = stableMessages.filter(msg => idSet.has(msg.id));
        if (matched.length === storedIds.length) {
            return storedIds
                .map(id => matched.find(msg => msg.id === id))
                .filter(Boolean);
        }
    }

    const startIndex = Math.max(0, Number(pendingTrigger.windowStartIndex) || 0);
    const endIndex = Math.max(startIndex, Number(pendingTrigger.windowEndIndex) || startIndex);
    
    if (startIndex < stableMessages.length) {
        const actualEnd = Math.min(endIndex + 1, stableMessages.length);
        return stableMessages.slice(startIndex, actualEnd);
    }
    
    return [];
}

export function buildBootstrapSegments(messages, interval) {
    const stableConv = getStableVisibleMessages(messages).filter(msg => msg.role === 'user' || msg.role === 'char');
    if (!stableConv.length || interval <= 0) return [];
    
    const segments = [];
    for (let i = 0; i < stableConv.length; i += interval) {
        const segment = stableConv.slice(i, i + interval);
        if (segment.length) {
            segments.push(segment);
        }
    }
    return segments;
}

// ============================================================================
// ARRAY & OVERLAP UTILITIES
// ============================================================================

export function arraysEqual(a = [], b = []) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return false;
    }
    return true;
}

export function calculateMessageOverlapRatio(leftIds = [], rightIds = []) {
    if (!Array.isArray(leftIds) || !Array.isArray(rightIds)) return 0;
    if (!leftIds.length || !rightIds.length) return 0;
    const leftSet = new Set(leftIds);
    const overlap = rightIds.filter(id => leftSet.has(id)).length;
    return overlap / rightIds.length;
}

// ============================================================================
// ENTRY MANAGEMENT
// ============================================================================

export function normalizeEntryMessageIds(entry) {
    if (!entry) return [];
    if (Array.isArray(entry.messageIds)) return entry.messageIds;
    if (Array.isArray(entry.segment)) return entry.segment.map(m => m?.id).filter(Boolean);
    return [];
}

export function findConflictingMemoryEntry(memoryBook, selectedIds, { includeDrafts = true, includeEntries = true, overlapThreshold = 0.8 } = {}) {
    if (!memoryBook || !Array.isArray(selectedIds) || !selectedIds.length) return null;

    const candidates = [];
    if (includeEntries && Array.isArray(memoryBook.entries)) {
        candidates.push(...memoryBook.entries);
    }
    if (includeDrafts && Array.isArray(memoryBook.pendingDrafts)) {
        candidates.push(...memoryBook.pendingDrafts);
    }

    for (const candidate of candidates) {
        const candidateIds = normalizeEntryMessageIds(candidate);
        if (arraysEqual(candidateIds, selectedIds)) {
            return { entry: candidate, reason: 'exact' };
        }
    }

    for (const candidate of candidates) {
        const candidateIds = normalizeEntryMessageIds(candidate);
        const overlap = calculateMessageOverlapRatio(candidateIds, selectedIds);
        if (overlap >= overlapThreshold) {
            return { entry: candidate, reason: 'overlap', overlap };
        }
    }

    return null;
}

export function genMemoryEntryId() {
    return `memory_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
}

export function genMemoryPromptId() {
    return `prompt_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
}

export function normalizeMemoryEntryShape(entry) {
    if (!entry || typeof entry !== 'object') return null;
    
    const normalized = {
        id: entry.id || genMemoryEntryId(),
        title: entry.title || '',
        content: entry.content || '',
        rawContent: entry.rawContent || entry.content || '',
        keys: Array.isArray(entry.keys) ? entry.keys : [],
        glazeKeys: Array.isArray(entry.glazeKeys) ? entry.glazeKeys : [],
        messageIds: normalizeEntryMessageIds(entry),
        messageRange: entry.messageRange && typeof entry.messageRange === 'object' ? { ...entry.messageRange } : null,
        status: entry.status || 'active',
        vectorSearch: !!entry.vectorSearch,
        source: entry.source || 'manual',
        createdAt: entry.createdAt || Date.now(),
        updatedAt: entry.updatedAt || Date.now(),
        generatedAt: entry.generatedAt || null
    };
    
    return normalized;
}

export function parseMemoryKeyInput(value) {
    if (typeof value !== 'string') return [];
    return value
        .split(',')
        .map(k => k.trim())
        .filter(Boolean);
}

export function buildMemoryKeysFromText(text, fallback = []) {
    if (typeof text !== 'string' || !text.trim()) return fallback;
    
    const words = text
        .toLowerCase()
        .replace(/[^\w\s]/g, ' ')
        .split(/\s+/)
        .filter(Boolean);
    
    const freq = {};
    for (const word of words) {
        if (word.length >= 4) {
            freq[word] = (freq[word] || 0) + 1;
        }
    }
    
    const sorted = Object.entries(freq)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 5)
        .map(([word]) => word);
    
    return sorted.length ? sorted : fallback;
}

// ============================================================================
// RECONCILIATION & COVERAGE
// ============================================================================

export function reconcileMemoryBookForMessages(memoryBook, messages) {
    if (!memoryBook || !Array.isArray(messages)) return;
    
    const messageIds = new Set(messages.map(m => m?.id).filter(Boolean));
    
    // Clean up entries
    if (Array.isArray(memoryBook.entries)) {
        for (const entry of memoryBook.entries) {
            if (Array.isArray(entry.messageIds)) {
                const valid = entry.messageIds.filter(id => messageIds.has(id));
                if (valid.length !== entry.messageIds.length) {
                    entry.messageIds = valid;
                    entry.status = valid.length ? 'needs_rebuild' : 'orphaned';
                }
            }
        }
        memoryBook.entries = memoryBook.entries.filter(entry => {
            const ids = normalizeEntryMessageIds(entry);
            return ids.length > 0;
        });
    }
    
    // Clean up pending drafts
    if (Array.isArray(memoryBook.pendingDrafts)) {
        memoryBook.pendingDrafts = memoryBook.pendingDrafts.filter(draft => {
            const ids = normalizeEntryMessageIds(draft);
            return ids.length > 0 && ids.every(id => messageIds.has(id));
        });
    }
}

export function reconcileSessionMemoryState(chatData, sessionId, messages) {
    const memoryBook = chatData.memoryBooks?.[sessionId];
    if (memoryBook) {
        reconcileMemoryBookForMessages(memoryBook, messages);
    }
}

// ============================================================================
// MAINTENANCE
// ============================================================================

export async function runMemoryMaintenancePass(chatData, sessionId, { reindex = false } = {}) {
    const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
    
    let removedEntries = 0;
    let clearedDrafts = 0;
    let rebuildEntries = 0;
    
    // Remove orphaned entries
    if (Array.isArray(memoryBook.entries)) {
        const before = memoryBook.entries.length;
        memoryBook.entries = memoryBook.entries.filter(entry => {
            const ids = normalizeEntryMessageIds(entry);
            return ids.length > 0;
        });
        removedEntries = before - memoryBook.entries.length;
        
        // Mark entries that need rebuild
        for (const entry of memoryBook.entries) {
            if (entry.status === 'needs_rebuild') {
                rebuildEntries++;
            }
        }
    }
    
    // Clear old drafts
    if (Array.isArray(memoryBook.pendingDrafts)) {
        clearedDrafts = memoryBook.pendingDrafts.length;
        memoryBook.pendingDrafts = [];
    }
    
    // Clear automation state
    if (memoryBook.automation) {
        memoryBook.automation.pendingTrigger = null;
    }
    
    // Reindex if requested
    if (reindex) {
        // Reindexing logic is handled by caller (requires charId, sessionId context)
        // This function just marks the intent
    }
    
    memoryBook.updatedAt = Date.now();
    
    return {
        removedEntries,
        clearedDrafts,
        rebuildEntries
    };
}

// ============================================================================
// VECTOR/EMBEDDING OPERATIONS
// ============================================================================

export function shouldEnableMemoryVectorSearch() {
    // This checks if embedding config is available
    // Implementation depends on embeddingSettings
    try {
        const { isEmbeddingConfigured } = require('@/core/config/embeddingSettings.js');
        return isEmbeddingConfigured();
    } catch {
        return false;
    }
}

export function getMemoryVectorSearchEnabled(memoryBook) {
    return memoryBook?.settings?.vectorSearchEnabled !== false;
}

export function getMemoryKeyMatchMode(memoryBook) {
    const mode = memoryBook?.settings?.keyMatchMode;
    if (mode === 'plain' || mode === 'glaze' || mode === 'both') {
        return mode;
    }
    return 'glaze';
}

export function setMemoryVectorSearchOnEntries(memoryBook, enabled) {
    if (!memoryBook || !Array.isArray(memoryBook.entries)) return;
    for (const entry of memoryBook.entries) {
        entry.vectorSearch = !!enabled;
    }
}

export async function indexMemoryEntryIfNeeded(entry, charId, sessionId) {
    if (!entry?.vectorSearch) return;
    const generationService = await import('./generationService.js');
    if (typeof generationService.indexMemoryEntryForSession === 'function') {
        await generationService.indexMemoryEntryForSession(entry, charId, sessionId);
    }
}

export async function deleteMemoryEntryIndexIfPresent(entryId) {
    if (!entryId) return;
    const generationService = await import('./generationService.js');
    if (typeof generationService.deleteMemoryEntryIndex === 'function') {
        await generationService.deleteMemoryEntryIndex(entryId);
    }
}

export async function reindexMemoryEntry(entry, charId, sessionId) {
    await deleteMemoryEntryIndexIfPresent(entry.id);
    await indexMemoryEntryIfNeeded(entry, charId, sessionId);
}

export async function reindexAllMemoryEntries(memoryBook, charId, sessionId) {
    if (!memoryBook || !Array.isArray(memoryBook.entries)) return;
    for (const entry of memoryBook.entries) {
        if (entry.vectorSearch) {
            await reindexMemoryEntry(entry, charId, sessionId);
        }
    }
}

// ============================================================================
// PROMPT MANAGEMENT
// ============================================================================

export const builtInMemoryPrompts = [
    {
        key: 'detailed_beats',
        label: 'Detailed beats (recommended)',
        prompt: [
            'Analyze the following roleplay segment and create a comprehensive memory entry.',
            'Preserve the original language of the source segment. Do not translate it.',
            'Exclude all [OOC] (out-of-character) conversation — it is not useful for memory.',
            '',
            'Create a detailed beat-by-beat summary in narrative prose. Include:',
            '- Timeline: Date/time context if mentioned',
            '- Story Beats: All important plot events, decisions, and developments in order',
            '- Key Interactions: Significant character exchanges, dialogue highlights, and relationship developments',
            '- Notable Details: Important objects, settings, revelations, memorable quotes',
            '- Outcome: Results, resolutions, emotional states, and consequences for future continuity',
            '',
            'Capture all nuance without repeating verbatim. Use concrete nouns (e.g., "rice cooker" not "appliance").',
            'Write in past tense, third person. Focus on cause → intention → reaction → consequence.',
            '',
            'Also provide a list of 3-5 comma-separated keywords (e.g., "kitchen, argument, rice cooker, apology") suitable for retrieval.',
            '',
            'Strictly format your response as:',
            'TITLE: <short title>',
            'KEYS: <comma-separated keywords>',
            'CONTENT:',
            '<your detailed narrative summary>',
        ].join('\n')
    },
    {
        key: 'concise_facts',
        label: 'Concise facts',
        prompt: [
            'Extract the key facts and developments from this roleplay segment.',
            'Preserve the original language of the source segment. Do not translate it.',
            'Exclude all [OOC] (out-of-character) conversation.',
            '',
            'List concrete facts in bullet points:',
            '- What happened (actions, events)',
            '- Important dialogue or revelations',
            '- Emotional shifts or decisions',
            '- Setting/location changes',
            '',
            'Be specific and factual. Avoid interpretation or inference.',
            '',
            'Also provide 3-5 comma-separated keywords for retrieval.',
            '',
            'Format:',
            'TITLE: <short title>',
            'KEYS: <comma-separated keywords>',
            'CONTENT:',
            '<bullet point facts>',
        ].join('\n')
    }
];

export function getMemoryPromptOptions(settings = {}) {
    const customPrompts = Array.isArray(settings?.customPrompts) ? settings.customPrompts : [];
    return [...builtInMemoryPrompts, ...customPrompts];
}

export function resolveMemoryPrompt(settings = {}) {
    const presetKey = settings?.promptPreset || 'detailed_beats';
    const options = getMemoryPromptOptions(settings);
    const found = options.find(opt => opt.key === presetKey);
    return found ? found.prompt : builtInMemoryPrompts[0].prompt;
}

export function getMemoryPromptLabel(settings = {}) {
    const presetKey = settings?.promptPreset || 'detailed_beats';
    const options = getMemoryPromptOptions(settings);
    const found = options.find(opt => opt.key === presetKey);
    return found ? found.label : builtInMemoryPrompts[0].label;
}

// ============================================================================
// CONTEXT BUILDING FOR DRAFTS
// ============================================================================

export function buildMemoryContinuityContext(memoryBook, selected) {
    if (!memoryBook || !Array.isArray(memoryBook.entries) || !memoryBook.entries.length) {
        return '';
    }
    
    const relevant = memoryBook.entries
        .filter(entry => entry.status === 'active' && entry.content)
        .slice(-3);
    
    if (!relevant.length) return '';
    
    return relevant
        .map(entry => entry.content)
        .join('\n\n');
}

export function buildMemoryDraftLoreContext(selected) {
    // Placeholder - depends on lorebook integration
    return '';
}

export function buildMemoryDraftSummaryExcerpt(summary) {
    if (!summary || typeof summary !== 'string') return '';
    const trimmed = summary.trim();
    if (trimmed.length <= 500) return trimmed;
    return trimmed.substring(0, 500) + '...';
}

// ============================================================================
// DRAFT RESPONSE PARSING
// ============================================================================

export function parseMemoryDraftResponse(rawText, fallbackKeys = []) {
    if (typeof rawText !== 'string') {
        return {
            title: '',
            keys: fallbackKeys,
            content: ''
        };
    }

    const lines = rawText.split('\n');
    let title = '';
    let keys = [];
    let content = '';
    let inContent = false;

    for (const line of lines) {
        const trimmed = line.trim();
        
        if (trimmed.startsWith('TITLE:')) {
            title = trimmed.substring(6).trim();
        } else if (trimmed.startsWith('KEYS:')) {
            const keyString = trimmed.substring(5).trim();
            keys = parseMemoryKeyInput(keyString);
        } else if (trimmed === 'CONTENT:') {
            inContent = true;
        } else if (inContent && trimmed) {
            content += (content ? '\n' : '') + trimmed;
        }
    }

    // Fallback to raw text if parsing failed
    if (!content && rawText.length > 20) {
        content = rawText;
    }

    return {
        title: title || 'Memory Entry',
        keys: keys.length ? keys : fallbackKeys,
        content: content || rawText
    };
}

// ============================================================================
// FORMAT UTILITIES
// ============================================================================

export function formatElapsedSeconds(ms) {
    const sec = Math.floor(ms / 1000);
    return `${sec}s`;
}
