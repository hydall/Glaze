import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { attachLongPress, showBottomSheet, closeBottomSheet } from './ui.js';
import { triggerCharacterImport } from './characterImporter.js';
import { initEditor, openCharacterEditor } from './editor.js';
import { db } from './db.js';
import { deleteAllChats, createNewSession, deleteSession } from './chat.js';

export let characters = [];
let onChatOpenCallback = null;
let activeActionCharIndex = -1;

export async function loadCharacters() {
    // 1. Проверяем localStorage (Миграция)
    const localData = localStorage.getItem('sc_characters');
    if (localData) {
        try {
            characters = JSON.parse(localData);
            // Сохраняем в новую БД
            await db.set('sc_characters', characters);
            // Очищаем старое хранилище
            localStorage.removeItem('sc_characters');
            console.log("Characters migrated to IndexedDB");
        } catch (e) {
            console.error("Migration failed:", e);
        }
    } else {
        // 2. Загружаем из IndexedDB
        try {
            const saved = await db.get('sc_characters');
            if (saved) characters = saved;
        } catch (e) {
            console.error("Error loading characters from DB:", e);
        }
    }
}

export async function saveCharacters() {
    try {
        await db.set('sc_characters', characters);
    } catch (e) {
        console.error("Failed to save characters:", e);
        throw e;
    }
}

export async function addCharacter(char) {
    characters.push(char);
    try {
        await saveCharacters();
    } catch (e) {
        characters.pop();
        alert("Не удалось сохранить персонажа: " + e.message);
        throw e;
    }
}

export function getCharacter(index) {
    return characters[index];
}

export function getCharacterByName(name) {
    return characters.find(c => c.name === name);
}

export async function deleteCharacter(index) {
    if (index > -1 && index < characters.length) {
        const char = characters[index];
        characters.splice(index, 1);
        await saveCharacters();

        // Delete chats
        try {
            await deleteAllChats(char.name);
        } catch (e) {
            console.warn("Failed to delete associated chats:", e);
        }

        // Delete unread status
        const unread = (await db.get('sc_unread')) || {};
        if (unread && unread[char.name]) {
            delete unread[char.name];
            await db.set('sc_unread', unread);
        }

        // Notify components to update (e.g. dialog list)
        window.dispatchEvent(new CustomEvent('character-updated', { detail: { character: null } }));
    }
}

export async function toggleFavorite(index) {
    if (characters[index]) {
        characters[index].isFavorite = !characters[index].isFavorite;
        await saveCharacters();
    }
}

export function init(chatCallback) {
    onChatOpenCallback = chatCallback;

    // FAB Listener
    const fabAdd = document.getElementById('fab-add-character');
    if (fabAdd) {
        // Update FAB content to Pill style
        const label = translations[currentLang]?.action_create_new || "Create New";
        fabAdd.innerHTML = `<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg><span>${label}</span>`;
        
        fabAdd.addEventListener('click', () => {
            openCharOptionsSheet();
        });
    }

    // Init Editor and Actions
    initActionListeners();
    
    initEditor({
        getCharacter: getCharacter,
        saveCharacters: saveCharacters,
        addCharacter: addCharacter,
        deleteCharacter: deleteCharacter,
        renderList: renderList
    });
}

function openCharOptionsSheet() {
    showBottomSheet({
        title: translations[currentLang]['sheet_title_char_options'],
        items: [
            {
                label: translations[currentLang]['action_create_new'],
                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => { closeBottomSheet(); openCharacterEditor(-1); }
            },
            {
                label: translations[currentLang]['action_import'],
                icon: '<svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                onClick: () => { 
                    closeBottomSheet();
                    triggerCharacterImport((data) => {
                        const newChar = {
                            name: data.name || "Unknown",
                            description: data.description || "",
                            desc: data.description || data.creator_notes || "",
                            creator_notes: data.creator_notes || "",
                            tags: data.tags || [],
                            personality: data.personality || "",
                            scenario: data.scenario || "",
                            first_mes: data.first_mes || "",
                            alternate_greetings: data.alternate_greetings || [],
                            mes_example: data.mes_example || "",
                            color: "#" + Math.floor(Math.random()*16777215).toString(16),
                            category: "anime",
                            version: data.character_version || "v1.0",
                            avatar: data.avatar || null
                        };
                        addCharacter(newChar);
                        renderList();
                    });
                }
            }
        ]
    });
}

