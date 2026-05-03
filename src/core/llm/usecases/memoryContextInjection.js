import { estimateTokens } from '@/utils/tokenizer.js';
import { db } from '@/utils/db.js';
import { getEmbeddings } from '@/core/services/embeddingService.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { findTopK } from '@/utils/vectorMath.js';
import { checkKeyMatch, normalizeMessageIdList, buildSummaryExcerpt } from './memoryKeyMatching.js';
import { getMemorySettings } from '@/core/services/memorySchema.js';

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
            if (emb && (emb.vectors || emb.vector)) {
                const candidate = { ...entry, retrievalHints: emb.retrievalHints || [] };
                if (emb.vectors) {
                    candidate.vectors = emb.vectors;
                } else if (emb.vector) {
                    candidate.vector = emb.vector;
                }
                return candidate;
            }
            return null;
        })
        .filter(Boolean);
    if (!candidates.length) return [];

    const recentHistory = history.slice(-(config.scanDepth || 5));
    const focusedQueryParts = recentHistory.filter(m => m.role === 'user').map(m => m.content).filter(Boolean);
    if (currentText && currentText.trim()) focusedQueryParts.push(currentText.trim());
    const queryText = focusedQueryParts.join('\n').trim();
    if (!queryText) return [];

    const queryVectorsData = await getEmbeddings([queryText]);
    if (!queryVectorsData || !queryVectorsData[0] || !queryVectorsData[0][0]?.vector) return [];

    const queryVector = queryVectorsData[0][0].vector;
    return findTopK(queryVector, candidates, candidates.length, 0)
        .filter(result => result.score >= (config.threshold || 0.6))
        .slice(0, config.topK || 5)
        .map(result => ({ ...result, vectorScore: result.score, vector: undefined }));
}

export async function buildMemoryInjection({ char, history, summary, safeContext, cutoffOriginalIndex = -1 }) {
    const charId = char?.id;
    const sessionId = char?.sessionId;
    if (!charId || !sessionId) return { messages: [], entries: [], tokens: 0, injectionTarget: 'summary_block', macroContent: '' };

    const chatData = await db.getChat(charId);
    const memoryBook = chatData?.memoryBooks?.[sessionId];
    const settings = getMemorySettings();
    const activeEntries = (Array.isArray(memoryBook?.entries) ? memoryBook.entries : [])
        .filter(entry => entry && (entry.status || 'active') === 'active' && (entry.content || '').trim());

    if (!settings.enabled || !activeEntries.length) {
        return {
            messages: [],
            entries: [],
            tokens: 0,
            injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
            macroContent: ''
        };
    }

    const recentHistory = Array.isArray(history) ? history.slice(-12) : [];
    const historyText = recentHistory.map(item => item?.content || item?.text || '').filter(Boolean).join('\n').toLowerCase();

    const inPromptMessageIds = new Set();
    if (cutoffOriginalIndex >= 0 && Array.isArray(history)) {
        for (const m of history) {
            if ((m.chatId ?? -1) >= cutoffOriginalIndex && m.messageId) {
                inPromptMessageIds.add(m.messageId);
            }
        }
    } else {
        recentHistory.forEach(item => {
            if (item?.messageId) inPromptMessageIds.add(item.messageId);
        });
    }

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

    const eligibleEntries = activeEntries.filter(entry => {
        const messageIds = normalizeMessageIdList(entry);
        if (!messageIds.length) return true;
        return !messageIds.some(id => inPromptMessageIds.has(id));
    });

    const scoredEntries = eligibleEntries.map((entry, index) => {
        const haystack = `${entry.title || ''}\n${entry.content || ''}`.toLowerCase();
        const messageIds = normalizeMessageIdList(entry);
        let score = 0;
        if (messageIds.length > 0) score += 2;
        if (keywordMatchedIds.has(entry.id)) score += 6;
        if (vectorScores.has(entry.id)) score += Math.max(0, (vectorScores.get(entry.id) || 0) * 5);
        (Array.isArray(entry.contextRefs) ? entry.contextRefs : []).forEach(ref => {
            const label = String(ref?.label || '').toLowerCase();
            if (label && recentLabels.has(label)) score += 3;
        });
        uniqueWords.forEach(word => {
            if (haystack.includes(word)) score += 1;
        });
        score += Math.min(3, index / Math.max(eligibleEntries.length, 1));
        return { entry, score };
    });

    const topEntries = scoredEntries
        .filter(item => item.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, Math.max(1, settings.maxInjectedEntries || 7))
        .map(item => item.entry);

    if (!topEntries.length) {
        return {
            messages: [],
            entries: [],
            tokens: 0,
            injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
            macroContent: ''
        };
    }

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
        return {
            messages: [],
            entries: [],
            tokens: 0,
            injectionTarget: settings.injectionTarget === 'summary_macro' ? 'summary_macro' : 'summary_block',
            macroContent: ''
        };
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
