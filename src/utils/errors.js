import { logger } from './logger.js';

export function formatError(error, currentText = '') {
    logger.debug("[ErrorUtils] Raw error:", error);
    let errorMessage = error.message || String(error);
    logger.debug("[ErrorUtils] Initial message:", errorMessage);

    // Try to extract message from JSON if present (e.g. API error response)
    try {
        // Look for JSON object or array in the string
        const jsonMatch = errorMessage.match(/(\{.*\}|\[.*\])/s);
        if (jsonMatch) {
            logger.debug("[ErrorUtils] JSON match found:", jsonMatch[0]);
            const json = JSON.parse(jsonMatch[0]);
            logger.debug("[ErrorUtils] Parsed JSON:", json);

            const findMessage = (obj) => {
                if (!obj || typeof obj !== 'object') return null;
                if (obj.message) return obj.message;
                for (const key of Object.keys(obj)) {
                    const found = findMessage(obj[key]);
                    if (found) return found;
                }
                return null;
            };

            const found = findMessage(json);
            if (found) {
                errorMessage = String(found);
                logger.debug("[ErrorUtils] Extracted message:", errorMessage);
            }
        }
    } catch (e) {
        console.error("[ErrorUtils] JSON parsing failed:", e);
        // Ignore parsing errors, keep original message
    }

    // Remove "Error: " prefix if present at the start
    if (errorMessage.startsWith('Error: ')) {
        errorMessage = errorMessage.substring(7);
    }

    // Wrap in monospace span
    const errorHtml = `<span style="font-family: monospace; white-space: pre-wrap; word-break: break-word;">${errorMessage}</span>`;

    if (currentText) {
        return currentText + "\n\n" + errorHtml;
    }
    return errorHtml;
}