export function renderList(category = 'all', searchQuery = '') {
    const list = document.getElementById('characters-list');
    const favList = document.getElementById('favorites-list');
    
    if (!list) return;
    list.innerHTML = '';
    if (favList) favList.innerHTML = '';

    // Render Favorites
    if (favList) {
        const favorites = characters.filter(c => c.isFavorite);
        if (favorites.length === 0) {
            favList.style.display = 'none';
        } else {
            favList.style.display = 'flex';
            
        favorites.forEach(char => {
            const el = document.createElement('div');
            el.className = 'favorite-item';
            
            let avatarHtml;
            if (char.avatar) {
                avatarHtml = `<div class="favorite-avatar"><img src="${char.avatar}" alt="${char.name}"></div>`;
            } else {
                const letter = (char.name && char.name[0]) ? char.name[0].toUpperCase() : "?";
                avatarHtml = `<div class="favorite-avatar" style="background-color: ${char.color || '#66ccff'}; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.2em;">${letter}</div>`;
            }

            el.innerHTML = `
                ${avatarHtml}
                <div class="favorite-name">${char.name.length > 10 ? char.name.substring(0, 10) + '...' : char.name}</div>
            `;
            el.addEventListener('click', () => handleCharacterClick(char));
            favList.appendChild(el);
        });
        }
    }

    // Render Main List
    // We need chats to sort. Since renderList is sync in UI flow, we might need to fetch chats async.
    // However, to keep UI responsive, we can fetch chats and then re-render or assume chats are loaded.
    // For now, let's fetch chats async and then sort.
    
    db.get('sc_chats').then(chats => {
        chats = chats || {};
        const sortedChars = [...characters].sort((a, b) => {
            const chatA = chats[a.name];
            const chatB = chats[b.name];
            
            let timeA = 0;
            let timeB = 0;

            if (chatA && chatA.sessions && chatA.sessions[chatA.currentId]) {
                const msgs = chatA.sessions[chatA.currentId];
                if (msgs.length > 0) timeA = msgs[msgs.length - 1].timestamp || 0;
            }
            if (chatB && chatB.sessions && chatB.sessions[chatB.currentId]) {
                const msgs = chatB.sessions[chatB.currentId];
                if (msgs.length > 0) timeB = msgs[msgs.length - 1].timestamp || 0;
            }
            return timeB - timeA;
        });
        renderSortedList(sortedChars, list, category, searchQuery);
    });

    // Initial render (unsorted or previously sorted) to avoid blank screen
    if (list.children.length === 0) {
        renderSortedList(characters, list, category, searchQuery);
    }
}

function renderSortedList(sortedChars, list, category, searchQuery) {
    const fabAdd = document.getElementById('fab-add-character');
    list.innerHTML = ''; // Clear current
    sortedChars.forEach((char) => {
        if (searchQuery && !char.name.toLowerCase().includes(searchQuery.toLowerCase())) {
            return;
        }

        const index = characters.indexOf(char); // Get original index for editing
        if (category !== 'all' && char.category !== category) return;

        const el = document.createElement('div');
        el.className = 'list-item';
        el.dataset.charName = char.name; // For animation finding
        if (char.isFavorite) el.classList.add('favorite');
        
        let avatarHtml;
        if (char.avatar) {
            avatarHtml = `<div class="avatar"><img src="${char.avatar}" alt="${char.name}"></div>`;
        } else {
            const letter = (char.name && char.name[0]) ? char.name[0].toUpperCase() : "?";
            avatarHtml = `<div class="avatar" style="background-color: ${char.color || '#66ccff'}; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.5em;">${letter}</div>`;
        }

        el.innerHTML = `
            ${avatarHtml}
            <div class="item-content">
                <div class="item-header">
                    <span class="item-title">${char.name.length > 20 ? char.name.substring(0, 20) + '...' : char.name}<sup class="item-version">${char.version}</sup></span>
                </div>
                <div class="item-subtitle">${char.desc}</div>
            </div>
            <div class="item-edit-btn">
                <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
            </div>
        `;
        
        const checkLongPress = attachLongPress(el, () => {
            openActions(char, index);
        });

        el.addEventListener('click', (e) => {
            if (checkLongPress()) return;
            // Check if click was on edit button
            if (e.target.closest('.item-edit-btn')) return;
            handleCharacterClick(char);
        });

        el.querySelector('.item-edit-btn').addEventListener('click', (e) => {
            e.stopPropagation();
            openCharacterEditor(index);
        });
        
        list.appendChild(el);
    });

    // Character Options Sheet Trigger
    if (fabAdd) { 
        fabAdd.style.display = ''; 
    }
}


