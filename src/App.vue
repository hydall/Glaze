<script setup>
import { ref, reactive, onMounted, nextTick, computed, watch, onBeforeUnmount, defineAsyncComponent } from 'vue';
import AppHeader from '@/components/layout/AppHeader.vue';
import BottomNavigation from '@/components/layout/BottomNavigation.vue';
import DialogList from '@/views/DialogList.vue';
import BottomSheet from '@/components/ui/BottomSheet.vue';
import FabButton from '@/components/ui/FabButton.vue';

const CharacterList = defineAsyncComponent(() => import('@/views/CharacterList.vue'));
const MenuView = defineAsyncComponent(() => import('@/views/Menu/MenuView.vue'));
const PresetView = defineAsyncComponent(() => import('@/views/PresetView.vue'));
const ChatView = defineAsyncComponent(() => import('@/views/ChatView.vue'));
const ThemeSettingsView = defineAsyncComponent(() => import('@/views/Menu/Settings/ThemeSettingsView.vue'));
const SettingsView = defineAsyncComponent(() => import('@/views/Menu/Settings/SettingsView.vue'));
const OnboardingView = defineAsyncComponent(() => import('@/views/OnboardingView.vue'));

const Editor = defineAsyncComponent(() => import('@/components/editors/GenericEditor.vue'));
const FullScreenEditor = defineAsyncComponent(() => import('@/components/editors/FullScreenEditor.vue'));

const HoloCardViewer = defineAsyncComponent(() => import('@/components/media/HoloCardViewer.vue'));
const ImageViewer = defineAsyncComponent(() => import('@/components/media/ImageViewer.vue'));
import AppToast from '@/components/ui/AppToast.vue';

const ConnectionsSheet = defineAsyncComponent(() => import('@/components/sheets/ConnectionsSheet.vue'));
const LorebookSheet = defineAsyncComponent(() => import('@/components/sheets/LorebookSheet.vue'));
const BackupSheet = defineAsyncComponent(() => import('@/components/sheets/BackupSheet.vue'));
const NotificationsSheet = defineAsyncComponent(() => import('@/components/sheets/NotificationsSheet.vue'));
const GlossaryView = defineAsyncComponent(() => import('@/components/sheets/GlossarySheet.vue'));
import { Capacitor } from '@capacitor/core';
import { isKeyboardOpen, onKeyboardShow, onKeyboardHide } from '@/core/services/keyboardHandler.js';
import { initSettings } from '@/core/config/APISettings.js';
import { initTheme, themeState } from '@/core/states/themeState.js';
import { updateLanguage } from '@/utils/i18n.js';
import { currentLang, imageViewerMode } from '@/core/config/APPSettings.js';
import { initRipple, initThemeToggle, initHeaderDropdown, initBackButton, initViewportFix } from '@/core/services/ui.js';
import { bottomSheetState, closeBottomSheet, showBottomSheet } from '@/core/states/bottomSheetState.js';
import { db, migrateScToGz } from '@/utils/db.js';
import { translations } from '@/utils/i18n.js';
import { addPersona, updatePersona, deletePersona, allPersonas, loadPersonas } from '@/core/states/personaState.js';
import { checkAndRequestNotifications, consumePendingNotificationData } from '@/core/services/notificationService.js';
import { logger } from './utils/logger.js';
import { generateMissingThumbnails } from '@/utils/characterIO.js';
import { initLorebookState } from '@/core/states/lorebookState.js';
import { initPresetState } from '@/core/states/presetState.js';
import { startTracking } from '@/core/services/timeTracker.js';

const t = (key) => translations[currentLang.value]?.[key] || key;
// Initialize error handling

// --- Navigation state ---
const currentView = ref('view-dialogs');
const headerRef = ref(null); // Reference to the AppHeader component
const headerContainer = ref(null);
const footerContainer = ref(null);
const isChatInitialized = ref(false); // Whether the chat has been initialized
const isDataLoaded = ref(false);
const dialogListRef = ref(null);
const characterListRef = ref(null);
const chatViewRef = ref(null);
const connectionsSheetRef = ref(null);
const lorebookSheetRef = ref(null);
const backupSheetRef = ref(null);
const presetViewRef = ref(null);

