const MEMORY_SETTINGS_KEY = 'gz_memory_settings';

export function getMemorySettings() {
    try {
        const raw = localStorage.getItem(MEMORY_SETTINGS_KEY);
        if (raw) {
            const parsed = JSON.parse(raw);
            if (parsed && typeof parsed === 'object') {
                normalizeMemorySettings(parsed);
                return parsed;
            }
        }
    } catch (_e) {}
    const defaults = createDefaultMemorySettings();
    try { localStorage.setItem(MEMORY_SETTINGS_KEY, JSON.stringify(defaults)); } catch (_e) {}
    return defaults;
}

export function saveMemorySettings(settings) {
    if (!settings || typeof settings !== 'object') return;
    const current = getMemorySettings();
    Object.assign(current, settings);
    normalizeMemorySettings(current);
    try { localStorage.setItem(MEMORY_SETTINGS_KEY, JSON.stringify(current)); } catch (_e) {}
}

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

export function createDefaultMemorySettings() {
    return {
        enabled: true,
        autoCreateEnabled: true,
        autoGenerateEnabled: false,
        maxInjectedEntries: 7,
        autoCreateInterval: 15,
        useDelayedAutomation: true,
        injectionTarget: 'summary_block',
        batchSize: 3,
        parallelJobs: 1,
        vectorSearchEnabled: false,
        keyMatchMode: 'glaze',
        generationSource: 'current',
        generationModel: '',
        generationUseCurrentModelOverride: false,
        generationEndpoint: '',
        generationApiKey: '',
        generationTemperature: null,
        generationMaxTokens: null,
        promptPreset: 'detailed_beats',
        customPrompts: []
    };
}

export function normalizeMemorySettings(settings) {
    if (typeof settings.enabled !== 'boolean') settings.enabled = true;
    if (typeof settings.autoCreateEnabled !== 'boolean') settings.autoCreateEnabled = true;
    if (typeof settings.autoGenerateEnabled !== 'boolean') settings.autoGenerateEnabled = false;
    if (!Number.isFinite(Number(settings.maxInjectedEntries)) || Number(settings.maxInjectedEntries) <= 0) settings.maxInjectedEntries = 7;
    if (!Number.isFinite(Number(settings.autoCreateInterval)) || Number(settings.autoCreateInterval) <= 0) settings.autoCreateInterval = 15;
    if (typeof settings.useDelayedAutomation !== 'boolean') settings.useDelayedAutomation = true;
    settings.injectionTarget = settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block';
    if (!Number.isFinite(Number(settings.batchSize)) || Number(settings.batchSize) <= 0) settings.batchSize = 3;
    if (!Number.isFinite(Number(settings.parallelJobs)) || Number(settings.parallelJobs) <= 0) settings.parallelJobs = 1;
    if (typeof settings.vectorSearchEnabled !== 'boolean') settings.vectorSearchEnabled = false;
    if (!['plain', 'glaze', 'both'].includes(settings.keyMatchMode)) settings.keyMatchMode = 'glaze';
    settings.generationSource = settings.generationSource === 'custom' ? 'custom' : 'current';
    if (typeof settings.generationModel !== 'string') settings.generationModel = '';
    if (typeof settings.generationUseCurrentModelOverride !== 'boolean') settings.generationUseCurrentModelOverride = false;
    if (typeof settings.generationEndpoint !== 'string') settings.generationEndpoint = '';
    if (typeof settings.generationApiKey !== 'string') settings.generationApiKey = '';
    if (settings.generationTemperature !== null && !Number.isFinite(Number(settings.generationTemperature))) settings.generationTemperature = null;
    if (settings.generationMaxTokens !== null && !Number.isFinite(Number(settings.generationMaxTokens))) settings.generationMaxTokens = null;
    if (typeof settings.promptPreset !== 'string' || !settings.promptPreset) settings.promptPreset = 'detailed_beats';
    if (!Array.isArray(settings.customPrompts)) settings.customPrompts = [];
}

export function normalizeMemoryEntryInPlace(entry) {
    if (!entry || typeof entry !== 'object') return entry;
    if (!Array.isArray(entry.keys)) entry.keys = [];
    if (!Array.isArray(entry.glazeKeys)) entry.glazeKeys = [];
    if (typeof entry.vectorSearch !== 'boolean') entry.vectorSearch = false;
    return entry;
}

export function ensureSessionMemoryBook(chatData, sessionId) {
    if (!chatData.memoryBooks) chatData.memoryBooks = {};
    if (!chatData.memoryBooks[sessionId]) {
        const globalSettings = getMemorySettings();
        chatData.memoryBooks[sessionId] = {
            id: `memorybook_${sessionId}`,
            entries: [],
            pendingDrafts: [],
            settings: { ...globalSettings },
            updatedAt: 0
        };
    }
    const memoryBook = chatData.memoryBooks[sessionId];
    if (!memoryBook.id) memoryBook.id = `memorybook_${sessionId}`;
    if (!Array.isArray(memoryBook.entries)) memoryBook.entries = [];
    if (!Array.isArray(memoryBook.pendingDrafts)) memoryBook.pendingDrafts = [];
    memoryBook.entries.forEach(normalizeMemoryEntryInPlace);
    memoryBook.pendingDrafts.forEach(normalizeMemoryEntryInPlace);
    if (!memoryBook.settings || typeof memoryBook.settings !== 'object') {
        memoryBook.settings = {};
    }
    normalizeMemorySettings(memoryBook.settings);
    if (!memoryBooksHasAutomationState(memoryBook)) {
        memoryBook.automation = createMemoryAutomationState();
    }
    if (!Number.isFinite(memoryBook.updatedAt)) memoryBook.updatedAt = 0;
    return memoryBook;
}
