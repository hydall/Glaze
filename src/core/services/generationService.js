import { getApiConfig } from '@/core/config/APISettings.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { executeRequest } from '@/core/services/llmApi.js';
import { sendMessageNotification } from '@/core/services/notificationService.js';
import { presetState, initPresetState, getEffectivePreset } from '@/core/states/presetState.js';
import { lorebookState, scanLorebooks, initLorebookState, vectorSearchLorebooks } from '@/core/states/lorebookState.js';
import { getEffectivePersona } from '@/core/states/personaState.js';
import { applyRegexes } from '@/core/services/regexService.js';
import { db } from '@/utils/db.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { findTopK } from '@/utils/vectorMath.js';
import { logger } from '../../utils/logger.js';

let lastPrompt = null;

export function getLastPrompt() {
    return lastPrompt;
}

/**
 * Strips embedded base64 media from text so it doesn't inflate token counts limits.
 */
function stripEmbeddedMedia(text) {
    if (!text || text.length < 256) return text;
    let cleaned = text.replace(/<img\s[^>]*src\s*=\s*["']data:image\/[^"']{256,}["'][^>]*\/?>/gi, '');
    cleaned = cleaned.replace(/data:image\/[a-z+]+;base64,[A-Za-z0-9+/=\n\r]{256,}/gi, '');
    return cleaned;
}

// --- Helpers ---

function getEffectiveApiConfig() {
    let config = getApiConfig();
    let { maxTokens, contextSize } = config;

    // Fallback if contextSize is not returned by getApiConfig
    if (!contextSize) contextSize = parseInt(localStorage.getItem('api-context')) || 32000;
    if (maxTokens === undefined || maxTokens === null) {
        const mt = parseInt(localStorage.getItem('api-max-tokens'));
        maxTokens = isNaN(mt) ? 8000 : mt;
    }

    return { ...config, maxTokens, contextSize };
}

function loadActivePreset(char, sessionId) {
    if (!presetState.initialized) {
        // Synchronous-ish check or just init (will be handled by reactive update anyway mostly)
    }
    const charId = char?.id;
    const chatId = charId && sessionId ? `${charId}_${sessionId}` : null;
    return getEffectivePreset(charId, chatId);
}

function getWorker() {
    if (!globalThis._genWorker) {
        globalThis._genWorker = new Worker(new URL('../../workers/generationWorker.js', import.meta.url), { type: 'module' });
        globalThis._workerQueue = new Map();
        globalThis._msgIdCounter = 0;

        globalThis._genWorker.onmessage = (e) => {
            const { id, success, data, error } = e.data;
            if (globalThis._workerQueue.has(id)) {
                if (success) globalThis._workerQueue.get(id).resolve(data);
                else globalThis._workerQueue.get(id).reject(new Error(error));
                globalThis._workerQueue.delete(id);
            }
        };

        globalThis._genWorker.onerror = (e) => {
            console.error("Generation worker crashed:", e);
            for (const [id, { reject }] of globalThis._workerQueue) {
                reject(new Error("Worker crashed: " + (e.message || "Unknown error")));
            }
            globalThis._workerQueue.clear();
            globalThis._genWorker.terminate();
            globalThis._genWorker = null;
        };
    }
    return globalThis._genWorker;
}

function processPromptAsync(payload) {
    const worker = getWorker();
    const WORKER_TIMEOUT = 30000;
    return new Promise((resolve, reject) => {
        const id = ++globalThis._msgIdCounter;

        const timer = setTimeout(() => {
            globalThis._workerQueue.delete(id);
            reject(new Error("Prompt building timed out (worker did not respond within 30s)"));
        }, WORKER_TIMEOUT);

        globalThis._workerQueue.set(id, {
            resolve: (data) => { clearTimeout(timer); resolve(data); },
            reject: (err) => { clearTimeout(timer); reject(err); }
        });
        worker.postMessage({ id, type: 'generateChatResponse', payload });
    });
}

