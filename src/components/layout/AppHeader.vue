<script setup>
import { reactive, computed, watch, nextTick, onMounted, onBeforeUnmount, ref } from 'vue';
import { translations } from '@/utils/i18n.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { activePersona, allPersonas, setActivePersona } from '@/core/states/personaState.js';
import { logger } from '../../utils/logger.js';
import { notificationsState, clearUnread } from '@/core/states/notificationsState.js';

const props = defineProps({
  currentView: String,
  categories: Object,
  editingIndex: { type: Number, default: -1 }
});

const emit = defineEmits(['action-save', 'action-delete', 'action-close']);

const headerEl = ref(null);

// State
const state = reactive({
    mode: 'default', // default, editor, chat, generation, more
    title: '',
    showLogo: false,
    showBack: false,
    showChatInfo: false,
    showActions: false,
    scrollHidden: false,
    hasSubheader: false,
    showSearch: false,
    isChatSearchMode: false,
    searchQuery: '',
    searchPlaceholder: '',
    generationTab: 'subview-api',
    onGenerationTabChange: null,
    tabApiLabel: '',
    tabPresetLabel: '',
    actions: [], // { id, icon, onClick, color }
    chat: {
        name: '',
        session: '',
        avatar: '',
        color: '',
        initial: '?',
        callbacks: null
    },
    lorebookBanner: {
        show: false,
        names: [],
        presetName: '', 
        personaName: '',
        timer: null,
        isTransitioning: false
    },
    onBack: null
});

// Computed
const headerClasses = computed(() => {
    const classes = ['app-header'];
    if (state.scrollHidden && !state.isChatSearchMode && state.mode !== 'editor') classes.push('scroll-hidden');
    if (state.mode === 'chat') classes.push('fixed-header');
    if (['generation', 'more'].includes(state.mode) || state.hasSubheader || state.showSearch || state.lorebookBanner.show || state.lorebookBanner.isTransitioning) {
        classes.push('header-wrap');
    }
    return classes.join(' ');
});

const avatarLetter = computed(() => {
    const name = activePersona.value.name;
    return (name && name[0]) ? name[0].toUpperCase() : "?";
});

// Internal Methods
function clearHeader(nextMode = 'default', keepSearchVisibility = false) {
    state.mode = nextMode;
    state.showLogo = false;
    state.showBack = false;
    state.showChatInfo = false;
    state.showActions = false;
    state.actions = [];
    state.generationTab = 'subview-api';
    state.onGenerationTabChange = null;
    state.onBack = null;
    if (!keepSearchVisibility) {
        state.showSearch = false;
        state.isChatSearchMode = false;
    }
    state.searchQuery = '';
    state.hasSubheader = false;
    state.scrollHidden = false;
    if (state.lorebookBanner.timer) {
        clearTimeout(state.lorebookBanner.timer);
        state.lorebookBanner.timer = null;
    }
    state.lorebookBanner.show = false;
}

function toggleTabbar(show) {
    const tabbar = document.querySelector('.tabbar');
    if (tabbar) tabbar.style.display = show ? 'flex' : 'none';
}

// Setup Methods
function setupDefaultHeader(title, showDropdown, keepSearchVisibility = false) {
    clearHeader('default', keepSearchVisibility);
    state.title = title;
    state.showLogo = true;
    toggleTabbar(true);
}

function setupEditorHeader(title, onBack, actions) {
    logger.debug('[AppHeader] setupEditorHeader:', title);
    clearHeader('editor');
    state.title = title;
    state.showBack = true;
    state.showActions = true;
    state.actions = actions || [];
    state.onBack = onBack;
    toggleTabbar(false);
}

