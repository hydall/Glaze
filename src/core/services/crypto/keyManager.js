import { generateAesKey, exportKey, importKey, encrypt, decrypt, deriveKeyFromPassword, generateSalt, arrayBufferToBase64, base64ToArrayBuffer } from './syncCrypto.js';
import { db } from '@/utils/db.js';

const KEY_STORAGE_KEY = 'gz_sync_key';
const SALT_STORAGE_KEY = 'gz_sync_salt';

import { generateMnemonic, mnemonicToEntropy, validateMnemonic } from '@scure/bip39';
import { wordlist } from '@scure/bip39/wordlists/english.js';

export async function generateSyncKey() {
    const key = await generateAesKey();
    const exportedKey = await exportKey(key);
    const salt = generateSalt(16);
    const saltBase64 = arrayBufferToBase64(salt.buffer);

    const mnemonic = generateMnemonic(wordlist, 128);

    await db.queuedSet(KEY_STORAGE_KEY, exportedKey);
    await db.queuedSet(SALT_STORAGE_KEY, saltBase64);

    return {
        key,
        recoveryPhrase: mnemonic,
        salt
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

    if (!validateMnemonic(trimmed, wordlist)) {
        throw new Error('Invalid recovery phrase. Please check your 12-word phrase and try again.');
    }

    const entropy = mnemonicToEntropy(trimmed, wordlist);
    const entropyBytes = hexToBytes(entropy);

    const encoder = new TextEncoder();
    const keyMaterial = await crypto.subtle.importKey(
        'raw',
        encoder.encode(trimmed),
        'PBKDF2',
        false,
        ['deriveKey']
    );

    const existingSalt = await db.get(SALT_STORAGE_KEY);
    let salt;
    if (existingSalt) {
        salt = new Uint8Array(base64ToArrayBuffer(existingSalt));
    } else {
        salt = generateSalt(16);
        await db.queuedSet(SALT_STORAGE_KEY, arrayBufferToBase64(salt.buffer));
    }

    const derivedKey = await deriveKeyFromPassword(trimmed, salt);
    const exportedDerived = await exportKey(derivedKey);

    await db.queuedSet(KEY_STORAGE_KEY, exportedDerived);

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

function hexToBytes(hex) {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
        bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return bytes;
}
