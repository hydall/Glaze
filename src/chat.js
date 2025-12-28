import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { sendToLLM } from './llmApi.js';
import { attachLongPress, showBottomSheet, closeBottomSheet, scrollToBottom, animateTextChange } from './ui.js';
import { formatText, replaceMacros } from './textFormatter.js';
import { renderDialogs, refreshDialogs } from './dialogList.js';
import { openCharacterEditor } from './editor.js';
import { db } from './db.js';
import { characters } from './characterList.js';

let activeChatChar = null;
let _currentOnBack = null;
const generatingStates = {}; // { charName: genId }
let genIdCounter = 0;

export function isCharacterGenerating(charName) {
    return !!generatingStates[charName];
}

// Local cache for chats to maintain synchronous-like access for UI
let allChats = {};

export async function loadChats() {
    // Migration
    const localChats = localStorage.getItem('sc_chats');
    if (localChats) {
        try {
            allChats = JSON.parse(localChats);
            await db.set('sc_chats', allChats);
            localStorage.removeItem('sc_chats');
            console.log("Migrated chats to IndexedDB");
        } catch(e) { console.error(e); }
    } else {
        allChats = (await db.get('sc_chats')) || {};
    }
}

function getAllGreetings(char) {
    const greetings = [char.first_mes];
    if (char.alternate_greetings && Array.isArray(char.alternate_greetings)) {
        greetings.push(...char.alternate_greetings);
    }
    return greetings.filter(g => g);
}

function getChatData(charName) {
    let chats = allChats;
    let data = chats[charName];

    if (Array.isArray(data)) {
        // Migration
        data = {
            currentId: 1,
            sessions: { 1: data }
        };
        chats[charName] = data;
        localStorage.setItem('sc_chats', JSON.stringify(chats));
    } else if (!data) {
        data = {
            currentId: 1,
            sessions: { 1: [] }
        };
    }
    return data;
}

function saveMessageToSession(charName, msg) {
    let chats = allChats;
    let data = chats[charName]; // Assume migration handled or structure valid if we are here
    
    if (Array.isArray(data) || !data) data = getChatData(charName);

    if (!data.sessions[data.currentId]) {
        data.sessions[data.currentId] = [];
    }
    if (!msg.timestamp) msg.timestamp = Date.now();
    data.sessions[data.currentId].push(msg);
    
    chats[charName] = data;
    db.set('sc_chats', chats); // Async save
}

function updateSessionMessage(char, msgIndex, newMsgData) {
    let chats = allChats;
    let data = chats[char.name];
    
    if (data && data.sessions[data.currentId]) {
        data.sessions[data.currentId][msgIndex] = newMsgData;
        chats[char.name] = data;
        db.set('sc_chats', chats);
    }
}

export async function deleteAllChats(charName) {
    if (allChats[charName]) {
        delete allChats[charName];
        await db.set('sc_chats', allChats);
    }
}

export function initChat() {
    const chatInput = document.getElementById('chat-input');
    if (chatInput) {
        chatInput.addEventListener('input', function() {
            this.style.height = 'auto';
            this.style.height = (this.scrollHeight) + 'px';
        });
        // Fix for double-tap issue on mobile (prevents parent handlers from stealing focus)
        chatInput.addEventListener('touchstart', (e) => {
            e.stopPropagation();
        }, { passive: true });
    }

    document.getElementById('btn-send').addEventListener('click', sendMessage);

    document.getElementById('btn-magic').addEventListener('click', (e) => {
        e.stopPropagation();
        document.getElementById('magic-menu').classList.toggle('hidden');
    });

    document.addEventListener('click', () => {
        const menu = document.getElementById('magic-menu');
        if (menu) menu.classList.add('hidden');
    });

    // Magic Menu Regenerate
    const btnMagicRegen = document.getElementById('btn-regenerate');
    if (btnMagicRegen) btnMagicRegen.addEventListener('click', (e) => {
        e.stopPropagation();
        
        // Cancel any active editing
        const editingEl = document.querySelector('.message-section.editing');
        if (editingEl) cancelEdit(editingEl);

        if (activeChatChar && generatingStates[activeChatChar.name]) return;

        const container = document.getElementById('chat-messages');
        const lastMsg = container.lastElementChild;
        const allMsgs = Array.from(container.querySelectorAll('.message-section'));
        const index = lastMsg ? allMsgs.indexOf(lastMsg) : -1;
        if (lastMsg && (index > 0 || (index === 0 && lastMsg.classList.contains('user')))) {
            regenerateMessage(lastMsg, 'magic');
        }
        document.getElementById('magic-menu').classList.add('hidden');
    });

    const btnImpersonate = document.getElementById('btn-impersonate');
    if (btnImpersonate) {
        btnImpersonate.addEventListener('click', (e) => {
            e.stopPropagation();
            document.getElementById('magic-menu').classList.add('hidden');
            startImpersonation();
        });
    }
}

function updateSendButton(isGenerating) {
    const btn = document.getElementById('btn-send');
    if (!btn) return;
    if (isGenerating) {
        // Stop Icon
        btn.innerHTML = '<svg viewBox="0 0 24 24"><path d="M6 6h12v12H6z"/></svg>';
    } else {
        // Send Icon
        btn.innerHTML = '<svg viewBox="0 0 24 24"><path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/></svg>';
    }
}

function sendMessage() {
    if (activeChatChar && generatingStates[activeChatChar.name]) {
        // Stop Generation
        const state = generatingStates[activeChatChar.name];
        if (state.controller) state.controller.abort();
        if (state.restoreState) state.restoreState();
        delete generatingStates[activeChatChar.name];
        updateSendButton(false);
        
        // Remove placeholder if exists (for re-entered chat)
        const placeholder = document.querySelector('.typing-indicator-placeholder');
        if (placeholder) placeholder.remove();

        // Aggressively remove any active typing indicator
        const activeTyping = document.querySelectorAll('.typing-container');
        activeTyping.forEach(el => {
            const section = el.closest('.message-section');
            if (section) removeWithAnimation(section);
        });

        return;
    }

    const input = document.getElementById('chat-input');
    const text = input.value.trim();
    if (text) {
        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        
        // Get current persona info
        const savedPersona = localStorage.getItem('sc_active_persona');
        const persona = savedPersona ? JSON.parse(savedPersona) : { name: "User", avatar: null };
        
        // Apply macros to user text
        const processedText = replaceMacros(text, activeChatChar, persona);
        
        input.value = '';
        input.style.height = 'auto';

        const msgData = { role: 'user', text: processedText, time: time, timestamp: Date.now(), persona: { name: persona.name, avatar: persona.avatar } };
        appendMessage(msgData, null, persona.name, null);
        
        if (activeChatChar) {
            startGeneration(activeChatChar, null);
        }
    }
}

window.addEventListener('character-updated', (e) => {
    if (!activeChatChar) return;
    
    const updatedChar = e.detail.character;
    // Check if it's the same character object reference
    if (activeChatChar === updatedChar) {
        // Update Header Avatar
        const headerAvatarImg = document.getElementById('chat-header-avatar');
        const headerPlaceholder = document.getElementById('chat-header-avatar-placeholder');
        
        if (activeChatChar.avatar) {
            if (headerAvatarImg) {
                headerAvatarImg.src = activeChatChar.avatar;
                headerAvatarImg.style.display = 'block';
            }
            if (headerPlaceholder) headerPlaceholder.style.display = 'none';
        } else {
            if (headerAvatarImg) headerAvatarImg.style.display = 'none';
            if (headerPlaceholder) {
                headerPlaceholder.style.display = 'flex';
                headerPlaceholder.style.backgroundColor = activeChatChar.color || '#ccc';
                headerPlaceholder.textContent = (activeChatChar.name[0] || "?").toUpperCase();
            }
        }
        
        // Update Message Avatars in the current chat view
        const charMsgs = document.querySelectorAll('.message-section.char .msg-header');
        charMsgs.forEach(header => {
            const avatarEl = header.querySelector('.msg-avatar');
            if (avatarEl) {
                // Re-render the avatar part
                let newAvatarHtml = '';
                if (activeChatChar.avatar) {
                    newAvatarHtml = `<img class="msg-avatar" src="${activeChatChar.avatar}" alt="">`;
                } else {
                    newAvatarHtml = `<div class="msg-avatar" style="background-color: ${activeChatChar.color || '#ccc'}; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.2em;">${(activeChatChar.name[0] || "?").toUpperCase()}</div>`;
                }
                avatarEl.outerHTML = newAvatarHtml;
            }
        });
    }
});

