import { describe, it, expect } from 'vitest';
import {
    convertToAnthropicBody,
    buildAnthropicHeaders,
    parseAnthropicSSE,
    parseAnthropicResponse,
} from '../anthropicFormat.js';

// ---------------------------------------------------------------------------
// convertToAnthropicBody
// ---------------------------------------------------------------------------

describe('convertToAnthropicBody', () => {
    const baseBody = {
        model: 'claude-3-5-sonnet-20241022',
        messages: [],
        max_tokens: 1024,
        stream: true,
    };

    // --- System message extraction ---

    it('extracts single system message to top-level system field', () => {
        const body = {
            ...baseBody,
            messages: [
                { role: 'system', content: 'You are helpful.' },
                { role: 'user', content: 'Hello' },
            ],
        };
        const result = convertToAnthropicBody(body);
        expect(result.system).toEqual([{ type: 'text', text: 'You are helpful.' }]);
        expect(result.messages.every(m => m.role !== 'system')).toBe(true);
    });

    it('extracts multiple system messages as separate TextBlockParams', () => {
        const body = {
            ...baseBody,
            messages: [
                { role: 'system', content: 'Instruction 1.' },
                { role: 'system', content: 'Instruction 2.' },
                { role: 'user', content: 'Hello' },
            ],
        };
        const result = convertToAnthropicBody(body);
        expect(result.system).toEqual([
            { type: 'text', text: 'Instruction 1.' },
            { type: 'text', text: 'Instruction 2.' },
        ]);
    });

    it('extracts system messages from anywhere in the array', () => {
        const body = {
            ...baseBody,
            messages: [
                { role: 'user', content: 'Hello' },
                { role: 'system', content: 'Mid-array system.' },
                { role: 'assistant', content: 'Hi!' },
            ],
        };
        const result = convertToAnthropicBody(body);
        expect(result.system).toEqual([{ type: 'text', text: 'Mid-array system.' }]);
    });

    it('omits system field when no system messages exist', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hello' }],
        };
        const result = convertToAnthropicBody(body);
        expect(result.system).toBeUndefined();
    });

    // --- Message ordering ---

    it('keeps assistant as the first message when no user message precedes it', () => {
        const body = {
            ...baseBody,
            messages: [
                { role: 'system', content: 'Sys' },
                { role: 'assistant', content: 'Hello!' },
            ],
        };
        const result = convertToAnthropicBody(body);
        expect(result.messages).toEqual([{ role: 'assistant', content: 'Hello!' }]);
    });

    it('preserves assistant-first prefill sequence without a synthetic user turn', () => {
        const body = {
            ...baseBody,
            messages: [
                { role: 'assistant', content: 'Hello!' },
                { role: 'user', content: 'Continue.' },
            ],
        };
        const result = convertToAnthropicBody(body);
        expect(result.messages).toEqual([
            { role: 'assistant', content: 'Hello!' },
            { role: 'user', content: 'Continue.' },
        ]);
    });

    it('passes through an empty messages array untouched', () => {
        const body = { ...baseBody, messages: [] };
        const result = convertToAnthropicBody(body);
        expect(result.messages).toEqual([]);
        expect(result.system).toBeUndefined();
    });

    it('merges consecutive same-role messages joining with \\n\\n', () => {
        const body = {
            ...baseBody,
            messages: [
                { role: 'user', content: 'First user.' },
                { role: 'user', content: 'Second user.' },
                { role: 'assistant', content: 'Reply.' },
            ],
        };
        const result = convertToAnthropicBody(body);
        expect(result.messages[0]).toEqual({ role: 'user', content: 'First user.\n\nSecond user.' });
        expect(result.messages[1]).toEqual({ role: 'assistant', content: 'Reply.' });
    });

    it('produces an empty messages array when only system messages are provided', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'system', content: 'Sys only.' }],
        };
        const result = convertToAnthropicBody(body);
        expect(result.messages).toEqual([]);
        expect(result.system).toEqual([{ type: 'text', text: 'Sys only.' }]);
    });

    // --- Sampling parameters ---

    it('passes temperature through', () => {
        const body = { ...baseBody, messages: [{ role: 'user', content: 'Hi' }], temperature: 0.7 };
        const result = convertToAnthropicBody(body);
        expect(result.temperature).toBe(0.7);
    });

    it('strips top_p when temperature is present', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hi' }],
            temperature: 0.7,
            top_p: 0.9,
        };
        const result = convertToAnthropicBody(body);
        expect(result.temperature).toBe(0.7);
        expect(result.top_p).toBeUndefined();
    });

    it('keeps top_p when temperature is absent', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hi' }],
            top_p: 0.9,
        };
        const result = convertToAnthropicBody(body);
        expect(result.top_p).toBe(0.9);
        expect(result.temperature).toBeUndefined();
    });

    it('converts stop to stop_sequences', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hi' }],
            stop: ['END', 'STOP'],
        };
        const result = convertToAnthropicBody(body);
        expect(result.stop_sequences).toEqual(['END', 'STOP']);
        expect(result.stop).toBeUndefined();
    });

    it('strips include_reasoning from result', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hi' }],
            include_reasoning: true,
        };
        const result = convertToAnthropicBody(body);
        expect(result.include_reasoning).toBeUndefined();
    });

    it('strips extra_body from result', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hi' }],
            extra_body: { some: 'provider-field' },
        };
        const result = convertToAnthropicBody(body);
        expect(result.extra_body).toBeUndefined();
    });

    // --- Thinking config ---

    it('adds thinking: { type: adaptive } when requestReasoning is true', () => {
        const body = { ...baseBody, messages: [{ role: 'user', content: 'Hi' }] };
        const result = convertToAnthropicBody(body, { requestReasoning: true });
        expect(result.thinking).toEqual({ type: 'adaptive' });
    });

    it('does not add thinking when requestReasoning is false', () => {
        const body = { ...baseBody, messages: [{ role: 'user', content: 'Hi' }] };
        const result = convertToAnthropicBody(body, { requestReasoning: false });
        expect(result.thinking).toBeUndefined();
    });

    it('strips temperature when thinking is enabled', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hi' }],
            temperature: 0.5,
        };
        const result = convertToAnthropicBody(body, { requestReasoning: true });
        expect(result.temperature).toBeUndefined();
    });

    // --- Image conversion ---

    it('converts image_url format to Anthropic base64 format', () => {
        const body = {
            ...baseBody,
            messages: [
                {
                    role: 'user',
                    content: [
                        {
                            type: 'image_url',
                            image_url: { url: 'data:image/png;base64,iVBORw0KGgo=' },
                        },
                    ],
                },
            ],
        };
        const result = convertToAnthropicBody(body);
        expect(result.messages[0].content[0]).toEqual({
            type: 'image',
            source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgo=' },
        });
    });

    it('passes through plain string content unchanged', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Just a string.' }],
        };
        const result = convertToAnthropicBody(body);
        expect(result.messages[0].content).toBe('Just a string.');
    });

    // --- Field cleanup ---

    it('strips name field from messages', () => {
        const body = {
            ...baseBody,
            messages: [{ role: 'user', content: 'Hi', name: 'Alice' }],
        };
        const result = convertToAnthropicBody(body);
        expect(result.messages[0].name).toBeUndefined();
    });
});

