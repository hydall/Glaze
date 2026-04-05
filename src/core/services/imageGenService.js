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
};

const ADDITIONAL_REFS_KEY = 'gz_imggen_additional_refs';

export function getImageGenSettings() {
    return {
        enabled: localStorage.getItem(SETTINGS_KEY.enabled) === 'true',
        apiType: localStorage.getItem(SETTINGS_KEY.apiType) || 'openai',
        endpoint: localStorage.getItem(SETTINGS_KEY.endpoint) || '',
        apiKey: localStorage.getItem(SETTINGS_KEY.apiKey) || '',
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

    const response = await fetch(url, {
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

    const body = {
        contents: [{ role: 'user', parts: [{ text: fullPrompt }] }],
        generationConfig: {
            responseModalities: ['TEXT', 'IMAGE'],
            imageConfig: { aspectRatio, imageSize },
        },
    };

    const response = await fetch(url, {
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

    const parts = candidates[0].content?.parts || [];
    for (const part of parts) {
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

    const response = await fetch(url, {
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
    const response = await fetch(url, {
        headers: { 'Authorization': `Bearer ${settings.apiKey}` },
    });
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

function escapeAttr(str) {
    return String(str || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/**
 * Process all image gen tags in a message text.
 * Calls onUpdate(newText) as each image is resolved/failed.
 * context: { charAvatar?, userAvatar? } for reference images (naistera)
 * Returns final text with all images replaced (data URLs or error states).
 */
export async function processMessageImages(text, onUpdate, context = {}) {
    const settings = getImageGenSettings();
    if (!settings.enabled) return text;

    const tags = parseImageGenTags(text);
    if (!tags.length) return text;

    // Replace all pending tags with loading placeholders
    let current = text;
    const placeholders = [];
    for (const tag of tags) {
        const placeholder = `<span class="imggen-loading" title="${escapeAttr(tag.instruction.prompt || 'Generating...')}"></span>`;
        current = current.replace(tag.fullMatch, placeholder);
        placeholders.push({ placeholder, instruction: tag.instruction });
    }
    onUpdate(current);

    // Generate images one by one
    for (const { placeholder, instruction } of placeholders) {
        try {
            const dataUrl = await generateImage(instruction, context);
            const alt = escapeAttr(instruction.prompt || 'Generated image');
            const imgHtml = `<img src="${dataUrl}" alt="${alt}" class="imggen-result">`;
            current = current.replace(placeholder, imgHtml);
        } catch (err) {
            console.error('[ImageGen]', err);
            const title = escapeAttr(err.message || 'Generation failed');
            current = current.replace(placeholder, `<span class="imggen-error" title="${title}">⚠ ${escapeAttr(String(err.message || '').slice(0, 60))}</span>`);
        }
        onUpdate(current);
    }

    return current;
}
