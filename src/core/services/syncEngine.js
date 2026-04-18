import { db, getSyncDeletedEntries, clearSyncDeletedEntry } from '@/utils/db.js';
import { encryptForSync, decryptFromSync, hasSyncKey, getSyncKey } from '@/core/services/crypto/keyManager.js';

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

let _encryptionEnabled = false;

export function isEncryptionEnabled() {
    return _encryptionEnabled;
}

export async function detectEncryptionState() {
    _encryptionEnabled = await hasSyncKey();
    return _encryptionEnabled;
}

function ext() {
    return _encryptionEnabled ? '.enc' : '.json';
}

function cloudPath(type, id) {
    const e = ext();
    switch (type) {
        case ENTITY_TYPES.CHARACTER: return `${CLOUD_BASE}/characters/${id}${e}`;
        case ENTITY_TYPES.PERSONA: return `${CLOUD_BASE}/personas/${id}${e}`;
        case ENTITY_TYPES.CHAT: return `${CLOUD_BASE}/chats/${id}${e}`;
        case ENTITY_TYPES.LOREBOOKS: return `${CLOUD_BASE}/lorebooks${e}`;
        case ENTITY_TYPES.API_PRESETS: return `${CLOUD_BASE}/api_presets${e}`;
        case ENTITY_TYPES.THEME_PRESETS: return `${CLOUD_BASE}/theme_presets${e}`;
        case ENTITY_TYPES.LOCAL_STORAGE: return `${CLOUD_BASE}/local_storage${e}`;
        case ENTITY_TYPES.MANIFEST: return `${CLOUD_BASE}/manifest.json`;
        default: return `${CLOUD_BASE}/misc/${id}${e}`;
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
    if (!key) return data;
    return encryptForSync(data, key);
}

async function decryptEntity(encrypted, key) {
    if (!key) return encrypted;
    if (!encrypted.iv || !encrypted.data) return encrypted;
    return decryptFromSync(encrypted, key);
}

const MANIFEST_VERSION = 2;

function entryKey(type, id) {
    return `${type}:${id}`;
}

function clone(obj) {
    return JSON.parse(JSON.stringify(obj));
}

async function getCloudVerificationCandidate(adapter) {
    const cloudFiles = await listAllFiles(adapter);
    const candidate = cloudFiles.find(file => {
        const path = file.path_display || file.path || '';
        return path !== cloudPath(ENTITY_TYPES.MANIFEST);
    });

    if (!candidate) {
        return null;
    }

    return adapter.download(candidate.path_display || candidate.path);
}

export async function cloudHasData(adapter) {
    try {
        const result = await adapter.download(cloudPath(ENTITY_TYPES.MANIFEST));
        return result !== null;
    } catch {
        return false;
    }
}

export async function verifyCloudKey(adapter, key) {
    const candidate = await getCloudVerificationCandidate(adapter);
    if (!candidate) return true;

    const parsed = JSON.parse(candidate.data);
    if (!_encryptionEnabled) return true;
    if (!parsed.iv || !parsed.data) return true;

    await decryptEntity(parsed, key);
    return true;
}

export async function buildManifest(lastSync, deviceId) {
    return {
        version: MANIFEST_VERSION,
        deviceId: deviceId || getDeviceId(),
        lastSync: lastSync || 0,
        createdAt: Date.now(),
        entries: {}
    };
}

async function computeSyncHash(data) {
    const normalized = JSON.stringify(data ?? null);
    const bytes = new TextEncoder().encode(normalized);
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function readCloudManifestV2(adapter) {
    const manifest = await readManifest(adapter);
    if (manifest?.version === MANIFEST_VERSION && manifest?.entries) {
        return manifest;
    }
    return null;
}

async function readLocalManifestV2() {
    return (await db.get('gz_sync_manifest_v2')) || null;
}

async function writeLocalManifestV2(manifest) {
    await db.set('gz_sync_manifest_v2', manifest);
}

async function collectSingletonEntries() {
    const singletons = [
        { type: ENTITY_TYPES.LOREBOOKS, id: 'lorebooks', data: await db.get('gz_lorebooks') },
        { type: ENTITY_TYPES.API_PRESETS, id: 'api_presets', data: await db.get('gz_api_connection_presets') },
        { type: ENTITY_TYPES.THEME_PRESETS, id: 'theme_presets', data: await db.get('gz_theme_presets') }
    ];

    const lsData = {};
    const lsKeys = ['silly_cradle_presets', 'silly_cradle_current_preset_id', 'gz_preset_connections', 'regex_scripts', 'gz_active_persona_id', 'gz_persona_connections'];
    for (const k of lsKeys) {
        const v = localStorage.getItem(k);
        if (v !== null) lsData[k] = v;
    }
    singletons.push({ type: ENTITY_TYPES.LOCAL_STORAGE, id: 'local_storage', data: Object.keys(lsData).length > 0 ? lsData : null });
    return singletons;
}

async function buildLocalManifestV2() {
    const manifest = await buildManifest(Date.now(), getDeviceId());
    const previousManifest = await readLocalManifestV2();
    const previousEntries = previousManifest?.entries || {};
    manifest.entries = {};

    const characters = await db.getAll('characters');
    for (const char of characters) {
        if (!char?.id) continue;
        const hash = await computeSyncHash(char);
        const previousEntry = previousEntries[entryKey(ENTITY_TYPES.CHARACTER, char.id)];
        manifest.entries[entryKey(ENTITY_TYPES.CHARACTER, char.id)] = {
            type: ENTITY_TYPES.CHARACTER,
            id: char.id,
            path: cloudPath(ENTITY_TYPES.CHARACTER, char.id),
            updatedAt: char.updatedAt || previousEntry?.updatedAt || Date.now(),
            hash,
            deleted: false
        };
    }

    const personas = await db.getAll('personas');
    for (const persona of personas) {
        if (!persona?.id) continue;
        const hash = await computeSyncHash(persona);
        const previousEntry = previousEntries[entryKey(ENTITY_TYPES.PERSONA, persona.id)];
        manifest.entries[entryKey(ENTITY_TYPES.PERSONA, persona.id)] = {
            type: ENTITY_TYPES.PERSONA,
            id: persona.id,
            path: cloudPath(ENTITY_TYPES.PERSONA, persona.id),
            updatedAt: persona.updatedAt || previousEntry?.updatedAt || Date.now(),
            hash,
            deleted: false
        };
    }

    const chats = await db.getChats();
    for (const [charId, chatData] of Object.entries(chats || {})) {
        const hash = await computeSyncHash(chatData);
        const previousEntry = previousEntries[entryKey(ENTITY_TYPES.CHAT, charId)];
        manifest.entries[entryKey(ENTITY_TYPES.CHAT, charId)] = {
            type: ENTITY_TYPES.CHAT,
            id: charId,
            path: cloudPath(ENTITY_TYPES.CHAT, charId),
            updatedAt: chatData?.updatedAt || previousEntry?.updatedAt || Date.now(),
            hash,
            deleted: false
        };
    }

    const singletons = await collectSingletonEntries();
    for (const item of singletons) {
        if (item.data === null || item.data === undefined) continue;
        const manifestKey = entryKey(item.type, item.id);
        const hash = await computeSyncHash(item.data);
        const previousEntry = previousEntries[manifestKey];
        manifest.entries[entryKey(item.type, item.id)] = {
            type: item.type,
            id: item.id,
            path: cloudPath(item.type, item.id),
            updatedAt: previousEntry?.hash === hash && !previousEntry?.deleted
                ? previousEntry.updatedAt
                : Date.now(),
            hash,
            deleted: false
        };
    }

    const deletions = await getSyncDeletedEntries();
    for (const [key, deletion] of Object.entries(deletions)) {
        manifest.entries[key] = {
            type: deletion.type,
            id: deletion.id,
            path: cloudPath(deletion.type, deletion.id),
            updatedAt: deletion.updatedAt,
            hash: null,
            deleted: true
        };
    }

    manifest.lastSync = Date.now();
    return manifest;
}

async function readCloudEntityByEntry(adapter, entry, key) {
    let result = await adapter.download(entry.path);
    if (!result) {
        const altPath = entry.path.endsWith('.enc')
            ? entry.path.replace('.enc', '.json')
            : entry.path.replace('.json', '.enc');
        result = await adapter.download(altPath);
    }
    if (!result) return null;
    const parsed = JSON.parse(result.data);
    return decryptEntity(parsed, key);
}

async function applyCloudEntry(adapter, entry, key) {
    if (entry.deleted) {
        if (entry.type === ENTITY_TYPES.CHARACTER) {
            await db.delete('characters', entry.id);
        } else if (entry.type === ENTITY_TYPES.PERSONA) {
            await db.delete('personas', entry.id);
        } else if (entry.type === ENTITY_TYPES.CHAT) {
            await db.delete('keyvalue', `gz_chat_${entry.id}`);
        }
        await clearSyncDeletedEntry(entry.type, entry.id);
        return null;
    }

    const entity = await readCloudEntityByEntry(adapter, entry, key);
    if (entry.type === ENTITY_TYPES.CHARACTER) {
        await db.put('characters', entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === ENTITY_TYPES.PERSONA) {
        await db.put('personas', entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === ENTITY_TYPES.CHAT) {
        await db.set(`gz_chat_${entry.id}`, entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === ENTITY_TYPES.LOREBOOKS) {
        await db.queuedSet('gz_lorebooks', entity);
    } else if (entry.type === ENTITY_TYPES.API_PRESETS) {
        await db.queuedSet('gz_api_connection_presets', entity);
    } else if (entry.type === ENTITY_TYPES.THEME_PRESETS) {
        await db.queuedSet('gz_theme_presets', entity);
    } else if (entry.type === ENTITY_TYPES.LOCAL_STORAGE) {
        for (const [lsKey, lsVal] of Object.entries(entity || {})) {
            localStorage.setItem(lsKey, lsVal);
        }
    }
    return entity;
}

function getBreakdownBucket(type) {
    if (type === ENTITY_TYPES.CHARACTER) return 'characters';
    if (type === ENTITY_TYPES.PERSONA) return 'personas';
    if (type === ENTITY_TYPES.CHAT) return 'chats';
    return 'settings';
}

function needsConflict(localEntry, cloudEntry) {
    return !!localEntry && !localEntry.deleted && localEntry.updatedAt > cloudEntry.updatedAt;
}

async function getLocalConflictEntity(type, id) {
    if (type === ENTITY_TYPES.CHARACTER) return getLocalCharacter(id);
    if (type === ENTITY_TYPES.PERSONA) return getLocalPersona(id);
    if (type === ENTITY_TYPES.CHAT) return getLocalChat(id);
    return null;
}

function getConflictName(type, localEntity, cloudEntity, id) {
    if (type === ENTITY_TYPES.CHARACTER || type === ENTITY_TYPES.PERSONA) {
        return localEntity?.name || cloudEntity?.name || id;
    }
    if (type === ENTITY_TYPES.CHAT) {
        return getChatName(localEntity, cloudEntity, id);
    }
    return id;
}

async function deleteCloudFileIfExists(adapter, entry) {
    try {
        await adapter.deleteFile(entry.path);
    } catch {
        // Ignore missing payload deletes; manifest remains source of truth.
    }
}

async function pushManifestV2(adapter, key, onProgress) {
    const cloudManifest = await readCloudManifestV2(adapter);
    const localManifest = await buildLocalManifestV2();
    const cloudEntries = cloudManifest?.entries || {};
    const breakdown = { characters: 0, personas: 0, chats: 0, settings: 0 };
    let pushed = 0;
    let skipped = 0;

    const allKeys = new Set([...Object.keys(localManifest.entries), ...Object.keys(cloudEntries)]);
    const allEntries = Array.from(allKeys);

    for (let i = 0; i < allEntries.length; i++) {
        const keyName = allEntries[i];
        const localEntry = localManifest.entries[keyName];
        const cloudEntry = cloudEntries[keyName];
        const phase = getBreakdownBucket((localEntry || cloudEntry)?.type);

        if (!localEntry) {
            if (onProgress) onProgress(phase, i + 1, allEntries.length);
            continue;
        }

        const shouldUpload = !cloudEntry
            || localEntry.deleted !== cloudEntry.deleted
            || localEntry.updatedAt > cloudEntry.updatedAt
            || localEntry.hash !== cloudEntry.hash;

        if (!shouldUpload) {
            skipped++;
            if (onProgress) onProgress(phase, i + 1, allEntries.length);
            continue;
        }

        if (localEntry.deleted) {
            await deleteCloudFileIfExists(adapter, localEntry);
        } else {
            let payload = null;
            if (localEntry.type === ENTITY_TYPES.CHARACTER) payload = await getLocalCharacter(localEntry.id);
            else if (localEntry.type === ENTITY_TYPES.PERSONA) payload = await getLocalPersona(localEntry.id);
            else if (localEntry.type === ENTITY_TYPES.CHAT) payload = await getLocalChat(localEntry.id);
            else {
                const singletons = await collectSingletonEntries();
                payload = singletons.find(item => item.type === localEntry.type && item.id === localEntry.id)?.data ?? null;
            }

            if (payload !== null && payload !== undefined) {
                const encrypted = await encryptEntity(payload, key);
                await adapter.upload(localEntry.path, JSON.stringify(encrypted));
            }
        }

        pushed++;
        breakdown[phase]++;
        if (onProgress) onProgress(phase, i + 1, allEntries.length);
    }

    localManifest.lastSync = Date.now();
    localManifest.createdAt = cloudManifest?.createdAt || Date.now();
    await adapter.upload(cloudPath(ENTITY_TYPES.MANIFEST), JSON.stringify(localManifest));
    await writeLocalManifestV2(localManifest);

    return { pushed, skipped, total: pushed + skipped, breakdown };
}

async function pullManifestV2(adapter, key, onProgress, onConflict) {
    const cloudManifest = await readCloudManifestV2(adapter);
    if (!cloudManifest) {
        throw new Error('Cloud manifest v2 not found');
    }

    const localManifest = await buildLocalManifestV2();
    const cloudEntries = cloudManifest.entries || {};
    const localEntries = localManifest.entries || {};
    const allKeys = new Set([...Object.keys(cloudEntries), ...Object.keys(localEntries)]);
    const allEntries = Array.from(allKeys);
    const breakdown = { characters: 0, personas: 0, chats: 0, settings: 0 };
    const decryptErrors = [];
    const conflicts = [];
    let pulled = 0;

    for (let i = 0; i < allEntries.length; i++) {
        const keyName = allEntries[i];
        const cloudEntry = cloudEntries[keyName];
        const localEntry = localEntries[keyName];
        const phase = getBreakdownBucket((cloudEntry || localEntry)?.type);

        if (!cloudEntry) {
            if (onProgress) onProgress(phase, i + 1, allEntries.length);
            continue;
        }

        const cloudIsNewer = !localEntry || cloudEntry.updatedAt > localEntry.updatedAt || cloudEntry.hash !== localEntry.hash || cloudEntry.deleted !== localEntry.deleted;
        if (!cloudIsNewer) {
            if (onProgress) onProgress(phase, i + 1, allEntries.length);
            continue;
        }

        if (needsConflict(localEntry, cloudEntry)) {
            const localEntity = await getLocalConflictEntity(cloudEntry.type, cloudEntry.id);
            let cloudEntity = null;
            if (!cloudEntry.deleted) {
                try {
                    cloudEntity = await readCloudEntityByEntry(adapter, cloudEntry, key);
                } catch (e) {
                    decryptErrors.push({ type: cloudEntry.type, id: cloudEntry.id, error: e.message });
                    if (onProgress) onProgress(phase, i + 1, allEntries.length);
                    continue;
                }
            }
            const conflict = {
                type: cloudEntry.type,
                id: cloudEntry.id,
                name: getConflictName(cloudEntry.type, localEntity, cloudEntity, cloudEntry.id),
                local: localEntity,
                cloud: cloudEntity,
                cloudModified: cloudEntry.updatedAt
            };
            conflicts.push(conflict);
            if (onConflict) onConflict(conflict);
            if (onProgress) onProgress(phase, i + 1, allEntries.length);
            continue;
        }

        try {
            await applyCloudEntry(adapter, cloudEntry, key);
            pulled++;
            breakdown[phase]++;
        } catch (e) {
            decryptErrors.push({ type: cloudEntry.type, id: cloudEntry.id, error: e.message });
        }

        if (onProgress) onProgress(phase, i + 1, allEntries.length);
    }

    await writeLocalManifestV2(clone(cloudManifest));

    if (pulled === 0 && conflicts.length === 0 && decryptErrors.length > 0 && Object.keys(cloudEntries).length > 0) {
        if (_encryptionEnabled) {
            throw new Error('Cloud data was found, but none of it could be decrypted. Restore the correct recovery phrase and try again.');
        } else {
            throw new Error('Cloud data was found, but could not be read. Check sync settings and try again.');
        }
    }

    return { pulled, conflicts, decryptErrors, breakdown };
}

export async function pushEntities(adapter, key, onProgress) {
    return pushManifestV2(adapter, key, onProgress);
}

export async function pullEntities(adapter, key, onProgress, onConflict) {
    if (!key && _encryptionEnabled) throw new Error('Encryption key not available. Set up encryption first.');
    return pullManifestV2(adapter, key, onProgress, onConflict);
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

export async function wipeCloudData(adapter, onProgress) {
    const files = await listAllFiles(adapter);
    let deleted = 0;
    let failed = 0;

    for (let i = 0; i < files.length; i++) {
        const file = files[i];
        try {
            await adapter.deleteFile(file);
            deleted++;
        } catch (e) {
            console.warn(`[syncEngine] Failed to delete ${file.path}:`, e);
            failed++;
        }
        if (onProgress) onProgress(i + 1, files.length);
    }

    return { deleted, failed, total: files.length };
}

export async function resolveConflict(conflict, choice) {
    const entity = choice === 'cloud' ? conflict.cloud : conflict.local;
    if (choice === 'cloud' && !entity) {
        if (conflict.type === ENTITY_TYPES.CHARACTER) {
            await db.delete('characters', conflict.id);
        } else if (conflict.type === ENTITY_TYPES.PERSONA) {
            await db.delete('personas', conflict.id);
        } else if (conflict.type === ENTITY_TYPES.CHAT) {
            await db.delete('keyvalue', `gz_chat_${conflict.id}`);
        }
        return null;
    }
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