function setupChatHeader(char, currentSessionId, callbacks, sessionName) {
    clearHeader('chat');
    state.showChatInfo = true;
    state.showActions = true;
    state.showBack = true;
    
    const safeName = (char && char.name) ? char.name : "Unknown";
    state.chat.name = safeName.length > 20 ? safeName.substring(0, 20) + '...' : safeName;
    state.chat.session = sessionName || `Session #${currentSessionId}`;
    state.chat.avatar = char && char.avatar ? char.avatar : null;
    state.chat.color = char && char.color ? char.color : '';
    state.chat.initial = (safeName[0] || "?").toUpperCase();
    state.chat.callbacks = callbacks;
    
    state.actions = [{
        id: 'chat-search-action',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor" style="width:24px;height:24px;"><path d="M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>`,
        onClick: () => {
             state.isChatSearchMode = !state.isChatSearchMode;
             if (!state.isChatSearchMode) {
                 state.searchQuery = '';
             }
             window.dispatchEvent(new CustomEvent('header-chat-search-toggle', { detail: state.isChatSearchMode }));
             if (state.isChatSearchMode) {
                 nextTick(() => {
                     const input = headerEl.value?.querySelector('.chat-search-input');
                     if (input) input.focus();
                 });
             }
        }
    }];
    
    state.onBack = () => {
        if (state.isChatSearchMode) {
            state.isChatSearchMode = false;
            state.searchQuery = '';
            window.dispatchEvent(new CustomEvent('header-chat-search-toggle', { detail: false }));
        } else {
            callbacks.onBackClick();
        }
    };
    toggleTabbar(false);
}

function setupGenerationHeader(title, activeTab, onTabChange) {
    logger.debug('[AppHeader] setupGenerationHeader:', title);
    clearHeader('generation');
    state.title = title;
    state.showLogo = true;
    state.generationTab = activeTab || 'subview-api';
    state.onGenerationTabChange = onTabChange;
    state.tabApiLabel = translations[currentLang.value]?.subtab_api || 'API';
    state.tabPresetLabel = translations[currentLang.value]?.subtab_preset || 'Preset';
    toggleTabbar(true);
}

function setupMoreHeader(title) {
    clearHeader('more');
    state.title = title;
    state.showLogo = true;
    toggleTabbar(true);
}

function setupThemeSettingsHeader(title) {
    clearHeader('default');
    state.title = title;
    state.showBack = true;
    state.onBack = () => window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-menu' }));
    toggleTabbar(false); // Hide tabbar for full screen feel
}

function setupGlossaryHeader() {
    clearHeader('default');
    state.title = translations[currentLang.value]?.menu_glossary || 'Glossary';
    state.showBack = true;
    state.onBack = () => window.dispatchEvent(new CustomEvent('gl-back'));
    toggleTabbar(true);
}

function setupSettingsHeader(title) {
    clearHeader('default');
    state.title = title;
    state.showBack = true;
    state.onBack = () => window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-menu' }));
    toggleTabbar(true);
}

function updateHeader() {
    const viewId = props.currentView;
    if (viewId === 'view-chat') return; // Chat module handles its own header
    const needsSearch = ['view-dialogs', 'view-characters'].includes(viewId);

    const titleKeys = {
        'view-dialogs': 'tab_dialogs',
        'view-characters': 'tab_characters',
        'view-generation': 'tab_generation',
        'view-menu': 'tab_more',
        'view-character-edit': 'header_editor',
        'view-theme-settings': 'header_theme_settings',
        'view-settings': 'section_settings'
    };
    
    const key = titleKeys[viewId];
    const title = key ? translations[currentLang.value][key] : '';

    if (viewId === 'view-glossary') {
        setupGlossaryHeader();
        return;
    } else if (viewId === 'view-generation') {
        setupGenerationHeader(title, state.generationTab, state.onGenerationTabChange);
    } else if (viewId === 'view-menu') {
        setupMoreHeader(title);
    } else if (viewId === 'view-theme-settings') {
        setupThemeSettingsHeader(title);
    } else if (viewId === 'view-settings') {
        setupSettingsHeader(title);
    } else if (viewId === 'view-character-edit') {
        const isNew = props.editingIndex === -1;
        const tr = translations[currentLang.value] || {};
        const editTitle = isNew 
            ? (tr.action_create_new || 'Create New') 
            : (tr.header_editor || 'Editor');
        
        const actions = [];
        if (isNew) {
            actions.push({
                icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                onClick: () => emit('action-save')
            });
        } else {
            actions.push({
                icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                color: '#ff4444',
                onClick: () => emit('action-delete')
            });
        }
        setupEditorHeader(editTitle, () => emit('action-close'), actions);
    } else if (viewId === 'view-persona-edit') {
        logger.debug('[AppHeader] Setting up Persona Editor Header');
        const isNew = props.editingIndex === -1;
        const tr = translations[currentLang.value] || {};
        const editTitle = isNew 
            ? (tr.new_persona || 'New Persona') 
            : (tr.header_editor || 'Editor');
        
        const actions = [];
        if (isNew) {
            // Auto-save on exit is enabled, so we don't need a manual save button for Personas.
            // This prevents duplicate creation if user clicks Save and then Back.
            // actions.push({
            //     icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
            //     onClick: () => emit('action-save')
            // });
        } else {
            actions.push({
                icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                color: '#ff4444',
                onClick: () => emit('action-delete')
            });
        }
        setupEditorHeader(editTitle, () => emit('action-close'), actions);
    } else {
        setupDefaultHeader(title, !!props.categories[viewId], needsSearch);
    }

    // Setup Search for specific views
    if (needsSearch) {
        state.showSearch = true;
        state.searchPlaceholder = viewId === 'view-dialogs' ? (translations[currentLang.value]?.search_dialogs || 'Search') : (translations[currentLang.value]?.search_characters || 'Search characters');
    }

    nextTick(() => {
        window.dispatchEvent(new CustomEvent('header-view-changed', { detail: props.currentView }));
    });
}

// --- Persona Logic (Moved from MenuView) ---
const t = (key) => translations[currentLang.value]?.[key] || key;

// Event Handlers
const handleBack = () => {
    if (state.onBack) state.onBack();
};

const handleActionsClick = (e) => {
    if (state.chat.callbacks?.onActionsClick) state.chat.callbacks.onActionsClick();
};

const handleAvatarClick = (e) => {
    e.stopPropagation();
    if (state.chat.avatar) {
        window.dispatchEvent(new CustomEvent('trigger-open-image', {
            detail: {
                src: state.chat.avatar,
                name: state.chat.name
            }
        }));
    }
};

// Listeners for external events (from header.js bridge)
const onSetupChat = (e) => {
    const { char, currentSessionId, callbacks, sessionName } = e.detail;
    setupChatHeader(char, currentSessionId, callbacks, sessionName);
};

const onUpdateAvatar = (e) => {
    const char = e.detail || {};
    const safeName = char.name || "Unknown";
    state.chat.avatar = char.avatar;
    state.chat.color = char.color;
    state.chat.initial = (safeName[0] || "?").toUpperCase();
};

const onSetupEditor = (e) => {
    logger.debug('[AppHeader] Event header-setup-editor received', e.detail);
    const { title, onBack, actions } = e.detail;
    setupEditorHeader(title, onBack, actions);
};

const onSetupSubmenu = (e) => {
    const { title, onBack } = e.detail;
    clearHeader('default');
    state.title = title;
    state.showBack = true;
    state.onBack = onBack;
    toggleTabbar(true);
};

const onForceUpdate = () => {
    updateHeader();
};

const onSetupGeneration = (e) => {
    logger.debug('[AppHeader] Event header-setup-generation received', e.detail);
    const { title, activeTab, onTabChange } = e.detail;
    setupGenerationHeader(title, activeTab, onTabChange);
};

const onUpdateSession = (e) => {
    if (state.mode === 'chat') {
        state.chat.session = `Session #${e.detail}`;
    }
};

const onScrollHidden = (e) => {
    state.scrollHidden = e.detail;
};

const onResetHeader = () => {
    clearHeader();
    setupDefaultHeader("", false);
};

const onShowLbBanner = (e) => {
    if (state.lorebookBanner.timer) clearTimeout(state.lorebookBanner.timer);
    
    // Support both Legacy (Array) and New (Object) formats
    if (Array.isArray(e.detail)) {
        state.lorebookBanner.names = e.detail;
        state.lorebookBanner.presetName = '';
    } else {
        state.lorebookBanner.names = e.detail.names || [];
        state.lorebookBanner.presetName = e.detail.preset || '';
        state.lorebookBanner.personaName = e.detail.persona || '';
    }

    state.lorebookBanner.show = true;

    state.lorebookBanner.timer = setTimeout(() => {
        state.lorebookBanner.show = false;
        state.lorebookBanner.timer = null;
    }, 4000);
};

function onBannerBeforeEnter() {
    state.lorebookBanner.isTransitioning = true;
    onBeforeTransition();
}
function onBannerEnter() {
    onStartTransition();
}
function onBannerAfterEnter() {
    onAfterTransition();
    state.lorebookBanner.isTransitioning = false;
}
function onBannerBeforeLeave() {
    state.lorebookBanner.isTransitioning = true;
    onBeforeTransition();
}
function onBannerLeave() {
    onStartTransition();
}
function onBannerAfterLeave() {
    onAfterTransition();
    state.lorebookBanner.isTransitioning = false;
}

const onChangeGenerationTab = (e) => {
    if (state.mode === 'generation') {
        handleGenTabClick(e.detail);
    }
};

const handleGenTabClick = (tab) => {
    state.generationTab = tab;
    if (state.onGenerationTabChange) {
        state.onGenerationTabChange(tab);
    }
};

// Update the header whenever the view or editing index changes
watch([() => props.currentView, () => props.editingIndex], updateHeader);

// Initial update on mount
onMounted(() => {
    updateHeader();
    window.addEventListener('header-setup-chat', onSetupChat);
    window.addEventListener('header-update-avatar', onUpdateAvatar);
    window.addEventListener('header-scroll-hidden', onScrollHidden);
    window.addEventListener('header-setup-editor', onSetupEditor);
    window.addEventListener('header-setup-generation', onSetupGeneration);
    window.addEventListener('header-reset', onResetHeader);
    window.addEventListener('header-update-session', onUpdateSession);
    window.addEventListener('change-generation-tab', onChangeGenerationTab);
    window.addEventListener('header-show-lb-banner', onShowLbBanner);
    window.addEventListener('header-setup-submenu', onSetupSubmenu);
    window.addEventListener('header-force-update', onForceUpdate);
    window.addEventListener('gl-header-update', onGlossaryHeaderUpdate);
});

onBeforeUnmount(() => {
    window.removeEventListener('header-setup-chat', onSetupChat);
    window.removeEventListener('header-update-avatar', onUpdateAvatar);
    window.removeEventListener('header-scroll-hidden', onScrollHidden);
    window.removeEventListener('header-setup-editor', onSetupEditor);
    window.removeEventListener('header-setup-generation', onSetupGeneration);
    window.removeEventListener('header-reset', onResetHeader);
    window.removeEventListener('header-update-session', onUpdateSession);
    window.removeEventListener('change-generation-tab', onChangeGenerationTab);
    window.removeEventListener('header-show-lb-banner', onShowLbBanner);
    window.removeEventListener('header-setup-submenu', onSetupSubmenu);
    window.removeEventListener('header-force-update', onForceUpdate);
    window.removeEventListener('gl-header-update', onGlossaryHeaderUpdate);
});

function onGlossaryHeaderUpdate(e) {
    if (props.currentView !== 'view-glossary') return;
    if (e.detail.title !== undefined) state.title = e.detail.title;
    // showBack stays true — back always navigates to view-menu
}

watch(() => state.searchQuery, (val) => {
    if (state.mode === 'chat' && state.isChatSearchMode) {
        window.dispatchEvent(new CustomEvent('header-chat-search', { detail: val }));
    } else {
        window.dispatchEvent(new CustomEvent('header-search', { detail: val }));
    }
});

// Transition Hooks for smooth height animation
function onBeforeTransition() {
    if (!headerEl.value) return;
    // Lock the current height
    headerEl.value.style.height = headerEl.value.offsetHeight + 'px';
}

function onStartTransition() {
    if (!headerEl.value) return;
    const startHeight = headerEl.value.style.height;
    
    // Measure the target height
    headerEl.value.style.height = 'auto';
    const targetHeight = headerEl.value.offsetHeight;
    
    // Restore start height
    headerEl.value.style.height = startHeight;
    
    // Force reflow
    void headerEl.value.offsetHeight;
    
    // Animate to the target height
    headerEl.value.style.height = targetHeight + 'px';
}

function onAfterTransition() {
    if (!headerEl.value) return;
    // Unlock height
    headerEl.value.style.height = 'auto';
}

function openNotifications() {
    clearUnread();
    window.dispatchEvent(new CustomEvent('open-notifications-sheet'));
}

// Expose updateHeader so the parent can force a refresh (e.g., on language change)
defineExpose({ updateHeader });
</script>

<template>
  <header ref="headerEl" :class="headerClasses">
      <!-- Left Section -->
      <div v-if="state.showBack && !state.isChatSearchMode" id="header-back" class="header-btn-left" @click="handleBack">
          <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
      </div>

      <!-- Logo -->
      <div v-if="state.showLogo" id="header-logo" class="header-logo">
          <svg viewBox="0 0 600 600" width="26" height="26" style="fill: var(--vk-blue);">
              <g transform="translate(0.000000,600.000000) scale(0.100000,-0.100000)">
                  <path d="M2799 4916 c-2 -2 -33 -7 -69 -10 -36 -3 -76 -8 -90 -11 -14 -2 -65 -12 -115 -21 -49 -9 -116 -25 -147 -35 -32 -11 -63 -19 -71 -19 -7 0 -31 -8 -53 -19 -21 -10 -55 -22 -74 -26 -38 -8 -146 -60 -285 -136 -43 -23 -118 -79 -123 -91 -2 -5 -10 -8 -18 -8 -8 0 -14 -4 -14 -10 0 -5 -6 -10 -13 -10 -8 0 -27 -13 -43 -30 -16 -16 -34 -30 -40 -30 -7 0 -30 -20 -52 -45 -23 -25 -45 -47 -49 -48 -12 -3 -133 -139 -133 -149 0 -5 -5 -6 -10 -3 -6 3 -10 1 -10 -6 0 -6 -36 -59 -80 -117 -44 -58 -80 -111 -80 -119 0 -7 -4 -13 -9 -13 -5 0 -12 -11 -15 -24 -3 -14 -12 -31 -19 -38 -6 -7 -17 -24 -24 -38 -6 -14 -30 -64 -52 -111 -23 -48 -41 -93 -41 -101 0 -8 -4 -18 -9 -23 -4 -6 -14 -32 -20 -60 -7 -27 -21 -72 -31 -100 -17 -43 -27 -94 -55 -255 -17 -100 -27 -293 -22 -435 6 -160 38 -417 56 -439 7 -9 17 -42 26 -86 11 -56 30 -120 41 -137 8 -12 14 -31 14 -41 0 -10 4 -22 8 -28 5 -5 17 -29 26 -54 36 -92 154 -293 216 -367 5 -7 10 -16 10 -22 0 -5 7 -11 15 -15 8 -3 15 -12 15 -20 0 -9 38 -54 85 -101 47 -47 85 -90 85 -96 0 -5 4 -9 9 -9 5 0 16 -6 23 -13 7 -6 38 -32 67 -57 30 -25 65 -54 77 -65 49 -43 92 -75 102 -75 5 0 15 -7 22 -15 7 -9 15 -13 18 -11 3 3 18 -4 34 -15 36 -26 190 -103 201 -101 4 1 7 -3 7 -8 0 -6 9 -10 19 -10 11 0 21 -4 23 -8 2 -6 140 -56 183 -67 6 -1 23 -7 38 -13 15 -7 51 -16 80 -21 29 -6 72 -14 97 -19 25 -6 68 -13 95 -16 28 -4 82 -11 120 -17 46 -7 343 -9 855 -7 725 3 787 4 815 20 17 10 37 18 46 18 20 0 95 36 119 58 11 9 32 28 47 42 15 14 31 24 35 23 5 -2 8 3 8 11 0 7 11 24 23 37 51 52 100 169 108 254 2 28 4 399 4 825 0 774 0 775 -23 858 -32 115 -48 143 -140 238 -63 65 -171 122 -272 143 -37 8 -1228 5 -1278 -3 -23 -4 -61 -14 -84 -22 -47 -16 -154 -86 -181 -118 -10 -11 -15 -15 -11 -7 5 9 3 12 -4 7 -7 -4 -12 -13 -12 -21 0 -7 -6 -20 -13 -27 -7 -7 -27 -37 -45 -66 -58 -94 -77 -226 -52 -362 10 -55 38 -144 40 -125 0 6 7 -3 15 -20 7 -16 27 -45 44 -64 17 -18 31 -37 31 -40 0 -4 15 -15 33 -26 17 -10 37 -23 42 -27 100 -81 181 -96 545 -97 266 -2 296 -3 308 -19 18 -24 13 -435 -6 -454 -9 -9 -112 -12 -460 -10 -246 1 -472 6 -502 11 -30 5 -58 7 -62 4 -5 -2 -8 -1 -8 4 0 4 -13 9 -30 10 -16 1 -51 11 -77 22 -26 10 -63 25 -82 32 -18 7 -49 23 -68 36 -19 13 -38 21 -43 18 -4 -3 -10 -2 -12 3 -1 4 -25 23 -53 42 -60 42 -181 163 -201 202 -8 15 -19 28 -23 28 -5 0 -12 13 -16 30 -4 16 -11 30 -16 30 -5 0 -9 6 -9 14 0 8 -3 16 -7 18 -13 5 -43 68 -43 88 0 10 -4 20 -9 22 -22 7 -70 238 -76 366 -9 172 11 297 68 432 5 14 12 36 14 49 2 13 11 30 19 38 7 8 14 23 14 34 0 11 5 17 10 14 6 -3 10 1 10 9 0 8 6 21 13 28 8 7 26 32 40 55 14 23 49 65 76 95 28 29 51 56 51 61 0 4 4 7 10 7 10 0 38 21 76 58 13 13 28 21 33 18 4 -3 16 3 26 14 10 11 24 20 32 20 7 0 13 5 13 11 0 6 7 9 15 6 8 -4 17 -2 20 3 4 6 15 10 26 10 10 0 19 4 19 8 0 8 81 37 165 58 74 20 230 24 910 27 704 2 775 4 823 20 94 32 208 99 218 130 3 9 12 17 20 17 8 0 14 4 14 8 0 5 8 17 18 28 36 42 70 110 88 177 26 100 8 307 -32 358 -6 8 -17 29 -25 47 -8 17 -17 32 -21 32 -5 0 -8 4 -8 9 0 11 -77 91 -88 91 -4 0 -19 11 -34 25 -15 14 -29 25 -30 26 -19 0 -48 14 -48 22 0 6 -3 8 -6 4 -3 -3 -27 4 -52 16 -47 22 -50 22 -842 25 -438 2 -798 1 -801 -2z" />
              </g>
          </svg>
      </div>

      <!-- Main Content Transition (Chat vs Default) -->
      <Transition name="header-fade" 
        @before-leave="onBeforeTransition" 
        @leave="onStartTransition" 
        @after-leave="onAfterTransition"
        @before-enter="onBeforeTransition" 
        @enter="onStartTransition" 
        @after-enter="onAfterTransition"
      >
          <!-- Chat Mode -->
          <div v-if="state.mode === 'chat'" class="header-chat-info" id="header-chat-info" key="chat">
              <template v-if="state.isChatSearchMode">
                  <div class="chat-search-wrapper">
                      <div class="chat-search-back" @click="handleBack">
                          <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>
                      </div>
                      <input type="text" v-model="state.searchQuery" class="chat-search-input" :placeholder="t('search_messages') || 'Search messages'">
                      <div v-if="state.searchQuery" class="chat-search-clear" @click="state.searchQuery = ''">
                          <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                      </div>
                  </div>
              </template>
              <template v-else>
                  <div class="header-avatar">
                      <img v-if="state.chat.avatar" id="chat-header-avatar" :src="state.chat.avatar" alt="" @click.stop="handleAvatarClick">
                      <div v-else id="chat-header-avatar-placeholder" class="avatar-placeholder" :style="{ backgroundColor: state.chat.color || '#ccc' }">
                          {{ state.chat.initial }}
                      </div>
                  </div>
                  <div style="display: flex; flex-direction: column; justify-content: center; margin-left: 10px;">
                      <div style="display: flex; align-items: center;">
                          <div class="header-name" id="chat-header-name" style="line-height: 1.2;">{{ state.chat.name }}</div>
                      </div>
                      <div id="chat-header-session" style="color: var(--text-gray); font-size: 0.8em; line-height: 1.2;">{{ state.chat.session }}</div>
                  </div>
              </template>
          </div>

          <!-- Default Mode (Title + Bottom Content) -->
          <div v-else class="header-default-group" key="default">
              <!-- Center Content (Title) -->
              <div class="header-content" id="header-content-default">
                  <Transition name="title-fade">
                      <span :key="state.title" id="header-title">{{ state.title }}</span>
                  </Transition>
              </div>

              <!-- Dynamic Bottom Content (Tabs, Search, Persona) -->
              <Transition name="header-fade" 
                @before-leave="onBeforeTransition" 
                @leave="onStartTransition" 
                @after-leave="onAfterTransition"
                @before-enter="onBeforeTransition" 
                @enter="onStartTransition" 
                @after-enter="onAfterTransition"
              >
                  <!-- Generation Sub-tabs -->
                  <div v-if="state.mode === 'generation'" class="header-sub-tabs" key="tabs">
                      <div class="segmented-control">
                          <div class="sub-tab-btn" :class="{ active: state.generationTab === 'subview-api' }" @click="handleGenTabClick('subview-api')">{{ state.tabApiLabel }}</div>
                          <div class="sub-tab-btn" :class="{ active: state.generationTab === 'subview-preset' }" @click="handleGenTabClick('subview-preset')">{{ state.tabPresetLabel }}</div>
                      </div>
                  </div>

                  <!-- Built-in Search Bar -->
                  <div v-else-if="state.showSearch" class="search-bar" key="search">
                      <div class="search-field-wrapper">
                          <Transition name="fade-slide">
                              <input :key="state.searchPlaceholder" type="text" v-model="state.searchQuery" :placeholder="state.searchPlaceholder">
                          </Transition>
                      </div>
                  </div>

                  <!-- Empty placeholder to prevent comment node insertion errors during nested transitions -->
                  <div v-else key="empty" style="display: none;"></div>
              </Transition>
          </div>
      </Transition>

      <!-- Right Actions + Notification Bell -->
      <div v-if="!state.isChatSearchMode" id="header-actions" class="header-btn-right" @click.stop>
          <div v-if="state.showActions" v-for="(action, idx) in state.actions" :key="idx" class="header-action-btn" :id="action.id" @click.stop="action.onClick" :style="{ color: action.color }">
              <span v-html="action.icon" style="display: flex; fill: currentColor;"></span>
          </div>
          <!-- <div class="header-action-btn notif-btn" @click.stop="openNotifications">
              <svg viewBox="0 0 24 24" fill="currentColor" style="width:22px;height:22px;"><path d="M12 22c1.1 0 2-.9 2-2h-4c0 1.1.9 2 2 2zm6-6v-5c0-3.07-1.64-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.63 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2z"/></svg>
              <span v-if="notificationsState.unreadCount > 0" class="notif-badge"></span>
          </div> -->
      </div>

      <!-- Lorebook Banner (Glassmorphism) -->
      <Transition name="lb-banner-fade" 
        @before-enter="onBannerBeforeEnter" @enter="onBannerEnter" @after-enter="onBannerAfterEnter"
        @before-leave="onBannerBeforeLeave" @leave="onBannerLeave" @after-leave="onBannerAfterLeave"
      >
          <div v-if="state.lorebookBanner.show" class="header-lb-banner">
              <div class="lb-banner-glass">
                  <div class="lb-banner-text">
                      <span v-if="state.lorebookBanner.presetName" class="lb-label-group">
                          <svg viewBox="0 0 24 24" class="lb-banner-icon"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                          <span class="lb-banner-label">{{ t('subtab_preset') }}:</span>
                          <span class="lb-banner-names">{{ state.lorebookBanner.presetName }}</span>
                      </span>
                      <span v-if="state.lorebookBanner.names.length > 0" class="lb-label-group">
                          <svg viewBox="0 0 24 24" class="lb-banner-icon"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
                          <span class="lb-banner-label">{{ t('label_lorebooks') }}:</span>
                          <span class="lb-banner-names">{{ state.lorebookBanner.names.join(', ') }}</span>
                      </span>
                      <span v-if="state.lorebookBanner.personaName" class="lb-label-group">
                          <svg viewBox="0 0 24 24" class="lb-banner-icon"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm0 14.2c-2.5 0-4.71-1.28-6-3.22.03-1.99 4-3.08 6-3.08 1.99 0 5.97 1.09 6 3.08-1.29 1.94-3.5 3.22-6 3.22z"/></svg>
                          <span class="lb-banner-label">{{ t('tab_personas') }}:</span>
                          <span class="lb-banner-names">{{ state.lorebookBanner.personaName }}</span>
                      </span>
                  </div>
              </div>
          </div>
      </Transition>
  </header>
</template>

<style>
/* Header */
.app-header {
    min-height: 56px;
    height: auto;
    padding-top: 0;
    background-color: rgba(30, 30, 30, var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px)) ;
    -webkit-backdrop-filter: blur(var(--element-blur, 12px)) ;
    background-image: url("data:image/svg+xml,%3Csvg width='200' height='200' viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)' opacity='0.03'/%3E%3C/svg%3E");
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--border-color, rgba(255, 255, 255, 0.1));
    border-radius: 20px;
    margin: 10px 16px 0 16px;
    margin-top: calc(var(--sat) + 10px);
    position: relative;
    width: auto;
    z-index: 100;
    flex-shrink: 0;
    transition: background-color var(--transition-speed) ease, margin-top var(--transition-speed) ease, transform var(--transition-speed) ease-in-out, height var(--transition-speed) ease, clip-path var(--transition-speed) ease-in-out !important;
    box-sizing: border-box;
    clip-path: inset(0 0 0 0);
}

