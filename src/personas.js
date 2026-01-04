import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { showBottomSheet, closeBottomSheet } from './bottomsheet.js';
import { db } from './db.js';
import { setupEditorHeader } from './header.js';

export async function initPersonas() {
    const personaCard = document.getElementById('persona-card');
    const avatarEl = personaCard.querySelector('.avatar');
    const titleEl = personaCard.querySelector('.title');
    
    // Helper for avatar
    function getAvatarHTML(name, avatar) {
        if (avatar) {
            return `<img src="${avatar}" style="width:100%;height:100%;object-fit:cover;">`;
        }
        const letter = (name && name[0]) ? name[0].toUpperCase() : "?";
        return `<div style="width:100%;height:100%;background-color:var(--vk-blue);display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;font-size:1.2em;">${letter}</div>`;
    }

    let personas = [];
    // Migration
    const localSaved = localStorage.getItem('sc_personas');
    if (localSaved) {
        try {
            personas = JSON.parse(localSaved);
            await db.set('sc_personas', personas);
            localStorage.removeItem('sc_personas');
        } catch(e) { console.error(e); }
    } else {
        personas = (await db.get('sc_personas')) || [];
    }

    if (personas.length === 0) {
        personas = [{ name: "Traveler", prompt: "A curious adventurer" }];
        await db.set('sc_personas', personas);
    }

    let activeIndex = parseInt(localStorage.getItem('sc_active_persona_index') || '0');
    if (activeIndex < 0 || activeIndex >= personas.length) activeIndex = 0;

    async function savePersonas() {
        await db.set('sc_personas', personas);
    }

    function updateActive() {
        if (personas.length === 0) return;
        if (activeIndex >= personas.length) activeIndex = 0;
        const p = personas[activeIndex];
        avatarEl.innerHTML = getAvatarHTML(p.name, p.avatar);
        avatarEl.style.backgroundColor = 'transparent';
        titleEl.textContent = p.name;
        // Save active persona for LLM
        localStorage.setItem('sc_active_persona', JSON.stringify(p));
        localStorage.setItem('sc_active_persona_index', activeIndex);
    }

    // Open Bottom Sheet
    personaCard.addEventListener('click', () => {
        renderSheet();
    });

    function renderSheet() {
        const listContainer = document.createElement('div');
        personas.forEach((p, i) => {
            const item = document.createElement('div');
            item.className = 'sheet-item';
            if (i === activeIndex) item.style.backgroundColor = 'var(--bg-gray)';
            
            item.innerHTML = `
                <div class="avatar" style="width: 40px; height: 40px; overflow: hidden; border-radius: 50%;">
                    ${getAvatarHTML(p.name, p.avatar)}
                </div>
                <div class="sheet-item-content">${p.name}</div>
                <div class="sheet-item-edit">
                    <svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor;"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                </div>
            `;

            // Select Persona
            item.addEventListener('click', () => {
                activeIndex = i;
                updateActive();
                closeBottomSheet();
            });

            // Edit Persona
            item.querySelector('.sheet-item-edit').addEventListener('click', (e) => {
                e.stopPropagation();
                openPersonaEditor(i);
                closeBottomSheet();
            });

            listContainer.appendChild(item);
        });

        showBottomSheet({
            title: translations[currentLang]['sheet_title_personas'],
            content: listContainer,
            headerAction: {
                icon: '<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:var(--vk-blue);"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                onClick: () => {
                    openPersonaEditor(-1);
                    closeBottomSheet();
                }
            }
        });
    }

    // Editor Logic
    const editView = document.getElementById('view-persona-edit');
    const nameInput = document.getElementById('persona-name-input');
    const promptInput = document.getElementById('persona-prompt-input');
    const btnSave = document.getElementById('btn-save-persona');
    const btnCancel = document.getElementById('btn-cancel-persona');

    const editAvatar = document.getElementById('edit-persona-avatar');
    const avatarUpload = document.getElementById('persona-avatar-upload');
    
    // Create Delete Button if not exists
    let deleteBtn = document.getElementById('header-btn-delete-persona');
    if (!deleteBtn) {
        const charDeleteBtn = document.getElementById('header-btn-delete-char');
        if (charDeleteBtn && charDeleteBtn.parentNode) {
            deleteBtn = document.createElement('div');
            deleteBtn.id = 'header-btn-delete-persona';
            deleteBtn.className = 'header-btn';
            deleteBtn.style.display = 'none';
            deleteBtn.style.alignItems = 'center';
            deleteBtn.style.justifyContent = 'center';
            deleteBtn.style.padding = '0 10px';
            deleteBtn.style.position = 'absolute';
            deleteBtn.style.right = '10px';
            deleteBtn.style.cursor = 'pointer';
            deleteBtn.innerHTML = `<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:#ff4444"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>`;
            charDeleteBtn.parentNode.appendChild(deleteBtn);
        }
    }

    let editingIndex = -1;
    let tempNewAvatar = null; // For new persona creation

    function openPersonaEditor(index) {
        editingIndex = index;
        tempNewAvatar = null;
        const isNew = index === -1;
        const data = isNew ? { name: "", prompt: "", avatar: null } : personas[index];
        
        nameInput.value = data.name;
        promptInput.value = data.prompt;
        updateEditAvatar(data.name, data.avatar);

        // Show View
        document.querySelector('.view.active-view').classList.remove('active-view');
        editView.classList.add('active-view', 'anim-fade-in');
        document.querySelector('.tabbar').style.display = 'none';

        // Buttons Logic
        if (isNew) {
            btnSave.style.display = 'flex';
            btnSave.textContent = translations[currentLang]['btn_add'];
            btnCancel.style.display = 'none';
        } else {
            btnSave.style.display = 'none';
            btnCancel.style.display = 'none';
        }

        const actions = [];
        if (!isNew) {
            actions.push({
                id: 'header-btn-delete-persona',
                onClick: () => {
                    showBottomSheet({
                        title: translations[currentLang]['confirm_delete_title'],
                        items: [
                            {
                                label: translations[currentLang]['btn_yes'],
                                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                                iconColor: '#ff4444',
                                isDestructive: true,
                                onClick: () => {
                                    personas.splice(editingIndex, 1);
                                    if (personas.length === 0) personas.push({ name: "Traveler", prompt: "A curious adventurer" });
                                    if (activeIndex >= personas.length) activeIndex = 0;
                                    savePersonas();
                                    updateActive();
                                    closeBottomSheet();
                                    closeEditor();
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
            });
        }

        setupEditorHeader(translations[currentLang]['sheet_title_personas'], closeEditor, actions);
    }

    function updateEditAvatar(name, avatar) {
        editAvatar.innerHTML = getAvatarHTML(name, avatar);
        editAvatar.style.borderRadius = '50%';
        editAvatar.style.overflow = 'hidden';
    }

    // Auto-save Logic
    function handleAutoSave() {
        if (editingIndex !== -1) {
            personas[editingIndex].name = nameInput.value;
            personas[editingIndex].prompt = promptInput.value;
            savePersonas();
            if (activeIndex === editingIndex) updateActive();
            updateEditAvatar(nameInput.value, personas[editingIndex].avatar);
        }
    }

    nameInput.addEventListener('input', handleAutoSave);
    promptInput.addEventListener('input', handleAutoSave);

    // Avatar Upload Logic
    editAvatar.addEventListener('click', () => avatarUpload.click());
    avatarUpload.addEventListener('change', (e) => {
        const file = e.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = (ev) => {
            const result = ev.target.result;
            if (editingIndex !== -1) {
                personas[editingIndex].avatar = result;
                handleAutoSave();
            } else {
                tempNewAvatar = result;
                updateEditAvatar(nameInput.value, tempNewAvatar);
            }
        };
        reader.readAsDataURL(file);
    });

    // Add Button Logic (Only for creation)
    btnSave.addEventListener('click', () => {
        if (editingIndex === -1) {
            const newData = { 
                name: nameInput.value || translations[currentLang]['new_persona'], 
                prompt: promptInput.value || "avatar",
                avatar: tempNewAvatar
            };
            personas.push(newData);
            activeIndex = personas.length - 1;
            savePersonas();
            updateActive();
            closeEditor();
        }
    });

    // Cancel button is hidden, but if it were visible:
    btnCancel.addEventListener('click', closeEditor);

    function closeEditor() {
        editView.classList.remove('anim-fade-in');
        editView.classList.add('anim-fade-out');
        
        const menuView = document.getElementById('view-menu');
        menuView.classList.add('active-view', 'anim-fade-in');

        const onAnimationEnd = () => {
            editView.classList.remove('active-view', 'anim-fade-out');
            menuView.classList.remove('anim-fade-in');
        };
        editView.addEventListener('animationend', onAnimationEnd, { once: true });

        document.querySelector('.tabbar').style.display = 'flex';

        // Restore Header by clicking active tab
        const activeTab = document.querySelector('.tab-btn.active');
        if (activeTab) activeTab.click();
    }

    updateActive();
}