export async function generateChatResponse({
    text,
    char,
    history,
    authorsNote,
    summary,
    guidanceText,
    type = 'normal',
    controller,
    callbacks
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    let apiConfig = getEffectiveApiConfig();
    let { apiKey, apiUrl, model, stream, requestReasoning, reasoningEffort, temp, topP, maxTokens, contextSize } = apiConfig;

    const t = (key) => translations[currentLang.value]?.[key] || key;

    if (!apiUrl || !model) {
        showBottomSheet({
            title: t('section_connection') || "Connection",
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                description: t('api_not_configured') || "API Not Configured",
                buttonText: t('btn_configure') || "Configure",
                onButtonClick: () => {
                    closeBottomSheet();
                    window.dispatchEvent(new CustomEvent('open-api-sheet'));
                }
            }
        });
        if (onError) onError(new Error("API Not Configured"));
        return;
    }

    // --- Prompt Construction based on Preset ---
    const activePreset = loadActivePreset(char, char?.sessionId);

    // Reasoning Tags from Preset
    const tagStart = activePreset?.reasoningStart || localStorage.getItem('gz_api_reasoning_start');
    const tagEnd = activePreset?.reasoningEnd || localStorage.getItem('gz_api_reasoning_end');

    // Merge Settings from Preset
    const mergePrompts = activePreset?.mergePrompts || false;
    const mergeRole = activePreset?.mergeRole || 'system';

    // NoAssistant Settings from Preset
    const noAssistant = activePreset?.noAssistant || false;
    const stopString = activePreset?.stopString || '';
    const userPrefix = activePreset?.userPrefix || '';
    const charPrefix = activePreset?.charPrefix || '';
    const squashRole = activePreset?.squashRole || 'assistant';

    if (activePreset && typeof activePreset.reasoningEnabled === 'boolean') {
        requestReasoning = activePreset.reasoningEnabled;
    }
    if (activePreset && activePreset.reasoningEffort) {
        reasoningEffort = activePreset.reasoningEffort;
    }

    // Get Persona object for macros
    const personaObj = getEffectivePersona(char?.id, char?.sessionId) || { name: "User", prompt: "" };

    const charId = char?.id || "default";
    const sessionId = char?.sessionId || "current";
    const varsKey = `gz_vars_${charId}_${sessionId}`;
    let sessionVars = {};
    try { sessionVars = JSON.parse(localStorage.getItem(varsKey)) || {}; } catch (e) { }

    let globalRegexes = [];
    try { globalRegexes = JSON.parse(localStorage.getItem('regex_scripts')) || []; } catch (e) { }

    let result;
    let safeHistory = history;
    try {
        const safeContextLimit = contextSize - maxTokens > 0 ? contextSize - maxTokens : 8000;
        const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent || '');
        const memoryLimitFactor = isIOS ? 15 : 5;
        const maxHistoryRetention = Math.max(100, Math.ceil(safeContextLimit / memoryLimitFactor));

        if (history && history.length > maxHistoryRetention) {
            safeHistory = history.slice(-maxHistoryRetention);
        }

        const payload = JSON.parse(JSON.stringify({
            char,
            history: safeHistory,
            summary,
            activePreset,
            mergePrompts,
            mergeRole,
            noAssistant,
            userPrefix,
            charPrefix,
            squashRole,
            personaObj,
            authorsNote: (authorsNote && authorsNote.enabled) ? authorsNote : null,
            guidanceText,
            guidanceType: type,
            lorebooks: lorebookState.lorebooks,
            globalSettings: lorebookState.globalSettings,
            activations: lorebookState.activations,
            globalRegexes,
            sessionVars,
            apiConfig
        }));

        result = await processPromptAsync(payload);
    } catch (e) {
        console.error("Worker error:", e);
        if (onError) onError(e);
        return;
    }

    // Guard: if aborted while worker was building prompt, don't send API request
    if (controller?.signal?.aborted) {
        if (onError) onError(new DOMException('Aborted', 'AbortError'));
        return;
    }

    if (result.needsVarsSave) {
        localStorage.setItem(varsKey, JSON.stringify(result.sessionVars));
    }

    let newVectorEntries = [];
    try {
        const vectorResults = await vectorSearchLorebooks(safeHistory || history, text, char, char?.sessionId);
        if (vectorResults.length > 0 && result.loreEntries) {
            const keywordIds = new Set(result.loreEntries.map(e => e.id));
            newVectorEntries = vectorResults.filter(e => !keywordIds.has(e.id));
            result.loreEntries = [...result.loreEntries, ...newVectorEntries];
        }
    } catch (e) {
        console.warn('[generateChatResponse] Vector search failed:', e);
        showBottomSheet({
            title: t('title_error') || 'Error',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff9500"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: t('msg_vector_generation_failed') || 'The embedding model did not respond during generation, so vector lorebook retrieval could not complete.',
                buttonText: t('btn_ok') || 'OK',
                onButtonClick: () => closeBottomSheet()
            }
        });
        if (onError) onError(e);
        return;
    }

    const safeContext = contextSize - maxTokens;
    const memoryInjection = await buildMemoryInjection({
        char,
        history: safeHistory || history,
        summary,
        safeContext
    });
    let messages = result.messages;

    if (memoryInjection.messages.length > 0) {
        messages = injectMemoryMessages(messages, memoryInjection, {
            injectionTarget: memoryInjection.injectionTarget
        });
    }

    if (newVectorEntries.length > 0) {
        const vectorLoreMessages = newVectorEntries
            .map(entry => {
                const content = entry.content || '';
                const tokens = estimateTokens(content);
                return {
                    role: 'system',
                    content,
                    blockName: `Lorebook: ${entry.comment || entry.keys?.[0] || 'Entry'}`,
                    isLorebook: true,
                    sources: tokens > 0 ? [{ source: 'lorebook', tokens }] : [],
                    _allSources: tokens > 0 ? [{ source: 'lorebook', tokens }] : []
                };
            })
            .filter(msg => msg.content && msg.content.trim().length > 0);

        if (vectorLoreMessages.length > 0) {
            messages = injectVectorLoreMessages(messages, vectorLoreMessages);

            // Re-apply history trimming after late vector lore injection so we don't blow the effective context.
            const staticMessages = messages.filter(m => !m.isHistory);
            const historyMessages = messages.filter(m => m.isHistory);
            let staticTokens = 0;
            for (const msg of staticMessages) {
                staticTokens += estimateTokens(msg.content || '');
            }

            if (staticTokens >= safeContext) {
                messages = staticMessages;
            } else {
                let remainingHistoryBudget = safeContext - staticTokens;
                let includedHistoryCount = 0;
                let currentHistoryTokens = 0;

                for (let i = historyMessages.length - 1; i >= 0; i--) {
                    const tokens = estimateTokens(historyMessages[i].content || '');
                    if (currentHistoryTokens + tokens <= remainingHistoryBudget) {
                        currentHistoryTokens += tokens;
                        includedHistoryCount++;
                    } else {
                        break;
                    }
                }

                const keptHistoryMessages = historyMessages.slice(historyMessages.length - includedHistoryCount);
                messages = [
                    ...staticMessages,
                    ...keptHistoryMessages
                ];
            }
        }
    }

    if (result.staticTokens >= safeContext) {
        showBottomSheet({
            title: t('error_context_limit') || "Context Limit Exceeded",
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;color:#ff4444"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                description: t('msg_context_limit') || "The preset prompts exceed the context limit. Please increase Context Size or reduce prompt length.",
                glossaryChip: { term: 'context', hint: t('context_limit_glossary_hint') || 'Learn more:', label: t('context_limit_glossary_chip') || 'Context' },
                buttonText: t('btn_ok') || "OK",
                onButtonClick: () => closeBottomSheet()
            }
        });
        if (onError) onError(new Error("Context limit exceeded"));
        return;
    }

    if (callbacks.onPromptReady) {
        const contextBreakdown = result.contextBreakdown
            ? {
                ...result.contextBreakdown,
                memory: memoryInjection.tokens || 0,
                summaryBase: result.contextBreakdown.summary || 0,
                summary: (result.contextBreakdown.summary || 0) + (memoryInjection.tokens || 0),
                fixedBase: (result.contextBreakdown.fixedBase || 0) + (memoryInjection.tokens || 0),
                fixedTotal: (result.contextBreakdown.fixedTotal || 0) + (memoryInjection.tokens || 0),
                totalUsed: (result.contextBreakdown.totalUsed || 0) + (memoryInjection.tokens || 0),
                remaining: Math.max(0, (result.contextBreakdown.remaining || 0) - (memoryInjection.tokens || 0))
            }
            : null;
        callbacks.onPromptReady({
            loreEntries: result.loreEntries,
            memoryEntries: memoryInjection.entries,
            contextBreakdown
        });
    }

    const requestBody = {
        model: model,
        messages: messages,
        temperature: temp,
        top_p: topP,
        stream: stream,
        reasoning_effort: reasoningEffort || 'medium'
    };

    if (maxTokens > 0) {
        requestBody.max_tokens = maxTokens;
    }

    if (stopString) {
        requestBody.stop = [stopString];
    }


    // Save for preview
    lastPrompt = JSON.parse(JSON.stringify(requestBody));

    // Sanitize messages for API (strict OpenAI compliance: only role, content, name)
    requestBody.messages = requestBody.messages.map(m => {
        const cleanMsg = {
            role: m.role,
            content: stripEmbeddedMedia(m.content)
        };

        if (m.image) {
            cleanMsg.content = [
                { type: "text", text: m.content || "" },
                { type: "image_url", image_url: { url: m.image } }
            ];
        }

        if (m.name) cleanMsg.name = m.name;
        return cleanMsg;
    });

    // Call LLM API
    try {
        logger.debug('[GenerationService] Final Request:', requestBody);
        await executeRequest({
            apiUrl,
            apiKey,
            requestBody,
            stream,
            controller,
            requestReasoning,
            tagStart,
            tagEnd,
            callbacks: { onUpdate, onComplete, onError }
        });
    } catch (e) {
        console.error("Generation error:", e);
        sendMessageNotification(
            t('error_generation') || "Generation Error",
            e.message,
            null,
            char?.id,
            null, // sessionId unknown here in catch block context easily without refactor
            null  // msgId
        );
        if (onError) onError(e);
    }
}