// ---------------------------------------------------------------------------
// buildAnthropicHeaders
// ---------------------------------------------------------------------------

describe('buildAnthropicHeaders', () => {
    it('builds headers for API key auth', () => {
        const headers = buildAnthropicHeaders({ authType: 'apikey', apiKey: 'sk-ant-test' });
        expect(headers).toEqual({
            'Content-Type': 'application/json',
            'x-api-key': 'sk-ant-test',
            'anthropic-version': '2023-06-01',
        });
    });

    it('builds headers for OAuth auth', () => {
        const headers = buildAnthropicHeaders({ authType: 'oauth', accessToken: 'tok-abc123' });
        expect(headers).toEqual({
            'Content-Type': 'application/json',
            'Authorization': 'Bearer tok-abc123',
            'anthropic-version': '2023-06-01',
            'anthropic-beta': 'claude-code-20250219,files-api-2025-04-14,oauth-2025-04-20,interleaved-thinking-2025-05-14',
        });
    });
});

// ---------------------------------------------------------------------------
// parseAnthropicSSE
// ---------------------------------------------------------------------------

describe('parseAnthropicSSE', () => {
    it('extracts text from text_delta event', () => {
        const line = 'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}';
        expect(parseAnthropicSSE(line)).toEqual({
            text: 'Hello',
            reasoning: null,
            done: false,
            error: null,
        });
    });

    it('extracts reasoning from thinking_delta event', () => {
        const line = 'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I think..."}}';
        expect(parseAnthropicSSE(line)).toEqual({
            text: null,
            reasoning: 'I think...',
            done: false,
            error: null,
        });
    });

    it('detects end of stream on message_stop', () => {
        const line = 'data: {"type":"message_stop"}';
        const result = parseAnthropicSSE(line);
        expect(result.done).toBe(true);
    });

    it('extracts error message from error event', () => {
        const line = 'data: {"type":"error","error":{"message":"Rate limit exceeded"}}';
        const result = parseAnthropicSSE(line);
        expect(result.error).toBe('Rate limit exceeded');
    });

    it('returns null for event: lines', () => {
        expect(parseAnthropicSSE('event: message_start')).toBeNull();
    });

    it('returns null for empty lines', () => {
        expect(parseAnthropicSSE('')).toBeNull();
    });

    it('returns neutral result for message_start event', () => {
        const line = 'data: {"type":"message_start","message":{}}';
        expect(parseAnthropicSSE(line)).toEqual({
            text: null,
            reasoning: null,
            done: false,
            error: null,
        });
    });

    it('returns neutral result for other non-content events', () => {
        const line = 'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}';
        expect(parseAnthropicSSE(line)).toEqual({
            text: null,
            reasoning: null,
            done: false,
            error: null,
        });
    });

    it('ignores signature_delta events returning neutral result not null', () => {
        const line = 'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}';
        expect(parseAnthropicSSE(line)).toEqual({
            text: null,
            reasoning: null,
            done: false,
            error: null,
        });
    });
});

