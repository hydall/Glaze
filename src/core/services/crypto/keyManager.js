import { exportKey, importKey, encrypt, decrypt, deriveKeyFromPassword, arrayBufferToBase64, base64ToArrayBuffer } from './syncCrypto.js';
import { db } from '@/utils/db.js';

const KEY_STORAGE_KEY = 'gz_sync_key';
const SALT_STORAGE_KEY = 'gz_sync_salt';

import { generateMnemonic, validateMnemonic } from '@scure/bip39';
import { wordlist } from '@scure/bip39/wordlists/english.js';

const SYNC_SALT = new TextEncoder().encode('GlazeSync-v1-derivation');

export async function generateSyncKey() {
    const mnemonic = generateMnemonic(wordlist, 128);

    const key = await deriveKeyFromPassword(mnemonic, SYNC_SALT);
    const exportedKey = await exportKey(key);
    const saltBase64 = arrayBufferToBase64(SYNC_SALT.buffer);

    await db.queuedSet(KEY_STORAGE_KEY, exportedKey);
    await db.queuedSet(SALT_STORAGE_KEY, saltBase64);

    return {
        key,
        recoveryPhrase: mnemonic,
        salt: SYNC_SALT
    };
}

export async function getSyncKey() {
    const exportedKey = await db.get(KEY_STORAGE_KEY);
    if (!exportedKey) return null;
    try {
        return await importKey(exportedKey);
    } catch (e) {
        console.error('[keyManager] Failed to import sync key:', e);
        return null;
    }
}

export async function hasSyncKey() {
    const key = await db.get(KEY_STORAGE_KEY);
    return key !== undefined && key !== null;
}

export async function restoreKeyFromPhrase(mnemonic) {
    const trimmed = mnemonic.trim().toLowerCase();
    console.log('[keyManager] restoreKeyFromPhrase, words:', trimmed.split(/\s+/).length);

    const valid = validateMnemonic(trimmed, wordlist);
    console.log('[keyManager] validateMnemonic result:', valid);

    if (!valid) {
        throw new Error('Invalid recovery phrase. Please check your 12-word phrase and try again.');
    }

    const derivedKey = await deriveKeyFromPassword(trimmed, SYNC_SALT);
    const exportedDerived = await exportKey(derivedKey);
    const saltBase64 = arrayBufferToBase64(SYNC_SALT.buffer);

    await db.queuedSet(KEY_STORAGE_KEY, exportedDerived);
    await db.queuedSet(SALT_STORAGE_KEY, saltBase64);

    console.log('[keyManager] Key restored and saved');
    return derivedKey;
}

export async function deleteSyncKey() {
    await db.delete('keyvalue', KEY_STORAGE_KEY);
    await db.delete('keyvalue', SALT_STORAGE_KEY);
}

export async function getSalt() {
    const saltBase64 = await db.get(SALT_STORAGE_KEY);
    if (!saltBase64) return null;
    return new Uint8Array(base64ToArrayBuffer(saltBase64));
}

export async function encryptForSync(data, key) {
    return encrypt(data, key);
}

export async function decryptFromSync(encrypted, key) {
    return decrypt(encrypted, key);
}


