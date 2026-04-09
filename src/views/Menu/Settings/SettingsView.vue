<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue';
import { updateLanguage, translations } from '@/utils/i18n.js';
import { currentLang, setLanguage, imageViewerMode, setImageViewerMode, disableSwipeRegeneration, setDisableSwipeRegeneration, hideMessageId, setHideMessageId, hideGenerationTime, setHideGenerationTime, hideTokenCount, setHideTokenCount, hideHelpTips, setHideHelpTips, dialogGrouping, setDialogGrouping, enterToSubmit, setEnterToSubmit } from '@/core/config/APPSettings.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { requestNotificationPermission } from '@/core/services/notificationService.js';
import { themeState, setChatLayout } from '@/core/states/themeState.js';

const localLang = ref(currentLang.value);
const t = (key) => translations[localLang.value]?.[key] || key;
const activeImageViewerMode = ref(localStorage.getItem('gz_image_viewer') || 'default');
const disableSwipeRegen = ref(disableSwipeRegeneration.value);

const currentScreen = ref('main');

watch(currentScreen, (newVal) => {
    if (newVal === 'interface') {
        window.dispatchEvent(new CustomEvent('header-setup-submenu', {
            detail: {
                title: t('menu_interface_settings') || 'Interface Settings',
                onBack: () => { currentScreen.value = 'main'; }
            }
        }));
    } else {
        window.dispatchEvent(new CustomEvent('header-force-update'));
    }
});
const hideMsgId = ref(hideMessageId.value);
const hideGenTime = ref(hideGenerationTime.value);
const hideTokenCnt = ref(hideTokenCount.value);
const enterSubmitMode = ref(enterToSubmit.value);

const toggleEnterToSubmit = () => {
    enterSubmitMode.value = !enterSubmitMode.value;
    setEnterToSubmit(enterSubmitMode.value);
    window.dispatchEvent(new CustomEvent('settings-changed'));
};
const hideHTips = ref(hideHelpTips.value);
const dialogGrouped = ref(dialogGrouping.value);

const toggleDisableSwipeRegen = () => {
    const newValue = !disableSwipeRegen.value;
    disableSwipeRegen.value = newValue;
    setDisableSwipeRegeneration(newValue);
    window.dispatchEvent(new CustomEvent('settings-changed'));
};

const toggleHideMsgId = () => {
    hideMsgId.value = !hideMsgId.value;
    setHideMessageId(hideMsgId.value);
    window.dispatchEvent(new CustomEvent('settings-changed'));
};

const toggleHideGenTime = () => {
    hideGenTime.value = !hideGenTime.value;
    setHideGenerationTime(hideGenTime.value);
    window.dispatchEvent(new CustomEvent('settings-changed'));
};

const toggleHideTokenCnt = () => {
    hideTokenCnt.value = !hideTokenCnt.value;
    setHideTokenCount(hideTokenCnt.value);
    window.dispatchEvent(new CustomEvent('settings-changed'));
};

const toggleHideHTips = () => {
    hideHTips.value = !hideHTips.value;
    setHideHelpTips(hideHTips.value);
    window.dispatchEvent(new CustomEvent('settings-changed'));
};

const toggleDialogGrouped = () => {
    dialogGrouped.value = !dialogGrouped.value;
    setDialogGrouping(dialogGrouped.value);
    window.dispatchEvent(new CustomEvent('settings-changed'));
};

const imageViewerLabel = computed(() => {
    return (activeImageViewerMode.value === 'holo' || activeImageViewerMode.value === 'holocards') ? (t('viewer_holo') || 'Holo Cards (3D)') : (t('viewer_default') || 'Default (2D)');
});

const openImageViewerSelector = () => {
    showBottomSheet({
        title: t('menu_image_viewer') || 'Image Viewer',
        items: [
            { label: t('viewer_default') || 'Default (2D)', onClick: () => setViewer('default') },
            { label: t('viewer_holo') || 'Holo Cards (3D)', onClick: () => setViewer('holo') }
        ]
    });
};

const setViewer = (mode) => {
    setImageViewerMode(mode);
    activeImageViewerMode.value = mode;
    closeBottomSheet();
};

const chatLayoutLabel = computed(() => {
    return themeState.chatLayout === 'bubble' ? (t('layout_bubble') || 'Bubbles') : (t('layout_default') || 'Default');
});

