<script setup>
import { ref, computed, onMounted } from 'vue';
import { allPersonas, activePersona, setActivePersona, loadPersonas, personaConnections } from '@/core/states/personaState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import SheetView from '@/components/ui/SheetView.vue';
import HelpTip from '@/components/ui/HelpTip.vue';

const sheet = ref(null);

const props = defineProps({
    activeChatChar: { type: Object, default: null }
});

const t = (key) => translations[currentLang.value]?.[key] || key;

const contextCharId = computed(() => props.activeChatChar?.id || null);
const contextChatId = computed(() => {
    const id = props.activeChatChar?.id;
    const sid = props.activeChatChar?.sessionId;
    if (!id) return null;
    return sid ? `${id}_${sid}` : null;
});

function getPersonaConnectionType(personaId) {
    if (contextChatId.value && personaConnections?.chat?.[contextChatId.value] === personaId) return 'chat';
    if (contextCharId.value && personaConnections?.character?.[contextCharId.value] === personaId) return 'character';
    if (activePersona.value?.id === personaId) return 'global';
    return null;
}

const openEditor = (index) => {
    window.dispatchEvent(new CustomEvent('open-persona-editor', {
        detail: {
            index: index,
            persona: index === -1 ? null : allPersonas.value[index]
        }
    }));
};

const openConnectionManager = (persona) => {
    window.dispatchEvent(new CustomEvent('open-connections', { detail: { type: 'persona', id: persona.id, name: persona.name } }));
};

const selectPersona = (index) => {
    setActivePersona(index);
};

const getAvatar = (p) => {
    if (p.avatar) return p.avatar;
    return null;
};

const getInitial = (p) => {
    return (p.name && p.name[0]) ? p.name[0].toUpperCase() : "?";
};

const open = () => sheet.value?.open();
const close = () => sheet.value?.close();

defineExpose({ open, close });

onMounted(() => {
    loadPersonas();
});
</script>

<template>
    <SheetView ref="sheet" :fit-content="false" :title="t('tab_personas') || 'Personas'" :actions="[{ icon: '<svg viewBox=\'0 0 24 24\'><path d=\'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z\'/></svg>', onClick: () => openEditor(-1) }]">
        <template #header-title>
            <HelpTip term="persona" />
        </template>
        <div class="view-content">
            <div class="personas-list">
                <div v-if="!allPersonas || allPersonas.length === 0" class="empty-state">
                    {{ t('no_characters') || 'No personas' }}
                </div>
                <div 
                    v-for="(persona, index) in allPersonas" 
                    :key="index"
                    class="persona-item"
                    :class="{ active: activePersona === persona }"
                    @click="selectPersona(index)"
                >
                    <div class="persona-avatar">
                        <img v-if="getAvatar(persona)" :src="getAvatar(persona)" />
                        <div v-else class="avatar-placeholder">{{ getInitial(persona) }}</div>
                    </div>
                    <div class="persona-info">
                        <div class="persona-name">{{ persona.name }}</div>
                        <div class="persona-prompt">{{ persona.prompt || t('no_prompt') || 'No prompt' }}</div>
                    </div>
                    <div class="persona-actions">
                        <button class="activation-btn" :class="getPersonaConnectionType(persona.id) || 'disabled'" @click.stop="openConnectionManager(persona)">
                            <svg viewBox="0 0 24 24"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>
                        </button>
                        <button class="icon-btn" @click.stop="openEditor(index)">
                            <svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                        </button>
                    </div>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
/* Remove unused legacy styles since SheetView handles this */

.view-content {
    padding: 16px;
    box-sizing: border-box;
}

.personas-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

.persona-item {
    display: flex;
    align-items: center;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-color, rgba(0,0,0,0.1));
    border-radius: 16px;
    padding: 12px;
    cursor: pointer;
    transition: background-color 0.2s, border-color 0.2s;
}

.persona-item.active {
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-color: var(--vk-blue);
}

.persona-avatar {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    overflow: hidden;
    flex-shrink: 0;
    margin-right: 16px;
    background-color: var(--vk-blue);
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 20px;
}

.persona-avatar img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.persona-info {
    flex: 1;
    min-width: 0;
}

.persona-name {
    font-weight: 600;
    font-size: 16px;
    margin-bottom: 4px;
}

.persona-prompt {
    font-size: 13px;
    color: var(--text-gray);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.persona-actions {
    margin-left: 12px;
    display: flex;
    gap: 4px;
}

.icon-btn {
    background: transparent;
    border: none;
    color: var(--accent-color, var(--vk-blue));
    padding: 8px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
}

.icon-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.activation-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    color: var(--text-gray);
    background: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
    transition: all 0.2s;
}

.activation-btn:active {
    transform: scale(0.9);
    opacity: 0.8;
}

.activation-btn svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
}

.activation-btn.global { color: #34c759; }
.activation-btn.character { color: #af52de; }
.activation-btn.chat { color: #ff9500; }
.activation-btn.disabled { opacity: 0.5; }

.empty-state {
    text-align: center;
    color: var(--text-gray);
    margin-top: 40px;
    font-size: 16px;
}
</style>