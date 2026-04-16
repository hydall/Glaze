const ALGO = 'AES-GCM';
const KEY_LENGTH = 256;
const IV_LENGTH = 12;
const PBKDF2_ITERATIONS = 600000;

function getSubtle() {
    if (!crypto || !crypto.subtle) {
        throw new Error('Web Crypto API is not available. Sync requires a secure context (HTTPS or localhost).');
    }
    return crypto.subtle;
}

export async function generateAesKey() {
    return getSubtle().generateKey(
        { name: ALGO, length: KEY_LENGTH },
        true,
        ['encrypt', 'decrypt']
    );
}

export async function exportKey(key) {
    const raw = await getSubtle().exportKey('raw', key);
    return arrayBufferToBase64(raw);
}

export async function importKey(base64Key) {
    const raw = base64ToArrayBuffer(base64Key);
    return getSubtle().importKey(
        'raw',
        raw,
        { name: ALGO, length: KEY_LENGTH },
        true,
        ['encrypt', 'decrypt']
    );
}

export async function deriveKeyFromPassword(password, salt) {
    const encoder = new TextEncoder();
    const keyMaterial = await getSubtle().importKey(
        'raw',
        encoder.encode(password),
        'PBKDF2',
        false,
        ['deriveKey']
    );
    return getSubtle().deriveKey(
        {
            name: 'PBKDF2',
            salt: salt,
            iterations: PBKDF2_ITERATIONS,
            hash: 'SHA-256'
        },
        keyMaterial,
        { name: ALGO, length: KEY_LENGTH },
        true,
        ['encrypt', 'decrypt']
    );
}

export async function encrypt(data, key) {
    const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH));
    const encoder = new TextEncoder();
    const encoded = encoder.encode(typeof data === 'string' ? data : JSON.stringify(data));

    const ciphertext = await getSubtle().encrypt(
        { name: ALGO, iv },
        key,
        encoded
    );

    return {
        iv: arrayBufferToBase64(iv.buffer),
        data: arrayBufferToBase64(ciphertext)
    };
}

export async function decrypt(encrypted, key) {
    const iv = base64ToArrayBuffer(encrypted.iv);
    const ciphertext = base64ToArrayBuffer(encrypted.data);

    const decrypted = await getSubtle().decrypt(
        { name: ALGO, iv },
        key,
        ciphertext
    );

    const decoder = new TextDecoder();
    const text = decoder.decode(decrypted);
    try {
        return JSON.parse(text);
    } catch {
        return text;
    }
}

export async function encryptBinary(uint8Array, key) {
    const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH));

    const ciphertext = await getSubtle().encrypt(
        { name: ALGO, iv },
        key,
        uint8Array
    );

    return {
        iv: arrayBufferToBase64(iv.buffer),
        data: arrayBufferToBase64(ciphertext)
    };
}

export async function decryptBinary(encrypted, key) {
    const iv = base64ToArrayBuffer(encrypted.iv);
    const ciphertext = base64ToArrayBuffer(encrypted.data);

    const decrypted = await getSubtle().decrypt(
        { name: ALGO, iv },
        key,
        ciphertext
    );

    return new Uint8Array(decrypted);
}

export function generateSalt(length = 16) {
    return crypto.getRandomValues(new Uint8Array(length));
}

export function arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    for (let i = 0; i < bytes.byteLength; i++) {
        binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
}

export function base64ToArrayBuffer(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }
    return bytes.buffer;
}