const openChatLayoutSelector = () => {
    showBottomSheet({
        title: t('menu_chat_layout') || 'Chat Layout',
        items: [
            { label: t('layout_default') || 'Default', onClick: () => { setChatLayout('default'); closeBottomSheet(); } },
            { label: t('layout_bubble') || 'Bubbles', onClick: () => { setChatLayout('bubble'); closeBottomSheet(); } }
        ]
    });
};

const openThemeSettings = () => {
    window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-theme-settings' }));
};

const openLanguageSelector = () => {
    showBottomSheet({
        title: t('menu_language'),
        items: [
            {
                label: 'English',
                icon: '<svg viewBox="0 0 24 24"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zm6.93 6h-2.95c-.32-1.25-.78-2.45-1.38-3.56 1.84.63 3.37 1.91 4.33 3.56zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2 0 .68.06 1.34.14 2H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56-1.84-.63-3.37-1.91-4.33-3.56zm2.95-8H5.08c.96-1.65 2.49-2.93 4.33-3.56C8.81 5.55 8.35 6.75 8.03 8zM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96zM14.34 14H9.66c-.09-.66-.16-1.32-.16-2 0-.68.07-1.35.16-2h4.68c.09.65.16 1.32.16 2 0 .68-.07 1.34-.16 2zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95c-.96 1.65-2.49 2.93-4.33 3.56zM16.36 14c.08-.66.14-1.32.14-2 0-.68-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2h-3.38z"/></svg>',
                onClick: () => changeLang('en')
            },
            {
                label: 'Русский',
                icon: '<svg viewBox="0 0 24 24"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zm6.93 6h-2.95c-.32-1.25-.78-2.45-1.38-3.56 1.84.63 3.37 1.91 4.33 3.56zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2 0 .68.06 1.34.14 2H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56-1.84-.63-3.37-1.91-4.33-3.56zm2.95-8H5.08c.96-1.65 2.49-2.93 4.33-3.56C8.81 5.55 8.35 6.75 8.03 8zM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96zM14.34 14H9.66c-.09-.66-.16-1.32-.16-2 0-.68.07-1.35.16-2h4.68c.09.65.16 1.32.16 2 0 .68-.07 1.34-.16 2zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95c-.96 1.65-2.49 2.93-4.33 3.56zM16.36 14c.08-.66.14-1.32.14-2 0-.68-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2h-3.38z"/></svg>',
                onClick: () => changeLang('ru')
            }
        ]
    });
};

const changeLang = (lang) => {
    setLanguage(lang);
    updateLanguage();
    localLang.value = lang;
    window.dispatchEvent(new CustomEvent('language-changed'));
    closeBottomSheet();
};

const onRequestNotifications = async () => {
    const granted = await requestNotificationPermission();
    if (granted) {
        alert(t('notifications_granted') || "Notifications enabled");
    } else {
        alert(t('notifications_denied') || "Notifications denied or check system settings");
    }
};

const onLangChange = () => {
    localLang.value = currentLang.value;
};

onMounted(() => {
    window.addEventListener('language-changed', onLangChange);
});
onUnmounted(() => window.removeEventListener('language-changed', onLangChange));
</script>