function handleGenerationError(charName, error) {
    const state = generatingStates[charName];
    if (state) {
        delete generatingStates[charName];
    }
    
    const placeholder = document.querySelector('.typing-indicator-placeholder');
    if (placeholder) placeholder.remove();

    const activeTyping = document.querySelectorAll('.typing-container');
    activeTyping.forEach(el => {
        const section = el.closest('.message-section');
        if (section) section.remove();
    });

    if (activeChatChar && activeChatChar.name === charName) {
        updateSendButton(false);
        
        if (error) {
            const now = new Date();
            const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
            const msg = {
                role: 'char',
                text: `Error: ${error.message}`,
                time: time, 
                style: 'color: white;',
                isError: true
            };
            appendMessage(msg, activeChatChar.avatar, activeChatChar.name, null, false);
        }
    }
    renderDialogs();
}

// Update startGeneration to accept existing element
function startGeneration(char, text, existingElement = null, onAbort = null) {
    const genId = ++genIdCounter;
    const controller = new AbortController();
    const startTime = Date.now();
    
    let timerInterval = null;
    const startTimer = (el) => {
        const statEl = el.querySelector('.gen-stat');
        if (statEl) {
            statEl.style.display = 'flex';
            if (timerInterval) return;
            timerInterval = setInterval(() => {
                const elapsed = ((Date.now() - startTime) / 1000).toFixed(1) + 's';
                const timeIcon = `<svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:4px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>`;
                statEl.innerHTML = `${timeIcon} <span class="gen-time">${elapsed}</span>`;
            }, 100);
        }
    };

    generatingStates[char.name] = { genId, controller };

    if (activeChatChar && activeChatChar.name === char.name) {
        updateSendButton(true);
    }
    
    if (existingElement) startTimer(existingElement);

    let streamingMsgElement = existingElement; // Use existing if provided
    
    // Create shell immediately if normal generation (ensures timer is visible instantly)
    if (!streamingMsgElement && !text) {
        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        const msg = { 
            role: 'char', 
            text: "", 
            time: time, 
            timestamp: Date.now(),
            swipes: [""],
            swipeId: 0
        };
        streamingMsgElement = appendMessage(msg, char.avatar, char.name, char.version, false, true);
        
        const body = streamingMsgElement.querySelector('.msg-body');
        if (body) {
            body.innerHTML = `
                <div class="typing-container">
                    <svg class="typing-icon" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    <span class="typing-text">${translations[currentLang]['model_typing'] || 'Generating...'}</span>
                </div>`;
        }
        
        startTimer(streamingMsgElement);
    }

    const restoreState = () => {
        if (timerInterval) clearInterval(timerInterval);
        if (existingElement) existingElement.classList.remove('generating-swipe');
        
        // Restore content if it was a swipe generation
        if (existingElement && existingElement._msgData) {
            const msg = existingElement._msgData;
            const body = existingElement.querySelector('.msg-body');
            if (body) body.innerHTML = formatText(msg.text);
            
            if (msg.swipes && msg.swipes.length > 1) {
                const footer = existingElement.querySelector('.msg-footer');
                let sw = footer.querySelector('.msg-switcher');
                if (!sw) {
                    sw = document.createElement('div');
                    sw.className = 'msg-switcher';
                    sw.innerHTML = `
                        <div class="msg-switcher-btn prev"><svg viewBox="0 0 24 24"><path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg></div>
                        <div class="msg-switcher-count"></div>
                        <div class="msg-switcher-btn next"><svg viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg></div>
                    `;
                    footer.appendChild(sw);
                    sw.querySelector('.prev').onclick = (e) => { e.stopPropagation(); changeSwipe(existingElement, msg, -1, true); };
                    sw.querySelector('.next').onclick = (e) => { 
                        e.stopPropagation(); 
                        if (msg.swipeId >= msg.swipes.length - 1) { 
                            if (!existingElement.nextElementSibling) regenerateMessage(existingElement, 'new_variant'); 
                        } else { 
                            changeSwipe(existingElement, msg, 1, true); 
                        } 
                    };
                }
                sw.querySelector('.msg-switcher-count').textContent = `${(msg.swipeId || 0) + 1}/${msg.swipes.length}`;
            }
        }

        if (onAbort) onAbort();
    };

    generatingStates[char.name] = { genId, controller, restoreState };

    const onError = (e) => {
        restoreState();
        handleGenerationError(char.name, e);
    };
    
    let fullText = text || ""; // If text provided (e.g. impersonation), start with it
    let fullReasoning = "";
    let displayedText = "";
    let typewriterRaf = null;
    const view = document.getElementById('chat-messages');

    const processTypewriter = () => {
        if (displayedText.length < fullText.length) {
            const pending = fullText.length - displayedText.length;
            const step = Math.max(1, Math.ceil(pending / 3));
            displayedText = fullText.substring(0, displayedText.length + step);
            
            const body = streamingMsgElement.querySelector('.msg-body');
            if (body) body.innerHTML = formatText(displayedText);

            // Smart Auto-scroll: скроллим только если пользователь внизу
            if (view) {
                const threshold = 50;
                const dist = view.scrollHeight - view.scrollTop - view.clientHeight;
                if (dist < threshold) view.scrollTop = view.scrollHeight;
            }
            
            typewriterRaf = requestAnimationFrame(processTypewriter);
        } else {
            typewriterRaf = null;
        }
    };

    const onUpdate = (chunk, reasoningChunk) => {
        // Clear initial typing dots on first chunk
        if (fullText === "" && chunk) {
             const body = streamingMsgElement.querySelector('.msg-body');
             if (body && body.querySelector('.typing-container')) {
                 body.innerHTML = "";
             }
        }
        
        fullText += chunk || "";
        if (reasoningChunk) fullReasoning += reasoningChunk;

        // ... (existing CoT logic) ...
        const tagStart = localStorage.getItem('sc_api_reasoning_start');
        const tagEnd = localStorage.getItem('sc_api_reasoning_end');
        
        let effectiveReasoning = fullReasoning;
        let effectiveText = fullText;

        if (tagStart && tagEnd && fullText.includes(tagStart)) {
            const startIndex = fullText.indexOf(tagStart);
            const endIndex = fullText.indexOf(tagEnd, startIndex);
            
            if (endIndex !== -1) {
                effectiveReasoning = fullText.substring(startIndex + tagStart.length, endIndex);
                effectiveText = fullText.substring(0, startIndex) + fullText.substring(endIndex + tagEnd.length);
            } else {
                effectiveReasoning = fullText.substring(startIndex + tagStart.length);
                effectiveText = fullText.substring(0, startIndex);
            }
        }

        updateReasoningBlock(streamingMsgElement, effectiveReasoning);
        fullText = effectiveText; // Update global text for typewriter
        if (!typewriterRaf) typewriterRaf = requestAnimationFrame(processTypewriter);
    };

    const type = (streamingMsgElement || existingElement) ? 'no_typing' : 'normal';
    sendToLLM(text, char, translations, currentLang, appendMessage, (response, finalReasoning) => {
        const currentState = generatingStates[char.name];
        if (timerInterval) clearInterval(timerInterval);
        if (!currentState || currentState.genId !== genId) return; // Stopped or superseded
        
        if (typewriterRaf) cancelAnimationFrame(typewriterRaf);
        delete generatingStates[char.name];

        if (existingElement) existingElement.classList.remove('generating-swipe');

        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        const duration = ((Date.now() - startTime) / 1000).toFixed(2) + 's';
        
        const msg = {
            role: 'char',
            text: response,
            time: time,
            genTime: duration,
            timestamp: Date.now(),
            tokens: response.length,
            reasoning: fullReasoning || finalReasoning,
            swipes: [response],
            swipeId: 0,
            swipesMeta: [{ genTime: duration }]
        };

        if (activeChatChar && activeChatChar.name === char.name) {
            // ... (existing tag check logic) ...
            const tagStart = localStorage.getItem('sc_api_reasoning_start');
            const tagEnd = localStorage.getItem('sc_api_reasoning_end');
            if (tagStart && tagEnd && response.includes(tagStart) && response.includes(tagEnd)) {
                 const sIdx = response.indexOf(tagStart);
                 const eIdx = response.indexOf(tagEnd, sIdx);
                 if (sIdx !== -1 && eIdx !== -1) {
                     msg.reasoning = response.substring(sIdx + tagStart.length, eIdx);
                     msg.text = response.substring(0, sIdx) + response.substring(eIdx + tagEnd.length);
                 }
            }

            // Remove placeholder if exists
            const placeholder = document.querySelector('.typing-indicator-placeholder');
            if (placeholder) placeholder.remove();

            if (streamingMsgElement) {
                // If we were streaming, just update the existing element one last time and save
                const body = streamingMsgElement.querySelector('.msg-body');
                if (body) {
                    // Ensure we don't have typing indicator
                    body.innerHTML = formatText(msg.text);
                }
                updateReasoningBlock(streamingMsgElement, msg.reasoning);
                
                // Final time update
                const statEl = streamingMsgElement.querySelector('.gen-stat');
                if (statEl) {
                     const timeIcon = `<svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:4px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>`;
                     statEl.innerHTML = `${timeIcon} <span class="gen-time">${duration}</span>`;
                     statEl.style.display = 'flex';
                }
                
                // If this was a new variant generation (reused element), we need to update the specific swipe
                if (existingElement && streamingMsgElement._msgData) {
                    const mData = streamingMsgElement._msgData;
                    addSwipe(streamingMsgElement, mData, msg.text, { genTime: duration });
                } else {
                    // New message - update the single swipe (fix for "empty first variant" issue)
                    if (streamingMsgElement._msgData) {
                        streamingMsgElement._msgData.text = msg.text;
                        streamingMsgElement._msgData.swipes = [msg.text];
                        streamingMsgElement._msgData.swipeId = 0;
                        streamingMsgElement._msgData.reasoning = msg.reasoning;
                        streamingMsgElement._msgData.swipesMeta = [{ genTime: duration }];
                        streamingMsgElement._msgData.genTime = duration;
                    }
                    saveMessageToSession(char.name, msg);
                }
                
                // Final scroll check
                if (view) {
                    const threshold = 100;
                    const dist = view.scrollHeight - view.scrollTop - view.clientHeight;
                    if (dist < threshold) scrollToBottom('chat-messages', streamingMsgElement);
                }
            } else {
                appendMessage(msg, char.avatar, char.name, char.version, true);
            }
            updateSendButton(false);
        } else {
            saveMessageToSession(char.name, msg);
            // Mark unread
            db.get('sc_unread').then(unread => {
                unread = unread || {};
                unread[char.name] = true;
                db.set('sc_unread', unread);
            });

            // If we are in the list view or another chat, update the list
            renderDialogs();
        }
    }, onError, controller, onUpdate, type);
}

