import { formatText, replaceMacros } from './textFormatter.js';
import { scrollToBottom } from './ui.js';
import { db } from './db.js';
import { BackgroundTask } from '@capawesome/capacitor-background-task';

export async function sendToLLM(text, activeChatChar, translations, currentLang, appendMessage, onComplete, onError, controller, onUpdate, type = 'normal') {
    let apiKey = localStorage.getItem('api-key');
    let apiUrl = localStorage.getItem('sc_api_endpoint_normalized') || localStorage.getItem('api-endpoint') || 'https://api.openai.com/v1';
    let model = localStorage.getItem('api-model') || 'gpt-3.5-turbo';
    let stream = localStorage.getItem('sc_api_stream') === 'true';
    let requestReasoning = localStorage.getItem('sc_api_request_reasoning') === 'true';
    let temp = parseFloat(localStorage.getItem('sc_api_temp')) || 0.7;
    let topP = parseFloat(localStorage.getItem('sc_api_topp')) || 0.9;
    let maxTokens = parseInt(localStorage.getItem('api-max-tokens')) || 300;

    if (!apiKey) {
        apiKey = prompt("Please enter your OpenAI API Key (stored locally):");
        if (apiKey) {
            localStorage.setItem('api-key', apiKey.trim());
            const keyInput = document.getElementById('api-key');
            if (keyInput) keyInput.value = apiKey.trim();
        } else {
            appendMessage({ role: 'char', text: "API Key is required. Please try again.", time: "System" }, null, "System", null);
            return;
        }
    }

    const container = document.getElementById('chat-messages');
    
    // --- Prompt Construction based on Preset ---
    const presets = (await db.get('sc_prompt_presets')) || [];
    const activePresetId = localStorage.getItem('sc_active_preset_id');
    const activePreset = presets.find(p => p.id === activePresetId) || presets[0]; // Fallback
    
    const messages = [];

    // Helper to get Chat History
    const getChatHistory = () => {
        const history = [];
        const msgNodes = container.querySelectorAll('.message-section:not(.deleting)');
        msgNodes.forEach(node => {
            const body = node.querySelector('.msg-body');
            if (!body || node.classList.contains('error')) return;
            if (node.classList.contains('generating-swipe')) return; // Skip message being regenerated
            if (body.querySelector('.typing-container')) return; // Skip incomplete messages

            // Clone to remove reasoning without affecting DOM
            const clone = body.cloneNode(true);
            const reasoning = clone.querySelector('.msg-reasoning');
            if (reasoning) reasoning.remove();
            const content = clone.textContent;

            if (node.classList.contains('user')) {
                history.push({ role: "user", content: content });
            } else if (node.classList.contains('char')) {
                history.push({ role: "assistant", content: content });
            }
        });
        return history;
    };

    // Helper to get User Persona
    const getUserPersona = () => {
        const savedPersona = localStorage.getItem('sc_active_persona');
        const persona = savedPersona ? JSON.parse(savedPersona) : { name: "User", prompt: "" };
        return `User Name: ${persona.name}\nUser Description: ${persona.prompt}`;
    };

    // Helper to get Char Card
    const getCharCard = () => {
        return `Character Name: ${activeChatChar.name}\nDescription: ${activeChatChar.description || activeChatChar.desc}`;
    };

    // Get Persona object for macros
    const savedPersonaStr = localStorage.getItem('sc_active_persona');
    const personaObj = savedPersonaStr ? JSON.parse(savedPersonaStr) : { name: "User", prompt: "" };

    // Iterate Blocks
    if (activePreset && activePreset.blocks) {
        activePreset.blocks.forEach(block => {
            if (!block.enabled) return;

            if (block.id === 'user_persona') {
                messages.push({ role: "system", content: getUserPersona() });
            } else if (block.id === 'char_card') {
                messages.push({ role: "system", content: getCharCard() });
            } else if (block.id === 'char_personality') {
                messages.push({ role: "system", content: `Personality: ${activeChatChar.personality}` });
            } else if (block.id === 'scenario') {
                messages.push({ role: "system", content: `Scenario: ${activeChatChar.scenario}` });
            } else if (block.id === 'chat_history') {
                messages.push(...getChatHistory());
            } else {
                // Custom Block
                let content = block.content;
                content = replaceMacros(content, activeChatChar, personaObj);
                messages.push({ role: block.role || "system", content: content });
            }
        });
    } else {
        // Fallback if no preset logic works
        messages.push({ role: "system", content: "You are a helpful assistant." });
        messages.push(...getChatHistory());
    }

    // Add Impersonation Prompt if needed
    if (type === 'impersonation' && text) {
        messages.push({ role: "system", content: text });
    }

    // --- Author's Notes Injection ---
    if (activeChatChar) {
        const anKey = `sc_an_${activeChatChar.name}`;
        try {
            const anData = JSON.parse(localStorage.getItem(anKey));
            if (anData && anData.enabled && anData.content) {
                let content = anData.content;
                content = replaceMacros(content, activeChatChar, personaObj);
                const noteMsg = { role: anData.role || 'system', content: content };
                const depth = parseInt(anData.depth) || 0;
                
                if (depth === 0) {
                    messages.push(noteMsg);
                } else {
                    let insertIdx = messages.length - depth;
                    if (insertIdx < 0) insertIdx = 0;
                    messages.splice(insertIdx, 0, noteMsg);
                }
            }
        } catch(e) { console.warn("Error processing Author's Notes:", e); }
    }
    // -------------------------------------------

    const charName = activeChatChar.name;
    
    let typingSection = null;
    let removeTypingWithAnimation = () => {};

    if (type !== 'impersonation' && type !== 'no_typing') {
        let avatarHtml = '';
        if (activeChatChar.avatar) {
            avatarHtml = `<img class="msg-avatar" src="${activeChatChar.avatar}" alt="">`;
        } else {
            const letter = (charName && charName[0]) ? charName[0].toUpperCase() : "?";
            const color = activeChatChar.color || '#ccc';
            avatarHtml = `<div class="msg-avatar" style="background-color: ${color}; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.2em;">${letter}</div>`;
        }
        
        typingSection = document.createElement('div');
        typingSection.className = 'message-section char';
        typingSection.innerHTML = `
            <div class="msg-header">
                ${avatarHtml}
                <span class="msg-name">${charName} <sup class="item-version">${activeChatChar.version}</sup></span>
            </div>
            <div class="msg-body">
                <div class="typing-container">
                    <svg class="typing-icon" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    <span class="typing-text">${translations[currentLang]['model_typing'] || 'Generating...'}</span>
                </div>
            </div>
        `;
        container.appendChild(typingSection);
        scrollToBottom('chat-messages', typingSection);

        removeTypingWithAnimation = () => {
            if (!typingSection || !typingSection.parentNode) return;
            typingSection.style.maxHeight = typingSection.scrollHeight + 'px';
            typingSection.classList.add('deleting');
            const onEnd = () => typingSection.remove();
            typingSection.addEventListener('animationend', onEnd, { once: true });
            setTimeout(onEnd, 350);
        };
    }

    const requestBody = {
        model: model,
        messages: messages,
        temperature: temp,
        top_p: topP,
        max_tokens: maxTokens,
        stream: stream,
        include_reasoning: requestReasoning // OpenRouter/DeepSeek specific
    };

    console.log("LLM Request:", requestBody);

    // Keep screen on during generation to prevent OS suspension
    let wakeLock = null;
    const requestWakeLock = async () => {
        if ('wakeLock' in navigator && document.visibilityState === 'visible') {
            try { wakeLock = await navigator.wakeLock.request('screen'); } catch (e) { console.warn("WakeLock error:", e); }
        }
    };
    await requestWakeLock();

    // Re-acquire lock if app comes back to foreground while generating
    const handleVisibilityChange = () => { if (document.visibilityState === 'visible') requestWakeLock(); };
    document.addEventListener('visibilitychange', handleVisibilityChange);

    // Setup Background Task to keep app alive if backgrounded
    let backgroundTaskId = null;
    let completeBackgroundTask = null;
    let isTaskFinished = false;

    try {
        backgroundTaskId = await BackgroundTask.beforeExit(async () => {
            if (isTaskFinished) {
                if (backgroundTaskId) BackgroundTask.finish({ taskId: backgroundTaskId });
                return;
            }
            await new Promise(resolve => {
                completeBackgroundTask = resolve;
            });
            if (backgroundTaskId) BackgroundTask.finish({ taskId: backgroundTaskId });
        });
    } catch (e) {
        console.warn("Background Task setup failed:", e);
    }

    try {
        const response = await fetch(`${apiUrl}/chat/completions`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${apiKey}`
            },
            body: JSON.stringify(requestBody),
            signal: controller ? controller.signal : undefined
        });

        if (!response.ok) throw new Error(`API Error: ${response.status}`);

        if (stream) {
            const reader = response.body.getReader();
            const decoder = new TextDecoder("utf-8");
            let fullText = "";
            let isFirst = true;

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                
                const chunk = decoder.decode(value, { stream: true });
                const lines = chunk.split('\n');
                
                for (const line of lines) {
                    const trimmed = line.trim();
                    if (!trimmed || !trimmed.startsWith('data: ')) continue;
                    
                    const dataStr = trimmed.substring(6);
                    if (dataStr === '[DONE]') continue;
                    
                    try {
                        const json = JSON.parse(dataStr);

                        if (json.error) {
                            throw new Error("API Stream Error: " + (json.error.message || JSON.stringify(json.error)));
                        }

                        if (!json.choices || !json.choices.length) continue;

                        const delta = json.choices[0].delta;
                        if (delta && (delta.content || delta.reasoning_content)) {
                            const content = delta.content || "";
                            const reasoning = delta.reasoning_content || null;
                            console.log("Stream chunk:", content, "Reasoning:", reasoning);
                            fullText += content;
                            
                            if (isFirst) {
                                if (typingSection) typingSection.remove();
                                isFirst = false;
                            }
                            
                            if (onUpdate) onUpdate(content, reasoning);
                        }
                    } catch (e) {
                        if (e.message && e.message.startsWith("API Stream Error")) {
                            throw e;
                        }
                        console.warn("Error parsing stream chunk", e);
                    }
                }
            }
            
            if (isFirst && typingSection) typingSection.remove(); // If stream finished but no content (rare)
            if (onComplete) onComplete(fullText, null);

        } else {
            const data = await response.json();
            console.log("LLM Response:", data);
            const content = data.choices[0].message.content;
            const reasoning = data.choices[0].message.reasoning_content;

            if (typingSection) typingSection.remove();
            if (onComplete) onComplete(content, reasoning);
        }
    } catch (e) {
        if (e.name === 'AbortError') {
            removeTypingWithAnimation();
            return;
        }
        removeTypingWithAnimation();
        if (onError) onError(e);
    } finally {
        document.removeEventListener('visibilitychange', handleVisibilityChange);
        if (wakeLock) {
            try { wakeLock.release(); } catch (e) {}
        }
        
        // Signal Background Task to finish
        isTaskFinished = true;
        if (completeBackgroundTask) {
            completeBackgroundTask();
        }
    }
}