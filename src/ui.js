import { currentLang } from './APPSettings.js';
import { translations } from './i18n.js';
import { formatText } from './textFormatter.js';
import { App } from '@capacitor/app';
import { Toast } from '@capacitor/toast';
import { Haptics, ImpactStyle } from '@capacitor/haptics';
import { Keyboard, KeyboardResize } from '@capacitor/keyboard';
import { StatusBar, Style } from '@capacitor/status-bar';
import { NavigationBar } from '@hugotomazi/capacitor-navigation-bar';

export function attachLongPress(element, callback) {
    let timer;
    let isLongPress = false;

    const start = () => {
        isLongPress = false;
        timer = setTimeout(() => {
            isLongPress = true;
            // Use Capacitor Haptics to bypass browser intervention
            try {
                Haptics.impact({ style: ImpactStyle.Light });
            } catch (e) {
                if (navigator.vibrate) try { navigator.vibrate(50); } catch (err) {}
            }
            callback();
        }, 500);
    };

    const cancel = () => {
        clearTimeout(timer);
    };

    element.addEventListener('touchstart', start, { passive: true });
    element.addEventListener('touchend', cancel);
    element.addEventListener('touchmove', cancel);
    
    element.addEventListener('mousedown', start);
    element.addEventListener('mouseup', cancel);
    element.addEventListener('mouseleave', cancel);
    
    element.addEventListener('contextmenu', (e) => {
        e.preventDefault();
    });
    
    return () => isLongPress;
}

let genericSheetOverlay = null;
let activeSheetConfig = null;
let closeTimer = null;
let isKeyboardOpen = false;

export function initGenericBottomSheet() {
    if (document.getElementById('generic-bottom-sheet')) {
        genericSheetOverlay = document.getElementById('generic-bottom-sheet');
        return;
    }

    const overlay = document.createElement('div');
    overlay.id = 'generic-bottom-sheet';
    overlay.className = 'modal-overlay bottom-sheet-overlay';
    overlay.style.display = 'none';
    overlay.innerHTML = `
        <div class="bottom-sheet-content">
            <div class="sheet-handle-bar"></div>
            <div class="sheet-header" style="display:none;">
                <span class="sheet-title"></span>
                <div class="sheet-header-action"></div>
            </div>
            <div class="sheet-scroll-container" style="overflow-y: auto; max-height: 70vh;">
                <div class="sheet-list"></div>
                <div class="sheet-custom-content"></div>
            </div>
        </div>
    `;
    document.body.appendChild(overlay);
    genericSheetOverlay = overlay;

    const content = overlay.querySelector('.bottom-sheet-content');
    let startY = 0;
    let isDragging = false;

    overlay.addEventListener('click', (e) => {
        if (e.target === overlay) closeBottomSheet();
    });

    content.addEventListener('touchstart', (e) => {
        const scrollContainer = overlay.querySelector('.sheet-scroll-container');
        if (scrollContainer && scrollContainer.scrollTop > 0) return;
        
        startY = e.touches[0].clientY;
        isDragging = true;
        content.style.transition = 'none';
    }, { passive: true });

    content.addEventListener('touchmove', (e) => {
        if (!isDragging) return; 
        const delta = e.touches[0].clientY - startY;
        if (delta > 0) {
            e.preventDefault();
            content.style.transform = `translateY(${delta}px)`;
        }
    }, { passive: false });

    content.addEventListener('touchend', (e) => {
        if (!isDragging) return;
        isDragging = false;
        const delta = e.changedTouches[0].clientY - startY;
        content.style.transition = '';
        if (delta > 100) {
            closeBottomSheet();
        } else {
            content.style.transform = '';
        }
    });
}

