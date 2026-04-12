<script setup>
import { ref, computed, onMounted } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import HelpTip from '@/components/ui/HelpTip.vue';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { lorebookState, setLorebookActivation } from '@/core/states/lorebookState.js';
import { presetState, setPresetConnection } from '@/core/states/presetState.js';
import { personaConnections, setPersonaConnection, activePersona, loadPersonas } from '@/core/states/personaState.js';
import { db } from '@/utils/db.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';

const t = (key) => translations[currentLang.value]?.[key] || key;

const sheet = ref(null);
const itemId = ref('');
const itemName = ref('');
const itemType = ref('lorebook'); // 'lorebook' | 'preset' | 'persona'
const activeCharContext = ref(null);

const allCharacters = ref([]);
const allSessions = ref([]);

const contextCharId = computed(() => activeCharContext.value?.id || null);
const contextChatId = computed(() => {
    if (!activeCharContext.value?.id) return null;
    const sid = activeCharContext.value.sessionId;
    return `${activeCharContext.value.id}_${sid || ''}`.replace(/_$/, '');
});

const sheetTitle = computed(() => itemName.value || t('header_connections') || 'Connections');

// --- Lorebook helper ---
const lb = computed(() =>
    itemType.value === 'lorebook'
        ? lorebookState.lorebooks.find((l) => l.id === itemId.value) || null
        : null
);

// --- Global toggle ---
function isGlobalActive() {
    if (itemType.value === 'lorebook') return !!lb.value?.enabled;
    if (itemType.value === 'preset') return presetState.globalPresetId === itemId.value;
    if (itemType.value === 'persona') return activePersona.value?.id === itemId.value;
    return false;
}

function toggleGlobal() {
    if (itemType.value === 'lorebook') {
        if (lb.value) lb.value.enabled = !lb.value.enabled;
    } else if (itemType.value === 'preset') {
        if (!isGlobalActive()) setPresetConnection('global', null, itemId.value);
        else setPresetConnection('global', null, 'default');
    } else if (itemType.value === 'persona') {
        if (!isGlobalActive()) setPersonaConnection('global', null, itemId.value);
        else setPersonaConnection('global', null, null);
    }
}

// --- Character connections ---
function getCharConnections() {
    const res = [];
    if (itemType.value === 'lorebook') {
        const map = lorebookState.activations?.character || {};
        Object.entries(map).forEach(([charId, ids]) => {
            if (Array.isArray(ids) && ids.includes(itemId.value)) {
                const char = allCharacters.value.find((c) => c.id === charId);
                res.push({ id: charId, name: char?.name || charId });
            }
        });
    } else if (itemType.value === 'preset') {
        Object.entries(presetState.connections?.character || {}).forEach(([charId, presetId]) => {
            if (presetId === itemId.value) {
                const char = allCharacters.value.find((c) => c.id === charId);
                res.push({ id: charId, name: char?.name || charId });
            }
        });
    } else if (itemType.value === 'persona') {
        Object.entries(personaConnections?.character || {}).forEach(([charId, personaId]) => {
            if (personaId === itemId.value) {
                const char = allCharacters.value.find((c) => c.id === charId);
                res.push({ id: charId, name: char?.name || charId });
            }
        });
    }
    return res;
}

function isCharConnected(charId) {
    if (itemType.value === 'lorebook') return !!lorebookState.activations?.character?.[charId]?.includes(itemId.value);
    if (itemType.value === 'preset') return presetState.connections?.character?.[charId] === itemId.value;
    if (itemType.value === 'persona') return personaConnections?.character?.[charId] === itemId.value;
    return false;
}

function addCharConnection() {
    showBottomSheet({
        title: t('sheet_title_select_char') || 'Select character',
        cardItems: allCharacters.value.map((c) => ({
            label: c.name,
            sublabel: c.scenario || c.description || '',
            icon: `<div style="width:100%;height:100%;border-radius:inherit;background:${c.color || 'var(--vk-blue)'};display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;">${(c.name && c.name[0]) ? c.name[0].toUpperCase() : '?'}</div>`,
            onClick: () => {
                if (!isCharConnected(c.id)) {
                    if (itemType.value === 'lorebook') setLorebookActivation(itemId.value, 'character', c.id);
                    else if (itemType.value === 'preset') setPresetConnection('character', c.id, itemId.value);
                    else if (itemType.value === 'persona') setPersonaConnection('character', c.id, itemId.value);
                }
                closeBottomSheet();
            }
        }))
    });
}

