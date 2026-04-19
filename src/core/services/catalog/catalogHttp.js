/**
 * HTTP abstraction for catalog requests.
 * On native (Android/iOS): uses CapacitorHttp to bypass WebView CORS — arbitrary headers allowed.
 * On web (dev): wraps URL with corsproxy.io to bypass CORS.
 */
import { Capacitor, CapacitorHttp } from '@capacitor/core';

const CORS_PROXY = 'https://corsproxy.io/?url=';
const TIMEOUT = 20000;

function proxyUrl(url, useProxy = true) {
    if (Capacitor.isNativePlatform() || !useProxy) return url;
    return CORS_PROXY + encodeURIComponent(url);
}

/**
 * GET request with custom headers.
 * @param {string} url
 * @param {Record<string, string>} headers
 * @returns {Promise<any>} Parsed JSON response data
 */
export async function catalogGet(url, headers = {}, useProxy = true) {
    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({
            url,
            headers,
            responseType: 'json',
            connectTimeout: TIMEOUT,
            readTimeout: TIMEOUT
        });
        if (response.status >= 400) {
            throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status, data: response.data });
        }
        return response.data;
    }

    // Web fallback
    const res = await fetch(proxyUrl(url, useProxy), { headers });
    if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw Object.assign(new Error(`HTTP ${res.status}`), { status: res.status, data: text });
    }
    return res.json();
}

/**
 * GET request that returns raw text (for HTML scraping).
 */
export async function catalogGetText(url, headers = {}, useProxy = true) {
    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.get({
            url,
            headers,
            responseType: 'text',
            connectTimeout: TIMEOUT,
            readTimeout: TIMEOUT
        });
        if (response.status >= 400) {
            throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status });
        }
        return response.data;
    }

    const res = await fetch(proxyUrl(url, useProxy), { headers });
    if (!res.ok) throw Object.assign(new Error(`HTTP ${res.status}`), { status: res.status });
    return res.text();
}

/**
 * POST request with JSON body and custom headers.
 * @param {string} url
 * @param {object} body
 * @param {Record<string, string>} headers
 * @returns {Promise<any>} Parsed JSON response data
 */
export async function catalogPost(url, body, headers = {}, useProxy = true) {
    const allHeaders = { 'Content-Type': 'application/json', ...headers };

    if (Capacitor.isNativePlatform()) {
        const response = await CapacitorHttp.post({
            url,
            headers: allHeaders,
            data: body,
            responseType: 'json',
            connectTimeout: TIMEOUT,
            readTimeout: TIMEOUT
        });
        if (response.status >= 400) {
            throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status, data: response.data });
        }
        return response.data;
    }

    // Web
    const res = await fetch(proxyUrl(url, useProxy), {
        method: 'POST',
        headers: allHeaders,
        body: JSON.stringify(body)
    });
    if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw Object.assign(new Error(`HTTP ${res.status}`), { status: res.status, data: text });
    }
    return res.json();
}