function startImpersonation() {
    if (!activeChatChar) return;
    
    const activePresetId = localStorage.getItem('sc_active_preset_id');
    const presets = JSON.parse(localStorage.getItem('sc_prompt_presets') || '[]');
    const preset = presets.find(p => p.id === activePresetId) || presets[0];
    const promptText = preset ? (preset.impersonationPrompt || "") : "";

    if (!promptText) {
        alert("Impersonation prompt is empty. Please configure it in Generation > Preset.");
        return;
    }

    const input = document.getElementById('chat-input');
    const statusEl = document.getElementById('impersonate-status');
    if (statusEl) statusEl.style.display = 'flex';

    const controller = new AbortController();
    generatingStates[activeChatChar.name] = { genId: ++genIdCounter, controller, type: 'impersonation' };
    updateSendButton(true);

    const onUpdate = (chunk) => {
        if (chunk) {
            input.value += chunk;
            input.style.height = 'auto';
            input.style.height = (input.scrollHeight) + 'px';
            input.scrollTop = input.scrollHeight;
        }
    };

    const onComplete = (response) => {
        delete generatingStates[activeChatChar.name];
        updateSendButton(false);
        if (statusEl) statusEl.style.display = 'none';
        if (input) {
            // Ensure full text is present (fixes non-streaming case)
            input.value = response;
            input.style.height = 'auto';
            input.style.height = (input.scrollHeight) + 'px';
        }
    };

    const onError = (err) => {
        delete generatingStates[activeChatChar.name];
        updateSendButton(false);
        if (statusEl) statusEl.style.display = 'none';
        console.error("Impersonation error:", err);
    };

    // We pass the prompt as 'text' to sendToLLM.
    sendToLLM(promptText, activeChatChar, translations, currentLang, () => {}, onComplete, onError, controller, onUpdate, 'impersonation');
}

