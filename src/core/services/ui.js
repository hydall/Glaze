import { currentLang, themeMode, setThemeMode, getThemeMode, imageViewerMode, setImageViewerMode } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import { formatText } from '@/utils/textFormatter.js';
import { Capacitor } from '@capacitor/core';
import { App } from '@capacitor/app';
import { Toast } from '@capacitor/toast';
import { Haptics, ImpactStyle } from '@capacitor/haptics';
import { SafeArea } from '@capacitor-community/safe-area';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { themeState, getPresets, applyPreset } from '@/core/states/themeState.js';
import { ref } from 'vue';
import { logger } from '../../utils/logger.js';
import { isKeyboardOpen, initKeyboard, hideKeyboard } from './keyboardHandler.js';

// --- Long-press background guard ---
const _activeLongPressTimers = new Set();
let _appPauseListenerRegistered = false;

function _ensureAppPauseListener() {
    if (_appPauseListenerRegistered) return;
    _appPauseListenerRegistered = true;
    App.addListener('appStateChange', ({ isActive }) => {
        if (!isActive) {
            _activeLongPressTimers.forEach(id => clearTimeout(id));
            _activeLongPressTimers.clear();
        }
    });
}
// ------------------------------------

export function attachLongPress(element, callback) {
    _ensureAppPauseListener();
    let timer;
    let isLongPress = false;
    let startX = 0;
    let startY = 0;

    const start = (e) => {
        if (e && e.type === 'mousedown' && e.button !== 0) return;

        if (e && e.touches && e.touches.length > 0) {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
        } else if (e) {
            startX = e.clientX;
            startY = e.clientY;
        }

        isLongPress = false;
        clearTimeout(timer);
        _activeLongPressTimers.delete(timer);

        timer = setTimeout(() => {
            _activeLongPressTimers.delete(timer);
            isLongPress = true;
            // Use Capacitor Haptics to bypass browser intervention
            try {
                Haptics.impact({ style: ImpactStyle.Light });
            } catch (err) {
                if (navigator.vibrate) try { navigator.vibrate(50); } catch (err2) { }
            }
            callback();
        }, 500);
        _activeLongPressTimers.add(timer);
    };

    const cancel = () => {
        clearTimeout(timer);
        _activeLongPressTimers.delete(timer);
    };

    const onMove = (e) => {
        let currentX = 0;
        let currentY = 0;

        if (e && e.touches && e.touches.length > 0) {
            currentX = e.touches[0].clientX;
            currentY = e.touches[0].clientY;
        } else if (e) {
            currentX = e.clientX;
            currentY = e.clientY;
        }

        if (Math.abs(currentX - startX) > 10 || Math.abs(currentY - startY) > 10) {
            cancel();
        }
    };

    element.addEventListener('touchstart', start, { passive: true });
    element.addEventListener('touchend', cancel);
    element.addEventListener('touchcancel', cancel);
    element.addEventListener('touchmove', onMove, { passive: true });

    element.addEventListener('mousedown', start);
    element.addEventListener('mouseup', cancel);
    element.addEventListener('mouseleave', cancel);
    element.addEventListener('mousemove', onMove, { passive: true });

    element.addEventListener('contextmenu', (e) => {
        e.preventDefault();
    });

    return () => isLongPress;
}

export function attachRipple(el) {
    if (el.dataset.rippleInit) return;
    el.dataset.rippleInit = 'true';

    const style = window.getComputedStyle(el);
    if (style.position === 'static') {
        el.style.position = 'relative';
    }

    el.style.overflow = 'hidden';

    el.addEventListener('pointerdown', function (e) {
        const circle = document.createElement('span');
        const diameter = Math.max(this.clientWidth, this.clientHeight);
        const radius = diameter / 2;

        const rect = this.getBoundingClientRect();

        circle.style.width = circle.style.height = `${diameter}px`;
        circle.style.left = `${e.clientX - rect.left - radius}px`;
        circle.style.top = `${e.clientY - rect.top - radius}px`;
        circle.classList.add('ripple');

        circle.style.background = `radial-gradient(circle, rgba(var(--vk-blue-rgb), 0.15) 0%, transparent 70%)`;

        circle.addEventListener('animationend', () => {
            circle.remove();
        });

        this.appendChild(circle);
    });
}