export async function calculateContext({ char, history, authorsNote, summary }) {
    const apiConfig = getEffectiveApiConfig();
    const activePreset = loadActivePreset(char, char?.sessionId);

    const mergePrompts = activePreset?.mergePrompts || false;
    const mergeRole = activePreset?.mergeRole || 'system';
    const noAssistant = activePreset?.noAssistant || false;
    const userPrefix = activePreset?.userPrefix || '';
    const charPrefix = activePreset?.charPrefix || '';
    const squashRole = activePreset?.squashRole || 'assistant';
    const personaObj = getEffectivePersona(char?.id, char?.sessionId) || { name: "User", prompt: "" };

    const anData = authorsNote;

    const charId = char?.id || "default";
    const sessionId = char?.sessionId || "current";
    const varsKey = `gz_vars_${charId}_${sessionId}`;
    let sessionVars = {};
    try { sessionVars = JSON.parse(localStorage.getItem(varsKey)) || {}; } catch (e) { }

    let globalRegexes = [];
    try { globalRegexes = JSON.parse(localStorage.getItem('regex_scripts')) || []; } catch (e) { }

    try {
        const safeContextLimit = apiConfig.contextSize - apiConfig.maxTokens > 0 ? apiConfig.contextSize - apiConfig.maxTokens : 8000;
        const isIOS = typeof navigator !== 'undefined' && /iPad|iPhone|iPod/.test(navigator.userAgent || '');
        const memoryLimitFactor = isIOS ? 15 : 5;
        const maxHistoryRetention = Math.max(100, Math.ceil(safeContextLimit / memoryLimitFactor));

        let safeHistory = history;
        if (history && history.length > maxHistoryRetention) {
            safeHistory = history.slice(-maxHistoryRetention);
        }

        const payload = JSON.parse(JSON.stringify({
            char,
            history: safeHistory,
            summary,
            activePreset,
            mergePrompts,
            mergeRole,
            noAssistant,
            userPrefix,
            charPrefix,
            squashRole,
            personaObj,
            authorsNote: (anData && anData.enabled) ? anData : null,
            lorebooks: lorebookState.lorebooks,
            globalSettings: lorebookState.globalSettings,
            activations: lorebookState.activations,
            globalRegexes,
            sessionVars,
            apiConfig
        }));

        const result = await processPromptAsync(payload);
        const memoryInjection = await buildMemoryInjection({
            char,
            history: safeHistory,
            summary,
            safeContext: safeContextLimit
        });

        const resolvedCutoff = result.cutoffOriginalIndex !== undefined && result.cutoffOriginalIndex !== -1
            ? result.cutoffOriginalIndex
            : result.cutoffIndex;

        const contextBreakdown = result.contextBreakdown
            ? {
                ...result.contextBreakdown,
                memory: memoryInjection.tokens || 0,
                summaryBase: result.contextBreakdown.summary || 0,
                summary: (result.contextBreakdown.summary || 0) + (memoryInjection.tokens || 0),
                fixedBase: (result.contextBreakdown.fixedBase || 0) + (memoryInjection.tokens || 0),
                fixedTotal: (result.contextBreakdown.fixedTotal || 0) + (memoryInjection.tokens || 0),
                totalUsed: (result.contextBreakdown.totalUsed || 0) + (memoryInjection.tokens || 0),
                remaining: Math.max(0, (result.contextBreakdown.remaining || 0) - (memoryInjection.tokens || 0))
            }
            : null;

        return {
            cutoffIndex: resolvedCutoff,
            contextBreakdown
        };
    } catch (e) {
        console.error("Calculate context worker error", e);
        return {
            cutoffIndex: 0,
            contextBreakdown: null
        };
    }
}

