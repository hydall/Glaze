<script setup>
import { ref, computed, watch, onBeforeUnmount } from 'vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';

const props = defineProps({
    modelValue: { type: Object, required: true },
    config: { type: Array, default: () => [] }, // [{ title: String, fields: [] }]
    showAvatar: { type: Boolean, default: false },
    avatarField: { type: String, default: 'avatar' },
    disableAutoSave: { type: Boolean, default: false },
});

const emit = defineEmits(['update:modelValue', 'save', 'open-fs']);

const item = ref({});
const avatarInput = ref(null);
const t = (key) => translations[currentLang.value]?.[key] || key;

// Specific state for greetings cycling
const currentGreetingIndex = ref(0);
const tagsString = ref("");

// Timers must be declared before usage in watch
let saveTimer = null;
let updateTimer = null;

watch(() => props.modelValue, (newVal) => {
    if (newVal) {
        // Fast shallow check before expensive stringify
        if (newVal === item.value) return;

        // Avoid infinite loops if objects are identical
        if (JSON.stringify(newVal) === JSON.stringify(item.value)) return;

        // If we are switching from one item to another, save the PREVIOUS item immediately
        if (item.value && Object.keys(item.value).length > 0 && saveTimer) {
            clearTimeout(saveTimer);
            if (updateTimer) {
                clearTimeout(updateTimer);
                emit('update:modelValue', item.value);
            }
            emit('save', item.value);
        }

        const oldName = item.value.name;
        item.value = JSON.parse(JSON.stringify(newVal));
        // Handle tags specifically if present
        if (item.value.tags !== undefined) {
            tagsString.value = Array.isArray(item.value.tags) ? item.value.tags.join(', ') : (item.value.tags || "");
        } else {
            tagsString.value = "";
        }
        if (newVal.name !== oldName) currentGreetingIndex.value = 0;
    } else {
        item.value = {};
        currentGreetingIndex.value = 0;
    }
}, { immediate: true });

const displayAvatar = computed(() => item.value[props.avatarField]);

function addGreeting() {
    if (!item.value.alternate_greetings) item.value.alternate_greetings = [];
    item.value.alternate_greetings.push("");
    // Open editor for the new greeting immediately
    openFsEditor('alternate_greetings', item.value.alternate_greetings.length); // length is the index because 1-based logic in openFsEditor wrapper needs adjustment or we pass specific index
}

