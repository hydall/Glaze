export function cosineSimilarity(a, b) {
    if (!a || !b || a.length !== b.length) return 0;

    let dotProduct = 0;
    let normA = 0;
    let normB = 0;

    for (let i = 0; i < a.length; i++) {
        dotProduct += a[i] * b[i];
        normA += a[i] * a[i];
        normB += b[i] * b[i];
    }

    const denominator = Math.sqrt(normA) * Math.sqrt(normB);
    if (denominator === 0) return 0;

    return dotProduct / denominator;
}

export function findTopKMulti(queryChunks, candidates, k, threshold = 0) {
    const scored = candidates.map(c => {
        let maxScore = 0;
        let bestQueryChunk = -1;
        let bestCandidateChunk = -1;
        
        if (Array.isArray(c.vectors)) {
            for (let qi = 0; qi < queryChunks.length; qi++) {
                const qVec = queryChunks[qi]?.vector;
                if (!qVec) continue;
                for (let ci = 0; ci < c.vectors.length; ci++) {
                    const cVec = c.vectors[ci]?.vector;
                    if (!cVec) continue;
                    const score = cosineSimilarity(qVec, cVec);
                    if (score > maxScore) {
                        maxScore = score;
                        bestQueryChunk = qi;
                        bestCandidateChunk = ci;
                    }
                }
            }
        } else if (c.vector) {
            for (let qi = 0; qi < queryChunks.length; qi++) {
                const qVec = queryChunks[qi]?.vector;
                if (!qVec) continue;
                const score = cosineSimilarity(qVec, c.vector);
                if (score > maxScore) {
                    maxScore = score;
                    bestQueryChunk = qi;
                    bestCandidateChunk = -1;
                }
            }
        }
        
        return {
            ...c,
            score: maxScore,
            _bestQueryChunk: bestQueryChunk,
            _bestCandidateChunk: bestCandidateChunk
        };
    });

    scored.sort((a, b) => b.score - a.score);

    const filtered = threshold > 0
        ? scored.filter(c => c.score >= threshold)
        : scored;

    return filtered.slice(0, k);
}

export function findTopK(queryVector, candidates, k, threshold = 0) {
    const scored = candidates.map(c => {
        let maxScore = 0;
        
        // NEW: Multi-vector support with MaxSim
        if (Array.isArray(c.vectors)) {
            // Multi-vector entry: find maximum similarity across all chunks
            for (const chunk of c.vectors) {
                if (chunk && chunk.vector) {
                    const score = cosineSimilarity(queryVector, chunk.vector);
                    maxScore = Math.max(maxScore, score);
                }
            }
        } else if (c.vector) {
            // Legacy single vector support (backward compatibility)
            maxScore = cosineSimilarity(queryVector, c.vector);
        }
        
        return {
            ...c,
            score: maxScore
        };
    });

    scored.sort((a, b) => b.score - a.score);

    const filtered = threshold > 0
        ? scored.filter(c => c.score >= threshold)
        : scored;

    return filtered.slice(0, k);
}