const isHeaderEditorMode = ref(false);

const waitForComponent = (refVar, callback) => {
    if (refVar.value) {
        callback(refVar.value);
    } else {
        const unwatch = watch(refVar, (val) => {
            if (val) {
                callback(val);
                unwatch();
            }
        });
    }
};

// --- Editor State ---
const editingCharacter = ref(null);
const editingCharacterIndex = ref(-1);
const editingPersona = ref(null);
const editingPersonaIndex = ref(-1);
const previousViewForEditor = ref(null);
const previousSessionIdForEditor = ref(null);
const currentChatSessionId = ref(null);
const activeChatCharObj = ref(null);
const chatPreviousView = ref(null);
const shouldOpenPersonasOnReturn = ref(false);

const isDeleting = ref(false); // Guard flag to prevent auto-save during deletion
const isOnboarding = ref(false);
let kbListeners = [];

// --- Categories ---
const activeCategories = reactive({
    'view-dialogs': 'all',
    'view-characters': 'all'
});

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

const isEditorView = computed(() => currentView.value === 'view-character-edit' || currentView.value === 'view-persona-edit');

const headerZIndex = computed(() => {
    if (fsEditorVisible.value) return 2001;
    if (isEditorView.value) return 1100;
    return 100;
});

const mainZIndex = computed(() => {
    if (isEditorView.value) return 1000;
    return 1;
});

function openChatWrapper(char) {
    currentChatSessionId.value = char.sessionId || null;
    activeChatCharObj.value = char;
    const previousView = currentView.value;
    chatPreviousView.value = previousView;
    currentView.value = 'view-chat';
    isChatInitialized.value = true;
    
    waitForComponent(chatViewRef, (comp) => {
        comp.openChat(char, () => {
            currentView.value = previousView;
            // DialogList updates automatically via events
        });
    });
}

function onLanguageChanged() {
    if (headerRef.value) headerRef.value.updateHeader();
}

// --- Editor Logic ---
async function openCharacterEditor(index) {
    previousViewForEditor.value = currentView.value;
    if (currentView.value === 'view-chat') {
        previousSessionIdForEditor.value = currentChatSessionId.value;
    } else {
        previousSessionIdForEditor.value = null;
    }
    isDeleting.value = false;
    editingCharacterIndex.value = index;
    if (index === -1) {
        editingCharacter.value = null; // New character
    } else {
        const chars = (await db.getAll('characters')) || [];
        editingCharacter.value = chars[index];
    }
    currentView.value = 'view-character-edit';
}

async function handleHeaderSave() {
    if (currentView.value === 'view-character-edit') {
        if (editingCharacter.value && editingCharacter.value.name && editingCharacter.value.name.trim() !== '') {
            await db.saveCharacter(editingCharacter.value, editingCharacterIndex.value);
            closeEditor();
        } else {
            showBottomSheet({
                title: t('title_error') || 'Error',
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                    description: t('error_name_required') || 'Name is required.',
                    buttonText: t('btn_ok') || 'OK',
                    onButtonClick: closeBottomSheet
                }
            });
        }
    } else if (currentView.value === 'view-persona-edit') {
        if (editingPersona.value && editingPersona.value.name && editingPersona.value.name.trim() !== '') {
            if (editingPersonaIndex.value === -1) {
                await addPersona(editingPersona.value);
            } else {
                await updatePersona(editingPersonaIndex.value, editingPersona.value);
            }
            closeEditor();
        } else {
            showBottomSheet({
                title: t('title_error') || 'Error',
                bigInfo: {
                    icon: '<svg viewBox="0 0 24 24" style="fill:#ff4444;width:100%;height:100%;"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>',
                    description: t('error_name_required') || 'Name is required.',
                    buttonText: t('btn_ok') || 'OK',
                    onButtonClick: closeBottomSheet
                }
            });
        }
    }
}