.app-header.no-border {
    border-bottom: none;
}

.app-header.header-transparent {
    background-color: transparent;
    box-shadow: none;
    border-bottom: none;
}

/* Mode: Wrapped (Generation, More) */
.app-header.header-wrap {
    flex-wrap: wrap;
    padding-bottom: 0;
}

.app-header.header-overlay {
    z-index: 10002;
}

.header-btn-left {
    position: absolute;
    left: 10px;
    top: 13px;
    width: 30px;
    height: 30px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    fill: var(--vk-blue);
    transition: fill var(--transition-speed) ease;
    z-index: 2;
}

.header-logo {
    position: absolute;
    left: 12px;
    top: 12px;
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    fill: var(--vk-blue);
    transition: fill var(--transition-speed) ease;
    z-index: 2;
}

.header-btn-right {
    position: absolute;
    right: 10px;
    top: 9px;
    display: flex;
    align-items: center;
    gap: 2px;
    color: var(--vk-blue);
    fill: currentColor;
    transition: color var(--transition-speed) ease;
    z-index: 10;
}

.header-action-btn {
    width: 38px;
    height: 38px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
}

.notif-btn {
    position: relative;
}

.notif-badge {
    position: absolute;
    top: 7px;
    right: 7px;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #ff4444;
    border: 1.5px solid rgba(30, 30, 30, 0.8);
    pointer-events: none;
}

