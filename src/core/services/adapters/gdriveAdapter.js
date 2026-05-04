import { Capacitor } from '@capacitor/core';
import { Browser } from '@capacitor/browser';
import { App } from '@capacitor/app';
import { db } from '@/utils/db.js';
import { GDRIVE_CLIENT_ID, GDRIVE_CLIENT_SECRET } from '@/core/config/syncConfig.js';
import { SYNC_TOKENS_KEY } from '@/core/states/syncState.js';
import { safeUploadFetch } from './nativeFetch.js';

const getNativeRedirectUri = () => {
    if (import.meta.env.VITE_GDRIVE_REDIRECT_NATIVE) return import.meta.env.VITE_GDRIVE_REDIRECT_NATIVE;
    if (GDRIVE_CLIENT_ID && GDRIVE_CLIENT_ID.endsWith('.apps.googleusercontent.com')) {
        return GDRIVE_CLIENT_ID.split('.').reverse().join('.') + ':/oauth2redirect';
    }
    return 'com.hydall.glaze://oauth/gdrive';
};
const REDIRECT_URI_NATIVE = getNativeRedirectUri();
const REDIRECT_URI_WEB = import.meta.env.VITE_GDRIVE_REDIRECT_WEB || `${window.location.origin}/oauth/gdrive/redirect.html`;
const API_BASE = 'https://www.googleapis.com/drive/v3';
const UPLOAD_BASE = 'https://www.googleapis.com/upload/drive/v3';
const AUTH_BASE = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';

const SCOPES = 'https://www.googleapis.com/auth/drive.file';

const FOLDER_NAME = 'Glaze';
let folderIdCache = null;
let pickerApiLoaded = false;

const _fileIdCache = new Map();

function loadFileIdCache() {
    try {
        const raw = localStorage.getItem('gz_gdrive_file_id_cache');
        if (raw) {
            const parsed = JSON.parse(raw);
            for (const [k, v] of Object.entries(parsed)) _fileIdCache.set(k, v);
        }
    } catch {}
}

function saveFileIdCache() {
    try {
        const obj = Object.fromEntries(_fileIdCache.entries());
        localStorage.setItem('gz_gdrive_file_id_cache', JSON.stringify(obj));
    } catch {}
}

function cacheFileId(path, fileId) {
    _fileIdCache.set(path, fileId);
    saveFileIdCache();
}

function getCachedFileId(path) {
    return _fileIdCache.get(path) || null;
}

loadFileIdCache();

function getRedirectUri() {
    if (Capacitor.isNativePlatform()) return REDIRECT_URI_NATIVE;
    if (isElectron()) return `http://127.0.0.1:${localStorage.getItem('gz_electron_oauth_port') || '0'}/oauth/callback`;
    return REDIRECT_URI_WEB;
}

function generateRandomString(length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    const array = crypto.getRandomValues(new Uint8Array(length));
    return Array.from(array, b => chars[b % chars.length]).join('');
}

async function sha256(text) {
    if (!crypto.subtle) return null;
    const encoder = new TextEncoder();
    const data = encoder.encode(text);
    const hash = await crypto.subtle.digest('SHA-256', data);
    return btoa(String.fromCharCode(...new Uint8Array(hash)))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function getTokens() {
    const all = await db.get(SYNC_TOKENS_KEY);
    if (!all) return null;
    return all.gdrive || null;
}

async function saveTokens(tokens) {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    all.gdrive = tokens;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

async function clearTokens() {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    delete all.gdrive;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

async function refreshAccessToken(refreshToken) {
    if (!GDRIVE_CLIENT_ID) throw new Error('Google Drive client ID not configured');

    const params = {
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
        client_id: GDRIVE_CLIENT_ID,
        ...(GDRIVE_CLIENT_SECRET && { client_secret: GDRIVE_CLIENT_SECRET })
    };

    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params)
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error_description || 'Token refresh failed'), { status: response.status });
    }

    const existing = await getTokens();
    const data = await response.json();
    const newTokens = {
        access_token: data.access_token,
        refresh_token: refreshToken,
        expires_at: Date.now() + (data.expires_in || 3600) * 1000,
        ...(existing?.folderId ? { folderId: existing.folderId } : {})
    };
    await saveTokens(newTokens);
    return newTokens;
}

