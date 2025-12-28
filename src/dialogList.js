import { getCharacterByName, characters } from './characterList.js';
import { attachLongPress, showBottomSheet, closeBottomSheet } from './ui.js';
import { formatText } from './textFormatter.js';
import { isCharacterGenerating, createNewSession, deleteSession } from './chat.js';
import { db } from './db.js';
import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';

let _onChatOpen, _lastCategory;

window.addEventListener('character-updated', () => {
    renderDialogs();
});

export function refreshDialogs() {
    return renderDialogs(_lastCategory);
}

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

    const fab = document.getElementById('fab-add-dialog');
    if (fab) {
        const newFab = fab.cloneNode(true);
        fab.parentNode.replaceChild(newFab, fab);
        newFab.addEventListener('click', () => {
            openNewSessionPicker();
        });
    }
}

function openDialogActions(char) {
    const previousView = document.querySelector('.view.active-view');
    const onBack = () => {
        if (previousView) previousView.classList.add('active-view', 'anim-fade-in');
        renderDialogs(_lastCategory, _onChatOpen);
    };

    showBottomSheet({
        title: char.name,
        items: [
            {
                label: 'Новая сессия', // TODO: i18n
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: async () => {
                    await createNewSession(char, onBack);
                    closeBottomSheet();
                }
            },
            {
                label: 'Удалить сессию', // TODO: i18n
                icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    closeBottomSheet();
                    openDeleteConfirm(char);
                }
            }
        ]
    });
}

function openNewSessionPicker() {
    const items = characters.map(char => ({
        label: char.name,
        icon: char.avatar ? `<img src="${char.avatar}" style="width:24px;height:24px;border-radius:50%;object-fit:cover;">` : 
              `<div style="width:24px;height:24px;border-radius:50%;background-color:${char.color||'#ccc'};display:flex;align-items:center;justify-content:center;color:white;font-size:12px;font-weight:bold;">${(char.name[0]||'?').toUpperCase()}</div>`,
        onClick: () => {
            closeBottomSheet();
            const previousView = document.getElementById('view-dialogs');
            createNewSession(char, () => {
                if (previousView) previousView.classList.add('active-view', 'anim-fade-in');
                renderDialogs(_lastCategory, _onChatOpen);
            });
        }
    }));

    showBottomSheet({
        title: translations[currentLang]['sheet_title_select_char'] || 'Select Character',
        items: items
    });
}

function openDeleteConfirm(char) {
    showBottomSheet({
        title: 'Удалить сессию?', // TODO: i18n
        items: [
            {
                label: 'Да',
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    await deleteSession(char.sessionId, char);
                    closeBottomSheet();
                }
            },
            {
                label: 'Нет',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}