.header-default-group {
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
}

.header-chat-info {
    display: flex;
    align-items: center;
    font-size: 16px;
    font-weight: 500;
    height: 56px;
    width: 100%;
    justify-content: center;
}

.header-avatar {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    overflow: hidden;
}

.header-avatar img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.header-content {
    font-weight: 500;
    font-size: 18px;
    display: flex;
    align-items: center;
    cursor: pointer;
    position: relative;
    justify-content: center;
    height: 56px;
    transition: width var(--transition-speed) ease;
    z-index: 5;
    background-color: transparent;
}

/* When wrapped, title takes full width to force break to new line for custom content */
.app-header.header-wrap .header-content {
    width: 100%;
}


#header-title {
    display: block;
    text-align: center;
}

#header-title.fade-out {
    opacity: 0;
}

/* Search Bar */
.search-bar {
    display: flex;
    padding: 0 16px 12px 16px;
    background-color: transparent;
    width: 100%;
    box-sizing: border-box;
    order: 10;
    flex-basis: 100%;
    overflow: hidden;
}

.search-field-wrapper {
    width: 100%;
    height: 32px;
    background-color: transparent;
    border-radius: 10px;
    position: relative;
    overflow: hidden;
}

.search-bar input {
    width: 100%;
    height: 100%;
    padding: 0 16px;
    border: none;
    background-color: var(--bg-gray);
    font-size: 16px;
    outline: none;
    color: var(--text-black);
    text-align: center;
    position: absolute;
    top: 0;
    left: 0;
}