async function getValidAccessToken() {
    const tokens = await getTokens();
    if (!tokens) return null;

    if (tokens.expires_at && Date.now() < tokens.expires_at - 60000) {
        return tokens.access_token;
    }

    if (tokens.refresh_token) {
        try {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            return refreshed.access_token;
        } catch {
            await clearTokens();
            return null;
        }
    }

    return null;
}

async function apiRequest(url, options = {}) {
    const accessToken = await getValidAccessToken();
    if (!accessToken) throw new Error('Not connected to Google Drive');

    const headers = {
        'Authorization': `Bearer ${accessToken}`,
        ...options.headers
    };

    const response = await fetch(url, { ...options, headers });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            headers.Authorization = `Bearer ${refreshed.access_token}`;
            return fetch(url, { ...options, headers });
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    return response;
}

export async function connect() {
    if (!GDRIVE_CLIENT_ID) {
        throw new Error('Google Drive is not configured. Set VITE_GDRIVE_CLIENT_ID environment variable.');
    }

    const verifier = generateRandomString(64);
    const challenge = await sha256(verifier);
    const usePlain = !challenge;
    const state = generateRandomString(16);

    localStorage.setItem('gz_gdrive_pkce_verifier', verifier);
    localStorage.setItem('gz_gdrive_pkce_state', state);

    if (isElectron()) {
        const result = await waitForElectronOAuth(challenge, usePlain, state, verifier);
        if (result) {
            await exchangeCodeForToken(result.code, verifier, result.redirectUri);
        } else {
            throw new Error('Authorization cancelled');
        }
        return;
    }

    const redirectUri = getRedirectUri();
    const authUrl = new URL(AUTH_BASE);
    authUrl.searchParams.set('client_id', GDRIVE_CLIENT_ID);
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('scope', SCOPES);
    authUrl.searchParams.set('code_challenge', usePlain ? verifier : challenge);
    authUrl.searchParams.set('code_challenge_method', usePlain ? 'plain' : 'S256');
    authUrl.searchParams.set('state', state);
    authUrl.searchParams.set('access_type', 'offline');
    authUrl.searchParams.set('prompt', 'consent');

    if (Capacitor.isNativePlatform()) {
        await new Promise((resolve, reject) => {
            App.addListener('appUrlOpen', async (data) => {
                try {
                    const url = new URL(data.url);
                    const code = url.searchParams.get('code');
                    const returnedState = url.searchParams.get('state');

                    if (!code) return;

                    if (returnedState !== state) {
                        reject(new Error('State mismatch'));
                        return;
                    }

                    await exchangeCodeForToken(code, verifier, redirectUri);
                    resolve();
                } catch (e) {
                    reject(e);
                } finally {
                    try { await Browser.close(); } catch { }
                }
            }).then(listener => {
                Browser.open({ url: authUrl.toString() }).catch(reject);
            });
        });
    } else {
        const code = await waitForWebOAuth(authUrl.toString(), state);
        if (code) {
            await exchangeCodeForToken(code, verifier, redirectUri);
        } else {
            throw new Error('Authorization cancelled');
        }
    }
}

function isElectron() {
    return typeof navigator !== 'undefined' && navigator.userAgent.includes('Electron');
}

