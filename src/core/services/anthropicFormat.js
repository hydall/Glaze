const ANTHROPIC_VERSION = '2023-06-01';
//const ANTHROPIC_OAUTH_BETA = 'oauth-2025-04-20';
const ANTHROPIC_OAUTH_BETA = 'claude-code-20250219,files-api-2025-04-14,oauth-2025-04-20,interleaved-thinking-2025-05-14';

/**
 * Convert an OpenAI-compatible request body to the Anthropic Messages API format.
 *
 * @param {object} requestBody - OpenAI-format request body
 * @param {object} [options]
 * @param {boolean} [options.requestReasoning=false] - Enable extended thinking
 * @returns {object} Anthropic-format request body
 */
export function convertToAnthropicBody(requestBody, options = {}) {
    const { requestReasoning = false } = options;

    // Separate system messages from the rest
    const systemBlocks = [];
    const nonSystemMessages = [];

    for (const msg of requestBody.messages) {
        if (msg.role === 'system') {
            systemBlocks.push({ type: 'text', text: msg.content });
        } else {
            // Strip the `name` field; Anthropic doesn't support it
            const { name: _name, ...rest } = msg;
            nonSystemMessages.push(rest);
        }
    }

    // Convert image blocks inside array-content messages
    const convertedMessages = nonSystemMessages.map(msg => {
        if (!Array.isArray(msg.content)) return msg;
        return {
            ...msg,
            content: msg.content.map(block =>
                block.type === 'image_url' ? convertImageBlock(block) : block
            ),
        };
    });

    // Merge consecutive same-role messages (string content only)
    const mergedMessages = [];
    for (const msg of convertedMessages) {
        const prev = mergedMessages[mergedMessages.length - 1];
        if (prev && prev.role === msg.role && typeof prev.content === 'string' && typeof msg.content === 'string') {
            prev.content = prev.content + '\n\n' + msg.content;
        } else {
            mergedMessages.push({ ...msg });
        }
    }

    // Build base result
    const result = {
        model: requestBody.model,
        messages: mergedMessages,
        max_tokens: requestBody.max_tokens,
        stream: requestBody.stream,
    };

    // System blocks
    if (systemBlocks.length > 0) {
        result.system = systemBlocks;
    }

    // Thinking / sampling parameters
    if (requestReasoning) {
        result.thinking = { type: 'adaptive' };
        // Temperature is incompatible with thinking — omit it
    } else {
        if (requestBody.temperature !== undefined) {
            result.temperature = requestBody.temperature;
        }
        // Anthropic forbids both temperature and top_p at the same time
        if (requestBody.top_p !== undefined && requestBody.temperature === undefined) {
            result.top_p = requestBody.top_p;
        }
    }

    // stop → stop_sequences
    if (requestBody.stop !== undefined) {
        result.stop_sequences = requestBody.stop;
    }

    // Fields intentionally NOT copied: include_reasoning, extra_body, top_p (when temp present),
    // and any other provider-specific fields.

    return result;
}

/**
 * Convert an OpenAI image_url content block to the Anthropic image block format.
 *
 * @param {{ type: 'image_url', image_url: { url: string } }} block
 * @returns {object} Anthropic image block
 */
function convertImageBlock(block) {
    const dataUrl = block.image_url.url;
    const match = dataUrl.match(/^data:([^;]+);base64,(.+)$/);
    if (match) {
        return { type: 'image', source: { type: 'base64', media_type: match[1], data: match[2] } };
    }
    return { type: 'image', source: { type: 'url', url: dataUrl } };
}

/**
 * Build HTTP headers for an Anthropic API request.
 *
 * @param {{ authType: string, apiKey?: string, accessToken?: string }} param0
 * @returns {object}
 */
export function buildAnthropicHeaders({ authType, apiKey, accessToken }) {
    const headers = {
        'Content-Type': 'application/json',
        'anthropic-version': ANTHROPIC_VERSION,
    };
    if (authType === 'oauth') {
        headers['Authorization'] = `Bearer ${accessToken}`;
        headers['anthropic-beta'] = ANTHROPIC_OAUTH_BETA;
    } else {
        headers['x-api-key'] = apiKey;
    }
    return headers;
}

/**
 * Parse a single SSE line from the Anthropic streaming API.
 *
 * @param {string} line - Raw SSE line
 * @returns {{ text: string|null, reasoning: string|null, done: boolean, error: string|null }|null}
 *   Returns null for non-data lines (event: lines, empty lines).
 */
export function parseAnthropicSSE(line) {
    const trimmed = line.trim();

    if (!trimmed || !trimmed.startsWith('data: ')) {
        return null;
    }

    let parsed;
    try {
        parsed = JSON.parse(trimmed.slice('data: '.length));
    } catch {
        return null;
    }

    const neutral = { text: null, reasoning: null, done: false, error: null };

    if (parsed.type === 'message_stop') {
        return { ...neutral, done: true };
    }

    if (parsed.type === 'error') {
        return { ...neutral, error: parsed.error?.message ?? 'Unknown error' };
    }

    if (parsed.type === 'content_block_delta') {
        const delta = parsed.delta;
        if (delta?.type === 'text_delta') {
            return { ...neutral, text: delta.text };
        }
        if (delta?.type === 'thinking_delta') {
            return { ...neutral, reasoning: delta.thinking };
        }
        // signature_delta and any other unknown delta types → neutral
        return neutral;
    }

    // message_start, content_block_start, message_delta, ping, etc.
    return neutral;
}

/**
 * Parse a complete (non-streaming) Anthropic API response body.
 *
 * @param {{ content: Array<{ type: string, text?: string, thinking?: string }> }} data
 * @returns {{ text: string, reasoning: string }}
 */
export function parseAnthropicResponse(data) {
    let text = '';
    let reasoning = '';
    for (const block of data.content) {
        if (block.type === 'text') {
            text += block.text;
        } else if (block.type === 'thinking') {
            reasoning += block.thinking;
        }
    }
    return { text, reasoning };
}
