import { formatText, replaceMacros, cleanText, formatInputPreview } from './textFormatter.js';
import { formatDate } from './dateFormatter.js';
import { currentLang, imageViewerMode, setImageViewerMode } from './APPSettings.js';
import { translations } from './i18n.js';
import { sendToLLM } from './llmApi.js';
import { attachLongPress, scrollToBottom, animateTextChange, updateAppColors, rgbToHex } from './ui.js';
import { showBottomSheet, closeBottomSheet, showBigInfoSheet } from './bottomsheet.js';
import { openImageViewer } from './imageViewer.js';
import { renderDialogs, refreshDialogs } from './dialogList.js';
import { openCharacterEditor } from './editor.js';
import { db } from './db.js';
import { characters } from './characterList.js';
import { StatusBar, Style } from '@capacitor/status-bar';
import { NavigationBar } from '@hugotomazi/capacitor-navigation-bar';
import { setupChatHeader, updateHeaderAvatar, resetHeader, initHeaderScroll } from './header.js';

let activeChatChar = null;
let _currentOnBack = null;
let _cleanupScroll = null;
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

function closeChat() {
    const chatView = document.getElementById('view-chat');
    const messagesContainer = document.getElementById('chat-messages');

    // Revert System Colors
    updateAppColors(true);

    if (activeChatChar) {
        const data = getChatData(activeChatChar.name);
        data.lastScrollPosition = messagesContainer.scrollTop;
        db.set('sc_chats', allChats);
    }
    
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }
    
    resetHeader();
    
    activeChatChar = null;
    chatView.classList.remove('anim-fade-in');
    chatView.classList.add('anim-fade-out');
    
    if (_currentOnBack) _currentOnBack();

    const onAnimationEnd = () => {
        chatView.classList.remove('active-view', 'anim-fade-out');
    };
    chatView.addEventListener('animationend', onAnimationEnd, { once: true });
}

export function initChat() {
    const chatInput = document.getElementById('chat-input');
    if (chatInput) {
        // Fix for Android Keyboard: ensure text input mode (prevents number row stuck)
        // chatInput.setAttribute('inputmode', 'text');

        chatInput.addEventListener('input', function() {
            this.style.height = 'auto';
            // Fix for Android height glitch: add buffer for borders/sub-pixel rendering
            this.style.height = (this.scrollHeight + 2) + 'px';
        });
        // Fix for double-tap issue on mobile (prevents parent handlers from stealing focus)
        chatInput.addEventListener('touchstart', (e) => {
            e.stopPropagation();
        }, { passive: true });

        // Markdown Preview Logic
        const highlight = document.getElementById('chat-input-highlight');
        if (highlight) {
            const updateHighlight = () => {
                highlight.innerHTML = formatInputPreview(chatInput.value);
            };
            
            // Sync styles
            setTimeout(() => {
                const style = window.getComputedStyle(chatInput);
                highlight.style.fontFamily = style.fontFamily;
                highlight.style.fontSize = style.fontSize;
                highlight.style.lineHeight = style.lineHeight;
                highlight.style.padding = style.padding;
                highlight.style.boxSizing = style.boxSizing;
                highlight.style.border = style.border;
                updateHighlight();
            }, 100);

            chatInput.addEventListener('input', updateHighlight);
            chatInput.addEventListener('scroll', () => {
                highlight.scrollTop = chatInput.scrollTop;
            });
            // Also update on value set programmatically if needed, but input covers typing
        }
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
        
        // Prevent regeneration if editing
        const editingEl = document.querySelector('.message-section.editing');
        if (editingEl) return;

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

    const scrollBtn = document.getElementById('scroll-to-bottom');
    if (scrollBtn) {
        scrollBtn.addEventListener('click', () => {
            scrollToBottom('chat-messages');
        });
    }

    // Inject Author's Notes button into Magic Menu
    const magicMenu = document.getElementById('magic-menu');
    if (magicMenu && !document.getElementById('btn-authors-notes')) {
        const btn = document.createElement('div');
        btn.id = 'btn-authors-notes';
        btn.className = 'magic-item'; // Assuming magic-item class exists or inherits styles
        btn.innerHTML = `<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor;margin-right:12px;"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg><span>${translations[currentLang]['magic_authors_notes'] || "Author's Notes"}</span>`;
        magicMenu.appendChild(btn);
        
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            magicMenu.classList.add('hidden');
            openAuthorsNotesEditor();
        });
    }

    // Init Holocards Toggle Listener (if element exists in DOM)
    const holoToggle = document.getElementById('holocards-toggle');
    if (holoToggle) {
        holoToggle.checked = imageViewerMode === 'holocards';
        holoToggle.addEventListener('change', (e) => {
            setImageViewerMode(e.target.checked ? 'holocards' : 'default');
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
        
        // Clear highlight
        const highlight = document.getElementById('chat-input-highlight');
        if (highlight) highlight.innerHTML = '';

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
        updateHeaderAvatar(activeChatChar);
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
                timestamp: Date.now(),
                isError: true
            };
            appendMessage(msg, activeChatChar.avatar, activeChatChar.name, null, false);
        }
    }
    renderDialogs();
}