async function waitForElectronOAuth(challenge, usePlain, state, verifier) {
    const ipcRenderer = window.require('electron').ipcRenderer;
    const port = await ipcRenderer.invoke('oauth-start-server');
    const redirectUri = `http://127.0.0.1:${port}/oauth/callback`;

    const authUrl = new URL(AUTH_BASE);
    authUrl.searchParams.set('client_id', GDRIVE_CLIENT_ID);
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('scope', SCOPES);
    authUrl.searchParams.set('code_challenge', usePlain ? verifier : challenge);
    authUrl.searchParams.set('code_challenge_method', usePlain ? 'plain' : 'S256');
    authUrl.searchParams.set('state', state);
    authUrl.searchParams.set('access_type', 'offline');
    authUrl.searchParams.set('prompt', 'consent');

    const width = 500;
    const height = 600;
    const left = window.screenX + (window.outerWidth - width) / 2;
    const top = window.screenY + (window.outerHeight - height) / 2;
    const win = window.open(authUrl.toString(), 'gdrive-auth', `width=${width},height=${height},left=${left},top=${top}`);

    return new Promise((resolve) => {
        let resolved = false;
        let interval;
        const cleanup = () => clearInterval(interval);

        ipcRenderer.once('oauth-callback', (event, { code, state: returnedState, error }) => {
            if (resolved) return;
            resolved = true;
            cleanup();
            try { if (win && !win.closed) win.close(); } catch { }

            if (error || !code) { resolve(null); return; }
            if (returnedState !== state) {
                console.error('[gdriveAdapter] State mismatch');
                resolve(null);
                return;
            }
            resolve({ code, redirectUri });
        });

        interval = setInterval(() => {
            if (resolved) return;
            try {
                if (win && win.closed) {
                    resolved = true;
                    cleanup();
                    ipcRenderer.invoke('oauth-cancel-server');
                    resolve(null);
                }
            } catch {
                resolved = true;
                cleanup();
                resolve(null);
            }
        }, 1000);
    });
}

function waitForWebOAuth(authUrl, expectedState) {
    return new Promise((resolve) => {
        const width = 500;
        const height = 600;
        const left = window.screenX + (window.outerWidth - width) / 2;
        const top = window.screenY + (window.outerHeight - height) / 2;
        const win = window.open(authUrl, 'gdrive-auth', `width=${width},height=${height},left=${left},top=${top}`);

        let resolved = false;
        let interval;
        let onMessage;

        const cleanup = () => {
            clearInterval(interval);
            window.removeEventListener('message', onMessage);
        };

        onMessage = (e) => {
            if (resolved) return;
            if (e.data?.type === 'gdrive-oauth') {
                resolved = true;
                cleanup();
                const state = e.data.state;
                if (state !== expectedState) {
                    console.error('[gdriveAdapter] State mismatch');
                    resolve(null);
                    return;
                }
                resolve(e.data.code || null);
            }
        };

        interval = setInterval(() => {
            if (resolved) return;
            try {
                if (win.closed) {
                    cleanup();
                    resolve(null);
                }
            } catch {
                cleanup();
                resolve(null);
            }
        }, 1000);

        window.addEventListener('message', onMessage);
    });
}

async function exchangeCodeForToken(code, verifier, redirectUri) {
    const params = {
        grant_type: 'authorization_code',
        code,
        code_verifier: verifier,
        client_id: GDRIVE_CLIENT_ID,
        redirect_uri: redirectUri,
        ...(GDRIVE_CLIENT_SECRET && { client_secret: GDRIVE_CLIENT_SECRET })
    };

    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params)
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error_description || 'Token exchange failed');
    }

    const data = await response.json();
    await saveTokens({
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: Date.now() + (data.expires_in || 3600) * 1000,
        token_type: data.token_type
    });

    localStorage.removeItem('gz_gdrive_pkce_verifier');
    localStorage.removeItem('gz_gdrive_pkce_state');

    folderIdCache = null;
}

export async function disconnect() {
    const tokens = await getTokens();
    if (tokens?.access_token) {
        try {
            await fetch(`https://oauth2.googleapis.com/revoke?token=${tokens.access_token}`, {
                method: 'POST'
            });
        } catch { }
    }
    await clearTokens();
    folderIdCache = null;
}

export async function isConnected() {
    const token = await getValidAccessToken();
    return token !== null;
}

