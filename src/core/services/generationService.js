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
    let messages = result.messages;

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
            const firstHistoryIndex = messages.findIndex(m => m.isHistory);
            if (firstHistoryIndex === -1) {
                messages = [...messages, ...vectorLoreMessages];
            } else {
                messages = [
                    ...messages.slice(0, firstHistoryIndex),
                    ...vectorLoreMessages,
                    ...messages.slice(firstHistoryIndex)
                ];
            }

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
        callbacks.onPromptReady({
            loreEntries: result.loreEntries,
            contextBreakdown: result.contextBreakdown || null
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

        const resolvedCutoff = result.cutoffOriginalIndex !== undefined && result.cutoffOriginalIndex !== -1
            ? result.cutoffOriginalIndex
            : result.cutoffIndex;

        return {
            cutoffIndex: resolvedCutoff,
            contextBreakdown: result.contextBreakdown || null
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