// Update startGeneration to accept existing element
function startGeneration(char, text, existingElement = null, onAbort = null) {
    // Check API Configuration before creating any message
    const model = localStorage.getItem('api-model');
    const endpoint = localStorage.getItem('sc_api_endpoint_normalized') || localStorage.getItem('api-endpoint');
    
    if (!model || !endpoint) {
        showBigInfoSheet({
            title: translations[currentLang]['section_connection'] || "Connection",
            icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
            description: translations[currentLang]['api_not_configured'] || "API Not Configured",
            buttonText: translations[currentLang]['btn_configure'] || "Configure",
            onButtonClick: () => {
                closeBottomSheet();
                const tab = document.querySelector('.tab-btn[data-target="view-generation"]');
                if (tab) tab.click();
            }
        });
        return;
    }

    const genId = ++genIdCounter;
    const controller = new AbortController();
    const startTime = Date.now();
    let rawStreamText = text || "";
    let lastSaveTime = 0; // Таймер для автосохранения
    
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
    
    if (existingElement) {
        existingElement.classList.remove('error');
        startTimer(existingElement);
        // Hide actions during generation
        const actions = existingElement.querySelector('.msg-actions-btn');
        if (actions) actions.style.display = 'none';
        updateReasoningBlock(existingElement, null);
    }

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
        // CHANGE: save=true (сразу сохраняем в БД, чтобы не потерять при выгрузке)
        streamingMsgElement = appendMessage(msg, char.avatar, char.name, char.version, true, true);
        // Hide actions during generation
        const actions = streamingMsgElement.querySelector('.msg-actions-btn');
        if (actions) actions.style.display = 'none';
        
        const body = streamingMsgElement.querySelector('.msg-body');
        if (body) {
            body.innerHTML = '';
            const tpl = document.getElementById('tpl-typing-indicator');
            const clone = tpl.content.cloneNode(true);
            clone.querySelector('.typing-text').textContent = translations[currentLang]['model_typing'] || 'Generating...';
            body.appendChild(clone);
        }
        
        startTimer(streamingMsgElement);
    }

    const restoreState = (isError = false) => {
        if (timerInterval) clearInterval(timerInterval);
        if (existingElement) existingElement.classList.remove('generating-swipe');
        // Show actions
        const actions = existingElement ? existingElement.querySelector('.msg-actions-btn') : null;
        if (actions) actions.style.display = 'flex';
        
        // Restore content if it was a swipe generation
        if (existingElement && existingElement._msgData) {
            const msg = existingElement._msgData;
            const body = existingElement.querySelector('.msg-body');
            if (body) body.innerHTML = formatText(msg.text);
            
            if (msg.swipes && msg.swipes.length > 1) {
                const footer = existingElement.querySelector('.msg-footer');
                let sw = footer.querySelector('.msg-switcher');
                if (!sw) {
                    const tpl = document.getElementById('tpl-msg-switcher');
                    sw = tpl.content.firstElementChild.cloneNode(true);
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

        if (onAbort) onAbort(isError);
    };

    generatingStates[char.name] = { genId, controller, restoreState };

    const onError = (e) => {
        restoreState(true);
        delete generatingStates[char.name];
        
        if (existingElement) {
            const errorText = `Error: ${e.message}`;
            const body = existingElement.querySelector('.msg-body');
            
            if (rawStreamText && rawStreamText.length > 0) {
                const typing = body ? body.querySelector('.typing-container') : null;
                if (typing) typing.remove();

                const errorHtml = `<div class="msg-error-footer" style="border-top: 1px solid var(--separator-color); margin-top: 8px; padding-top: 8px; color: #ff6b6b;">${errorText}</div>`;
                const fullText = rawStreamText + errorHtml;
                
                if (body) body.innerHTML = formatText(fullText);
                
                if (existingElement._msgData) {
                    existingElement._msgData.text = fullText;
                    if (existingElement._msgData.swipes) {
                        existingElement._msgData.swipes[existingElement._msgData.swipeId] = fullText;
                    }
                    existingElement._msgData.isError = true;
                    
                    const container = document.getElementById('chat-messages');
                    const allMsgs = Array.from(container.querySelectorAll('.message-section'));
                    const index = allMsgs.indexOf(existingElement);
                    if (index !== -1) {
                        updateSessionMessage(char, index, existingElement._msgData);
                    }
                }
            } else {
                if (body) body.innerHTML = formatText(errorText);
                if (existingElement._msgData) {
                    addSwipe(existingElement, existingElement._msgData, errorText, { genTime: '0.0s', isError: true });
                }
            }
            existingElement.classList.add('error');
            
            if (activeChatChar && activeChatChar.name === char.name) {
                updateSendButton(false);
            }
        } else {
            handleGenerationError(char.name, e);
        }
    };
    
    // Fetch preset settings asynchronously before starting generation
    db.get('sc_prompt_presets').then(presets => {
        presets = presets || [];
        const activePresetId = localStorage.getItem('sc_active_preset_id');
        const activePreset = presets.find(p => p.id === activePresetId) || presets[0];
        
        // Use preset tags, fallback to legacy localStorage if needed (or empty)
        const tagStart = activePreset?.reasoningStart || localStorage.getItem('sc_api_reasoning_start');
        const tagEnd = activePreset?.reasoningEnd || localStorage.getItem('sc_api_reasoning_end');
        const allowNativeReasoning = localStorage.getItem('sc_api_request_reasoning') === 'true';

        let fullText = text || ""; // Clean text for typewriter
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
            
            rawStreamText += chunk || "";
            if (reasoningChunk && allowNativeReasoning) fullReasoning += reasoningChunk;

            // ... (existing CoT logic) ...
            
            let effectiveReasoning = allowNativeReasoning ? fullReasoning : "";
            let effectiveText = rawStreamText;

            if (tagStart && tagEnd && rawStreamText.includes(tagStart)) {
                const startIndex = rawStreamText.indexOf(tagStart);
                const endIndex = rawStreamText.indexOf(tagEnd, startIndex);
                
                if (endIndex !== -1) {
                    effectiveReasoning = rawStreamText.substring(startIndex + tagStart.length, endIndex);
                    effectiveText = rawStreamText.substring(0, startIndex) + rawStreamText.substring(endIndex + tagEnd.length);
                } else {
                    effectiveReasoning = rawStreamText.substring(startIndex + tagStart.length);
                    effectiveText = rawStreamText.substring(0, startIndex);
                }
            }

            updateReasoningBlock(streamingMsgElement, effectiveReasoning);
            fullText = effectiveText; // Update global text for typewriter
            
            // CHANGE: Периодическое сохранение в БД (каждые 2 сек)
            // Это спасет текст, если приложение будет убито системой в фоне
            const now = Date.now();
            if (now - lastSaveTime > 2000 && streamingMsgElement && streamingMsgElement._msgData) {
                lastSaveTime = now;
                streamingMsgElement._msgData.text = fullText;
                if (allowNativeReasoning) streamingMsgElement._msgData.reasoning = effectiveReasoning;
                
                const container = document.getElementById('chat-messages');
                const allMsgs = Array.from(container.querySelectorAll('.message-section'));
                const index = allMsgs.indexOf(streamingMsgElement);
                if (index !== -1) updateSessionMessage(char, index, streamingMsgElement._msgData);
            }

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
            
            response = cleanText(response);
            
            const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
            const duration = ((Date.now() - startTime) / 1000).toFixed(2) + 's';
            
            const nativeReasoning = allowNativeReasoning ? (fullReasoning || finalReasoning) : "";
            
            const msg = {
                role: 'char',
                text: response,
                time: time,
                genTime: duration,
                timestamp: Date.now(),
                tokens: response.length,
                reasoning: nativeReasoning,
                swipes: [response],
                swipeId: 0,
                swipesMeta: [{ genTime: duration, reasoning: nativeReasoning }]
            };

            if (activeChatChar && activeChatChar.name === char.name) {
                // ... (existing tag check logic) ...
                if (tagStart && tagEnd && response.includes(tagStart)) {
                    const sIdx = response.indexOf(tagStart);
                    const eIdx = response.indexOf(tagEnd, sIdx);
                    if (sIdx !== -1) {
                        if (eIdx !== -1) {
                        msg.reasoning = response.substring(sIdx + tagStart.length, eIdx);
                        msg.text = response.substring(0, sIdx) + response.substring(eIdx + tagEnd.length);
                        } else {
                            msg.reasoning = response.substring(sIdx + tagStart.length);
                            msg.text = response.substring(0, sIdx);
                        }
                        // Sync swipes and meta with parsed content
                        msg.swipes = [msg.text];
                        msg.swipesMeta = [{ genTime: duration, reasoning: msg.reasoning }];
                    }
                }

                // Remove placeholder if exists
                const placeholder = document.querySelector('.typing-indicator-placeholder');
                if (placeholder) placeholder.remove();
                
                const actions = streamingMsgElement ? streamingMsgElement.querySelector('.msg-actions-btn') : null;
                if (actions) actions.style.display = 'flex';

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
                        addSwipe(streamingMsgElement, mData, msg.text, { genTime: duration, reasoning: msg.reasoning });
                        
                        // Clear error state if we recovered
                        if (mData.isError) {
                            mData.isError = false;
                            streamingMsgElement.classList.remove('error');
                        }
                    } else {
                        // New message - update the single swipe (fix for "empty first variant" issue)
                        if (streamingMsgElement._msgData) {
                            streamingMsgElement._msgData.text = msg.text;
                            streamingMsgElement._msgData.swipes = [msg.text];
                            streamingMsgElement._msgData.swipeId = 0;
                            streamingMsgElement._msgData.reasoning = msg.reasoning;
                            streamingMsgElement._msgData.swipesMeta = [{ genTime: duration, reasoning: msg.reasoning }];
                            streamingMsgElement._msgData.genTime = duration;
                            
                            // Clear error state
                            if (streamingMsgElement._msgData.isError) {
                                streamingMsgElement._msgData.isError = false;
                                streamingMsgElement.classList.remove('error');
                            }
                        }
                        // CHANGE: Так как мы сохранили сообщение в начале (save=true),
                        // здесь мы обновляем его, а не создаем дубликат.
                        const container = document.getElementById('chat-messages');
                        const allMsgs = Array.from(container.querySelectorAll('.message-section'));
                        const index = allMsgs.indexOf(streamingMsgElement);
                        if (index !== -1) updateSessionMessage(char, index, streamingMsgElement._msgData);
                        else saveMessageToSession(char.name, msg); // Fallback
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
    });
}

async function startImpersonation() {
    if (!activeChatChar) return;
    
    const activePresetId = localStorage.getItem('sc_active_preset_id');
    const presets = (await db.get('sc_prompt_presets')) || [];
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
        response = cleanText(response);
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
        alert("Impersonation failed: " + err.message);
    };

    // We pass the prompt as 'text' to sendToLLM.
    sendToLLM(promptText, activeChatChar, translations, currentLang, () => {}, onComplete, onError, controller, onUpdate, 'impersonation');
}

function openAuthorsNotesEditor() {
    if (!activeChatChar) return;
    
    const key = `sc_an_${activeChatChar.name}`;
    let data = { enabled: true, role: 'system', depth: 4, content: '' };
    try {
        const saved = localStorage.getItem(key);
        if (saved) data = { ...data, ...JSON.parse(saved) };
    } catch(e) {}

    const content = document.createElement('div');
    content.style.padding = '16px';
    content.innerHTML = `
        <div style="margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between;">
            <label style="font-weight: 500;">${translations[currentLang]['label_enabled'] || 'Enabled'}</label>
            <input type="checkbox" class="vk-switch" id="an-enabled" ${data.enabled ? 'checked' : ''}>
        </div>
        
        <div style="margin-bottom: 16px;">
            <label style="display:block; margin-bottom: 8px; font-size: 14px; color: var(--text-gray);">${translations[currentLang]['label_role'] || 'Role'}</label>
            <select id="an-role" style="width: 100%; padding: 10px; border-radius: 8px; border: 1px solid var(--separator-color); background: var(--bg-gray); color: var(--text-black);">
                <option value="system" ${data.role === 'system' ? 'selected' : ''}>System</option>
                <option value="user" ${data.role === 'user' ? 'selected' : ''}>User</option>
                <option value="assistant" ${data.role === 'assistant' ? 'selected' : ''}>Assistant</option>
            </select>
        </div>

        <div style="margin-bottom: 16px;">
            <label style="display:block; margin-bottom: 8px; font-size: 14px; color: var(--text-gray);">${translations[currentLang]['label_depth'] || 'Depth'}</label>
            <input type="number" id="an-depth" value="${data.depth}" placeholder="${translations[currentLang]['placeholder_depth'] || '0 = at the end'}" style="width: 100%; padding: 10px; border-radius: 8px; border: 1px solid var(--separator-color); background: var(--bg-gray); color: var(--text-black);">
        </div>

        <div style="margin-bottom: 16px;">
            <label style="display:block; margin-bottom: 8px; font-size: 14px; color: var(--text-gray);">${translations[currentLang]['label_content'] || 'Content'}</label>
            <textarea id="an-content" rows="5" style="width: 100%; padding: 10px; border-radius: 8px; border: 1px solid var(--separator-color); background: var(--bg-gray); color: var(--text-black); resize: vertical;">${data.content}</textarea>
        </div>
    `;

    const save = () => {
        const newData = {
            enabled: content.querySelector('#an-enabled').checked,
            role: content.querySelector('#an-role').value,
            depth: parseInt(content.querySelector('#an-depth').value) || 0,
            content: content.querySelector('#an-content').value
        };
        localStorage.setItem(key, JSON.stringify(newData));
    };

    content.querySelector('#an-enabled').addEventListener('change', save);
    content.querySelector('#an-role').addEventListener('change', save);
    content.querySelector('#an-depth').addEventListener('input', save);
    content.querySelector('#an-content').addEventListener('input', save);

    showBottomSheet({
        title: translations[currentLang]['magic_authors_notes'] || "Author's Notes",
        content: content
    });
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
    const messagesContainer = document.getElementById('chat-messages');
    
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

    updateSendButton(!!generatingStates[char.name]);

    // Clear unread
    let unread = (await db.get('sc_unread')) || {};
    if (unread[char.name]) {
        delete unread[char.name];
        await db.set('sc_unread', unread);
    }

    const chatData = getChatData(char.name);
    const currentSessionId = chatData.currentId;

    setupChatHeader(char, currentSessionId, {
        onInfoClick: openChatInfoSheet,
        onActionsClick: openSessionsSheet,
        onBackClick: closeChat
    });

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
            <div class="msg-body"></div>
        `;
        const tpl = document.getElementById('tpl-typing-indicator');
        const clone = tpl.content.cloneNode(true);
        clone.querySelector('.typing-text').textContent = translations[currentLang]['model_typing'] || 'Generating...';
        typingSection.querySelector('.msg-body').appendChild(clone);

        messagesContainer.appendChild(typingSection);
    }

    if (currentView) currentView.classList.remove('active-view');
    chatView.classList.add('active-view', 'anim-fade-in');
    requestAnimationFrame(() => {
        // Update System Colors for Chat
        updateAppColors();

        // If it's a new session (empty or just greeting), scroll to top
        if (msgs.length <= 1) {
            messagesContainer.scrollTop = 0;
        } else {
            const savedScroll = chatData.lastScrollPosition !== undefined ? chatData.lastScrollPosition : messagesContainer.scrollHeight;
            messagesContainer.scrollTop = savedScroll;
        }
    });

    const initialScroll = getChatData(char.name).lastScrollPosition || 0;
    _cleanupScroll = initHeaderScroll(messagesContainer, initialScroll, () => activeChatChar && generatingStates[activeChatChar.name]);
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
            chats[charName] = data;
        } else {
            delete chats[charName];
        }
        
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
                        resetHeader();
                        const backBtn = document.getElementById('header-back');
                        if (backBtn) backBtn.style.display = 'flex'; // Ensure visible for editor return
                        openCharacterEditor(idx);
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
    let reasoningEl = element.querySelector('.msg-reasoning');
    if (!reasoningText) {
        if (reasoningEl) {
            if (reasoningEl.classList.contains('exiting')) return;
            
            // Lock height for smooth transition
            reasoningEl.style.maxHeight = reasoningEl.scrollHeight + 'px';
            reasoningEl.classList.remove('entering');
            void reasoningEl.offsetWidth; // Force reflow
            
            reasoningEl.classList.add('exiting');
            
            reasoningEl.addEventListener('transitionend', () => {
                if (reasoningEl.classList.contains('exiting')) reasoningEl.remove();
            }, { once: true });
            setTimeout(() => { if(reasoningEl.parentNode && reasoningEl.classList.contains('exiting')) reasoningEl.remove(); }, 350);
        }
        return;
    }
    if (!reasoningEl) {
        // Insert before body (to avoid typewriter overwrite)
        const body = element.querySelector('.msg-body');
        const tpl = document.getElementById('tpl-reasoning-block');
        reasoningEl = tpl.content.firstElementChild.cloneNode(true);
        reasoningEl.querySelector('.msg-reasoning-header').onclick = () => reasoningEl.classList.toggle('collapsed');
        if (body) {
            element.insertBefore(reasoningEl, body);
        } else {
            element.appendChild(reasoningEl);
        }
    } else if (reasoningEl.classList.contains('exiting')) {
        reasoningEl.classList.remove('exiting');
        reasoningEl.style.maxHeight = '';
        reasoningEl.classList.add('entering');
    }
    reasoningEl.querySelector('.msg-reasoning-inner').innerHTML = formatText(reasoningText);
}

function removeWithAnimation(element) {
    if (!element) return;
    // Remove error class to prevent red blinking during deletion
    element.classList.remove('error');

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
    const displayTime = msg.timestamp ? formatDate(msg.timestamp, 'long') : msg.time;
    const timeHtml = `<span class="msg-time">${displayTime}</span>`;

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
    
    const avatarImg = section.querySelector('.msg-avatar');
    if (avatarImg && avatarImg.tagName === 'IMG') {
        avatarImg.style.cursor = 'pointer';
        avatarImg.onclick = (e) => {
            e.stopPropagation();
            let charName = displayName || "Character";
            let charDesc = "";
            
            if (activeChatChar && (displayName === activeChatChar.name || msg.role === 'char')) {
                charName = activeChatChar.name;
                charDesc = activeChatChar.description || "";
            }
            openImageViewer(avatarImg.src, charName, charDesc);
        };
    }

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
            const tpl = document.getElementById('tpl-msg-switcher');
            switcher = tpl.content.firstElementChild.cloneNode(true);
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

    const tplActions = document.getElementById('tpl-msg-actions-btn');
    const actionsBtn = tplActions.content.firstElementChild.cloneNode(true);
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
            if (section.classList.contains('editing')) return;
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
            
            const body = section.querySelector('.msg-body');
            if (body) body.style.transition = 'none';
            isScrolling = false;
        }, {passive: true});
        
        section.addEventListener('touchmove', e => {
            if (section.classList.contains('editing')) return;
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
                
                if (canSwitch && activeChatChar) {
                    const greetings = getAllGreetings(activeChatChar);
                    if (greetings.length <= 1) return;
                }

                if (delta > 0) {
                    if (canSwitch && (msg.greetingIndex || 0) <= 0) return;
                    if (!canSwitch && msg.swipeId <= 0) return;
                }
                
                body.style.transform = `translateX(${delta}px)`;
            }
        }, {passive: false});
        
        section.addEventListener('touchend', e => {
            if (section.classList.contains('editing')) return;
            const body = section.querySelector('.msg-body');
            if (isScrolling) {
                if (body) body.style.transform = '';
                return;
            }
            const delta = e.changedTouches[0].clientX - startX;
            // First message: Switch greetings only
            if (canSwitch) {
                if (activeChatChar) {
                    const greetings = getAllGreetings(activeChatChar);
                    if (greetings.length <= 1) return;
                }

                if (delta < -100) {
                    if (body) body.style.opacity = '0';
                    changeGreeting(section, msg, 1, true);
                }
                else if (delta > 100) {
                    if ((msg.greetingIndex || 0) > 0) {
                        if (body) body.style.opacity = '0';
                        changeGreeting(section, msg, -1, true);
                    }
                    else if (body) {
                        body.style.transition = 'transform 0.3s ease';
                        body.style.transform = '';
                    }
                }
                else if (body) {
                    body.style.transition = 'transform 0.3s ease';
                    body.style.transform = '';
                }
                return;
            }

            // Normal message
            if (delta < -100) { // Swipe Left (Next)
                if (msg.swipeId < msg.swipes.length - 1) {
                    if (body) body.style.opacity = '0';
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
                    if (body) body.style.opacity = '0';
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

    // Restore reasoning
    if (msg.swipesMeta && msg.swipesMeta[newIndex]) {
        msg.reasoning = msg.swipesMeta[newIndex].reasoning || "";
    }
    updateReasoningBlock(element, msg.reasoning);

    const isError = msg.swipesMeta && msg.swipesMeta[newIndex] && msg.swipesMeta[newIndex].isError;
    
    if (isError) {
        element.classList.add('error');
    } else {
        element.classList.remove('error');
    }

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
        const tpl = document.getElementById('tpl-msg-switcher');
        sw = tpl.content.firstElementChild.cloneNode(true);
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
            icon: '<svg viewBox="0 0 24 24"><path d="M17.5 4C15.57 4 14 5.57 14 7.5C14 8.55 14.46 9.49 15.2 10.15L11.2 14.15C10.46 13.46 9.55 13 8.5 13C7.57 13 6.72 13.36 6.08 13.96L6 6.5C6.55 6.23 7 5.69 7 5C7 3.9 6.1 3 5 3C3.9 3 3 3.9 3 5C3 5.69 3.45 6.23 4 6.5L4.08 16.04C3.44 16.64 3 17.43 3 18.5C3 20.43 4.57 22 6.5 22C8.43 22 10 20.43 10 18.5C10 17.55 9.54 16.71 8.8 16.05L12.8 12.05C13.54 12.74 14.45 13.2 15.5 13.2C17.43 13.2 19 11.63 19 9.7C19 7.77 17.43 6.2 15.5 6.2C15.5 6.2 15.5 6.2 15.5 6.2L17.5 4Z"/></svg>',
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

    const tpl = document.getElementById('tpl-msg-edit-buttons');
    const editButtons = tpl.content.firstElementChild.cloneNode(true);
    
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
    
    newText = cleanText(newText);
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
    const isLast = index === allMsgs.length - 1;
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

    // Prefer New Variant for last message to avoid destroying history/block
    if (!isUser && isLast && (mode === 'normal')) {
        mode = 'new_variant';
    }

    // New Variant Logic (Swipe at end)
    if (mode === 'new_variant' && !isUser) {
        // Prepare UI for generation inside existing element
        const body = element.querySelector('.msg-body');
        body.style.opacity = '0';
        
        setTimeout(() => {
            body.innerHTML = '';
            const tpl = document.getElementById('tpl-typing-indicator');
            const clone = tpl.content.cloneNode(true);
            clone.querySelector('.typing-text').textContent = translations[currentLang]['model_typing'] || 'Generating...';
            body.appendChild(clone);
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
            const onAbort = async (isError) => {
                // If Magic Menu regeneration AND Error -> Do not restore (let error replace it)
                if (isMagic && isError) return;

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