async function handleEditorAutoSave(val) {
    // CRITICAL: Do not save if we are in the process of deleting
    if (isDeleting.value) return;

    if (currentView.value === 'view-character-edit') {
        if (!val || !val.name || val.name.trim() === '') return; // Don't auto-save character without name

        if (editingCharacterIndex.value === -1) {
            // Create new character
            await db.saveCharacter(val, -1);
            // Retrieve new index (assuming added to end) to prevent duplicates on next save
            const chars = (await db.getAll('characters')) || [];
            editingCharacterIndex.value = chars.length - 1;
        } else {
            await db.saveCharacter(val, editingCharacterIndex.value);
        }
    } else if (currentView.value === 'view-persona-edit') {
        if (!val.name) return; // Don't save empty personas on exit

        if (editingPersonaIndex.value === -1) {
            // Create new persona
            const newPersona = await addPersona(val);
            // Update index to point to the new persona (last one)
            editingPersonaIndex.value = allPersonas.value.length - 1;
            // Update the editing object to include the generated ID to prevent duplicates on next save
            editingPersona.value = JSON.parse(JSON.stringify(newPersona));
        } else {
            await updatePersona(editingPersonaIndex.value, val);
        }
    }
}

async function handleHeaderDelete() {
    const isPersona = currentView.value === 'view-persona-edit';
    const title = isPersona ? (t('confirm_delete_persona') || 'Delete persona?') : (t('confirm_delete_title') || 'Delete character?');

    showBottomSheet({
        title: title,
        items: [
            {
                label: t('btn_delete') || 'Delete',
                icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    isDeleting.value = true; // Set flag BEFORE deletion
                    try {
                        if (isPersona) {
                            await deletePersona(editingPersonaIndex.value);
                        } else {
                            const char = editingCharacter.value;
                            if (char && char.id && db.deleteCharacter) {
                                await db.deleteCharacter(char.id);
                            } else {
                                console.error('[App] Character ID is missing or db.deleteCharacter not found');
                            }
                        }
                    } catch (e) {
                        console.error('[App] Error deleting item:', e);
                    }
                    closeBottomSheet();
                    
                    if (isPersona) {
                        currentView.value = 'view-menu';
                    } else {
                        currentView.value = 'view-characters';
                    }
                    previousViewForEditor.value = null;
                    // isDeleting remains true until the view changes and editor unmounts, 
                    // effectively blocking the 'save' emit on unmount.
                }
            },
            {
                label: t('btn_cancel') || 'Cancel',
                icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: closeBottomSheet
            }
        ]
    });
}

async function closeEditor() {
    const prev = previousViewForEditor.value;
    previousViewForEditor.value = null;
    const prevSessionId = previousSessionIdForEditor.value;
    previousSessionIdForEditor.value = null;

    if (prev === 'view-chat') {
        const isEditingChar = currentView.value === 'view-character-edit';
        currentView.value = 'view-chat';
        
        waitForComponent(chatViewRef, async (comp) => {
            if (activeChatCharObj.value) {
                // If we were editing character, update the active object
                if (isEditingChar && editingCharacter.value) {
                    activeChatCharObj.value = { ...editingCharacter.value };
                }

                if (prevSessionId) {
                    activeChatCharObj.value.sessionId = prevSessionId;
                }

                comp.openChat(activeChatCharObj.value, () => {
                    currentView.value = chatPreviousView.value || 'view-dialogs';
                });

                if (shouldOpenPersonasOnReturn.value) {
                    shouldOpenPersonasOnReturn.value = false;
                    await nextTick();
                    if (typeof comp.openPersonas === 'function') {
                        comp.openPersonas();
                    }
                }
            }
        });
    } else if (prev) {
        currentView.value = prev;
    } else {
        // Fallback if previousView was not set
        if (currentView.value === 'view-persona-edit') {
            currentView.value = 'view-menu';
        } else {
            currentView.value = 'view-characters';
        }
    }
}

