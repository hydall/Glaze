import { beforeEach, describe, expect, it, vi } from 'vitest';

const embeddingRecords = new Map();
const mockGetEmbeddings = vi.fn();
const mockExecuteRequest = vi.fn(async ({ callbacks }) => {
    callbacks?.onComplete?.('ok', null);
});

vi.mock('@/core/services/embeddingService.js', () => ({
    getEmbeddings: (...args) => mockGetEmbeddings(...args)
}));

vi.mock('@/utils/db.js', () => ({
    db: {
        get: vi.fn(async () => null),
        queuedSet: vi.fn(async () => undefined),
        getEmbedding: vi.fn(async (id) => embeddingRecords.get(id) || null),
        getEmbeddingsBySource: vi.fn(async (sourceType) => Array.from(embeddingRecords.values()).filter(v => v.sourceType === sourceType)),
        saveEmbedding: vi.fn(async (record) => {
            embeddingRecords.set(record.id, record);
        }),
        deleteEmbedding: vi.fn(async (id) => {
            embeddingRecords.delete(id);
        })
    }
}));

vi.mock('@/core/services/llmApi.js', () => ({
    executeRequest: (...args) => mockExecuteRequest(...args)
}));

vi.mock('@/core/services/notificationService.js', () => ({
    sendMessageNotification: vi.fn()
}));

vi.mock('@/core/states/bottomSheetState.js', () => ({
    showBottomSheet: vi.fn(),
    closeBottomSheet: vi.fn()
}));

class MockWorker {
    constructor() {
        this.onmessage = null;
        this.onerror = null;
    }

    postMessage(message) {
        const data = {
            messages: [
                { role: 'system', content: 'Base prompt block' },
                { role: 'user', content: 'Current user message', isHistory: true }
            ],
            loreEntries: [],
            staticTokens: 8,
            contextBreakdown: { lorebook: 0 },
            needsVarsSave: false,
            sessionVars: {}
        };

        queueMicrotask(() => {
            this.onmessage?.({ data: { id: message.id, success: true, data } });
        });
    }

    terminate() {}
}

globalThis.Worker = MockWorker;

const localStorageData = new Map();
globalThis.localStorage = {
    getItem(key) {
        return localStorageData.has(key) ? localStorageData.get(key) : null;
    },
    setItem(key, value) {
        localStorageData.set(key, String(value));
    },
    removeItem(key) {
        localStorageData.delete(key);
    },
    clear() {
        localStorageData.clear();
    }
};

if (!globalThis.crypto?.subtle) {
    const { webcrypto } = await import('node:crypto');
    Object.defineProperty(globalThis, 'crypto', {
        value: webcrypto,
        configurable: true
    });
}

const { lorebookState, indexLorebookEntries, vectorSearchLorebooks } = await import('../../states/lorebookState.js');
const { generateChatResponse, getLastPrompt } = await import('../generationService.js');