/* Header Sub-tabs */
.header-sub-tabs {
    width: 100%;
    padding: 0 16px 12px 16px;
    order: 10;
    flex-basis: 100%;
    box-sizing: border-box;
    position: relative;
    z-index: 1;
}

.item-subtitle {
    font-size: 13px;
    color: var(--text-gray);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* Header Fade Transition */
.header-fade-enter-active,
.header-fade-leave-active {
    transition: opacity var(--transition-speed) ease;
}
.header-fade-enter-from,
.header-fade-leave-to {
    opacity: 0;
}
.header-fade-leave-active {
    position: absolute;
    bottom: 0;
    left: 0;
    width: 100%;
}

/* Lorebook Banner Glassmorphism */
.header-lb-banner {
    width: 100%;
    padding: 0 12px 12px;
    order: 20;
    flex-basis: 100%;
    box-sizing: border-box;
    overflow: hidden;
}

.lb-banner-glass {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    background: rgba(var(--vk-blue-rgb), 0.15);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid rgba(var(--vk-blue-rgb), 0.3);
    border-radius: 12px;
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.05);
}

.lb-banner-text {
    font-size: 13px;
    font-weight: 500;
    color: var(--vk-blue);
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: flex-start;
    overflow: hidden;
    min-width: 0;
    line-height: 1.2;
}

