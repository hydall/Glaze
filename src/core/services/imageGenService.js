import { t } from '@/utils/i18n.js';
import { startGenerationNotification, stopGenerationNotification } from '@/core/services/notificationService.js';
import { addNotification } from '@/core/states/notificationsState.js';

/**
 * Image Generation Service for Glaze
 *
 * Parses [IMG:GEN:{...}] and <img data-iig-instruction='...' src="[IMG:GEN]"> tags
 * in AI messages and generates images via configured API.
 * Supports OpenAI-compatible, Gemini-compatible, and Naistera endpoints.
 */

// ---- Settings ----

const SETTINGS_KEY = {
    enabled: 'gz_imggen_enabled',
    apiType: 'gz_imggen_api_type',
    endpoint: 'gz_imggen_endpoint',
    apiKey: 'gz_imggen_api_key',
    model: 'gz_imggen_model',
    size: 'gz_imggen_size',
    quality: 'gz_imggen_quality',
    aspectRatio: 'gz_imggen_aspect_ratio',
    imageSize: 'gz_imggen_image_size',
    // Naistera
    naisteraModel: 'gz_imggen_naistera_model',
    naisteraAspectRatio: 'gz_imggen_naistera_aspect_ratio',
    naisteraSendCharAvatar: 'gz_imggen_naistera_send_char_avatar',
    naisteraSendUserAvatar: 'gz_imggen_naistera_send_user_avatar',
    // Image context
    imageContextEnabled: 'gz_imggen_image_context_enabled',
    imageContextCount: 'gz_imggen_image_context_count',
};

const ADDITIONAL_REFS_KEY = 'gz_imggen_additional_refs';

function sanitizeHeaderValue(val) {
    return String(val || '').replace(/[^\x20-\x7E]/g, '').trim();
}

/**
 * fetch() wrapper that aborts after `timeoutMs` milliseconds.
 * Converts AbortError to a user-friendly "Request timed out" error.
 */
function fetchWithTimeout(url, options = {}, timeoutMs = 300000) {
    const ctrl = new AbortController();
    const id = setTimeout(() => ctrl.abort(), timeoutMs);
    return fetch(url, { ...options, signal: ctrl.signal })
        .catch(e => { throw e.name === 'AbortError' ? new Error('Request timed out') : e; })
        .finally(() => clearTimeout(id));
}

export function getImageGenSettings() {
    return {
        enabled: localStorage.getItem(SETTINGS_KEY.enabled) === 'true',
        apiType: localStorage.getItem(SETTINGS_KEY.apiType) || 'openai',
        endpoint: (localStorage.getItem(SETTINGS_KEY.endpoint) || '').trim(),
        apiKey: sanitizeHeaderValue(localStorage.getItem(SETTINGS_KEY.apiKey)),
        model: localStorage.getItem(SETTINGS_KEY.model) || '',
        size: localStorage.getItem(SETTINGS_KEY.size) || '1024x1024',
        quality: localStorage.getItem(SETTINGS_KEY.quality) || 'standard',
        aspectRatio: localStorage.getItem(SETTINGS_KEY.aspectRatio) || '1:1',
        imageSize: localStorage.getItem(SETTINGS_KEY.imageSize) || '1K',
        // Naistera
        naisteraModel: localStorage.getItem(SETTINGS_KEY.naisteraModel) || 'grok',
        naisteraAspectRatio: localStorage.getItem(SETTINGS_KEY.naisteraAspectRatio) || '1:1',
        naisteraSendCharAvatar: localStorage.getItem(SETTINGS_KEY.naisteraSendCharAvatar) === 'true',
        naisteraSendUserAvatar: localStorage.getItem(SETTINGS_KEY.naisteraSendUserAvatar) === 'true',
        additionalReferences: getAdditionalReferences(),
        // Image context
        imageContextEnabled: localStorage.getItem(SETTINGS_KEY.imageContextEnabled) === 'true',
        imageContextCount: Math.min(3, Math.max(1, parseInt(localStorage.getItem(SETTINGS_KEY.imageContextCount), 10) || 1)),
    };
}

