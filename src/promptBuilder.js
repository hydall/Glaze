import { translations } from './i18n.js';
import { currentLang } from './APPSettings.js';
import { showBottomSheet, closeBottomSheet } from './ui.js';
import { db } from './db.js';
import { setupEditorHeader } from './header.js';

let internalRender = null;

export function refreshPromptBlocks() {
    if (internalRender) internalRender();
}

export async function initPromptEditor() {
    console.log("Debug: Initializing Prompt Editor...");

    const list = document.getElementById('prompt-blocks-list');
    const addBtn = document.getElementById('add-block-btn');
    const presetSelector = document.getElementById('btn-preset-selector');
    const currentPresetLabel = document.getElementById('current-preset-name');
    const btnCreatePreset = document.getElementById('btn-create-preset');
    const newPresetInput = document.getElementById('new-preset-name-input');
    const impInput = document.getElementById('impersonation-prompt-input');
    const reasoningStartInput = document.getElementById('preset-reasoning-start');
    const reasoningEndInput = document.getElementById('preset-reasoning-end');
    
    // Component Existence Checks
    if (!list) console.error("Debug: Element 'prompt-blocks-list' not found!");
    if (!addBtn) console.error("Debug: Element 'add-block-btn' not found!");
    if (!presetSelector) console.error("Debug: Element 'btn-preset-selector' not found!");
    if (!currentPresetLabel) console.error("Debug: Element 'current-preset-name' not found!");
    if (!btnCreatePreset) console.error("Debug: Element 'btn-create-preset' not found!");
    if (!newPresetInput) console.error("Debug: Element 'new-preset-name-input' not found!");
    
    // Mandatory blocks definition
    const mandatoryBlocks = [
        { id: "user_persona", i18n: "block_user_persona", type: "system", isStatic: true, enabled: true },
        { id: "char_card", i18n: "block_char_card", type: "system", isStatic: true, enabled: true },
        { id: "char_personality", i18n: "block_char_personality", type: "system", isStatic: true, enabled: true },
        { id: "scenario", i18n: "block_scenario", type: "system", isStatic: true, enabled: true },
        { id: "chat_history", i18n: "block_chat_history", type: "system", isStatic: true, enabled: true }
    ];

    // Load Presets
    let presets = [];
    const localPresets = localStorage.getItem('sc_prompt_presets');
    if (localPresets) {
        presets = JSON.parse(localPresets);
        await db.set('sc_prompt_presets', presets);
        localStorage.removeItem('sc_prompt_presets');
    } else {
        presets = (await db.get('sc_prompt_presets')) || [];
    }

    let activePresetId = localStorage.getItem('sc_active_preset_id');
    
    let presetToDeleteId = null;
    let activePreset = null;

    if (presets.length === 0) {
        // Create Default Preset
        const defaultPreset = {
            id: 'default',
            name: 'Default',
            reasoningStart: "",
            reasoningEnd: "",
            blocks: [
                { name: "Main Prompt", content: "You will participate in a roleplay with {{user}}. Take on a role of {{char}}", enabled: true, role: "system" },
                ...mandatoryBlocks
            ]
        };
        presets.push(defaultPreset);
        activePresetId = 'default';
        activePreset = defaultPreset;
        savePresets();
    } else {
        activePreset = presets.find(p => p.id === activePresetId) || presets[0];
    }

    updatePresetUI();

    async function savePresets() {
        await db.set('sc_prompt_presets', presets);
        localStorage.setItem('sc_active_preset_id', activePreset.id);
    }

    function updatePresetUI() {
        if (currentPresetLabel) currentPresetLabel.textContent = activePreset.name;
        renderBlocks();
        if (impInput) impInput.value = activePreset.impersonationPrompt || "";
        if (reasoningStartInput) reasoningStartInput.value = activePreset.reasoningStart || "";
        if (reasoningEndInput) reasoningEndInput.value = activePreset.reasoningEnd || "";
    }

    // Preset Selector Logic
    if (presetSelector) {
        presetSelector.addEventListener('click', () => {
            console.log("Debug: Preset selector clicked");
            try {
                openPresetsSheet();
            } catch (e) {
                console.error("Debug: Error in preset selector click handler:", e);
            }
        });
    } else {
        console.error("Debug: Preset selector element NOT found");
    }

    function openPresetsSheet() {
        const listContainer = document.createElement('div');
        presets.forEach(p => {
            const el = document.createElement('div');
            el.className = 'sheet-item';
            if (activePreset && p.id === activePreset.id) el.style.backgroundColor = 'var(--bg-gray)';
            
            el.innerHTML = `
                <div class="sheet-item-content">${p.name}</div>
                ${presets.length > 1 ? `
                <div class="sheet-item-remove">
                    <svg viewBox="0 0 24 24" style="fill:#ff4444;width:24px;height:24px;"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                </div>` : ''}
            `;

            el.addEventListener('click', () => {
                activePreset = p;
                savePresets();
                updatePresetUI();
                closeBottomSheet();
            });

            if (presets.length > 1) {
                el.querySelector('.sheet-item-remove').addEventListener('click', (e) => {
                    e.stopPropagation();
                    presetToDeleteId = p.id;
                    closeBottomSheet();
                    openDeletePresetConfirm();
                });
            }

            listContainer.appendChild(el);
        });

        showBottomSheet({
            title: translations[currentLang]['sheet_title_presets'],
            content: listContainer,
            headerAction: {
                icon: '+',
                onClick: () => {
                    closeBottomSheet();
                    openImportCreateSheet();
                }
            }
        });
    }

    function openDeletePresetConfirm() {
        showBottomSheet({
            title: translations[currentLang]['confirm_delete_preset'],
            items: [
                {
                    label: translations[currentLang]['btn_yes'],
                    icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    iconColor: '#ff4444',
                    isDestructive: true,
                    onClick: () => {
                        if (presetToDeleteId) {
                            presets = presets.filter(pr => pr.id !== presetToDeleteId);
                            if (activePreset.id === presetToDeleteId) activePreset = presets[0];
                            savePresets();
                            updatePresetUI();
                            presetToDeleteId = null;
                            closeBottomSheet();
                            setTimeout(openPresetsSheet, 300);
                        }
                    }
                },
                {
                    label: translations[currentLang]['btn_no'],
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        setTimeout(openPresetsSheet, 300);
                    }
                }
            ]
        });
    }

    function openImportCreateSheet() {
        showBottomSheet({
            title: translations[currentLang]['new_preset'],
            items: [
                {
                    label: translations[currentLang]['action_create_new'],
                    icon: '<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        if (newPresetInput) newPresetInput.value = '';
                        openBottomSheet('new-preset-sheet-overlay'); // Keep this one static for now or refactor to dynamic input
                    }
                },
                {
                    label: translations[currentLang]['action_import'],
                    icon: '<svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>',
                    onClick: () => {
                        closeBottomSheet();
                        const fileInput = document.getElementById('preset-file-input');
                        if (fileInput) fileInput.click();
                    }
                }
            ]
        });
    }

    // Hidden File Input
    if (!document.getElementById('preset-file-input')) {
        const input = document.createElement('input');
        input.type = 'file';
        input.id = 'preset-file-input';
        input.accept = '.json';
        input.style.display = 'none';
        document.body.appendChild(input);

        input.addEventListener('change', (e) => {
            const file = e.target.files[0];
            if (!file) return;

            const reader = new FileReader();
            reader.onload = (event) => {
                try {
                    const json = JSON.parse(event.target.result);
                    processImportedPreset(json, file.name.replace(/\.json$/i, ''));
                } catch (err) {
                    console.error("Error parsing JSON:", err);
                    alert("Invalid JSON file");
                }
                e.target.value = '';
            };
            reader.readAsText(file);
        });
    }

    function processImportedPreset(data, defaultName) {
        console.group("Preset Import Debug Logic");
        console.log("Raw JSON Data:", data);

        if (!data.prompts || !Array.isArray(data.prompts)) {
            console.error("Error: 'prompts' array is missing or invalid.");
            alert("Invalid ST format: 'prompts' array missing.");
            console.groupEnd();
            return;
        }

        const orderedBlocks = [];
        const usedMandatory = new Set();

        // 1. Determine Order
        let orderList = [];
        if (data.prompt_order && Array.isArray(data.prompt_order) && data.prompt_order.length > 0) {
            // Select the order list with the most items (usually the actual preset, not the default/system one)
            const bestOrder = data.prompt_order.reduce((prev, current) => 
                (current.order.length > prev.order.length) ? current : prev
            , data.prompt_order[0]);
            console.log(`Strategy: Using 'prompt_order' with most items (Count: ${bestOrder.order.length}).`);
            orderList = bestOrder.order;
        } else {
            console.log("Strategy: Using 'prompts' array order (no explicit order found).");
            orderList = data.prompts.map(p => ({ identifier: p.identifier, enabled: p.enabled !== false }));
        }
        console.log(`Total items to process: ${orderList.length}`, orderList);

        const findPrompt = (id) => {
            const found = data.prompts.find(p => p.identifier === id);
            if (!found) console.warn(`Warning: Prompt definition for '${id}' not found in 'prompts' array.`);
            return found;
        };

        // 2. Process Items
        orderList.forEach((item, index) => {
            console.groupCollapsed(`[${index}] Processing '${item.identifier}'`);
            
            const p = findPrompt(item.identifier);
            if (!p) {
                console.log("Result: Skipped (Definition not found)");
                console.groupEnd();
                return;
            }

            // Skip blacklisted blocks
            if (['enhanceDefinitions', 'worldInfoBefore', 'worldInfoAfter'].includes(item.identifier)) {
                console.log("Result: Skipped (Blacklisted)");
                console.groupEnd();
                return;
            }

            const isEnabled = item.enabled !== undefined ? item.enabled : (p.enabled !== false);
            console.log(`Enabled status: ${isEnabled}`);

            // Check for Mandatory Mapping
            let mandatoryId = null;
            if (item.identifier === 'personaDescription') mandatoryId = 'user_persona';
            else if (item.identifier === 'charDescription') mandatoryId = 'char_card';
            else if (item.identifier === 'charPersonality') mandatoryId = 'char_personality';
            else if (item.identifier === 'scenario') mandatoryId = 'scenario';
            else if (item.identifier === 'chatHistory') mandatoryId = 'chat_history';

            console.log(`Mandatory Mapping: ${mandatoryId ? mandatoryId : "None (Custom Block)"}`);

            if (mandatoryId) {
                if (!usedMandatory.has(mandatoryId)) {
                    const mb = mandatoryBlocks.find(b => b.id === mandatoryId);
                    if (mb) {
                        console.log(`Action: Added as Mandatory Block (${mandatoryId})`);
                        orderedBlocks.push({ ...mb, enabled: isEnabled });
                        usedMandatory.add(mandatoryId);
                        console.groupEnd();
                        return;
                    }
                } else {
                    console.log(`Info: Mandatory block '${mandatoryId}' already added. Attempting to add as text content.`);
                }
            }

            // Add as Text Block (Custom or Duplicate Mandatory)
            // Allow empty strings if they are explicitly defined, but skip null/undefined
            if (p.content !== undefined && p.content !== null) {
                console.log("Action: Added as Text Block");
                console.log(`Content Preview: ${String(p.content).substring(0, 50)}...`);
                
                const safeName = (p.name || item.identifier).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");

                orderedBlocks.push({
                    name: safeName,
                    content: p.content,
                    enabled: isEnabled,
                    role: p.role || "system"
                });
            } else {
                console.log("Result: Skipped (No content)");
            }
            console.groupEnd();
        });

        // 3. Add Missing Mandatory Blocks
        console.log("Checking for missing mandatory blocks...");
        mandatoryBlocks.forEach(mb => {
            if (!usedMandatory.has(mb.id)) {
                console.log(`Action: Appending missing mandatory block '${mb.id}'`);
                orderedBlocks.push({ ...mb });
            }
        });

        console.log("Final Block Count:", orderedBlocks.length);
        console.groupEnd();

        const newPreset = {
            id: Date.now().toString(),
            name: defaultName || "Imported Preset",
            impersonationPrompt: data.impersonation_prompt || "",
            reasoningStart: data.reasoning_start || "",
            reasoningEnd: data.reasoning_end || "",
            blocks: orderedBlocks
        };

        presets.push(newPreset);
        activePreset = newPreset;
        savePresets();
        updatePresetUI();
    }

    if (btnCreatePreset) {
        btnCreatePreset.addEventListener('click', () => {
            const name = newPresetInput.value.trim() || "New Preset";
            const newPreset = {
                id: Date.now().toString(),
                name: name,
                impersonationPrompt: "",
                reasoningStart: "",
                reasoningEnd: "",
                blocks: [...mandatoryBlocks] // Start with mandatory blocks
            };
            presets.push(newPreset);
            activePreset = newPreset;
            savePresets();
            updatePresetUI();
            closeBottomSheet('new-preset-sheet-overlay');
        });
    }

    function renderBlocks() {
        if (!list) {
            console.error("Debug: Cannot render blocks, list container missing.");
            return;
        }
        list.innerHTML = '';
        activePreset.blocks.forEach((block, index) => {
            const el = document.createElement('div');
            el.className = 'prompt-block';
            el.draggable = false;
            el.dataset.index = index;
            
            const blockName = block.isStatic ? translations[currentLang][block.i18n] : block.name;
            const isStatic = block.isStatic;

            el.innerHTML = `
                <div class="block-handle">≡</div>
                <div class="block-content">
                    <div class="block-name">${blockName} ${isStatic ? '<span style="font-size:0.8em;opacity:0.6;">(Static)</span>' : ''}</div>
                    ${!isStatic ? `
                    <div class="block-edit">
                        <svg viewBox="0 0 24 24"><path d="M3 17.46v3.04h3.04l11.12-11.12-3.04-3.04L3 17.46zm16.48-9.71c.39-.39.39-1.02 0-1.41l-1.63-1.63c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.04 3.04 1.83-1.83z"/></svg>
                    </div>` : ''}
                </div>
                <div class="block-actions">
                    <input type="checkbox" class="vk-switch block-toggle" ${block.enabled ? 'checked' : ''}>
                </div>
            `;

            // Edit handler
            if (!isStatic) {
                el.querySelector('.block-edit').addEventListener('click', () => openEditModal(index));
            }

            // Toggle handler
            const toggle = el.querySelector('.block-toggle');
            if (toggle) {
                toggle.addEventListener('change', (e) => {
                    console.log(`Debug: Block '${block.name}' toggled to ${e.target.checked}`);
                    activePreset.blocks[index].enabled = e.target.checked;
                    savePresets();
                });
            } else {
                console.warn(`Debug: Toggle element not found for block index ${index}`);
            }

            const handle = el.querySelector('.block-handle');

            // Drag Events
            el.addEventListener('dragstart', handleDragStart);
            el.addEventListener('dragover', handleDragOver);
            el.addEventListener('drop', handleDrop);
            el.addEventListener('dragend', handleDragEnd);

            // Desktop: Enable drag only via handle
            if (handle) {
                handle.addEventListener('mousedown', () => el.draggable = true);
                handle.addEventListener('mouseup', () => el.draggable = false);
                handle.addEventListener('mouseleave', () => el.draggable = false);

                // Mobile: Touch Events
                handle.addEventListener('touchstart', handleTouchStart, { passive: false });
                handle.addEventListener('touchmove', handleTouchMove, { passive: false });
                handle.addEventListener('touchend', handleTouchEnd);
            }

            list.appendChild(el);
        });

        internalRender = renderBlocks;
    }

    if (addBtn) {
        addBtn.addEventListener('click', () => {
            activePreset.blocks.push({ name: translations[currentLang]['new_block'], content: "", enabled: true, role: "system" });
            savePresets();
            renderBlocks();
        });
    }

    // Drag & Drop Handlers
    let dragSrcEl = null;

    function handleDragStart(e) {
        dragSrcEl = this;
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/html', this.innerHTML);
        this.classList.add('dragging');
    }

    function handleDragOver(e) {
        if (e.preventDefault) e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        return false;
    }

    function handleDrop(e) {
        if (e.stopPropagation) e.stopPropagation();
        if (dragSrcEl !== this) {
            const srcIdx = parseInt(dragSrcEl.dataset.index);
            const targetIdx = parseInt(this.dataset.index);
            // Swap in array
            const temp = activePreset.blocks[srcIdx];
            activePreset.blocks.splice(srcIdx, 1);
            activePreset.blocks.splice(targetIdx, 0, temp);
            savePresets();
            renderBlocks();
        }
        return false;
    }

    function handleDragEnd() {
        this.classList.remove('dragging');
    }

    // Touch Reordering Logic
    let touchDragEl = null;

    function handleTouchStart(e) {
        touchDragEl = this.closest('.prompt-block');
        if (touchDragEl) {
            touchDragEl.classList.add('dragging');
            document.body.style.overflow = 'hidden';
        }
    }

    function handleTouchMove(e) {
        if (!touchDragEl) return;
        e.preventDefault();
        const touch = e.touches[0];
        const target = document.elementFromPoint(touch.clientX, touch.clientY);
        const row = target ? target.closest('.prompt-block') : null;

        if (row && row !== touchDragEl && list.contains(row)) {
            const rect = row.getBoundingClientRect();
            const next = (touch.clientY - rect.top) / (rect.bottom - rect.top) > 0.5;
            if (next) {
                list.insertBefore(touchDragEl, row.nextSibling);
            } else {
                list.insertBefore(touchDragEl, row);
            }
        }
    }

    function handleTouchEnd(e) {
        if (!touchDragEl) return;
        touchDragEl.classList.remove('dragging');
        document.body.style.overflow = '';

        const newBlocks = Array.from(list.children).map(child => activePreset.blocks[parseInt(child.dataset.index)]);
        activePreset.blocks = newBlocks.filter(b => b);
        savePresets();
        renderBlocks();
        touchDragEl = null;
    }

    // Block Editor View Logic
    const editBlockView = document.getElementById('view-block-edit');
    const nameInput = document.getElementById('edit-block-name');
    const roleInput = document.getElementById('edit-block-role');
    const contentInput = document.getElementById('edit-block-content');
    let currentEditIndex = -1;
    const btnDeleteBlock = document.getElementById('btn-delete-block');    const headerTitle = document.getElementById('header-title');

    function openEditModal(index) {
        currentEditIndex = index;
        nameInput.value = activePreset.blocks[index].name;
        roleInput.value = activePreset.blocks[index].role || "system";
        contentInput.value = activePreset.blocks[index].content;
        
        if (btnDeleteBlock) {
            // Hide delete button if static (though static blocks don't have edit button usually)
            // But just in case
            btnDeleteBlock.style.display = activePreset.blocks[index].isStatic ? 'none' : 'flex';
        }

        // Switch view
        document.querySelector('.view.active-view').classList.remove('active-view');
        editBlockView.classList.add('active-view', 'anim-fade-in');
        document.querySelector('.tabbar').style.display = 'none';
        
        setupEditorHeader(translations[currentLang]['header_prompt_edit'], closeEditBlockView);
    }

    function closeEditBlockView() {
        editBlockView.classList.remove('anim-fade-in');
        editBlockView.classList.add('anim-fade-out');
        
        const genView = document.getElementById('view-generation');
        genView.classList.add('active-view', 'anim-fade-in');

        const onAnimationEnd = () => {
            editBlockView.classList.remove('active-view', 'anim-fade-out');
            genView.classList.remove('anim-fade-in');
        };
        editBlockView.addEventListener('animationend', onAnimationEnd, { once: true });

        document.querySelector('.tabbar').style.display = 'flex';
        
        // Restore Header via active tab
        const activeTab = document.querySelector('.tab-btn.active');
        if (activeTab) activeTab.click();
    }

    // Auto-save Logic
    function autoSaveBlock() {
        if (currentEditIndex > -1) {
            activePreset.blocks[currentEditIndex].name = nameInput.value;
            activePreset.blocks[currentEditIndex].role = roleInput.value;
            activePreset.blocks[currentEditIndex].content = contentInput.value;
            savePresets();
            renderBlocks(); // Updates the list in background
        }
    }

    if (nameInput) nameInput.addEventListener('input', autoSaveBlock);
    if (roleInput) roleInput.addEventListener('change', autoSaveBlock);
    if (contentInput) contentInput.addEventListener('input', autoSaveBlock);

    if (btnDeleteBlock) {
        btnDeleteBlock.addEventListener('click', () => {
            if (currentEditIndex > -1) {
                showBottomSheet({
                    title: translations[currentLang]['confirm_delete_block'],
                    items: [
                        {
                            label: translations[currentLang]['btn_yes'],
                            icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                            iconColor: '#ff4444',
                            isDestructive: true,
                            onClick: () => {
                                activePreset.blocks.splice(currentEditIndex, 1);
                                savePresets();
                                renderBlocks();
                                closeBottomSheet();
                                closeEditBlockView();
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

    if (impInput) {
        impInput.addEventListener('input', () => {
            activePreset.impersonationPrompt = impInput.value;
            savePresets();
        });
    }

    if (reasoningStartInput) {
        reasoningStartInput.addEventListener('input', () => {
            activePreset.reasoningStart = reasoningStartInput.value;
            savePresets();
        });
    }

    if (reasoningEndInput) {
        reasoningEndInput.addEventListener('input', () => {
            activePreset.reasoningEnd = reasoningEndInput.value;
            savePresets();
        });
    }
}