function confirmDeleteGreeting(index) {
    showBottomSheet({
        title: t('confirm_delete_greeting') || 'Delete?',
        items: [
            {
                label: t('btn_yes') || 'Yes',
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: () => {
                    performDelete(index);
                    closeBottomSheet();
                }
            },
            {
                label: t('btn_no') || 'No',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

function performDelete(index) {
    if (index === 0) {
        // Removing first_mes
        if (item.value.alternate_greetings && item.value.alternate_greetings.length > 0) {
            item.value.first_mes = item.value.alternate_greetings.shift();
        } else {
            item.value.first_mes = "";
        }
    } else {
        // Removing from alternate_greetings
        const altIndex = index - 1;
        if (item.value.alternate_greetings && item.value.alternate_greetings.length > altIndex) {
            item.value.alternate_greetings.splice(altIndex, 1);
        }
    }
    autoSave();
}

function removeGreeting(index) {
    // Deprecated direct call, redirected to confirm
    confirmDeleteGreeting(index);
}

const allGreetings = computed(() => {
    const list = [];
    list.push(item.value.first_mes || "");
    if (item.value.alternate_greetings) {
        list.push(...item.value.alternate_greetings);
    }
    return list;
});
// ------------------------------------------------

function onTagsInput() {
    item.value.tags = tagsString.value.split(',').map(t => t.trim()).filter(t => t);
    autoSave();
}

function autoSave() {
    // Debounce V-Model update to prevent lag in parent re-renders/token counts
    if (updateTimer) clearTimeout(updateTimer);
    updateTimer = setTimeout(() => {
        emit('update:modelValue', item.value);
        updateTimer = null;
    }, 200);

    if (props.disableAutoSave) return;

    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
        emit('save', item.value);
        saveTimer = null;
    }, 1000);
}

onBeforeUnmount(() => {
    if (updateTimer) {
        clearTimeout(updateTimer);
        emit('update:modelValue', item.value);
    }
    if (saveTimer) {
        clearTimeout(saveTimer);
        emit('save', item.value);
    }
    // Final defensive save
    if (item.value && Object.keys(item.value).length > 0) {
        emit('save', item.value);
    }
});

function triggerAvatarUpload() {
    if (avatarInput.value) avatarInput.value.click();
}

function handleAvatarChange(e) {
    const file = e.target.files[0];
    if (file) {
        const reader = new FileReader();
        reader.onload = (ev) => {
            item.value[props.avatarField] = ev.target.result;
            autoSave();
        };
        reader.readAsDataURL(file);
    }
}

function openFsEditor(field, index = -1) {
    let val = item.value[field];
    
    // Special handling for greeting list field
    if (field === 'first_mes' || field === 'alternate_greetings') {
        if (index === -1) index = 0; // Default to first message if not specified
        
        if (index === 0) {
            val = item.value.first_mes || "";
        } else {
            val = item.value.alternate_greetings?.[index - 1] || "";
        }
    }
    
    const payload = {
        value: val,
        onSave: (newVal) => {
            if (field === 'first_mes' || field === 'alternate_greetings') {
                if (index === 0) {
                    item.value.first_mes = newVal;
                } else {
                    if (!item.value.alternate_greetings) item.value.alternate_greetings = [];
                    // Ensure array is big enough if we jumped indices (shouldn't happen with this UI)
                    while (item.value.alternate_greetings.length < index) item.value.alternate_greetings.push("");
                    item.value.alternate_greetings[index - 1] = newVal;
                }
            } else {
                item.value[field] = newVal;
            }
            autoSave();
        }
    };

    // Emit for parent component (legacy/optional)
    emit('open-fs', payload);
    
    // Dispatch global event for App.vue to catch
    window.dispatchEvent(new CustomEvent('open-fs-request', { detail: payload }));
}
</script>

<template>
    <div class="view active-view editor-container">
        <div class="editor-content">
            <!-- Avatar Section (Redesigned as a window/card) -->
            <div class="menu-group avatar-card" v-if="showAvatar" @click="triggerAvatarUpload">
                <div class="avatar-wrapper">
                    <div class="avatar-header-overlay">{{ t('avatar') || 'Avatar' }}</div>
                    <img v-if="displayAvatar" :src="displayAvatar" class="avatar-img">
                    <div v-else class="avatar-placeholder">
                        {{ (item.name || "?")[0].toUpperCase() }}
                    </div>
                    <div class="avatar-overlay-hint">{{ t('hint_change_avatar') }}</div>
                </div>
                <input type="file" ref="avatarInput" accept="image/*" style="display: none;" @change="handleAvatarChange">
            </div>
            
            <!-- Dynamic Sections -->
            <template v-for="(section, sIdx) in config" :key="sIdx">
                <div class="menu-group">
                    <div class="group-header" v-if="section.title">{{ t(section.title) || section.title }}</div>
                    
                <div v-for="(field, fIdx) in section.fields" :key="fIdx" class="settings-item">
                    
                    <!-- Label Row -->
                    <div class="label-row" v-if="field.expandable || field.type === 'greeting_list'">
                        <label>{{ t(field.label) || field.label }}</label> 
                        <div v-if="field.expandable" class="expand-btn" @click="openFsEditor(field.key)"><svg viewBox="0 0 24 24"><path d="M15 3l2.3 2.3-2.89 2.87 1.42 1.42L18.7 6.7 21 9V3zM3 9l2.3-2.3 2.87 2.89 1.42-1.42L6.7 5.3 9 3H3zm6 12l-2.3-2.3 2.89-2.87-1.42-1.42L5.3 17.3 3 15v6zm12-6l-2.3 2.3-2.87-2.89-1.42 1.42 2.89 2.87L15 21h6z"/></svg></div>
                    </div>
                    <label v-else-if="field.type !== 'greeting_list'">{{ t(field.label) || field.label }}</label>

                    <!-- Inputs -->
                    <input v-if="field.type === 'text'" type="text" v-model="item[field.key]" @input="autoSave" :placeholder="field.placeholder ? t(field.placeholder) : ''">
                    
                    <input v-else-if="field.type === 'number'" type="number" v-model.number="item[field.key]" @input="autoSave" :placeholder="field.placeholder ? t(field.placeholder) : ''">
                    
                    <input v-else-if="field.type === 'tags'" type="text" v-model="tagsString" @input="onTagsInput">
                    
                    <textarea v-else-if="field.type === 'textarea'" v-model="item[field.key]" :rows="field.rows || 3" @input="autoSave" :placeholder="field.placeholder ? t(field.placeholder) : ''"></textarea>

                    <!-- Greeting List (Custom List View) -->
                    <div v-else-if="field.type === 'greeting_list'" class="greeting-list-container">
                        <div v-for="(greet, gIdx) in allGreetings" :key="gIdx" class="greeting-item">
                            <div class="greeting-header">
                                <span class="greeting-label">{{ gIdx === 0 ? (t('label_first_mes') || 'First Message') : '#' + gIdx }}</span>
                                <div class="greeting-actions">
                                    <div class="action-btn" @click="openFsEditor('first_mes', gIdx)">
                                        <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                                    </div>
                                    <div class="action-btn delete" @click="confirmDeleteGreeting(gIdx)">
                                        <svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                                    </div>
                                </div>
                            </div>
                            <div class="greeting-preview" @click="openFsEditor('first_mes', gIdx)">
                                {{ greet || t('placeholder_empty') || 'Empty' }}
                            </div>
                        </div>
                        <div class="add-greeting-btn" @click="addGreeting">
                            <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                            <span>{{ t('action_add_greeting') || 'Add Message' }}</span>
                        </div>
                    </div>

                    <select v-else-if="field.type === 'select'" v-model="item[field.key]" class="vk-select" @change="autoSave" style="width: 100%; padding: 8px; border-radius: 8px; border: 1px solid var(--border-color); background: var(--bg-gray); color: var(--text-black);">
                        <option v-for="opt in field.options" :key="opt.value" :value="opt.value">{{ t(opt.label) || opt.label }}</option>
                    </select>
                    
                    <div v-else-if="field.type === 'info'" class="info-field">
                        {{ field.text || item[field.key] }}
                    </div>

                </div>
                    <slot v-if="sIdx === config.length - 1" name="footer"></slot>
                </div>
            </template>
        </div>
        
    </div>
</template>
<style scoped>
.editor-container {
    height: 100%;
    overflow-y: auto;
    overflow-x: hidden;
}

/* Content Layout */
.editor-content {
    width: 100%;
    box-sizing: border-box;
}

/* Avatar Card */
.menu-group.avatar-card {
    display: flex;
    flex-direction: column;
}

.avatar-wrapper {
    width: 100%;
    aspect-ratio: 1 / 1;
    max-height: 400px;
    position: relative;
    cursor: pointer;
    background-color: var(--bg-gray);
    border-bottom: none;
    border-radius: 20px;
    overflow: hidden;
}

.avatar-img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.avatar-placeholder {
    width: 100%;
    height: 100%;
    background: linear-gradient(135deg, #66ccff 0%, #7996ce 100%);
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 6em;
}

.avatar-overlay-hint {
    position: absolute;
    bottom: 0;
    left: 0;
    width: 100%;
    text-align: center;
    color: rgba(255, 255, 255, 0.9);
    font-size: 14px;
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    pointer-events: none;
    z-index: 2;
    background: linear-gradient(to top, rgba(0,0,0,0.5), transparent);
    padding-bottom: 20px;
    padding-top: 20px;
}

.avatar-header-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    padding: 14px 16px 30px 16px;
    font-size: 14px;
    font-weight: 700;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.9);
    letter-spacing: 0.5px;
    z-index: 2;
    background: linear-gradient(to bottom, rgba(0,0,0,0.5), transparent);
    text-shadow: 0 2px 4px rgba(0,0,0,0.5);
    pointer-events: none;
}

.group-header {
    padding: 14px 16px 10px 16px;
    font-size: 14px;
    font-weight: 700;
    text-transform: uppercase;
    color: var(--vk-blue);
    letter-spacing: 0.5px;
    border-bottom: 1px solid rgba(0,0,0,0.03);
}

body.dark-theme .group-header {
    border-bottom: 1px solid rgba(255,255,255,0.03);
}

.settings-item {
    padding: 16px;
    border-bottom: 1px solid rgba(0,0,0,0.05);
}

body.dark-theme .settings-item {
    border-bottom: 1px solid rgba(255,255,255,0.05);
}

.settings-item:last-child {
    border-bottom: none;
}

/* Field Styles */
.label-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 10px;
}

.label-row label {
    margin-bottom: 0;
    font-weight: 500;
    font-size: 15px;
    color: var(--text-black);
}

.expand-btn {
    cursor: pointer;
    color: var(--vk-blue);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 6px;
    margin: -6px;
    border-radius: 50%;
    transition: background-color 0.2s;
}

.expand-btn:hover {
    background-color: rgba(121, 150, 206, 0.1);
}

.expand-btn svg {
    width: 22px;
    height: 22px;
    fill: currentColor;
}

.info-field {
    padding: 4px 0;
    color: var(--text-gray);
    font-size: 14px;
    line-height: 1.5;
    white-space: pre-wrap;
}

/* Input Styles Override for Editor */
input[type="text"],
input[type="number"],
textarea,
select {
    width: 100%;
    padding: 10px 12px;
    border-radius: 10px;
    border: 1px solid var(--border-color);
    background-color: rgba(255,255,255,0.5);
    font-size: 15px;
    transition: border-color 0.2s, background-color 0.2s;
}

input[type="text"]:focus,
input[type="number"]:focus,
textarea:focus,
select:focus {
    border-color: var(--vk-blue);
    background-color: #fff;
    outline: none;
}

body.dark-theme input[type="text"],
body.dark-theme input[type="number"],
body.dark-theme textarea,
body.dark-theme select {
    background-color: rgba(0,0,0,0.2);
    border-color: rgba(255,255,255,0.1);
    color: var(--text-black);
}

body.dark-theme input[type="text"]:focus,
body.dark-theme input[type="number"]:focus,
body.dark-theme textarea:focus,
body.dark-theme select:focus {
    border-color: var(--vk-blue);
    background-color: rgba(0,0,0,0.4);
}

.greeting-list-container {
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.greeting-item {
    background: rgba(0,0,0,0.03);
    border: 1px solid var(--border-color);
    border-radius: 10px;
    padding: 10px;
}

body.dark-theme .greeting-item {
    background: rgba(255,255,255,0.03);
}

.greeting-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 6px;
}

.greeting-label {
    font-size: 13px;
    color: var(--text-gray);
    font-weight: 500;
}

.greeting-actions {
    display: flex;
    align-items: center;
    gap: 8px;
}

.greeting-actions .action-btn {
    cursor: pointer;
    color: var(--vk-blue);
    opacity: 0.8;
}

.greeting-actions .action-btn:hover {
    opacity: 1;
}

.greeting-actions .action-btn.delete {
    color: #ff4444;
}

.greeting-actions .action-btn svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.greeting-preview {
    font-size: 14px;
    color: var(--text-black);
    white-space: pre-wrap;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    line-clamp: 3;
    -webkit-box-orient: vertical;
    overflow: hidden;
    cursor: pointer;
    line-height: 1.4;
    opacity: 0.9;
}

.greeting-preview:hover {
    opacity: 1;
}

.add-greeting-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 12px;
    background: rgba(121, 150, 206, 0.1);
    border-radius: 10px;
    cursor: pointer;
    color: var(--vk-blue);
    font-weight: 500;
    transition: background 0.2s;
}

.add-greeting-btn:hover {
    background: rgba(121, 150, 206, 0.15);
}

.add-greeting-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}
</style>