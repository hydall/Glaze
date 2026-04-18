import { Capacitor } from '@capacitor/core';
import { Browser } from '@capacitor/browser';
import { App } from '@capacitor/app';
import { db } from '@/utils/db.js';
import { SYNC_TOKENS_KEY } from '@/core/states/syncState.js';

const DROPBOX_APP_KEY = import.meta.env.VITE_DROPBOX_APP_KEY || '';
const REDIRECT_URI_NATIVE = import.meta.env.VITE_DROPBOX_REDIRECT_NATIVE || 'com.hydall.glaze://oauth/dropbox';
const REDIRECT_URI_WEB = import.meta.env.VITE_DROPBOX_REDIRECT_WEB || `${window.location.origin}/oauth/dropbox/redirect.html`;
const API_BASE = 'https://api.dropboxapi.com/2';
const CONTENT_BASE = 'https://content.dropboxapi.com/2';

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
    return all.dropbox || null;
}

async function saveTokens(tokens) {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    all.dropbox = tokens;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

async function clearTokens() {
    const all = (await db.get(SYNC_TOKENS_KEY)) || {};
    delete all.dropbox;
    await db.queuedSet(SYNC_TOKENS_KEY, all);
}

async function getValidToken() {
    const tokens = await getTokens();
    if (!tokens) return null;

    try {
        await listFolder('');
        return tokens.access_token;
    } catch (e) {
        if (e.status === 401 && tokens.refresh_token) {
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
}

async function refreshAccessToken(refreshToken) {
    if (!DROPBOX_APP_KEY) throw new Error('Dropbox app key not configured');

    const response = await fetch('https://api.dropboxapi.com/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            grant_type: 'refresh_token',
            refresh_token: refreshToken,
            client_id: DROPBOX_APP_KEY
        })
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error_description || 'Token refresh failed'), { status: response.status });
    }

    const data = await response.json();
    const newTokens = {
        access_token: data.access_token,
        refresh_token: refreshToken,
        expires_at: Date.now() + (data.expires_in || 14400) * 1000,
        account_id: data.account_id
    };
    await saveTokens(newTokens);
    return newTokens;
}

