import { getCharacterByName } from './characterList.js';
import { attachLongPress, openBottomSheet, closeBottomSheet } from './ui.js';
import { formatText } from './textFormatter.js';
import { isCharacterGenerating, createNewSession, deleteSession } from './chat.js';
import { db } from './db.js';

let _onChatOpen, _lastCategory;

window.addEventListener('character-updated', () => {
    renderDialogs();
});

export async function renderDialogs(category = 'all', onChatOpen) {
    if (onChatOpen) _onChatOpen = onChatOpen;
    if (category && category !== 'all') _lastCategory = category;

    const list = document.getElementById('dialogs-list');
    if (!list) return;
    
    list.innerHTML = '';

    const chats = (await db.get('sc_chats')) || {};
    const unread = (await db.get('sc_unread')) || {};

    const cat = category === 'all' && _lastCategory ? 'all' : (category || _lastCategory || 'all');

    const chatList = [];

    Object.keys(chats).forEach(charName => {
        const charData = chats[charName];
        const char = getCharacterByName(charName);
        if (!char) return;

        if (Array.isArray(charData)) {
            // Legacy format (single session)
            const msgs = charData;
            const lastMsg = msgs[msgs.length - 1];
            chatList.push({
                name: charName,
                sessionId: 1,
                msg: lastMsg ? lastMsg.text : (char.first_mes || ""),
                time: lastMsg ? lastMsg.time : "",
                timestamp: lastMsg ? (lastMsg.timestamp || 0) : 0,
                avatar: char.avatar,
                color: char.color,
                category: char.category,
                charObj: { ...char, sessionId: 1 },
                isCurrent: true
            });
        } else if (charData && charData.sessions) {
            // Multiple sessions
            Object.keys(charData.sessions).forEach(sid => {
                const sessionId = parseInt(sid);
                const msgs = charData.sessions[sid];
                const lastMsg = msgs[msgs.length - 1];
                chatList.push({
                    name: charName,
                    sessionId: sessionId,
                    msg: lastMsg ? lastMsg.text : (char.first_mes || ""),
                    time: lastMsg ? lastMsg.time : "",
                    timestamp: lastMsg ? (lastMsg.timestamp || 0) : 0,
                    avatar: char.avatar,
                    color: char.color,
                    category: char.category,
                    charObj: { ...char, sessionId: sessionId },
                    isCurrent: sessionId === charData.currentId
                });
            });
        }
    });

    // Sort by timestamp descending
    chatList.sort((a, b) => {
        return b.timestamp - a.timestamp;
    });

    chatList.forEach(chat => {
        if (cat !== 'all' && chat.category !== cat) return;

        const el = document.createElement('div');
        el.className = 'list-item';
        el.dataset.charName = chat.name;
        el.dataset.sessionId = chat.sessionId;
        // Mark unread only if it's the current session (where new messages arrive)
        if (unread[chat.name] && chat.isCurrent) {
            el.classList.add('unread');
        }
        
        let avatarHtml;
        if (chat.avatar) {
            avatarHtml = `<div class="avatar"><img src="${chat.avatar}" alt="${chat.name}"></div>`;
        } else {
            avatarHtml = `<div class="avatar" style="background-color: ${chat.color || '#66ccff'}; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.5em;">${chat.name[0].toUpperCase()}</div>`;
        }

        let subtitleHtml = "";
        if (isCharacterGenerating(chat.name) && chat.isCurrent) {
            subtitleHtml = `<div class="typing-dots"><div class="typing-dot"></div><div class="typing-dot"></div><div class="typing-dot"></div></div>`;
        } else {
            let rawText = chat.msg || "";
            // Apply markdown and strip paragraph tags if added by formatter
            let formatted = formatText(rawText);
            formatted = formatted.replace(/<\/?p>/g, '');

            const maxLength = 100;
            if (formatted.length > maxLength) {
                formatted = formatted.substring(0, maxLength) + '...';
            }
            subtitleHtml = formatted;
        }

        const sessionLabel = `<div style="color: var(--text-gray); font-size: 0.8em; margin-bottom: 2px;">Session #${chat.sessionId}</div>`;

        el.innerHTML = `
            ${avatarHtml}
            <div class="item-content">
                <div class="item-header">
                    <span class="item-title">${chat.name.length > 20 ? chat.name.substring(0, 20) + '...' : chat.name}</span>
                    <span class="item-meta">${chat.time}</span>
                </div>
                <div class="item-subtitle">
                    ${sessionLabel}
                    ${subtitleHtml}
                </div>
            </div>
        `;
        
        const checkLongPress = attachLongPress(el, () => {
            openDialogActions(chat.charObj);
        });

        el.addEventListener('click', (e) => {
            if (checkLongPress()) return;
            if (_onChatOpen) _onChatOpen(chat.charObj);
        });

        list.appendChild(el);
    });
}

function openDialogActions(char) {
    const title = document.getElementById('chat-actions-title');
    if (title) {
        const previousView = document.querySelector('.view.active-view');
        const onBack = () => {
            if (previousView) previousView.classList.add('active-view', 'anim-fade-in');
            renderDialogs(_lastCategory, _onChatOpen);
        };

        title.textContent = char.name;
        openBottomSheet('chat-actions-sheet-overlay');

        const btnNew = document.getElementById('btn-chat-new-session');
        const btnDel = document.getElementById('btn-chat-delete');

        // Clone to replace listeners with specific chat context
        const newBtnNew = btnNew.cloneNode(true);
        btnNew.parentNode.replaceChild(newBtnNew, btnNew);

        const newBtnDel = btnDel.cloneNode(true);
        btnDel.parentNode.replaceChild(newBtnDel, btnDel);

        newBtnNew.addEventListener('click', async () => {
            await createNewSession(char, onBack);
            closeBottomSheet('chat-actions-sheet-overlay');
        });

        newBtnDel.addEventListener('click', () => {
            closeBottomSheet('chat-actions-sheet-overlay');
            const sheetId = 'session-delete-confirm-sheet';
            const btnYes = document.getElementById('btn-confirm-delete-session');
            const newYes = btnYes.cloneNode(true);
            btnYes.parentNode.replaceChild(newYes, btnYes);
            
            newYes.onclick = async () => {
                const list = document.getElementById('dialogs-list');
                const safeName = char.name.replace(/"/g, '\\"');
                const item = list.querySelector(`.list-item[data-char-name="${safeName}"][data-session-id="${char.sessionId}"]`);

                if (item) {
                    item.style.transition = 'all 0.3s ease-out';
                    item.style.opacity = '0';
                    item.style.maxHeight = '0';
                    item.style.marginTop = '0';
                    item.style.marginBottom = '0';
                    item.style.paddingTop = '0';
                    item.style.paddingBottom = '0';
                    item.style.overflow = 'hidden';
                    await new Promise(resolve => setTimeout(resolve, 300));
                }

                await deleteSession(char.sessionId, char);
                closeBottomSheet(sheetId);
                await renderDialogs(_lastCategory, _onChatOpen);
            };
            
            openBottomSheet(sheetId);
        });
    }
}