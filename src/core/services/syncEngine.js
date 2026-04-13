import { db } from '@/utils/db.js';
import { getSyncKey, encryptForSync, decryptFromSync, hasSyncKey } from '@/core/services/crypto/keyManager.js';

const CLOUD_BASE = '/Glaze';

const ENTITY_TYPES = {
    CHARACTER: 'character',
    PERSONA: 'persona',
    CHAT: 'chat',
    LOREBOOKS: 'lorebooks',
    API_PRESETS: 'api_presets',
    THEME_PRESETS: 'theme_presets',
    LOCAL_STORAGE: 'local_storage',
    MANIFEST: 'manifest'
};

function cloudPath(type, id) {
    switch (type) {
        case ENTITY_TYPES.CHARACTER: return `${CLOUD_BASE}/characters/${id}.enc`;
        case ENTITY_TYPES.PERSONA: return `${CLOUD_BASE}/personas/${id}.enc`;
        case ENTITY_TYPES.CHAT: return `${CLOUD_BASE}/chats/${id}.enc`;
        case ENTITY_TYPES.LOREBOOKS: return `${CLOUD_BASE}/lorebooks.enc`;
        case ENTITY_TYPES.API_PRESETS: return `${CLOUD_BASE}/api_presets.enc`;
        case ENTITY_TYPES.THEME_PRESETS: return `${CLOUD_BASE}/theme_presets.enc`;
        case ENTITY_TYPES.LOCAL_STORAGE: return `${CLOUD_BASE}/local_storage.enc`;
        case ENTITY_TYPES.MANIFEST: return `${CLOUD_BASE}/manifest.json`;
        default: return `${CLOUD_BASE}/misc/${id}.enc`;
    }
}

function generateDeviceId() {
    const stored = localStorage.getItem('gz_sync_device_id');
    if (stored) return stored;
    const id = Date.now().toString(36) + Math.random().toString(36).substr(2, 8);
    localStorage.setItem('gz_sync_device_id', id);
    return id;
}

function getDeviceId() {
    return localStorage.getItem('gz_sync_device_id') || generateDeviceId();
}

async function encryptEntity(data, key) {
    if (!key) throw new Error('Sync encryption key not available');
    return encryptForSync(data, key);
}

async function decryptEntity(encrypted, key) {
    if (!key) throw new Error('Sync encryption key not available');
    return decryptFromSync(encrypted, key);
}

export async function buildManifest(lastSync, deviceId) {
    return {
        version: 1,
        deviceId: deviceId || getDeviceId(),
        lastSync: lastSync || 0,
        createdAt: Date.now()
    };
}

export async function pushEntities(adapter, key, onProgress) {
    const lastSync = await readManifest(adapter);
    const lastSyncTime = lastSync?.lastSync || 0;
    const now = Date.now();
    let pushed = 0;
    let skipped = 0;

    const characters = await db.getAll('characters');
    const count = characters.length;
    for (let i = 0; i < count; i++) {
        const char = characters[i];
        if (!char.updatedAt || char.updatedAt > lastSyncTime) {
            const encrypted = await encryptEntity(char, key);
            await adapter.upload(cloudPath(ENTITY_TYPES.CHARACTER, char.id), JSON.stringify(encrypted));
            pushed++;
        } else {
            skipped++;
        }
        if (onProgress) onProgress('characters', i + 1, count);
    }

    const personas = await db.getAll('personas');
    const pCount = personas.length;
    for (let i = 0; i < pCount; i++) {
        const persona = personas[i];
        if (!persona.updatedAt || persona.updatedAt > lastSyncTime) {
            const encrypted = await encryptEntity(persona, key);
            await adapter.upload(cloudPath(ENTITY_TYPES.PERSONA, persona.id), JSON.stringify(encrypted));
            pushed++;
        } else {
            skipped++;
        }
        if (onProgress) onProgress('personas', i + 1, pCount);
    }

    const chats = await db.getChats();
    const chatIds = Object.keys(chats);
    const cCount = chatIds.length;
    for (let i = 0; i < cCount; i++) {
        const charId = chatIds[i];
        const chatData = chats[charId];
        if (chatData.updatedAt && chatData.updatedAt > lastSyncTime) {
            const encrypted = await encryptEntity(chatData, key);
            await adapter.upload(cloudPath(ENTITY_TYPES.CHAT, charId), JSON.stringify(encrypted));
            pushed++;
        } else {
            skipped++;
        }
        if (onProgress) onProgress('chats', i + 1, cCount);
    }

    const singletons = [
        { type: ENTITY_TYPES.LOREBOOKS, data: await db.get('gz_lorebooks'), id: 'lorebooks' },
        { type: ENTITY_TYPES.API_PRESETS, data: await db.get('gz_api_connection_presets'), id: 'api_presets' },
        { type: ENTITY_TYPES.THEME_PRESETS, data: await db.get('gz_theme_presets'), id: 'theme_presets' }
    ];

    const lsData = {};
    const lsKeys = ['silly_cradle_presets', 'silly_cradle_current_preset_id', 'gz_preset_connections', 'regex_scripts', 'gz_active_persona_id', 'gz_persona_connections'];
    for (const k of lsKeys) {
        const v = localStorage.getItem(k);
        if (v !== null) lsData[k] = v;
    }
    if (Object.keys(lsData).length > 0) {
        singletons.push({ type: ENTITY_TYPES.LOCAL_STORAGE, data: lsData, id: 'local_storage' });
    }

    for (let i = 0; i < singletons.length; i++) {
        const { type, data, id } = singletons[i];
        if (data !== null && data !== undefined) {
            const encrypted = await encryptEntity(data, key);
            await adapter.upload(cloudPath(type, id), JSON.stringify(encrypted));
            pushed++;
        }
        if (onProgress) onProgress('settings', i + 1, singletons.length);
    }

    const manifest = await buildManifest(now, getDeviceId());
    await adapter.upload(cloudPath(ENTITY_TYPES.MANIFEST), JSON.stringify(manifest));

    return { pushed, skipped, total: pushed + skipped };
}