export async function openChat(char, onBack) {
    if (onBack) _currentOnBack = onBack;
    // Handle Session Switch if sessionId is provided in char object (from dialog list)
    if (char.sessionId) {
        const chats = allChats;
        const data = chats[char.name];
        if (data && data.sessions && data.sessions[char.sessionId]) {
            if (data.currentId !== char.sessionId) {
                data.currentId = char.sessionId;
                chats[char.name] = data;
                await db.set('sc_chats', chats);
            }
        }
    }

    activeChatChar = char;
    const chatView = document.getElementById('view-chat');
    const currentView = document.querySelector('.view.active-view');
    const tabbar = document.querySelector('.tabbar');
    const headerDefault = document.getElementById('header-content-default');
    const headerChatInfo = document.getElementById('header-chat-info');
    const headerActions = document.getElementById('header-actions');
    const backBtn = document.getElementById('header-back');
    const headerLogo = document.getElementById('header-logo');

    // Scroll Handler for Header Hiding
    let lastScrollTop = 0;
    const messagesContainer = document.getElementById('chat-messages');
    const onChatScroll = () => {
        const st = messagesContainer.scrollTop;
        const header = document.querySelector('.app-header');
        if (!header) return;

        // Ignore rubber-banding/overscroll
        if (st < 0) return;
        if (st + messagesContainer.clientHeight > messagesContainer.scrollHeight) return;

        // Добавлен порог (hysteresis) 10px, чтобы избежать дрожания
        if (st > lastScrollTop + 10 && st > 50) {
            header.classList.add('scroll-hidden');
        } else if (st < lastScrollTop - 10) {
            header.classList.remove('scroll-hidden');
        }
        lastScrollTop = st <= 0 ? 0 : st;
    };
    messagesContainer.addEventListener('scroll', onChatScroll, { passive: true });

    // Ensure Editor artifacts are cleaned up
    const btnDeleteChar = document.getElementById('header-btn-delete-char');
    if (btnDeleteChar) btnDeleteChar.style.display = 'none';

    // Restore header title based on active tab (in case we came from Editor)
    const activeTab = document.querySelector('.tab-btn.active');
    const headerTitle = document.getElementById('header-title');
    if (activeTab && headerTitle) {
        const titleKey = activeTab.getAttribute('data-i18n-title');
        if (titleKey && translations[currentLang] && translations[currentLang][titleKey]) {
            headerTitle.textContent = translations[currentLang][titleKey];
            headerTitle.setAttribute('data-i18n', titleKey);
        }
    }

    chatView.classList.remove('anim-fade-out', 'anim-fade-in');

    headerDefault.style.display = 'none';
    headerChatInfo.style.display = 'flex';
    headerActions.style.display = 'flex';
    backBtn.style.display = 'flex';
    tabbar.style.display = 'none';
    if(headerLogo) headerLogo.style.display = 'none';

    updateSendButton(!!generatingStates[char.name]);

    // Clear unread
    let unread = (await db.get('sc_unread')) || {};
    if (unread[char.name]) {
        delete unread[char.name];
        await db.set('sc_unread', unread);
    }

    const chatData = getChatData(char.name);
    const currentSessionId = chatData.currentId;
    document.getElementById('chat-header-name').textContent = char.name.length > 20 ? char.name.substring(0, 20) + '...' : char.name;
    const sessionEl = document.getElementById('chat-header-session');
    if (sessionEl) sessionEl.textContent = `Session #${currentSessionId}`;
    
    const headerAvatarImg = document.getElementById('chat-header-avatar');
    const headerAvatarParent = headerAvatarImg.parentElement;
    let headerPlaceholder = document.getElementById('chat-header-avatar-placeholder');

    if (char.avatar) {
        headerAvatarImg.style.display = 'block';
        headerAvatarImg.src = char.avatar;
        if (headerPlaceholder) headerPlaceholder.style.display = 'none';
    } else {
        headerAvatarImg.style.display = 'none';
        if (!headerPlaceholder) {
            headerPlaceholder = document.createElement('div');
            headerPlaceholder.id = 'chat-header-avatar-placeholder';
            headerPlaceholder.className = 'header-avatar';
            // Copy basic styles from img or set defaults
            headerPlaceholder.style.cssText = "border-radius: 50%; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.2em;";
            headerAvatarParent.insertBefore(headerPlaceholder, headerAvatarImg);
        }
        headerPlaceholder.style.display = 'flex';
        headerPlaceholder.style.backgroundColor = char.color || '#ccc';
        headerPlaceholder.textContent = (char.name[0] || "?").toUpperCase();
    }

    headerChatInfo.onclick = (e) => {
        e.stopPropagation();
        openChatInfoSheet(char);
    };

    headerActions.onclick = (e) => {
        e.stopPropagation();
        openSessionsSheet(char);
    };

    messagesContainer.innerHTML = '';

    const dateDiv = document.createElement('div');
    dateDiv.className = 'chat-date-separator';
    dateDiv.textContent = translations[currentLang]['dialog_started'];
    messagesContainer.appendChild(dateDiv);

    let msgs = chatData.sessions[currentSessionId] || [];

    // First Message Logic
    const greetings = getAllGreetings(char);
    if (msgs.length === 0 && greetings.length > 0) {
        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        
        const firstMsg = {
            role: 'char',
            text: greetings[0],
            time: time,
            genTime: '0s',
            tokens: 0,
            greetingIndex: 0,
            swipes: greetings,
            swipeId: 0,
            timestamp: Date.now()
        };
        // Save immediately
        saveMessageToSession(char.name, firstMsg);
        
        // Refresh msgs reference to ensure render
        const updatedData = getChatData(char.name);
        msgs = updatedData.sessions[currentSessionId] || [];
    }

    msgs.forEach((m, index) => {
        let avatar = null;
        let name = 'User';
        if (m.role === 'char') {
            avatar = char.avatar; // Will be handled by appendMessage fallback
            name = char.name;
        }
        const isFirst = index === 0 && m.role === 'char';
        const canSwitch = isFirst;
        appendMessage(m, avatar, name, m.role === 'char' ? char.version : null, false, false, canSwitch);
    });

    // Check generation state to restore typing indicator (After messages are loaded)
    if (generatingStates[char.name] && generatingStates[char.name].type !== 'impersonation') {
        const charName = char.name;
        
        let avatarHtml = '';
        if (char.avatar) {
            avatarHtml = `<img class="msg-avatar" src="${char.avatar}" alt="">`;
        } else {
            avatarHtml = `<div class="msg-avatar" style="background-color: ${char.color || '#ccc'}; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.2em;">${(charName[0] || "?").toUpperCase()}</div>`;
        }

        const typingSection = document.createElement('div');
        typingSection.className = 'message-section char typing-indicator-placeholder';
        typingSection.innerHTML = `
            <div class="msg-header">
                ${avatarHtml}
                <span class="msg-name">${charName} <sup class="item-version">#${currentSessionId}</sup></span>
            </div>
            <div class="msg-body">
                <div class="typing-container">
                    <svg class="typing-icon" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    <span class="typing-text">${translations[currentLang]['model_typing'] || 'Generating...'}</span>
                </div>
            </div>
        `;
        messagesContainer.appendChild(typingSection);
    }

    if (currentView) currentView.classList.remove('active-view');
    chatView.classList.add('active-view', 'anim-fade-in');
    requestAnimationFrame(() => {
        // If it's a new session (empty or just greeting), scroll to top
        if (msgs.length <= 1) {
            chatView.scrollTop = 0;
        } else {
            chatView.scrollTop = chatView.scrollHeight;
        }
    });

    backBtn.onclick = () => {
        messagesContainer.removeEventListener('scroll', onChatScroll);
        document.querySelector('.app-header').classList.remove('scroll-hidden');
        activeChatChar = null;
        chatView.classList.remove('anim-fade-in');
        chatView.classList.add('anim-fade-out');
        
        if (_currentOnBack) _currentOnBack();

        headerChatInfo.onclick = null;
        headerActions.onclick = null;
        const onAnimationEnd = () => {
            chatView.classList.remove('active-view', 'anim-fade-out');
        };
        chatView.addEventListener('animationend', onAnimationEnd, { once: true });

        headerDefault.style.display = 'flex';
        headerChatInfo.style.display = 'none';
        headerActions.style.display = 'none';
        backBtn.style.display = 'none';
        tabbar.style.display = 'flex';
        if(headerLogo) headerLogo.style.display = 'flex';
    };
}

export async function createNewSession(targetChar, onBack) {
    const char = targetChar || activeChatChar;
    if (char) {
        const charName = char.name;
        let chats = allChats;
        let data = chats[charName];
        
        if (Array.isArray(data) || !data) data = getChatData(charName);

        // Find max session ID
        const ids = Object.keys(data.sessions).map(Number);
        const nextId = (ids.length > 0 ? Math.max(...ids) : 0) + 1;
        
        data.currentId = nextId;
        data.sessions[nextId] = [];
        
        chats[charName] = data;
        await db.set('sc_chats', chats);
        
        const charObj = { ...char };
        delete charObj.sessionId;
        await openChat(charObj, onBack); // Reload chat
    }
}

export async function deleteSession(sessionIdToDelete, targetChar) {
    const char = targetChar || activeChatChar;
    if (char) {
        const charName = char.name;
        let chats = allChats;
        let data = chats[charName];
        
        if (Array.isArray(data) || !data) data = getChatData(charName);

        const targetId = sessionIdToDelete || data.currentId;
        
        delete data.sessions[targetId];
        
        const remainingIds = Object.keys(data.sessions).map(Number).sort((a,b) => a-b);
        if (remainingIds.length > 0) {
            data.currentId = remainingIds[remainingIds.length - 1];
        } else {
            data.currentId = 1;
            data.sessions[1] = [];
        }
        
        chats[charName] = data;
        await db.set('sc_chats', chats);
        
        if (activeChatChar && activeChatChar.name === charName) {
            await openChat(activeChatChar); // Reload chat if active
        }
        refreshDialogs();
    }
}

function switchSession(char, sessionId) {
    let chats = allChats;
    let data = chats[char.name];
    
    if (Array.isArray(data) || !data) data = getChatData(char.name);
    
    if (data.sessions[sessionId]) {
        data.currentId = sessionId;
        chats[char.name] = data;
        db.set('sc_chats', chats);
        
        const charObj = { ...char };
        delete charObj.sessionId;
        openChat(charObj);
    }
}

function openChatInfoSheet(char) {
    showBottomSheet({
        title: char.name,
        items: [
            {
                label: translations[currentLang]['block_char_card'],
                icon: '<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M3 5v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2H5c-1.11 0-2 .9-2 2zm12 4c0 1.66-1.34 3-3 3s-3-1.34-3-3 1.34-3 3-3 3 1.34 3 3zm-9 8c0-2 4-3.1 6-3.1s6 1.1 6 3.1v1H6v-1z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    const savedChars = characters; 
                    const idx = savedChars.findIndex(c => c.name === char.name);
                    if (idx !== -1) {
                        document.getElementById('header-chat-info').style.display = 'none';
                        document.getElementById('header-actions').style.display = 'none';
                        document.getElementById('header-content-default').style.display = 'flex';
                        const headerLogo = document.getElementById('header-logo');
                        if (headerLogo) headerLogo.style.display = 'flex';
                        openCharacterEditor(idx);
                        const backBtn = document.getElementById('header-back');
                        backBtn.onclick = () => {
                            const currentChars = characters;
                            const updatedChar = currentChars[idx];
                            if (updatedChar) openChat(updatedChar);
                            else {
                                document.getElementById('header-back').style.display = 'none';
                                document.getElementById('header-chat-info').style.display = 'none';
                                document.getElementById('header-actions').style.display = 'none';
                                document.getElementById('header-content-default').style.display = 'flex';
                                if (headerLogo) headerLogo.style.display = 'flex';
                                document.querySelector('.tabbar').style.display = 'flex';
                                const btn = document.querySelector('.tab-btn[data-target="view-dialogs"]');
                                if (btn) btn.click();
                            }
                        };
                    }
                }
            },
            {
                label: translations[currentLang]['action_chat_stats'],
                icon: '<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M10 20h4V4h-4v16zm-6 0h4v-8H4v8zM16 9v11h4V9h-4z"/></svg>',
                onClick: () => {
                    openChatStatsSheet(char);
                }
            }
        ]
    });
}