export async function generateSummary({ history, prompt, controller, apiConfigOverride = null }) {
    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { apiKey, apiUrl, model, temp } = effectiveConfig;

    if (!apiUrl || !model) {
        throw new Error("API Not Configured");
    }

    const defaultPrompt = "Summarize the following roleplay conversation concisely, focusing on the current situation and key events:\n\n{{history}}";
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    let result = "";

    await executeRequest({
        apiUrl,
        apiKey,
        requestBody: {
            model,
            messages: [{ role: 'user', content: finalPrompt }],
            temperature: temp
        },
        controller,
        callbacks: {
            onComplete: (text) => { result = text; }
        }
    });

    return result;
}

function normalizeMessageIdList(entry) {
    if (!entry || typeof entry !== 'object') return [];
    if (Array.isArray(entry.messageIds)) return [...new Set(entry.messageIds.filter(Boolean))];
    const ids = [];
    if (entry.messageRange?.startMessageId) ids.push(entry.messageRange.startMessageId);
    if (entry.messageRange?.endMessageId && entry.messageRange.endMessageId !== entry.messageRange.startMessageId) ids.push(entry.messageRange.endMessageId);
    return [...new Set(ids.filter(Boolean))];
}

function buildSummaryExcerpt(summary) {
    if (!summary) return '';
    if (typeof summary === 'string') return summary.trim().slice(0, 800);
    if (typeof summary === 'object') {
        if (typeof summary.content === 'string') return summary.content.trim().slice(0, 800);
        return ['timeline', 'characterArcs', 'conflictsThreads', 'notHappenedYet', 'notes']
            .map(key => summary[key])
            .filter(value => typeof value === 'string' && value.trim())
            .join('\n\n')
            .slice(0, 800);
    }
    return '';
}

