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

function ensureMemoryBookSessionData(chatData) {
    if (!chatData || typeof chatData !== 'object') return chatData;
    if (!chatData.memoryBooks || typeof chatData.memoryBooks !== 'object') {
        chatData.memoryBooks = {};
    }
    return chatData;
}

function ensureMemoryEntry(entry) {
    if (!entry || typeof entry !== 'object') return entry;
    if (!Array.isArray(entry.keys)) entry.keys = [];
    if (!Array.isArray(entry.glazeKeys)) entry.glazeKeys = [];
    if (typeof entry.vectorSearch !== 'boolean') entry.vectorSearch = false;
    return entry;
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
        safeMessages.forEach(ensureMessageMetadata);
        chatData.sessions[sessionId] = safeMessages;
    }

    ensureMemoryBookSessionData(chatData);

    for (const sessionId of Object.keys(chatData.sessions)) {
        if (!chatData.memoryBooks[sessionId] || typeof chatData.memoryBooks[sessionId] !== 'object') {
                chatData.memoryBooks[sessionId] = {
                    id: `memorybook_${sessionId}`,
                    entries: [],
                    pendingDrafts: [],
                    settings: {
                    enabled: true,
                    maxInjectedEntries: 3,
                    batchSize: 1,
                        parallelJobs: 1,
                        vectorSearchEnabled: false,
                        keyMatchMode: 'plain',
                        generationSource: 'current',
                        generationModel: '',
                        generationUseCurrentModelOverride: false,
                        generationEndpoint: '',
                        generationApiKey: '',
                        generationTemperature: null,
                        promptPreset: 'strict_factual',
                        customPrompts: []
                    },
                    updatedAt: 0
                };
        } else {
            const memoryBook = chatData.memoryBooks[sessionId];
            if (!memoryBook.id) memoryBook.id = `memorybook_${sessionId}`;
            if (!Array.isArray(memoryBook.entries)) memoryBook.entries = [];
            if (!Array.isArray(memoryBook.pendingDrafts)) memoryBook.pendingDrafts = [];
            memoryBook.entries.forEach(ensureMemoryEntry);
            memoryBook.pendingDrafts.forEach(ensureMemoryEntry);
            if (!memoryBook.settings || typeof memoryBook.settings !== 'object') {
                memoryBook.settings = {};
            }
            if (typeof memoryBook.settings.enabled !== 'boolean') memoryBook.settings.enabled = true;
            if (!Number.isFinite(memoryBook.settings.maxInjectedEntries)) memoryBook.settings.maxInjectedEntries = 3;
            if (!Number.isFinite(memoryBook.settings.batchSize)) memoryBook.settings.batchSize = 1;
            if (!Number.isFinite(memoryBook.settings.parallelJobs)) memoryBook.settings.parallelJobs = 1;
            if (typeof memoryBook.settings.vectorSearchEnabled !== 'boolean') memoryBook.settings.vectorSearchEnabled = false;
            if (!['plain', 'glaze', 'both'].includes(memoryBook.settings.keyMatchMode)) memoryBook.settings.keyMatchMode = 'plain';
            if (!memoryBook.settings.generationSource) memoryBook.settings.generationSource = 'current';
            if (typeof memoryBook.settings.generationModel !== 'string') memoryBook.settings.generationModel = '';
            if (typeof memoryBook.settings.generationUseCurrentModelOverride !== 'boolean') memoryBook.settings.generationUseCurrentModelOverride = false;
            if (typeof memoryBook.settings.generationEndpoint !== 'string') memoryBook.settings.generationEndpoint = '';
            if (typeof memoryBook.settings.generationApiKey !== 'string') memoryBook.settings.generationApiKey = '';
            if (!(memoryBook.settings.generationTemperature === null || Number.isFinite(memoryBook.settings.generationTemperature))) {
                memoryBook.settings.generationTemperature = null;
            }
            if (typeof memoryBook.settings.promptPreset !== 'string') memoryBook.settings.promptPreset = 'strict_factual';
            if (!Array.isArray(memoryBook.settings.customPrompts)) memoryBook.settings.customPrompts = [];
            if (!Number.isFinite(memoryBook.updatedAt)) memoryBook.updatedAt = 0;
        }
    }

    return chatData;
}

// Global write queue — serializes all IndexedDB writes to prevent race conditions
let _dbWriteQueue = Promise.resolve();

export function queueDbWrite(fn) {
    _dbWriteQueue = _dbWriteQueue.then(fn).catch(err => console.error('[DB] Write queue error:', err));
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
            req.onsuccess = () => {
                resolve();
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
            req.onsuccess = () => {
                resolve();
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
            req.onsuccess = () => {
                resolve();
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
        return new Promise((resolve, reject) => {
            const tx = database.transaction(STORE_KEYVALUE, 'readwrite');
            const store = tx.objectStore(STORE_KEYVALUE);

            // First, check if legacy monolithic sc_chats exists
            const getLegacyReq = store.get('gz_chats');
            getLegacyReq.onsuccess = () => {
                const legacyChats = getLegacyReq.result;
                let hasLegacy = legacyChats && Object.keys(legacyChats).length > 0;

                // Fetch all granular chats
                const allChatsMap = {};
                const cursorReq = store.openCursor();

                cursorReq.onsuccess = (e) => {
                    const cursor = e.target.result;
                    if (cursor) {
                        if (cursor.key.toString().startsWith('gz_chat_')) {
                            const charId = cursor.key.toString().substring(8); // remove 'gz_chat_' (8 chars)
                            allChatsMap[charId] = cursor.value;
                        }
                        cursor.continue();
                    } else {
                        // Cursor iteration finished
                        if (hasLegacy) {
                            // Perform Migration
                            let migratedCount = 0;
                            let keysToMigrate = Object.keys(legacyChats);

                            // If there are legacy chats, migrate them to granular keys if they don't exist yet
                            for (const charId of keysToMigrate) {
                                if (!allChatsMap[charId]) {
                                    store.put(legacyChats[charId], `gz_chat_${charId}`);
                                    allChatsMap[charId] = legacyChats[charId];
                                }
                            }
                            // Delete legacy monolithic key to reclaim space
                            store.delete('gz_chats');
                        }
                        resolve(allChatsMap);
                    }
                };
                cursorReq.onerror = () => reject(cursorReq.error);
            };
            getLegacyReq.onerror = () => reject(getLegacyReq.error);
        }).finally(() => {
            database.close();
        });
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
        return data;
    },
    saveChat: async (charId, chatData) => {
        await db.set(`gz_chat_${charId}`, normalizeChatData(chatData));
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

        await db.saveChat(charId, data);
        return nextId;
    },
    deleteSession: async (charId, sessionId) => {
        let data = await db.getChat(charId);
        if (!data || !data.sessions) return;

        delete data.sessions[sessionId];

        // If current session deleted, switch to another or create new
        if (data.currentId == sessionId) {
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