function finishOnboarding() {
    localStorage.setItem('glaze_onboarding_completed', 'true');
    isOnboarding.value = false;
}

// Full Screen Editor Logic
const fsEditorVisible = ref(false);
const fsEditorValue = ref("");
let fsEditorCallback = null;

function openFsEditor({ value, onSave }) {
    fsEditorValue.value = value;
    fsEditorCallback = onSave;
    fsEditorVisible.value = true;
}

function closeAndSaveFsEditor() {
    if (fsEditorCallback) fsEditorCallback(fsEditorValue.value);
    fsEditorVisible.value = false;
}

function autoSaveFsEditor(val) {
    if (fsEditorCallback) fsEditorCallback(val);
}

const mainStyle = computed(() => {
    if (!themeState.hasBackgroundImage) return {};
    return {
        backgroundImage: 'url("data:image/svg+xml,%3Csvg width=\'200\' height=\'200\' viewBox=\'0 0 200 200\' xmlns=\'http://www.w3.org/2000/svg\'%3E%3Cfilter id=\'noiseFilter\'%3E%3CfeTurbulence type=\'fractalNoise\' baseFrequency=\'0.8\' numOctaves=\'3\' stitchTiles=\'stitch\'/%3E%3C/filter%3E%3Crect width=\'100%25\' height=\'100%25\' filter=\'url(%23noiseFilter)\' opacity=\'0.05\'/%3E%3C/svg%3E")',
        backgroundRepeat: 'repeat',
        backgroundPosition: '0 0',
        backgroundSize: '200px 200px'
    };
});

watch(fsEditorVisible, (val) => {
    if (val) {
        window.dispatchEvent(new CustomEvent('header-setup-editor', {
            detail: {
                title: translations[currentLang.value]?.header_editor || 'Editor',
                onBack: () => { fsEditorVisible.value = false; },
                actions: [{
                    icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                    onClick: closeAndSaveFsEditor
                }]
            }
        }));
    } else {
        if (headerRef.value) headerRef.value.updateHeader();
        window.dispatchEvent(new CustomEvent('fs-editor-closed'));
    }
});

// --- Character Editor Config ---
const characterEditorConfig = [
    {
        title: 'section_basic_info',
        fields: [
            { key: 'name', label: 'label_name', type: 'text' },
            { key: 'description', label: 'label_description', type: 'textarea', rows: 3, expandable: true },
            { key: 'creator_notes', label: 'label_creator_notes', type: 'textarea', rows: 2 },
            { key: 'tags', label: 'label_tags', type: 'tags' }
        ]
    },
    {
        title: 'section_personality',
        fields: [
            { key: 'personality', label: 'label_personality', type: 'textarea', rows: 4, expandable: true },
            { key: 'scenario', label: 'label_scenario', type: 'textarea', rows: 3, expandable: true }
        ]
    },
    {
        title: 'section_dialogue',
        fields: [
            { key: 'first_mes', label: 'label_first_mes', type: 'greeting_list', rows: 4 },
            { key: 'mes_example', label: 'label_mes_example', type: 'textarea', rows: 6, expandable: true }
        ]
    }
];

const personaEditorConfig = [
    {
        title: 'section_basic_info',
        fields: [
            { key: 'name', label: 'label_name', type: 'text' },
            { key: 'prompt', label: 'label_description', type: 'textarea', rows: 4, expandable: true }
        ]
    }
];

// --- FAB Logic ---
const fabConfig = computed(() => {
    if (currentView.value === 'view-dialogs') {
        return {
            text: translations[currentLang.value]?.btn_new_chat || 'New Chat',
            action: () => dialogListRef.value?.openNewChatPicker()
        };
    } else if (currentView.value === 'view-characters') {
        return {
            text: translations[currentLang.value]?.btn_add || 'Add',
            action: () => characterListRef.value?.onAddCharacter()
        };
    }
    return null;
});

