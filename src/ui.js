import { currentLang } from './APPSettings.js';
import { translations } from './i18n.js';
import { App } from '@capacitor/app';
import { Toast } from '@capacitor/toast';

export function attachLongPress(element, callback) {
    let timer;
    let isLongPress = false;

    const start = () => {
        isLongPress = false;
        timer = setTimeout(() => {
            isLongPress = true;
            if (navigator.vibrate) navigator.vibrate(50);
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

export function initBottomSheet(id) {
    const overlay = document.getElementById(id);
    if (!overlay) return;
    const content = overlay.querySelector('.bottom-sheet-content');
    
    let startY = 0;
    let isDragging = false;

    overlay.addEventListener('click', (e) => {
        if (e.target === overlay) closeBottomSheet(id);
    });

    content.addEventListener('touchstart', (e) => {
        if (content.scrollTop > 0) return;
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
            closeBottomSheet(id);
        } else {
            content.style.transform = '';
        }
    });
}

export function openBottomSheet(id) {
    const overlay = document.getElementById(id);
    if (!overlay) return;
    const content = overlay.querySelector('.bottom-sheet-content');
    overlay.style.display = 'flex';
    
    // Use requestAnimationFrame to ensure the browser registers the display change before adding the class
    requestAnimationFrame(() => {
        content.style.transform = ''; 
        overlay.classList.add('visible');
    });
}

export function closeBottomSheet(id) {
    const overlay = document.getElementById(id);
    if (!overlay) return;
    const content = overlay.querySelector('.bottom-sheet-content');
    content.style.transform = '';
    overlay.classList.remove('visible');
    setTimeout(() => {
        overlay.style.display = 'none';
        content.style.transform = '';
    }, 300);
}

export function initRipple() {
    const tabbar = document.querySelector('.tabbar');
    if (tabbar) {
        tabbar.addEventListener('click', function(e) {
            const circle = document.createElement('span');
            const diameter = Math.max(this.clientWidth, this.clientHeight);
            const radius = diameter / 2;
            
            const rect = this.getBoundingClientRect();
            
            circle.style.width = circle.style.height = `${diameter}px`;
            circle.style.left = `${e.clientX - rect.left - radius}px`;
            circle.style.top = `${e.clientY - rect.top - radius}px`;
            circle.classList.add('ripple');
            
            const ripple = this.getElementsByClassName('ripple')[0];
            if (ripple) {
                ripple.remove();
            }
            
            this.appendChild(circle);
        });
    }
}

export function initThemeToggle() {
    const themeToggle = document.getElementById('theme-toggle');

    const updateStatusBar = () => {
        const isDark = document.body.classList.contains('dark-theme');
        const color = isDark ? '#121212' : '#ffffff';
        let meta = document.querySelector('meta[name="theme-color"]');
        if (!meta) {
            meta = document.createElement('meta');
            meta.name = "theme-color";
            document.head.appendChild(meta);
        }
        meta.setAttribute('content', color);
    };

    // Auto-detect system theme
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
        document.body.classList.add('dark-theme');
    }
    updateStatusBar();

    if (themeToggle) {
        themeToggle.addEventListener('click', () => {
            document.body.classList.toggle('dark-theme');
            updateStatusBar();
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

export function initBackButton() {
    let lastBackPress = 0;
    const handleBackButton = async () => {
        // 1. Проверяем открытые Bottom Sheets
        const openSheet = document.querySelector('.modal-overlay.visible');
        if (openSheet) {
            closeBottomSheet(openSheet.id);
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