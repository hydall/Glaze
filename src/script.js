import { initGlobalErrorHandling } from './errorHandler.js';
import { initSettings } from './APISettings.js';
import { translations, updateLanguage } from './i18n.js';
import { currentLang, setLanguage } from './APPSettings.js';
import * as CharList from './characterList.js';
import * as Chat from './chat.js';
import { renderDialogs } from './dialogList.js';
import { initRipple, initThemeToggle, initLanguageToggle, initHeaderDropdown, initBackButton, initViewportFix, initKeyboardFix } from './ui.js';
import { initGenericBottomSheet } from './bottomsheet.js';
import { initPromptEditor } from './promptBuilder.js';
import { initPersonas } from './personas.js';
import { setupDefaultHeader, setupGenerationHeader, setupMoreHeader } from './header.js';

let activeCategories = {
    'view-dialogs': 'all',
    'view-characters': 'all'
};

// Initialize error handling as early as possible
initGlobalErrorHandling();

document.addEventListener('DOMContentLoaded', async () => {
    console.log("Debug: DOMContentLoaded - App initializing...");
    document.body.classList.add('preload');
    
    try {
        localStorage.setItem('sc_debug_test', 'ok');
        localStorage.removeItem('sc_debug_test');
        console.log("Debug: localStorage is available.");
    } catch (e) {
        console.error("Debug: localStorage is NOT available:", e);
    }

    // Navigation Logic
    const tabs = document.querySelectorAll('.tab-btn');
    const views = document.querySelectorAll('.view');
    let pendingAnimation = null;

    // Dropdown Categories Configuration
    const categories = {
        'view-dialogs': [
            { id: 'all', i18n: 'cat_all_dialogs' },
            { id: 'personal', i18n: 'cat_personal' },
            { id: 'groups', i18n: 'cat_groups' }
        ],
        'view-characters': [
            { id: 'all', i18n: 'cat_all_chars' },
            { id: 'anime', i18n: 'cat_anime' },
            { id: 'games', i18n: 'cat_games' }
        ]
    };

    function updateHeaderForView(targetId) {
        const activeTab = document.querySelector(`.tab-btn[data-target="${targetId}"]`);
        const titleKey = activeTab ? activeTab.getAttribute('data-i18n-title') : '';
        const title = titleKey ? translations[currentLang][titleKey] : '';

        if (targetId === 'view-generation') {
            const subTabsContainer = document.querySelector('.sub-tab-bar'); // Assuming this class exists or we find parent
            const subTabsBtn = document.querySelector('.sub-tab-btn');
            setupGenerationHeader(title, subTabsBtn ? subTabsBtn.parentNode : null);
        } else if (targetId === 'view-menu') {
            const personaCard = document.getElementById('persona-card');
            setupMoreHeader(title, personaCard);
        } else if (targetId === 'view-dialogs' || targetId === 'view-characters') {
            setupDefaultHeader(title, !!categories[targetId]);
            const appHeader = document.querySelector('.app-header');
            if (appHeader) appHeader.classList.add('no-border');
        } else {
            setupDefaultHeader(title, !!categories[targetId]);
        }
    }

    function openChatWrapper(char) {
        const previousView = document.querySelector('.view.active-view');
        Chat.openChat(char, () => {
            if (previousView) {
                previousView.classList.add('active-view', 'anim-fade-in');
                updateHeaderForView(previousView.id); // Restore header state (title, border, etc.)
            }
            renderDialogs(activeCategories['view-dialogs'], openChatWrapper);
        });
    }

    tabs.forEach((tab) => {
        tab.addEventListener('click', () => {
            const targetId = tab.getAttribute('data-target');
            const newView = document.getElementById(targetId);
            // Ищем текущий активный экран динамически
            const oldView = document.querySelector('.view.active-view');

            // Если нажали на ту же вкладку, ничего не делаем
            if (newView === oldView) return;

            // Если есть незавершенная анимация, отменяем её обработчик очистки
            if (pendingAnimation) {
                pendingAnimation.element.removeEventListener('animationend', pendingAnimation.handler);
                pendingAnimation = null;
            }

            // Сброс классов анимации и скрытие неактивных экранов
            views.forEach(v => {
                v.classList.remove('anim-fade-in', 'anim-fade-out');
                // Оставляем видимым только тот экран, с которого уходим (чтобы он мог красиво исчезнуть)
                if (v !== oldView) v.classList.remove('active-view');
            });

            // Обновляем табы
            tabs.forEach(t => t.classList.remove('active'));
            tab.classList.add('active');
            
            updateHeaderForView(targetId);

            // Запуск новой анимации
            newView.classList.add('active-view');
            
            if (oldView) {
                oldView.classList.add('anim-fade-out');
                newView.classList.add('anim-fade-in');

                const onAnimationEnd = () => {
                    oldView.classList.remove('active-view', 'anim-fade-out');
                    newView.classList.remove('anim-fade-in');
                    pendingAnimation = null;
                };

                oldView.addEventListener('animationend', onAnimationEnd, { once: true });
                // Сохраняем ссылку на обработчик, чтобы отменить его при быстром клике
                pendingAnimation = { element: oldView, handler: onAnimationEnd };
            } else {
                // Если старого экрана нет (первый запуск), просто показываем новый
                newView.classList.remove('anim-fade-in');
            }
        });
    });

    // Generation Sub-tabs Logic
    const subTabs = document.querySelectorAll('.sub-tab-btn');
    subTabs.forEach(btn => {
        btn.addEventListener('click', () => {
            // UI Update
            subTabs.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            // View Update
            document.querySelectorAll('.sub-view').forEach(v => v.classList.remove('active-sub-view'));
            document.getElementById(btn.dataset.subtarget).classList.add('active-sub-view');
        });
    });

    // Initialize Settings (API, etc)
    initSettings();

    // Prompt Preset Logic
    initPromptEditor();

    // UI Initialization (Ripple, Theme, Language, Dropdown)
    initRipple();
    initThemeToggle();
    
    initViewportFix();
    initKeyboardFix();
    initBackButton();
    initLanguageToggle(() => {
        setLanguage(currentLang === 'ru' ? 'en' : 'ru');
        updateLanguage();
    });

    initHeaderDropdown(categories, activeCategories, (viewId, itemId) => {
        if (viewId === 'view-dialogs') renderDialogs(itemId, openChatWrapper);
        if (viewId === 'view-characters') CharList.renderList(itemId);
    });


    // Mock Data Generation
    await CharList.loadCharacters(); // Загрузка из IndexedDB
    await Chat.loadChats(); // Загрузка чатов
    CharList.init(openChatWrapper);
    CharList.renderList(activeCategories['view-characters']);
    await renderDialogs('all', openChatWrapper);
    await initPersonas(); // Now imported from personas.js
    await initPromptEditor();
    Chat.initChat();
    
    // Initialize Generic Bottom Sheet
    initGenericBottomSheet();

    // initActionSheets(); // No longer needed as sheets are dynamic
    updateLanguage(); // Initial translation

    updateHeaderForView('view-dialogs');

    // Search Listeners
    const searchDialogs = document.getElementById('search-dialogs');
    if (searchDialogs) {
        searchDialogs.addEventListener('input', (e) => {
            renderDialogs(activeCategories['view-dialogs'], openChatWrapper, e.target.value);
        });
    }

    const searchChars = document.getElementById('search-characters');
    if (searchChars) {
        searchChars.addEventListener('input', (e) => {
            CharList.renderList(activeCategories['view-characters'], e.target.value);
        });
    }

    // Remove preload class to enable transitions
    setTimeout(() => {
        document.body.classList.remove('preload');
        document.body.classList.add('app-loaded');
    }, 100);
});