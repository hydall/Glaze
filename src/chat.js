import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { sendToLLM } from './llmApi.js';
import { attachLongPress, openBottomSheet, closeBottomSheet, scrollToBottom } from './ui.js';
import { formatText, replaceMacros } from './textFormatter.js';
import { renderDialogs } from './dialogList.js';
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

export function initChat() {
    const chatInput = document.getElementById('chat-input');
    if (chatInput) {
        chatInput.addEventListener('input', function() {
            this.style.height = 'auto';
            this.style.height = (this.scrollHeight) + 'px';
        });
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
        if (activeChatChar && generatingStates[activeChatChar.name]) return;

        const container = document.getElementById('chat-messages');
        const lastMsg = container.lastElementChild;
        const allMsgs = Array.from(container.querySelectorAll('.message-section'));
        if (lastMsg && allMsgs.indexOf(lastMsg) > 0) {
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

    // Init Session Actions
    const btnNewSession = document.getElementById('btn-chat-new-session');
    const btnDeleteSession = document.getElementById('btn-chat-delete');

    if (btnNewSession) btnNewSession.addEventListener('click', () => {
        createNewSession();
        closeBottomSheet('chat-actions-sheet-overlay');
    });

    if (btnDeleteSession) btnDeleteSession.addEventListener('click', () => {
        deleteSession();
        closeBottomSheet('chat-actions-sheet-overlay');
    });
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
            startGeneration(activeChatChar, processedText);
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

    if (activeChatChar && activeChatChar.name === charName) {
        updateSendButton(false);
        
        if (error) {
            const now = new Date();
            const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
            const msg = {
                role: 'char',
                text: `Error: ${error.message}`,
                time: time,
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
                statEl.innerHTML = `${timeIcon} ${elapsed}`;
            }, 100);
        }
    };

    generatingStates[char.name] = { genId, controller };

    if (activeChatChar && activeChatChar.name === char.name) {
        updateSendButton(true);
    }
    
    if (existingElement) startTimer(existingElement);

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
    
    let streamingMsgElement = existingElement; // Use existing if provided
    let fullText = text || ""; // If text provided (e.g. impersonation), start with it
    let fullReasoning = "";
    let displayedText = "";
    let typewriterRaf = null;
    const view = document.getElementById('view-chat');

    const processTypewriter = () => {
        if (displayedText.length < fullText.length) {
            const pending = fullText.length - displayedText.length;
            const step = Math.max(1, Math.ceil(pending / 3));
            displayedText = fullText.substring(0, displayedText.length + step);
            
            const body = streamingMsgElement.querySelector('.msg-body');
            const dots = '<span class="typing-dots-bounce"><span>.</span><span>.</span><span>.</span></span>';
            if (body) body.innerHTML = formatText(displayedText) + dots;

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
        if (!streamingMsgElement) {
            // Create message shell on first chunk
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
            startTimer(streamingMsgElement);
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

    const type = existingElement ? 'no_typing' : 'normal';
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
                     statEl.innerHTML = `${timeIcon} ${duration}`;
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
                    if (dist < threshold) scrollToBottom('view-chat', streamingMsgElement);
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

    const messagesContainer = document.getElementById('chat-messages');
    messagesContainer.innerHTML = '';

    const dateDiv = document.createElement('div');
    dateDiv.className = 'chat-date-separator';
    dateDiv.textContent = translations[currentLang]['dialog_started'];
    messagesContainer.appendChild(dateDiv);

    let msgs = chatData.sessions[currentSessionId] || [];

    // First Message Logic
    if (msgs.length === 0 && char.first_mes) {
        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        
        const firstMsg = {
            role: 'char',
            text: char.first_mes,
            time: time,
            genTime: '0s',
            tokens: 0,
            greetingIndex: 0,
            swipes: [char.first_mes],
            swipeId: 0,
            timestamp: Date.now()
        };
        // Save immediately
        saveMessageToSession(char.name, firstMsg);
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
    const sheetId = 'chat-info-sheet-overlay';
    
    const btnCard = document.getElementById('btn-chat-info-card');
    const btnStats = document.getElementById('btn-chat-info-stats');

    if (btnCard) {
        btnCard.onclick = () => {
            closeBottomSheet(sheetId);
            // We can use the exported characters array from characterList since it's kept in sync
            const savedChars = characters; 
            const idx = savedChars.findIndex(c => c.name === char.name);
            
            if (idx !== -1) {
                // Fix UI state: Hide Chat Header, Show Default Header
                document.getElementById('header-chat-info').style.display = 'none';
                document.getElementById('header-actions').style.display = 'none';
                document.getElementById('header-content-default').style.display = 'flex';
                const headerLogo = document.getElementById('header-logo');
                if (headerLogo) headerLogo.style.display = 'flex';

                openCharacterEditor(idx);

                // Override Back Button to return to Chat
                const backBtn = document.getElementById('header-back');
                backBtn.onclick = () => {
                    const currentChars = characters;
                    const updatedChar = currentChars[idx];
                    if (updatedChar) openChat(updatedChar);
                    else {
                        // Restore UI state if character deleted
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
        };
    }

    if (btnStats) {
        btnStats.onclick = () => {
            alert(`Messages: ${getChatData(char.name).sessions[getChatData(char.name).currentId]?.length || 0}`);
            closeBottomSheet(sheetId);
        };
    }
    openBottomSheet(sheetId);
}

function openSessionsSheet(char) {
    const list = document.getElementById('sessions-list');
    list.innerHTML = '';
    
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
            openDeleteSessionConfirm(char, sid);
        });

        el.onclick = () => {
            switchSession(char, sid);
            closeBottomSheet('sessions-sheet-overlay');
        };
        
        list.appendChild(el);
    });
    
    const btnNew = document.getElementById('btn-new-session-main');
    const newBtn = btnNew.cloneNode(true);
    btnNew.parentNode.replaceChild(newBtn, btnNew);
    
    newBtn.onclick = () => {
        createNewSession();
        closeBottomSheet('sessions-sheet-overlay');
    };

    openBottomSheet('sessions-sheet-overlay');
}

function openDeleteSessionConfirm(char, sessionId) {
    closeBottomSheet('sessions-sheet-overlay');
    const sheetId = 'session-delete-confirm-sheet';
    // Assuming this sheet exists in HTML or created in script.js
    const sheet = document.getElementById(sheetId);
    if (sheet) {
        const btnYes = document.getElementById('btn-confirm-delete-session');
        const btnNo = document.getElementById('btn-cancel-delete-session');
        
        // Clone to remove old listeners
        const newYes = btnYes.cloneNode(true);
        btnYes.parentNode.replaceChild(newYes, btnYes);
        
        newYes.onclick = () => {
            deleteSession(sessionId);
            closeBottomSheet(sheetId);
        };
        
        btnNo.onclick = () => closeBottomSheet(sheetId);
        openBottomSheet(sheetId);
    }
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
        metaHtml = `<div class="gen-stat" style="${displayStyle}align-items:center;opacity:0.7;">${timeIcon} ${msg.genTime || '0.0s'}</div>`;
    }

    const nameHtml = version ? `${displayName} <sup class="item-version">${version}</sup>` : displayName;
    const timeHtml = `<span class="msg-time">${msg.time}</span>`;

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
        contentHtml = `<span style="color:red">${msg.text}</span>`;
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
        scrollToBottom('view-chat', section);
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
    const checkLongPress = attachLongPress(section, () => {
        activeMessageElement = section;
        openMessageActions(section, msg);
    });

    // Swipe Left Logic (Regenerate) - Only for Char
    if (msg.role === 'char') {
        let startX = 0;
        let startY = 0;
        let isScrolling = false;

        section.addEventListener('touchstart', e => {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
            section.style.transition = 'none';
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

            if (delta < 0) {
                if (msg.swipeId >= msg.swipes.length - 1 && section.nextElementSibling) return;
                section.style.transform = `translateX(${delta}px)`;
            }
        }, {passive: false});
        
        section.addEventListener('touchend', e => {
            if (isScrolling) {
                section.style.transform = '';
                return;
            }
            const delta = e.changedTouches[0].clientX - startX;
            section.style.transition = 'transform 0.3s ease';
            // First message: Switch greetings only
            if (canSwitch) {
                if (delta < -100) changeGreeting(section, msg, 1, true);
                else if (delta > 100) changeGreeting(section, msg, -1, true);
                section.style.transform = '';
                return;
            }

            // Normal message
            if (delta < -100) { // Swipe Left (Next)
                if (msg.swipeId < msg.swipes.length - 1) {
                    changeSwipe(section, msg, 1, true);
                    section.style.transform = '';
                } else {
                    // Last swipe -> Regenerate (New Variant)
                    if (!section.nextElementSibling) {
                        section.style.transform = `translateX(-20px)`; // Small bounce hint
                        setTimeout(() => { section.style.transform = ''; }, 100);
                        regenerateMessage(section, 'new_variant');
                    } else {
                        section.style.transform = '';
                    }
                }
            } else if (delta > 100) { // Swipe Right (Prev)
                if (msg.swipeId > 0) {
                    changeSwipe(section, msg, -1, true);
                }
                section.style.transform = '';
            } else {
                section.style.transform = 'translateX(0)';
                setTimeout(() => {
                    section.style.transform = '';
                    section.style.transition = '';
                }, 300);
            }
        });
    }

    if (save && activeChatChar) {
        saveMessageToSession(activeChatChar.name, msg);
    }

    return section;
}

function animateTextChange(element, newText, onUpdate) {
    const body = element.querySelector('.msg-body');
    body.style.opacity = '0';
    
    setTimeout(() => {
        if (onUpdate) onUpdate();
        else body.innerHTML = formatText(newText);
        
        body.style.opacity = '1';
    }, 200);
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

    if (animate) {
        animateTextChange(element, processedText);
    } else {
        const body = element.querySelector('.msg-body');
        if (body) body.innerHTML = formatText(processedText);
    }

    const counter = element.querySelector('.msg-switcher-count');
    if (counter) counter.textContent = `${newIndex + 1}/${greetings.length}`;

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

    if (msg.swipesMeta && msg.swipesMeta[newIndex]) {
        msg.genTime = msg.swipesMeta[newIndex].genTime;
        const statEl = element.querySelector('.gen-stat');
        if (statEl) {
             const timeIcon = `<svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:4px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>`;
             statEl.innerHTML = `${timeIcon} ${msg.genTime}`;
             const showTimer = msg.genTime && msg.genTime !== '0s' && msg.genTime !== '0.0s';
             statEl.style.display = showTimer ? 'flex' : 'none';
        }
    }

    if (animate) {
        animateTextChange(element, textToDisplay);
    } else {
        const body = element.querySelector('.msg-body');
        if (body) body.innerHTML = formatText(textToDisplay);
    }

    const counter = element.querySelector('.msg-switcher-count');
    if (counter) counter.textContent = `${newIndex + 1}/${msg.swipes.length}`;

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
    const sheetId = 'msg-actions-sheet-overlay';
    
    // Setup handlers
    document.getElementById('btn-msg-copy').onclick = () => {
        navigator.clipboard.writeText(msgData.text);
        closeBottomSheet(sheetId);
    };

    document.getElementById('btn-msg-edit').onclick = () => {
        closeBottomSheet(sheetId);
        editMessage(element);
    };

    document.getElementById('btn-msg-branch').onclick = () => {
        closeBottomSheet(sheetId);
        branchSession(element);
    };

    const btnRegen = document.getElementById('btn-msg-regenerate');
    
    const container = document.getElementById('chat-messages');
    const allMsgs = Array.from(container.querySelectorAll('.message-section'));
    const index = allMsgs.indexOf(element);

    if (msgData.role === 'char' && index > 0) {
        btnRegen.style.display = 'flex';
        btnRegen.onclick = () => {
            regenerateMessage(element);
            closeBottomSheet(sheetId);
        };
    } else {
        btnRegen.style.display = 'none';
    }

    document.getElementById('btn-msg-delete').onclick = () => {
        deleteMessage(element);
        closeBottomSheet(sheetId);
    };

    openBottomSheet(sheetId);
}

function editMessage(element) {
    const body = element.querySelector('.msg-body');
    const originalText = body.innerText; // Simple text extraction
    
    const newText = prompt("Edit message:", originalText);
    if (newText !== null && newText !== originalText) {
        // Update DOM
        body.innerHTML = formatText(newText);
        
        // Update Storage
        const container = document.getElementById('chat-messages');
        const allMsgs = Array.from(container.querySelectorAll('.message-section'));
        const index = allMsgs.indexOf(element);
        
        if (index !== -1 && activeChatChar) {
            let chats = allChats;
            let data = chats[activeChatChar.name];
            if (data && data.sessions[data.currentId]) {
                data.sessions[data.currentId][index].text = newText;
                chats[activeChatChar.name] = data;
                db.set('sc_chats', chats);
            }
        }
    }
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