function openChatStatsSheet(char) {
    const data = getChatData(char.name);
    const msgs = data.sessions[data.currentId] || [];
    const count = msgs.length;
    
    let totalTime = 0;
    msgs.forEach(m => {
        if (m.genTime) {
            const t = parseFloat(m.genTime);
            if (!isNaN(t)) totalTime += t;
        }
    });

    showBottomSheet({
        title: translations[currentLang]['action_chat_stats'],
        items: [
            {
                label: `${translations[currentLang]['stat_messages'] || 'Messages'}: ${count}`,
                icon: '<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>'
            },
            {
                label: `${translations[currentLang]['stat_gen_time'] || 'Generation Time'}: ${totalTime.toFixed(1)}s`,
                icon: '<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>'
            }
        ]
    });
}

function openSessionsSheet(char) {
    const listContainer = document.createElement('div');
    
    const data = getChatData(char.name);
    const sessions = data.sessions;
    
    // Sort by ID desc
    const ids = Object.keys(sessions).map(Number).sort((a,b) => {
        // Sort by last message timestamp if available
        const lastA = sessions[a][sessions[a].length-1]?.timestamp || 0;
        const lastB = sessions[b][sessions[b].length-1]?.timestamp || 0;
        return lastB - lastA;
    });
    
    ids.forEach(sid => {
        const msgs = sessions[sid];
        const lastMsg = msgs[msgs.length - 1];
        let preview = 'Empty session';
        let time = '';
        if (lastMsg) {
            preview = lastMsg.text.length > 40 ? lastMsg.text.substring(0, 40) + '...' : lastMsg.text;
            time = lastMsg.time;
        }
        
        const count = msgs.length;
        const isCurrent = sid === data.currentId;
        
        const el = document.createElement('div');
        el.className = 'sheet-item';
        if (isCurrent) el.style.backgroundColor = 'var(--bg-secondary)';
        
        el.innerHTML = `
            <div class="sheet-item-content" style="width: 100%; overflow: hidden;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px;">
                    <div style="display: flex; align-items: center; gap: 8px;">
                        <span style="font-weight: bold;">Session #${sid}</span>
                        <span style="display: flex; align-items: center; font-size: 0.8em; color: var(--text-gray);">
                            <svg viewBox="0 0 24 24" style="width:14px;height:14px;fill:currentColor;margin-right:2px;"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>
                            ${count}
                        </span>
                    </div>
                    <div style="display:flex; align-items:center; gap:5px;">
                        <div style="font-size: 0.8em; color: var(--text-gray); white-space: nowrap;">${time}</div>
                        ${isCurrent ? '<div style="width:6px; height:6px; background-color:var(--vk-blue); border-radius:50%;"></div>' : ''}
                    </div>
                </div>
                <div style="display: flex; justify-content: space-between; align-items: center;">
                    <div style="font-size: 0.8em; opacity: 0.7; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 1; margin-right: 8px;">${preview}</div>
                    <div class="session-delete-btn" style="color: #ff4444; padding: 4px; cursor: pointer; display: flex;">
                        <svg viewBox="0 0 24 24" style="width:18px;height:18px;fill:currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                    </div>
                </div>
            </div>
        `;
        
        el.querySelector('.session-delete-btn').addEventListener('click', (e) => {
            e.stopPropagation();
            openDeleteSessionConfirm(char, sid, true); // true = return to sessions sheet
        });

        el.onclick = () => {
            switchSession(char, sid); 
            closeBottomSheet();
        };
        
        listContainer.appendChild(el);
    });
    
    showBottomSheet({
        title: translations[currentLang]['history_title'],
        content: listContainer,
        headerAction: {
            icon: '+',
            onClick: () => {
                createNewSession();
                closeBottomSheet();
            }
        }
    });
}

function openDeleteSessionConfirm(char, sessionId, returnToSessions = false) {
    // closeBottomSheet(); // Close previous if any
    showBottomSheet({
        title: translations[currentLang]['confirm_delete_session'],
        items: [
            {
                label: translations[currentLang]['btn_yes'],
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    deleteSession(sessionId);
                    closeBottomSheet();
                    if (returnToSessions) setTimeout(() => openSessionsSheet(char), 300);
                }
            },
            {
                label: translations[currentLang]['btn_no'],
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    if (returnToSessions) setTimeout(() => openSessionsSheet(char), 300);
                }
            }
        ]
    });
}

function updateReasoningBlock(element, reasoningText) {
    if (!reasoningText) return;
    let reasoningEl = element.querySelector('.msg-reasoning');
    if (!reasoningEl) {
        // Insert inside body (at the top)
        const body = element.querySelector('.msg-body');
        reasoningEl = document.createElement('div');
        reasoningEl.className = 'msg-reasoning collapsed'; // Default collapsed
        reasoningEl.innerHTML = `<div class="msg-reasoning-header"><span>Reasoning</span><svg class="reasoning-arrow" viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor"><path d="M7 10l5 5 5-5z"/></svg></div><div class="msg-reasoning-content"><div class="msg-reasoning-inner"></div></div>`;
        reasoningEl.querySelector('.msg-reasoning-header').onclick = () => reasoningEl.classList.toggle('collapsed');
        if (body) body.insertBefore(reasoningEl, body.firstChild);
    }
    reasoningEl.querySelector('.msg-reasoning-inner').textContent = reasoningText;
}

function removeWithAnimation(element) {
    if (!element) return;
    // Set explicit height to allow transition from it
    element.style.maxHeight = element.scrollHeight + 'px';
    element.classList.add('deleting');
    
    const onEnd = () => {
        element.remove();
    };
    
    element.addEventListener('animationend', onEnd, { once: true });
    // Fallback in case animation doesn't fire
    setTimeout(onEnd, 350);
}

let activeMessageElement = null;

