import { Capacitor } from '@capacitor/core';
import { Browser } from '@capacitor/browser';
import { App } from '@capacitor/app';
import { db } from '@/utils/db.js';

const DROPBOX_APP_KEY = import.meta.env.VITE_DROPBOX_APP_KEY || '';
const REDIRECT_URI_NATIVE = 'com.hydall.glaze://oauth/dropbox';
const REDIRECT_URI_WEB = `${window.location.origin}/oauth/dropbox`;
const API_BASE = 'https://api.dropboxapi.com/2';
const CONTENT_BASE = 'https://content.dropboxapi.com/2';
const TOKEN_KEY = 'gz_sync_tokens';

function getRedirectUri() {
    return Capacitor.isNativePlatform() ? REDIRECT_URI_NATIVE : REDIRECT_URI_WEB;
}

function generateRandomString(length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    const array = crypto.getRandomValues(new Uint8Array(length));
    return Array.from(array, b => chars[b % chars.length]).join('');
}

async function sha256(text) {
    const encoder = new TextEncoder();
    const data = encoder.encode(text);
    const hash = await crypto.subtle.digest('SHA-256', data);
    return btoa(String.fromCharCode(...new Uint8Array(hash)))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function getTokens() {
    const all = await db.get(TOKEN_KEY);
    if (!all) return null;
    return all.dropbox || null;
}

async function saveTokens(tokens) {
    const all = (await db.get(TOKEN_KEY)) || {};
    all.dropbox = tokens;
    await db.queuedSet(TOKEN_KEY, all);
}

async function clearTokens() {
    const all = (await db.get(TOKEN_KEY)) || {};
    delete all.dropbox;
    await db.queuedSet(TOKEN_KEY, all);
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
    const redirectUri = getRedirectUri();
    const state = generateRandomString(16);

    localStorage.setItem('gz_dropbox_pkce_verifier', verifier);
    localStorage.setItem('gz_dropbox_pkce_state', state);

    const authUrl = new URL('https://www.dropbox.com/oauth2/authorize');
    authUrl.searchParams.set('client_id', DROPBOX_APP_KEY);
    authUrl.searchParams.set('response_type', 'code');
    authUrl.searchParams.set('code_challenge', challenge);
    authUrl.searchParams.set('code_challenge_method', 'S256');
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
    } else {
        const code = await waitForWebOAuth(authUrl.toString(), state);
        if (code) {
            await exchangeCodeForToken(code, verifier, redirectUri);
        }
    }
}

function waitForWebOAuth(authUrl, expectedState) {
    return new Promise((resolve) => {
        const width = 500;
        const height = 600;
        const left = window.screenX + (window.outerWidth - width) / 2;
        const top = window.screenY + (window.outerHeight - height) / 2;
        const win = window.open(authUrl, 'dropbox-auth', `width=${width},height=${height},left=${left},top=${top}`);

        const interval = setInterval(() => {
            try {
                if (win.closed) {
                    clearInterval(interval);
                    resolve(null);
                    return;
                }
                const url = win.location.href;
                if (url && (url.includes('code=') || url.includes('error='))) {
                    clearInterval(interval);
                    const params = new URL(url).searchParams;
                    const code = params.get('code');
                    const state = params.get('state');
                    win.close();

                    if (state !== expectedState) {
                        console.error('[dropboxAdapter] State mismatch');
                        resolve(null);
                        return;
                    }
                    resolve(code);
                }
            } catch {}
        }, 500);
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

export async function ensureFolder(path) {
    try {
        await apiCall('/files/create_folder_v2', { path, autorename: false });
    } catch (e) {
        if (e.message?.includes('conflict') || e.message?.includes('already_exists')) {
            return;
        }
        throw e;
    }
}

export async function listFolder(path) {
    return apiCall('/files/list_folder', { path, recursive: false, include_deleted: false });
}

export async function listFolderContinue(cursor) {
    return apiCall('/files/list_folder/continue', { cursor });
}

export async function upload(path, data) {
    return contentUpload(path, data);
}

export async function download(path) {
    return contentDownload(path);
}

export async function deleteFile(path) {
    return apiCall('/files/delete_v2', { path });
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