// ---------------------------------------------------------------------------
// parseAnthropicResponse
// ---------------------------------------------------------------------------

describe('parseAnthropicResponse', () => {
    it('extracts text from content blocks', () => {
        const data = { content: [{ type: 'text', text: 'Hello world.' }] };
        expect(parseAnthropicResponse(data)).toEqual({ text: 'Hello world.', reasoning: '' });
    });

    it('separates thinking and text content blocks', () => {
        const data = {
            content: [
                { type: 'thinking', thinking: 'My reasoning.' },
                { type: 'text', text: 'My answer.' },
            ],
        };
        expect(parseAnthropicResponse(data)).toEqual({
            text: 'My answer.',
            reasoning: 'My reasoning.',
        });
    });

    it('concatenates multiple text blocks', () => {
        const data = {
            content: [
                { type: 'text', text: 'Part 1.' },
                { type: 'text', text: 'Part 2.' },
            ],
        };
        expect(parseAnthropicResponse(data)).toEqual({ text: 'Part 1.Part 2.', reasoning: '' });
    });

    it('concatenates multiple thinking blocks', () => {
        const data = {
            content: [
                { type: 'thinking', thinking: 'Thought A.' },
                { type: 'thinking', thinking: 'Thought B.' },
            ],
        };
        expect(parseAnthropicResponse(data)).toEqual({ text: '', reasoning: 'Thought A.Thought B.' });
    });
});