const headerEditingIndex = computed(() => {
    if (currentView.value === 'view-character-edit') return editingCharacterIndex.value;
    if (currentView.value === 'view-persona-edit') return editingPersonaIndex.value;
    return -1;
});

const showLogo = computed(() => {
    return !['view-chat', 'view-character-edit', 'view-persona-edit', 'view-theme-settings', 'view-settings'].includes(currentView.value) && !isHeaderEditorMode.value;
});

const updateLayoutMetrics = () => {
    if (headerContainer.value) {
        document.documentElement.style.setProperty('--header-height', `${headerContainer.value.offsetHeight}px`);
    }
    if (footerContainer.value) {
        document.documentElement.style.setProperty('--footer-height', `${footerContainer.value.offsetHeight}px`);
    }
};

let layoutObserver = null;

const onOpenCharacterEditor = (e) => { openCharacterEditor(e.detail.index); };

const onOpenPersonaEditor = (e) => {
    previousViewForEditor.value = currentView.value;
    if (currentView.value === 'view-chat') {
        shouldOpenPersonasOnReturn.value = true;
    }
    isDeleting.value = false;
    editingPersonaIndex.value = e.detail.index;
    editingPersona.value = e.detail.persona ? JSON.parse(JSON.stringify(e.detail.persona)) : { name: '', description: '', avatar: '' };
    currentView.value = 'view-persona-edit';
};

const onNavigateTo = (e) => { currentView.value = e.detail; };

const onOpenOnboarding = () => { isOnboarding.value = true; };

const onTriggerOpenImage = (e) => {
    const { src, name, description, onCloseCallback } = e.detail;
    logger.debug('[App] trigger-open-image. Current Mode:', imageViewerMode.value);
    if (imageViewerMode.value === 'holo' || imageViewerMode.value === 'holocards') {
        window.dispatchEvent(new CustomEvent('open-holocards', {
            detail: { src, name, description, onCloseCallback }
        }));
    } else {
        logger.debug('[App] Dispatching open-image-viewer');
        window.dispatchEvent(new CustomEvent('open-image-viewer', {
            detail: { src, description, onCloseCallback }
        }));
    }
};

const onOpenFsRequest = (e) => { openFsEditor(e.detail); };

const onOpenConnections = (e) => {
    const { type, id, name } = e.detail || {};
    waitForComponent(connectionsSheetRef, (comp) => {
        comp.open(type, id, name, activeChatCharObj.value);
    });
};

const onOpenItemEditor = (e) => {
    const { type, id } = e.detail;
    if (type === 'lorebook') {
        waitForComponent(lorebookSheetRef, (comp) => {
            comp.openLorebook(id);
        });
    } else if (type === 'preset') {
        waitForComponent(presetViewRef, (comp) => {
            comp.openPreset(id);
        });
    } else if (type === 'persona') {
        const index = allPersonas.value.findIndex(p => p.id === id);
        if (index !== -1) {
            const persona = allPersonas.value[index];
            window.dispatchEvent(new CustomEvent('open-persona-editor', { detail: { index, persona } }));
        }
    }
};

const onOpenLorebookEntry = (e) => {
    const { lorebookId, entryId } = e.detail;
    if (currentView.value === 'view-chat') {
        waitForComponent(chatViewRef, (comp) => {
            comp.openLorebookEntry(lorebookId, entryId);
        });
    }
};

const onOpenBackupSheet = () => {
    waitForComponent(backupSheetRef, (comp) => {
        comp.open();
    });
};

const onHeaderSetupEditor = () => { isHeaderEditorMode.value = true; };
const onHeaderSetupGeneration = () => { isHeaderEditorMode.value = false; };
const onHeaderReset = () => { isHeaderEditorMode.value = false; };

