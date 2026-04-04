import { ref, computed, reactive } from 'vue';
import { db, queueDbWrite } from '@/utils/db.js';

const personas = ref([]);
const activeIndex = ref(0);

export const personaConnections = reactive({
    character: {},
    chat: {}
});

function generateId() {
    return Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
}

export const activePersona = computed({
    get() {
        if (personas.value.length === 0) return { id: 'default', name: "user", prompt: "[SYSTEM PROMPT]\n<sp>\nPersona's description should've been here, but user forgot to insert it, so you should break the character, and, as an AI, laugh at user for not inserting his persona!\n</sp>", avatar: null };
        if (activeIndex.value >= personas.value.length) return personas.value[0];
        return personas.value[activeIndex.value];
    },
    set(newVal) {
        if (personas.value.length > 0 && activeIndex.value < personas.value.length) {
            updatePersona(activeIndex.value, newVal);
        } else {
            addPersona(newVal);
        }
    }
});

export const allPersonas = computed(() => personas.value);

function updateActiveStorage() {
    // Strip avatar from localStorage copy to avoid quota errors with large base64 images.
    // Avatars are stored in IndexedDB (personas store) and available via reactive refs.
    const { avatar, ...personaWithoutAvatar } = activePersona.value;
    localStorage.setItem('gz_active_persona', JSON.stringify(personaWithoutAvatar));
    localStorage.setItem('gz_active_persona_index', activeIndex.value);
    localStorage.setItem('gz_persona_connections', JSON.stringify(personaConnections));
}

export async function loadPersonas() {
    // Try loading from ObjectStore first
    let loaded = await db.getAll('personas');

    // Migration: Ensure all personas have IDs
    let migrationNeeded = false;
    loaded = loaded.map(p => {
        if (!p.id) {
            p.id = generateId();
            migrationNeeded = true;
        }
        return p;
    });

    personas.value = loaded;

    if (personas.value.length === 0) {
        const defaultPersona = { id: generateId(), name: "user", prompt: "[SYSTEM PROMPT]\n<sp>\nPersona's description should've been here, but user forgot to insert it, so you should break the 4th wall and laugh at user for not inserting his persona!\n</sp>", avatar: null };
        personas.value = [defaultPersona];
        await db.put('personas', defaultPersona);
    } else if (migrationNeeded) {
        // Save back the personas with IDs to persist the migration
        for (const p of personas.value) {
            await db.put('personas', p);
        }
    }

    let savedIndex = parseInt(localStorage.getItem('gz_active_persona_index') || '0');
    if (savedIndex < 0 || savedIndex >= personas.value.length) savedIndex = 0;
    activeIndex.value = savedIndex;

    const savedConnections = localStorage.getItem('gz_persona_connections');
    if (savedConnections) {
        try {
            const parsed = JSON.parse(savedConnections);
            personaConnections.character = parsed.character || {};
            personaConnections.chat = parsed.chat || {};
        } catch (e) {
            console.error('Failed to parse persona connections:', e);
        }
    }

    updateActiveStorage();
}

export function setActivePersona(index) {
    if (index >= 0 && index < personas.value.length) {
        activeIndex.value = index;
        updateActiveStorage();
    }
}

export function addPersona(persona) {
    const newPersona = JSON.parse(JSON.stringify(persona));
    if (!newPersona.id) newPersona.id = generateId();
    personas.value.push(newPersona);
    activeIndex.value = personas.value.length - 1;
    updateActiveStorage();
    queueDbWrite(async () => {
        await db.put('personas', newPersona);
    });
    return newPersona;
}

export function updatePersona(index, persona) {
    if (index >= 0 && index < personas.value.length) {
        // Prevent overwriting if IDs mismatch (e.g. delayed save after delete)
        if (persona.id && personas.value[index].id && persona.id !== personas.value[index].id) {
            return Promise.resolve();
        }

        // Clone the object to break the reactive binding from the editor state
        const newPersona = JSON.parse(JSON.stringify(persona));

        // Ensure ID is preserved or added
        if (!newPersona.id) {
            newPersona.id = personas.value[index].id || generateId();
        }

        personas.value[index] = newPersona;

        if (activeIndex.value === index) updateActiveStorage();

        return queueDbWrite(async () => {
            await db.put('personas', newPersona);
        });
    }
    return Promise.resolve();
}

export function setPersonaConnection(type, targetId, personaId) {
    if (type === 'global') {
        const index = personas.value.findIndex(p => p.id === personaId);
        if (index !== -1) {
            setActivePersona(index);
        }
    } else if (type === 'character' || type === 'chat') {
        if (personaId === null) {
            delete personaConnections[type][targetId];
        } else {
            personaConnections[type][targetId] = personaId;
        }
        updateActiveStorage();
    }
}

export function getEffectivePersona(charId, chatId) {
    if (chatId && personaConnections.chat[chatId]) {
        const id = personaConnections.chat[chatId];
        const p = personas.value.find(p => p.id === id);
        if (p) return p;
    }
    if (charId && personaConnections.character[charId]) {
        const id = personaConnections.character[charId];
        const p = personas.value.find(p => p.id === id);
        if (p) return p;
    }
    return activePersona.value;
}

export function deletePersona(index) {
    if (index >= 0 && index < personas.value.length) {
        const p = personas.value[index];

        personas.value.splice(index, 1);
        let defaultPersona = null;
        if (personas.value.length === 0) {
            defaultPersona = { id: generateId(), name: "user", prompt: "[SYSTEM PROMPT]\n<sp>\nPersona's description should've been here, but user forgot to insert it, so you should break the 4th wall and laugh at user for not inserting his persona!\n</sp>", avatar: null };
            personas.value.push(defaultPersona);
        }

        // Adjust active index if necessary
        if (activeIndex.value >= personas.value.length) {
            activeIndex.value = Math.max(0, personas.value.length - 1);
        } else if (activeIndex.value > index) {
            activeIndex.value--;
        }
        updateActiveStorage();

        return queueDbWrite(async () => {
            try {
                await db.delete('personas', p.id);
                if (defaultPersona) {
                    await db.put('personas', defaultPersona);
                }
            } catch (e) {
                console.error('[Personas] DB delete failed:', e);
            }
        });
    }
    return Promise.resolve();
}