export function initGlobalErrorHandling() {
    const translations = {
        ru: {
            title: "Произошла ошибка",
            desc: "Приложение столкнулось с непредвиденной ошибкой. Попробуйте перезапустить его.",
            restart: "Перезапустить",
            close: "Закрыть",
            details: "ТЕХНИЧЕСКИЕ ДЕТАЛИ"
        },
        en: {
            title: "An error occurred",
            desc: "The application encountered an unexpected error. Please try restarting it.",
            restart: "Restart",
            close: "Close",
            details: "TECHNICAL DETAILS"
        }
    };

    const showError = (title, details) => {
        let lang = 'en';
        try {
            const saved = localStorage.getItem('gz_lang');
            if (saved) lang = saved;
            else if ((navigator.language || 'en').startsWith('ru')) lang = 'ru';
        } catch (e) { }
        const t = translations[lang] || translations['en'];

        // Ensure body is visible if error occurs during loading
        if (document.body) {
            document.body.classList.remove('preload');
        }

        // Inject styles once
        if (!document.getElementById('app-error-styles')) {
            const style = document.createElement('style');
            style.id = 'app-error-styles';
            style.textContent = `
                .error-overlay {
                    position: fixed;
                    top: 0; left: 0;
                    width: 100%; height: 100%;
                    background: rgba(0, 0, 0, 0.4);
                    z-index: 50000;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    color: var(--text-black, #000);
                    animation: errorOverlayIn 0.3s ease forwards;
                    backdrop-filter: blur(20px);
                    -webkit-backdrop-filter: blur(20px);
                }

                @keyframes errorOverlayIn {
                    from { opacity: 0; }
                    to { opacity: 1; }
                }

                                .error-card {
                    width: calc(100% - 32px);
                    max-width: 400px;
                    text-align: center;
                    padding: 0;
                    overflow: hidden;
                    position: relative;
                    will-change: transform, opacity;
                    transform: translateZ(0);
                    border-radius: 20px;
                    background-color: rgba(var(--ui-bg-rgb, 255, 255, 255), var(--element-opacity, 0.8));
                    backdrop-filter: blur(var(--element-blur, 20px));
                    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
                    border: var(--border-width, 1px) solid var(--border-color, rgba(255, 255, 255, 0.1));
                    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
                    animation: errorCardIn 0.3s cubic-bezier(0.34, 1.56, 0.64, 1) forwards;
                }

                @keyframes errorCardIn {
                    from { transform: scale(0.92) translateZ(0); opacity: 0; }
                    to { transform: scale(1) translateZ(0); opacity: 1; }
                }

                .error-close-btn {
                    position: absolute;
                    top: 14px; right: 14px;
                    width: 36px; height: 36px;
                    border-radius: 50%;
                    background: rgba(255, 255, 255, 0.1);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    cursor: pointer;
                    z-index: 10;
                    transition: all 0.2s ease;
                    border: 1px solid rgba(255, 255, 255, 0.05);
                }

                .error-close-btn:active {
                    transform: scale(0.9) translateZ(0);
                    background-color: rgba(255, 255, 255, 0.15);
                }

                .error-close-btn svg {
                    width: 20px; height: 20px;
                    fill: var(--text-gray, #99a2ad);
                }

                .error-header {
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    gap: 8px;
                    padding: 28px 20px 16px;
                }

                .error-icon-wrapper {
                    width: 72px; height: 72px;
                    border-radius: 22px;
                    background: linear-gradient(135deg, #FF3347, #FF6B6B);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    box-shadow: 0 6px 20px rgba(255, 51, 71, 0.35);
                    margin-bottom: 4px;
                }

                .error-icon-wrapper svg {
                    width: 36px; height: 36px;
                    color: #fff;
                }

                .error-title {
                    font-size: 1.5rem;
                    font-weight: 700;
                    margin: 0;
                    color: var(--text-dark-gray, #222);
                }

                .error-desc {
                    font-size: 0.82rem;
                    color: var(--text-gray, #818c99);
                    margin: 0;
                    line-height: 1.4;
                }

                .error-actions {
                    padding: 4px 16px 20px;
                    display: flex;
                    flex-direction: column;
                    gap: 12px;
                }

                .error-action-btn {
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    gap: 10px;
                    width: 100%;
                    padding: 14px;
                    border-radius: 16px;
                    border: none;
                    font-size: 1rem;
                    font-weight: 600;
                    cursor: pointer;
                    transition: transform 0.15s ease;
                    color: white;
                    font-family: inherit;
                }

                .error-action-btn:active {
                    transform: scale(0.96);
                }

                .error-action-btn.restart {
                    background: var(--vk-blue, #7996CE);
                }



                /* Terminal block */
                                .error-terminal {
                    margin: 0 16px 16px;
                    border-radius: 12px;
                    overflow: hidden;
                    border: 1px solid rgba(255, 255, 255, 0.08);
                    background: rgba(0, 0, 0, 0.2);
                }

                .error-terminal-header {
                    padding: 8px 12px;
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
                }

                .error-terminal-label {
                    font-size: 11px;
                    font-weight: 600;
                    color: var(--text-gray, #818c99);
                    letter-spacing: 0.5px;
                }

                .error-copy-btn {
                    cursor: pointer;
                    padding: 4px;
                    border-radius: 4px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    transition: background 0.2s;
                    background: none;
                    border: none;
                }

                .error-copy-btn svg {
                    width: 16px; height: 16px;
                    fill: var(--text-gray, #818c99);
                }

                .error-list {
                    padding: 12px;
                    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
                    font-size: 11px;
                    color: #d4d4d4;
                    word-break: break-all;
                    max-height: 180px;
                    overflow-y: auto;
                    text-align: left;
                }

                .error-list-item {
                    margin-bottom: 10px;
                    padding-bottom: 10px;
                    border-bottom: 1px dashed rgba(255, 255, 255, 0.08);
                }

                .error-list-item:last-child {
                    margin-bottom: 0;
                    padding-bottom: 0;
                    border-bottom: none;
                }

                .error-list-item-title {
                    color: #FF3347;
                    font-weight: bold;
                    margin-bottom: 4px;
                }

                .error-list-item-details {
                    color: #aaa;
                    padding-left: 14px;
                    line-height: 1.4;
                    text-align: left;
                }
            `;
            document.head.appendChild(style);
        }

        let overlay = document.getElementById('app-error-overlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = 'app-error-overlay';
            overlay.className = 'error-overlay';

            overlay.innerHTML = `
                <div class="error-card">
                    <div class="error-close-btn" id="error-close-x">
                        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                    </div>

                    <div class="error-header">
                        <div class="error-icon-wrapper">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                <path stroke-linecap="round" stroke-linejoin="round" d="M12 9v4m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
                            </svg>
                        </div>
                        <h2 class="error-title">${t.title}</h2>
                        <p class="error-desc">${t.desc}</p>
                    </div>

                    <div class="error-actions">
                        <button class="error-action-btn restart" id="error-restart-btn">
                            <svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor"><path d="M17.65 6.35A7.958 7.958 0 0012 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0112 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                            <span>${t.restart}</span>
                        </button>

                    </div>

                    <div class="error-terminal">
                        <div class="error-terminal-header">
                            <div class="error-terminal-label">${t.details}</div>
                            <button class="error-copy-btn" id="btn-copy-error" title="Copy">
                                <svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
                            </button>
                        </div>
                        <div class="error-list" id="error-list"></div>
                    </div>
                </div>
            `;

            const mount = () => {
                document.body.appendChild(overlay);

                // Close X button
                document.getElementById('error-close-x').addEventListener('click', () => {
                    overlay.style.display = 'none';
                });

                // Restart button
                document.getElementById('error-restart-btn').addEventListener('click', () => {
                    window.location.reload();
                });


                // Copy button
                const copyBtn = document.getElementById('btn-copy-error');
                copyBtn.addEventListener('click', () => {
                    const list = document.getElementById('error-list');
                    if (list) {
                        const text = list.innerText;
                        const markdown = "```\n" + text + "\n```";
                        try {
                            if (navigator.clipboard && navigator.clipboard.writeText) {
                                navigator.clipboard.writeText(markdown).catch(e => console.warn(e));
                            } else {
                                const textArea = document.createElement("textarea");
                                textArea.value = markdown;
                                textArea.style.position = "fixed";
                                document.body.appendChild(textArea);
                                textArea.focus();
                                textArea.select();
                                document.execCommand('copy');
                                document.body.removeChild(textArea);
                            }
                            const originalIcon = copyBtn.innerHTML;
                            copyBtn.innerHTML = `<svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: #4CAF50;"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>`;
                            setTimeout(() => copyBtn.innerHTML = originalIcon, 2000);
                        } catch (e) {
                            console.warn("Copy failed", e);
                        }
                    }
                });
            };

            if (document.body) {
                mount();
            } else {
                window.addEventListener('load', mount);
            }
        } else {
            overlay.style.display = 'flex';
        }

        const list = overlay.querySelector('#error-list');
        const item = document.createElement('div');
        item.className = 'error-list-item';
        item.innerHTML = `<div class="error-list-item-title">➜ ${title}</div><div class="error-list-item-details">${details}</div>`;
        list.appendChild(item);
    };

    const handleGlobalError = (msg, url, lineNo, columnNo, error) => {
        // Suppress errors explicitly marked or originating from Shadow DOM interactions
        const isRecentShadowInteraction = window._lastShadowInteraction && (Date.now() - window._lastShadowInteraction < 100);
        if (error && error.isShadowError) return true;
        if (isRecentShadowInteraction) return true;

        // Suppress reference errors that likely come from shadow DOM element inline handlers
        if (typeof msg === 'string' && (msg.includes('ReferenceError') || msg.includes('Shadow Error')) && isRecentShadowInteraction) return true;

        let details = "";
        let finalTitle = 'Uncaught Exception';

        if (msg === 'Script error.') {
            finalTitle = 'CORS / Cross-Origin Error';
            details = "Script error (masked by browser). <br><br><b>Potential reasons:</b><br>- Error in a cross-origin script.<br>- Script not served with correct CORS headers.<br>- iOS security restriction.<br><br>Check remote debugger/Safari Web Inspector for actual details.";
        } else {
            details = `${msg}<br>URL: ${url}<br>Line: ${lineNo} Column: ${columnNo}<br>Stack: ${error ? (error.stack || 'N/A').replace(/\n/g, '<br>') : 'N/A'}`;
        }

        showError(finalTitle, details);
        return false;
    };

    // Use both window.onerror and addEventListener('error') for maximum coverage
    window.onerror = handleGlobalError;

    window.addEventListener('error', (event) => {
        if (event.error) {
            handleGlobalError(event.message, event.filename, event.lineno, event.colno, event.error);
        } else if (event.message === 'Script error.') {
            handleGlobalError('Script error.', '', 0, 0, null);
        }
    }, true);

    window.onunhandledrejection = function (event) {
        const reason = event.reason;
        const isRecentShadowInteraction = window._lastShadowInteraction && (Date.now() - window._lastShadowInteraction < 100);
        if ((reason && reason.isShadowError) || isRecentShadowInteraction) return; // Suppress

        let details = reason;
        if (reason instanceof Error) {
            details = `${reason.message}\nStack: ${reason.stack}`;
        } else {
            try {
                details = JSON.stringify(reason);
            } catch (e) {
                details = String(reason);
            }
        }
        showError('Unhandled Promise Rejection', String(details).replace(/\n/g, '<br>'));
    };

    window.addEventListener('vue-error', (event) => {
        const { err, info } = event.detail;
        const details = `${err.message}<br>Component Info: ${info}<br>Stack: ${(err.stack || 'N/A').replace(/\n/g, '<br>')}`;
        showError('Vue Error', details);
    });
}