function appendMessage(msg, forceAvatarUrl, defaultName, version, save = true, autoScroll = true, canSwitch = false) {
    const container = document.getElementById('chat-messages');
    const section = document.createElement('div');
    section.className = `message-section ${msg.role}`;
    if (msg.isError) section.classList.add('error');

    // Ensure swipes structure
    if (!msg.swipes) msg.swipes = [msg.text];
    if (msg.swipeId === undefined) msg.swipeId = 0;
    section._msgData = msg; // Attach data for easy access
    
    // Determine Name and Avatar
    let displayName = defaultName;
    let displayAvatar = forceAvatarUrl;

    if (msg.role === 'user') {
        if (msg.persona) {
            displayName = msg.persona.name || "User";
            displayAvatar = msg.persona.avatar;
        } else {
            // Fallback for old messages
            displayName = "User";
        }
    }

    let metaHtml = '';
    if (msg.role === 'char') {
        const timeIcon = `<svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:4px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>`;
        const showTimer = msg.genTime && msg.genTime !== '0s' && msg.genTime !== '0.0s';
        const displayStyle = showTimer ? 'display:flex;' : 'display:none;';
        metaHtml = `<div class="gen-stat" style="${displayStyle}">${timeIcon} <span class="gen-time">${msg.genTime || '0.0s'}</span></div>`;
    }

    const nameHtml = version ? `${displayName} <sup class="item-version">${version}</sup>` : displayName;
    const timeHtml = `<span class="msg-time"${msg.isError ? ' style="color:white;opacity:0.8;"' : ''}>${msg.time}</span>`;

    // Avatar HTML generation
    let avatarHtml = '';
    if (displayAvatar) {
        avatarHtml = `<img class="msg-avatar" src="${displayAvatar}" alt="">`;
    } else {
        // Letter avatar
        const letter = (displayName && displayName[0]) ? displayName[0].toUpperCase() : "?";
        const color = msg.role === 'char' ? (activeChatChar?.color || '#ccc') : 'var(--vk-blue)';
        avatarHtml = `<div class="msg-avatar" style="background-color: ${color}; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.2em;">${letter}</div>`;
    }

    let textToDisplay = msg.text;
    if (msg.role === 'char' && activeChatChar) {
        const savedPersona = localStorage.getItem('sc_active_persona');
        const persona = savedPersona ? JSON.parse(savedPersona) : { name: "User", avatar: null };
        textToDisplay = replaceMacros(msg.text, activeChatChar, persona);
    }

    let contentHtml = formatText(textToDisplay);
    if (msg.isError) {
        contentHtml = `<span style="color:white">${msg.text}</span>`;
    }

    let reasoningHtml = '';
    // Reasoning block is added dynamically if present

    section.innerHTML = `
        <div class="msg-header">
            ${avatarHtml}
            <span class="msg-name">${nameHtml}</span>
            ${timeHtml}
        </div>
        <div class="msg-body">${contentHtml}</div>
        <div class="msg-footer">${metaHtml}</div>
    `;

    if (msg.reasoning) {
        updateReasoningBlock(section, msg.reasoning);
    }
    
    container.appendChild(section);
    
    if (autoScroll) {
        scrollToBottom('chat-messages', section);
    }

    // Greeting Switcher (First Message)
    if (canSwitch && activeChatChar) {
        const greetings = getAllGreetings(activeChatChar);
        if (greetings.length > 1) {
            renderSwitcher(section, msg, (dir, anim) => changeGreeting(section, msg, dir, anim), greetings.length, (msg.greetingIndex || 0) + 1);
        }
    } 
    // Normal Message Switcher
    else if (msg.role === 'char' && msg.swipes && msg.swipes.length > 1) {
        renderSwitcher(section, msg, (dir, anim) => {
            if (dir === 1 && msg.swipeId >= msg.swipes.length - 1) {
                if (!section.nextElementSibling) regenerateMessage(section, 'new_variant');
            } else {
                changeSwipe(section, msg, dir, anim);
            }
        }, msg.swipes.length, (msg.swipeId || 0) + 1);
    }

    function renderSwitcher(el, m, callback, total, current) {
        let switcher = el.querySelector('.msg-switcher');
        if (!switcher) {
            switcher = document.createElement('div');
            switcher.className = 'msg-switcher';
            switcher.innerHTML = `
                <div class="msg-switcher-btn prev"><svg viewBox="0 0 24 24"><path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg></div>
                <div class="msg-switcher-count"></div>
                <div class="msg-switcher-btn next"><svg viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg></div>
            `;
            el.querySelector('.msg-footer').appendChild(switcher);
        }
        
        switcher.querySelector('.msg-switcher-count').textContent = `${current}/${total}`;
        
        // Clone to remove old listeners
        const prevBtn = switcher.querySelector('.prev');
        const nextBtn = switcher.querySelector('.next');
        
        const newPrev = prevBtn.cloneNode(true);
        const newNext = nextBtn.cloneNode(true);
        
        prevBtn.parentNode.replaceChild(newPrev, prevBtn);
        nextBtn.parentNode.replaceChild(newNext, nextBtn);

        newPrev.onclick = (e) => { e.stopPropagation(); callback(-1, true); };
        newNext.onclick = (e) => { e.stopPropagation(); callback(1, true); };
    }

    // Attach Long Press for Actions
    // REMOVED: Long press caused issues with swipe back
    // const checkLongPress = attachLongPress(section, () => { ... });

    // Add Actions Icon to Footer
    const footer = section.querySelector('.msg-footer');

    const actionsBtn = document.createElement('div');
    actionsBtn.className = 'msg-actions-btn';
    const iconStyle = msg.isError ? 'fill:white;opacity:1;' : 'fill:currentColor;opacity:0.6;';
    actionsBtn.innerHTML = `<svg viewBox="0 0 24 24" style="width:22px;height:22px;${iconStyle}"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>`;
    actionsBtn.onclick = (e) => {
        e.stopPropagation();
        activeMessageElement = section;
        openMessageActions(section, msg);
    };
    footer.appendChild(actionsBtn);

    // Swipe Left Logic (Regenerate) - Only for Char
    if (msg.role === 'char') {
        let startX = 0;
        let startY = 0;
        let isScrolling = false;

        section.addEventListener('touchstart', e => {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
            
            const body = section.querySelector('.msg-body');
            if (body) body.style.transition = 'none';
            isScrolling = false;
        }, {passive: true});
        
        section.addEventListener('touchmove', e => {
            if (isScrolling) return;

            const delta = e.touches[0].clientX - startX;
            const deltaY = e.touches[0].clientY - startY;

            if (Math.abs(deltaY) > Math.abs(delta)) {
                isScrolling = true;
                return;
            }

            if (e.cancelable) e.preventDefault();

            const body = section.querySelector('.msg-body');
            if (body) {
                // Prevent dragging too far if no more swipes
                if (delta < 0 && msg.swipeId >= msg.swipes.length - 1 && section.nextElementSibling) return;
                if (delta > 0 && msg.swipeId <= 0 && !canSwitch) return; // Allow if canSwitch (greetings) or just block
                
                body.style.transform = `translateX(${delta}px)`;
            }
        }, {passive: false});
        
        section.addEventListener('touchend', e => {
            const body = section.querySelector('.msg-body');
            if (isScrolling) {
                if (body) body.style.transform = '';
                return;
            }
            const delta = e.changedTouches[0].clientX - startX;
            // First message: Switch greetings only
            if (canSwitch) {
                if (delta < -100) changeGreeting(section, msg, 1, true);
                else if (delta > 100) changeGreeting(section, msg, -1, true);
                else if (body) {
                    body.style.transition = 'transform 0.3s ease';
                    body.style.transform = '';
                }
                return;
            }

            // Normal message
            if (delta < -100) { // Swipe Left (Next)
                if (msg.swipeId < msg.swipes.length - 1) {
                    changeSwipe(section, msg, 1, true);
                } else {
                    // Last swipe -> Regenerate (New Variant)
                    if (!section.nextElementSibling) {
                        if (body) {
                            body.style.transition = 'transform 0.1s';
                            body.style.transform = `translateX(-20px)`;
                            setTimeout(() => { 
                                body.style.transform = ''; 
                                regenerateMessage(section, 'new_variant');
                            }, 100);
                        } else {
                            regenerateMessage(section, 'new_variant');
                        }
                    } else {
                        if (body) {
                            body.style.transition = 'transform 0.3s ease';
                            body.style.transform = '';
                        }
                    }
                }
            } else if (delta > 100) { // Swipe Right (Prev)
                if (msg.swipeId > 0) {
                    changeSwipe(section, msg, -1, true);
                }
                else if (body) {
                    body.style.transition = 'transform 0.3s ease';
                    body.style.transform = '';
                }
            } else {
                if (body) {
                    body.style.transition = 'transform 0.3s ease';
                    body.style.transform = '';
                }
            }
        });
    }

    if (save && activeChatChar) {
        saveMessageToSession(activeChatChar.name, msg);
    }

    return section;
}

function changeGreeting(element, msg, dir, animate = true) {
    if (!activeChatChar) return;
    const greetings = getAllGreetings(activeChatChar);
    if (greetings.length <= 1) return;

    let currentIndex = msg.greetingIndex !== undefined ? msg.greetingIndex : 0;
    let newIndex = currentIndex + dir;

    if (newIndex >= greetings.length) newIndex = 0;
    if (newIndex < 0) newIndex = greetings.length - 1;

    const rawGreeting = greetings[newIndex];
    
    // Process macros
    const savedPersona = localStorage.getItem('sc_active_persona');
    const persona = savedPersona ? JSON.parse(savedPersona) : { name: "User", avatar: null };
    const processedText = replaceMacros(rawGreeting, activeChatChar, persona);

    msg.text = rawGreeting;
    msg.swipes = [rawGreeting]; // Reset swipes for first message logic if needed, or keep sync
    msg.greetingIndex = newIndex;
    
    const counter = element.querySelector('.msg-switcher-count');
    const updateCounter = () => {
        if (counter) counter.textContent = `${newIndex + 1}/${greetings.length}`;
    };

    if (animate) {
        if (counter) {
            counter.style.transition = 'transform 0.15s ease, opacity 0.15s ease';
            counter.style.transform = `translateX(${dir * -10}px)`;
            counter.style.opacity = '0';
        }
        
        setTimeout(() => {
            updateCounter();
            if (counter) {
                counter.style.transition = 'none';
                counter.style.transform = `translateX(${dir * 10}px)`;
                void counter.offsetWidth; // Trigger reflow
                counter.style.transition = 'transform 0.15s ease, opacity 0.15s ease';
                counter.style.transform = 'translateX(0)';
                counter.style.opacity = '1';
            }
        }, 200);
        animateTextChange(element, processedText, dir);
    } else {
        const body = element.querySelector('.msg-body');
        if (body) body.innerHTML = formatText(processedText);
        updateCounter();
    }

    // Update session (Index 0 is always the first message)
    updateSessionMessage(activeChatChar, 0, msg);
}