export async function pullEntities(adapter, key, onProgress, onConflict) {
    const keyAvailable = await hasSyncKey();
    if (!keyAvailable) throw new Error('Encryption key not available. Set up encryption first.');

    const manifest = await readManifest(adapter);
    const localLastSync = manifest?.lastSync || 0;

    const cloudFiles = await listAllFiles(adapter);
    let pulled = 0;
    let conflicts = [];

    const charFiles = cloudFiles.filter(f => f.path.startsWith(`${CLOUD_BASE}/characters/`));
    for (let i = 0; i < charFiles.length; i++) {
        const file = charFiles[i];
        const charId = file.path.replace(`${CLOUD_BASE}/characters/`, '').replace('.enc', '');
        const cloudModified = file.serverModified ? new Date(file.serverModified).getTime() : 0;

        const localChar = await getLocalCharacter(charId);
        const downloadResult = await adapter.download(file.path_display || file.path);
        if (!downloadResult) {
            if (onProgress) onProgress('characters', i + 1, charFiles.length);
            continue;
        }

        const encrypted = JSON.parse(downloadResult.data);
        const cloudEntity = await decryptEntity(encrypted, key);

        if (localChar && localChar.updatedAt && localChar.updatedAt > cloudModified) {
            if (onConflict) {
                conflicts.push({ type: ENTITY_TYPES.CHARACTER, id: charId, name: localChar.name || charId, local: localChar, cloud: cloudEntity, cloudModified });
            }
        } else {
            await db.put('characters', cloudEntity);
            pulled++;
        }
        if (onProgress) onProgress('characters', i + 1, charFiles.length);
    }

    const personaFiles = cloudFiles.filter(f => f.path.startsWith(`${CLOUD_BASE}/personas/`));
    for (let i = 0; i < personaFiles.length; i++) {
        const file = personaFiles[i];
        const personaId = file.path.replace(`${CLOUD_BASE}/personas/`, '').replace('.enc', '');
        const cloudModified = file.serverModified ? new Date(file.serverModified).getTime() : 0;

        const localPersona = await getLocalPersona(personaId);
        const downloadResult = await adapter.download(file.path_display || file.path);
        if (!downloadResult) {
            if (onProgress) onProgress('personas', i + 1, personaFiles.length);
            continue;
        }

        const encrypted = JSON.parse(downloadResult.data);
        const cloudEntity = await decryptEntity(encrypted, key);

        if (localPersona && localPersona.updatedAt && localPersona.updatedAt > cloudModified) {
            if (onConflict) {
                conflicts.push({ type: ENTITY_TYPES.PERSONA, id: personaId, name: localPersona.name || personaId, local: localPersona, cloud: cloudEntity, cloudModified });
            }
        } else {
            await db.put('personas', cloudEntity);
            pulled++;
        }
        if (onProgress) onProgress('personas', i + 1, personaFiles.length);
    }

    const chatFiles = cloudFiles.filter(f => f.path.startsWith(`${CLOUD_BASE}/chats/`));
    for (let i = 0; i < chatFiles.length; i++) {
        const file = chatFiles[i];
        const charId = file.path.replace(`${CLOUD_BASE}/chats/`, '').replace('.enc', '');
        const cloudModified = file.serverModified ? new Date(file.serverModified).getTime() : 0;

        const localChat = await getLocalChat(charId);
        const downloadResult = await adapter.download(file.path_display || file.path);
        if (!downloadResult) {
            if (onProgress) onProgress('chats', i + 1, chatFiles.length);
            continue;
        }

        const encrypted = JSON.parse(downloadResult.data);
        const cloudEntity = await decryptEntity(encrypted, key);
        const chatName = getChatName(localChat, cloudEntity, charId);

        if (localChat && localChat.updatedAt && localChat.updatedAt > cloudModified) {
            if (onConflict) {
                conflicts.push({ type: ENTITY_TYPES.CHAT, id: charId, name: chatName, local: localChat, cloud: cloudEntity, cloudModified });
            }
        } else {
            await db.saveChat(charId, cloudEntity);
            pulled++;
        }
        if (onProgress) onProgress('chats', i + 1, chatFiles.length);
    }

    const singletonFiles = [
        { path: cloudPath(ENTITY_TYPES.LOREBOOKS, 'lorebooks'), type: ENTITY_TYPES.LOREBOOKS, key: 'gz_lorebooks' },
        { path: cloudPath(ENTITY_TYPES.API_PRESETS, 'api_presets'), type: ENTITY_TYPES.API_PRESETS, key: 'gz_api_connection_presets' },
        { path: cloudPath(ENTITY_TYPES.THEME_PRESETS, 'theme_presets'), type: ENTITY_TYPES.THEME_PRESETS, key: 'gz_theme_presets' },
        { path: cloudPath(ENTITY_TYPES.LOCAL_STORAGE, 'local_storage'), type: ENTITY_TYPES.LOCAL_STORAGE, key: null }
    ];

    for (let i = 0; i < singletonFiles.length; i++) {
        const { path, key: dbKey } = singletonFiles[i];
        const result = await adapter.download(path);
        if (result) {
            const encrypted = JSON.parse(result.data);
            const decrypted = await decryptEntity(encrypted, key);
            if (dbKey) {
                await db.queuedSet(dbKey, decrypted);
            } else {
                for (const [lsKey, lsVal] of Object.entries(decrypted)) {
                    localStorage.setItem(lsKey, lsVal);
                }
            }
            pulled++;
        }
        if (onProgress) onProgress('settings', i + 1, singletonFiles.length);
    }

    return { pulled, conflicts };
}