describe('Vector lorebook E2E verification', () => {
    beforeEach(() => {
        embeddingRecords.clear();
        localStorage.clear();
        mockGetEmbeddings.mockReset();
        mockExecuteRequest.mockClear();
        globalThis._genWorker = null;
        globalThis._workerQueue = new Map();
        globalThis._msgIdCounter = 0;

        localStorage.setItem('gz_embedding_enabled', 'true');
        localStorage.setItem('gz_embedding_use_same', 'false');
        localStorage.setItem('gz_embedding_endpoint', 'http://127.0.0.1:11434/v1');
        localStorage.setItem('gz_embedding_model', 'test-embedding-model');
        localStorage.setItem('gz_embedding_target', 'content');
        localStorage.setItem('gz_embedding_scan_depth', '5');
        localStorage.setItem('gz_embedding_threshold', '0.6');
        localStorage.setItem('gz_embedding_top_k', '5');

        localStorage.setItem('api-endpoint', 'http://127.0.0.1:1234/v1');
        localStorage.setItem('gz_api_endpoint_normalized', 'http://127.0.0.1:1234/v1');
        localStorage.setItem('api-model', 'test-llm');
        localStorage.setItem('api-max-tokens', '256');
        localStorage.setItem('api-context', '4096');
        localStorage.setItem('gz_api_stream', 'false');
        localStorage.setItem('gz_api_temp', '0.7');
        localStorage.setItem('gz_api_topp', '0.9');

        lorebookState.lorebooks = [
            {
                id: 'lb-vector',
                name: 'Vector QA',
                enabled: true,
                entries: [
                    {
                        id: 'entry-vector-only',
                        comment: 'Asei Vector QA',
                        keys: ['Asei'],
                        content: 'Asei has bright blue hair, cat ears, a fluffy tail, and heterochromia.',
                        enabled: true,
                        vectorSearch: true,
                        position: 'worldInfoBefore'
                    }
                ]
            }
        ];
    });

    it('indexes a vector-only entry and matches it semantically', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => {
            if (text.includes('bright blue hair')) return [1, 0, 0];
            return [0.98, 0.02, 0];
        }));

        const result = await indexLorebookEntries('lb-vector');
        expect(result.failed).toBe(0);
        expect(result.indexed).toBe(1);

        const matches = await vectorSearchLorebooks([], 'blue-haired catgirl with a fluffy tail', { id: 'char-1' }, 'chat-1');
        expect(matches).toHaveLength(1);
        expect(matches[0].id).toBe('entry-vector-only');
        expect(matches[0].comment).toBe('Asei Vector QA');
    });

    it('injects a vector-only entry into triggered lorebooks and final prompt', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => {
            if (text.includes('bright blue hair')) return [1, 0, 0];
            return [0.98, 0.02, 0];
        }));

        await indexLorebookEntries('lb-vector');

        let promptReadyPayload = null;
        await generateChatResponse({
            text: 'I am looking for the blue-haired catgirl with a fluffy tail.',
            char: { id: 'char-1', name: 'Tester', sessionId: 'chat-1' },
            history: [{ role: 'user', content: 'Tell me about the blue-haired catgirl.' }],
            authorsNote: null,
            summary: '',
            controller: { signal: { aborted: false } },
            callbacks: {
                onUpdate: vi.fn(),
                onComplete: vi.fn(),
                onError: vi.fn(),
                onPromptReady: (payload) => {
                    promptReadyPayload = payload;
                }
            }
        });

        expect(promptReadyPayload).toBeTruthy();
        expect(promptReadyPayload.loreEntries.some(entry => entry.id === 'entry-vector-only')).toBe(true);

        const lastPrompt = getLastPrompt();
        expect(lastPrompt).toBeTruthy();
        expect(lastPrompt.messages.some(message =>
            typeof message.content === 'string' && message.content.includes('bright blue hair, cat ears, a fluffy tail')
        )).toBe(true);
        expect(mockExecuteRequest).toHaveBeenCalledOnce();
    });

    it('fails generation with a visible error when embedding retrieval crashes', async () => {
        mockGetEmbeddings.mockImplementation(async (texts) => texts.map((text) => {
            if (text.includes('bright blue hair')) return [1, 0, 0];
            throw new Error('Embedding API Error: 503');
        }));

        await indexLorebookEntries('lb-vector');

        const onError = vi.fn();

        await generateChatResponse({
            text: 'Tell me about the blue-haired catgirl.',
            char: { id: 'char-1', name: 'Tester', sessionId: 'chat-1' },
            history: [{ role: 'user', content: 'Tell me about the blue-haired catgirl.' }],
            authorsNote: null,
            summary: '',
            controller: { signal: { aborted: false } },
            callbacks: {
                onUpdate: vi.fn(),
                onComplete: vi.fn(),
                onError,
                onPromptReady: vi.fn()
            }
        });

        expect(onError).toHaveBeenCalledOnce();
        expect(mockExecuteRequest).not.toHaveBeenCalled();
    });
});