function escapeRegex(string) {
    return String(string || '').replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

const GLAZE_BOUNDARIES = '[\\s.,!?;:"\'\u201C\u201D\u2018\u2019\u00AB\u00BB(){}\\[\\]—–]';

function tryCreateRegex(pattern, flags = 'g') {
    try {
        return new RegExp(pattern, flags);
    } catch {
        return null;
    }
}

function normalizeHybridText(text = '') {
    return String(text || '')
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\s-]+/gu, ' ')
        .replace(/\s+/g, ' ')
        .trim();
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

function extractMemoryRetrievalHints(entry) {
    const hints = [];
    if (entry?.title) hints.push(String(entry.title));
    if (Array.isArray(entry?.keys)) hints.push(...entry.keys.map(v => String(v)));
    if (Array.isArray(entry?.glazeKeys)) hints.push(...entry.glazeKeys.map(v => String(v)));
    const content = String(entry?.content || '');
    if (content) {
        const lines = content.split(/\r?\n/).map(line => line.trim()).filter(Boolean).slice(0, 8);
        hints.push(...lines);
    }
    return uniqueStrings(hints, 32);
}

function checkKeyMatch(key, text, { glaze = false, caseSensitive = false } = {}) {
    if (!key || !text) return false;
    const sourceText = String(text || '');
    const sourceKey = String(key || '');
    const flags = caseSensitive ? '' : 'i';
    if (glaze) {
        const escaped = escapeRegex(sourceKey);
        const regex = tryCreateRegex(`(?:^|${GLAZE_BOUNDARIES})${escaped}(?:$|${GLAZE_BOUNDARIES})`, flags);
        return regex ? regex.test(sourceText) : false;
    }
    const regex = tryCreateRegex(`\\b${escapeRegex(sourceKey)}\\b`, flags);
    if (regex && regex.test(sourceText)) return true;
    const haystack = caseSensitive ? sourceText : sourceText.toLowerCase();
    const needle = caseSensitive ? sourceKey : sourceKey.toLowerCase();
    return haystack.includes(needle);
}