function changeSwipe(element, msg, dir, animate = true) {
    if (!msg.swipes || msg.swipes.length <= 1) return;

    let newIndex = msg.swipeId + dir;
    if (newIndex < 0 || newIndex >= msg.swipes.length) return;

    msg.swipeId = newIndex;
    msg.text = msg.swipes[newIndex];

    let textToDisplay = msg.text;
    if (activeChatChar) {
        const savedPersona = localStorage.getItem('sc_active_persona');
        const persona = savedPersona ? JSON.parse(savedPersona) : { name: "User", avatar: null };
        textToDisplay = replaceMacros(msg.text, activeChatChar, persona);
    }

    const statEl = element.querySelector('.gen-stat');
    const counter = element.querySelector('.msg-switcher-count');

    const updateUI = () => {
        if (msg.swipesMeta && msg.swipesMeta[newIndex]) {
            msg.genTime = msg.swipesMeta[newIndex].genTime;
            if (statEl) {
                 const showTimer = msg.genTime && msg.genTime !== '0s' && msg.genTime !== '0.0s';
                 statEl.style.display = showTimer ? 'flex' : 'none';
                 
                 let timeSpan = statEl.querySelector('.gen-time');
                 if (!timeSpan) {
                     const timeIcon = `<svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:4px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>`;
                     statEl.innerHTML = `${timeIcon} <span class="gen-time">${msg.genTime}</span>`;
                 } else {
                     timeSpan.textContent = msg.genTime;
                 }
            }
        }
        if (counter) counter.textContent = `${newIndex + 1}/${msg.swipes.length}`;
    };

    if (animate) {
        const timeSpan = statEl ? statEl.querySelector('.gen-time') : null;
        if (timeSpan) {
            timeSpan.style.transition = 'transform 0.15s ease, opacity 0.15s ease';
            timeSpan.style.transform = `translateX(${dir * -10}px)`;
            timeSpan.style.opacity = '0';
        }
        if (counter) {
            counter.style.transition = 'transform 0.15s ease, opacity 0.15s ease';
            counter.style.transform = `translateX(${dir * -10}px)`;
            counter.style.opacity = '0';
        }
        setTimeout(() => {
            updateUI();
            const newTimeSpan = statEl ? statEl.querySelector('.gen-time') : null;
            if (newTimeSpan) {
                newTimeSpan.style.transition = 'none';
                newTimeSpan.style.transform = `translateX(${dir * 10}px)`;
                void newTimeSpan.offsetWidth;
                newTimeSpan.style.transition = 'transform 0.15s ease, opacity 0.15s ease';
                newTimeSpan.style.transform = 'translateX(0)';
                newTimeSpan.style.opacity = '1';
            }
            if (counter) {
                counter.style.transition = 'none';
                counter.style.transform = `translateX(${dir * 10}px)`;
                void counter.offsetWidth;
                counter.style.transition = 'transform 0.15s ease, opacity 0.15s ease';
                counter.style.transform = 'translateX(0)';
                counter.style.opacity = '1';
            }
        }, 200);
        animateTextChange(element, textToDisplay, dir);
    } else {
        updateUI();
        const body = element.querySelector('.msg-body');
        if (body) body.innerHTML = formatText(textToDisplay);
    }

    // Find index of this message in session to save
    const container = document.getElementById('chat-messages');
    const allMsgs = Array.from(container.querySelectorAll('.message-section'));
    const index = allMsgs.indexOf(element);
    if (index !== -1) {
        updateSessionMessage(activeChatChar, index, msg);
    }
}

function addSwipe(element, msg, newText, meta = {}) {
    if (!msg.swipes) msg.swipes = [];
    if (!msg.swipesMeta) {
        msg.swipesMeta = msg.swipes.map(() => ({ genTime: msg.genTime || '0.0s' }));
    }
    
    msg.swipes.push(newText);
    msg.swipesMeta.push(meta);
    msg.swipeId = msg.swipes.length - 1;
    msg.text = newText;

    // Re-render switcher to show new count
    const switcher = element.querySelector('.msg-switcher');
    if (switcher) switcher.remove(); // Remove old to re-render
    
    // We need to call appendMessage logic's switcher renderer, but we are outside.
    // Manually trigger update or re-render switcher logic.
    // Simplest is to call the logic we extracted or just update the count if we kept the switcher.
    // But since we might have just added the first alt, we might need to create the switcher.
    // Let's just update the session and let the user interact.
    
    // Update UI
    const footer = element.querySelector('.msg-footer');
    let sw = footer.querySelector('.msg-switcher');
    if (!sw) {
        // Create switcher if it didn't exist
        sw = document.createElement('div');
        sw.className = 'msg-switcher';
        sw.innerHTML = `
            <div class="msg-switcher-btn prev"><svg viewBox="0 0 24 24"><path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg></div>
            <div class="msg-switcher-count"></div>
            <div class="msg-switcher-btn next"><svg viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg></div>
        `;
        footer.appendChild(sw);
        sw.querySelector('.prev').onclick = (e) => { e.stopPropagation(); changeSwipe(element, msg, -1, true); };
        sw.querySelector('.next').onclick = (e) => { 
            e.stopPropagation(); 
            if (msg.swipeId >= msg.swipes.length - 1) {
                if (!element.nextElementSibling) regenerateMessage(element, 'new_variant');
            } else {
                changeSwipe(element, msg, 1, true);
            }
        };
    }
    sw.querySelector('.msg-switcher-count').textContent = `${msg.swipeId + 1}/${msg.swipes.length}`;

    // Save
    const container = document.getElementById('chat-messages');
    const allMsgs = Array.from(container.querySelectorAll('.message-section'));
    const index = allMsgs.indexOf(element);
    if (index !== -1) {
        updateSessionMessage(activeChatChar, index, msg);
    }
}

function openMessageActions(element, msgData) {
    const container = document.getElementById('chat-messages');
    const allMsgs = Array.from(container.querySelectorAll('.message-section'));
    const index = allMsgs.indexOf(element);
    
    const items = [
        {
            label: translations[currentLang]['action_copy'],
            icon: '<svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>',
            onClick: () => {
                navigator.clipboard.writeText(msgData.text);
                closeBottomSheet();
            }
        }
    ];

    if (!msgData.isError) {
        items.push({
            label: translations[currentLang]['action_edit'],
            icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                editMessage(element);
            }
        });
        items.push({
            label: translations[currentLang]['action_branch'],
            icon: '<svg viewBox="0 0 24 24"><path d="M6 14l3 3v5h6v-5l3-3V9H6v5zm2-3h8v2.17l-4 4-4-4V11zM12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                branchSession(element);
            }
        });
    }
    
    if (msgData.role === 'char' && index > 0) {
        items.push({
            label: translations[currentLang]['action_regenerate'],
            icon: '<svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>',
            onClick: () => {
                regenerateMessage(element);
                closeBottomSheet();
            }
        });
    }
    
    items.push({
        label: translations[currentLang]['action_delete_msg'],
        icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
        iconColor: '#ff4444',
        isDestructive: true,
        onClick: () => {
            deleteMessage(element);
            closeBottomSheet();
        }
    });

    showBottomSheet({
        title: translations[currentLang]['sheet_title_msg_actions'],
        items: items
    });
}

function editMessage(element) {
    if (element.classList.contains('editing')) return;
    element.classList.add('editing');

    const body = element.querySelector('.msg-body');
    const footer = element.querySelector('.msg-footer');
    const actionsBtn = footer.querySelector('.msg-actions-btn');
    
    if (actionsBtn) actionsBtn.style.display = 'none';

    const rawText = element._msgData ? element._msgData.text : body.innerText;
    body.innerHTML = '';
    
    const textarea = document.createElement('textarea');
    textarea.className = 'edit-textarea';
    textarea.value = rawText;
    textarea.spellcheck = false;
    
    const resize = () => {
        textarea.style.height = 'auto';
        textarea.style.height = textarea.scrollHeight + 'px';
    };
    textarea.addEventListener('input', resize);
    
    body.appendChild(textarea);
    requestAnimationFrame(resize);
    textarea.focus();

    const editButtons = document.createElement('div');
    editButtons.className = 'edit-buttons';
    editButtons.innerHTML = `
        <div class="edit-btn cancel" title="Cancel">
            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
        </div>
        <div class="edit-btn save" title="Save">
            <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
        </div>
    `;
    
    footer.appendChild(editButtons);

    editButtons.querySelector('.cancel').onclick = (e) => {
        e.stopPropagation();
        cancelEdit(element);
    };
    editButtons.querySelector('.save').onclick = (e) => {
        e.stopPropagation();
        saveEdit(element, textarea.value);
    };
}

