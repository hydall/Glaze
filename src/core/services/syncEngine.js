import { hasSyncKey } from '@/core/services/crypto/keyManager.js';

import { entryKey, clone, getDeviceId, readLocalManifestV2, writeLocalManifestV2, collectSingletonEntries, buildLocalManifestV2, readCloudManifestV2 } from './sync/syncManifest.js';
import { dataUrlToBinary, computeImageHash, guessImageExt, computeBinaryHash, applyGalleryEntriesForChar, removeGalleryEntryFromChar } from './sync/syncGallery.js';
import { needsConflict, getLocalConflictEntity, getConflictName, resolveConflict as _resolveConflict } from './sync/syncConflict.js';
import { computeSyncHash, encryptEntity, decryptEntity, getLocalCharacter, getLocalCharacterWithImages, getLocalPersona, getLocalChat, deleteCloudFileIfExists, readCloudEntityByEntry, applyCloudEntry } from './sync/syncSerialization.js';

export { ENTITY_TYPES, CLOUD_BASE, cloudPath, getDeviceId };
export { computeSyncHash } from './sync/syncSerialization.js';
export { entryKey, MANIFEST_VERSION } from './sync/syncManifest.js';
export { needsConflict, getLocalConflictEntity, getConflictName } from './sync/syncConflict.js';
export { getLocalCharacter, getLocalCharacterWithImages, getLocalPersona, getLocalChat } from './sync/syncSerialization.js';
export { computeImageHash, guessImageExt, dataUrlToBinary, computeBinaryHash } from './sync/syncGallery.js';
export { buildManifest, readLocalManifestV2, writeLocalManifestV2, buildLocalManifestV2, readCloudManifestV2, collectSingletonEntries } from './sync/syncManifest.js';
export { applyCloudEntry, readCloudEntityByEntry, encryptEntity, decryptEntity, deleteCloudFileIfExists } from './sync/syncSerialization.js';
export { applyGalleryEntriesForChar, removeGalleryEntryFromChar } from './sync/syncGallery.js';

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

function getBreakdownBucket(type) {
    if (type === ENTITY_TYPES.CHARACTER) return 'characters';
    if (type === ENTITY_TYPES.PERSONA) return 'personas';
    if (type === ENTITY_TYPES.CHAT) return 'chats';
    if (type === ENTITY_TYPES.GALLERY) return 'gallery';
    return 'settings';
}

async function getCloudVerificationCandidate(adapter) {
    const cloudFiles = await listAllFiles(adapter);
    const candidate = cloudFiles.find(file => {
        const path = file.path_display || file.path || '';
        return path !== cloudPath(ENTITY_TYPES.MANIFEST);
    });
    if (!candidate) return null;
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

const _deps = { computeSyncHash, cloudPath, galleryCloudPath, computeImageHash, guessImageExt, entryKey, ENTITY_TYPES, getLocalCharacterWithImages, getLocalPersona, getLocalChat, listAllFiles };

async function pushManifestV2(adapter, key, onProgress) {
    if (adapter.ensureFolder) {
        await adapter.ensureFolder(CLOUD_BASE);
    }
    const cloudManifest = await readCloudManifestV2(adapter, _deps);
    const localManifest = await buildLocalManifestV2(_deps);
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
                        console.warn(`[sync] Gallery image ${localEntry.imgId} for char ${localEntry.charId} has no src, skipping push`);
                        skipped++;
                        if (onProgress) onProgress(phase, i + 1, allEntries.length);
                        return;
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
        cloudManifest = await readCloudManifestV2(adapter, _deps);
    } catch (e) {
        throw new Error(`Cannot access cloud data: ${e.message}`);
    }
    if (!cloudManifest) {
        throw new Error(`Cloud manifest not found. No sync data was found in the cloud folder. If this is a new device, try pushing your local data first.`);
    }

    const localManifest = await buildLocalManifestV2(_deps);
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

        if (localEntry?.deleted && !cloudEntry.deleted) continue;

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
        const result = await applyGalleryEntriesForChar(adapter, entries, charId, localEntries, onConflict, { entryKey, ENTITY_TYPES });
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
                const localEntity = await getLocalConflictEntity(cloudEntry.type, cloudEntry.id, _deps);
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
                    cloudModified: cloudEntry.updatedAt,
                    localModified: localEntry.updatedAt
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

const WIPE_POLL_INTERVAL = 2000;
const WIPE_MAX_POLLS = 10;

export async function wipeCloudData(adapter, onProgress) {
    if (adapter.invalidateGlazeFolderCache) {
        adapter.invalidateGlazeFolderCache();
    }
    if (adapter.invalidateFolderCache) {
        adapter.invalidateFolderCache();
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
    return _resolveConflict(conflict, choice, { ENTITY_TYPES, getLocalCharacterWithImages });
}