async function vectorSearchMemoryEntries(entries, history = [], currentText = '') {
    const config = getEmbeddingConfig();
    if (!config.enabled || !isEmbeddingConfigured()) return [];
    const vectorEntries = entries.filter(entry => entry?.vectorSearch);
    if (!vectorEntries.length) return [];

    const allEmbeddings = await db.getEmbeddingsBySource('memory_entry');
    const embeddingMap = new Map(allEmbeddings.map(e => [e.id, e]));
    const candidates = vectorEntries
        .map(entry => {
            const emb = embeddingMap.get(entry.id);
            return emb?.vector ? { ...entry, vector: emb.vector, retrievalHints: emb.retrievalHints || [] } : null;
        })
        .filter(Boolean);
    if (!candidates.length) return [];

    const recentHistory = history.slice(-(config.scanDepth || 5));
    const focusedQueryParts = recentHistory.filter(m => m.role === 'user').map(m => m.content).filter(Boolean);
    if (currentText && currentText.trim()) focusedQueryParts.push(currentText.trim());
    const queryText = focusedQueryParts.join('\n').trim();
    if (!queryText) return [];

    const queryVectors = await getEmbeddings([queryText]);
    if (!queryVectors || !queryVectors[0]) return [];

    return findTopK(queryVectors[0], candidates, candidates.length, 0)
        .filter(result => result.score >= (config.threshold || 0.6))
        .slice(0, config.topK || 5)
        .map(result => ({ ...result, vectorScore: result.score, vector: undefined }));
}

async function ensureMemoryEntryEmbedding(entry, charId, sessionId) {
    if (!entry?.id || !entry.vectorSearch || !isEmbeddingConfigured()) return;
    const config = getEmbeddingConfig();
    if (!config.enabled) return;
    const text = (config.target === 'keys'
        ? [...(entry.keys || []), ...(entry.glazeKeys || [])].join(', ')
        : String(entry.content || '')).trim();
    if (!text) return;
    const existing = await db.getEmbedding(entry.id);
    const retrievalHints = extractMemoryRetrievalHints(entry);
    const textHash = JSON.stringify({ text, retrievalHints });
    if (existing && existing.textHash === textHash) return;
    const vectors = await getEmbeddings([text]);
    if (!vectors || !vectors[0]) return;
    await db.saveEmbedding({
        id: entry.id,
        sourceType: 'memory_entry',
        sourceId: `memorybook_${charId}_${sessionId}`,
        vector: vectors[0],
        textHash,
        retrievalHints,
        updatedAt: Date.now()
    });
}

export async function indexMemoryEntryForSession(entry, charId, sessionId) {
    await ensureMemoryEntryEmbedding(entry, charId, sessionId);
}

export async function deleteMemoryEntryIndex(entryId) {
    if (!entryId) return;
    await db.deleteEmbedding(entryId);
}

