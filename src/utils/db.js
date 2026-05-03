import { ensureSessionMemoryBook } from '@/core/services/memorySchema.js';
import { showToast } from '@/core/states/toastState.js';

const DB_NAME = 'SillyCradleDB';
const DB_VERSION = 8;
const STORE_KEYVALUE = 'keyvalue';
const STORE_CHARACTERS = 'characters';
const STORE_PERSONAS = 'personas';
const STORE_EMBEDDINGS = 'embeddings';
const SYNC_DELETIONS_KEY = 'gz_sync_deleted_entries';

function toPlain(data) {
    return JSON.parse(JSON.stringify(data));
}

function stripHeavyFields(message) {
    if (!message || typeof message !== 'object') return message;
    if (message.persona && typeof message.persona === 'object') {
        const { id, name } = message.persona;
        message.persona = { id: id || null, name: name || null };
    }
    if (Array.isArray(message.triggeredLorebooks)) {
        message.triggeredLorebooks = message.triggeredLorebooks.map(lb => ({
            id: lb.id,
            name: lb.name || lb.comment,
            lorebookName: lb.lorebookName,
            lorebookId: lb.lorebookId,
            _source: lb._source
        }));
    }
    if (Array.isArray(message.triggeredMemories)) {
        message.triggeredMemories = message.triggeredMemories.map(mem => ({
            id: mem.id,
            name: mem.name || mem.title
        }));
    }
    return message;
}

