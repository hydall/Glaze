import { T as GPTTokenizer } from '@/tokenizers/gp-tokenizer-9KQssiTx.js';

/**
 * Strips embedded base64 media from text so it doesn't inflate token counts.
 */
function stripEmbeddedMedia(text) {
    if (!text || text.length < 256) return text;
    let cleaned = text.replace(/<img\s[^>]*src\s*=\s*["']data:image\/[^"']{256,}["'][^>]*\/?>/gi, '');
    cleaned = cleaned.replace(/data:image\/[a-z+]+;base64,[A-Za-z0-9+/=\n\r]{256,}/gi, '');
    return cleaned;
}

/**
 * Estimates token count for a given text.
 * Uses the extracted Janitor tokenizer (cl100k_base compatible).
 * Strips embedded base64 images before counting.
 */
export function estimateTokens(text) {
    if (!text) return 0;
    const cleaned = stripEmbeddedMedia(text);
    try {
        return GPTTokenizer.countTokens(cleaned);
    } catch (e) {
        console.warn("Tokenizer error, falling back to heuristic:", e);
        return Math.ceil(cleaned.length / 3);
    }
}