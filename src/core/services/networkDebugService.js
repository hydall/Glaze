const STORAGE_KEY = 'gz_last_network_trace';
const ENABLED_KEY = 'gz_debug_network_capture';
const MAX_STREAM_LINES = 200;

let lastNetworkTrace = null;

function clone(value) {
    if (value === undefined) return undefined;
    return JSON.parse(JSON.stringify(value));
}

function persist() {
    try {
        if (lastNetworkTrace) {
            localStorage.setItem(STORAGE_KEY, JSON.stringify(lastNetworkTrace));
        } else {
            localStorage.removeItem(STORAGE_KEY);
        }
    } catch (e) {
        console.warn('[networkDebug] Failed to persist trace', e);
    }
}

function ensureLoaded() {
    if (lastNetworkTrace !== null) return;
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        lastNetworkTrace = raw ? JSON.parse(raw) : null;
    } catch (e) {
        lastNetworkTrace = null;
    }
}

function maskHeaders(headers = {}) {
    const masked = { ...headers };
    if (masked.Authorization) masked.Authorization = 'Bearer ***';
    if (masked.authorization) masked.authorization = 'Bearer ***';
    return masked;
}

export function isNetworkDebugEnabled() {
    return localStorage.getItem(ENABLED_KEY) === 'true';
}

export function setNetworkDebugEnabled(enabled) {
    localStorage.setItem(ENABLED_KEY, enabled ? 'true' : 'false');
}

export function getLastNetworkTrace() {
    ensureLoaded();
    return clone(lastNetworkTrace);
}

export function clearLastNetworkTrace() {
    lastNetworkTrace = null;
    persist();
}

export function startNetworkTrace({ requestType = 'unknown', apiUrl, stream, requestBody, headers }) {
    if (!isNetworkDebugEnabled()) return;

    lastNetworkTrace = {
        requestType,
        apiUrl,
        stream: !!stream,
        startedAt: Date.now(),
        completedAt: null,
        durationMs: null,
        request: clone(requestBody),
        requestHeaders: maskHeaders(headers),
        responseStatus: null,
        responseHeaders: null,
        rawResponse: null,
        streamLines: [],
        parsed: {
            text: '',
            reasoning: '',
            error: null
        }
    };

    persist();
}

export function updateNetworkTrace(patch = {}) {
    if (!isNetworkDebugEnabled() || !lastNetworkTrace) return;

    if (patch.responseHeaders) {
        patch.responseHeaders = maskHeaders(patch.responseHeaders);
    }

    Object.assign(lastNetworkTrace, clone(patch));
    persist();
}

export function appendNetworkTraceLine(line) {
    if (!isNetworkDebugEnabled() || !lastNetworkTrace || !line) return;

    lastNetworkTrace.streamLines.push(String(line));
    if (lastNetworkTrace.streamLines.length > MAX_STREAM_LINES) {
        lastNetworkTrace.streamLines = lastNetworkTrace.streamLines.slice(-MAX_STREAM_LINES);
    }
    persist();
}

export function finishNetworkTrace({ rawResponse, text, reasoning, error } = {}) {
    if (!isNetworkDebugEnabled() || !lastNetworkTrace) return;

    if (rawResponse !== undefined) lastNetworkTrace.rawResponse = clone(rawResponse);
    if (text !== undefined) lastNetworkTrace.parsed.text = text || '';
    if (reasoning !== undefined) lastNetworkTrace.parsed.reasoning = reasoning || '';
    if (error !== undefined) {
        lastNetworkTrace.parsed.error = error
            ? (typeof error === 'string' ? error : (error.message || String(error)))
            : null;
    }

    lastNetworkTrace.completedAt = Date.now();
    lastNetworkTrace.durationMs = Math.max(0, lastNetworkTrace.completedAt - (lastNetworkTrace.startedAt || lastNetworkTrace.completedAt));
    persist();
}