export function saveImageGenSettings(partial) {
    for (const [key, storageKey] of Object.entries(SETTINGS_KEY)) {
        if (Object.hasOwn(partial, key)) {
            localStorage.setItem(storageKey, String(partial[key]));
        }
    }
    if (Object.hasOwn(partial, 'additionalReferences')) {
        saveAdditionalReferences(partial.additionalReferences);
    }
}

export function getAdditionalReferences() {
    try {
        const raw = localStorage.getItem(ADDITIONAL_REFS_KEY);
        if (!raw) return [];
        const parsed = JSON.parse(raw);
        return Array.isArray(parsed) ? parsed.slice(0, 8) : [];
    } catch {
        return [];
    }
}

export function saveAdditionalReferences(refs) {
    const clean = (Array.isArray(refs) ? refs : []).slice(0, 8).map(r => ({
        name: String(r?.name || '').trim(),
        imageData: String(r?.imageData || ''),
        matchMode: r?.matchMode === 'always' ? 'always' : 'match',
    }));
    localStorage.setItem(ADDITIONAL_REFS_KEY, JSON.stringify(clean));
}

// ---- Image Context Extraction ----

const IMGGEN_RESULT_REGEX = /<img[^>]+class="imggen-result"[^>]+src="([^"]+)"/g;

/**
 * Extract previously generated image data URLs from chat messages.
 * Scans backwards from currentIndex looking for imggen-result images.
 * Returns array of data URL strings (up to `count`).
 */
export function extractPreviousGeneratedImages(messages, currentIndex, count = 1) {
    const urls = [];
    if (!Array.isArray(messages) || currentIndex <= 0) return urls;

    for (let i = currentIndex - 1; i >= 0 && urls.length < count; i--) {
        const msg = messages[i];
        if (!msg || msg.role === 'user') continue;
        const text = msg.text || '';
        let m;
        IMGGEN_RESULT_REGEX.lastIndex = 0;
        while ((m = IMGGEN_RESULT_REGEX.exec(text)) !== null && urls.length < count) {
            const src = m[1];
            if (src && src.startsWith('data:image/')) {
                urls.push(src);
            }
        }
    }
    return urls;
}

// ---- Tag Parsing ----

