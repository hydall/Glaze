let originalParent = null;
let movedElement = null;

export function clearHeader() {
    const ids = ['header-content-default', 'header-chat-info', 'header-actions', 'header-back', 'header-logo', 'header-arrow'];
    ids.forEach(id => {
        const el = document.getElementById(id);
        if (el) el.style.display = 'none';
    });

    // Reset specific buttons
    ['header-btn-delete-char', 'header-btn-create-char', 'header-btn-delete-persona', 'header-btn-close-viewer'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.style.display = 'none';
    });

    // Restore moved elements (like tabs)
    if (movedElement && originalParent) {
        movedElement.style.width = '';
        movedElement.style.marginTop = '';
        movedElement.style.marginBottom = '';
        movedElement.style.borderTop = '';
        movedElement.style.order = '';
        originalParent.appendChild(movedElement);
        movedElement = null;
        originalParent = null;
    }

    // Reset styles
    const appHeader = document.querySelector('.app-header');
    if (appHeader) {
        appHeader.classList.remove('no-border', 'fixed-header', 'scroll-hidden', 'header-transparent', 'header-wrap', 'header-overlay');
        // Clear inline styles if they were set previously
        appHeader.style.backgroundColor = '';
        appHeader.style.boxShadow = '';
        appHeader.style.borderBottom = '';
        appHeader.style.height = '';
        appHeader.style.paddingBottom = '';
        appHeader.style.flexWrap = '';
        appHeader.style.zIndex = '';
    }
    
    const headerDefault = document.getElementById('header-content-default');
    if (headerDefault) {
        headerDefault.style.justifyContent = '';
        headerDefault.style.flexDirection = '';
        headerDefault.style.alignItems = '';
        headerDefault.style.gap = '';
        headerDefault.style.width = '';
        headerDefault.style.margin = '';
        headerDefault.style.flex = '';
        headerDefault.style.height = '';
    }

    // Reset handlers
    const backBtn = document.getElementById('header-back');
    if (backBtn) backBtn.onclick = null;
}

export function setupDefaultHeader(title, showDropdown = false) {
    clearHeader();
    const headerDefault = document.getElementById('header-content-default');
    const titleEl = document.getElementById('header-title');
    const logo = document.getElementById('header-logo');
    const arrow = document.getElementById('header-arrow');
    const tabbar = document.querySelector('.tabbar');

    if (headerDefault) headerDefault.style.display = 'flex';
    if (titleEl) titleEl.textContent = title;
    if (logo) logo.style.display = 'flex';
    if (arrow) arrow.style.display = showDropdown ? 'block' : 'none';
    if (tabbar) tabbar.style.display = 'flex';
}

export function setupEditorHeader(title, onBack, actions = []) {
    clearHeader();
    const headerDefault = document.getElementById('header-content-default');
    const titleEl = document.getElementById('header-title');
    const backBtn = document.getElementById('header-back');
    const tabbar = document.querySelector('.tabbar');

    if (headerDefault) {
        headerDefault.style.display = 'flex';
        headerDefault.style.justifyContent = 'center';
    }
    if (titleEl) titleEl.textContent = title;
    if (backBtn) {
        backBtn.style.display = 'flex';
        backBtn.onclick = onBack;
    }
    if (tabbar) tabbar.style.display = 'none';

    actions.forEach(action => {
        const btn = document.getElementById(action.id);
        if (btn) {
            btn.style.display = 'flex';
            if (action.onClick) {
                // Clone to remove old listeners
                const newBtn = btn.cloneNode(true);
                btn.parentNode.replaceChild(newBtn, btn);
                newBtn.addEventListener('click', action.onClick);
            }
        }
    });
}

export function setupChatHeader(char, currentSessionId, callbacks) {
    clearHeader();
    const { onInfoClick, onActionsClick, onBackClick } = callbacks;
    
    const headerChatInfo = document.getElementById('header-chat-info');
    const headerActions = document.getElementById('header-actions');
    const backBtn = document.getElementById('header-back');
    const tabbar = document.querySelector('.tabbar');
    const appHeader = document.querySelector('.app-header');

    if (appHeader) appHeader.classList.add('fixed-header');
    if (headerChatInfo) headerChatInfo.style.display = 'flex';
    if (headerActions) headerActions.style.display = 'flex';
    if (backBtn) backBtn.style.display = 'flex';
    if (tabbar) tabbar.style.display = 'none';

    const nameEl = document.getElementById('chat-header-name');
    if (nameEl) nameEl.textContent = char.name.length > 20 ? char.name.substring(0, 20) + '...' : char.name;
    
    const sessionEl = document.getElementById('chat-header-session');
    if (sessionEl) sessionEl.textContent = `Session #${currentSessionId}`;

    updateHeaderAvatar(char);

    if (headerChatInfo) {
        headerChatInfo.onclick = (e) => {
            e.stopPropagation();
            onInfoClick(char);
        };
    }

    if (headerActions) {
        headerActions.onclick = (e) => {
            e.stopPropagation();
            onActionsClick(char);
        };
    }

    if (backBtn) {
        backBtn.onclick = onBackClick;
    }
}

