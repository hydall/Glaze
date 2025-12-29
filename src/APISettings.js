import { showBottomSheet, closeBottomSheet } from './ui.js';
import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';

export function initSettings() {
    // API Settings Logic (Sliders)
    const rangeConfigs = [
        { slider: 'api-temp', input: 'val-temp-input', key: 'sc_api_temp', def: 0.7 },
        { slider: 'api-topp', input: 'val-topp-input', key: 'sc_api_topp', def: 0.9 }
    ];

    rangeConfigs.forEach(config => {
        const slider = document.getElementById(config.slider);
        const input = document.getElementById(config.input);
        
        // Load saved values
        const saved = localStorage.getItem(config.key);
        const val = saved !== null ? saved : config.def;
        if (slider) slider.value = val;
        if (input) input.value = val;

        if (slider) {
            slider.addEventListener('input', () => {
                if (input) input.value = slider.value;
                localStorage.setItem(config.key, slider.value);
            });
        }
        if (input) {
            input.addEventListener('input', () => {
                if (slider) slider.value = input.value;
                localStorage.setItem(config.key, input.value);
            });
        }
    });

    // Text Inputs for API Settings
    const apiInputs = [
        { id: 'api-endpoint', key: 'api-endpoint' },
        { id: 'api-key', key: 'api-key' },
        { id: 'api-model', key: 'api-model' },
        { id: 'api-max-tokens', key: 'api-max-tokens' },
        { id: 'api-context', key: 'api-context' }
    ];

    apiInputs.forEach(config => {
        const el = document.getElementById(config.id);
        if (el) {
            const saved = localStorage.getItem(config.key);
            if (saved) el.value = saved;
            
            const save = (e) => {
                let val = el.value.trim();
                if (config.id === 'api-endpoint') {
                    let normalized = val;
                    if (normalized) {
                        if (!/^https?:\/\//i.test(normalized)) {
                            normalized = 'https://' + normalized;
                        }
                        if (normalized.endsWith('/')) normalized = normalized.slice(0, -1);

                        const suffix = '/chat/completions';
                        if (normalized.toLowerCase().endsWith(suffix)) {
                            normalized = normalized.slice(0, -suffix.length);
                        }
                        if (normalized.endsWith('/')) normalized = normalized.slice(0, -1);

                        if (!normalized.endsWith('/v1')) normalized += '/v1';
                        localStorage.setItem('sc_api_endpoint_normalized', normalized);
                    }
                }
                localStorage.setItem(config.key, val);
            };
            el.addEventListener('input', save);
            el.addEventListener('change', save);
        }
    });

    // Checkbox for Stream
    const streamEl = document.getElementById('api-stream');
    if (streamEl) {
        const saved = localStorage.getItem('sc_api_stream');
        streamEl.checked = saved === 'true';
        streamEl.addEventListener('change', () => {
            localStorage.setItem('sc_api_stream', streamEl.checked);
        });
    }

    // Checkbox for Request Reasoning
    const reasoningEl = document.getElementById('api-reasoning');
    if (reasoningEl) {
        const saved = localStorage.getItem('sc_api_request_reasoning');
        reasoningEl.checked = saved === 'true';
        reasoningEl.addEventListener('change', () => {
            localStorage.setItem('sc_api_request_reasoning', reasoningEl.checked);
        });
    }

    // --- Auto-fetch Models Logic ---
    let debounceTimer = null;
    let availableModels = [];
    let isFetching = false;
    let statusTimeout = null;
    const endpointInput = document.getElementById('api-endpoint');
    const apiKeyInput = document.getElementById('api-key');

    // Status Indicator Elements
    const statusDot = document.getElementById('api-status-dot');
    const statusText = document.getElementById('api-status-text');
    const statusIndicator = document.getElementById('api-status-indicator');

    function updateStatusUI(state) {
        if (!statusDot || !statusText) return;
        
        const texts = {
            connecting: translations[currentLang]?.status_connecting || "Connecting...",
            connected: translations[currentLang]?.status_connected || "Connected",
            failed: translations[currentLang]?.status_failed || "Failed"
        };

        if (state === 'connecting') {
            statusDot.style.backgroundColor = 'orange';
        } else if (state === 'connected') {
            statusDot.style.backgroundColor = '#4CAF50'; // Green
        } else if (state === 'failed') {
            statusDot.style.backgroundColor = '#ff4444'; // Red
        }

        // Handle Text Transition
        if (statusTimeout) {
            clearTimeout(statusTimeout);
            statusTimeout = null;
        }

        if (statusText.textContent === texts[state]) {
            statusText.style.opacity = '1';
        } else {
            statusText.style.opacity = '0';
            statusTimeout = setTimeout(() => {
                statusText.textContent = texts[state];
                statusText.style.opacity = '1';
                statusTimeout = null;
            }, 200);
        }
    }

    async function fetchModels() {
        if (isFetching) return;

        const endpoint = localStorage.getItem('sc_api_endpoint_normalized') || localStorage.getItem('api-endpoint');
        if (!endpoint) {
            updateStatusUI('failed');
            return;
        }

        isFetching = true;
        updateStatusUI('connecting');

        // Construct models URL (assuming OpenAI compatible /v1/models)
        let url = endpoint;
        if (url.endsWith('/chat/completions')) url = url.replace('/chat/completions', '');
        if (url.endsWith('/')) url = url.slice(0, -1);
        if (!url.endsWith('/models')) url += '/models';

        const key = localStorage.getItem('api-key');
        
        try {
            const headers = {};
            if (key) headers['Authorization'] = `Bearer ${key}`;
            
            console.log("Fetching models from:", url);
            const res = await fetch(url, { headers });
            if (res.ok) {
                updateStatusUI('connected');
                const data = await res.json();
                let models = [];
                // Handle different response formats (OpenAI {data: []}, or direct array)
                if (data.data && Array.isArray(data.data)) {
                    models = data.data.map(m => m.id);
                } else if (Array.isArray(data)) {
                    models = data.map(m => m.id);
                }
                
                if (models.length > 0) {
                    models.sort();
                    availableModels = models;
                    console.log('Models updated:', models);
                }
            } else {
                updateStatusUI('failed');
            }
        } catch (e) {
            console.warn('Error fetching models:', e);
            updateStatusUI('failed');
        } finally {
            isFetching = false;
        }
    }

    if (endpointInput) {
        endpointInput.addEventListener('input', () => {
            if (debounceTimer) clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                fetchModels();
            }, 1000);
        });
    }

    if (apiKeyInput) {
        apiKeyInput.addEventListener('input', () => {
            if (debounceTimer) clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                fetchModels();
            }, 1000);
        });
    }

    if (statusIndicator) {
        statusIndicator.addEventListener('click', () => {
            fetchModels();
        });
    }

    // Initial check on load
    setTimeout(fetchModels, 500);

    // --- Model Dropdown Logic ---
    const btnModelList = document.getElementById('btn-model-list');
    const modelInput = document.getElementById('api-model');

    if (btnModelList && modelInput) {
        btnModelList.addEventListener('click', () => {
            let models = availableModels;

            showBottomSheet({
                title: "Select Model",
                items: models.length > 0 ? models.map(m => ({
                    label: m,
                    onClick: () => {
                        modelInput.value = m;
                        localStorage.setItem('api-model', m);
                        closeBottomSheet();
                    }
                })) : [{ label: "No models found", onClick: closeBottomSheet }]
            });
        });
    }
}