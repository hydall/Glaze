import { Capacitor } from '@capacitor/core';
import { Browser } from '@capacitor/browser';
import { App } from '@capacitor/app';
import { db } from '@/utils/db.js';
import { SYNC_TOKENS_KEY } from '@/core/states/syncState.js';

const GDRIVE_CLIENT_ID = import.meta.env.VITE_GDRIVE_CLIENT_ID || '';
const GDRIVE_CLIENT_SECRET = import.meta.env.VITE_GDRIVE_CLIENT_SECRET || '';
const REDIRECT_URI_NATIVE = import.meta.env.VITE_GDRIVE_REDIRECT_NATIVE || 'com.hydall.glaze://oauth/gdrive';
const REDIRECT_URI_WEB = import.meta.env.VITE_GDRIVE_REDIRECT_WEB || `${window.location.origin}/oauth/gdrive/redirect.html`;
const API_BASE = 'https://www.googleapis.com/drive/v3';
const UPLOAD_BASE = 'https://www.googleapis.com/upload/drive/v3';
const AUTH_BASE = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';

const SCOPES = 'https://www.googleapis.com/auth/drive.file';

const FOLDER_NAME = 'Glaze';
let folderIdCache = null;

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
        client_id: GDRIVE_CLIENT_ID
    };
    if (GDRIVE_CLIENT_SECRET) params.client_secret = GDRIVE_CLIENT_SECRET;

    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(params)
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error_description || 'Token refresh failed'), { status: response.status });
    }

    const data = await response.json();
    const newTokens = {
        access_token: data.access_token,
        refresh_token: refreshToken,
        expires_at: Date.now() + (data.expires_in || 3600) * 1000
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
        const listener = await App.addListener('appUrlOpen', async (data) => {
            try {
                const url = new URL(data.url);
                const code = url.searchParams.get('code');
                const returnedState = url.searchParams.get('state');

                if (!code) return;

                if (returnedState !== state) {
                    console.error('[gdriveAdapter] State mismatch');
                    return;
                }

                await exchangeCodeForToken(code, verifier, redirectUri);
            } catch (e) {
                console.error('[gdriveAdapter] OAuth callback error:', e);
            } finally {
                listener.remove();
                try { await Browser.close(); } catch {}
            }
        });

        await Browser.open({ url: authUrl.toString() });
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

        const cleanup = () => clearInterval(interval);

        ipcRenderer.once('oauth-callback', (event, { code, state: returnedState, error }) => {
            if (resolved) return;
            resolved = true;
            cleanup();
            try { if (win && !win.closed) win.close(); } catch {}

            if (error || !code) { resolve(null); return; }
            if (returnedState !== state) {
                console.error('[gdriveAdapter] State mismatch');
                resolve(null);
                return;
            }
            resolve({ code, redirectUri });
        });

        const interval = setInterval(() => {
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

        const onMessage = (e) => {
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

        const interval = setInterval(() => {
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

        const cleanup = () => {
            clearInterval(interval);
            window.removeEventListener('message', onMessage);
        };

        window.addEventListener('message', onMessage);
    });
}

async function exchangeCodeForToken(code, verifier, redirectUri) {
    const params = {
        grant_type: 'authorization_code',
        code,
        code_verifier: verifier,
        client_id: GDRIVE_CLIENT_ID,
        redirect_uri: redirectUri
    };
    if (GDRIVE_CLIENT_SECRET) params.client_secret = GDRIVE_CLIENT_SECRET;

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
    await ensureFolder('/Glaze');
}

export async function disconnect() {
    const tokens = await getTokens();
    if (tokens?.access_token) {
        try {
            await fetch(`https://oauth2.googleapis.com/revoke?token=${tokens.access_token}`, {
                method: 'POST'
            });
        } catch {}
    }
    await clearTokens();
    folderIdCache = null;
}

export async function isConnected() {
    const token = await getValidAccessToken();
    return token !== null;
}

async function findFolderByName(name, parentId) {
    let query = `name='${name}' and mimeType='application/vnd.google-apps.folder' and trashed=false`;
    if (parentId) {
        query += ` and '${parentId}' in parents`;
    } else {
        query += ` and 'root' in parents`;
    }

    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name)`
    );

    if (!response.ok) return null;
    const data = await response.json();
    return data.files?.[0]?.id || null;
}

async function createFolder(name, parentId) {
    const body = {
        name,
        mimeType: 'application/vnd.google-apps.folder'
    };
    if (parentId) {
        body.parents = [parentId];
    }

    const response = await apiRequest(`${API_BASE}/files?fields=id`, {
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

export async function ensureFolder(path) {
    const parts = path.split('/').filter(Boolean);
    let parentId = null;

    for (const part of parts) {
        const folderId = await getOrCreateFolder(part, parentId);
        parentId = folderId;
    }

    if (path === '/Glaze') {
        folderIdCache = parentId;
    }

    return parentId;
}

async function getGlazeFolderId() {
    if (folderIdCache) return folderIdCache;
    folderIdCache = await findFolderByName(FOLDER_NAME, null);
    if (!folderIdCache) {
        folderIdCache = await createFolder(FOLDER_NAME, null);
    }
    return folderIdCache;
}

async function resolvePathToParent(path) {
    const parts = path.replace(/^\//, '').split('/');
    const fileName = parts.pop();
    let parentId = await getGlazeFolderId();

    for (const dir of parts) {
        if (dir === FOLDER_NAME) continue;
        parentId = await getOrCreateFolder(dir, parentId);
    }

    return { parentId, fileName };
}

async function findFileByName(name, parentId) {
    const query = `name='${name}' and '${parentId}' in parents and trashed=false`;
    const response = await apiRequest(
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name,modifiedTime)`
    );

    if (!response.ok) return null;
    const data = await response.json();
    return data.files?.[0] || null;
}

export async function upload(path, data) {
    const { parentId, fileName } = await resolvePathToParent(path);
    const existingFile = await findFileByName(fileName, parentId);

    const body = typeof data === 'string' ? data : JSON.stringify(data);

    if (existingFile) {
        const response = await apiRequest(
            `${UPLOAD_BASE}/files/${existingFile.id}?uploadType=media`,
            {
                method: 'PATCH',
                headers: { 'Content-Type': 'application/octet-stream' },
                body
            }
        );

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error?.message || `Upload failed ${response.status}`);
        }

        return response.json();
    } else {
        const metadata = {
            name: fileName,
            parents: [parentId]
        };

        const boundary = 'glaze_boundary_' + generateRandomString(16);
        const multipartBody =
            `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n` +
            `--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n${body}\r\n` +
            `--${boundary}--`;

        const response = await apiRequest(
            `${UPLOAD_BASE}/files?uploadType=multipart&fields=id`,
            {
                method: 'POST',
                headers: { 'Content-Type': `multipart/related; boundary=${boundary}` },
                body: multipartBody
            }
        );

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error?.message || `Upload failed ${response.status}`);
        }

        return response.json();
    }
}

export async function download(path) {
    const { parentId, fileName } = await resolvePathToParent(path);
    const file = await findFileByName(fileName, parentId);

    if (!file) return null;

    const response = await apiRequest(
        `${API_BASE}/files/${file.id}?alt=media`
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
        `${API_BASE}/files?q=${encodeURIComponent(query)}&spaces=drive&fields=files(id,name,mimeType,modifiedTime)&pageSize=1000`
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

export async function deleteFile(fileOrPath) {
    let fileId = null;

    if (typeof fileOrPath === 'object' && fileOrPath?.id) {
        fileId = fileOrPath.id;
    } else {
        const path = typeof fileOrPath === 'string'
            ? fileOrPath
            : (fileOrPath?.path_display || fileOrPath?.path || '');
        const { parentId, fileName } = await resolvePathToParent(path);
        const file = await findFileByName(fileName, parentId);
        if (!file) return null;
        fileId = file.id;
    }

    const response = await apiRequest(
        `${API_BASE}/files/${fileId}`,
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