function decodeHtmlEntities(str) {
    return String(str || '')
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&#39;/g, "'")
        .replace(/&#34;/g, '"')
        .replace(/&amp;/g, '&');
}

/**
 * Find all image gen tags in text.
 * Returns array of { fullMatch, instruction: { prompt, style, aspectRatio, imageSize, quality } }
 */
export function parseImageGenTags(text) {
    if (!text) return [];
    const tags = [];
    const seen = new Set();

    // New format with data-iig-instruction attribute (attribute order may vary)
    const newRegex = /<img\b[^>]*?(?:data-iig-instruction='([^']*)'[^>]*?src="\[IMG:GEN\]"|src="\[IMG:GEN\]"[^>]*?data-iig-instruction='([^']*?)')[^>]*?>/g;
    let m;
    while ((m = newRegex.exec(text)) !== null) {
        if (seen.has(m[0])) continue;
        seen.add(m[0]);
        const raw = m[1] ?? m[2] ?? '{}';
        let instruction = {};
        try { instruction = JSON.parse(decodeHtmlEntities(raw)); } catch { instruction = { prompt: raw }; }
        tags.push({ fullMatch: m[0], instruction });
    }

    // Legacy format: [IMG:GEN:{...json...}]
    const legacyRegex = /\[IMG:GEN:(\{[\s\S]*?\})\]/g;
    while ((m = legacyRegex.exec(text)) !== null) {
        if (seen.has(m[0])) continue;
        seen.add(m[0]);
        let instruction = {};
        try { instruction = JSON.parse(m[1]); } catch { instruction = { prompt: m[1] }; }
        tags.push({ fullMatch: m[0], instruction });
    }

    return tags;
}

// ---- Naistera helpers ----

const NAISTERA_DEFAULT_ENDPOINT = 'https://naistera.org';

function normalizeNaisteraModel(model) {
    const raw = String(model || '').trim().toLowerCase();
    if (raw.startsWith('nano')) return 'nano banana';
    if (raw === 'grok') return 'grok';
    return 'grok';
}

function getNaisteraEndpoint(settings) {
    const base = (settings.endpoint || NAISTERA_DEFAULT_ENDPOINT).replace(/\/$/, '').replace(/\/api\/generate$/i, '');
    return `${base}/api/generate`;
}

function getMatchedAdditionalReferences(prompt, refs) {
    if (!refs?.length) return [];
    const lower = prompt.toLowerCase();
    return refs.filter(ref => {
        if (ref.matchMode === 'always') return true;
        if (!ref.name) return false;
        return lower.includes(ref.name.toLowerCase());
    });
}

// ---- API Calls ----

async function generateImageOpenAI(prompt, options, settings) {
    const endpoint = settings.endpoint.replace(/\/$/, '');
    const url = `${endpoint}/v1/images/generations`;

    let size = settings.size;
    if (options.aspectRatio) {
        if (options.aspectRatio === '16:9') size = '1792x1024';
        else if (options.aspectRatio === '9:16') size = '1024x1792';
        else size = '1024x1024';
    }

    const fullPrompt = options.style ? `[Style: ${options.style}] ${prompt}` : prompt;

    const body = {
        model: settings.model,
        prompt: fullPrompt,
        n: 1,
        size,
        quality: options.quality || settings.quality,
        response_format: 'b64_json',
    };

    // OpenAI supports a single reference image
    if (options.previousImages?.length) {
        body.image = options.previousImages[0];
    }

    const response = await fetchWithTimeout(url, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${settings.apiKey}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const txt = await response.text().catch(() => '');
        throw new Error(`API Error (${response.status}): ${txt.slice(0, 300)}`);
    }

    const result = await response.json();
    const dataList = result.data || [];
    if (!dataList.length) throw new Error('No image data in response');

    const imageObj = dataList[0];
    if (imageObj.b64_json) return `data:image/png;base64,${imageObj.b64_json}`;
    if (imageObj.url) return imageObj.url;
    throw new Error('No image in response');
}

const VALID_ASPECT_RATIOS = ['1:1', '2:3', '3:2', '3:4', '4:3', '4:5', '5:4', '9:16', '16:9', '21:9'];
const VALID_IMAGE_SIZES = ['1K', '2K', '4K'];

async function generateImageGemini(prompt, options, settings) {
    const endpoint = settings.endpoint.replace(/\/$/, '');
    const url = `${endpoint}/v1beta/models/${settings.model}:generateContent`;

    let aspectRatio = options.aspectRatio || settings.aspectRatio || '1:1';
    if (!VALID_ASPECT_RATIOS.includes(aspectRatio)) aspectRatio = '1:1';

    let imageSize = options.imageSize || settings.imageSize || '1K';
    if (!VALID_IMAGE_SIZES.includes(imageSize)) imageSize = '1K';

    const fullPrompt = options.style ? `[Style: ${options.style}] ${prompt}` : prompt;

    // Build parts: reference images first, then prompt text
    const parts = [];
    if (options.previousImages?.length) {
        for (const dataUrl of options.previousImages) {
            const commaIdx = dataUrl.indexOf(',');
            if (commaIdx === -1) continue;
            const meta = dataUrl.slice(5, commaIdx);
            const mimeType = meta.split(';')[0] || 'image/png';
            const base64Data = dataUrl.slice(commaIdx + 1);
            parts.push({ inlineData: { mimeType, data: base64Data } });
        }
    }
    parts.push({ text: fullPrompt });

    const body = {
        contents: [{ role: 'user', parts }],
        generationConfig: {
            responseModalities: ['TEXT', 'IMAGE'],
            imageConfig: { aspectRatio, imageSize },
        },
    };

    const response = await fetchWithTimeout(url, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${settings.apiKey}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const txt = await response.text().catch(() => '');
        throw new Error(`API Error (${response.status}): ${txt.slice(0, 300)}`);
    }

    const result = await response.json();
    const candidates = result.candidates || [];
    if (!candidates.length) throw new Error('No candidates in response');

    const responseParts = candidates[0].content?.parts || [];
    for (const part of responseParts) {
        if (part.inlineData) return `data:${part.inlineData.mimeType};base64,${part.inlineData.data}`;
        if (part.inline_data) return `data:${part.inline_data.mime_type};base64,${part.inline_data.data}`;
    }
    throw new Error('No image found in Gemini response');
}

const MAX_NAISTERA_REFS = 5;

async function generateImageNaistera(prompt, options, settings) {
    const url = getNaisteraEndpoint(settings);
    const model = normalizeNaisteraModel(settings.naisteraModel);
    const aspectRatio = options.aspectRatio || settings.naisteraAspectRatio || '1:1';

    const referenceImages = [];
    if (options.charAvatar) referenceImages.push(options.charAvatar);
    if (options.userAvatar) referenceImages.push(options.userAvatar);
    if (options.additionalRefs?.length) referenceImages.push(...options.additionalRefs);
    if (options.previousImages?.length) referenceImages.push(...options.previousImages);

    let fullPrompt = options.style ? `[Style: ${options.style}] ${prompt}` : prompt;
    if (referenceImages.length > 0) {
        fullPrompt = `[CRITICAL: The reference image(s) above show the EXACT appearance of the character(s). You MUST precisely copy their: face structure, eye color, hair color and style, skin tone, body type, clothing, and all distinctive features. Do not deviate from the reference appearances.]\n\n${fullPrompt}`;
    }

    const body = {
        prompt: fullPrompt,
        aspect_ratio: aspectRatio,
        model,
    };
    if (referenceImages.length > 0) {
        body.reference_images = referenceImages.slice(0, MAX_NAISTERA_REFS);
    }

    const response = await fetchWithTimeout(url, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${settings.apiKey}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const txt = await response.text().catch(() => '');
        throw new Error(`API Error (${response.status}): ${txt.slice(0, 300)}`);
    }

    const result = await response.json();
    if (!result?.data_url) throw new Error('No data_url in response');
    return result.data_url;
}

/**
 * Generate image from instruction object { prompt, style, aspectRatio, imageSize, quality }
 * context: { charAvatar?, userAvatar? } — data URLs for reference images (naistera)
 * Returns a data URL or remote URL string.
 */
export async function generateImage(instruction, context = {}) {
    const settings = getImageGenSettings();

    if (!settings.apiKey) throw new Error('Image API key not configured');
    if (settings.apiType !== 'naistera' && !settings.endpoint) throw new Error('Image endpoint not configured');
    if (settings.apiType === 'openai' && !settings.model) throw new Error('Image model not configured');
    if (settings.apiType === 'gemini' && !settings.model) throw new Error('Image model not configured');

    const prompt = instruction.prompt || '';
    if (!prompt) throw new Error('No prompt in image tag');

    const options = {
        style: instruction.style,
        aspectRatio: instruction.aspect_ratio || instruction.aspectRatio,
        imageSize: instruction.image_size || instruction.imageSize,
        quality: instruction.quality,
        charAvatar: null,
        userAvatar: null,
        additionalRefs: [],
        previousImages: context.previousImages || [],
    };

    if (settings.apiType === 'naistera') {
        if (settings.naisteraSendCharAvatar && context.charAvatar) options.charAvatar = context.charAvatar;
        if (settings.naisteraSendUserAvatar && context.userAvatar) options.userAvatar = context.userAvatar;
        const matched = getMatchedAdditionalReferences(prompt, settings.additionalReferences);
        options.additionalRefs = matched.map(r => r.imageData).filter(Boolean);
    }

    if (settings.apiType === 'naistera') return generateImageNaistera(prompt, options, settings);
    if (settings.apiType === 'gemini') return generateImageGemini(prompt, options, settings);
    return generateImageOpenAI(prompt, options, settings);
}

/**
 * Fetch image models from the configured endpoint (OpenAI /v1/models).
 */
export async function fetchImageModels() {
    const settings = getImageGenSettings();
    if (!settings.endpoint || !settings.apiKey) return [];

    const url = `${settings.endpoint.replace(/\/$/, '')}/v1/models`;
    const response = await fetchWithTimeout(url, {
        headers: { 'Authorization': `Bearer ${settings.apiKey}` },
    }, 10000);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const data = await response.json();
    const IMG_KW = ['dall-e', 'midjourney', 'stable-diffusion', 'sdxl', 'flux', 'imagen',
        'image', 'seedream', 'hidream', 'ideogram', 'gpt-image', 'wanx', 'qwen', 'drawing'];
    const VID_KW = ['sora', 'kling', 'veo', 'pika', 'runway', 'luma', 'video', 'cogvideo'];

    return (data.data || [])
        .map(m => m.id)
        .filter(id => {
            const lower = id.toLowerCase();
            if (VID_KW.some(k => lower.includes(k))) return false;
            return IMG_KW.some(k => lower.includes(k));
        });
}

/**
 * Lightweight connection test for the configured image generation endpoint.
 * Uses a short timeout (10s) — not a full generation.
 */
export async function checkImageGenConnection() {
    const settings = getImageGenSettings();
    if (!settings.apiKey) throw new Error('API key not configured');

    if (settings.apiType === 'openai') {
        if (!settings.endpoint) throw new Error('Endpoint not configured');
        const url = `${settings.endpoint.replace(/\/$/, '')}/v1/models`;
        const response = await fetchWithTimeout(url, {
            headers: { 'Authorization': `Bearer ${settings.apiKey}` },
        }, 10000);
        if (!response.ok) {
            const txt = await response.text().catch(() => '');
            throw new Error(`HTTP ${response.status}: ${txt.slice(0, 200)}`);
        }
    } else if (settings.apiType === 'gemini') {
        if (!settings.endpoint) throw new Error('Endpoint not configured');
        const url = `${settings.endpoint.replace(/\/$/, '')}/v1beta/models`;
        const response = await fetchWithTimeout(url, {
            headers: { 'Authorization': `Bearer ${settings.apiKey}` },
        }, 10000);
        if (!response.ok) {
            const txt = await response.text().catch(() => '');
            throw new Error(`HTTP ${response.status}: ${txt.slice(0, 200)}`);
        }
    } else if (settings.apiType === 'naistera') {
        const base = (settings.endpoint || NAISTERA_DEFAULT_ENDPOINT).replace(/\/$/, '');
        const response = await fetchWithTimeout(base, {}, 10000);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
    }
}

// ---- Image HTML Builders ----

function makeIIGId() {
    return `iig_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

function encodeIIGInstruction(instruction) {
    return JSON.stringify(instruction).replace(/&/g, '&amp;').replace(/'/g, '&#39;');
}

/**
 * Derive CSS aspect-ratio string from current image gen settings.
 * e.g. "16:9" → "16 / 9", OpenAI "1024x1792" → "1024 / 1792"
 */
function getPlaceholderAspectRatio() {
    const s = getImageGenSettings();
    if (s.apiType === 'openai') {
        const [w, h] = (s.size || '1024x1024').split('x').map(Number);
        return `${w} / ${h}`;
    }
    const arStr = s.apiType === 'naistera' ? (s.naisteraAspectRatio || '1:1') : (s.aspectRatio || '1:1');
    const [w, h] = arStr.split(':').map(Number);
    return `${w} / ${h}`;
}

export function makeLoadingHtml(instruction, id) {
    const enc = encodeIIGInstruction(instruction);
    const prompt = (instruction.prompt || '').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    return `<span class="imggen-loading" data-iig-instruction='${enc}' data-iig-id="${id}"><span class="imggen-loading-hint">Generating Image...</span><span class="imggen-loading-timer" data-start="${Date.now()}">0.0s</span><span class="imggen-loading-prompt">${prompt}</span></span>`;
}

function extractErrorMessage(errorMessage) {
    const str = String(errorMessage || 'Generation failed');
    const jsonMatch = str.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
        try {
            const obj = JSON.parse(jsonMatch[0]);
            const detail = obj.detail || obj.message || obj.error_description;
            if (detail && typeof detail === 'string') {
                const prefix = str.slice(0, jsonMatch.index).replace(/:?\s*$/, '').trim();
                return prefix ? `${prefix}: ${detail}` : detail;
            }
        } catch { /* fall through */ }
    }
    return str.slice(0, 120);
}

export function makeErrorHtml(instruction, id, errorMessage) {
    const enc = encodeIIGInstruction(instruction);
    const msg = extractErrorMessage(errorMessage).replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const label = t('action_regenerate') || 'Regenerate';
    return `<span class="imggen-error" data-iig-instruction='${enc}' data-iig-id="${id}"><span class="imggen-error-icon">⚠</span><span class="imggen-error-msg">${msg}</span><button class="imggen-error-retry" type="button">${RETRY_SVG}${label}</button></span>`;
}

export function makeDisabledHtml(instruction, id) {
    const enc = encodeIIGInstruction(instruction);
    const msg = t('imggen_disabled') || 'Image generation disabled';
    const label = t('imggen_enable_btn') || 'Enable and generate';
    return `<span class="imggen-error imggen-disabled" data-iig-instruction='${enc}' data-iig-id="${id}"><span class="imggen-error-icon">🖼️</span><span class="imggen-error-msg">${msg}</span><button class="imggen-enable-retry" type="button" style="display: flex;align-items: center;gap: 4px;border-radius: 12px;padding: 2px 8px;height: 22px;font-size: 11px;color: rgba(255,59,48,0.9);background: rgba(255,59,48,0.1);border: 1px solid rgba(255,59,48,0.3);cursor: pointer;transition: background 0.15s;">${label}</button></span>`;
}

const RETRY_SVG = `<svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>`;
const OPTIONS_SVG = `<svg viewBox="0 0 24 24"><path d="M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z"/></svg>`;

export function makeResultHtml(instruction, id, dataUrl) {
    const enc = encodeIIGInstruction(instruction);
    const alt = (instruction.prompt || 'Generated image').slice(0, 120).replace(/"/g, '&quot;').replace(/</g, '&lt;');
    return `<span class="imggen-result-wrapper"><img class="imggen-result" src="${dataUrl}" alt="${alt}" data-iig-instruction='${enc}' data-iig-id="${id}"><button class="imggen-options-btn" type="button" title="Options">${OPTIONS_SVG}</button></span>`;
}

/**
 * Process all image gen tags in a message text.
 * Calls onUpdate(newText) as each image is resolved/failed.
 * context: { charAvatar?, userAvatar? } for reference images (naistera)
 * Returns final text with all images replaced (data URLs or error states).
 */
export async function processMessageImages(text, onUpdate, context = {}) {
    const settings = getImageGenSettings();

    const tags = parseImageGenTags(text);
    if (!tags.length) return text;

    if (!settings.enabled) {
        let current = text;
        for (const tag of tags) {
            const id = makeIIGId();
            const placeholder = makeDisabledHtml(tag.instruction, id);
            current = current.replace(tag.fullMatch, placeholder);
        }
        return current;
    }

    // Collect previous generated images as context if the setting is enabled
    if (settings.imageContextEnabled && context.messages && context.currentMsgIndex != null) {
        const prevImages = extractPreviousGeneratedImages(
            context.messages,
            context.currentMsgIndex,
            settings.imageContextCount,
        );
        if (prevImages.length) {
            context.previousImages = prevImages;
        }
    }

    // Replace all pending tags with loading placeholders
    let current = text;
    const placeholders = [];
    for (const tag of tags) {
        const id = makeIIGId();
        const placeholder = makeLoadingHtml(tag.instruction, id);
        current = current.replace(tag.fullMatch, placeholder);
        placeholders.push({ placeholder, id, instruction: tag.instruction, fullMatch: tag.fullMatch });
    }
    onUpdate(current);

    if (placeholders.length > 0) {
        addNotification(t('imggen_notification_body') || 'Generating image...', 'info');
        startGenerationNotification(t('imggen_notification_title') || 'Glaze', t('imggen_notification_body') || 'Generating image...');
    }

    try {
        // Generate images one by one
        for (const { placeholder, id, instruction } of placeholders) {
            try {
                const dataUrl = await generateImage(instruction, context);
                current = current.replace(placeholder, makeResultHtml(instruction, id, dataUrl));
            } catch (err) {
                console.error('[ImageGen]', err);
                current = current.replace(placeholder, makeErrorHtml(instruction, id, err.message));
            }
            onUpdate(current);
        }
    } finally {
        if (placeholders.length > 0) {
            stopGenerationNotification();
        }
    }

    return current;
}