async function findFoldersByName(name, parentId) {
    let query = `name='${name}' and mimeType='application/vnd.google-apps.folder' and trashed=false`;
    if (parentId) {
        query += ` and '${parentId}' in parents`;
    } else {
        query += ` and 'root' in parents`;
    }

    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name)&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || `Failed to search for folder '${name}' (${response.status})`);
    }
    const data = await response.json();
    return data.files || [];
}

async function findFolderByName(name, parentId) {
    let query = `name='${name}' and mimeType='application/vnd.google-apps.folder' and trashed=false`;
    if (parentId) {
        query += ` and '${parentId}' in parents`;
    } else {
        query += ` and 'root' in parents`;
    }

    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name)&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || `Failed to search for folder '${name}' (${response.status})`);
    }
    const data = await response.json();
    return data.files?.[0]?.id || null;
}

async function folderHasContent(folderId) {
    const query = `'${folderId}' in parents and trashed=false`;
    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id)&pageSize=1&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );
    if (!response.ok) return false;
    const data = await response.json();
    return (data.files?.length || 0) > 0;
}

export function invalidateGlazeFolderCache() {
    folderIdCache = null;
    _folderIdCache.clear();
    _fileIdCache.clear();
    saveFileIdCache();
}

export async function setGlazeFolderId(folderId) {
    folderIdCache = folderId;
    const tokens = await getTokens();
    if (tokens) {
        tokens.folderId = folderId;
        await saveTokens(tokens);
    }
}

async function loadPickerApi() {
    if (pickerApiLoaded && window.google?.picker) return;
    return new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = 'https://apis.google.com/js/api.js';
        script.onload = () => {
            window.gapi.load('picker', {
                callback: () => { pickerApiLoaded = true; resolve(); },
                onerror: () => reject(new Error('Failed to load Google Picker API'))
            });
        };
        script.onerror = () => reject(new Error('Failed to load Google API script'));
        document.head.appendChild(script);
    });
}

export async function pickFolder() {
    const accessToken = await getValidAccessToken();
    if (!accessToken) throw new Error('Not connected to Google Drive');

    await loadPickerApi();

    return new Promise((resolve, reject) => {
        try {
            const appId = GDRIVE_CLIENT_ID?.split('-')[0] || '';
            const view = new window.google.picker.DocsView(
                window.google.picker.ViewId.DOCS
            )
                .setSelectFolderEnabled(true)
                .setMimeTypes('application/vnd.google-apps.folder')
                .setMode(window.google.picker.DocsViewMode.LIST);

            const picker = new window.google.picker.PickerBuilder()
                .setAppId(appId)
                .setOAuthToken(accessToken)
                .addView(view)
                .setTitle('Select Glaze folder')
                .setCallback((data) => {
                    if (data.action === window.google.picker.Action.PICKED) {
                        const folder = data.docs[0];
                        resolve({ id: folder.id, name: folder.name });
                    } else if (data.action === window.google.picker.Action.CANCEL) {
                        resolve(null);
                    }
                })
                .build();
            picker.setVisible(true);
        } catch (e) {
            reject(e);
        }
    });
}

export { getGlazeFolderId };

export function extractFolderId(input) {
    if (!input) return null;
    input = input.trim();
    const driveUrlMatch = input.match(/\/folders\/([a-zA-Z0-9_-]+)/);
    if (driveUrlMatch) return driveUrlMatch[1];
    const openUrlMatch = input.match(/[?&]id=([a-zA-Z0-9_-]+)/);
    if (openUrlMatch) return openUrlMatch[1];
    if (/^[a-zA-Z0-9_-]{10,}$/.test(input)) return input;
    return null;
}

export async function verifyFolderId(folderId) {
    try {
        const response = await apiRequest(
            `${API_BASE}/files/${encodeURIComponent(folderId)}?fields=id,name,mimeType,trashed&supportsAllDrives=true`
        );
        if (!response.ok) return null;
        const data = await response.json();
        if (data.trashed) return null;
        if (data.mimeType !== 'application/vnd.google-apps.folder') return null;
        return data;
    } catch {
        return null;
    }
}