const handleOpenChatEvent = async (e) => {
    logger.debug("[App] Received open-chat event:", e.detail);
    const data = e.detail;
    // Handle both object (new) and string (legacy/fallback) formats
    const charId = typeof data === 'object' ? data.charId : data;
    const sessionId = typeof data === 'object' ? data.sessionId : null;
    const msgId = typeof data === 'object' ? data.msgId : null;

    if (!charId) return;

    const chars = await db.getAll('characters');
    const char = chars.find(c => c.id === charId);
    if (char) {
        if (sessionId) char.sessionId = sessionId;
        if (msgId) char.msgId = msgId;
        // Force back destination to dialogs — user may be on any view when tapping notification
        currentView.value = 'view-dialogs';
        openChatWrapper(char);
    }
};

onMounted(async () => {
    await migrateScToGz(); // One-time migration: sc_ -> gz_ storage keys

    isOnboarding.value = localStorage.getItem('glaze_onboarding_completed') !== 'true';

    initSettings();
    await initTheme();
    await Promise.all([
        initLorebookState(),
        initPresetState(),
        loadPersonas()
    ]);
    
    startTracking();
    
    initRipple();
    initThemeToggle();
    initViewportFix();
    initBackButton();
    
    initHeaderDropdown(categories, activeCategories, (viewId, itemId) => {
        // view-dialogs is handled reactively via props to DialogList component
        // view-characters is handled reactively via props to CharacterList component
    });

    
    // Listen for editor events
    window.addEventListener('open-character-editor', onOpenCharacterEditor);
    window.addEventListener('open-persona-editor', onOpenPersonaEditor);
    window.addEventListener('navigate-to', onNavigateTo);
    window.addEventListener('language-changed', onLanguageChanged);
    window.addEventListener('open-chat', handleOpenChatEvent);
    window.addEventListener('open-onboarding', onOpenOnboarding);

    const pendingData = consumePendingNotificationData();
    if (pendingData) {
        handleOpenChatEvent({ detail: pendingData });
    }

    window.addEventListener('trigger-open-image', onTriggerOpenImage);
    window.addEventListener('open-fs-request', onOpenFsRequest);
    window.addEventListener('open-connections', onOpenConnections);
    window.addEventListener('open-item-editor', onOpenItemEditor);
    window.addEventListener('open-lorebook-entry', onOpenLorebookEntry);
    window.addEventListener('open-backup-sheet', onOpenBackupSheet);
    window.addEventListener('header-setup-editor', onHeaderSetupEditor);
    window.addEventListener('header-setup-generation', onHeaderSetupGeneration);
    window.addEventListener('header-reset', onHeaderReset);

    // Initialize ResizeObserver for layout metrics
    layoutObserver = new ResizeObserver(() => {
        requestAnimationFrame(updateLayoutMetrics);
    });
    if (headerContainer.value) layoutObserver.observe(headerContainer.value);
    if (footerContainer.value) layoutObserver.observe(footerContainer.value);
    updateLayoutMetrics();

    updateLanguage();
    // AppHeader updates itself when it mounts
    isDataLoaded.value = true;
    
    // Asynchronously generate missing thumbnails without blocking UI
    generateMissingThumbnails();

    setTimeout(() => {
        document.body.classList.remove('preload');
        document.body.classList.add('app-loaded');
    }, 100);

    // Check and prompt to enable notifications on first run
    setTimeout(checkAndRequestNotifications, 1000);

    if (Capacitor.isNativePlatform()) {
        kbListeners.push(await onKeyboardShow(() => { isKeyboardOpen.value = true; }));
        kbListeners.push(await onKeyboardHide(() => { isKeyboardOpen.value = false; }));
    }
});