export function initRipple() {
    // Inject styles for the new ripple if not present
    if (!document.getElementById('ripple-effect-styles')) {
        const style = document.createElement('style');
        style.id = 'ripple-effect-styles';
        style.textContent = `
            @keyframes ripple-glow {
                0% { transform: scale(0.2); opacity: 1; }
                100% { transform: scale(2.5); opacity: 0; }
            }
            .ripple {
                position: absolute;
                border-radius: 50%;
                pointer-events: none;
                filter: blur(10px);
                animation: ripple-glow 0.8s ease-out forwards;
                z-index: -1;
            }
        `;
        document.head.appendChild(style);
    }

    const elements = document.querySelectorAll('.tabbar, .app-header, .menu-group, .preset-selector, .api-status, .glass-panel, .segmented-control, .bottom-sheet-content');
    elements.forEach(attachRipple);
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
    // Hardcoded palette to match CSS variables and avoid transition lag
    const palette = {
        light: {
            body: '#ffffff'
        },
        dark: {
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

    // Apply to body to prevent flashes
    document.documentElement.style.setProperty('--app-bg', theme.body);
    if (isDark) document.body.classList.add('dark-theme');
    else document.body.classList.remove('dark-theme');

    // Apply UI Element Effects
    const elemOp = localStorage.getItem('gz_theme_elem_opacity');
    const elemBl = localStorage.getItem('gz_theme_elem_blur');
    // Defaults: opacity 0.8, blur 12px
    document.documentElement.style.setProperty('--element-opacity', elemOp !== null ? elemOp : '0.8');
    document.documentElement.style.setProperty('--element-blur', (elemBl !== null ? elemBl : '12') + 'px');

    let meta = document.querySelector('meta[name="theme-color"]');
    if (!meta) {
        meta = document.createElement('meta');
        meta.name = "theme-color";
        document.head.appendChild(meta);
    }
    // Edge-to-edge makes the status bar transparent; color is controlled by the body/header background
    meta.setAttribute('content', isDark ? '#19191a' : '#ffffff');

    try {
        // DARK = light icons on dark background, LIGHT = dark icons on light background
        await SafeArea.setSystemBarsStyle({ style: isDark ? 'DARK' : 'LIGHT' });
    } catch (e) { console.warn('SafeArea SystemBars error', e); }
}

export function initThemeToggle() {
    // Inject global styles for text selection behavior
    if (!document.getElementById('ui-fixes-styles')) {
        const style = document.createElement('style');
        style.id = 'ui-fixes-styles';
        style.textContent = `
            body { -webkit-user-select: none; user-select: none; }
            .msg-body, .selectable, [contenteditable] { -webkit-user-select: text; user-select: text; }
            input, textarea, [contenteditable] { -webkit-user-select: auto; user-select: auto; }
        `;
        document.head.appendChild(style);
    }

    // Auto-detect system theme
    updateAppColors();

    // System theme change listener
    if (window.matchMedia) {
        const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
        const handleChange = async () => {
            if (getThemeMode() === 'system') {
                updateAppColors();

                const isDark = mediaQuery.matches;
                const presetId = localStorage.getItem(isDark ? 'gz_theme_system_dark' : 'gz_theme_system_light');
                if (presetId) {
                    const presets = await getPresets();
                    const preset = presets.find(p => p.id === presetId);
                    if (preset) {
                        await applyPreset(preset);
                    }
                }
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
        const t = translations[currentLang.value] || {};
        const map = {
            'system': t.theme_system || 'System',
            'dark': t.theme_dark || 'Dark',
            'light': t.theme_light || 'Light'
        };
        themeValue.textContent = map[getThemeMode()] || (t.theme_system || 'System');
    };
    updateThemeText();

    if (themeSelector) {
        themeSelector.addEventListener('click', () => {
            const t = translations[currentLang.value] || {};
            const getIcon = (mode) => getThemeMode() === mode ? '<svg viewBox="0 0 24 24" style="fill: var(--vk-blue);"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : '';
            showBottomSheet({
                title: t.theme_title || 'Theme',
                items: [
                    { label: t.theme_system || 'System', icon: getIcon('system'), onClick: () => { setThemeMode('system'); updateAppColors(); updateThemeText(); closeBottomSheet(); } },
                    { label: t.theme_dark || 'Dark', icon: getIcon('dark'), onClick: () => { setThemeMode('dark'); updateAppColors(); updateThemeText(); closeBottomSheet(); } },
                    { label: t.theme_light || 'Light', icon: getIcon('light'), onClick: () => { setThemeMode('light'); updateAppColors(); updateThemeText(); closeBottomSheet(); } }
                ]
            });
        });
    }

    // Holo Cards Selector
    const holoSelector = document.getElementById('holocards-selector');
    const holoValue = document.getElementById('holocards-value-text');

    const updateHoloText = () => {
        if (!holoValue) return;
        holoValue.textContent = imageViewerMode.value === 'holo' ? 'Holo Card' : 'Standard';
    };
    updateHoloText();

    if (holoSelector) {
        holoSelector.addEventListener('click', () => {
            const getIcon = (mode) => imageViewerMode.value === mode ? '<svg viewBox="0 0 24 24" style="fill: var(--vk-blue);"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>' : '';
            showBottomSheet({
                title: 'Image viewer',
                items: [
                    { label: 'Standard image viewer', description: 'Standard image viewer', icon: getIcon('default'), onClick: () => { setImageViewerMode('default'); updateHoloText(); closeBottomSheet(); } },
                    { label: 'Holographic card', description: 'It shines!', icon: getIcon('holo'), onClick: () => { setImageViewerMode('holo'); updateHoloText(); closeBottomSheet(); } }
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
                <span>${translations[currentLang.value][item.i18n]}</span>
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
    const isIos = Capacitor.getPlatform() === 'ios';

    // Update viewport meta tag dynamically
    const viewport = document.querySelector('meta[name="viewport"]');
    if (viewport) {
        let content = viewport.getAttribute('content');
        let changed = false;

        // Dynamic viewport-fit=cover for iOS only (required for safe areas)
        if (isIos && !content.includes('viewport-fit=cover')) {
            content += ', viewport-fit=cover';
            changed = true;
        }

        // Ensure interactive-widget=overlays-content is present for all to prevent native viewport shrinking
        if (!content.includes('interactive-widget=overlays-content')) {
            content += ', interactive-widget=overlays-content';
            changed = true;
        }

        if (changed) {
            viewport.setAttribute('content', content);
        }
    }

    if (isIos) {
        SafeArea.showSystemBars({ bar: 'NAVIGATION_BAR' }).catch(() => { });
    }

    // Fix for 100vh on mobile browsers (address bar issue)
    const setVh = () => {
        if (isKeyboardOpen.value && isIos) return;
        const vh = window.innerHeight * 0.01;
        document.documentElement.style.setProperty('--vh', `${vh}px`);
    };

    window.addEventListener('resize', setVh);
    setVh();

    initKeyboard();
}

export function initBackButton() {
    let lastBackPress = 0;
    const handleBackButton = async () => {
        // 0. If keyboard is open — dismiss it
        if (isKeyboardOpen.value) {
            await hideKeyboard();
            return;
        }

        // 1. Check for open Bottom Sheets
        const openSheet = document.querySelector('.modal-overlay.visible');
        if (openSheet) {
            closeBottomSheet();
            return;
        }

        // 1.1 Check SheetView
        const openSheetView = document.querySelector('.sheet-view-overlay.visible');
        if (openSheetView) {
            openSheetView.click();
            return;
        }

        // 1.2 Check Magic Drawer (ChatInput)
        // Skip if it is already in the process of closing (leave animation)
        const magicDrawer = document.querySelector('.magic-drawer');
        if (magicDrawer && !magicDrawer.classList.contains('drawer-leave-active')) {
            const btn = document.getElementById('btn-magic');
            if (btn) btn.click();
            return;
        }

        // 1.25 Check chat search mode
        const searchBackBtn = document.querySelector('.chat-search-back');
        if (searchBackBtn && searchBackBtn.offsetParent !== null) {
            searchBackBtn.click();
            return;
        }

        // 1.3 Check message selection mode
        const cancelSelectionBtn = document.querySelector('.btn-cancel-selection');
        if (cancelSelectionBtn && cancelSelectionBtn.offsetParent !== null) {
            cancelSelectionBtn.click();
            return;
        }

        // Check Viewers (Image Viewer & Holo Cards)
        // We look for any visible element with class 'viewer-overlay'
        const visibleViewer = document.querySelector('.viewer-overlay.visible');
        if (visibleViewer) {
            // Try to find a close button inside, or just dispatch a click if it has a handler
            const closeBtn = visibleViewer.querySelector('.close-btn-trigger') || visibleViewer.querySelector('#image-viewer-close-btn') || visibleViewer.querySelector('#holocards-close-btn');
            if (closeBtn) closeBtn.click();
            return;
        }

        // 2. Check full-screen editor
        const fsEditor = document.getElementById('full-screen-editor');
        if (fsEditor && fsEditor.style.display !== 'none') {
            const closeBtn = document.getElementById('fs-editor-close');
            if (closeBtn) closeBtn.click();
            return;
        }

        // 2.1 Check onboarding (back arrow)
        const onboardingBack = document.querySelector('.onboarding-overlay .nav-back-btn');
        if (onboardingBack) {
            onboardingBack.click();
            return;
        }

        // 3. Check header back button
        const backBtn = document.getElementById('header-back');
        if (backBtn && backBtn.offsetParent !== null) {
            backBtn.click();
            return;
        }

        // 4. App exit logic (main screen)
        const now = Date.now();
        if (now - lastBackPress < 2000) {
            App.exitApp();
        } else {
            lastBackPress = now;
            await Toast.show({
                text: (translations[currentLang.value] && translations[currentLang.value]['exit_hint']) || 'Press again to exit',
                duration: 'short',
                position: 'bottom'
            });
        }
    };

    App.addListener('backButton', handleBackButton);
    // For console testing: window.simulateBackButton()
    window.simulateBackButton = handleBackButton;

    // Handle Escape key as back button
    window.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            handleBackButton();
        }
    });
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

export function animateNumber(start, end, duration, callback) {
    const startTime = performance.now();
    let rafId;

    function update(currentTime) {
        const elapsed = currentTime - startTime;
        const progress = Math.min(elapsed / duration, 1);
        const ease = 1 - Math.pow(1 - progress, 3); // Ease Out Cubic

        const value = start + (end - start) * ease;
        callback(value);

        if (progress < 1) {
            rafId = requestAnimationFrame(update);
        } else {
            callback(end);
        }
    }

    rafId = requestAnimationFrame(update);
    return () => cancelAnimationFrame(rafId);
}

export function animateOdometer(element, target) {
    const start = parseFloat(element.textContent) || 0;
    const end = parseFloat(target);

    if (isNaN(end)) {
        element.textContent = target;
        return;
    }

    if (element._cancelOdometer) element._cancelOdometer();

    element._cancelOdometer = animateNumber(start, end, 200, (val) => {
        element.textContent = val.toFixed(1) + 's';
    });
}

export function initHeaderScroll(messagesContainer, initialScrollTop, isGeneratingCallback) {
    let lastScrollTop = initialScrollTop || 0;
    let ticking = false;
    let isHidden = false;

    const updateHeader = () => {
        const st = messagesContainer.scrollTop;
        const scrollBtn = document.getElementById('scroll-to-bottom');

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
            if (!isHidden) {
                window.dispatchEvent(new CustomEvent('header-scroll-hidden', { detail: true }));
                isHidden = true;
            }
        } else if (st < lastScrollTop - 3) {
            if (isHidden) {
                window.dispatchEvent(new CustomEvent('header-scroll-hidden', { detail: false }));
                isHidden = false;
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