async function getGlazeFolderId(invalidate = false) {
    if (invalidate) {
        folderIdCache = null;
        _folderIdCache.clear();
    }
    if (folderIdCache) {
        const check = await apiRequest(`${API_BASE}/files/${folderIdCache}?fields=id,trashed,name&supportsAllDrives=true`);
        if (check.ok) {
            const data = await check.json();
            if (!data.trashed && data.name === FOLDER_NAME) return folderIdCache;
        }
        folderIdCache = null;
        _folderIdCache.clear();
    }
    const persistedTokens = await getTokens();
    if (persistedTokens?.folderId && persistedTokens.folderId !== folderIdCache) {
        const check = await apiRequest(`${API_BASE}/files/${persistedTokens.folderId}?fields=id,trashed,name&supportsAllDrives=true`);
        if (check.ok) {
            const data = await check.json();
            if (!data.trashed && data.name === FOLDER_NAME) {
                folderIdCache = persistedTokens.folderId;
                _folderIdCache.clear();
                return folderIdCache;
            }
        }
    }
    const folders = await findFoldersByName(FOLDER_NAME, null);
    if (folders.length === 0) return null;
    if (folders.length === 1) {
        folderIdCache = folders[0].id;
        return folderIdCache;
    }
    let bestFolder = null;
    for (const folder of folders) {
        const manifestFile = await findFileByName('manifest.json', folder.id);
        if (manifestFile) {
            bestFolder = folder;
            break;
        }
    }
    if (!bestFolder) {
        for (const folder of folders) {
            if (await folderHasContent(folder.id)) {
                bestFolder = folder;
                break;
            }
        }
    }
    if (!bestFolder) {
        bestFolder = folders[0];
    }
    folderIdCache = bestFolder.id;
    for (const folder of folders) {
        if (folder.id !== bestFolder.id) {
            const hasContent = await folderHasContent(folder.id);
            if (!hasContent) {
                try {
                    await apiRequest(`${API_BASE}/files/${folder.id}`, { method: 'DELETE' });
                } catch {}
            }
        }
    }
    return folderIdCache;
}

async function createFolder(name, parentId) {
    const body = {
        name,
        mimeType: 'application/vnd.google-apps.folder'
    };
    if (parentId) {
        body.parents = [parentId];
    }

    const response = await apiRequest(`${API_BASE}/files?fields=id&supportsAllDrives=true`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || 'Failed to create folder');
    }

    const data = await response.json();
    return data.id;
}

async function getOrCreateFolder(name, parentId) {
    const existingId = await findFolderByName(name, parentId);
    if (existingId) return existingId;
    return createFolder(name, parentId);
}

const _folderIdCache = new Map();

export async function ensureFolder(path) {
    const parts = path.split('/').filter(Boolean);
    let parentId = null;

    if (parts[0] === FOLDER_NAME) {
        parentId = await getGlazeFolderId();
        if (!parentId) {
            parentId = await createFolder(FOLDER_NAME, null);
            folderIdCache = parentId;
            _folderIdCache.clear();
        }
        for (let i = 1; i < parts.length; i++) {
            parentId = await getOrCreateFolder(parts[i], parentId);
        }
    } else {
        for (const part of parts) {
            parentId = await getOrCreateFolder(part, parentId);
        }
    }

    if (path === '/Glaze') {
        folderIdCache = parentId;
    }

    return parentId;
}

async function resolvePathToParent(path) {
    const parts = path.replace(/^\//, '').split('/');
    const fileName = parts.pop();
    let parentId = await getGlazeFolderId();

    if (!parentId) return { parentId: null, fileName };

    for (const dir of parts) {
        if (dir === FOLDER_NAME) continue;
        const cacheKey = `${parentId}/${dir}`;
        if (_folderIdCache.has(cacheKey)) {
            parentId = _folderIdCache.get(cacheKey);
            continue;
        }
        const existing = await findFolderByName(dir, parentId);
        if (existing) {
            _folderIdCache.set(cacheKey, existing);
            parentId = existing;
        } else {
            const created = await createFolder(dir, parentId);
            _folderIdCache.set(cacheKey, created);
            parentId = created;
        }
    }

    return { parentId, fileName };
}

async function findFileByName(name, parentId) {
    if (!parentId) return null;
    const query = `name='${name}' and '${parentId}' in parents and trashed=false`;
    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name,modifiedTime)&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) {
        if (response.status === 404) return null;
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error?.message || `Failed to search for file '${name}' (${response.status})`);
    }
    const data = await response.json();
    return data.files?.[0] || null;
}

