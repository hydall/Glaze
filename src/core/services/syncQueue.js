import { ref, computed } from 'vue';
import { setSyncError } from '@/core/states/syncState.js';

const MAX_RETRIES = 3;
const BASE_DELAY_MS = 1000;
const MAX_DELAY_MS = 30000;

let _queue = Promise.resolve();
let _pendingCount = ref(0);
let _isPaused = false;
let _abortController = null;

export const pendingOperations = computed(() => _pendingCount.value);

export function enqueue(operation, label = 'sync') {
    if (_isPaused) {
        console.warn(`[syncQueue] Paused — dropping "${label}"`);
        return Promise.resolve();
    }

    _pendingCount.value++;
    const controller = _abortController;

    _queue = _queue.then(async () => {
        try {
            await retryWithBackoff(operation, label, controller);
        } catch (err) {
            if (err.name === 'AbortError') {
                console.log(`[syncQueue] Aborted "${label}"`);
                return;
            }
            console.error(`[syncQueue] Failed "${label}" after retries:`, err);
            setSyncError(`${label}: ${err.message}`);
        } finally {
            _pendingCount.value = Math.max(0, _pendingCount.value - 1);
        }
    });

    return _queue;
}

async function retryWithBackoff(operation, label, controller) {
    let lastError;

    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
        if (controller && controller.signal.aborted) {
            throw new DOMException('Aborted', 'AbortError');
        }

        try {
            return await operation();
        } catch (err) {
            lastError = err;

            if (err.name === 'AbortError') throw err;

            const isRetryable = isRetryableError(err);
            if (!isRetryable || attempt === MAX_RETRIES) {
                throw err;
            }

            const delay = Math.min(
                BASE_DELAY_MS * Math.pow(2, attempt) + Math.random() * 500,
                MAX_DELAY_MS
            );

            console.warn(
                `[syncQueue] Retry ${attempt + 1}/${MAX_RETRIES} for "${label}" in ${Math.round(delay)}ms:`,
                err.message
            );

            await sleep(delay, controller);
        }
    }

    throw lastError;
}

function isRetryableError(err) {
    if (err.status === 401 || err.status === 403) return false;
    if (err.status === 400 || err.status === 404) return false;
    if (err.status >= 400 && err.status < 500) return false;
    if (err.name === 'AbortError') return false;
    return true;
}

function sleep(ms, controller) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(resolve, ms);
        if (controller && controller.signal) {
            controller.signal.addEventListener('abort', () => {
                clearTimeout(timer);
                reject(new DOMException('Aborted', 'AbortError'));
            }, { once: true });
        }
    });
}

export function pauseQueue() {
    _isPaused = true;
}

export function resumeQueue() {
    _isPaused = false;
}

export function abortQueue() {
    if (_abortController) {
        _abortController.abort();
    }
    _abortController = new AbortController();
    _isPaused = false;
}

export function createAbortSignal() {
    if (!_abortController) {
        _abortController = new AbortController();
    }
    return _abortController.signal;
}

export function clearQueue() {
    abortQueue();
    _queue = Promise.resolve();
    _pendingCount.value = 0;
    _isPaused = false;
}