export function setupGenerationHeader(title, tabsContainer) {
    clearHeader();
    const headerDefault = document.getElementById('header-content-default');
    const titleEl = document.getElementById('header-title');
    const logo = document.getElementById('header-logo');
    const tabbar = document.querySelector('.tabbar');
    const appHeader = document.querySelector('.app-header');

    if (headerDefault) {
        headerDefault.style.display = 'flex';
        headerDefault.style.width = '100%';
        headerDefault.style.height = '56px';
        headerDefault.style.alignItems = 'center';
    }
    if (titleEl) titleEl.textContent = title;
    if (logo) logo.style.display = 'flex';
    if (tabbar) tabbar.style.display = 'flex';
    if (appHeader) {
        appHeader.classList.add('no-border');
        appHeader.classList.add('header-wrap');
    }

    if (tabsContainer) {
        originalParent = tabsContainer.parentNode;
        movedElement = tabsContainer;
        if (appHeader) appHeader.appendChild(tabsContainer);
        tabsContainer.style.display = 'flex';
        tabsContainer.style.width = '100%';
        tabsContainer.style.order = '10';
    }
}

export function setupMoreHeader(title, customElement) {
    clearHeader();
    const headerDefault = document.getElementById('header-content-default');
    const titleEl = document.getElementById('header-title');
    const logo = document.getElementById('header-logo');
    const tabbar = document.querySelector('.tabbar');
    const appHeader = document.querySelector('.app-header');

    if (headerDefault) {
        headerDefault.style.display = 'flex';
        headerDefault.style.width = '100%';
        headerDefault.style.height = '56px';
        headerDefault.style.alignItems = 'center';
    }
    if (titleEl) titleEl.textContent = title;
    if (logo) logo.style.display = 'flex';
    if (tabbar) tabbar.style.display = 'flex';
    if (appHeader) {
        appHeader.classList.add('no-border');
        appHeader.classList.add('header-wrap');
    }

    if (customElement) {
        originalParent = customElement.parentNode;
        movedElement = customElement;
        if (appHeader) appHeader.appendChild(customElement);
        customElement.style.display = 'flex';
        customElement.style.width = '100%';
        customElement.style.order = '10';
        customElement.style.marginTop = '0';
        customElement.style.marginBottom = '0';
        customElement.style.borderTop = 'none';
    }
}

export function updateHeaderAvatar(char) {
    const headerAvatarImg = document.getElementById('chat-header-avatar');
    if (!headerAvatarImg) return;
    
    const headerAvatarParent = headerAvatarImg.parentElement;
    let headerPlaceholder = document.getElementById('chat-header-avatar-placeholder');

    if (char.avatar) {
        headerAvatarImg.style.display = 'block';
        headerAvatarImg.src = char.avatar;
        if (headerPlaceholder) headerPlaceholder.style.display = 'none';
        headerAvatarImg.onclick = (e) => {
            e.stopPropagation();
            // Callback for restoration is handled by caller (chat.js)
        };
    } else {
        headerAvatarImg.style.display = 'none';
        if (!headerPlaceholder) {
            headerPlaceholder = document.createElement('div');
            headerPlaceholder.id = 'chat-header-avatar-placeholder';
            headerPlaceholder.className = 'header-avatar';
            headerPlaceholder.style.cssText = "border-radius: 50%; display: flex; align-items: center; justify-content: center; color: white; font-weight: bold; font-size: 1.2em;";
            headerAvatarParent.insertBefore(headerPlaceholder, headerAvatarImg);
        }
        headerPlaceholder.style.display = 'flex';
        headerPlaceholder.style.backgroundColor = char.color || '#ccc';
        headerPlaceholder.textContent = (char.name[0] || "?").toUpperCase();
    }
}

export function resetHeader() {
    clearHeader();
    setupDefaultHeader(""); // Title will be set by script.js
}

export function initHeaderScroll(messagesContainer, initialScrollTop, isGeneratingCallback) {
    let lastScrollTop = initialScrollTop || 0;
    let ticking = false;

    const updateHeader = () => {
        const st = messagesContainer.scrollTop;
        const header = document.querySelector('.app-header');
        const scrollBtn = document.getElementById('scroll-to-bottom');
        
        if (!header) {
            ticking = false;
            return;
        }

        if (st < 0 || st + messagesContainer.clientHeight > messagesContainer.scrollHeight) {
            lastScrollTop = st <= 0 ? 0 : st;
            ticking = false;
            return;
        }

        if (isGeneratingCallback && isGeneratingCallback()) {
            lastScrollTop = st <= 0 ? 0 : st;
            ticking = false;
            return;
        }

        if (st > lastScrollTop + 3 && st > 50) {
            if (!header.classList.contains('scroll-hidden')) {
                header.classList.add('scroll-hidden');
            }
        } else if (st < lastScrollTop - 3) {
            if (header.classList.contains('scroll-hidden')) {
                header.classList.remove('scroll-hidden');
            }
        }
        lastScrollTop = st <= 0 ? 0 : st;

        if (scrollBtn) {
            const dist = messagesContainer.scrollHeight - st - messagesContainer.clientHeight;
            if (dist > 300) {
                scrollBtn.classList.add('visible');
            } else {
                scrollBtn.classList.remove('visible');
            }
        }

        ticking = false;
    };

    const onChatScroll = () => {
        if (!ticking) {
            window.requestAnimationFrame(updateHeader);
            ticking = true;
        }
    };
    
    messagesContainer.addEventListener('scroll', onChatScroll, { passive: true });
    
    return () => {
        messagesContainer.removeEventListener('scroll', onChatScroll);
    };
}