export async function upload(path, data) {
    const { parentId, fileName } = await resolvePathToParent(path);
    let existingFile = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) existingFile = info;
        }
    }
    if (!existingFile) {
        existingFile = await findFileByName(fileName, parentId);
        if (existingFile) cacheFileId(path, existingFile.id);
    }

    const body = typeof data === 'string' ? data : JSON.stringify(data);

    if (existingFile) {
        const accessToken = await getValidAccessToken();
        if (!accessToken) throw new Error('Not connected to Google Drive');

        const response = await safeUploadFetch(
            `${UPLOAD_BASE}/files/${existingFile.id}?uploadType=media&supportsAllDrives=true`,
            {
                method: 'PATCH',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/octet-stream'
                },
                body
            }
        );

        if (response.status === 401) {
            const tokens = await getTokens();
            if (tokens?.refresh_token) {
                const refreshed = await refreshAccessToken(tokens.refresh_token);
                const retry = await safeUploadFetch(
                    `${UPLOAD_BASE}/files/${existingFile.id}?uploadType=media&supportsAllDrives=true`,
                    {
                        method: 'PATCH',
                        headers: {
                            'Authorization': `Bearer ${refreshed.access_token}`,
                            'Content-Type': 'application/octet-stream'
                        },
                        body
                    }
                );
                if (!retry.ok) throw new Error(`Upload failed ${retry.status}`);
                return retry.json();
            }
            throw Object.assign(new Error('Session expired'), { status: 401 });
        }

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error?.message || `Upload failed ${response.status}`);
        }

        return response.json();
    } else {
        const accessToken = await getValidAccessToken();
        if (!accessToken) throw new Error('Not connected to Google Drive');

        const metadata = {
            name: fileName,
            parents: [parentId]
        };

        const boundary = 'glaze_boundary_' + generateRandomString(16);
        const multipartBody =
            `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n` +
            `--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n${body}\r\n` +
            `--${boundary}--`;

        const response = await safeUploadFetch(
            `${UPLOAD_BASE}/files?uploadType=multipart&fields=id`,
            {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': `multipart/related; boundary=${boundary}`
                },
                body: multipartBody
            }
        );

        if (response.status === 401) {
            const tokens = await getTokens();
            if (tokens?.refresh_token) {
                const refreshed = await refreshAccessToken(tokens.refresh_token);
                const retry = await safeUploadFetch(
`${UPLOAD_BASE}/files?uploadType=multipart&fields=id&supportsAllDrives=true`,
                    {
                        method: 'POST',
                        headers: {
                            'Authorization': `Bearer ${refreshed.access_token}`,
                            'Content-Type': `multipart/related; boundary=${boundary}`
                        },
                        body: multipartBody
                    }
                );
                if (!retry.ok) throw new Error(`Upload failed ${retry.status}`);
                return retry.json();
            }
            throw Object.assign(new Error('Session expired'), { status: 401 });
        }

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error?.message || `Upload failed ${response.status}`);
        }

        const result = await response.json();
        if (result?.id) cacheFileId(path, result.id);
        return result;
    }
}

