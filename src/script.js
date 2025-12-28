import { initSettings } from './APISettings.js';
import { translations, updateLanguage } from './i18n.js';
import { currentLang, setLanguage } from './APPSettings.js';
import * as CharList from './characterList.js';
import * as Chat from './chat.js';
import { renderDialogs } from './dialogList.js';
import { initBottomSheet, openBottomSheet, closeBottomSheet, initRipple, initThemeToggle, initLanguageToggle, initHeaderDropdown, initBackButton } from './ui.js';
import { initPromptEditor } from './promptBuilder.js';
import { initPersonas } from './personas.js';

let activeCategories = {
    'view-dialogs': 'all',
    'view-characters': 'all'
};

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
    const headerTitle = document.getElementById('header-title');
    const backBtn = document.getElementById('header-back');
    const headerDefault = document.getElementById('header-content-default');
    const headerChatInfo = document.getElementById('header-chat-info');
    const headerActions = document.getElementById('header-actions');
    
    // Переменная для хранения текущей анимации, чтобы можно было отменить очистку при быстром клике
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
            
            // Update Header Title with translation
            const titleKey = tab.getAttribute('data-i18n-title');
            headerTitle.classList.add('fade-out');
            setTimeout(() => {
                headerTitle.textContent = translations[currentLang][titleKey];
                headerTitle.classList.remove('fade-out');
            }, 150);

            // Toggle Header Border for Generation View
            const appHeader = document.querySelector('.app-header');
            if (targetId === 'view-generation' || targetId === 'view-menu') {
                appHeader.classList.add('no-border');
            } else {
                appHeader.classList.remove('no-border');
            }

            // Update Arrow Visibility
            const arrow = document.getElementById('header-arrow');
            if (categories[targetId]) {
                arrow.style.display = 'block';
            } else {
                arrow.style.display = 'none';
            }

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
    
    // Initialize Bottom Sheets (Swipe Logic)
    const sheetIds = [
        'personas-sheet-overlay',
        'char-options-sheet-overlay',
        'char-selection-sheet-overlay',
        'chat-actions-sheet-overlay',
        'char-actions-sheet-overlay',
        'sessions-sheet-overlay',
        'char-delete-confirm-sheet',
        'msg-actions-sheet-overlay',
        'prompt-presets-sheet-overlay',
        'new-preset-sheet-overlay',
        'delete-block-sheet-overlay',
        'delete-preset-sheet-overlay',
        'session-delete-confirm-sheet',
        'chat-info-sheet-overlay'
    ];
    sheetIds.forEach(id => initBottomSheet(id));

    initActionSheets();
    updateLanguage(); // Initial translation

    // Remove preload class to enable transitions
    setTimeout(() => {
        document.body.classList.remove('preload');
    }, 100);
});

function openChatWrapper(char) {
    const previousView = document.querySelector('.view.active-view');
    Chat.openChat(char, () => {
        if (previousView) previousView.classList.add('active-view', 'anim-fade-in');
        renderDialogs(activeCategories['view-dialogs'], openChatWrapper);
    });
}

// Action Sheets Logic
function initActionSheets() {
    const chatSheet = document.getElementById('chat-actions-sheet-overlay');
}