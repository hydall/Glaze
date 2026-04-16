import { Capacitor, CapacitorHttp } from '@capacitor/core';
import { getEmbeddingConfig } from '@/core/config/embeddingSettings.js';
import { estimateTokens } from '@/utils/tokenizer.js';

function chunkTextsByTokenLimit(texts, maxChunkTokens) {
    if (!maxChunkTokens || maxChunkTokens <= 0) return texts.map(t => [t]);

    const chunks = [];
    for (const text of texts) {
        const tokens = estimateTokens(text);
        if (tokens <= maxChunkTokens) {
            chunks.push([text]);
            continue;
        }

        const estimatedCharsPerToken = text.length / tokens;
        const maxChars = Math.floor(maxChunkTokens * estimatedCharsPerToken);

        const subChunks = [];
        let remaining = text;
        while (remaining.length > 0) {
            if (remaining.length <= maxChars) {
                subChunks.push(remaining);
                break;
            }

            let splitAt = remaining.lastIndexOf('\n', maxChars);
            if (splitAt < maxChars * 0.3) splitAt = remaining.lastIndexOf('. ', maxChars);
            if (splitAt < maxChars * 0.3) splitAt = remaining.lastIndexOf(' ', maxChars);
            if (splitAt < maxChars * 0.3) splitAt = maxChars;

            subChunks.push(remaining.substring(0, splitAt).trim());
            remaining = remaining.substring(splitAt).trim();
        }
        chunks.push(subChunks);
    }
    return chunks;
}

function averageVectors(vectors) {
    if (!vectors || vectors.length === 0) return null;
    if (vectors.length === 1) return vectors[0];

    const dim = vectors[0].length;
    const result = new Array(dim).fill(0);
    for (const vec of vectors) {
        for (let i = 0; i < dim; i++) {
            result[i] += vec[i];
        }
    }
    for (let i = 0; i < dim; i++) {
        result[i] /= vectors.length;
    }
    return result;
}

async function callEmbeddingAPI(url, headers, requestBody) {
    let data;

    if (Capacitor.isNativePlatform() && url.startsWith('http:')) {
        const response = await CapacitorHttp.post({
            url,
            headers,
            data: requestBody,
            responseType: 'json'
        });
        if (response.status >= 400) {
            throw new Error(`Embedding API Error: ${response.status}`);
        }
        data = response.data;
    } else {
        const res = await fetch(url, {
            method: 'POST',
            headers,
            body: JSON.stringify(requestBody)
        });
        if (!res.ok) {
            const errText = await res.text().catch(() => '');
            throw new Error(`Embedding API Error: ${res.status} ${errText}`);
        }
        data = await res.json();
    }

    if (!data.data || !Array.isArray(data.data)) {
        throw new Error('Invalid embedding response: missing data array');
    }

    return data.data.sort((a, b) => a.index - b.index).map(item => item.embedding);
}

export async function getEmbedding(text) {
    const results = await getEmbeddings([text]);
    return results[0];
}

export async function getEmbeddings(texts) {
    if (!texts || texts.length === 0) return [];

    const config = getEmbeddingConfig();
    if (!config.endpoint) throw new Error('Embedding endpoint not configured');
    if (!config.model) throw new Error('Embedding model not configured');

    const url = `${config.endpoint}/embeddings`;
    const headers = { 'Content-Type': 'application/json' };
    if (config.apiKey) headers['Authorization'] = `Bearer ${config.apiKey}`;

    console.info('[embeddingService] requesting embeddings', {
        count: texts.length,
        model: config.model,
        endpoint: config.endpoint,
        target: config.target,
        maxChunkTokens: config.maxChunkTokens,
        sampleLengths: texts.slice(0, 3).map(text => (text || '').length)
    });

    const allChunked = chunkTextsByTokenLimit(texts, config.maxChunkTokens);
    const results = [];

    for (let i = 0; i < allChunked.length; i++) {
        const chunks = allChunked[i];

        if (chunks.length === 1) {
            const vectors = await callEmbeddingAPI(url, headers, {
                model: config.model,
                input: chunks
            });
            results.push(vectors[0]);
        } else {
            const vectors = await callEmbeddingAPI(url, headers, {
                model: config.model,
                input: chunks
            });
            results.push(averageVectors(vectors));
        }
    }

    console.info('[embeddingService] embeddings received', {
        count: results.length,
        dimensions: results.slice(0, 3).map(v => Array.isArray(v) ? v.length : 0)
    });

    return results;
}

export async function testEmbeddingConnection() {
    const testText = 'Hello, this is a test.';
    const result = await getEmbedding(testText);
    if (!result || !Array.isArray(result) || result.length === 0) {
        throw new Error('Embedding returned empty vector');
    }
    return {
        dimension: result.length,
        success: true
    };
}