export async function uploadBinary(path, arrayBuffer) {
    if (!arrayBuffer) return null;
    const { parentId, fileName } = await resolvePathToParent(path);
    let existingFile = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) existingFile = info;
        }
    }
    if (!existingFile) {
        existingFile = await findFileByName(fileName, parentId);
        if (existingFile) cacheFileId(path, existingFile.id);
    }
    const accessToken = await getValidAccessToken();
    if (!accessToken) throw new Error('Not connected to Google Drive');

    if (existingFile) {
        const response = await safeUploadFetch(
            `${UPLOAD_BASE}/files/${existingFile.id}?uploadType=media&supportsAllDrives=true`,
            {
                method: 'PATCH',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/octet-stream'
                },
                body: arrayBuffer
            }
        );
        if (!response.ok) throw new Error(`Binary upload failed ${response.status}`);
        return response.json();
    }

    const metadata = { name: fileName, parents: [parentId] };
    const boundary = 'glaze_boundary_' + generateRandomString(16);
    const metaPart = `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n`;
    const binaryBlob = new Blob([arrayBuffer]);
    const multipartBody = new Blob([
        new TextEncoder().encode(metaPart),
        new TextEncoder().encode(`--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n`),
        binaryBlob,
        new TextEncoder().encode(`\r\n--${boundary}--`)
    ]);

    const response = await safeUploadFetch(
        `${UPLOAD_BASE}/files?uploadType=multipart&fields=id&supportsAllDrives=true`,
        {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${accessToken}`,
                'Content-Type': `multipart/related; boundary=${boundary}`
            },
            body: multipartBody
        }
    );
    if (!response.ok) throw new Error(`Binary upload failed ${response.status}`);
    const result = await response.json();
    if (result?.id) cacheFileId(path, result.id);
    return result;
}

export async function downloadBinary(path, _retry = false) {
    const { parentId, fileName } = await resolvePathToParent(path);
    let file = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) file = info;
        }
    }
    if (!file) {
        file = await findFileByName(fileName, parentId);
        if (file) cacheFileId(path, file.id);
    }

    if (!file) {
        if (!_retry && parentId === folderIdCache) {
            invalidateGlazeFolderCache();
            return downloadBinary(path, true);
        }
        return null;
    }

    const response = await apiRequest(
        `${API_BASE}/files/${file.id}?alt=media&supportsAllDrives=true`
    );

    if (!response.ok) {
        if (response.status === 404) return null;
        throw new Error(`Binary download failed ${response.status}`);
    }

    return response.arrayBuffer();
}

export async function download(path, _retry = false) {
    const { parentId, fileName } = await resolvePathToParent(path);
    let file = null;
    const cachedId = getCachedFileId(path);
    if (cachedId) {
        const check = await apiRequest(`${API_BASE}/files/${cachedId}?fields=id,name,trashed&supportsAllDrives=true`);
        if (check.ok) {
            const info = await check.json();
            if (!info.trashed) file = info;
        }
    }
    if (!file) {
        file = await findFileByName(fileName, parentId);
        if (file) cacheFileId(path, file.id);
    }

    if (!file) {
        if (!_retry && parentId === folderIdCache) {
            invalidateGlazeFolderCache();
            return download(path, true);
        }
        return null;
    }

    const response = await apiRequest(
        `${API_BASE}/files/${file.id}?alt=media&supportsAllDrives=true`
    );

    if (!response.ok) {
        if (response.status === 404) return null;
        throw new Error(`Download failed ${response.status}`);
    }

    const text = await response.text();
    return {
        data: text,
        metadata: { id: file.id, modifiedTime: file.modifiedTime }
    };
}

export async function listFolder(path) {
    const parts = path.replace(/^\//, '').split('/').filter(Boolean);
    let parentId = null;

    if (parts.length === 0 || (parts.length === 1 && parts[0] === FOLDER_NAME)) {
        parentId = await getGlazeFolderId();
    } else {
        const folderName = parts[parts.length - 1];
        const parentPath = '/' + parts.slice(0, -1).join('/');
        const { parentId: resolvedParent } = await resolvePathToParent(parentPath || `/${FOLDER_NAME}`);
        const folder = await findFolderByName(folderName, resolvedParent);
        parentId = folder;
    }

    if (!parentId) return { entries: [] };

    const query = `'${parentId}' in parents and trashed=false`;
    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name,mimeType,modifiedTime)&pageSize=1000&includeItemsFromAllDrives=true&supportsAllDrives=true`
    );

    if (!response.ok) return { entries: [] };

    const data = await response.json();
    const entries = (data.files || []).map(f => ({
        '.tag': f.mimeType === 'application/vnd.google-apps.folder' ? 'folder' : 'file',
        name: f.name,
        path: path === '/Glaze' ? `/Glaze/${f.name}` : `${path}/${f.name}`,
        path_display: path === '/Glaze' ? `/Glaze/${f.name}` : `${path}/${f.name}`,
        serverModified: f.modifiedTime,
        id: f.id
    }));

    return { entries, has_more: false };
}

