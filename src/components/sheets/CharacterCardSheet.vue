<!-- src/components/sheets/CharacterCardSheet.vue -->
<script setup>
import { ref, computed } from 'vue';
import SheetView from '@/components/ui/SheetView.vue';
import Editor from '@/components/editors/GenericEditor.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { db } from '@/utils/db.js';
import HelpTip from '@/components/ui/HelpTip.vue';

const sheet = ref(null);
const character = ref({});
const t = (key) => translations[currentLang.value]?.[key] || key;

const config = computed(() => [
    {
        title: 'section_basic_info',
        fields: [
            { key: 'name', label: 'label_name', type: 'text', placeholder: 'placeholder_enter_name' },
            { key: 'description', label: 'label_description', type: 'textarea', rows: 4, placeholder: 'placeholder_char_desc', expandable: true },
            { key: 'first_mes', label: 'label_first_mes', type: 'greeting_list', rows: 4, placeholder: 'placeholder_greeting' }
        ]
    },
    {
        title: 'section_personality',
        fields: [
            { key: 'personality', label: 'label_personality', type: 'textarea', rows: 4, expandable: true },
            { key: 'scenario', label: 'label_scenario', type: 'textarea', rows: 3, expandable: true },
            { key: 'mes_example', label: 'label_mes_example', type: 'textarea', rows: 6, expandable: true }
        ]
    },
    {
        title: 'section_info',
        fields: [
            { key: 'creator_notes', label: 'label_creator_notes', type: 'textarea', rows: 2 },
            { key: 'tags', label: 'label_tags', type: 'tags' }
        ]
    }
]);

function open(char) {
    if (char) {
        // Clone the object to avoid mutating the original before saving
        character.value = JSON.parse(JSON.stringify(char));
    }
    sheet.value?.open();
}

function close() {
    sheet.value?.close();
}

async function onSave(newVal) {
    if (newVal.id) {
        // Use the correct method to update the character in the proper object store
        const charToSave = { ...newVal };
        // Clean up session-specific properties to prevent polluting the character definition
        delete charToSave.sessionId;
        delete charToSave.authors_note;
        delete charToSave.summary;
        
        await db.saveCharacter(charToSave);
        // Notify the app that a character was updated
        window.dispatchEvent(new CustomEvent('character-updated', { detail: { character: charToSave } }));
    }
}

function handleOpenFs(payload) {
    window.dispatchEvent(new CustomEvent('open-fs-request', { detail: payload }));
}

defineExpose({ open, close });
</script>

<template>
    <SheetView ref="sheet" :title="t('block_char_card')">
        <template #header-title>
            <HelpTip term="character" />
        </template>
        <Editor 
            :model-value="character" 
            :config="config" 
            show-avatar 
            avatar-field="avatar"
            @save="onSave"
            @update:modelValue="(val) => character = val"
            @open-fs="handleOpenFs"
        />
    </SheetView>
</template>

<style scoped>
.sheet-header-wrapper {
    height: 56px;
    display: flex;
    align-items: center;
    justify-content: flex-start;
    padding: 0 16px;
    border-bottom: 1px solid var(--border-color);
    flex-shrink: 0;
}
.sheet-header-title {
    font-weight: 600;
    font-size: 17px;
}
</style>