<template>
    <div style="position: relative; overflow-x: hidden;">
        <Transition name="slide-fade" mode="out-in">
            <div v-if="currentScreen === 'main'" key="main">
                <div class="menu-group">
                <div class="section-header">{{ t('section_settings') }}</div>
                <!-- Theme -->
                <div class="menu-item" @click="openThemeSettings">
                    <svg class="menu-icon" viewBox="0 0 24 24"><path d="M12 3a9 9 0 0 0 0 18c.83 0 1.5-.67 1.5-1.5 0-.39-.13-.73-.34-1.01-.21-.26-.32-.59-.32-.95 0-.82.68-1.5 1.5-1.5h2.62A5.88 5.88 0 0 0 22 10.12c0-3.93-4.48-7.12-10-7.12zM7.13 13c-.76 0-1.38-.62-1.38-1.38s.62-1.38 1.38-1.38 1.38.62 1.38 1.38-.62 1.38-1.38 1.38zm4.12-1.38c-.76 0-1.38-.62-1.38-1.38s.62-1.38 1.38-1.38 1.38.62 1.38 1.38-.62 1.38-1.38 1.38zm4.13 3.87c-.76 0-1.38-.62-1.38-1.38s.62-1.38 1.38-1.38 1.38.62 1.38 1.38-.62 1.38-1.38 1.38z"/></svg>
                    <div class="menu-text">{{ t('menu_custom_theme') }}</div>
                    <div class="menu-value" :style="{ color: themeState.accentColor }">●</div>
                </div>

                <!-- Language -->
                <div class="menu-item" @click="openLanguageSelector">
                    <svg class="menu-icon" viewBox="0 0 24 24"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zm6.93 6h-2.95c-.32-1.25-.78-2.45-1.38-3.56 1.84.63 3.37 1.91 4.33 3.56zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2 0 .68.06 1.34.14 2H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56-1.84-.63-3.37-1.91-4.33-3.56zm2.95-8H5.08c.96-1.65 2.49-2.93 4.33-3.56C8.81 5.55 8.35 6.75 8.03 8zM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96zM14.34 14H9.66c-.09-.66-.16-1.32-.16-2 0-.68.07-1.35.16-2h4.68c.09.65.16 1.32.16 2 0 .68-.07 1.34-.16 2zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95c-.96 1.65-2.49 2.93-4.33 3.56zM16.36 14c.08-.66.14-1.32.14-2 0-.68-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2h-3.38z"/></svg>
                    <div class="menu-text">{{ t('menu_language') }}</div>
                    <div class="menu-value">{{ localLang === 'ru' ? 'Русский' : 'English' }}</div>
                </div>

                <!-- Notifications -->
                <div class="menu-item" @click="onRequestNotifications">
                    <svg class="menu-icon" viewBox="0 0 24 24"><path d="M12 22c1.1 0 2-.9 2-2h-4c0 1.1.9 2 2 2zm6-6v-5c0-3.07-1.63-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.64 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2zm-2 1H8v-6c0-2.48 1.51-4.5 4-4.5s4 2.02 4 4.5v6z"/></svg>
                    <div class="menu-text">{{ t('menu_notifications') }}</div>
                </div>

                <!-- Interface Settings Submenu -->
                <div class="menu-item" @click="currentScreen = 'interface'">
                    <svg class="menu-icon" viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/></svg>
                    <div class="menu-text">{{ t('menu_interface_settings') || 'Interface Settings' }}</div>
                    <div class="menu-value">
                        <svg viewBox="0 0 24 24" style="width: 16px; height: 16px; fill: var(--text-light-gray);"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>
                    </div>
                </div>

                <div class="menu-hint">
                    <span>{{ t('hint_generation_settings') }}</span>&nbsp;<svg viewBox="0 0 24 24" class="hint-icon"><path d="M19 9l1.25-2.75L23 5l-2.75-1.25L19 1l-1.25 2.75L15 5l2.75 1.25L19 9zm-7.5.5L9 4 6.5 9.5 1 12l5.5 2.5L9 20l2.5-5.5L17 12l-5.5-2.5zM19 15l-1.25 2.75L15 19l2.75 1.25L19 23l1.25-2.75L23 19l-2.75-1.25L19 15z"/></svg>
                </div>
            </div>
        </div>

        <div v-else-if="currentScreen === 'interface'" key="interface">
            <div class="menu-group">
                <!-- Enter to Send -->
                <div class="settings-item-checkbox" @click="toggleEnterToSubmit" style="cursor: pointer; padding: 12px 16px;">
                    <div class="settings-text-col">
                        <label style="cursor: pointer; margin-bottom: 2px;">{{ t('menu_enter_to_send') || 'Enter to Send' }}</label>
                        <div class="settings-desc" style="font-size: 11px; color: var(--text-gray); font-weight: normal;">{{ t('desc_enter_to_send') || 'Press Enter to send message. If disabled, Enter adds a new line. Applies only to physical keyboards.' }}</div>
                    </div>
                    <input type="checkbox" class="vk-switch" :checked="enterSubmitMode" style="pointer-events: none;">
                </div>

                <div class="section-header">{{ t('menu_interface_settings') || 'Interface Settings' }}</div>
                <!-- Dialog Grouping -->
                <div class="settings-item-checkbox" @click="toggleDialogGrouped">
                    <div class="settings-text-col">
                        <label>{{ t('menu_dialog_grouping') || 'Group Dialogs' }}</label>
                        <div class="settings-desc">{{ t('desc_dialog_grouping') || 'Groups all sessions by character, sorted by latest message' }}</div>
                    </div>
                    <input type="checkbox" class="vk-switch" :checked="dialogGrouped" style="pointer-events: none;">
                </div>
                <!-- Hide Help Tips -->
                <div class="settings-item-checkbox" @click="toggleHideHTips">
                    <div class="settings-text-col">
                        <label>{{ t('menu_hide_help_tips') || 'Hide Tooltips' }}</label>
                        <div class="settings-desc">{{ t('desc_hide_help_tips') || 'Hides contextual help buttons (?) across the app' }}</div>
                    </div>
                    <input type="checkbox" class="vk-switch" :checked="hideHTips" style="pointer-events: none;">
                </div>
            </div>

            <div class="menu-group">
                <div class="section-header">{{ t('menu_message_settings') || 'Message Settings' }}</div>
                <!-- Disable Swipe Regeneration -->
                <div class="settings-item-checkbox" @click="toggleDisableSwipeRegen">
                    <div class="settings-text-col">
                        <label>{{ t('menu_disable_swipe_regeneration') || 'Disable Swipe Regeneration' }}</label>
                        <div class="settings-desc">{{ t('desc_disable_swipe_regeneration') || 'Disables regenerating messages by swiping left' }}</div>
                    </div>
                    <input type="checkbox" class="vk-switch" :checked="disableSwipeRegen" style="pointer-events: none;">
                </div>

                <!-- Image Viewer (Holo Cards) -->
                <div class="settings-item-checkbox" @click="openImageViewerSelector">
                    <div class="settings-text-col">
                        <label>{{ t('menu_image_viewer') || 'Image Viewer' }}</label>
                        <div class="settings-desc">{{ t('desc_image_viewer') || 'Change how attached images are displayed' }}</div>
                    </div>
                    <div class="menu-value" style="font-size: 14px; color: var(--text-gray);">{{ imageViewerLabel }}</div>
                </div>

                <!-- Chat Layout -->
                <div class="settings-item-checkbox" @click="openChatLayoutSelector">
                    <div class="settings-text-col">
                        <label>{{ t('menu_chat_layout') || 'Chat Layout' }}</label>
                        <div class="settings-desc">{{ t('desc_chat_layout') || 'Switch between bubbles or classic message layout' }}</div>
                    </div>
                    <div class="menu-value" style="font-size: 14px; color: var(--text-gray);">{{ chatLayoutLabel }}</div>
                </div>

                <!-- Hide Message ID -->
                <div class="settings-item-checkbox" @click="toggleHideMsgId">
                    <div class="settings-text-col">
                        <label>{{ t('menu_hide_msg_id') || 'Hide Message ID' }}</label>
                        <div class="settings-desc">{{ t('desc_hide_msg_id') || 'Hides the unique message identifier in the chat interface' }}</div>
                    </div>
                    <input type="checkbox" class="vk-switch" :checked="hideMsgId" style="pointer-events: none;">
                </div>

                <!-- Hide Generation Time -->
                <div class="settings-item-checkbox" @click="toggleHideGenTime">
                    <div class="settings-text-col">
                        <label>{{ t('menu_hide_gen_time') || 'Hide Gen Time' }}</label>
                        <div class="settings-desc">{{ t('desc_hide_gen_time') || 'Hides the generation time statistics for AI messages' }}</div>
                    </div>
                    <input type="checkbox" class="vk-switch" :checked="hideGenTime" style="pointer-events: none;">
                </div>

                <!-- Hide Token Count -->
                <div class="settings-item-checkbox" @click="toggleHideTokenCnt">
                    <div class="settings-text-col">
                        <label>{{ t('menu_hide_token_count') || 'Hide Token Count' }}</label>
                        <div class="settings-desc">{{ t('desc_hide_token_count') || 'Hides token usage statistics attached to messages' }}</div>
                    </div>
                    <input type="checkbox" class="vk-switch" :checked="hideTokenCnt" style="pointer-events: none;">
                </div>
            </div>
        </div>
        </Transition>
    </div>
</template>

<style scoped>
.slide-fade-enter-active,
.slide-fade-leave-active {
  transition: all 0.2s ease-out;
}
.slide-fade-enter-from {
  transform: translateX(10%);
  opacity: 0;
}
.slide-fade-leave-to {
  transform: translateX(-10%);
  opacity: 0;
}

.menu-hint {
    padding: 4px 16px 16px 16px;
    font-size: 13px;
    color: var(--text-gray, #8E8E93);
    line-height: 1.4;
    opacity: 0.9;
}

.hint-icon {
    width: 14px;
    height: 14px;
    fill: currentColor;
    display: inline-block;
    vertical-align: middle;
    margin-bottom: 2px;
}
</style>