function openActions(char, index) {
    activeActionCharIndex = index;
    
    const favIcon = char.isFavorite 
        ? `<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/><line x1="4" y1="4" x2="20" y2="20" stroke="#ff4444" stroke-width="2" /></svg>`
        : `<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>`;
    
    const favLabel = char.isFavorite ? translations[currentLang]['action_remove_fav'] : translations[currentLang]['action_add_fav'];
    const favColor = char.isFavorite ? '#ff4444' : 'var(--text-gray)';

    showBottomSheet({
        title: char.name,
        items: [
            {
                label: favLabel,
                icon: favIcon,
                iconColor: favColor,
                onClick: async () => {
                    await toggleFavorite(activeActionCharIndex);
                    renderList();
                    closeBottomSheet();
                }
            },
            {
                label: translations[currentLang]['action_delete_char'],
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

function openDeleteConfirm(char) {
    showBottomSheet({
        title: translations[currentLang]['confirm_delete_title'],
        items: [
            {
                label: translations[currentLang]['btn_yes'],
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    const list = document.getElementById('characters-list');
                    const item = list.querySelector(`.list-item[data-char-name="${char.name.replace(/"/g, '\\"')}"]`);
                    if (item) {
                        item.style.transition = 'all 0.3s ease-out';
                        item.style.opacity = '0';
                        item.style.maxHeight = '0';
                        await new Promise(resolve => setTimeout(resolve, 300));
                    }
                    await deleteCharacter(activeActionCharIndex);
                    renderList();
                    closeBottomSheet();
                }
            },
            {
                label: translations[currentLang]['btn_no'],
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

function initActionListeners() {
    // Listeners are now handled dynamically in openActions to support context
    
    // Create New Character (from Options Sheet)
    // This logic is moved to openCharOptionsSheet
}

async function handleCharacterClick(char, forceSelector = false) {
    const allChats = (await db.get('sc_chats')) || {};
    const charData = allChats[char.name];
    
    if (charData && (forceSelector || (charData.sessions && Object.keys(charData.sessions).length > 1))) {
        openSessionSelector(char, charData);
    } else {
        if(onChatOpenCallback) onChatOpenCallback(char);
    }
}

function openSessionSelector(char, charData) {
    const listContainer = document.createElement('div');
    const sessions = charData.sessions;
    
    const ids = Object.keys(sessions).map(Number).sort((a,b) => {
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
        const isCurrent = sid === charData.currentId;
        
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
        
        el.onclick = () => {
            closeBottomSheet();
            if (onChatOpenCallback) {
                const charWithSession = { ...char, sessionId: sid };
                onChatOpenCallback(charWithSession);
            }
        };

        el.querySelector('.session-delete-btn').addEventListener('click', (e) => {
            e.stopPropagation();
            closeBottomSheet();
            openDeleteSessionConfirm(char, sid);
        });
        
        listContainer.appendChild(el);
    });

    showBottomSheet({
        title: translations[currentLang]['history_title'] || 'Chat History',
        content: listContainer,
        headerAction: {
            icon: '+',
            onClick: () => {
                closeBottomSheet();
                createNewSession(char);
            }
        }
    });
}

function openDeleteSessionConfirm(char, sessionId) {
    showBottomSheet({
        title: translations[currentLang]['confirm_delete_session'] || 'Delete Session?',
        items: [
            {
                label: translations[currentLang]['btn_yes'],
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    await deleteSession(sessionId, char);
                    closeBottomSheet();
                    handleCharacterClick(char, true);
                }
            },
            {
                label: translations[currentLang]['btn_no'],
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    handleCharacterClick(char);
                }
            }
        ]
    });
}