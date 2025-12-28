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
        const lang = (navigator.language || 'en').startsWith('ru') ? 'ru' : 'en';
        const t = translations[lang];

        // Theme detection
        let isDark = false;
        try {
            const saved = localStorage.getItem('sc_theme');
            if (saved === 'dark') isDark = true;
            else if (saved === 'light') isDark = false;
            else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) isDark = true;
        } catch(e) {}

        const colors = isDark ? {
            bg: '#121212',
            text: '#E0E0E0',
            sub: '#aaaaaa',
            card: '#1E1E1E',
            border: '#333333',
            close: '#71aaeb'
        } : {
            bg: '#EBEDF0',
            text: '#000000',
            sub: '#818C99',
            card: '#ffffff',
            border: '#f0f0f0',
            close: '#5181B8'
        };

        let overlay = document.getElementById('app-error-overlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = 'app-error-overlay';
            overlay.style.cssText = `
                position: fixed;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
                background: ${colors.bg};
                z-index: 10000;
                overflow-y: auto;
                font-family: -apple-system, BlinkMacSystemFont, Roboto, "Helvetica Neue", sans-serif;
                display: flex;
                flex-direction: column;
                align-items: center;
                padding: 20px;
                box-sizing: border-box;
            `;
            
            overlay.innerHTML = `
                <div style="margin-top: auto; margin-bottom: auto; display: flex; flex-direction: column; align-items: center; text-align: center; max-width: 400px; width: 100%;">
                    <div style="width: 72px; height: 72px; margin-bottom: 20px;">
                        <svg viewBox="0 0 72 72" fill="none" xmlns="http://www.w3.org/2000/svg">
                            <circle cx="36" cy="36" r="36" fill="#FF3347"/>
                            <path d="M36 18V42" stroke="white" stroke-width="5" stroke-linecap="round"/>
                            <circle cx="36" cy="54" r="3.5" fill="white"/>
                        </svg>
                    </div>
                    <h2 style="font-size: 20px; font-weight: 500; color: ${colors.text}; margin: 0 0 10px 0;">${t.title}</h2>
                    <p style="font-size: 15px; color: ${colors.sub}; margin: 0 0 24px 0; line-height: 1.4;">
                        ${t.desc}
                    </p>
                    <button onclick="window.location.reload()" style="
                        background: #5181B8;
                        color: white;
                        border: none;
                        border-radius: 8px;
                        padding: 0 24px;
                        font-size: 15px;
                        font-weight: 500;
                        cursor: pointer;
                        width: 100%;
                        height: 44px;
                        margin-bottom: 12px;
                    ">${t.restart}</button>
                    
                    <button onclick="document.getElementById('app-error-overlay').style.display = 'none'" style="
                        background: transparent;
                        color: ${colors.close};
                        border: none;
                        padding: 10px;
                        font-size: 14px;
                        cursor: pointer;
                    ">${t.close}</button>
                </div>

                <div style="width: 100%; margin-top: 30px; background: #1e1e1e; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 12px rgba(0,0,0,0.3); border: 1px solid #333; display: flex; flex-direction: column;">
                    <div style="background: #252526; padding: 8px 12px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #333;">
                        <div style="font-size: 11px; font-weight: 600; color: #888; font-family: -apple-system, BlinkMacSystemFont, sans-serif; letter-spacing: 0.5px;">TERMINAL</div>
                        <div id="btn-copy-error" title="Copy" style="cursor: pointer; padding: 4px; border-radius: 4px; display: flex; align-items: center; justify-content: center; transition: background 0.2s;">
                            <svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: #ccc;"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
                        </div>
                    </div>
                    <div id="error-list" style="background: #1e1e1e; padding: 12px; font-family: 'Consolas', 'Monaco', 'Courier New', monospace; font-size: 11px; color: #d4d4d4; word-break: break-word; max-height: 200px; overflow-y: auto;"></div>
                </div>
            `;
            document.body.appendChild(overlay);

            // Add Copy Listener
            const copyBtn = document.getElementById('btn-copy-error');
            if (copyBtn) {
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
            }
        } else {
            overlay.style.display = 'flex';
        }
        const list = overlay.querySelector('#error-list');
        const item = document.createElement('div');
        item.style.cssText = `margin-bottom: 12px; border-bottom: 1px dashed #333; padding-bottom: 12px;`;
        item.innerHTML = `<div style="color: #ff6b6b; font-weight: bold; margin-bottom: 4px;">➜ ${title}</div><div style="color: #cccccc; padding-left: 14px; line-height: 1.4;">${details}</div>`;
        list.appendChild(item);
    };

    window.onerror = function(msg, url, lineNo, columnNo, error) {
        const details = `${msg}\nURL: ${url}\nLine: ${lineNo} Column: ${columnNo}\nStack: ${error ? error.stack : 'N/A'}`;
        showError('Uncaught Exception', details.replace(/\n/g, '<br>'));
        return false;
    };

    window.onunhandledrejection = function(event) {
        const reason = event.reason;
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
}