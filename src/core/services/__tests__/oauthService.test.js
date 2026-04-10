import { describe, it, expect, vi, beforeEach } from 'vitest';
import { generatePKCE, buildAuthorizationURL, getValidAccessToken, _resetRefreshPromises } from '../oauthService.js';

// ---------------------------------------------------------------------------
// generatePKCE
// ---------------------------------------------------------------------------

describe('generatePKCE', () => {
    it('generates code_verifier, code_challenge, and state (all truthy)', async () => {
        const pkce = await generatePKCE();
        expect(pkce.code_verifier).toBeTruthy();
        expect(pkce.code_challenge).toBeTruthy();
        expect(pkce.state).toBeTruthy();
    });

    it('all values are base64url-encoded', async () => {
        const pkce = await generatePKCE();
        const base64url = /^[A-Za-z0-9_-]+$/;
        expect(pkce.code_verifier).toMatch(base64url);
        expect(pkce.code_challenge).toMatch(base64url);
        expect(pkce.state).toMatch(base64url);
    });

    it('generates different values each call', async () => {
        const pkce1 = await generatePKCE();
        const pkce2 = await generatePKCE();
        expect(pkce1.code_verifier).not.toBe(pkce2.code_verifier);
        expect(pkce1.code_challenge).not.toBe(pkce2.code_challenge);
        expect(pkce1.state).not.toBe(pkce2.state);
    });
});

// ---------------------------------------------------------------------------
// buildAuthorizationURL
// ---------------------------------------------------------------------------

describe('buildAuthorizationURL', () => {
    let pkce;

    beforeEach(async () => {
        pkce = await generatePKCE();
    });

    it('contains the correct authorize base URL', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain('https://claude.ai/oauth/authorize');
    });

    it('contains client_id', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain('client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e');
    });

    it('contains response_type=code', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain('response_type=code');
    });

    it('contains URL-encoded redirect_uri', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain('redirect_uri=');
        expect(url).toContain(encodeURIComponent('https://console.anthropic.com/oauth/code/callback'));
    });

    it('contains URL-encoded scope', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain('scope=');
        expect(url).toContain(encodeURIComponent('org:create_api_key user:profile user:inference'));
    });

    it('contains code_challenge and code_challenge_method=S256', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain(`code_challenge=${pkce.code_challenge}`);
        expect(url).toContain('code_challenge_method=S256');
    });

    it('contains state', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain(`state=${pkce.state}`);
    });

    it('contains code=true', () => {
        const url = buildAuthorizationURL(pkce);
        expect(url).toContain('code=true');
    });
});

// ---------------------------------------------------------------------------
// getValidAccessToken
// ---------------------------------------------------------------------------

describe('getValidAccessToken', () => {
    beforeEach(() => {
        _resetRefreshPromises();
        global.fetch = vi.fn();
    });

    it('returns existing token if not expired', async () => {
        const oauth = {
            access_token: 'valid-token',
            refresh_token: 'refresh-token',
            expires_at: Date.now() + 3600000
        };
        const token = await getValidAccessToken(oauth, 'preset1', vi.fn());
        expect(token).toBe('valid-token');
        expect(global.fetch).not.toHaveBeenCalled();
    });

    it('refreshes token when expired and calls onTokenRefresh callback', async () => {
        const oauth = {
            access_token: 'old-token',
            refresh_token: 'refresh-token',
            expires_at: Date.now() - 1000
        };
        const newTokens = {
            access_token: 'new-token',
            refresh_token: 'new-refresh-token',
            expires_in: 3600
        };
        global.fetch = vi.fn().mockResolvedValue({
            ok: true,
            json: () => Promise.resolve(newTokens)
        });
        const onTokenRefresh = vi.fn();
        const token = await getValidAccessToken(oauth, 'preset1', onTokenRefresh);
        expect(token).toBe('new-token');
        expect(onTokenRefresh).toHaveBeenCalledWith(expect.objectContaining({
            access_token: 'new-token',
            refresh_token: 'new-refresh-token'
        }));
    });

    it('refreshes token when expires_at is within 60-second buffer', async () => {
        const oauth = {
            access_token: 'almost-expired-token',
            refresh_token: 'refresh-token',
            expires_at: Date.now() + 30000
        };
        global.fetch = vi.fn().mockResolvedValue({
            ok: true,
            json: () => Promise.resolve({
                access_token: 'new-token',
                refresh_token: 'new-refresh',
                expires_in: 3600
            })
        });
        const token = await getValidAccessToken(oauth, 'preset1', vi.fn());
        expect(global.fetch).toHaveBeenCalled();
        expect(token).toBe('new-token');
    });

    it('deduplicates concurrent refresh calls for the same preset', async () => {
        const oauth = {
            access_token: 'old-token',
            refresh_token: 'refresh-token',
            expires_at: Date.now() - 1000
        };
        global.fetch = vi.fn().mockResolvedValue({
            ok: true,
            json: () => Promise.resolve({
                access_token: 'new-token',
                refresh_token: 'new-refresh',
                expires_in: 3600
            })
        });
        const [token1, token2] = await Promise.all([
            getValidAccessToken(oauth, 'preset1', vi.fn()),
            getValidAccessToken(oauth, 'preset1', vi.fn())
        ]);
        expect(token1).toBe('new-token');
        expect(token2).toBe('new-token');
        expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('allows independent refresh for different presets', async () => {
        const oauthA = {
            access_token: 'old-a',
            refresh_token: 'refresh-a',
            expires_at: Date.now() - 1000
        };
        const oauthB = {
            access_token: 'old-b',
            refresh_token: 'refresh-b',
            expires_at: Date.now() - 1000
        };
        global.fetch = vi.fn().mockResolvedValue({
            ok: true,
            json: () => Promise.resolve({
                access_token: 'new-token',
                refresh_token: 'new-refresh',
                expires_in: 3600
            })
        });
        await Promise.all([
            getValidAccessToken(oauthA, 'presetA', vi.fn()),
            getValidAccessToken(oauthB, 'presetB', vi.fn())
        ]);
        expect(global.fetch).toHaveBeenCalledTimes(2);
    });

    it('throws when no oauth tokens provided', async () => {
        await expect(getValidAccessToken(null, 'preset1', vi.fn())).rejects.toThrow('Not authenticated');
    });

    it('throws when refresh fails (mock fetch returning 401)', async () => {
        const oauth = {
            access_token: 'old-token',
            refresh_token: 'refresh-token',
            expires_at: Date.now() - 1000
        };
        global.fetch = vi.fn().mockResolvedValue({
            ok: false,
            status: 401,
            text: () => Promise.resolve('Unauthorized')
        });
        await expect(getValidAccessToken(oauth, 'preset1', vi.fn())).rejects.toThrow();
    });
});
