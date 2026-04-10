import { InAppBrowser } from '@capgo/inappbrowser';

const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const AUTHORIZE_URL = 'https://claude.ai/oauth/authorize';
const TOKEN_URL = 'https://console.anthropic.com/v1/oauth/token';
const REDIRECT_URI = 'https://console.anthropic.com/oauth/code/callback';
const SCOPE = 'org:create_api_key user:profile user:inference';

// Buffer in milliseconds before expiry to trigger proactive refresh
const EXPIRY_BUFFER_MS = 60000;

// Map of presetId -> pending refresh Promise for deduplication
const refreshPromises = new Map();

function base64url(bytes) {
    return btoa(String.fromCharCode(...bytes))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=/g, '');
}

export async function generatePKCE() {
    const verifierBytes = new Uint8Array(32);
    crypto.getRandomValues(verifierBytes);
    const code_verifier = base64url(verifierBytes);

    const encoder = new TextEncoder();
    const data = encoder.encode(code_verifier);
    const digest = await crypto.subtle.digest('SHA-256', data);
    const code_challenge = base64url(new Uint8Array(digest));

    const stateBytes = new Uint8Array(16);
    crypto.getRandomValues(stateBytes);
    const state = base64url(stateBytes);

    return { code_verifier, code_challenge, state };
}

export function buildAuthorizationURL(pkce) {
    const params = new URLSearchParams({
        client_id: CLIENT_ID,
        response_type: 'code',
        redirect_uri: REDIRECT_URI,
        scope: SCOPE,
        code_challenge: pkce.code_challenge,
        code_challenge_method: 'S256',
        state: pkce.state,
        code: 'true'
    });
    return `${AUTHORIZE_URL}?${params.toString().replace(/\+/g, '%20')}`;
}

export async function exchangeCodeForTokens(code, codeVerifier, state) {
    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            grant_type: 'authorization_code',
            client_id: CLIENT_ID,
            code,
            code_verifier: codeVerifier,
            redirect_uri: REDIRECT_URI,
            state
        })
    });

    if (!response.ok) {
        const text = await response.text();
        throw new Error(`Token exchange failed: ${response.status} ${text}`);
    }

    const data = await response.json();
    return {
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: Date.now() + (data.expires_in || 3600) * 1000
    };
}

async function refreshAccessToken(refreshToken) {
    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            grant_type: 'refresh_token',
            client_id: CLIENT_ID,
            refresh_token: refreshToken
        })
    });

    if (!response.ok) {
        const text = await response.text();
        throw new Error(`Token refresh failed: ${response.status} ${text}`);
    }

    const data = await response.json();
    return {
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: Date.now() + (data.expires_in || 3600) * 1000
    };
}

export async function getValidAccessToken(oauth, presetId, onTokenRefresh) {
    if (!oauth) {
        throw new Error('Not authenticated');
    }

    const isExpiringSoon = !oauth.expires_at || oauth.expires_at - Date.now() < EXPIRY_BUFFER_MS;

    if (!isExpiringSoon) {
        return oauth.access_token;
    }

    // Deduplicate concurrent refresh calls for the same preset
    if (refreshPromises.has(presetId)) {
        return refreshPromises.get(presetId);
    }

    const refreshPromise = refreshAccessToken(oauth.refresh_token)
        .then(newTokens => {
            if (onTokenRefresh) onTokenRefresh(newTokens);
            return newTokens.access_token;
        })
        .finally(() => {
            refreshPromises.delete(presetId);
        });

    refreshPromises.set(presetId, refreshPromise);
    return refreshPromise;
}

export async function startOAuthFlow() {
    const pkce = await generatePKCE();
    const authUrl = buildAuthorizationURL(pkce);

    return new Promise((resolve, reject) => {
        let settled = false;

        const cleanup = () => {
            InAppBrowser.removeAllListeners();
        };

        InAppBrowser.addListener('urlChangeEvent', async ({ url }) => {
            if (settled) return;
            if (!url.includes('console.anthropic.com/oauth/code/callback')) return;

            settled = true;
            cleanup();

            try {
                await InAppBrowser.close();
            } catch (e) {
                console.warn('Failed to close InAppBrowser:', e);
            }

            try {
                const params = new URL(url).searchParams;
                const code = params.get('code');
                const state = params.get('state');

                if (!code) {
                    reject(new Error('No authorization code in callback URL'));
                    return;
                }

                if (state !== pkce.state) {
                    reject(new Error('OAuth state mismatch'));
                    return;
                }

                const tokens = await exchangeCodeForTokens(code, pkce.code_verifier, state);
                resolve(tokens);
            } catch (e) {
                reject(e);
            }
        });

        InAppBrowser.addListener('browserFinished', () => {
            if (settled) return;
            settled = true;
            cleanup();
            reject(new Error('Authorization cancelled by user'));
        });

        InAppBrowser.openWebView({
            url: authUrl,
            title: 'Authorize with Claude',
            isPresentAfterPageLoad: true
        }).catch(e => {
            if (!settled) {
                settled = true;
                cleanup();
                reject(e);
            }
        });
    });
}

export function _resetRefreshPromises() {
    refreshPromises.clear();
}