async function readManifest(adapter) {
    try {
        const result = await adapter.download(cloudPath(ENTITY_TYPES.MANIFEST));
        if (result) {
            return JSON.parse(result.data);
        }
    } catch {}
    return null;
}

async function listAllFiles(adapter) {
    const files = [];
    try {
        let result = await adapter.listFolder(CLOUD_BASE);
        if (!result || !result.entries) return files;

        for (const entry of result.entries) {
            if (entry['.tag'] === 'folder') {
                const subResult = await adapter.listFolder(entry.path_display || entry.path_lower);
                if (subResult && subResult.entries) {
                    files.push(...subResult.entries.filter(e => e['.tag'] === 'file'));
                }
            } else if (entry['.tag'] === 'file') {
                files.push(entry);
            }
        }

        while (result && result.has_more && result.cursor) {
            result = await adapter.listFolderContinue(result.cursor);
            if (result && result.entries) {
                for (const entry of result.entries) {
                    if (entry['.tag'] === 'folder') {
                        const subResult = await adapter.listFolder(entry.path_display || entry.path_lower);
                        if (subResult && subResult.entries) {
                            files.push(...subResult.entries.filter(e => e['.tag'] === 'file'));
                        }
                    } else if (entry['.tag'] === 'file') {
                        files.push(entry);
                    }
                }
            }
        }
    } catch (e) {
        console.warn('[syncEngine] listAllFiles error:', e);
    }
    return files;
}

async function getLocalCharacter(id) {
    const all = await db.getAll('characters');
    return all.find(c => c.id === id) || null;
}

async function getLocalPersona(id) {
    const all = await db.getAll('personas');
    return all.find(p => p.id === id) || null;
}

async function getLocalChat(charId) {
    return db.getChat(charId);
}

function getChatName(localChat, cloudChat, charId) {
    const msgs = cloudChat?.messages || localChat?.messages || [];
    if (msgs.length > 0) {
        const first = msgs[0];
        const text = first.mes || first.content || '';
        const preview = text.substring(0, 40).replace(/\n/g, ' ');
        return preview || charId;
    }
    return charId;
}

export async function resolveConflict(conflict, choice) {
    const entity = choice === 'cloud' ? conflict.cloud : conflict.local;
    if (conflict.type === ENTITY_TYPES.CHARACTER) {
        await db.put('characters', entity);
    } else if (conflict.type === ENTITY_TYPES.PERSONA) {
        await db.put('personas', entity);
    } else if (conflict.type === ENTITY_TYPES.CHAT) {
        await db.saveChat(conflict.id, entity);
    }
    return entity;
}

export { ENTITY_TYPES, CLOUD_BASE, cloudPath, getDeviceId };
