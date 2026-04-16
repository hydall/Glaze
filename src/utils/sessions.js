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
    const data = await db.getChat(charId);

    // Also cleanup authors notes if exists
    if (data.authorsNotes && Object.prototype.hasOwnProperty.call(data.authorsNotes, sessionId)) {
        delete data.authorsNotes[sessionId];
        await db.saveChat(charId, data);
    }

    const refreshed = await db.get(`gz_chat_${charId}`);
    if (!refreshed || !refreshed.sessions || Object.keys(refreshed.sessions).length === 0) {
        await markSyncDeletedEntry('chat', charId);
    }

    return data.currentId;
}

export async function switchSession(charId, sessionId) {
    const data = await db.getChat(charId);

    if (data.sessions[sessionId]) {
        data.currentId = sessionId;
        await db.saveChat(charId, data);
    }
    return data.currentId;
}

export async function renameSession(charId, sessionId, newName) {
    const data = await db.getChat(charId);
    if (!data.sessionNames) data.sessionNames = {};
    data.sessionNames[sessionId] = newName;
    await db.saveChat(charId, data);
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