export async function connect() {
    if (!DROPBOX_APP_KEY) {
        throw new Error('Dropbox is not configured. Set VITE_DROPBOX_APP_KEY environment variable.');
    }

    const verifier = generateRandomString(64);
    const challenge = await sha256(verifier);
    const usePlain = !challenge;
    const redirectUri = getRedirectUri();
    const state = generateRandomString(16);

    localStorage.setItem('gz_dropbox_pkce_verifier', verifier);
    localStorage.setItem('gz_dropbox_pkce_state', state);

    const authUrl = new URL('https://www.dropbox.com/oauth2/authorize');
    authUrl.searchParams.set('client_id', DROPBOX_APP_KEY);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('code_challenge', usePlain ? verifier : challenge);
    authUrl.searchParams.set('code_challenge_method', usePlain ? 'plain' : 'S256');
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('token_access_type', 'offline');
    authUrl.searchParams.set('state', state);

    if (Capacitor.isNativePlatform()) {
        const listener = await App.addListener('appUrlOpen', async (data) => {
            try {
                const url = new URL(data.url);
                const code = url.searchParams.get('code');
                const returnedState = url.searchParams.get('state');

                if (!code) return;

                if (returnedState !== state) {
                    console.error('[dropboxAdapter] State mismatch');
                    return;
                }

                await exchangeCodeForToken(code, verifier, redirectUri);
            } catch (e) {
                console.error('[dropboxAdapter] OAuth callback error:', e);
            } finally {
                listener.remove();
                try { await Browser.close(); } catch {}
            }
        });

        await Browser.open({ url: authUrl.toString() });
    } else if (isElectron()) {
        const code = await waitForElectronOAuth(redirectUri, state);
        if (code) {
            await exchangeCodeForToken(code, verifier, redirectUri);
        } else {
            throw new Error('Authorization cancelled');
        }
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

async function waitForElectronOAuth(redirectUri, expectedState) {
    const ipcRenderer = window.require('electron').ipcRenderer;
    const port = await ipcRenderer.invoke('oauth-start-server');
    redirectUri = `http://127.0.0.1:${port}/oauth/callback`;

    const authUrl = new URL('https://www.dropbox.com/oauth2/authorize');
    authUrl.searchParams.set('client_id', DROPBOX_APP_KEY);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('code_challenge', localStorage.getItem('gz_dropbox_pkce_verifier'));
    authUrl.searchParams.set('code_challenge_method', 'plain');
    authUrl.searchParams.set('redirect_uri', redirectUri);
    authUrl.searchParams.set('token_access_type', 'offline');
    authUrl.searchParams.set('state', expectedState);

    const width = 500;
    const height = 600;
    const left = window.screenX + (window.outerWidth - width) / 2;
    const top = window.screenY + (window.outerHeight - height) / 2;
    const win = window.open(authUrl.toString(), 'dropbox-auth', `width=${width},height=${height},left=${left},top=${top}`);

    return new Promise((resolve) => {
        let resolved = false;

        const cleanup = () => clearInterval(interval);

        ipcRenderer.once('oauth-callback', (event, { code, state: returnedState, error }) => {
            if (resolved) return;
            resolved = true;
            cleanup();
            try { if (win && !win.closed) win.close(); } catch {}

            if (error || !code) { resolve(null); return; }
            if (returnedState !== expectedState) {
                console.error('[dropboxAdapter] State mismatch');
                resolve(null);
                return;
            }
            resolve(code);
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
        const win = window.open(authUrl, 'dropbox-auth', `width=${width},height=${height},left=${left},top=${top}`);

        let resolved = false;

        const onMessage = (e) => {
            if (resolved) return;
            if (e.data?.type === 'dropbox-oauth') {
                resolved = true;
                cleanup();
                const state = e.data.state;
                if (state !== expectedState) {
                    console.error('[dropboxAdapter] State mismatch');
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
    const response = await fetch('https://api.dropboxapi.com/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            grant_type: 'authorization_code',
            code,
            code_verifier: verifier,
            client_id: DROPBOX_APP_KEY,
            redirect_uri: redirectUri
        })
    });

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw new Error(err.error_description || 'Token exchange failed');
    }

    const data = await response.json();
    await saveTokens({
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: Date.now() + (data.expires_in || 14400) * 1000,
        account_id: data.account_id,
        uid: data.uid
    });

    localStorage.removeItem('gz_dropbox_pkce_verifier');
    localStorage.removeItem('gz_dropbox_pkce_state');

    await ensureFolder('/Glaze');
}

export async function disconnect() {
    const tokens = await getTokens();
    if (tokens?.access_token) {
        try {
            await fetch('https://api.dropboxapi.com/2/auth/token/revoke', {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${tokens.access_token}` }
            });
        } catch {}
    }
    await clearTokens();
}

export async function isConnected() {
    const tokens = await getTokens();
    if (!tokens) return false;
    const valid = await getValidToken();
    return valid !== null;
}

async function apiCall(endpoint, body, accessToken) {
    if (!accessToken) {
        const tokens = await getTokens();
        if (!tokens) throw new Error('Not connected to Dropbox');
        accessToken = tokens.access_token;
    }

    const response = await fetch(`${API_BASE}${endpoint}`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(body)
    });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            return apiCall(endpoint, body, refreshed.access_token);
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error?.tag || err.error_summary || `API error ${response.status}`), { status: response.status });
    }

    if (response.status === 204) return null;
    return response.json();
}

async function contentUpload(path, data, accessToken) {
    if (!accessToken) {
        const tokens = await getTokens();
        if (!tokens) throw new Error('Not connected to Dropbox');
        accessToken = tokens.access_token;
    }

    const body = typeof data === 'string' ? data : JSON.stringify(data);

    const response = await fetch(`${CONTENT_BASE}/files/upload`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/octet-stream',
            'Dropbox-API-Arg': JSON.stringify({
                path,
                mode: 'overwrite',
                autorename: false,
                mute: true
            })
        },
        body
    });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            return contentUpload(path, data, refreshed.access_token);
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (!response.ok) {
        const err = await response.json().catch(() => ({}));
        throw Object.assign(new Error(err.error?.tag || err.error_summary || `Upload failed ${response.status}`), { status: response.status });
    }

    return response.json();
}

async function contentDownload(path, accessToken) {
    if (!accessToken) {
        const tokens = await getTokens();
        if (!tokens) throw new Error('Not connected to Dropbox');
        accessToken = tokens.access_token;
    }

    const response = await fetch(`${CONTENT_BASE}/files/download`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Dropbox-API-Arg': JSON.stringify({ path })
        }
    });

    if (response.status === 401) {
        const tokens = await getTokens();
        if (tokens?.refresh_token) {
            const refreshed = await refreshAccessToken(tokens.refresh_token);
            return contentDownload(path, refreshed.access_token);
        }
        throw Object.assign(new Error('Session expired'), { status: 401 });
    }

    if (response.status === 409) {
        return null;
    }

    if (!response.ok) {
        throw Object.assign(new Error(`Download failed ${response.status}`), { status: response.status });
    }

    const metadata = JSON.parse(response.headers.get('dropbox-api-result') || '{}');
    const text = await response.text();
    return { data: text, metadata };
}

const APP_FOLDER_PREFIX = '/Glaze';

function stripAppFolderPrefix(path) {
    if (path === APP_FOLDER_PREFIX || path === APP_FOLDER_PREFIX + '/') return '';
    if (path.startsWith(APP_FOLDER_PREFIX + '/')) return path.slice(APP_FOLDER_PREFIX.length);
    return path;
}

export async function ensureFolder(path) {
    const strippedPath = stripAppFolderPrefix(path);
    const parts = strippedPath.split('/').filter(Boolean);
    if (parts.length === 0) return;
    let currentPath = '';
    for (const part of parts) {
        currentPath = currentPath + '/' + part;
        try {
            await apiCall('/files/create_folder_v2', { path: currentPath, autorename: false });
        } catch (e) {
            if (e.message?.includes('conflict') || e.message?.includes('already_exists')) {
                continue;
            }
            throw e;
        }
    }
}

export async function listFolder(path) {
    return apiCall('/files/list_folder', { path: stripAppFolderPrefix(path) || '', recursive: false, include_deleted: false });
}

export async function listFolderContinue(cursor) {
    return apiCall('/files/list_folder/continue', { cursor });
}

export async function upload(path, data) {
    return contentUpload(stripAppFolderPrefix(path), data);
}

export async function download(path) {
    return contentDownload(stripAppFolderPrefix(path));
}

export async function deleteFile(fileOrPath) {
    const path = typeof fileOrPath === 'string'
        ? fileOrPath
        : (fileOrPath?.path_display || fileOrPath?.path || '');
    return apiCall('/files/delete_v2', { path: stripAppFolderPrefix(path) });
}

export async function getAccountInfo() {
    const tokens = await getTokens();
    if (!tokens) return null;
    try {
        const result = await apiCall('/users/get_current_account', null, tokens.access_token);
        return {
            name: result.name?.display_name || 'Dropbox User',
            email: result.email,
            accountId: result.account_id
        };
    } catch {
        return null;
    }
}
