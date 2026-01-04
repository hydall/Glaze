import { currentLang, themeMode, setThemeMode, getThemeMode, imageViewerMode, setImageViewerMode } from './APPSettings.js';
import { translations } from './i18n.js';
import { formatText } from './textFormatter.js';
import { App } from '@capacitor/app';
import { Toast } from '@capacitor/toast';
import { Haptics, ImpactStyle } from '@capacitor/haptics';
import { Keyboard, KeyboardResize } from '@capacitor/keyboard';
import { StatusBar, Style } from '@capacitor/status-bar';
import { NavigationBar } from '@hugotomazi/capacitor-navigation-bar';
import { showBottomSheet, closeBottomSheet } from './bottomsheet.js';

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

let isKeyboardOpen = false;

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

    let isDark = false;
    const currentMode = getThemeMode();
    if (currentMode === 'system') {
        isDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    } else {
        isDark = currentMode === 'dark';
    }

    const theme = isDark ? palette.dark : palette.light;
    
    const statusBarColor = theme.statusBar;
    const navBarColor = isChatOpen ? theme.navBarChat : theme.navBarMain;

    // Apply to body to prevent flashes
    document.body.style.backgroundColor = theme.body;
    if (isDark) document.body.classList.add('dark-theme');
    else document.body.classList.remove('dark-theme');

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
    updateAppColors();

    // System theme change listener
    if (window.matchMedia) {
        const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
        const handleChange = () => {
            if (getThemeMode() === 'system') {
                updateAppColors();
            }
        };
        if (mediaQuery.addEventListener) mediaQuery.addEventListener('change', handleChange);
        else mediaQuery.addListener(handleChange);
    }

    // Theme Selector
    const themeSelector = document.getElementById('theme-selector');
    const themeValue = document.getElementById('theme-value-text');
    
    const updateThemeText = () => {
        if (!themeValue) return;
        const map = { 'system': 'Системная', 'dark': 'Тёмная', 'light': 'Светлая' };
        themeValue.textContent = map[getThemeMode()] || 'Системная';
    };
    updateThemeText();

    if (themeSelector) {
        themeSelector.addEventListener('click', () => {
            const getIcon = (mode) => getThemeMode() === mode ? '<svg viewBox="0 0 24 24" style="fill: var(--vk-blue);"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : '';
            showBottomSheet({
                title: 'Тема',
                items: [
                    { label: 'Системная', icon: getIcon('system'), onClick: () => { setThemeMode('system'); updateAppColors(); updateThemeText(); closeBottomSheet(); } },
                    { label: 'Тёмная', icon: getIcon('dark'), onClick: () => { setThemeMode('dark'); updateAppColors(); updateThemeText(); closeBottomSheet(); } },
                    { label: 'Светлая', icon: getIcon('light'), onClick: () => { setThemeMode('light'); updateAppColors(); updateThemeText(); closeBottomSheet(); } }
                ]
            });
        });
    }

    // Holo Cards Selector
    const holoSelector = document.getElementById('holocards-selector');
    const holoValue = document.getElementById('holocards-value-text');

    const updateHoloText = () => {
        if (!holoValue) return;
        holoValue.textContent = imageViewerMode === 'holo' ? 'Holo Card' : 'Стандарт';
    };
    updateHoloText();

    if (holoSelector) {
        holoSelector.addEventListener('click', () => {
            const getIcon = (mode) => imageViewerMode === mode ? '<svg viewBox="0 0 24 24" style="fill: var(--vk-blue);"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : '';
            showBottomSheet({
                title: 'Просмотр изображений',
                items: [
                    { label: 'Стандартный просмотрщик изображений', description: 'Стандартный просмотрщик изображений', icon: getIcon('default'), onClick: () => { setImageViewerMode('default'); updateHoloText(); closeBottomSheet(); } },
                    { label: 'Голографическая карточка', description: 'Она блестит!', icon: getIcon('holo'), onClick: () => { setImageViewerMode('holo'); updateHoloText(); closeBottomSheet(); } }
                ]
            });
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
            const closeBtn = document.getElementById('image-viewer-close-btn');
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
    
    // Reset inline styles that might interfere (from swipe gestures)
    body.style.transform = '';
    body.style.transition = '';

    // Clean up previous animations if any
    body.classList.remove('slide-out-left', 'slide-out-right', 'slide-in-left', 'slide-in-right');
    void body.offsetWidth; // Trigger reflow

    const exitClass = direction > 0 ? 'slide-out-left' : 'slide-out-right';
    body.classList.add(exitClass);

    body.addEventListener('animationend', () => {
        // Prevent flickering: keep hidden until new animation starts
        body.style.opacity = '0';
        body.classList.remove(exitClass);
        
        if (onUpdate) onUpdate();
        else body.innerHTML = formatText(newText);
        
        void body.offsetWidth; // Trigger reflow

        const enterClass = direction > 0 ? 'slide-in-right' : 'slide-in-left';
        body.classList.add(enterClass);
        body.style.opacity = ''; // Release opacity override
        body.addEventListener('animationend', () => body.classList.remove(enterClass), { once: true });
    }, { once: true });
}