function removeCharConnection(charId) {
    if (itemType.value === 'lorebook') { if (isCharConnected(charId)) setLorebookActivation(itemId.value, 'character', charId); }
    else if (itemType.value === 'preset') setPresetConnection('character', charId, null);
    else if (itemType.value === 'persona') setPersonaConnection('character', charId, null);
}

// --- Chat connections ---
function getChatConnections() {
    const res = [];
    if (itemType.value === 'lorebook') {
        const map = lorebookState.activations?.chat || {};
        Object.entries(map).forEach(([chatId, ids]) => {
            if (Array.isArray(ids) && ids.includes(itemId.value)) {
                const sess = allSessions.value.find((s) => s.id === chatId);
                res.push({ id: chatId, charName: sess?.charName || 'Chat', sessionId: sess?.sessionId || chatId.split('_').pop() });
            }
        });
    } else if (itemType.value === 'preset') {
        Object.entries(presetState.connections?.chat || {}).forEach(([chatId, presetId]) => {
            if (presetId === itemId.value) {
                const sess = allSessions.value.find((s) => s.id === chatId);
                res.push({ id: chatId, charName: sess?.charName || 'Chat', sessionId: sess?.sessionId || chatId.split('_').pop() });
            }
        });
    } else if (itemType.value === 'persona') {
        Object.entries(personaConnections?.chat || {}).forEach(([chatId, personaId]) => {
            if (personaId === itemId.value) {
                const sess = allSessions.value.find((s) => s.id === chatId);
                res.push({ id: chatId, charName: sess?.charName || 'Chat', sessionId: sess?.sessionId || chatId.split('_').pop() });
            }
        });
    }
    return res;
}

function isChatConnected(chatId) {
    if (itemType.value === 'lorebook') return !!lorebookState.activations?.chat?.[chatId]?.includes(itemId.value);
    if (itemType.value === 'preset') return presetState.connections?.chat?.[chatId] === itemId.value;
    if (itemType.value === 'persona') return personaConnections?.chat?.[chatId] === itemId.value;
    return false;
}

function addChatConnection() {
    showBottomSheet({
        title: t('sheet_title_select_chat') || 'Select chat',
        cardItems: allSessions.value.map((s) => ({
            label: s.charName,
            sublabel: `#${s.sessionId}`,
            icon: `<div style="width:100%;height:100%;border-radius:inherit;background:var(--vk-blue);display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;">${(s.charName && s.charName[0]) ? s.charName[0].toUpperCase() : '?'}</div>`,
            onClick: () => {
                if (!isChatConnected(s.id)) {
                    if (itemType.value === 'lorebook') setLorebookActivation(itemId.value, 'chat', s.id);
                    else if (itemType.value === 'preset') setPresetConnection('chat', s.id, itemId.value);
                    else if (itemType.value === 'persona') setPersonaConnection('chat', s.id, itemId.value);
                }
                closeBottomSheet();
            }
        }))
    });
}

function removeChatConnection(chatId) {
    if (itemType.value === 'lorebook') { if (isChatConnected(chatId)) setLorebookActivation(itemId.value, 'chat', chatId); }
    else if (itemType.value === 'preset') setPresetConnection('chat', chatId, null);
    else if (itemType.value === 'persona') setPersonaConnection('chat', chatId, null);
}

// --- Data loading ---
async function loadPickerData() {
    const [chars, chatsData] = await Promise.all([
        db.getAll('characters'),
        db.getChats()
    ]);

    allCharacters.value = chars || [];

    const sessions = [];
    if (chatsData) {
        Object.keys(chatsData).forEach((charId) => {
            const char = allCharacters.value.find((c) => c.id === charId);
            const data = chatsData[charId];
            const sess = data?.sessions || (Array.isArray(data) ? { 1: data } : {});
            Object.keys(sess || {}).forEach((sid) => {
                sessions.push({
                    id: `${charId}_${sid}`,
                    charName: char?.name || charId,
                    sessionId: sid
                });
            });
        });
    }
    allSessions.value = sessions;
}

async function open(type, id, name, contextChar = null) {
    itemType.value = type || 'lorebook';
    itemId.value = id || '';
    itemName.value = name || '';
    activeCharContext.value = contextChar;
    await loadPickerData();
    if (itemType.value === 'persona') loadPersonas();
    sheet.value?.open();
}