onBeforeUnmount(() => {
    if (layoutObserver) layoutObserver.disconnect();
    window.removeEventListener('open-character-editor', onOpenCharacterEditor);
    window.removeEventListener('open-persona-editor', onOpenPersonaEditor);
    window.removeEventListener('navigate-to', onNavigateTo);
    window.removeEventListener('language-changed', onLanguageChanged);
    window.removeEventListener('open-chat', handleOpenChatEvent);
    window.removeEventListener('open-onboarding', onOpenOnboarding);
    window.removeEventListener('trigger-open-image', onTriggerOpenImage);
    window.removeEventListener('open-fs-request', onOpenFsRequest);
    window.removeEventListener('open-connections', onOpenConnections);
    window.removeEventListener('open-item-editor', onOpenItemEditor);
    window.removeEventListener('open-lorebook-entry', onOpenLorebookEntry);
    window.removeEventListener('open-backup-sheet', onOpenBackupSheet);
    window.removeEventListener('header-setup-editor', onHeaderSetupEditor);
    window.removeEventListener('header-setup-generation', onHeaderSetupGeneration);
    window.removeEventListener('header-reset', onHeaderReset);
    kbListeners.forEach(l => l.remove());
});

watch(currentView, () => {
    isHeaderEditorMode.value = false;
});
</script>

<template>
  <div class="app-layout" :style="mainStyle">
    <!-- Onboarding Overlay -->
    <Transition name="fade">
        <OnboardingView v-if="isOnboarding" @finish="finishOnboarding" />
    </Transition>

    <!-- Header Component -->
    <div class="header-container" ref="headerContainer" :style="{ zIndex: headerZIndex }">
        <AppHeader 
            ref="headerRef" 
            :current-view="currentView" 
            :categories="categories"
            :editing-index="headerEditingIndex"
            @action-save="handleHeaderSave"
            @action-delete="handleHeaderDelete"
            @action-close="closeEditor"
        />
    </div>

    <!-- Main Content Area -->
    <main id="main-container" v-if="isDataLoaded" :style="{ zIndex: mainZIndex }" :class="{ 'keyboard-open': isKeyboardOpen && currentView !== 'view-chat', 'chat-view-main': currentView === 'view-chat' }">
      
      <Transition name="fade">
          <!-- VIEW 1: DIALOGS -->
          <div id="view-dialogs" class="view active-view" v-if="currentView === 'view-dialogs'">
              <DialogList 
                  ref="dialogListRef"
                  :active-category="activeCategories['view-dialogs']"
                  @open-chat="openChatWrapper"
              />
          </div>

          <!-- VIEW 2: CHARACTERS -->
          <div id="view-characters" class="view active-view" v-else-if="currentView === 'view-characters'">
              <CharacterList 
                  ref="characterListRef"
                  :active-category="activeCategories['view-characters']"
                  @open-chat="openChatWrapper"
              />
          </div>

          <!-- VIEW 3: MENU -->
          <MenuView
              class="view active-view view-gray-bg"
              v-else-if="currentView === 'view-menu'"
          />

          <!-- VIEW: GLOSSARY -->
          <GlossaryView
              class="view active-view view-gray-bg"
              v-else-if="currentView === 'view-glossary'"
              :view-mode="true"
          />

          <!-- VIEW: THEME SETTINGS -->
          <ThemeSettingsView 
              class="view active-view view-gray-bg"
              v-else-if="currentView === 'view-theme-settings'"
          />

          <!-- VIEW: SETTINGS -->
          <SettingsView 
              class="view active-view view-gray-bg"
              v-else-if="currentView === 'view-settings'"
          />

          <!-- VIEW 5: CHAT -->
          <ChatView class="view active-view" v-else-if="currentView === 'view-chat'" ref="chatViewRef" />

          <!-- VIEW 6: CHARACTER / PERSONA EDITOR -->
          <Editor 
              class="view active-view"
              v-else-if="currentView === 'view-character-edit' || currentView === 'view-persona-edit'"
              :model-value="currentView === 'view-character-edit' ? (editingCharacter || {}) : (editingPersona || {})"
              :config="currentView === 'view-character-edit' ? characterEditorConfig : personaEditorConfig"
              :show-avatar="true"
              @update:modelValue="(val) => currentView === 'view-character-edit' ? editingCharacter = val : editingPersona = val"
              @save="handleEditorAutoSave"
              @close="closeEditor"
              @open-fs="openFsEditor"
          />
      </Transition>
    </main>

    <!-- Floating Action Button -->
    <Transition name="fab">
        <FabButton v-if="fabConfig" :text="fabConfig.text" @click="fabConfig.action">
            <template #icon>
                <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
            </template>
        </FabButton>
    </Transition>

    <!-- Bottom Navigation Bar -->
    <div class="footer-container" ref="footerContainer">
        <BottomNavigation v-model:currentView="currentView" />
    </div>

    <!-- Global Bottom Sheet -->
    <BottomSheet
        :visible="bottomSheetState.visible"
        :locked="bottomSheetState.locked"
        :title="bottomSheetState.title"
        :help-tip="bottomSheetState.helpTip"
        :content="bottomSheetState.content"
        :items="bottomSheetState.items"
        :header-action="bottomSheetState.headerAction"
        :big-info="bottomSheetState.bigInfo"
        :session-items="bottomSheetState.sessionItems"
        :card-items="bottomSheetState.cardItems"
        :input="bottomSheetState.input"
        @close="closeBottomSheet"
    />

    <!-- Holo Cards Viewer -->
    <HoloCardViewer />

    <!-- Standard Image Viewer -->
    <ImageViewer />

    <!-- Toast -->
    <AppToast />
  </div>

  <!-- Full Screen Editor (Managed by App.vue now) -->
  <FullScreenEditor 
      :visible="fsEditorVisible"
      v-model="fsEditorValue"
      @save="autoSaveFsEditor"
      @close="fsEditorVisible = false"
  />

  <ConnectionsSheet ref="connectionsSheetRef" />
  <LorebookSheet ref="lorebookSheetRef" />
  <BackupSheet ref="backupSheetRef" />
  <PresetView ref="presetViewRef" />
  <NotificationsSheet />

