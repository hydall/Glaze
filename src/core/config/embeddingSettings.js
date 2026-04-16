import { normalizeEndpoint } from '@/core/config/APISettings.js';

function normalizeEmbeddingEndpoint(url) {
    if (!url) return '';
    let normalized = url.trim();
    if (!/^https?:\/\//i.test(normalized)) {
        normalized = 'https://' + normalized;
    }
    if (normalized.endsWith('/')) normalized = normalized.slice(0, -1);
    const suffix = '/embeddings';
    if (normalized.toLowerCase().endsWith(suffix)) {
        normalized = normalized.slice(0, -suffix.length);
    }
    if (normalized.endsWith('/v1')) {
        // keep /v1, it's the base path
    }
    if (normalized.endsWith('/')) normalized = normalized.slice(0, -1);
    return normalized;
}

export function getEmbeddingConfig() {
    const useSame = localStorage.getItem('gz_embedding_use_same') !== 'false';

    const base = {
        target: localStorage.getItem('gz_embedding_target') || 'content',
        scanDepth: parseInt(localStorage.getItem('gz_embedding_scan_depth')) || 5,
        threshold: parseFloat(localStorage.getItem('gz_embedding_threshold')) || 0.6,
        topK: parseInt(localStorage.getItem('gz_embedding_top_k')) || 10,
        maxChunkTokens: parseInt(localStorage.getItem('gz_embedding_max_chunk_tokens')) || 8192,
        enabled: localStorage.getItem('gz_embedding_enabled') === 'true'
    };

    if (useSame) {
        return {
            ...base,
            endpoint: normalizeEndpoint(localStorage.getItem('api-endpoint') || ''),
            apiKey: localStorage.getItem('api-key') || '',
            model: localStorage.getItem('api-model') || '',
            useSame: true
        };
    }

    return {
        ...base,
        endpoint: normalizeEmbeddingEndpoint(localStorage.getItem('gz_embedding_endpoint') || ''),
        apiKey: localStorage.getItem('gz_embedding_key') || '',
        model: localStorage.getItem('gz_embedding_model') || '',
        useSame: false
    };
}

export function saveEmbeddingSetting(key, value) {
    localStorage.setItem(key, value);
}

export function isEmbeddingConfigured() {
    const config = getEmbeddingConfig();
    return !!config.endpoint && !!config.model;
}