export function showBottomSheet({ title, items, content, headerAction, onClose }) {
    if (!genericSheetOverlay) initGenericBottomSheet();
    const overlay = genericSheetOverlay;
    
    if (closeTimer) {
        clearTimeout(closeTimer);
        closeTimer = null;
    }

    const titleEl = overlay.querySelector('.sheet-title');
    const headerEl = overlay.querySelector('.sheet-header');
    const headerActionEl = overlay.querySelector('.sheet-header-action');
    const listEl = overlay.querySelector('.sheet-list');
    const customEl = overlay.querySelector('.sheet-custom-content');

    // Reset
    listEl.innerHTML = '';
    customEl.innerHTML = '';
    headerActionEl.innerHTML = '';
    listEl.style.display = 'none';
    customEl.style.display = 'none';

    // Title
    if (title) {
        titleEl.textContent = title;
        headerEl.style.display = 'flex';
    } else {
        headerEl.style.display = 'none';
    }

    // Header Action
    if (headerAction) {
        const btn = document.createElement('div');
        btn.className = 'sheet-action-btn';
        btn.innerHTML = headerAction.icon || '+';
        btn.onclick = (e) => {
            e.stopPropagation();
            if (headerAction.onClick) headerAction.onClick();
        };
        headerActionEl.appendChild(btn);
    }

    // Items List
    if (items && items.length > 0) {
        items.forEach(item => {
            const el = document.createElement('div');
            el.className = 'sheet-item';
            if (item.id) el.id = item.id;
            
            const iconHtml = item.icon ? `<div class="sheet-item-icon" style="${item.iconColor ? 'fill:'+item.iconColor : ''}">${item.icon}</div>` : '';
            const labelStyle = item.isDestructive ? 'color: #ff4444;' : '';
            
            el.innerHTML = `
                ${iconHtml}
                <div class="sheet-item-content" style="${labelStyle}">${item.label}</div>
            `;
            
            el.onclick = (e) => {
                if (item.onClick) item.onClick(e);
            };
            listEl.appendChild(el);
        });
        listEl.style.display = 'block';
    }

    // Custom Content
    if (content) {
        if (typeof content === 'string') {
            customEl.innerHTML = content;
        } else if (content instanceof HTMLElement || content instanceof DocumentFragment) {
            customEl.appendChild(content);
        }
        customEl.style.display = 'block';
    }

    activeSheetConfig = { onClose };

    overlay.style.display = 'flex';
    const contentEl = overlay.querySelector('.bottom-sheet-content');
    
    // Double RAF ensures the browser paints the display:flex frame before adding the class
    requestAnimationFrame(() => {
        requestAnimationFrame(() => {
            contentEl.style.transform = ''; 
            overlay.classList.add('visible');
        });
    });
}

export function closeBottomSheet() {
    if (!genericSheetOverlay) return;
    const overlay = genericSheetOverlay;
    const content = overlay.querySelector('.bottom-sheet-content');
    
    content.style.transform = '';
    overlay.classList.remove('visible');
    
    if (activeSheetConfig && activeSheetConfig.onClose) {
        activeSheetConfig.onClose();
    }
    activeSheetConfig = null;

    if (closeTimer) clearTimeout(closeTimer);
    closeTimer = setTimeout(() => {
        overlay.style.display = 'none';
        content.style.transform = '';
        closeTimer = null;
    }, 300);
}

export function initRipple() {
    const elements = document.querySelectorAll('.tabbar, .chat-input-bar');
    elements.forEach(el => {
        el.addEventListener('pointerdown', function(e) {
            // Remove existing ripples to prevent buildup
            const existing = this.getElementsByClassName('ripple');
            while(existing.length > 0) {
                existing[0].remove();
            }

            const circle = document.createElement('span');
            const diameter = Math.max(this.clientWidth, this.clientHeight);
            const radius = diameter / 2;
            
            const rect = this.getBoundingClientRect();
            
            circle.style.width = circle.style.height = `${diameter}px`;
            circle.style.left = `${e.clientX - rect.left - radius}px`;
            circle.style.top = `${e.clientY - rect.top - radius}px`;
            circle.classList.add('ripple');
            
            circle.addEventListener('animationend', () => {
                circle.remove();
            });
            
            this.appendChild(circle);
        });
    });
}

export function rgbToHex(rgb) {
    if (!rgb || rgb.startsWith('#')) return rgb || '#ffffff';
    const start = rgb.indexOf('(') + 1;
    const end = rgb.indexOf(')');
    const rgbVals = rgb.substring(start, end).split(',').map(x => x.trim());
    
    let r = (+rgbVals[0]).toString(16),
        g = (+rgbVals[1]).toString(16),
        b = (+rgbVals[2]).toString(16);
    if (r.length == 1) r = "0" + r;
    if (g.length == 1) g = "0" + g;
    if (b.length == 1) b = "0" + b;
    return "#" + r + g + b;
}