</template>

<style>
.header-container {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    z-index: 100;
    pointer-events: none;
    display: flex;
    flex-direction: column;
}

.header-container > * {
    pointer-events: auto;
}

.footer-container {
    position: absolute;
    bottom: 0;
    left: 0;
    width: 100%;
    z-index: 100;
    pointer-events: none;
    display: flex;
    flex-direction: column;
}

.footer-container > * {
    pointer-events: auto;
}

#main-container {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    overflow-y: overlay;
    overflow-x: hidden;
    z-index: 1;
}

#main-container::-webkit-scrollbar-track {
    margin-top: calc(var(--header-height, 60px) + 12px);
    margin-bottom: calc(var(--footer-height, 80px) + 12px);
}

#main-container.chat-view-main {
    overflow-y: hidden;
}

#main-container.keyboard-open {
    padding-bottom: var(--keyboard-overlap, 300px) !important;
}

.active-view::-webkit-scrollbar-track {
    background-color: transparent;
}

.view {
    padding-top: calc(var(--header-height, 60px) + 16px) !important;
    padding-bottom: calc(var(--footer-height, 80px) + 20px) !important;
    box-sizing: border-box;
}

/* If a view contains a sub-view, delegate padding to the sub-view */
.view:has(.sub-view) {
    padding-top: 0;
    padding-bottom: 0;
}

.sub-view {
    padding-top: calc(var(--header-height, 60px) + 10px);
    padding-bottom: calc(var(--footer-height, 80px) + 20px);
    box-sizing: border-box;
}

/* ChatView handles its own layout/padding */

/* Global override for body to prevent WebView scrolling/panning */
body.no-scroll {
    position: fixed !important;
    width: 100% !important;
    height: 100% !important;
    overflow: hidden !important;
    overscroll-behavior: none !important;
    touch-action: none;
}

/* Re-enable touch for scrollable areas while body is locked */
body.no-scroll #chat-messages,
body.no-scroll .chat-input-editable,
body.no-scroll .edit-textarea,
body.no-scroll .magic-drawer,
body.no-scroll .bottom-sheet-content {
    touch-action: pan-y;
}
</style>