async function buildMemoryInjection({ char, history, summary, safeContext }) {
    const charId = char?.id;
    const sessionId = char?.sessionId;
    if (!charId || !sessionId) return { messages: [], entries: [], tokens: 0, injectionTarget: 'summary_block', macroContent: '' };

    const chatData = await db.getChat(charId);
    const memoryBook = chatData?.memoryBooks?.[sessionId];
    const settings = memoryBook?.settings || {};
    const activeEntries = (Array.isArray(memoryBook?.entries) ? memoryBook.entries : [])
        .filter(entry => entry && (entry.status || 'active') === 'active' && (entry.content || '').trim());

    if (!settings.enabled || !activeEntries.length) return { messages: [], entries: [], tokens: 0, injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block', macroContent: '' };

    const recentHistory = Array.isArray(history) ? history.slice(-12) : [];
    const historyText = recentHistory.map(item => item?.content || item?.text || '').filter(Boolean).join('\n').toLowerCase();
    const recentMessageIds = new Set(recentHistory.map(item => item?.messageId).filter(Boolean));
    const recentLabels = new Set();
    recentHistory.forEach(item => {
        (Array.isArray(item?.contextRefs) ? item.contextRefs : []).forEach(ref => {
            if (ref?.label) recentLabels.add(String(ref.label).toLowerCase());
        });
    });

    const uniqueWords = [...new Set(historyText.match(/[\p{L}\p{N}_-]{4,}/gu) || [])].slice(0, 40);
    const currentText = recentHistory[recentHistory.length - 1]?.content || '';
    const keywordMatchedIds = new Set();
    const scanText = `${recentHistory.map(item => item?.content || '').join('\n')}\n${currentText}`;
    const keyMatchMode = ['plain', 'glaze', 'both'].includes(settings.keyMatchMode) ? settings.keyMatchMode : 'plain';

    activeEntries.forEach(entry => {
        const directKeys = Array.isArray(entry.keys) ? entry.keys : [];
        const plainMatch = keyMatchMode !== 'glaze' && directKeys.some(key => checkKeyMatch(key, scanText));
        const glazeMatch = keyMatchMode !== 'plain' && directKeys.some(key => checkKeyMatch(key, scanText, { glaze: true }));
        if (plainMatch || glazeMatch) {
            keywordMatchedIds.add(entry.id);
        }
    });

    const vectorResults = await vectorSearchMemoryEntries(activeEntries, history, currentText).catch(() => []);
    const vectorScores = new Map(vectorResults.map(item => [item.id, item.vectorScore || item.score || 0]));
    const scoredEntries = activeEntries.map((entry, index) => {
        const haystack = `${entry.title || ''}\n${entry.content || ''}`.toLowerCase();
        const messageIds = normalizeMessageIdList(entry);
        let score = 0;
        if (messageIds.some(id => recentMessageIds.has(id))) score += 8;
        if (keywordMatchedIds.has(entry.id)) score += 6;
        if (vectorScores.has(entry.id)) score += Math.max(0, (vectorScores.get(entry.id) || 0) * 5);
        (Array.isArray(entry.contextRefs) ? entry.contextRefs : []).forEach(ref => {
            const label = String(ref?.label || '').toLowerCase();
            if (label && recentLabels.has(label)) score += 3;
        });
        uniqueWords.forEach(word => {
            if (haystack.includes(word)) score += 1;
        });
        score += Math.min(3, index / Math.max(activeEntries.length, 1));
        return { entry, score };
    });

    const topEntries = scoredEntries
        .filter(item => item.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, Math.max(1, Math.min(5, settings.maxInjectedEntries || 3)))
        .map(item => item.entry);

    if (!topEntries.length) return { messages: [], entries: [], tokens: 0, injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block', macroContent: '' };

    const summaryExcerpt = buildSummaryExcerpt(summary);
    const macroContent = topEntries
        .map(entry => (entry.content || '').trim())
        .filter(Boolean)
        .join('\n\n');
    const content = [
        summaryExcerpt ? `Summary excerpt:\n${summaryExcerpt}` : '',
        'Memory context:',
        ...topEntries.map(entry => `- ${(entry.title || 'Memory').trim()}: ${(entry.content || '').trim()}`)
    ].filter(Boolean).join('\n\n');
    const tokens = estimateTokens(content);
    if (!content || tokens <= 0 || tokens >= Math.max(256, Math.floor(safeContext * 0.35))) {
        return { messages: [], entries: [], tokens: 0, injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block', macroContent: '' };
    }

    return {
        messages: [{
            role: 'system',
            content,
            blockName: 'Memory Book',
            isMemory: true,
            sources: [{ source: 'memory', tokens }],
            _allSources: [{ source: 'memory', tokens }]
        }],
        entries: topEntries,
        tokens,
        injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
        macroContent
    };
}

function findSummaryInsertIndex(messages) {
    return messages.findIndex(msg => Array.isArray(msg?.sources) && msg.sources.some(source => source?.source === 'summary'));
}

function injectMemoryIntoSummaryMacro(messages, memoryInjection) {
    if (!memoryInjection?.macroContent) return messages;

    const summaryIndex = findSummaryInsertIndex(messages);
    if (summaryIndex === -1) return null;

    const summaryMessage = messages[summaryIndex];
    const existingContent = String(summaryMessage?.content || '').trim();
    const appendedContent = existingContent
        ? `${existingContent}\n\n${memoryInjection.macroContent}`
        : memoryInjection.macroContent;

    const nextSources = Array.isArray(summaryMessage?.sources) ? [...summaryMessage.sources] : [];
    const memorySource = nextSources.find(source => source?.source === 'memory');
    if (memorySource) memorySource.tokens += memoryInjection.tokens || 0;
    else if ((memoryInjection.tokens || 0) > 0) nextSources.push({ source: 'memory', tokens: memoryInjection.tokens || 0 });

    const nextAllSources = Array.isArray(summaryMessage?._allSources) ? [...summaryMessage._allSources] : [];
    if ((memoryInjection.tokens || 0) > 0) nextAllSources.push({ source: 'memory', tokens: memoryInjection.tokens || 0 });

    return [
        ...messages.slice(0, summaryIndex),
        {
            ...summaryMessage,
            content: appendedContent,
            sources: nextSources,
            _allSources: nextAllSources
        },
        ...messages.slice(summaryIndex + 1)
    ];
}

function injectMemoryMessages(messages, memoryInjection, settings = {}) {
    if (!memoryInjection?.messages?.length) return messages;

    const injectionTarget = settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block';
    if (injectionTarget === 'summary_macro') {
        const macroInjected = injectMemoryIntoSummaryMacro(messages, memoryInjection);
        if (macroInjected) {
            return macroInjected;
        }
    }

    const firstHistoryIndex = messages.findIndex(m => m.isHistory);
    if (firstHistoryIndex === -1) {
        return [...messages, ...memoryInjection.messages];
    }
    return [
        ...messages.slice(0, firstHistoryIndex),
        ...memoryInjection.messages,
        ...messages.slice(firstHistoryIndex)
    ];
}

function injectVectorLoreMessages(messages, loreEntries) {
    if (!Array.isArray(loreEntries) || !loreEntries.length) return messages;

    const combinedContent = loreEntries.map(msg => msg.content || '').filter(Boolean).join('\n\n');
    if (!combinedContent) return messages;

    const sourceMap = new Map();
    for (const item of loreEntries.flatMap(msg => msg._allSources || msg.sources || [])) {
        if (!item?.source) continue;
        sourceMap.set(item.source, (sourceMap.get(item.source) || 0) + (item.tokens || 0));
    }
    const combinedSources = [...sourceMap.entries()].map(([source, tokens]) => ({ source, tokens }));
    const combinedMessage = {
        role: 'system',
        content: combinedContent,
        blockName: 'Vector Lorebook',
        isLorebook: true,
        sources: combinedSources,
        _allSources: combinedSources
    };

    const firstHistoryIndex = messages.findIndex(m => m.isHistory);
    if (firstHistoryIndex === -1) {
        return [...messages, combinedMessage];
    }
    return [
        ...messages.slice(0, firstHistoryIndex),
        combinedMessage,
        ...messages.slice(firstHistoryIndex)
    ];
}

export async function generateMemoryDraft({ history, prompt, controller, apiConfigOverride = null }) {
    const effectiveConfig = {
        ...getEffectiveApiConfig(),
        ...(apiConfigOverride || {})
    };
    const { apiKey, apiUrl, model, temp } = effectiveConfig;

    if (!apiUrl || !model) {
        throw new Error("API Not Configured");
    }

    const defaultPrompt = [
        'Create exactly one concise long-term memory entry from the following roleplay segment.',
        'Preserve the original language of the source segment. Do not translate it.',
        'Use only facts that are explicitly supported by the segment.',
        'Do not infer completed outcomes, registrations, approvals, or decisions unless the text clearly states them.',
        'Focus on durable facts, developments, or relationship changes that should persist beyond immediate context.',
        'Do not copy the dialogue verbatim.',
        'Return only the memory entry text with no preface, label, or explanation.',
        '',
        '{{history}}'
    ].join('\n');
    const template = prompt || defaultPrompt;

    let finalPrompt = template.replace('{{history}}', history);
    if (!template.includes('{{history}}')) {
        finalPrompt = `${template}\n\n${history}`;
    }

    let result = "";

    await executeRequest({
        apiUrl,
        apiKey,
        requestBody: {
            model,
            messages: [{ role: 'user', content: finalPrompt }],
            temperature: temp
        },
        controller,
        callbacks: {
            onComplete: (text) => { result = text; }
        }
    });

    return result;
}
