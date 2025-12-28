import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { attachLongPress, openBottomSheet, closeBottomSheet } from './ui.js';
import { triggerCharacterImport } from './characterImporter.js';
import { initEditor, openCharacterEditor } from './editor.js';
import { db } from './db.js';

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
            const chats = (await db.get('sc_chats')) || {};
            if (chats[char.name]) {
                delete chats[char.name];
                await db.set('sc_chats', chats);
            }
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

    // Import Button Logic
    const btnImport = document.getElementById('btn-import-char');
    if (btnImport) {
        btnImport.addEventListener('click', () => {
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
                closeBottomSheet('char-options-sheet-overlay');
            });
        });
    }

    // FAB Listener
    const fabAdd = document.getElementById('fab-add-character');
    if (fabAdd) {
        fabAdd.addEventListener('click', () => {
            openBottomSheet('char-options-sheet-overlay');
        });
    }

    // Init Editor and Actions
    initActionListeners();
    initSelectionList();
    
    initEditor({
        getCharacter: getCharacter,
        saveCharacters: saveCharacters,
        addCharacter: addCharacter,
        deleteCharacter: deleteCharacter,
        renderList: renderList
    });
}

export function renderList(category = 'all') {
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
            el.addEventListener('click', () => { if(onChatOpenCallback) onChatOpenCallback(char); });
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
        renderSortedList(sortedChars, list, category);
    });

    // Initial render (unsorted or previously sorted) to avoid blank screen
    if (list.children.length === 0) {
        renderSortedList(characters, list, category);
    }
}

function renderSortedList(sortedChars, list, category) {
    const fabAdd = document.getElementById('fab-add-character');
    list.innerHTML = ''; // Clear current
    sortedChars.forEach((char) => {
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
            if(onChatOpenCallback) onChatOpenCallback(char);
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
    const title = document.getElementById('char-actions-title');
    const favBtn = document.getElementById('btn-char-favorite');
    const favLabel = document.getElementById('lbl-char-favorite');
    const btnNewVer = document.getElementById('btn-char-new-version');
    const btnDelete = document.getElementById('btn-char-delete');

    // Hide New Version button as requested
    if (btnNewVer) btnNewVer.style.display = 'none';
    
    if (title) {
        title.textContent = char.name;
        
        // Update Favorite Button State
        const favIconContainer = favBtn.querySelector('.sheet-item-icon');
        if (char.isFavorite) {
            favLabel.textContent = translations[currentLang]['action_remove_fav'];
            favIconContainer.style.fill = '#ff4444';
            favIconContainer.innerHTML = `<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/><line x1="4" y1="4" x2="20" y2="20" stroke="#ff4444" stroke-width="2" /></svg>`;
        } else {
            favLabel.textContent = translations[currentLang]['action_add_fav'];
            favIconContainer.style.fill = 'var(--text-gray)';
            favIconContainer.innerHTML = `<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>`;
        }
        
        const newFavBtn = favBtn.cloneNode(true);
        favBtn.parentNode.replaceChild(newFavBtn, favBtn);
        
        newFavBtn.addEventListener('click', async () => {
            await toggleFavorite(activeActionCharIndex);
            renderList();
            closeBottomSheet('char-actions-sheet-overlay');
        });

        // Setup Delete Button
        if (btnDelete) {
            const newBtnDelete = btnDelete.cloneNode(true);
            btnDelete.parentNode.replaceChild(newBtnDelete, btnDelete);
            
            newBtnDelete.addEventListener('click', () => {
                closeBottomSheet('char-actions-sheet-overlay');
                
                const sheetId = 'char-delete-confirm-sheet';
                const confirmBtn = document.getElementById('btn-confirm-delete-char');
                const cancelBtn = document.getElementById('btn-cancel-delete-char');
                
                const newConfirm = confirmBtn.cloneNode(true);
                confirmBtn.parentNode.replaceChild(newConfirm, confirmBtn);
                
                newConfirm.addEventListener('click', async () => {
                    // Animation Logic
                    const list = document.getElementById('characters-list');
                    const item = list.querySelector(`.list-item[data-char-name="${char.name.replace(/"/g, '\\"')}"]`);
                    
                    if (item) {
                        item.style.transition = 'all 0.3s ease-out';
                        item.style.opacity = '0';
                        item.style.maxHeight = '0';
                        item.style.marginTop = '0';
                        item.style.marginBottom = '0';
                        item.style.paddingTop = '0';
                        item.style.paddingBottom = '0';
                        item.style.overflow = 'hidden';
                        // Wait for animation
                        await new Promise(resolve => setTimeout(resolve, 300));
                    }

                    await deleteCharacter(activeActionCharIndex);
                    renderList();
                    closeBottomSheet(sheetId);
                });
                
                if (cancelBtn) {
                    const newCancel = cancelBtn.cloneNode(true);
                    cancelBtn.parentNode.replaceChild(newCancel, cancelBtn);
                    newCancel.onclick = () => closeBottomSheet(sheetId);
                }
                
                openBottomSheet(sheetId);
            });
        }

        openBottomSheet('char-actions-sheet-overlay');
    }
}

function initActionListeners() {
    // Listeners are now handled dynamically in openActions to support context
    
    // Create New Character (from Options Sheet)
    document.getElementById('btn-create-char').addEventListener('click', () => {
        closeBottomSheet('char-options-sheet-overlay');
        // Open editor for new character (index -1)
        openCharacterEditor(-1);
    });
}

function initSelectionList() {
    const fabDialog = document.getElementById('fab-add-dialog');
    if (fabDialog) {
        fabDialog.addEventListener('click', () => {
            renderSelectionList();
            openBottomSheet('char-selection-sheet-overlay');
        });
    }
}

function renderSelectionList() {
    const charSelectionList = document.getElementById('char-selection-list');
    if (!charSelectionList) return;
    
    charSelectionList.innerHTML = '';
    characters.forEach(char => {
        const item = document.createElement('div');
        item.className = 'sheet-item';
        
        let avatarHtml;
        if (char.avatar) {
            avatarHtml = `<div class="avatar" style="width:40px;height:40px;"><img src="${char.avatar}" style="width:100%;height:100%;object-fit:cover;"></div>`;
        } else {
            const letter = (char.name && char.name[0]) ? char.name[0].toUpperCase() : "?";
            avatarHtml = `<div class="avatar" style="width:40px;height:40px;background-color:${char.color||'#ccc'};display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;">${letter}</div>`;
        }

        item.innerHTML = `${avatarHtml}<div class="sheet-item-content">${char.name}</div>`;
        item.addEventListener('click', () => {
            if(onChatOpenCallback) onChatOpenCallback(char);
            closeBottomSheet('char-selection-sheet-overlay');
        });
        charSelectionList.appendChild(item);
    });
}