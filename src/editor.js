import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { showBottomSheet, closeBottomSheet } from './ui.js';

let callbacks = {};
let editingCharIndex = -1;
let tempNewChar = null;
let tempAvatar = null;
let currentGreetingIndex = 0;

export function initEditor(cbs) {
    callbacks = cbs;
    
    const avatarEl = document.getElementById('edit-char-avatar');
    const avatarInput = document.getElementById('char-avatar-upload');
    
    // Inputs
    const nameInput = document.getElementById('char-name-input');
    const descInput = document.getElementById('char-description-input');
    const creatorNotesInput = document.getElementById('char-creator-notes-input');
    const tagsInput = document.getElementById('char-tags-input');
    const personalityInput = document.getElementById('char-personality-input');
    const scenarioInput = document.getElementById('char-scenario-input');
    const firstMesInput = document.getElementById('char-first-mes-input');
    const mesExampleInput = document.getElementById('char-mes-example-input');
    const inputs = [nameInput, descInput, creatorNotesInput, tagsInput, personalityInput, scenarioInput, firstMesInput, mesExampleInput];

    // Greeting Switcher Logic
    const btnPrev = document.getElementById('btn-prev-first-mes');
    const btnNext = document.getElementById('btn-next-first-mes');

    if (btnPrev && btnNext) {
        btnPrev.onclick = (e) => { e.stopPropagation(); cycleEditorGreeting(-1); };
        btnNext.onclick = (e) => { e.stopPropagation(); cycleEditorGreeting(1); };
    }

    // Auto-save
    const autoSave = () => {
        let char = null;
        if (editingCharIndex > -1) {
            char = callbacks.getCharacter(editingCharIndex);
        } else if (tempNewChar) {
            char = tempNewChar;
        }

        if (char) {
            char.name = nameInput.value;
            char.description = descInput.value;
            char.desc = descInput.value;
            char.creator_notes = creatorNotesInput.value;
            char.tags = tagsInput.value.split(',').map(t => t.trim()).filter(t => t);
            char.personality = personalityInput.value;
            char.scenario = scenarioInput.value;
            char.mes_example = mesExampleInput.value;
            char.avatar = tempAvatar;

            // Handle Greeting
            if (currentGreetingIndex === 0) {
                char.first_mes = firstMesInput.value;
            } else {
                if (!char.alternate_greetings) char.alternate_greetings = [];
                char.alternate_greetings[currentGreetingIndex - 1] = firstMesInput.value;
            }

            if (editingCharIndex > -1) {
                callbacks.saveCharacters();
                window.dispatchEvent(new CustomEvent('character-updated', { detail: { character: char } }));
            }
        }
    };

    inputs.forEach(input => input.addEventListener('input', autoSave));

    // Avatar Upload
    avatarEl.addEventListener('click', () => avatarInput.click());
    avatarInput.addEventListener('change', (e) => {
        const file = e.target.files[0];
        if (file) {
            const reader = new FileReader();
            reader.onload = (ev) => {
                tempAvatar = ev.target.result;
                updateAvatarDisplay(tempAvatar, nameInput.value);
                autoSave();
                if (callbacks.renderList) callbacks.renderList();
            };
            reader.readAsDataURL(file);
        }
    });

    // Full Screen Editor Logic
    const fsEditor = document.getElementById('full-screen-editor');
    const fsTextarea = document.getElementById('fs-editor-textarea');
    const fsClose = document.getElementById('fs-editor-close');
    const fsSave = document.getElementById('fs-editor-save');
    let currentTargetInput = null;

    if (fsEditor && fsTextarea && !fsEditor.dataset.initialized) {
        fsEditor.dataset.initialized = 'true';

        const closeFullScreen = () => {
            fsEditor.classList.remove('anim-fade-in');
            fsEditor.classList.add('anim-fade-out');
            setTimeout(() => {
                fsEditor.style.display = 'none';
                fsEditor.classList.remove('active-view', 'anim-fade-out');
                currentTargetInput = null;
            }, 200);
        };

        if (fsClose) fsClose.onclick = closeFullScreen;
        
        if (fsSave) fsSave.onclick = () => {
            if (currentTargetInput) {
                currentTargetInput.value = fsTextarea.value;
                currentTargetInput.dispatchEvent(new Event('input', { bubbles: true }));
            }
            closeFullScreen();
        };

        document.body.addEventListener('click', (e) => {
            const btn = e.target.closest('.expand-btn');
            if (btn) {
                const targetId = btn.getAttribute('data-target');
                const target = document.getElementById(targetId);
                if (target) {
                    currentTargetInput = target;
                    fsTextarea.value = target.value || '';
                    fsEditor.style.display = 'flex';
                    requestAnimationFrame(() => {
                        fsEditor.classList.add('active-view', 'anim-fade-in');
                    });
                }
            }
        });
    }
}

