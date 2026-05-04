import { db, getSyncDeletedEntries, clearSyncDeletedEntry } from '@/utils/db.js';
import { encryptForSync, decryptFromSync, hasSyncKey, getSyncKey } from '@/core/services/crypto/keyManager.js';
import { isSyncIncludingApiKeys } from '@/core/config/ProviderProfiles.js';
import { showToast } from '@/core/states/toastState.js';

const CLOUD_BASE = '/Glaze';

const MAX_SYNC_PAYLOAD_BYTES = 30 * 1024 * 1024;

const ENTITY_TYPES = {
    CHARACTER: 'character',
    PERSONA: 'persona',
    CHAT: 'chat',
    LOREBOOKS: 'lorebooks',
    API_PRESETS: 'api_presets',
    THEME_PRESETS: 'theme_presets',
    THEME_STATE: 'theme_state',
    LOCAL_STORAGE: 'local_storage',
    MANIFEST: 'manifest',
    GALLERY: 'gallery'
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
        case ENTITY_TYPES.THEME_STATE: return `${CLOUD_BASE}/theme_state${e}`;
        case ENTITY_TYPES.LOCAL_STORAGE: return `${CLOUD_BASE}/local_storage${e}`;
        case ENTITY_TYPES.MANIFEST: return `${CLOUD_BASE}/manifest.json`;
        default: return `${CLOUD_BASE}/misc/${id}${e}`;
    }
}

function galleryCloudPath(charId, imgId, imgExt) {
    return `${CLOUD_BASE}/gallery/${charId}/${imgId}.${imgExt}`;
}

async function dataUrlToBinary(dataUrl) {
    const res = await fetch(dataUrl);
    return await res.arrayBuffer();
}