function cancelEdit(element) {
    if (!element.classList.contains('editing')) return;
    
    const textarea = element.querySelector('.edit-textarea');
    const editButtons = element.querySelector('.edit-buttons');

    if (textarea) textarea.classList.add('anim-exit');
    if (editButtons) editButtons.classList.add('anim-exit');

    setTimeout(() => {
        element.classList.remove('editing');
        
        const body = element.querySelector('.msg-body');
        const footer = element.querySelector('.msg-footer');
        const actionsBtn = footer.querySelector('.msg-actions-btn');
        const btns = footer.querySelector('.edit-buttons');

        const rawText = element._msgData ? element._msgData.text : "";
        
        let textToDisplay = rawText;
        if (element._msgData && element._msgData.role === 'char' && activeChatChar) {
            const savedPersona = localStorage.getItem('sc_active_persona');
            const persona = savedPersona ? JSON.parse(savedPersona) : { name: "User", avatar: null };
            textToDisplay = replaceMacros(rawText, activeChatChar, persona);
        }

        body.innerHTML = formatText(textToDisplay);

        if (actionsBtn) actionsBtn.style.display = 'flex';
        if (btns) btns.remove();
    }, 200);
}

function saveEdit(element, newText) {
    if (!element.classList.contains('editing')) return;
    
    const textarea = element.querySelector('.edit-textarea');
    const editButtons = element.querySelector('.edit-buttons');

    if (textarea) textarea.classList.add('anim-exit');
    if (editButtons) editButtons.classList.add('anim-exit');

    setTimeout(() => {
        element.classList.remove('editing');
        
        const body = element.querySelector('.msg-body');
        const footer = element.querySelector('.msg-footer');
        const actionsBtn = footer.querySelector('.msg-actions-btn');
        const btns = footer.querySelector('.edit-buttons');

        // Update Data
        if (element._msgData) {
            element._msgData.text = newText;
            if (element._msgData.swipes) {
                element._msgData.swipes[element._msgData.swipeId] = newText;
            }
        }

        let textToDisplay = newText;
        if (element._msgData && element._msgData.role === 'char' && activeChatChar) {
            const savedPersona = localStorage.getItem('sc_active_persona');
            const persona = savedPersona ? JSON.parse(savedPersona) : { name: "User", avatar: null };
            textToDisplay = replaceMacros(newText, activeChatChar, persona);
        }

        body.innerHTML = formatText(textToDisplay);

        if (actionsBtn) actionsBtn.style.display = 'flex';
        if (btns) btns.remove();

        // Save to DB
        const container = document.getElementById('chat-messages');
        const allMsgs = Array.from(container.querySelectorAll('.message-section'));
        const index = allMsgs.indexOf(element);
        
        if (index !== -1 && activeChatChar) {
            updateSessionMessage(activeChatChar, index, element._msgData);
        }
    }, 200);
}

function branchSession(element) {
    const container = document.getElementById('chat-messages');
    const allMsgs = Array.from(container.querySelectorAll('.message-section'));
    const index = allMsgs.indexOf(element);
    
    if (index !== -1 && activeChatChar) {
        let chats = allChats;
        let data = chats[activeChatChar.name];
        
        if (data && data.sessions[data.currentId]) {
            const currentMsgs = data.sessions[data.currentId];
            // Slice up to this message (inclusive)
            const newHistory = currentMsgs.slice(0, index + 1);
            
            // Create new session
            createNewSession(); 
            // createNewSession reloads chat, so we need to overwrite the new empty session
            // But createNewSession is async in terms of UI reload? No, it's sync.
            // We need to get the data again after createNewSession
            chats = allChats;
            data = chats[activeChatChar.name];
            data.sessions[data.currentId] = newHistory;
            chats[activeChatChar.name] = data;
            db.set('sc_chats', chats);
            
            // Reload UI
            const charObj = { ...activeChatChar };
            delete charObj.sessionId;
            openChat(charObj);
        }
    }
}

function deleteMessage(element) {
    const container = document.getElementById('chat-messages');
    // Exclude already deleting messages to keep index in sync with storage
    const allMsgs = Array.from(container.querySelectorAll('.message-section:not(.deleting)'));
    const index = allMsgs.indexOf(element);
    
    if (index === -1) return;

    // Remove from DOM
    removeWithAnimation(element);

    // Update Storage
    if (activeChatChar) {
        let chats = allChats;
        let data = chats[activeChatChar.name];
        if (Array.isArray(data)) data = getChatData(activeChatChar.name);

        if (data && data.sessions[data.currentId]) {
            data.sessions[data.currentId].splice(index, 1);
            chats[activeChatChar.name] = data;
            db.set('sc_chats', chats);
        }
    }
}

function regenerateMessage(element, mode = 'normal') {
    const container = document.getElementById('chat-messages');
    const allMsgs = Array.from(container.querySelectorAll('.message-section'));
    const index = allMsgs.indexOf(element);
    
    if (index === -1) return;

    const isUser = element.classList.contains('user');
    const isMagic = mode === 'magic';

    // If Magic Menu and last message is User -> Don't delete, just generate
    if (isMagic && isUser) {
        if (activeChatChar) {
            // We pass null text to imply "continue/regenerate" based on history, 
            // or we could pass the user text if the API requires it. 
            // Assuming sendToLLM(null...) handles context building from history.
            startGeneration(activeChatChar, null);
        }
        return;
    }

    // New Variant Logic (Swipe at end)
    if (mode === 'new_variant' && !isUser) {
        // Prepare UI for generation inside existing element
        const body = element.querySelector('.msg-body');
        body.style.opacity = '0';
        
        setTimeout(() => {
            body.innerHTML = `
                <div class="typing-container">
                    <svg class="typing-icon" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    <span class="typing-text">${translations[currentLang]['model_typing'] || 'Generating...'}</span>
                </div>
            `;
            body.style.opacity = '1';
            
            // Mark for API to ignore this message's content in history
            element.classList.add('generating-swipe');
            
            const switcher = element.querySelector('.msg-switcher');
            if (switcher) switcher.remove();
            
            startGeneration(activeChatChar, null, element);
        }, 200);
        return;
    }

    // If Magic Menu and last message is Char -> Swipe animation then delete & regen
    if (isMagic && !isUser) {
        element.style.transition = 'transform 0.3s ease, opacity 0.3s ease';
        element.style.transform = 'translateX(-100%)';
        element.style.opacity = '0';
        
        setTimeout(() => {
            performDeleteAndRegen();
        }, 300);
        return;
    }

    // Default behavior (context menu) or after animation
    performDeleteAndRegen(); // This is the "Delete and Regenerate" action

    function performDeleteAndRegen() {
        // Capture data for restoration
        const deletedData = [];
        for (let i = index; i < allMsgs.length; i++) {
             if (allMsgs[i]._msgData) {
                 deletedData.push(allMsgs[i]._msgData);
             }
        }

        // Remove this message and all subsequent messages from DOM
        for (let i = allMsgs.length - 1; i >= index; i--) {
            if (allMsgs[i] === element && (isMagic || element.style.transform.includes('translateX(-100%)'))) {
                allMsgs[i].remove();
            } else {
                removeWithAnimation(allMsgs[i]);
            }
        }

        // Update Storage (Remove this and subsequent)
        if (activeChatChar) {
            let chats = allChats;
            let data = chats[activeChatChar.name];
            if (Array.isArray(data)) data = getChatData(activeChatChar.name);

            if (data && data.sessions[data.currentId]) {
                data.sessions[data.currentId].splice(index);
                chats[activeChatChar.name] = data;
                db.set('sc_chats', chats);
            }
            
            // Define Restore Callback
            const onAbort = async () => {
                let chatsRestored = allChats;
                let dataRestored = chatsRestored[activeChatChar.name];
                
                if (dataRestored && dataRestored.sessions[dataRestored.currentId]) {
                    dataRestored.sessions[dataRestored.currentId].splice(index, 0, ...deletedData);
                    chatsRestored[activeChatChar.name] = dataRestored;
                    await db.set('sc_chats', chatsRestored);
                }

                deletedData.forEach(msg => {
                    appendMessage(msg, activeChatChar.avatar, activeChatChar.name, activeChatChar.version, false, true);
                });
            };

            // Trigger Generation
            startGeneration(activeChatChar, null, null, onAbort);
        }
    }
}