export function openCharacterEditor(index) {
    editingCharIndex = index;
    currentGreetingIndex = 0;
    
    const isNew = index === -1;
    const char = isNew ? { 
        name: "", description: "", creator_notes: "", tags: [], 
        personality: "", scenario: "", first_mes: "", mes_example: "", 
        avatar: null, alternate_greetings: [] 
    } : callbacks.getCharacter(index);
    
    if (isNew) tempNewChar = char;

    const editView = document.getElementById('view-character-edit');
    const previousView = document.querySelector('.view.active-view');

    // Populate Fields
    const getVal = (id, val) => { const el = document.getElementById(id); if(el) el.value = val || ''; };
    getVal('char-name-input', char.name);
    getVal('char-description-input', char.description || char.desc);
    getVal('char-creator-notes-input', char.creator_notes);
    getVal('char-tags-input', Array.isArray(char.tags) ? char.tags.join(', ') : (char.tags || ""));
    getVal('char-personality-input', char.personality);
    getVal('char-scenario-input', char.scenario);
    getVal('char-mes-example-input', char.mes_example);
    
    tempAvatar = char.avatar;
    updateAvatarDisplay(tempAvatar, char.name);
    updateGreetingEditorUI(char);

    // Show View
    if (previousView) previousView.classList.remove('active-view');
    editView.classList.add('active-view', 'anim-fade-in');
    document.querySelector('.tabbar').style.display = 'none';

    // Header Setup
    const headerTitle = document.getElementById('header-title');
    const headerArrow = document.getElementById('header-arrow');
    const backBtn = document.getElementById('header-back');
    const headerLogo = document.getElementById('header-logo');
    const deleteBtn = document.getElementById('header-btn-delete-char');

    if(headerLogo) headerLogo.style.display = 'none';
    backBtn.style.display = 'flex';
    headerArrow.style.display = 'none';
    headerTitle.textContent = isNew ? translations[currentLang]['action_create_new'] : translations[currentLang]['header_editor'];
    if(deleteBtn) deleteBtn.style.display = isNew ? 'none' : 'flex';

    // Create Button (for new char)
    let createBtn = document.getElementById('header-btn-create-char');
    if (!createBtn) {
        createBtn = document.createElement('div');
        createBtn.id = 'header-btn-create-char';
        createBtn.className = 'header-btn';
        createBtn.style.alignItems = 'center';
        createBtn.style.justifyContent = 'center';
        createBtn.style.padding = '0 10px';
        createBtn.style.cursor = 'pointer';
        createBtn.style.position = 'absolute';
        createBtn.style.right = '10px';
        createBtn.innerHTML = `<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:var(--vk-blue);"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>`;
        if (deleteBtn && deleteBtn.parentNode) deleteBtn.parentNode.insertBefore(createBtn, deleteBtn);
        else backBtn.parentNode.appendChild(createBtn);
        
        createBtn.addEventListener('click', () => {
            if (tempNewChar) {
                if (!tempNewChar.name || !tempNewChar.name.trim()) {
                    alert(translations[currentLang]['placeholder_enter_name'] || "Name is required");
                    return;
                }
                tempNewChar.color = "#" + Math.floor(Math.random()*16777215).toString(16);
                tempNewChar.category = "anime";
                tempNewChar.version = "v1.0";
                callbacks.addCharacter(tempNewChar);
                callbacks.renderList();
                closeEditor(previousView);
            }
        });
    }
    createBtn.style.display = isNew ? 'flex' : 'none';

    // Back Button
    backBtn.onclick = () => closeEditor(previousView);

    // Delete Button
    if (deleteBtn) {
        // Clone to remove old listeners
        const newDeleteBtn = deleteBtn.cloneNode(true);
        deleteBtn.parentNode.replaceChild(newDeleteBtn, deleteBtn);
        
        newDeleteBtn.style.display = isNew ? 'none' : 'flex';
        newDeleteBtn.onclick = () => {
            showBottomSheet({
                title: translations[currentLang]['confirm_delete_title'],
                items: [
                    {
                        label: translations[currentLang]['btn_yes'],
                        icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                        iconColor: '#ff4444',
                        isDestructive: true,
                        onClick: () => {
                            callbacks.deleteCharacter(editingCharIndex);
                            closeBottomSheet();
                            closeEditor(previousView);
                        }
                    },
                    {
                        label: translations[currentLang]['btn_no'],
                        icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                        onClick: () => closeBottomSheet()
                    }
                ]
            });
        };
    }
}

