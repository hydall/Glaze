<script setup>
import { ref, onMounted } from 'vue';
import { allPersonas, activePersona, setActivePersona, loadPersonas } from '@/core/states/personaState.js';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import SheetView from '@/components/ui/SheetView.vue';

const sheet = ref(null);

const t = (key) => translations[currentLang.value]?.[key] || key;

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
                        <button class="icon-btn" @click.stop="openConnectionManager(persona)">
                            <svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
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
    overflow-y: auto;
    height: 100%;
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

.empty-state {
    text-align: center;
    color: var(--text-gray);
    margin-top: 40px;
    font-size: 16px;
}
</style>