function close() {
    sheet.value?.close();
}

onMounted(() => {
    loadPickerData();
});

defineExpose({ open, close });
</script>

<template>
    <SheetView ref="sheet" :z-index="11010" :title="sheetTitle" fit-content>
        <template #header-title>
            <HelpTip term="connections" />
        </template>
        <div class="lbc-body">

            <div class="lbc-card">
                <div class="lbc-row">
                    <div class="lbc-row-label">
                        <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
                        {{ t('label_global_enabled') || 'Включить для всех чатов' }}
                    </div>
                    <div class="lbc-toggle" :class="{ active: isGlobalActive() }" @click="toggleGlobal">
                        <div class="lbc-toggle-thumb"></div>
                    </div>
                </div>
            </div>

            <div class="lbc-card">
                <div class="lbc-section-head">
                    <div class="lbc-section-title">{{ t('lbc_section_characters') || 'Включить для персонажей' }}</div>
                    <button class="lbc-add" @click="addCharConnection">
                        <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                    </button>
                </div>
                <div class="lbc-chips">
                    <div v-for="c in getCharConnections()" :key="c.id" class="lbc-chip char">
                        <span>{{ c.name }}</span>
                        <button class="lbc-chip-x" @click="removeCharConnection(c.id)">
                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                        </button>
                    </div>
                    <div v-if="getCharConnections().length === 0" class="lbc-empty">{{ t('none') || 'None' }}</div>
                </div>
            </div>

            <div class="lbc-card">
                <div class="lbc-section-head">
                    <div class="lbc-section-title">{{ t('lbc_section_chats') || 'Включить для чатов' }}</div>
                    <button class="lbc-add" @click="addChatConnection">
                        <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
                    </button>
                </div>
                <div class="lbc-chips">
                    <div v-for="c in getChatConnections()" :key="c.id" class="lbc-chip chat">
                        <span>{{ c.charName }} #{{ c.sessionId }}</span>
                        <button class="lbc-chip-x" @click="removeChatConnection(c.id)">
                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                        </button>
                    </div>
                    <div v-if="getChatConnections().length === 0" class="lbc-empty">{{ t('none') || 'None' }}</div>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.lbc-body {
    padding: 10px 12px 24px;
    display: flex;
    flex-direction: column;
    gap: 10px;
}

.lbc-card {
    background: rgba(30, 30, 32, var(--element-opacity, 0.7));
    backdrop-filter: blur(var(--element-blur, 10px));
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 16px;
    padding: 12px;
}

.lbc-section-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    margin-bottom: 10px;
}

.lbc-section-title {
    font-size: 12px;
    font-weight: 800;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    color: var(--text-gray);
}

.lbc-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
}

.lbc-row-label {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 13px;
    font-weight: 700;
    color: var(--text-black);
}

.lbc-row-label svg {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
}

.lbc-toggle {
    width: 44px;
    height: 24px;
    background: var(--border-color, rgba(0,0,0,0.1));
    border-radius: 12px;
    position: relative;
    cursor: pointer;
    transition: background 0.3s;
}

.lbc-toggle.active {
    background: var(--vk-green, #34c759);
}

.lbc-toggle-thumb {
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    position: absolute;
    top: 2px;
    left: 2px;
    transition: transform 0.3s;
    box-shadow: 0 1px 3px rgba(0,0,0,0.2);
}

.lbc-toggle.active .lbc-toggle-thumb {
    transform: translateX(20px);
}

.lbc-add {
    width: 26px;
    height: 26px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--vk-blue-rgb), 0.12);
    color: var(--vk-blue);
    border: none;
    border-radius: 8px;
    cursor: pointer;
    padding: 0;
}

.lbc-add svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
}

.lbc-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    min-height: 26px;
}

.lbc-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 8px 5px 10px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 600;
}

.lbc-chip.char { background: rgba(175, 82, 222, 0.12); color: #af52de; }
.lbc-chip.chat { background: rgba(255, 149, 0, 0.12); color: #ff9500; }

.lbc-chip-x {
    width: 18px;
    height: 18px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    cursor: pointer;
    color: currentColor;
    opacity: 0.6;
    padding: 0;
}

.lbc-chip-x svg {
    width: 12px;
    height: 12px;
    fill: currentColor;
}

.lbc-empty {
    font-size: 12px;
    color: var(--text-gray);
    opacity: 0.5;
    font-style: italic;
    line-height: 26px;
}
</style>