function closeEditor(previousView) {
    const editView = document.getElementById('view-character-edit');
    editView.classList.remove('anim-fade-in');
    editView.classList.add('anim-fade-out');
    
    if (previousView) previousView.classList.add('active-view', 'anim-fade-in');

    const onAnimationEnd = () => {
        editView.classList.remove('active-view', 'anim-fade-out');
        if (previousView) previousView.classList.remove('anim-fade-in');
    };
    editView.addEventListener('animationend', onAnimationEnd, { once: true });

    // Restore Header
    const headerLogo = document.getElementById('header-logo');
    const backBtn = document.getElementById('header-back');
    const deleteBtn = document.getElementById('header-btn-delete-char');
    const createBtn = document.getElementById('header-btn-create-char');
    const headerTitle = document.getElementById('header-title');
    const headerArrow = document.getElementById('header-arrow');

    if(headerLogo) headerLogo.style.display = 'flex';
    backBtn.style.display = 'none';
    if(deleteBtn) deleteBtn.style.display = 'none';
    if(createBtn) createBtn.style.display = 'none';
    
    if (previousView) {
        const prevTab = document.querySelector(`.tab-btn[data-target="${previousView.id}"]`);
        if (prevTab) {
            const titleKey = prevTab.getAttribute('data-i18n-title');
            headerTitle.textContent = translations[currentLang][titleKey];
        }
        const hasDropdown = (previousView.id === 'view-dialogs' || previousView.id === 'view-characters');
        headerArrow.style.display = hasDropdown ? 'block' : 'none';
    }

    document.querySelector('.tabbar').style.display = 'flex';
    callbacks.renderList();
}

function updateAvatarDisplay(src, name) {
    const avatarEl = document.getElementById('edit-char-avatar');
    if (src) {
        avatarEl.innerHTML = `<img src="${src}" style="width:100%;height:100%;object-fit:cover;">`;
    } else {
         avatarEl.innerHTML = `<div style="width:100%;height:100%;background-color:#66ccff;display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;font-size:2em;">${(name||"?")[0]}</div>`;
    }
}

function cycleEditorGreeting(dir) {
    let char = editingCharIndex > -1 ? callbacks.getCharacter(editingCharIndex) : tempNewChar;
    if (!char) return;
    
    const alts = char.alternate_greetings || [];
    const total = 1 + alts.length;
    
    currentGreetingIndex += dir;
    if (currentGreetingIndex >= total) currentGreetingIndex = 0;
    if (currentGreetingIndex < 0) currentGreetingIndex = total - 1;
    
    updateGreetingEditorUI(char);
}

function updateGreetingEditorUI(char) {
    const input = document.getElementById('char-first-mes-input');
    const counter = document.getElementById('first-mes-counter');
    
    let text = "";
    if (currentGreetingIndex === 0) {
        text = char.first_mes || "";
    } else {
        const alts = char.alternate_greetings || [];
        text = alts[currentGreetingIndex - 1] || "";
    }
    
    if (input) input.value = text;
    
    const alts = char.alternate_greetings || [];
    const total = 1 + alts.length;
    if (counter) counter.textContent = `${currentGreetingIndex + 1}/${total}`;
}