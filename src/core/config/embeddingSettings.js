export function getEmbeddingConfig() {
    const useSame = localStorage.getItem('gz_embedding_use_same') !== 'false';

    const base = {
        target: localStorage.getItem('gz_embedding_target') || 'content',
        scanDepth: parseInt(localStorage.getItem('gz_embedding_scan_depth')) || 5,
        threshold: parseFloat(localStorage.getItem('gz_embedding_threshold')) || 0.45,
        topK: parseInt(localStorage.getItem('gz_embedding_top_k')) || 10,
        maxChunkTokens: parseInt(localStorage.getItem('gz_embedding_max_chunk_tokens')) || 512,
        enabled: localStorage.getItem('gz_embedding_enabled') === 'true'
    };

    if (useSame) {
        const rawEndpoint = (localStorage.getItem('api-endpoint') || '').trim();
        return {
            ...base,
            endpoint: rawEndpoint,
            apiKey: localStorage.getItem('api-key') || '',
            model: localStorage.getItem('api-model') || '',
            useSame: true
        };
    }

    const rawEndpoint = (localStorage.getItem('gz_embedding_endpoint') || '').trim();
    return {
        ...base,
        endpoint: rawEndpoint,
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
