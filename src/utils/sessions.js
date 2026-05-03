import { db, markSyncDeletedEntry } from '@/utils/db.js';
import { replaceMacros } from '@/utils/macroEngine.js';

// Helper to ensure data structure exists
export async function getChatData(charId) {
    return await db.getChat(charId);
}

export async function createNewSession(charId) {
    return await db.createSession(charId);
}

export async function deleteSession(charId, sessionId) {
    await db.deleteSession(charId, sessionId);
    await db.patchChatData(charId, (data) => {
        if (data.authorsNotes && Object.prototype.hasOwnProperty.call(data.authorsNotes, sessionId)) {
            delete data.authorsNotes[sessionId];
        }
    });

    const refreshed = await db.get(`gz_chat_${charId}`);
    if (!refreshed || !refreshed.sessions || Object.keys(refreshed.sessions).length === 0) {
        await markSyncDeletedEntry('chat', charId);
    }

    const data = await db.getChat(charId);
    return data.currentId;
}

export async function switchSession(charId, sessionId) {
    await db.patchChatData(charId, (data) => {
        if (data.sessions[sessionId]) {
            data.currentId = sessionId;
        }
    });
    const data = await db.getChat(charId);
    return data.currentId;
}

export async function renameSession(charId, sessionId, newName) {
    await db.patchChatData(charId, (data) => {
        if (!data.sessionNames) data.sessionNames = {};
        data.sessionNames[sessionId] = newName;
    });
}

export function getAllGreetings(char, persona) {
    if (!char) return [];
    let greetings = [char.first_mes];
    if (char.alternate_greetings && Array.isArray(char.alternate_greetings)) {
        greetings.push(...char.alternate_greetings);
    }
    greetings = greetings.filter(g => g);
    if (persona) {
        return greetings.map(g => replaceMacros(g, char, persona));
    }
    return greetings;
}