export async function updateAppColors(forceMainView = false) {
    const isDark = document.body.classList.contains('dark-theme');
    const chatView = document.getElementById('view-chat');
    const isChatOpen = chatView && chatView.classList.contains('active-view') && !forceMainView;
    
    // Hardcoded palette to match CSS variables and avoid transition lag
    const palette = {
        light: {
            statusBar: '#ffffff', // --vk-header-bg
            navBarMain: '#f9f9f9', // tabbar bg
            navBarChat: '#ebedf0', // chat input bg
            body: '#ffffff'
        },
        dark: {
            statusBar: '#19191a', // --vk-header-bg
            navBarMain: '#19191a', // tabbar bg
            navBarChat: '#252526', // chat input bg
            body: '#19191a'
        }
    };

    const theme = isDark ? palette.dark : palette.light;
    
    const statusBarColor = theme.statusBar;
    const navBarColor = isChatOpen ? theme.navBarChat : theme.navBarMain;

    // Apply to body to prevent flashes
    document.body.style.backgroundColor = theme.body;

    let meta = document.querySelector('meta[name="theme-color"]');
    if (!meta) {
        meta = document.createElement('meta');
        meta.name = "theme-color";
        document.head.appendChild(meta);
    }
    meta.setAttribute('content', statusBarColor);

    try {
        await StatusBar.setBackgroundColor({ color: statusBarColor });
        await StatusBar.setStyle({ style: isDark ? Style.Dark : Style.Light });
        await NavigationBar.setColor({ color: navBarColor, darkButtons: !isDark });
    } catch (e) { console.warn('StatusBar/NavBar error', e); }
}

export function initThemeToggle() {
    const themeToggle = document.getElementById('theme-toggle');
    // Fix: Inject global styles for text selection and UI tweaks
    if (!document.getElementById('ui-fixes-styles')) {
        const style = document.createElement('style');
        style.id = 'ui-fixes-styles';
        style.textContent = `
            body { -webkit-user-select: none; user-select: none; }
            .msg-body, .selectable, [contenteditable] { -webkit-user-select: text; user-select: text; }
            input, textarea { -webkit-user-select: auto; user-select: auto; }
        `;
        document.head.appendChild(style);
    }

    // Auto-detect system theme
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
        document.body.classList.add('dark-theme');
    }
    updateAppColors();

    if (themeToggle) {
        themeToggle.addEventListener('click', () => {
            document.body.classList.toggle('dark-theme');
            updateAppColors();
        });
    }
}

export function initLanguageToggle(onToggle) {
    const langToggle = document.getElementById('lang-toggle');
    if (langToggle) {
        langToggle.addEventListener('click', onToggle);
    }
}

export function initHeaderDropdown(categories, activeCategories, onCategoryChange) {
    const headerContent = document.getElementById('header-content-default');
    const dropdown = document.getElementById('header-dropdown');
    const arrow = document.getElementById('header-arrow');

    if (!headerContent || !dropdown || !arrow) return;

    headerContent.addEventListener('click', () => {
        const currentView = document.querySelector('.view.active-view').id;
        if (!categories[currentView]) return;

        const isOpen = dropdown.style.display === 'block';
        if (isOpen) {
            closeDropdown();
        } else {
            openDropdown(currentView);
        }
    });

    function openDropdown(viewId) {
        dropdown.innerHTML = '';
        const items = categories[viewId];
        const currentVal = activeCategories[viewId];

        items.forEach(item => {
            const el = document.createElement('div');
            el.className = 'dropdown-item' + (item.id === currentVal ? ' selected' : '');
            el.innerHTML = `
                <span>${translations[currentLang][item.i18n]}</span>
                <svg class="dropdown-check" viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
            `;
            el.addEventListener('click', () => {
                activeCategories[viewId] = item.id;
                onCategoryChange(viewId, item.id);
                closeDropdown();
            });
            dropdown.appendChild(el);
        });

        dropdown.style.display = 'block';
        arrow.classList.add('rotated');
    }

    function closeDropdown() {
        dropdown.style.display = 'none';
        arrow.classList.remove('rotated');
    }

    // Close dropdown when clicking outside
    document.addEventListener('click', (e) => {
        if (!e.target.closest('#header-content-default') && !e.target.closest('#header-dropdown')) {
            closeDropdown();
        }
    });
}

export function scrollToBottom(elementId, targetElement) {
    const element = document.getElementById(elementId);
    if (!element) return;

    requestAnimationFrame(() => {
        const maxScroll = element.scrollHeight - element.clientHeight;
        let target = maxScroll;

        if (targetElement) {
            const elRect = targetElement.getBoundingClientRect();
            const containerRect = element.getBoundingClientRect();
            target = elRect.top - containerRect.top + element.scrollTop;
        }

        if (target > maxScroll) target = maxScroll;
        if (target < 0) target = 0;

        const start = element.scrollTop;
        const change = target - start;
        
        if (Math.abs(change) < 2) return;

        const duration = 400;
        let startTime = null;

        function animate(currentTime) {
            if (!startTime) startTime = currentTime;
            const elapsed = currentTime - startTime;
            const progress = Math.min(elapsed / duration, 1);
            const ease = 1 - Math.pow(1 - progress, 3); // Ease Out Cubic
            
            element.scrollTop = start + (change * ease);

            if (elapsed < duration) requestAnimationFrame(animate);
            else element.scrollTop = target;
        }
        requestAnimationFrame(animate);
    });
}

