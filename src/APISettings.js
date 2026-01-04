import { showBottomSheet, closeBottomSheet } from './bottomsheet.js';
import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { db } from './db.js';

export async function initSettings() {
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

    // --- API Presets Logic ---
    const presetSelector = document.getElementById('btn-api-preset-selector');
    const presetNameLabel = document.getElementById('current-api-preset-name');
    
    let apiPresets = [];
    let activeApiPreset = null;

    async function loadApiPresets() {
        const saved = await db.get('sc_api_connection_presets');
        if (saved && Array.isArray(saved) && saved.length > 0) {
            apiPresets = saved;
        } else {
            // Create default from current
            apiPresets = [{
                id: 'default',
                name: 'Default',
                endpoint: localStorage.getItem('api-endpoint') || '',
                key: localStorage.getItem('api-key') || '',
                model: localStorage.getItem('api-model') || '',
                max_tokens: localStorage.getItem('api-max-tokens') || '8000',
                context: localStorage.getItem('api-context') || '32000',
                temp: localStorage.getItem('sc_api_temp') || '0.7',
                topp: localStorage.getItem('sc_api_topp') || '0.9',
                stream: localStorage.getItem('sc_api_stream') === 'true',
                reasoning: localStorage.getItem('sc_api_request_reasoning') === 'true'
            }];
            await db.set('sc_api_connection_presets', apiPresets);
        }

        const activeId = localStorage.getItem('sc_active_api_preset_id');
        activeApiPreset = apiPresets.find(p => p.id === activeId) || apiPresets[0];
        updatePresetUI();
    }

    function updatePresetUI() {
        if (presetNameLabel) presetNameLabel.textContent = activeApiPreset.name;
        
        const setVal = (key, val, elId) => {
            localStorage.setItem(key, val);
            const el = document.getElementById(elId);
            if (el) {
                if (el.type === 'checkbox') el.checked = (val === true || val === 'true');
                else el.value = val;
                // Trigger change event for existing listeners (like normalization)
                el.dispatchEvent(new Event('input', { bubbles: true }));
            }
        };

        setVal('api-endpoint', activeApiPreset.endpoint, 'api-endpoint');
        setVal('api-key', activeApiPreset.key, 'api-key');
        setVal('api-model', activeApiPreset.model, 'api-model');
        setVal('api-max-tokens', activeApiPreset.max_tokens, 'api-max-tokens');
        setVal('api-context', activeApiPreset.context, 'api-context');
        setVal('sc_api_temp', activeApiPreset.temp, 'api-temp');
        setVal('sc_api_topp', activeApiPreset.topp, 'api-topp');
        
        const tempInput = document.getElementById('val-temp-input');
        if (tempInput) tempInput.value = activeApiPreset.temp;
        const toppInput = document.getElementById('val-topp-input');
        if (toppInput) toppInput.value = activeApiPreset.topp;

        setVal('sc_api_stream', activeApiPreset.stream, 'api-stream');
        setVal('sc_api_request_reasoning', activeApiPreset.reasoning, 'api-reasoning');

        if (activeApiPreset.endpoint) {
             if (debounceTimer) clearTimeout(debounceTimer);
             debounceTimer = setTimeout(fetchModels, 500);
        }
    }

    async function saveApiPresets() {
        await db.set('sc_api_connection_presets', apiPresets);
        localStorage.setItem('sc_active_api_preset_id', activeApiPreset.id);
    }

    const hookInput = (id, field) => {
        const el = document.getElementById(id);
        if (el) {
            el.addEventListener('input', () => {
                activeApiPreset[field] = el.type === 'checkbox' ? el.checked : el.value;
                saveApiPresets();
            });
            if (el.type === 'checkbox') {
                el.addEventListener('change', () => {
                    activeApiPreset[field] = el.checked;
                    saveApiPresets();
                });
            }
        }
    };

    hookInput('api-endpoint', 'endpoint');
    hookInput('api-key', 'key');
    hookInput('api-model', 'model');
    hookInput('api-max-tokens', 'max_tokens');
    hookInput('api-context', 'context');
    hookInput('api-temp', 'temp');
    hookInput('api-topp', 'topp');
    hookInput('api-stream', 'stream');
    hookInput('api-reasoning', 'reasoning');

    if (presetSelector) {
        presetSelector.addEventListener('click', () => {
            const listContainer = document.createElement('div');
            apiPresets.forEach(p => {
                const el = document.createElement('div');
                el.className = 'sheet-item';
                if (p.id === activeApiPreset.id) el.style.backgroundColor = 'var(--bg-gray)';
                el.innerHTML = `<div class="sheet-item-content">${p.name}</div>` + 
                    (apiPresets.length > 1 ? `<div class="sheet-item-remove"><svg viewBox="0 0 24 24" style="fill:#ff4444;width:24px;height:24px;"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg></div>` : '');
                
                el.addEventListener('click', () => {
                    activeApiPreset = p;
                    saveApiPresets();
                    updatePresetUI();
                    closeBottomSheet();
                });

                if (apiPresets.length > 1) {
                    el.querySelector('.sheet-item-remove').addEventListener('click', (e) => {
                        e.stopPropagation();
                        apiPresets = apiPresets.filter(pr => pr.id !== p.id);
                        if (activeApiPreset.id === p.id) activeApiPreset = apiPresets[0];
                        saveApiPresets();
                        updatePresetUI();
                        closeBottomSheet();
                    });
                }
                listContainer.appendChild(el);
            });

            // Add "Create New" button to the list
            const addEl = document.createElement('div');
            addEl.className = 'sheet-item';
            addEl.innerHTML = `<div class="sheet-item-icon"><svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg></div><div class="sheet-item-content">${translations[currentLang]['create_new']}</div>`;
            addEl.addEventListener('click', () => {
                closeBottomSheet();
                setTimeout(() => {
                    showBottomSheet({ title: translations[currentLang]['new_preset'], content: `<div class="menu-group" style="margin-bottom: 20px;"><div class="settings-item"><input type="text" id="new-api-preset-name" placeholder="Preset Name" style="width:100%;padding:10px;border-radius:8px;border:1px solid var(--border-color);background:var(--bg-gray);color:var(--text-black);"></div></div><div class="btn-save" id="btn-create-api-preset">${translations[currentLang]['btn_create']}</div>` });
                    setTimeout(() => { const btn = document.getElementById('btn-create-api-preset'); const input = document.getElementById('new-api-preset-name'); if (btn && input) { input.focus(); btn.onclick = () => { const name = input.value.trim() || "New Preset"; const newPreset = { ...activeApiPreset, id: Date.now().toString(), name: name }; apiPresets.push(newPreset); activeApiPreset = newPreset; saveApiPresets(); updatePresetUI(); closeBottomSheet(); }; } }, 100);
                }, 300);
            });
            listContainer.appendChild(addEl);

            showBottomSheet({ title: "API Presets", content: listContainer });
        });
    }
    await loadApiPresets();
}