import { BackgroundMode } from '@anuradev/capacitor-background-mode';
import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { startGenerationNotification, stopGenerationNotification } from '@/core/services/notificationService.js';
import { cleanText } from '@/utils/textFormatter.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { logger } from '../../utils/logger.js';

export async function executeRequest({
    apiUrl,
    apiKey,
    requestBody,
    stream,
    controller,
    requestReasoning,
    tagStart,
    tagEnd,
    callbacks
}) {
    const { onUpdate, onComplete, onError } = callbacks;
    const t = (key) => translations[currentLang.value]?.[key] || key;
    const headerModel = `<span style="color: var(--vk-blue); font-weight: 700; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px;">${t('reasoning_model')}</span>`;
    const headerInline = `<span style="color: var(--vk-blue); font-weight: 700; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px;">${t('reasoning_inline')}</span>`;

    const hasInlineTags = !!tagStart && !!tagEnd;

    // Timeout configuration (configurable via localStorage for future settings UI)
    const CONNECT_TIMEOUT = parseInt(localStorage.getItem('gz_api_connect_timeout')) || 90000;
    const STREAM_TIMEOUT = parseInt(localStorage.getItem('gz_api_stream_timeout')) || 120000;
    let connectTimer = null;
    let streamTimer = null;
    let timedOut = false;

    // Keep screen on during generation to prevent OS suspension
    let wakeLock = null;
    const requestWakeLock = async () => {
        if ('wakeLock' in navigator && document.visibilityState === 'visible') {
            try { wakeLock = await navigator.wakeLock.request('screen'); } catch (e) { console.warn("WakeLock error:", e); }
        }
    };
    await requestWakeLock();

    // Re-acquire lock if app comes back to foreground while generating
    const handleVisibilityChange = () => { if (document.visibilityState === 'visible') requestWakeLock(); };
    document.addEventListener('visibilitychange', handleVisibilityChange);

    // Keep app alive when backgrounded during generation
    const isAndroid = Capacitor.getPlatform() === 'android';
    const isIos = Capacitor.getPlatform() === 'ios';

    if (isAndroid) {
        await startGenerationNotification('Glaze', translations[currentLang.value]['model_typing'] || 'Generating...');
    } else if (isIos) {
        try {
            await BackgroundMode.enable();
        } catch (e) {
            console.warn("BackgroundMode enable failed:", e);
        }
    }

    let fullText = "";
    let rawAccumulated = "";
    let accumulatedReasoning = "";

    const headers = {
        'Content-Type': 'application/json'
    };
    if (apiKey) headers['Authorization'] = `Bearer ${apiKey}`;

    try {
        logger.debug("LLM Request Body:", JSON.stringify(requestBody, null, 2));

        // Bypass Mixed Content/Cleartext restrictions on Native for local HTTP
        // Use CapacitorHttp only for non-streaming requests.
        // For streaming, we fall through to standard fetch (requires android:usesCleartextTraffic="true")
        if (Capacitor.isNativePlatform() && apiUrl.startsWith('http:') && !apiUrl.includes('https:') && !stream) {
            const response = await CapacitorHttp.post({
                url: `${apiUrl}/chat/completions`,
                headers: headers,
                data: requestBody,
                responseType: 'json',
                connectTimeout: CONNECT_TIMEOUT,
                readTimeout: STREAM_TIMEOUT
            });

            if (response.status >= 400) {
                const errorData = typeof response.data === 'object' ? JSON.stringify(response.data) : String(response.data || '');
                throw new Error(`API Error: ${response.status} ${errorData}`);
            }

            const data = response.data;
            logger.debug("LLM Response (Native):", data);
            const content = data.choices[0].message.content;
            const rawReasoning = data.choices[0].message.reasoning_content;

            let finalText = content;
            let finalReasoning = requestReasoning ? (rawReasoning || "") : "";
            let inlineReasoning = "";

            if (hasInlineTags && content.includes(tagStart)) {
                const startIndex = content.indexOf(tagStart);
                const endIndex = content.indexOf(tagEnd, startIndex);
                if (endIndex !== -1) {
                    inlineReasoning = content.substring(startIndex + tagStart.length, endIndex);
                    finalText = content.substring(0, startIndex) + content.substring(endIndex + tagEnd.length);
                }
            }

            if (finalReasoning && inlineReasoning) {
                finalReasoning = `${headerModel}\n${finalReasoning}\n\n---\n\n${headerInline}\n${inlineReasoning}`;
            } else if (inlineReasoning) {
                finalReasoning = inlineReasoning;
            }

            if (onComplete) onComplete(cleanText(finalText), finalReasoning || null);

            // Exit function, finally block will still run for cleanup
            return;
        }

        // Connection timeout — abort if server doesn't respond
        connectTimer = setTimeout(() => { timedOut = true; if (controller) controller.abort(); }, CONNECT_TIMEOUT);

        const response = await fetch(`${apiUrl}/chat/completions`, {
            method: 'POST',
            headers: headers,
            body: JSON.stringify(requestBody),
            signal: controller ? controller.signal : undefined
        });

        clearTimeout(connectTimer);
        connectTimer = null;

        if (!response.ok) {
            let errText = "";
            try { errText = await response.text(); } catch (e) { }
            throw new Error(`API Error: ${response.status} ${errText}`);
        }

        if (stream) {
            const reader = response.body.getReader();
            const decoder = new TextDecoder("utf-8");
            let isFirst = true;
            let previousEffectiveText = "";

            const resetStreamTimer = () => {
                if (streamTimer) clearTimeout(streamTimer);
                streamTimer = setTimeout(() => { timedOut = true; if (controller) controller.abort(); }, STREAM_TIMEOUT);
            };
            resetStreamTimer();

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                resetStreamTimer();

                const chunk = decoder.decode(value, { stream: true });
                const lines = chunk.split('\n');

                for (const line of lines) {
                    const trimmed = line.trim();
                    if (!trimmed || !trimmed.startsWith('data: ')) continue;

                    const dataStr = trimmed.substring(6);
                    if (dataStr === '[DONE]') continue;

                    try {
                        const json = JSON.parse(dataStr);

                        if (json.error) {
                            throw new Error("API Stream Error: " + (json.error.message || JSON.stringify(json.error)));
                        }

                        if (!json.choices || !json.choices.length) continue;

                        const delta = json.choices[0].delta;
                        if (delta && (delta.content || delta.reasoning_content)) {
                            const content = delta.content || "";
                            const reasoning = (requestReasoning && delta.reasoning_content) || null;

                            if (content) logger.debug(content);

                            fullText += content;
                            rawAccumulated += content;
                            if (reasoning) accumulatedReasoning += reasoning;

                            // Process Outer CoT (Reasoning Tags)
                            let effectiveText = rawAccumulated;
                            let effectiveReasoning = "";

                            if (requestReasoning) {
                                effectiveReasoning = accumulatedReasoning || "";
                            }

                            let inlineReasoning = "";
                            if (hasInlineTags && rawAccumulated.includes(tagStart)) {
                                const startIndex = rawAccumulated.indexOf(tagStart);
                                const endIndex = rawAccumulated.indexOf(tagEnd, startIndex);
                                if (endIndex !== -1) {
                                    inlineReasoning = rawAccumulated.substring(startIndex + tagStart.length, endIndex);
                                    effectiveText = rawAccumulated.substring(0, startIndex) + rawAccumulated.substring(endIndex + tagEnd.length);
                                } else {
                                    inlineReasoning = rawAccumulated.substring(startIndex + tagStart.length);
                                    effectiveText = rawAccumulated.substring(0, startIndex);
                                }
                            }

                            if (effectiveReasoning && inlineReasoning) {
                                effectiveReasoning = `${headerModel}\n${effectiveReasoning}\n\n---\n\n${headerInline}\n${inlineReasoning}`;
                            } else if (inlineReasoning) {
                                effectiveReasoning = inlineReasoning;
                            }

                            // Strip leading whitespace and decode HTML entities
                            effectiveText = effectiveText.replace(/^\s+/, '')
                                .replace(/&amp;/g, '&')
                                .replace(/&gt;/g, '>')
                                .replace(/&lt;/g, '<')
                                .replace(/&quot;/g, '"')
                                .replace(/&apos;/g, "'");

                            // Buffer text ending in an incomplete HTML entity, flush it in the next delta
                            const incompleteEntity = effectiveText.match(/&[a-zA-Z0-9#]*$/);
                            if (incompleteEntity) {
                                effectiveText = effectiveText.substring(0, incompleteEntity.index);
                            }

                            let textDelta = null;
                            if (effectiveText.startsWith(previousEffectiveText)) {
                                textDelta = effectiveText.substring(previousEffectiveText.length);
                            }
                            previousEffectiveText = effectiveText;

                            if (onUpdate) onUpdate(content, reasoning, effectiveText, effectiveReasoning, textDelta);
                        }
                    } catch (e) {
                        if (e.message && e.message.startsWith("API Stream Error")) {
                            throw e;
                        }
                        console.warn("Error parsing stream chunk", e);
                    }
                }
            }

            if (streamTimer) { clearTimeout(streamTimer); streamTimer = null; }

            // Final processing for onComplete
            let finalReasoning = requestReasoning ? accumulatedReasoning : "";
            let finalText = fullText;
            let inlineReasoning = "";

            if (hasInlineTags && fullText.includes(tagStart)) {
                const startIndex = fullText.indexOf(tagStart);
                const endIndex = fullText.indexOf(tagEnd, startIndex);
                if (endIndex !== -1) {
                    inlineReasoning = fullText.substring(startIndex + tagStart.length, endIndex);
                    finalText = fullText.substring(0, startIndex) + fullText.substring(endIndex + tagEnd.length);
                }
            }

            if (finalReasoning && inlineReasoning) {
                finalReasoning = `${headerModel}\n${finalReasoning}\n\n---\n\n${headerInline}\n${inlineReasoning}`;
            } else if (inlineReasoning) {
                finalReasoning = inlineReasoning;
            }

            logger.debug("Stream finished:", finalText);

            if (onComplete) onComplete(cleanText(finalText), finalReasoning || null);

        } else {
            const data = await response.json();
            logger.debug("LLM Response:", data);
            const content = data.choices[0].message.content;
            const rawReasoning = data.choices[0].message.reasoning_content;

            let finalText = content;
            let finalReasoning = requestReasoning ? (rawReasoning || "") : "";
            let inlineReasoning = "";

            if (hasInlineTags && content.includes(tagStart)) {
                const startIndex = content.indexOf(tagStart);
                const endIndex = content.indexOf(tagEnd, startIndex);
                if (endIndex !== -1) {
                    inlineReasoning = content.substring(startIndex + tagStart.length, endIndex);
                    finalText = content.substring(0, startIndex) + content.substring(endIndex + tagEnd.length);
                }
            }

            if (finalReasoning && inlineReasoning) {
                finalReasoning = `${headerModel}\n${finalReasoning}\n\n---\n\n${headerInline}\n${inlineReasoning}`;
            } else if (inlineReasoning) {
                finalReasoning = inlineReasoning;
            }

            if (onComplete) onComplete(cleanText(finalText), finalReasoning || null);
        }
    } catch (e) {
        if (e.name === 'AbortError') {
            if (timedOut) {
                // Timeout-induced abort — treat as error, not user cancellation
                if (fullText.length > 0) {
                    if (onComplete) onComplete(cleanText(fullText), requestReasoning ? accumulatedReasoning : null, { partialError: "Generation timed out" });
                } else {
                    if (onError) onError(new Error("Generation timed out — no response from server"));
                }
                return;
            }

            // User-initiated abort — save partial text if available
            if (fullText.length > 0) {
                if (onComplete) onComplete(cleanText(fullText), requestReasoning ? accumulatedReasoning : null);
            } else {
                if (onError) onError(e);
            }
            return;
        }

        // Network error (connection abort, DNS failure, etc.) — save partial text cleanly
        if (fullText.length > 0) {
            console.warn("Network error during stream, saving partial response:", e);
            const errorMsg = e.message || "Stream Error";
            if (onComplete) onComplete(cleanText(fullText), requestReasoning ? accumulatedReasoning : null, { partialError: errorMsg });
            return;
        }

        if (onError) onError(e);
    } finally {
        if (connectTimer) clearTimeout(connectTimer);
        if (streamTimer) clearTimeout(streamTimer);
        document.removeEventListener('visibilitychange', handleVisibilityChange);
        if (wakeLock) {
            try { wakeLock.release(); } catch (e) { }
        }

        if (isAndroid) {
            await stopGenerationNotification();
        } else if (isIos) {
            try {
                await BackgroundMode.disable();
            } catch (e) { }
        }
    }
}