export function initViewportFix() {
    // Fix for 100vh on mobile browsers (address bar issue)
    const setVh = () => {
        // Не пересчитываем высоту, если открыта клавиатура (избегаем прыжков)
        if (isKeyboardOpen) return;
        
        const vh = window.innerHeight * 0.01;
        document.documentElement.style.setProperty('--vh', `${vh}px`);
    };
    window.addEventListener('resize', setVh);
    setVh();
}

export function initKeyboardFix() {
    if (typeof Keyboard === 'undefined') return;

    // Skip on web platform to avoid "not implemented" errors
    if (!window.Capacitor || window.Capacitor.getPlatform() === 'web') return;

    // Настройка режима ресайза (помогает от двойного тапа и проблем с layout)
    try {
        if (window.Capacitor && window.Capacitor.getPlatform() === 'android') {
            Keyboard.setResizeMode({ mode: KeyboardResize.Native });
        }
    } catch (e) { console.warn('Keyboard resize mode error', e); }

    Keyboard.addListener('keyboardWillShow', () => {
        isKeyboardOpen = true;
        document.body.classList.add('keyboard-open');
    });

    Keyboard.addListener('keyboardWillHide', () => {
        isKeyboardOpen = false;
        document.body.classList.remove('keyboard-open');
    });
}

export function initBackButton() {
    let lastBackPress = 0;
    const handleBackButton = async () => {
        // 0. Если клавиатура открыта - закрываем её
        if (isKeyboardOpen) {
            await Keyboard.hide();
            return;
        }

        // 1. Проверяем открытые Bottom Sheets
        const openSheet = document.querySelector('.modal-overlay.visible');
        if (openSheet) {
            closeBottomSheet();
            return;
        }

        // Check Image Viewer
        const imageViewer = document.getElementById('image-viewer-overlay');
        if (imageViewer && imageViewer.classList.contains('visible')) {
            const closeBtn = document.getElementById('header-btn-close-viewer');
            if (closeBtn) closeBtn.click();
            return;
        }

        // 2. Проверяем полноэкранный редактор
        const fsEditor = document.getElementById('full-screen-editor');
        if (fsEditor && fsEditor.style.display !== 'none') {
            const closeBtn = document.getElementById('fs-editor-close');
            if (closeBtn) closeBtn.click();
            return;
        }

        // 3. Проверяем, находимся ли мы во вложенном экране (Чат, Редактор персонажа и т.д.)
        const activeView = document.querySelector('.view.active-view');
        const mainViews = ['view-dialogs', 'view-characters', 'view-generation', 'view-menu'];
        
        if (activeView && !mainViews.includes(activeView.id)) {
            const backBtn = document.getElementById('header-back');
            if (backBtn && backBtn.offsetParent !== null) {
                backBtn.click();
                return;
            }
        }

        // 4. Логика выхода из приложения (Главный экран)
        const now = Date.now();
        if (now - lastBackPress < 2000) {
            App.exitApp();
        } else {
            lastBackPress = now;
            await Toast.show({
                text: (translations[currentLang] && translations[currentLang]['exit_hint']) || 'Нажмите ещё раз для выхода',
                duration: 'short',
                position: 'bottom'
            });
        }
    };

    App.addListener('backButton', handleBackButton);
    // Для тестов через консоль: window.simulateBackButton()
    window.simulateBackButton = handleBackButton;
}

export function animateTextChange(element, newText, direction, onUpdate) {
    const body = element.querySelector('.msg-body');
    
    body.style.transition = 'opacity 0.15s ease, transform 0.15s ease';
    body.style.opacity = '0';
    if (direction) {
        body.style.transform = `translateX(${direction * -20}px)`;
    }
    
    setTimeout(() => {
        if (onUpdate) onUpdate();
        else body.innerHTML = formatText(newText);
        
        body.style.transition = 'none';
        if (direction) {
            body.style.transform = `translateX(${direction * 20}px)`;
        }
        void body.offsetWidth; // Trigger reflow

        body.style.transition = 'opacity 0.15s ease, transform 0.15s ease';
        body.style.opacity = '1';
        body.style.transform = 'translateX(0)';
    }, 200);
}