export async function listFolderContinue() {
    return { entries: [], has_more: false };
}

const GLAZE_PATH_PREFIX = '/Glaze';

function assertGlazePath(path) {
    if (!path || !path.startsWith(GLAZE_PATH_PREFIX)) {
        throw new Error(`Refusing to delete outside Glaze folder: ${path}`);
    }
}

export async function deleteFolder(path) {
    assertGlazePath(path);
    if (path === '/Glaze' || path === `/${FOLDER_NAME}`) {
        const folderId = await getGlazeFolderId();
        if (!folderId) return false;
        const verifyResponse = await apiRequest(`${API_BASE}/files/${folderId}?fields=name&supportsAllDrives=true`);
        if (verifyResponse.ok) {
            const verifyData = await verifyResponse.json();
            if (verifyData.name !== FOLDER_NAME) {
                throw new Error(`Safety check failed: folder ID ${folderId} is named "${verifyData.name}", expected "${FOLDER_NAME}". Aborting delete.`);
            }
        }
        const response = await apiRequest(`${API_BASE}/files/${folderId}?supportsAllDrives=true`, { method: 'DELETE' });
        if (!response.ok && response.status !== 204) {
            throw new Error(`Delete folder failed ${response.status}`);
        }
        folderIdCache = null;
        _folderIdCache.clear();
        return true;
    }
    const parts = path.replace(/^\//, '').split('/').filter(Boolean);
    const folderName = parts[parts.length - 1];
    const parentPath = '/' + parts.slice(0, -1).join('/');
    const { parentId } = await resolvePathToParent(parentPath);
    const folderId = await findFolderByName(folderName, parentId);
    if (!folderId) return false;
    const response = await apiRequest(`${API_BASE}/files/${folderId}?supportsAllDrives=true`, { method: 'DELETE' });
    if (!response.ok && response.status !== 204) {
        throw new Error(`Delete folder failed ${response.status}`);
    }
    return true;
}

export async function deleteFile(fileOrPath) {
    let fileId = null;
    let resolvedPath = '';

    if (typeof fileOrPath === 'object' && fileOrPath?.id) {
        fileId = fileOrPath.id;
        resolvedPath = fileOrPath?.path_display || fileOrPath?.path || '';
    } else {
        resolvedPath = typeof fileOrPath === 'string'
            ? fileOrPath
            : (fileOrPath?.path_display || fileOrPath?.path || '');
        assertGlazePath(resolvedPath);
        const { parentId, fileName } = await resolvePathToParent(resolvedPath);
        const file = await findFileByName(fileName, parentId);
        if (!file) return null;
        fileId = file.id;
    }

    const response = await apiRequest(
        `${API_BASE}/files/${fileId}?supportsAllDrives=true`,
        { method: 'DELETE' }
    );

    if (!response.ok && response.status !== 204) {
        throw new Error(`Delete failed ${response.status}`);
    }

    return null;
}

export async function getAccountInfo() {
    const accessToken = await getValidAccessToken();
    if (!accessToken) return null;

    try {
        const response = await fetch('https://www.googleapis.com/oauth2/v2/userinfo', {
            headers: { 'Authorization': `Bearer ${accessToken}` }
        });

        if (!response.ok) return null;
        const data = await response.json();
        return {
            name: data.name || 'Google User',
            email: data.email,
            accountId: data.id
        };
    } catch {
        return null;
    }
}