function ensureMessageMetadata(message) {
    if (!message || typeof message !== 'object') return message;
    if (!message.id) {
        message.id = `legacy_${message.timestamp || Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
    }
    if (!Array.isArray(message.contextRefs)) {
        message.contextRefs = [];
    }
    if (!message.memoryCoverage || typeof message.memoryCoverage !== 'object') {
        message.memoryCoverage = {
            entryIds: [],
            needsRebuild: false,
            stale: false
        };
    } else {
        if (!Array.isArray(message.memoryCoverage.entryIds)) {
            message.memoryCoverage.entryIds = [];
        }
        if (typeof message.memoryCoverage.needsRebuild !== 'boolean') {
            message.memoryCoverage.needsRebuild = false;
        }
        if (typeof message.memoryCoverage.stale !== 'boolean') {
            message.memoryCoverage.stale = false;
        }
    }
    return message;
}

function normalizeChatData(chatData) {
    if (!chatData || typeof chatData !== 'object') {
        return { currentId: 1, sessions: { 1: [] }, memoryBooks: {} };
    }

    if (!chatData.sessions || typeof chatData.sessions !== 'object') {
        chatData.sessions = { 1: [] };
    }

    for (const [sessionId, messages] of Object.entries(chatData.sessions)) {
        const safeMessages = Array.isArray(messages) ? messages.filter(Boolean) : [];
        safeMessages.forEach(msg => {
            ensureMessageMetadata(msg);
            stripHeavyFields(msg);
        });
        chatData.sessions[sessionId] = safeMessages;
    }

    if (!chatData.memoryBooks || typeof chatData.memoryBooks !== 'object') {
        chatData.memoryBooks = {};
    }

    for (const sessionId of Object.keys(chatData.sessions)) {
        ensureSessionMemoryBook(chatData, sessionId);
    }

    return chatData;
}

// Global write queue — serializes all IndexedDB writes to prevent race conditions
let _dbWriteQueue = Promise.resolve();

export function queueDbWrite(fn) {
    const resultPromise = _dbWriteQueue.then(fn);
    _dbWriteQueue = resultPromise.catch(err => {
        console.error('[DB] Write queue error:', err);
    });
    return resultPromise;
}

export function flushDbWriteQueue() {
    return _dbWriteQueue;
}

export const db = {
    open: () => {
        return new Promise((resolve, reject) => {
            const request = indexedDB.open(DB_NAME, DB_VERSION);
            request.onupgradeneeded = (e) => {
                const db = e.target.result;
                const transaction = e.target.transaction;

                if (!db.objectStoreNames.contains(STORE_KEYVALUE)) {
                    db.createObjectStore(STORE_KEYVALUE);
                }

                // Migration for characters to use ID instead of name
                if (db.objectStoreNames.contains(STORE_CHARACTERS)) {
                    const store = transaction.objectStore(STORE_CHARACTERS);
                    if (store.keyPath === 'name') {
                        // Read all data to migrate
                        const req = store.getAll();
                        req.onsuccess = () => {
                            const chars = req.result;
                            const nameToId = {};

                            // Assign IDs and map
                            chars.forEach(c => {
                                if (!c.id) c.id = Date.now().toString(36) + Math.random().toString(36).substr(2);
                                nameToId[c.name] = c.id;
                            });

                            // Recreate store
                            db.deleteObjectStore(STORE_CHARACTERS);
                            const newStore = db.createObjectStore(STORE_CHARACTERS, { keyPath: 'id' });
                            chars.forEach(c => newStore.add(c));

                            // Migrate chats to use IDs
                            const kvStore = transaction.objectStore(STORE_KEYVALUE);
                            const chatsReq = kvStore.get('gz_chats');
                            chatsReq.onsuccess = () => {
                                const chats = chatsReq.result || {};
                                const newChats = {};
                                Object.keys(chats).forEach(name => {
                                    const id = nameToId[name];
                                    if (id) newChats[id] = chats[name];
                                    else newChats[name] = chats[name]; // Keep orphans just in case
                                });
                                kvStore.put(newChats, 'gz_chats');
                            };
                        };
                    }
                } else {
                    db.createObjectStore(STORE_CHARACTERS, { keyPath: 'id' });
                }

                // Migration for personas to use ID instead of name
                if (!db.objectStoreNames.contains(STORE_PERSONAS)) {
                    db.createObjectStore(STORE_PERSONAS, { keyPath: 'id' });
                } else {
                    const store = transaction.objectStore(STORE_PERSONAS);
                    if (store.keyPath === 'name') {
                        const req = store.getAll();
                        req.onsuccess = () => {
                            const items = req.result;

                            // Try to preserve active persona selection
                            let currentActive = null;
                            try {
                                const saved = localStorage.getItem('gz_active_persona');
                                if (saved) currentActive = JSON.parse(saved);
                            } catch (e) { }

                            items.forEach(item => {
                                if (!item.id) item.id = Date.now().toString(36) + Math.random().toString(36).substr(2);
                                // Update active persona in localStorage if it matches
                                if (currentActive && currentActive.name === item.name) {
                                    localStorage.setItem('gz_active_persona', JSON.stringify(item));
                                }
                            });
                            db.deleteObjectStore(STORE_PERSONAS);
                            const newStore = db.createObjectStore(STORE_PERSONAS, { keyPath: 'id' });
                            items.forEach(item => newStore.add(item));
                        };
                    }
                }

                if (!db.objectStoreNames.contains(STORE_EMBEDDINGS)) {
                    db.createObjectStore(STORE_EMBEDDINGS, { keyPath: 'id' });
                }

                // Migration v8: Convert legacy single-vector embeddings to multi-vector format
                if (e.oldVersion < 8 && db.objectStoreNames.contains(STORE_EMBEDDINGS)) {
                    console.log('[DB] Migrating to version 8: multi-vector embeddings');
                    const embStore = transaction.objectStore(STORE_EMBEDDINGS);
                    const getAllReq = embStore.getAll();
                    getAllReq.onsuccess = () => {
                        const allEmbeddings = getAllReq.result || [];
                        let migrated = 0;
                        allEmbeddings.forEach(emb => {
                            if (emb.vector && !emb.vectors) {
                                // Convert legacy single vector to multi-vector format
                                emb.vectors = [{
                                    text: '(legacy full content)',
                                    vector: emb.vector
                                }];
                                emb.vector = null;  // Mark as migrated
                                embStore.put(emb);
                                migrated++;
                            }
                        });
                        console.log(`[DB] Migrated ${migrated} embeddings to multi-vector format`);
                    };
                }
            };
            request.onsuccess = (e) => resolve(e.target.result);
            request.onerror = (e) => reject(e.target.error);
        });
    },
    get: async (key) => {
        const database = await db.open();
        return new Promise((resolve, reject) => {
            const tx = database.transaction(STORE_KEYVALUE, 'readonly');
            const store = tx.objectStore(STORE_KEYVALUE);
            const req = store.get(key);
            req.onsuccess = () => {
                resolve(req.result);
                database.close();
            };
            req.onerror = () => {
                reject(req.error);
                database.close();
            };
        });
    },
    set: async (key, value) => {
        const database = await db.open();
        return new Promise((resolve, reject) => {
            const tx = database.transaction(STORE_KEYVALUE, 'readwrite');
            const store = tx.objectStore(STORE_KEYVALUE);
            const req = store.put(toPlain(value), key);
            tx.oncomplete = () => {
                resolve();
                database.close();
            };
            tx.onerror = () => {
                reject(tx.error);
                database.close();
            };
            req.onerror = () => {
                reject(req.error);
                database.close();
            };
        });
    },
    // Queued version of set — safe for high-frequency writes (e.g. auto-save on typing)
    queuedSet: (key, value) => queueDbWrite(() => db.set(key, value)),
    delete: async (storeName, key) => {
        const database = await db.open();
        return new Promise((resolve, reject) => {
            const tx = database.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            const req = store.delete(key);
            tx.oncomplete = () => {
                resolve();
                database.close();
            };
            tx.onerror = () => {
                reject(tx.error);
                database.close();
            };
            req.onerror = () => {
                reject(req.error);
                database.close();
            };
        });
    },
    // Generic methods for other stores (like characters)
    getAll: async (storeName) => {
        const database = await db.open();
        return new Promise((resolve, reject) => {
            const tx = database.transaction(storeName, 'readonly');
            const store = tx.objectStore(storeName);
            const req = store.getAll();
            req.onsuccess = () => {
                resolve(req.result);
                database.close();
            };
            req.onerror = () => {
                reject(req.error);
                database.close();
            };
        });
    },
    put: async (storeName, value) => {
        const database = await db.open();
        return new Promise((resolve, reject) => {
            const tx = database.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            const req = store.put(toPlain(value));
            tx.oncomplete = () => {
                resolve();
                database.close();
            };
            tx.onerror = () => {
                reject(tx.error);
                database.close();
            };
            req.onerror = () => {
                reject(req.error);
                database.close();
            };
        });
    },
    // Character specific logic
    saveCharacter: async (character, index) => {
        // Ensure ID exists
        if (!character.id) {
            character.id = Date.now().toString(36) + Math.random().toString(36).substr(2);
        }
        if (!character.updatedAt) {
            character.updatedAt = Date.now();
        }
        await db.put(STORE_CHARACTERS, character);
    },
    deleteCharacter: async (id) => {
        if (id) {
            await db.delete(STORE_CHARACTERS, id);
        }
    },
    // Persona specific logic
    savePersona: async (persona, index) => {
        if (!persona.id) {
            persona.id = Date.now().toString(36) + Math.random().toString(36).substr(2);
        }
        if (!persona.updatedAt) {
            persona.updatedAt = Date.now();
        }
        await db.put(STORE_PERSONAS, persona);
    },
    deletePersona: async (index) => {
        const personas = await db.getAll(STORE_PERSONAS);
        if (personas[index]) {
            await db.delete(STORE_PERSONAS, personas[index].id);
        }
    },
    // Embedding specific logic
    getEmbedding: async (id) => {
        const database = await db.open();
        return new Promise((resolve, reject) => {
            const tx = database.transaction(STORE_EMBEDDINGS, 'readonly');
            const store = tx.objectStore(STORE_EMBEDDINGS);
            const req = store.get(id);
            req.onsuccess = () => {
                resolve(req.result);
                database.close();
            };
            req.onerror = () => {
                reject(req.error);
                database.close();
            };
        });
    },
    getAllEmbeddings: async () => {
        return db.getAll(STORE_EMBEDDINGS);
    },
    getEmbeddingsBySource: async (sourceType) => {
        const all = await db.getAll(STORE_EMBEDDINGS);
        return all.filter(e => e.sourceType === sourceType);
    },
    saveEmbedding: async (embeddingRecord) => {
        await db.put(STORE_EMBEDDINGS, embeddingRecord);
    },
    deleteEmbedding: async (id) => {
        await db.delete(STORE_EMBEDDINGS, id);
    },
    deleteEmbeddingsBySource: async (sourceType) => {
        const all = await db.getAll(STORE_EMBEDDINGS);
        const toDelete = all.filter(e => e.sourceType === sourceType);
        const database = await db.open();
        return new Promise((resolve, reject) => {
            const tx = database.transaction(STORE_EMBEDDINGS, 'readwrite');
            const store = tx.objectStore(STORE_EMBEDDINGS);
            for (const item of toDelete) {
                store.delete(item.id);
            }
            tx.oncomplete = () => { database.close(); resolve(); };
            tx.onerror = () => { database.close(); reject(tx.error); };
        });
    },
    // Chat specific logic
    getChats: async () => {
        const database = await db.open();
        try {
            const allChatsMap = await new Promise((resolve, reject) => {
                const tx = database.transaction(STORE_KEYVALUE, 'readwrite');
                const store = tx.objectStore(STORE_KEYVALUE);

                // First, check if legacy monolithic sc_chats exists
                const getLegacyReq = store.get('gz_chats');
                getLegacyReq.onsuccess = () => {
                    const legacyChats = getLegacyReq.result;
                    const hasLegacy = legacyChats && Object.keys(legacyChats).length > 0;

                    // Fetch all granular chats
                    const allChatsMap = {};
                    const cursorReq = store.openCursor();

                    cursorReq.onsuccess = (e) => {
                        const cursor = e.target.result;
                        if (cursor) {
                            if (cursor.key.toString().startsWith('gz_chat_')) {
                                const charId = cursor.key.toString().substring(8);
                                allChatsMap[charId] = cursor.value;
                            }
                            cursor.continue();
                        } else {
                            if (hasLegacy) {
                                const keysToMigrate = Object.keys(legacyChats);
                                for (const charId of keysToMigrate) {
                                    if (!allChatsMap[charId]) {
                                        store.put(legacyChats[charId], `gz_chat_${charId}`);
                                        allChatsMap[charId] = legacyChats[charId];
                                    }
                                }
                                store.delete('gz_chats');
                            }
                            resolve(allChatsMap);
                        }
                    };
                    cursorReq.onerror = () => reject(cursorReq.error);
                };
                getLegacyReq.onerror = () => reject(getLegacyReq.error);
            });

            const fbKeys = [];
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (key && key.startsWith('gz_fb_chat_')) {
                    fbKeys.push(key);
                }
            }
            for (const key of fbKeys) {
                try {
                    const charId = key.substring(11);
                    const fbRaw = localStorage.getItem(key);
                    if (!fbRaw) continue;
                    const fb = JSON.parse(fbRaw);
                    if (!fb._fb) continue;
                    const existing = allChatsMap[charId];
                    if (!existing || !existing.updatedAt || fb._fb > existing.updatedAt) {
                        delete fb._fb;
                        allChatsMap[charId] = normalizeChatData(fb);
                        try {
                            await db.set(`gz_chat_${charId}`, toPlain(allChatsMap[charId]));
                            localStorage.removeItem(key);
                            showToast('Chat data recovered from backup', 2500);
                        } catch (_e) {}
                    }
                } catch (_e) {}
            }

            return allChatsMap;
        } finally {
            database.close();
        }
    },
    getUnread: async () => {
        return (await db.get('gz_unread')) || {};
    },
    getChat: async (charId) => {
        let data = await db.get(`gz_chat_${charId}`);
        if (!data) {
            // Check legacy store as fallback (e.g. if getChats wasn't called yet)
            const legacyChats = await db.get('gz_chats');
            if (legacyChats && legacyChats[charId]) {
                data = legacyChats[charId];
                // Migrate this specific character
                await db.set(`gz_chat_${charId}`, data);
                delete legacyChats[charId];
                if (Object.keys(legacyChats).length === 0) {
                    await db.delete(STORE_KEYVALUE, 'gz_chats');
                } else {
                    await db.set('gz_chats', legacyChats);
                }
            }
        }

        if (!data) {
            data = { currentId: 1, sessions: { 1: [] } };
        }
        data = normalizeChatData(data);
        if (!data.currentId) {
            const ids = Object.keys(data.sessions).map(Number);
            data.currentId = ids.length > 0 ? Math.max(...ids) : 1;
        }

        try {
            const fbRaw = localStorage.getItem(`gz_fb_chat_${charId}`);
            if (fbRaw) {
                const fb = JSON.parse(fbRaw);
                if (fb._fb && (!data.updatedAt || fb._fb > data.updatedAt)) {
                    delete fb._fb;
                    const restored = normalizeChatData(fb);
                    await db.set(`gz_chat_${charId}`, toPlain(restored));
                    try { localStorage.removeItem(`gz_fb_chat_${charId}`); } catch (_e) {}
                    showToast('Chat data recovered from backup', 2500);
                    return restored;
                }
            }
        } catch (_e) {}

        return data;
    },
    saveChat: async (charId, chatData) => {
        const normalized = normalizeChatData(chatData);
        const snapshot = toPlain(normalized);
        try {
            await queueDbWrite(() => db.set(`gz_chat_${charId}`, snapshot));
            try { localStorage.removeItem(`gz_fb_chat_${charId}`); } catch (_e) {}
        } catch (err) {
            console.error('[DB] Chat save failed, saving to localStorage fallback:', err);
            showToast('Chat write failed, backup saved locally', 3000);
            try {
                localStorage.setItem(`gz_fb_chat_${charId}`, JSON.stringify({
                    ...snapshot,
                    _fb: Date.now()
                }));
            } catch (fbErr) {
                console.error('[DB] Fallback save also failed:', fbErr);
            }
            throw err;
        }
    },
    /**
     * Apply a single mutation to chat data in a serialized read-mutate-write cycle.
     * For 2+ mutations with no async work between them, use patchChatDataBatch instead.
     */
    patchChatData: async (charId, patchFn) => {
        return db.patchChatDataBatch(charId, [patchFn]);
    },
    /**
     * Apply multiple mutations to chat data in a single read-mutate-write cycle.
     * All patchFns must be synchronous — no async work between mutations.
     * Reduces IDB reads and eliminates the gap between sequential patches.
     */
    patchChatDataBatch: async (charId, patchFns) => {
        return queueDbWrite(async () => {
            const data = await db.getChat(charId);
            if (!data) return;
            for (const patchFn of patchFns) {
                patchFn(data);
            }
            const normalized = normalizeChatData(data);
            const snapshot = toPlain(normalized);
            try {
                await db.set(`gz_chat_${charId}`, snapshot);
                try { localStorage.removeItem(`gz_fb_chat_${charId}`); } catch (_e) {}
            } catch (err) {
                console.error('[DB] Chat patch failed, saving to localStorage fallback:', err);
                showToast('Chat write failed, backup saved locally', 3000);
                try {
                    localStorage.setItem(`gz_fb_chat_${charId}`, JSON.stringify({
                        ...snapshot,
                        _fb: Date.now()
                    }));
                } catch (fbErr) {
                    console.error('[DB] Fallback save also failed:', fbErr);
                }
                throw err;
            }
        });
    },
    createSession: async (charId) => {
        let data = await db.get(`gz_chat_${charId}`);
        if (!data) {
            const legacyChats = await db.get('gz_chats');
            if (legacyChats && legacyChats[charId]) {
                data = await db.getChat(charId);
            } else {
                data = { currentId: 1, sessions: { 1: [] } };
                await db.saveChat(charId, data);
                return 1;
            }
        }
        if (!data.sessions) {
            data.sessions = { 1: [] };
        }
        if (!data.currentId) {
            const ids = Object.keys(data.sessions).map(Number);
            data.currentId = ids.length > 0 ? Math.max(...ids) : 1;
        }

        const ids = Object.keys(data.sessions).map(Number);
        const nextId = (ids.length > 0 ? Math.max(...ids) : 0) + 1;
        data.currentId = nextId;
        data.sessions[nextId] = [];

        if (!data.sessionDates) data.sessionDates = {};
        data.sessionDates[nextId] = Date.now();

        await db.saveChat(charId, data);
        return nextId;
    },
    deleteSession: async (charId, sessionId) => {
        const data = await db.getChat(charId);
        if (!data || !data.sessions) return;

        delete data.sessions[sessionId];

        // If current session deleted, switch to another or create new
        if (data.currentId === sessionId) {
            const ids = Object.keys(data.sessions).map(Number);
            if (ids.length > 0) {
                data.currentId = Math.max(...ids);
            } else {
                data.currentId = null;
            }
        }

        await db.saveChat(charId, data);
    }
};

// ---------------------------------------------------------------------------
// Sync helpers — bulk read/write for cloud sync operations
// ---------------------------------------------------------------------------

export async function getAllSyncableData() {
    const characters = await db.getAll(STORE_CHARACTERS);
    const personas = await db.getAll(STORE_PERSONAS);
    const chats = await db.getChats();
    const lorebooks = await db.get('gz_lorebooks');
    const apiPresets = await db.get('gz_api_connection_presets');
    const themePresets = await db.get('gz_theme_presets');

    const localStorageData = {};
    const syncKeys = [
        'silly_cradle_presets',
        'silly_cradle_current_preset_id',
        'gz_preset_connections',
        'regex_scripts',
        'gz_active_persona_id',
        'gz_persona_connections'
    ];
    for (const key of syncKeys) {
        const val = localStorage.getItem(key);
        if (val !== null) localStorageData[key] = val;
    }

    return {
        characters,
        personas,
        chats,
        lorebooks: lorebooks || null,
        apiPresets: apiPresets || null,
        themePresets: themePresets || null,
        localStorage: localStorageData
    };
}

export function touchUpdatedAt(entity) {
    entity.updatedAt = Date.now();
    return entity;
}

// ---------------------------------------------------------------------------
// One-time migration: sc_ -> gz_ for both IndexedDB keyvalue store and localStorage
// Runs once; guarded by localStorage flag 'gz_migration_done'.
// ---------------------------------------------------------------------------
export async function migrateScToGz() {
    if (localStorage.getItem('gz_migration_done') === '1') return;

    // --- 1. IndexedDB keyvalue store ---
    try {
        const database = await db.open();
        await new Promise((resolve) => {
            const tx = database.transaction(STORE_KEYVALUE, 'readwrite');
            const store = tx.objectStore(STORE_KEYVALUE);
            const cursorReq = store.openCursor();

            cursorReq.onsuccess = (e) => {
                const cursor = e.target.result;
                if (cursor) {
                    const key = cursor.key.toString();
                    if (key.startsWith('sc_')) {
                        const newKey = 'gz_' + key.slice(3);
                        // Only copy if gz_ key does not already exist
                        const checkReq = store.get(newKey);
                        checkReq.onsuccess = () => {
                            if (checkReq.result === undefined) {
                                store.put(cursor.value, newKey);
                            }
                            // Remove old sc_ key
                            store.delete(key);
                        };
                    }
                    cursor.continue();
                } else {
                    resolve();
                }
            };
            cursorReq.onerror = () => resolve(); // Don't block on error
            tx.oncomplete = () => { database.close(); resolve(); };
            tx.onerror = () => { database.close(); resolve(); };
        });
    } catch (e) {
        console.warn('[migrateScToGz] IndexedDB migration error:', e);
    }

    // --- 2. localStorage ---
    try {
        const keysToMigrate = [];
        for (let i = 0; i < localStorage.length; i++) {
            const key = localStorage.key(i);
            if (key && key.startsWith('sc_')) keysToMigrate.push(key);
        }
        for (const key of keysToMigrate) {
            const newKey = 'gz_' + key.slice(3);
            if (localStorage.getItem(newKey) === null) {
                localStorage.setItem(newKey, localStorage.getItem(key));
            }
            localStorage.removeItem(key);
        }
    } catch (e) {
        console.warn('[migrateScToGz] localStorage migration error:', e);
    }

    localStorage.setItem('gz_migration_done', '1');
    console.log('[migrateScToGz] Migration from sc_ to gz_ complete.');
}

export async function getSyncDeletedEntries() {
    return (await db.get(SYNC_DELETIONS_KEY)) || {};
}

export async function setSyncDeletedEntries(entries) {
    await db.set(SYNC_DELETIONS_KEY, entries || {});
}

export async function markSyncDeletedEntry(type, id) {
    if (!type || !id) return;
    const entries = await getSyncDeletedEntries();
    entries[`${type}:${id}`] = {
        type,
        id,
        deleted: true,
        updatedAt: Date.now()
    };
    await setSyncDeletedEntries(entries);
}

export async function clearSyncDeletedEntry(type, id) {
    if (!type || !id) return;
    const entries = await getSyncDeletedEntries();
    delete entries[`${type}:${id}`];
    await setSyncDeletedEntries(entries);
}
