import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { db } from '@/utils/db.js';

export const PROVIDER_BLACKLIST = [
    { name: 'EllyAI', match: 'ellyai' },
    { name: 'MegaLLM', match: 'megallm' }
];

// On web, browser CORS is blocked at the organization level even with the
// dangerous-direct-browser-access header, so route through the vite dev proxy
// (see vite.config.js). On native, CapacitorHttp bypasses CORS → hit direct.
export const ANTHROPIC_API_URL = Capacitor.isNativePlatform()
    ? 'https://api.anthropic.com/v1'
    : '/anthropic/v1';

export function getBlacklistedProvider(url) {
    if (!url) return null;
    const lower = url.toLowerCase();
    return PROVIDER_BLACKLIST.find(entry => lower.includes(entry.match)) || null;
}

export async function initSettings() {
    // Ensure defaults exist
    if (localStorage.getItem('gz_api_temp') === null) localStorage.setItem('gz_api_temp', '0.7');
    if (localStorage.getItem('gz_api_topp') === null) localStorage.setItem('gz_api_topp', '0.9');
    if (localStorage.getItem('gz_api_stream') === null) localStorage.setItem('gz_api_stream', 'true');
    if (localStorage.getItem('gz_api_reasoning_start') === null) localStorage.setItem('gz_api_reasoning_start', '<think>');
    if (localStorage.getItem('gz_api_reasoning_end') === null) localStorage.setItem('gz_api_reasoning_end', '</think>');
    if (localStorage.getItem('gz_api_auto_hide_images') === null) localStorage.setItem('gz_api_auto_hide_images', 'false');
    if (localStorage.getItem('gz_api_auto_hide_images_n') === null) localStorage.setItem('gz_api_auto_hide_images_n', '1');
    if (localStorage.getItem('gz_api_reasoning_effort') === null) localStorage.setItem('gz_api_reasoning_effort', 'medium');
}

export function normalizeEndpoint(url) {
    if (!url) return '';
    let normalized = url.trim();
    if (!/^https?:\/\//i.test(normalized)) {
        normalized = 'https://' + normalized;
    }
    if (normalized.endsWith('/')) normalized = normalized.slice(0, -1);

    const suffix = '/chat/completions';
    if (normalized.toLowerCase().endsWith(suffix)) {
        normalized = normalized.slice(0, -suffix.length);
    }
    if (normalized.endsWith('/')) normalized = normalized.slice(0, -1);

    return normalized;
}

export function getApiConfig() {
    const mt = parseInt(localStorage.getItem('api-max-tokens'));
    const ctx = parseInt(localStorage.getItem('api-context'));
    return {
        apiKey: localStorage.getItem('api-key') || '',
        apiUrl: localStorage.getItem('gz_api_endpoint_normalized') || localStorage.getItem('api-endpoint') || '',
        model: localStorage.getItem('api-model') || '',
        stream: localStorage.getItem('gz_api_stream') === 'true',
        requestReasoning: localStorage.getItem('gz_api_request_reasoning') === 'true',
        temp: parseFloat(localStorage.getItem('gz_api_temp')) || 0.7,
        topP: parseFloat(localStorage.getItem('gz_api_topp')) || 0.9,
        maxTokens: isNaN(mt) ? 8000 : mt,
        contextSize: isNaN(ctx) ? 32000 : ctx,
        autoHideImages: localStorage.getItem('gz_api_auto_hide_images') === 'true',
        autoHideImagesN: parseInt(localStorage.getItem('gz_api_auto_hide_images_n') || '1', 10),
        reasoningEffort: localStorage.getItem('gz_api_reasoning_effort') || 'medium',
        apiType: localStorage.getItem('gz_api_type') || 'openai',
        authType: localStorage.getItem('gz_api_auth_type') || 'key',
    };
}

export async function fetchRemoteModels(endpoint, key, apiType, authType, oauth) {
    if (!endpoint && apiType !== 'anthropic') throw new Error("No endpoint");

    if (apiType === 'anthropic') {
        const headers = {
            'anthropic-version': '2023-06-01'
        };
        if (authType === 'oauth' && oauth?.access_token) {
            headers['Authorization'] = `Bearer ${oauth.access_token}`;
            headers['anthropic-beta'] = 'oauth-2025-04-20';
        } else if (key) {
            headers['x-api-key'] = key;
        } else {
            throw new Error('Not authenticated');
        }

        let data;
        const url = `${ANTHROPIC_API_URL}/models`;
        if (Capacitor.isNativePlatform()) {
            const response = await CapacitorHttp.get({ url, headers });
            if (response.status >= 400) {
                const body = typeof response.data === 'object' ? JSON.stringify(response.data) : String(response.data || '');
                throw new Error(`HTTP ${response.status} ${body}`);
            }
            data = response.data;
        } else {
            const res = await fetch(url, { headers });
            if (!res.ok) {
                const body = await res.text().catch(() => '');
                throw new Error(`HTTP ${res.status} ${body}`);
            }
            data = await res.json();
        }
        if (data?.data && Array.isArray(data.data)) {
            return data.data.map(m => m.id).sort();
        }
        throw new Error('Unexpected /v1/models response shape');
    }

    if (!endpoint) throw new Error("No endpoint");

    let url = endpoint;
    if (url.endsWith('/chat/completions')) url = url.replace('/chat/completions', '');
    if (url.endsWith('/')) url = url.slice(0, -1);
    if (!url.endsWith('/models')) url += '/models';

    const headers = {};
    if (key) headers['Authorization'] = `Bearer ${key}`;

    let data;
    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({
            url: url,
            headers: headers
        });
        if (response.status >= 400) throw new Error(`HTTP ${response.status}`);
        data = response.data;
    } else {
        const res = await fetch(url, { headers });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        data = await res.json();
    }

    let models = [];
    if (data.data && Array.isArray(data.data)) {
        models = data.data.map(m => m.id);
    } else if (Array.isArray(data)) {
        models = data.map(m => m.id);
    }
    return models.sort();
}

export async function getApiPresets() {
    const saved = await db.get('gz_api_connection_presets');
    if (saved && Array.isArray(saved) && saved.length > 0) {
        return saved;
    }
    // Default
    return [{
        id: 'default',
        name: 'Default',
        apiType: 'openai',
        authType: 'key',
        oauth: null,
        endpoint: localStorage.getItem('api-endpoint') || '',
        key: localStorage.getItem('api-key') || '',
        model: localStorage.getItem('api-model') || '',
        max_tokens: localStorage.getItem('api-max-tokens') || '8000',
        context: localStorage.getItem('api-context') || '32000',
        temp: localStorage.getItem('gz_api_temp') || '0.7',
        topp: localStorage.getItem('gz_api_topp') || '0.9',
        stream: localStorage.getItem('gz_api_stream') === 'true'
    }];
}

export async function saveApiPresets(presets) {
    await db.set('gz_api_connection_presets', presets);
}