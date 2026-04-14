import { Capacitor } from '@capacitor/core';
import { sha256 } from 'js-sha256';

const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const AUTHORIZE_URL = 'https://claude.ai/oauth/authorize';
const TOKEN_URL = Capacitor.isNativePlatform()
    ? 'https://console.anthropic.com/v1/oauth/token'
    : '/anthropic/oauth/token';
const REDIRECT_URI = 'https://console.anthropic.com/oauth/code/callback';
const SCOPE = 'user:profile user:inference user:sessions:claude_code';

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

function generatePKCE() {
    const verifierBytes = new Uint8Array(32);
    crypto.getRandomValues(verifierBytes);
    const code_verifier = base64url(verifierBytes);

    const digest = sha256.arrayBuffer(code_verifier);
    const code_challenge = base64url(new Uint8Array(digest));

    const stateBytes = new Uint8Array(32);
    crypto.getRandomValues(stateBytes);
    const state = base64url(stateBytes);

    return { code_verifier, code_challenge, state };
}

function buildAuthorizationURL(pkce) {
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

// Parse a pasted callback value. Accepts either the full callback URL
// (https://console.anthropic.com/oauth/code/callback?code=...&state=...)
// or the raw authorization code shown on the callback page.
// Manual paste is under direct user control, so state validation is skipped —
// there is no CSRF surface when the user copies the code by hand.
function parseCallbackInput(input) {
    const trimmed = input.trim();
    let code = null;

    if (/^https?:\/\//i.test(trimmed)) {
        code = new URL(trimmed).searchParams.get('code');
    } else {
        // Raw paste. Claude Code's CLI flow displays the code as `code#state`.
        code = trimmed.split('#')[0] || null;
    }

    // Defensive: the `code` value may embed `#state` even when pasted via URL.
    if (code && code.includes('#')) {
        code = code.split('#')[0] || null;
    }

    return code;
}

async function exchangeCodeForTokens(code, pkce) {
    const response = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            grant_type: 'authorization_code',
            client_id: CLIENT_ID,
            code,
            code_verifier: pkce.code_verifier,
            redirect_uri: REDIRECT_URI,
            state: pkce.state
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

// Public API -----------------------------------------------------------------

/**
 * Begin an authorization attempt. Generates a fresh PKCE pair and builds the
 * authorize URL. Opening the URL in a browser is the caller's responsibility
 * (native: Capacitor Browser, web: window.open or copyable link).
 *
 * The caller must keep the returned `pkce` around until the user pastes the
 * code back and calls `completeAuthorize(code, pkce)`.
 */
export function beginAuthorize() {
    const pkce = generatePKCE();
    const authUrl = buildAuthorizationURL(pkce);
    return { pkce, authUrl };
}

/**
 * Complete an authorization attempt. `input` is either the full callback URL
 * or the raw code (optionally with `#state` suffix) the user copied from the
 * callback page. `pkce` must be the object returned by `beginAuthorize`.
 */
export async function completeAuthorize(input, pkce) {
    const code = parseCallbackInput(input);
    if (!code) throw new Error('No authorization code found');
    if (!pkce) throw new Error('Missing PKCE state — tap Authorize first');
    return exchangeCodeForTokens(code, pkce);
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

// Test-only exports. Not part of the public API — do not import from production code.
export const __testing = {
    resetRefreshPromises: () => refreshPromises.clear()
};