.lb-label-group {
    display: flex;
    align-items: center;
    width: 100%;
    min-width: 0;
}

.lb-banner-icon {
    width: 14px;
    height: 14px;
    fill: var(--vk-blue);
    flex-shrink: 0;
    margin-right: 6px;
    opacity: 0.8;
}

.lb-banner-label {
    opacity: 0.6;
    margin-right: 4px;
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    white-space: nowrap;
    flex-shrink: 0;
}

.lb-banner-names {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.lb-banner-fade-enter-active, .lb-banner-fade-leave-active {
    transition: all 0.4s cubic-bezier(0.16, 1, 0.3, 1);
}

.lb-banner-fade-enter-from, .lb-banner-fade-leave-to {
    opacity: 0;
    transform: translateY(-10px);
}

/* Chat Search Header */
.chat-search-wrapper {
    flex: 1;
    display: flex;
    align-items: center;
    position: relative;
    margin: 0 16px;
    height: 36px;
    background-color: var(--bg-gray);
    border-radius: 12px;
}
.chat-search-input {
    flex: 1;
    height: 100%;
    padding: 0 32px;
    border: none;
    background: transparent;
    font-size: 16px;
    outline: none;
    color: var(--text-black);
    text-align: center;
}
.chat-search-back {
    position: absolute;
    left: 8px;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    fill: #888;
    cursor: pointer;
    z-index: 5;
}
.chat-search-clear {
    position: absolute;
    right: 8px;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    fill: #888;
    cursor: pointer;
    z-index: 5;
}
</style>