async function computeImageHash(dataUrl) {
    const binary = await dataUrlToBinary(dataUrl);
    const digest = await crypto.subtle.digest('SHA-256', binary);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

function guessImageExt(dataUrl) {
    const match = dataUrl.match(/^data:image\/([\w+]+)/);
    if (!match) return 'png';
    const raw = match[1].toLowerCase();
    if (raw === 'jpeg') return 'jpg';
    return raw;
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

async function migrateV1ManifestToV2(adapter, v1Manifest) {
    const cloudFiles = await listAllFiles(adapter);
    const entries = {};

    for (const file of cloudFiles) {
        const filePath = file.path_display || file.path || '';
        const cloudModified = file.serverModified ? new Date(file.serverModified).getTime() : Date.now();

        let type = null;
        let id = null;

        if (filePath.startsWith(`${CLOUD_BASE}/characters/`)) {
            type = ENTITY_TYPES.CHARACTER;
            id = filePath.replace(`${CLOUD_BASE}/characters/`, '').replace(/\.(enc|json)$/, '');
        } else if (filePath.startsWith(`${CLOUD_BASE}/personas/`)) {
            type = ENTITY_TYPES.PERSONA;
            id = filePath.replace(`${CLOUD_BASE}/personas/`, '').replace(/\.(enc|json)$/, '');
        } else if (filePath.startsWith(`${CLOUD_BASE}/chats/`)) {
            type = ENTITY_TYPES.CHAT;
            id = filePath.replace(`${CLOUD_BASE}/chats/`, '').replace(/\.(enc|json)$/, '');
        } else if (filePath.startsWith(`${CLOUD_BASE}/`)) {
            const fileName = filePath.replace(`${CLOUD_BASE}/`, '').replace(/\.(enc|json)$/, '');
            if (fileName === 'lorebooks') { type = ENTITY_TYPES.LOREBOOKS; id = 'lorebooks'; }
            else if (fileName === 'api_presets') { type = ENTITY_TYPES.API_PRESETS; id = 'api_presets'; }
            else if (fileName === 'theme_presets') { type = ENTITY_TYPES.THEME_PRESETS; id = 'theme_presets'; }
            else if (fileName === 'theme_state') { type = ENTITY_TYPES.THEME_STATE; id = 'theme_state'; }
            else if (fileName === 'local_storage') { type = ENTITY_TYPES.LOCAL_STORAGE; id = 'local_storage'; }
            else { type = ENTITY_TYPES.LOCAL_STORAGE; id = fileName; }
        }

        if (!type || !id) continue;

        const entryKeyStr = entryKey(type, id);
        entries[entryKeyStr] = {
            type,
            id,
            path: filePath,
            updatedAt: cloudModified,
            hash: null,
            deleted: false
        };
    }

    const migrated = {
        version: MANIFEST_VERSION,
        deviceId: v1Manifest.deviceId || getDeviceId(),
        lastSync: v1Manifest.lastSync || 0,
        createdAt: v1Manifest.createdAt || Date.now(),
        entries
    };

    await adapter.upload(cloudPath(ENTITY_TYPES.MANIFEST), JSON.stringify(migrated));
    return migrated;
}

async function readCloudManifestV2(adapter) {
    const manifest = await readManifest(adapter);
    if (!manifest) return null;
    if (manifest?.version === MANIFEST_VERSION && manifest?.entries) {
        return manifest;
    }
    if (manifest?.version === 1 && !manifest?.entries) {
        return migrateV1ManifestToV2(adapter, manifest);
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
        { type: ENTITY_TYPES.THEME_PRESETS, id: 'theme_presets', data: await db.get('gz_theme_presets') },
        { type: ENTITY_TYPES.THEME_STATE, id: 'theme_state', data: await db.get('gz_theme_active_preset') }
    ];

    const lsData = {};
    const lsKeys = [
        'silly_cradle_presets', 'silly_cradle_current_preset_id', 'gz_preset_connections',
        'regex_scripts', 'gz_active_persona_id', 'gz_persona_connections',
        'gz_lang', 'gz_theme', 'gz_chat_padding_lr', 'gz_force_mobile_layout',
        'gz_battery_saver_ui',
        // Legacy LLM runtime
        'api-endpoint', 'api-max-tokens', 'api-context',
        'gz_api_provider', 'gz_api_endpoint_normalized',
        'gz_api_temp', 'gz_api_topp', 'gz_api_stream',
        'gz_api_auto_hide_images', 'gz_api_auto_hide_images_n',
        'gz_api_request_reasoning', 'gz_api_reasoning_start', 'gz_api_reasoning_end', 'gz_api_reasoning_effort',
        'gz_api_omit_temperature', 'gz_api_omit_top_p', 'gz_api_omit_reasoning', 'gz_api_omit_reasoning_effort',
        'gz_api_connect_timeout', 'gz_api_stream_timeout',
        // Embeddings (non-sensitive)
        'gz_embedding_use_same', 'gz_embedding_target', 'gz_embedding_scan_depth',
        'gz_embedding_threshold', 'gz_embedding_top_k', 'gz_embedding_max_chunk_tokens',
        'gz_embedding_enabled',
        // Image Gen (non-sensitive)
        'gz_imggen_enabled', 'gz_imggen_api_type', 'gz_imggen_endpoint', 'gz_imggen_model',
        'gz_imggen_size', 'gz_imggen_quality', 'gz_imggen_aspect_ratio', 'gz_imggen_image_size',
        'gz_imggen_naistera_model', 'gz_imggen_naistera_aspect_ratio',
        'gz_imggen_naistera_send_char_avatar', 'gz_imggen_naistera_send_user_avatar',
        'gz_imggen_routmy_model', 'gz_imggen_routmy_aspect_ratio', 'gz_imggen_routmy_image_size',
        'gz_imggen_routmy_quality', 'gz_imggen_routmy_send_char_avatar', 'gz_imggen_routmy_send_user_avatar',
        'gz_imggen_image_context_enabled', 'gz_imggen_image_context_count',
        'gz_imggen_additional_refs',
        // Provider profiles (metadata only; the JSON with keys is conditional below)
        'gz_active_llm_profile_id', 'gz_service_profile_map', 'gz_provider_profiles_migrated',
        'gz_sync_include_api_keys'
    ];
    const includeKeys = isSyncIncludingApiKeys();
    if (includeKeys) {
        lsKeys.push('api-key', 'api-model', 'gz_provider_profiles', 'gz_imggen_api_key', 'gz_imggen_naistera_api_key', 'gz_imggen_routmy_api_key');
    }
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
        const { images, ...charNoImages } = char;
        const hash = await computeSyncHash(charNoImages);
        const previousEntry = previousEntries[entryKey(ENTITY_TYPES.CHARACTER, char.id)];
        manifest.entries[entryKey(ENTITY_TYPES.CHARACTER, char.id)] = {
            type: ENTITY_TYPES.CHARACTER,
            id: char.id,
            path: cloudPath(ENTITY_TYPES.CHARACTER, char.id),
            updatedAt: char.updatedAt || previousEntry?.updatedAt || Date.now(),
            hash,
            deleted: false
        };

        if (Array.isArray(images)) {
            for (const img of images) {
                if (!img?.id || !img?.src) continue;
                const imgExt = guessImageExt(img.src);
                const imgHash = await computeImageHash(img.src);
                const galleryKey = entryKey(ENTITY_TYPES.GALLERY, `${char.id}:${img.id}`);
                const prevImgEntry = previousEntries[galleryKey];
                manifest.entries[galleryKey] = {
                    type: ENTITY_TYPES.GALLERY,
                    id: `${char.id}:${img.id}`,
                    charId: char.id,
                    imgId: img.id,
                    path: galleryCloudPath(char.id, img.id, imgExt),
                    ext: imgExt,
                    updatedAt: prevImgEntry?.hash === imgHash && !prevImgEntry?.deleted
                        ? prevImgEntry.updatedAt
                        : Date.now(),
                    hash: imgHash,
                    deleted: false
                };
            }
        }
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
    if (result.data.length > MAX_SYNC_PAYLOAD_BYTES) {
        console.warn(`[sync] Skipping download ${entry.type} ${entry.id}: payload ${Math.round(result.data.length / 1024 / 1024)}MB exceeds limit`);
        showToast(`Sync: ${entry.type} too large (${Math.round(result.data.length / 1024 / 1024)}MB), skipped`, 5000);
        return null;
    }
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
        const existing = await db.get('characters', entry.id);
        if (existing?.images) {
            entity.images = existing.images;
        } else if (!entity.images) {
            entity.images = [];
        }
        await db.put('characters', entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === ENTITY_TYPES.PERSONA) {
        await db.put('personas', entity);
        await clearSyncDeletedEntry(entry.type, entry.id);
} else if (entry.type === ENTITY_TYPES.CHAT) {
            await db.saveChat(entry.id, entity);
            await clearSyncDeletedEntry(entry.type, entry.id);
    } else if (entry.type === ENTITY_TYPES.LOREBOOKS) {
        await db.set('gz_lorebooks', entity);
    } else if (entry.type === ENTITY_TYPES.API_PRESETS) {
        await db.set('gz_api_connection_presets', entity);
    } else if (entry.type === ENTITY_TYPES.THEME_PRESETS) {
        await db.set('gz_theme_presets', entity);
    } else if (entry.type === ENTITY_TYPES.THEME_STATE) {
        await db.set('gz_theme_active_preset', entity);
    } else if (entry.type === ENTITY_TYPES.LOCAL_STORAGE) {
        for (const [lsKey, lsVal] of Object.entries(entity || {})) {
            if (lsKey === 'silly_cradle_presets') {
                try {
                    const cloudPresets = JSON.parse(lsVal);
                    const localRaw = localStorage.getItem('silly_cradle_presets');
                    const localPresets = localRaw ? JSON.parse(localRaw) : {};
                    for (const [pId, cloudPreset] of Object.entries(cloudPresets)) {
                        const localRegexes = localPresets[pId]?.regexes;
                        const cloudRegexes = cloudPreset.regexes;
                        if (localRegexes?.length) {
                            if (!cloudRegexes?.length) {
                                cloudPreset.regexes = localRegexes;
                            } else {
                                const cloudIds = new Set(cloudRegexes.map(r => r.id));
                                const localOnly = localRegexes.filter(r => !cloudIds.has(r.id));
                                if (localOnly.length) cloudPreset.regexes = [...cloudRegexes, ...localOnly];
                            }
                        }
                    }
                    localStorage.setItem(lsKey, JSON.stringify({ ...localPresets, ...cloudPresets }));
                } catch (e) {
                    localStorage.setItem(lsKey, lsVal);
                }
            } else if (lsKey === 'regex_scripts') {
                try {
                    const cloudScripts = JSON.parse(lsVal);
                    const localRaw = localStorage.getItem('regex_scripts');
                    const localScripts = localRaw ? JSON.parse(localRaw) : [];
                    if (!Array.isArray(cloudScripts)) {
                        localStorage.setItem(lsKey, lsVal);
                    } else if (!localScripts.length) {
                        localStorage.setItem(lsKey, lsVal);
                    } else {
                        const cloudIds = new Set(cloudScripts.map(r => r.id));
                        const localOnly = localScripts.filter(r => !cloudIds.has(r.id));
                        localStorage.setItem(lsKey, JSON.stringify([...cloudScripts, ...localOnly]));
                    }
                } catch (e) {
                    localStorage.setItem(lsKey, lsVal);
                }
            } else {
                localStorage.setItem(lsKey, lsVal);
            }
        }
    }
    return entity;
}

function getBreakdownBucket(type) {
    if (type === ENTITY_TYPES.CHARACTER) return 'characters';
    if (type === ENTITY_TYPES.PERSONA) return 'personas';
    if (type === ENTITY_TYPES.CHAT) return 'chats';
    if (type === ENTITY_TYPES.GALLERY) return 'gallery';
    return 'settings';
}

function needsConflict(localEntry, cloudEntry) {
    return !!localEntry && !localEntry.deleted && localEntry.updatedAt > cloudEntry.updatedAt;
}

async function getLocalConflictEntity(type, id) {
    if (type === ENTITY_TYPES.CHARACTER) return getLocalCharacterWithImages(id);
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

async function computeBinaryHash(arrayBuffer) {
    const digest = await crypto.subtle.digest('SHA-256', arrayBuffer);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function applyGalleryEntriesForChar(adapter, entries, charId, localEntries, onConflict) {
    const char = await getLocalCharacterWithImages(charId);
    if (!char) return entries.length;
    if (!Array.isArray(char.images)) char.images = [];

    const localHashes = new Map();
    for (const img of char.images) {
        if (img?.src) {
            try {
                const h = await computeImageHash(img.src);
                localHashes.set(h, img);
            } catch {}
        }
    }

    let applied = 0;
    const galleryConflicts = [];
    for (const cloudEntry of entries) {
        const localEntry = localEntries?.[entryKey(ENTITY_TYPES.GALLERY, cloudEntry.id)];
        if (localEntry && !localEntry.deleted && localEntry.updatedAt > cloudEntry.updatedAt) {
            const conflict = {
                type: ENTITY_TYPES.GALLERY,
                id: cloudEntry.id,
                name: `Gallery: ${cloudEntry.imgId}`,
                charId,
                imgId: cloudEntry.imgId,
                local: { imgId: localEntry.imgId, hash: localEntry.hash, updatedAt: localEntry.updatedAt },
                cloud: { imgId: cloudEntry.imgId, hash: cloudEntry.hash, updatedAt: cloudEntry.updatedAt },
                cloudModified: cloudEntry.updatedAt
            };
            galleryConflicts.push(conflict);
            if (onConflict) onConflict(conflict);
            continue;
        }

        try {
            if (cloudEntry.deleted) {
                char.images = char.images.filter(im => im.id !== cloudEntry.imgId);
                applied++;
                continue;
            }

            const binary = await adapter.downloadBinary(cloudEntry.path);
            if (!binary) continue;

            const cloudHash = await computeBinaryHash(binary);
            const existingByIdIdx = char.images.findIndex(im => im.id === cloudEntry.imgId);

            if (existingByIdIdx >= 0) {
                const blob = new Blob([binary]);
                const dataUrl = await new Promise((resolve, reject) => {
                    const reader = new FileReader();
                    reader.onload = () => resolve(reader.result);
                    reader.onerror = reject;
                    reader.readAsDataURL(blob);
                });
                const old = char.images[existingByIdIdx];
                char.images[existingByIdIdx] = { id: cloudEntry.imgId, src: dataUrl, name: old?.name || '', thumbnail: null };
                applied++;
            } else {
                const existingByHash = localHashes.get(cloudHash);
                if (existingByHash) {
                    const existingIdx = char.images.findIndex(im => im.id === existingByHash.id);
                    const blob = new Blob([binary]);
                    const dataUrl = await new Promise((resolve, reject) => {
                        const reader = new FileReader();
                        reader.onload = () => resolve(reader.result);
                        reader.onerror = reject;
                        reader.readAsDataURL(blob);
                    });
                    if (existingIdx >= 0) {
                        char.images[existingIdx] = { id: cloudEntry.imgId, src: dataUrl, name: char.images[existingIdx]?.name || '', thumbnail: null };
                    } else {
                        char.images.push({ id: cloudEntry.imgId, src: dataUrl, name: '', thumbnail: null });
                    }
                    localHashes.delete(cloudHash);
                    localHashes.set(cloudHash, { id: cloudEntry.imgId });
                    applied++;
                } else {
                    const blob = new Blob([binary]);
                    const dataUrl = await new Promise((resolve, reject) => {
                        const reader = new FileReader();
                        reader.onload = () => resolve(reader.result);
                        reader.onerror = reject;
                        reader.readAsDataURL(blob);
                    });
                    char.images.push({ id: cloudEntry.imgId, src: dataUrl, name: '', thumbnail: null });
                    localHashes.set(cloudHash, { id: cloudEntry.imgId });
                    applied++;
                }
            }
        } catch (e) {
            console.warn(`[sync] Gallery entry ${cloudEntry.imgId} for char ${charId} failed:`, e);
        }
    }

    await db.put('characters', char);
    return { applied, conflicts: galleryConflicts };
}

async function removeGalleryEntryFromChar(charId, imgId) {
    const char = await getLocalCharacterWithImages(charId);
    if (char?.images) {
        char.images = char.images.filter(im => im.id !== imgId);
        await db.put('characters', char);
    }
}

async function deleteCloudFileIfExists(adapter, entry) {
    try {
        await adapter.deleteFile(entry.path);
    } catch {
        // Ignore missing payload deletes; manifest remains source of truth.
    }
}

async function runParallel(tasks, concurrency = 5, delayMs = 200) {
    const results = [];
    let index = 0;

    async function worker() {
        while (index < tasks.length) {
            const i = index++;
            results[i] = await tasks[i]();
            if (delayMs > 0 && index < tasks.length) {
                await new Promise(r => setTimeout(r, delayMs));
            }
        }
    }

    const workers = Array.from({ length: Math.min(concurrency, tasks.length) }, () => worker());
    await Promise.all(workers);
    return results;
}

async function pushManifestV2(adapter, key, onProgress) {
    if (adapter.ensureFolder) {
        await adapter.ensureFolder(CLOUD_BASE);
    }
    const cloudManifest = await readCloudManifestV2(adapter);
    const localManifest = await buildLocalManifestV2();
    const cloudEntries = cloudManifest?.entries || {};
    const breakdown = { characters: 0, personas: 0, chats: 0, gallery: 0, settings: 0 };
    let pushed = 0;
    let skipped = 0;

    const allKeys = new Set([...Object.keys(localManifest.entries), ...Object.keys(cloudEntries)]);
    const allEntries = Array.from(allKeys);

    const singletonEntries = await collectSingletonEntries();

    const galleryDirs = new Set();
    for (const entry of Object.values(localManifest.entries)) {
        if (entry.type === ENTITY_TYPES.GALLERY && !entry.deleted && adapter.ensureFolder) {
            galleryDirs.add(`${CLOUD_BASE}/gallery/${entry.charId}`);
        }
    }
    for (const dir of galleryDirs) {
        await adapter.ensureFolder(dir);
    }

    const tasks = allEntries.map((keyName, i) => {
        const localEntry = localManifest.entries[keyName];
        const cloudEntry = cloudEntries[keyName];
        const phase = getBreakdownBucket((localEntry || cloudEntry)?.type);

        return async () => {
            if (!localEntry) {
                if (onProgress) onProgress(phase, i + 1, allEntries.length);
                return;
            }

            if (localEntry.type === ENTITY_TYPES.GALLERY) {
                const shouldUpload = !cloudEntry
                    || localEntry.deleted !== cloudEntry.deleted
                    || localEntry.hash !== cloudEntry.hash;

                if (!shouldUpload) {
                    skipped++;
                    if (onProgress) onProgress(phase, i + 1, allEntries.length);
                    return;
                }

                if (localEntry.deleted) {
                    await deleteCloudFileIfExists(adapter, localEntry);
                } else {
                    const char = await getLocalCharacterWithImages(localEntry.charId);
                    const img = char?.images?.find(im => im.id === localEntry.imgId);
                    if (img?.src) {
                        const binary = await dataUrlToBinary(img.src);
                        await adapter.uploadBinary(localEntry.path, binary);
                    } else {
                        localManifest.entries[keyName] = { ...localEntry, deleted: true, updatedAt: Date.now() };
                        await deleteCloudFileIfExists(adapter, localEntry);
                    }
                }

                pushed++;
                breakdown[phase]++;
                if (onProgress) onProgress(phase, i + 1, allEntries.length);
                return;
            }

            const shouldUpload = !cloudEntry
                || localEntry.deleted !== cloudEntry.deleted
                || localEntry.hash !== cloudEntry.hash;

            if (!shouldUpload) {
                skipped++;
                if (onProgress) onProgress(phase, i + 1, allEntries.length);
                return;
            }

            if (localEntry.deleted) {
                await deleteCloudFileIfExists(adapter, localEntry);
            } else {
                let payload = null;
                if (localEntry.type === ENTITY_TYPES.CHARACTER) payload = await getLocalCharacter(localEntry.id);
                else if (localEntry.type === ENTITY_TYPES.PERSONA) payload = await getLocalPersona(localEntry.id);
                else if (localEntry.type === ENTITY_TYPES.CHAT) payload = await getLocalChat(localEntry.id);
                else {
                    payload = singletonEntries.find(item => item.type === localEntry.type && item.id === localEntry.id)?.data ?? null;
                }

                if (payload !== null && payload !== undefined) {
                    const encrypted = await encryptEntity(payload, key);
                    const serialized = JSON.stringify(encrypted);
                    if (serialized.length > MAX_SYNC_PAYLOAD_BYTES) {
                        console.warn(`[sync] Skipping ${localEntry.type} ${localEntry.id}: payload ${Math.round(serialized.length / 1024 / 1024)}MB exceeds ${Math.round(MAX_SYNC_PAYLOAD_BYTES / 1024 / 1024)}MB limit`);
                        showToast(`${localEntry.type} too large to sync (${Math.round(serialized.length / 1024 / 1024)}MB), skipped`, 5000);
                        skipped++;
                        if (onProgress) onProgress(phase, i + 1, allEntries.length);
                        return;
                    }
                    await adapter.upload(localEntry.path, serialized);
                }
            }

            pushed++;
            breakdown[phase]++;
            if (onProgress) onProgress(phase, i + 1, allEntries.length);
        };
    });

    await runParallel(tasks, 3, 300);

    localManifest.lastSync = Date.now();
    localManifest.createdAt = cloudManifest?.createdAt || Date.now();
    await adapter.upload(cloudPath(ENTITY_TYPES.MANIFEST), JSON.stringify(localManifest));
    await writeLocalManifestV2(localManifest);

    return { pushed, skipped, total: pushed + skipped, breakdown };
}

async function pullManifestV2(adapter, key, onProgress, onConflict) {
    let cloudManifest;
    try {
        cloudManifest = await readCloudManifestV2(adapter);
    } catch (e) {
        throw new Error(`Cannot access cloud data: ${e.message}`);
    }
    if (!cloudManifest) {
        throw new Error(`Cloud manifest not found. No sync data was found in the cloud folder. If this is a new device, try pushing your local data first.`);
    }

    const localManifest = await buildLocalManifestV2();
    const cloudEntries = cloudManifest.entries || {};
    const localEntries = localManifest.entries || {};
    const allKeys = new Set([...Object.keys(cloudEntries), ...Object.keys(localEntries)]);
    const allEntries = Array.from(allKeys);
    const breakdown = { characters: 0, personas: 0, chats: 0, gallery: 0, settings: 0 };
    const decryptErrors = [];
    const conflicts = [];
    let pulled = 0;

    const galleryEntriesByChar = new Map();
    const nonGalleryTasks = [];

    for (let i = 0; i < allEntries.length; i++) {
        const keyName = allEntries[i];
        const cloudEntry = cloudEntries[keyName];
        const localEntry = localEntries[keyName];
        const phase = getBreakdownBucket((cloudEntry || localEntry)?.type);

        if (!cloudEntry) continue;

        const cloudIsNewer = !localEntry || cloudEntry.hash !== localEntry.hash || cloudEntry.deleted !== localEntry.deleted;
        if (!cloudIsNewer) continue;

        if (cloudEntry.type === ENTITY_TYPES.GALLERY) {
            if (!galleryEntriesByChar.has(cloudEntry.charId)) {
                galleryEntriesByChar.set(cloudEntry.charId, []);
            }
            galleryEntriesByChar.get(cloudEntry.charId).push(cloudEntry);
            continue;
        }

        nonGalleryTasks.push({ cloudEntry, localEntry, phase, index: i });
    }

    for (const [charId, entries] of galleryEntriesByChar) {
        const result = await applyGalleryEntriesForChar(adapter, entries, charId, localEntries, onConflict);
        pulled += result.applied;
        breakdown.gallery += result.applied;
        if (result.conflicts.length > 0) {
            conflicts.push(...result.conflicts);
        }
        for (let j = 0; j < entries.length; j++) {
            if (onProgress) onProgress('gallery', j + 1, entries.length);
        }
    }

    const ngTasks = nonGalleryTasks.map(({ cloudEntry, localEntry, phase, index }) => {
        return async () => {
            if (needsConflict(localEntry, cloudEntry)) {
                const localEntity = await getLocalConflictEntity(cloudEntry.type, cloudEntry.id);
                let cloudEntity = null;
                if (!cloudEntry.deleted) {
                    try {
                        cloudEntity = await readCloudEntityByEntry(adapter, cloudEntry, key);
                    } catch (e) {
                        decryptErrors.push({ type: cloudEntry.type, id: cloudEntry.id, error: e.message });
                        if (onProgress) onProgress(phase, index + 1, allEntries.length);
                        return;
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
                if (onProgress) onProgress(phase, index + 1, allEntries.length);
                return;
            }

            try {
                await applyCloudEntry(adapter, cloudEntry, key);
                pulled++;
                breakdown[phase]++;
            } catch (e) {
                decryptErrors.push({ type: cloudEntry.type, id: cloudEntry.id, error: e.message });
            }

            if (onProgress) onProgress(phase, index + 1, allEntries.length);
        };
    });

    await runParallel(ngTasks, 3, 300);

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
        return null;
    } catch {
        return null;
    }
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
    const char = await db.get('characters', id);
    if (!char) return null;
    const { images: _images, ...rest } = char;
    return rest;
}

async function getLocalCharacterWithImages(id) {
    return (await db.get('characters', id)) || null;
}

async function getLocalPersona(id) {
    return (await db.get('personas', id)) || null;
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

const WIPE_POLL_INTERVAL = 2000;
const WIPE_MAX_POLLS = 10;

export async function wipeCloudData(adapter, onProgress) {
    if (adapter.invalidateGlazeFolderCache) {
        adapter.invalidateGlazeFolderCache();
    }
    if (onProgress) onProgress({ phase: 'deleting', message: 'Deleting cloud data...' });
    try {
        const result = await adapter.deleteFolder(CLOUD_BASE);
        if (onProgress) onProgress({ phase: 'waiting', message: 'Waiting for cloud to finalize...' });
        let pollAttempts = 0;
        while (pollAttempts < WIPE_MAX_POLLS) {
            await new Promise(r => setTimeout(r, WIPE_POLL_INTERVAL));
            const listing = await adapter.listFolder(CLOUD_BASE);
            if (!listing || !listing.entries || listing.entries.length === 0) break;
            pollAttempts++;
            if (onProgress) onProgress({ phase: 'waiting', message: `Waiting for cloud... (${pollAttempts + 1})` });
        }
        if (onProgress) onProgress({ phase: 'recreating', message: 'Recreating cloud folder...' });
        try {
            await adapter.ensureFolder(CLOUD_BASE);
        } catch (e) {
            console.warn('[syncEngine] ensureFolder after wipe failed (may already exist):', e);
        }
        return { deleted: 'all', failed: 0, total: 'all' };
    } catch (e) {
        if (e.message?.includes('not_found') || e.message?.includes('path_not_found') || e.message?.includes('does not exist')) {
            if (onProgress) onProgress({ phase: 'recreating', message: 'Recreating cloud folder...' });
            try {
                await adapter.ensureFolder(CLOUD_BASE);
            } catch (err) {
                console.warn('[syncEngine] ensureFolder after wipe (not_found) failed:', err);
            }
            return { deleted: 0, failed: 0, total: 0 };
        }
        throw e;
    }
}

export async function resolveConflict(conflict, choice) {
    if (conflict.type === ENTITY_TYPES.GALLERY) {
        if (choice === 'local') return null;
        const char = await getLocalCharacterWithImages(conflict.charId);
        if (!char) return null;
        return char;
    }
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
        const existing = await db.get('characters', conflict.id);
        if (existing?.images && !entity.images) {
            entity.images = existing.images;
        }
        await db.put('characters', entity);
    } else if (conflict.type === ENTITY_TYPES.PERSONA) {
        await db.put('personas', entity);
    } else if (conflict.type === ENTITY_TYPES.CHAT) {
        await db.saveChat(conflict.id, entity);
    }
    return entity;
}

export { ENTITY_TYPES, CLOUD_BASE, cloudPath, getDeviceId };
