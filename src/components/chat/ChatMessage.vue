<script setup>
import { ref, computed, nextTick, watch, onMounted, onUnmounted } from 'vue';
import { formatText } from '@/utils/textFormatter.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import ShadowContent from '@/components/ui/ShadowContent.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang, disableSwipeRegeneration } from '@/core/config/APPSettings.js';
import { themeState } from '@/core/states/themeState.js';
import { getAllGreetings } from '@/utils/sessions.js';
import { getEffectivePersona, allPersonas } from '@/core/states/personaState.js';
import { showBottomSheet, closeBottomSheet } from '@/core/states/bottomSheetState.js';
import { hideMessageId, hideGenerationTime, hideTokenCount } from '@/core/config/APPSettings.js';
import RollingNumber from '@/components/ui/RollingNumber.vue';
import SheetView from '@/components/ui/SheetView.vue';
import { getBlacklistedProvider } from '@/core/config/APISettings.js';
import { saveFile } from '@/core/services/fileSaver.js';

const props = defineProps({
    message: { type: Object, required: true },
    index: { type: Number, required: true },
    activeChatChar: { type: Object, default: null },
    isGenerating: { type: Boolean, default: false },
    isLast: { type: Boolean, default: false },
    searchQuery: { type: String, default: '' },
    activeSearchMatchIndex: { type: Number, default: -1 },
    isSelectionMode: { type: Boolean, default: false },
    isSelected: { type: Boolean, default: false },
    regexRevision: { type: Number, default: 0 }
});

const emit = defineEmits([
    'swipe', 'change-greeting', 'regenerate', 'edit', 'save-edit', 'cancel-edit',
    'open-actions', 'open-avatar', 'delete', 'toggle-selection', 'toggle-image-hidden',
    'save-guidance', 'regenerate-image'
]);

const triggeredItemsSheet = ref(null);
const t = (key) => translations[currentLang.value]?.[key] || key;

const isGuidedSwipeOpen = ref(false);
const guidedSwipeText = ref('');
const guidedSwipeInput = ref(null);

const toggleGuidedSwipe = () => {
    isGuidedSwipeOpen.value = !isGuidedSwipeOpen.value;
    if (isGuidedSwipeOpen.value) {
        nextTick(() => { if (guidedSwipeInput.value) guidedSwipeInput.value.focus(); });
    } else {
        guidedSwipeText.value = '';
    }
};

const submitGuidedSwipe = () => {
    emit('regenerate', 'guided', guidedSwipeText.value);
    isGuidedSwipeOpen.value = false;
    guidedSwipeText.value = '';
};

const isGuidanceEditing = ref(false);
const guidanceEditText = ref('');

const startGuidanceEdit = () => {
    guidanceEditText.value = currentGuidance.value?.text || '';
    isGuidanceEditing.value = true;
};

const cancelGuidanceEdit = () => {
    isGuidanceEditing.value = false;
};

const saveGuidanceEdit = () => {
    emit('save-guidance', guidanceEditText.value.trim() || null);
    isGuidanceEditing.value = false;
};

const currentGuidance = computed(() => {
    // If it's a character message, ONLY show if it's explicitly a SWIPE
    if (props.message.role === 'char') {
        const meta = props.message.swipesMeta?.[props.message.swipeId || 0];
        if (meta && meta.guidanceText && meta.guidanceType === 'SWIPE') {
            return {
                text: meta.guidanceText,
                type: 'SWIPE'
            };
        }
        // Fallback for typing/initial swipe state
        if (props.message.isTyping && props.message.guidanceText && props.message.guidanceType === 'SWIPE') {
            return {
                text: props.message.guidanceText,
                type: 'SWIPE'
            };
        }
        return null; // Don't show redundant headers for GENERATION or IMPERSONATION on bot side
    }

    // User message: Show if it has any guidance
    if (props.message.role === 'user' && props.message.guidanceText) {
        return {
            text: props.message.guidanceText,
            type: props.message.guidanceType || 'GENERATION'
        };
    }
    return null;
});

// --- Helpers ---
const getAvatar = () => {
    if (props.message.role === 'user') {
        if (props.message.persona?.id) {
            const p = allPersonas.value.find(p => p.id === props.message.persona.id);
            if (p?.avatar) return p.avatar;
        }
        return props.message.persona?.avatar || null;
    }
    return props.activeChatChar?.avatar || null;
};

const getAvatarLetter = () => {
    if (props.message.role === 'user') {
        let name = "U";
        if (props.message.persona?.id) {
            const p = allPersonas.value.find(p => p.id === props.message.persona.id);
            if (p?.name) name = p.name;
        } else if (props.message.persona?.name) {
            name = props.message.persona.name;
        }
        return (name[0] || "U").toUpperCase();
    }
    return (props.activeChatChar?.name?.[0] || "?").toUpperCase();
};

const getAvatarColor = () => {
    if (props.message.role === 'user') return 'var(--vk-blue)';
    return props.activeChatChar?.color || '#ccc';
};

const getDisplayName = () => {
    if (props.message.role === 'user') {
        if (props.message.persona?.id) {
            const p = allPersonas.value.find(p => p.id === props.message.persona.id);
            if (p?.name) return p.name;
        }
        return props.message.persona?.name || "User";
    }
    return props.activeChatChar?.name || "Character";
};

const formatMessageText = (text, regexTracking = undefined) => {
    if (!text) return '';
    const effPersona = getEffectivePersona(props.activeChatChar?.id, props.activeChatChar?.sessionId);
    text = replaceMacros(text, props.activeChatChar, effPersona);
    // Fix: Clean artifacts and trim leading whitespace immediately
    let clean = text.replace(/^\s+/, '')
                    .replace(/&gt;/gi, '>')
                    .replace(/&lt;/gi, '<')
                    .replace(/&amp;/gi, '&')
                    .replace(/&quot;/gi, '"')
                    .replace(/&apos;/gi, "'");
    const isUser = props.message.role === 'user';
    return formatText(clean, isUser, { 
        charId: props.activeChatChar?.id, 
        sessionId: props.activeChatChar?.sessionId,
        char: props.activeChatChar,
        persona: effPersona,
        triggeredRegexes: regexTracking
    });
};

// --- Swipe & Long Press Logic ---
let swipeStartX = 0;
let swipeStartY = 0;
let isSwipeScrolling = false;
let currentSwipeElement = null;
let longPressTimer = null;
let isLongPressTriggered = false;

let hadSelectionOnStart = false;
 
function handleTouchStart(e) {
    hadSelectionOnStart = false;
    const sel = window.getSelection();
    if (sel && sel.toString().trim().length > 0) {
        hadSelectionOnStart = true;
    }

    if (props.isSelectionMode) return;
    if (props.message.role !== 'char' || props.message.isEditing || props.isGenerating) {
        // Still allow long press for selection on user messages or non-editing states
        if (props.message.isEditing || props.isGenerating) return;
    } else {
        swipeStartX = e.touches[0].clientX;
        swipeStartY = e.touches[0].clientY;
        isSwipeScrolling = false;
        
        const section = e.currentTarget;
        const body = section.querySelector('.msg-body');
        if (body) {
            body.style.transition = 'none';
            currentSwipeElement = body;
        }
    }

    // Long press logic
    isLongPressTriggered = false;
    longPressTimer = setTimeout(() => {
        isLongPressTriggered = true;
        emit('toggle-selection');
        if (currentSwipeElement) {
            currentSwipeElement.style.transform = '';
            currentSwipeElement = null;
        }
    }, 500);
}

function handleTouchMove(e) {
    if (isLongPressTriggered) return;
    
    const dX = e.touches[0].clientX - (swipeStartX || e.touches[0].clientX);
    const dY = e.touches[0].clientY - (swipeStartY || e.touches[0].clientY);

    // If moved significantly, cancel long press
    if (Math.abs(dX) > 10 || Math.abs(dY) > 10) {
        if (longPressTimer) {
            clearTimeout(longPressTimer);
            longPressTimer = null;
        }
    }

    if (!currentSwipeElement || props.message.role !== 'char' || props.message.isEditing) return;
    if (isSwipeScrolling) return;

    const deltaX = e.touches[0].clientX - swipeStartX;
    const deltaY = e.touches[0].clientY - swipeStartY;

    if (Math.abs(deltaY) > Math.abs(deltaX)) {
        isSwipeScrolling = true;
        return;
    }

    if (e.cancelable) e.preventDefault();

    const isFirstMsg = props.index === 0;
    const canSwitchGreeting = isFirstMsg && getAllGreetings(props.activeChatChar).length > 1;
    
    if (deltaX < 0) { // Left (Next)
        if (!canSwitchGreeting) {
            if (!props.isLast && (props.message.swipeId || 0) >= (props.message.swipes?.length || 1) - 1) return;
        }
    } else if (deltaX > 0) { // Right (Prev)
        if (!canSwitchGreeting) {
            if ((props.message.swipeId || 0) <= 0) return;
        }
    }

    currentSwipeElement.style.transform = `translateX(${deltaX}px)`;
}

function handleTouchEnd(e) {
    if (longPressTimer) {
        clearTimeout(longPressTimer);
        longPressTimer = null;
    }

    if (isLongPressTriggered) {
        isLongPressTriggered = false;
        return;
    }

    if (!currentSwipeElement) return;
    
    const deltaX = e.changedTouches[0].clientX - swipeStartX;
    const body = currentSwipeElement;
    currentSwipeElement = null;
    
    if (isSwipeScrolling) {
        body.style.transform = '';
        return;
    }

    const isFirstMsg = props.index === 0;
    const canSwitchGreeting = isFirstMsg && getAllGreetings(props.activeChatChar).length > 1;

    const resetStyle = () => {
        body.style.transition = 'transform 0.3s ease';
        body.style.transform = '';
    };

    const animateChange = (callback) => {
        body.style.opacity = '0';
        callback();
        nextTick(() => {
            body.style.transform = '';
            setTimeout(() => {
                body.style.transition = 'opacity 0.2s ease';
                body.style.opacity = '1';
                setTimeout(() => { body.style.transition = ''; }, 200);
            }, 50);
        });
    };

    if (canSwitchGreeting) {
        if (deltaX < -100) animateChange(() => emit('change-greeting', 1));
        else if (deltaX > 100) animateChange(() => emit('change-greeting', -1));
        else resetStyle();
        return;
    }

    if (deltaX < -100) {
        if ((props.message.swipeId || 0) < (props.message.swipes?.length || 1) - 1) {
            animateChange(() => emit('swipe', 1));
        } else if (props.isLast && !disableSwipeRegeneration.value) {
            body.style.transition = 'transform 0.1s';
            body.style.transform = `translateX(-20px)`;
            setTimeout(() => { 
                body.style.transform = ''; 
                emit('regenerate', 'new_variant');
            }, 100);
        } else {
            resetStyle();
        }
    } else if (deltaX > 100) {
        if ((props.message.swipeId || 0) > 0) animateChange(() => emit('swipe', -1));
        else resetStyle();
    } else {
        resetStyle();
    }
}
 
const handleMessageClick = () => {
    if (!props.isSelectionMode) return;
    
    if (hadSelectionOnStart) {
        hadSelectionOnStart = false;
        window.getSelection()?.removeAllRanges();
        return;
    }
    
    emit('toggle-selection');
};

const handleBubbleClick = (e) => {
    if (layoutMode.value !== 'bubble') return;
    if (props.isSelectionMode) return;
    
    const sel = window.getSelection();
    if (sel && sel.toString().trim().length > 0) return;
    
    emit('open-actions');
};



const focusAndResize = (el) => {
    if (!el) return;
    requestAnimationFrame(() => el.focus());
};

const copyText = (text) => {
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text);
    }
};

const combinedMessageData = computed(() => {
    // Adding regexRevision as a dependency to trigger re-render
    const _rev = props.regexRevision;
    const triggeredRegexes = [];
    let html = formatMessageText(props.message.text, triggeredRegexes);
    
    if (props.searchQuery) {
        let matchCount = 0;
        const escapedQuery = props.searchQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const regex = new RegExp(`(${escapedQuery})(?![^<]*>)`, 'gi');
        html = html.replace(regex, (match) => {
            const isCurrent = matchCount === props.activeSearchMatchIndex;
            matchCount++;
            return `<span class="search-highlight-text${isCurrent ? ' active-search-match' : ''}">${match}</span>`;
        });
    }

    if (props.message.isTyping) {
        html += ` <span class="typing-dots-bounce"><span>.</span><span>.</span><span>.</span></span>`;
    }
    return { html, regexes: triggeredRegexes };
});

const openTriggeredSheet = () => {
    triggeredItemsSheet.value?.open();
};

const openLorebookEntry = (lb) => {
    triggeredItemsSheet.value?.close();
    window.dispatchEvent(new CustomEvent('open-lorebook-entry', {
        detail: { lorebookId: lb.lorebookId, entryId: lb.id }
    }));
};
const copyErrorText = (text) => {
    if (!text) return;
    const div = document.createElement('div');
    // Convert <br> to newlines before stripping tags
    div.innerHTML = text.replace(/<br\s*\/?>/gi, '\n');
    const cleanText = div.textContent || div.innerText || text;
    copyText(cleanText.trim());
};

const openImage = (src, instruction = null) => {
    if (!src) return;
    window.dispatchEvent(new CustomEvent('trigger-open-image', {
        detail: { src, name: 'Attachment', description: instruction?.prompt || '' }
    }));
};

const parseIIGInstruction = (el) => {
    if (!el?.dataset?.iigInstruction) return null;
    try {
        return JSON.parse(el.dataset.iigInstruction
            .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&'));
    } catch { return null; }
};

const handleContentClick = (e) => {
    const path = e.composedPath();

    // Loading block — tap to expand/collapse prompt text
    const loadingBlock = path.find(el => el?.classList?.contains('imggen-loading'));
    if (loadingBlock) {
        e.stopPropagation();
        loadingBlock.classList.toggle('expanded');
        return;
    }

    // Options button on janitor image → bottom sheet with 2 actions
    const janitorOptionsBtn = path.find(el => el?.classList?.contains('janitor-options-btn'));
    if (janitorOptionsBtn) {
        e.stopPropagation();
        const wrapper = path.find(el => el?.classList?.contains('janitor-img-wrapper'));
        const img = wrapper?.querySelector?.('img.janitor-img');
        if (!img) return;
        const src = img.src;
        showBottomSheet({
            items: [
                {
                    label: t('imggen_expand_image') || 'Expand image',
                    hint: t('expand_image_hint') || 'Открыть картинку в полноэкранном режиме',
                    icon: '<svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zm0 12.5c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>',
                    onClick: () => { closeBottomSheet(); openImage(src); }
                },
                {
                    label: t('action_save_image') || 'Save image',
                    hint: t('imggen_save_hint') || 'Сохранить картинку на устройство',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
                    onClick: async () => {
                        closeBottomSheet();
                        try {
                            const response = await fetch(src);
                            const blob = await response.blob();
                            await saveFile(`Image_${Date.now()}.png`, blob, 'image/png');
                        } catch (err) {
                            console.error('Failed to save image:', err);
                        }
                    }
                },
            ]
        });
        return;
    }

    // Options button on generated image → bottom sheet with 3 actions
    const optionsBtn = path.find(el => el?.classList?.contains('imggen-options-btn'));
    if (optionsBtn) {
        e.stopPropagation();
        const wrapper = path.find(el => el?.classList?.contains('imggen-result-wrapper'));
        const img = wrapper?.querySelector?.('img.imggen-result');
        if (!img) return;
        const instr = parseIIGInstruction(img);
        const id = img.dataset?.iigId;
        const src = img.src;
        showBottomSheet({
            items: [
                {
                    label: t('imggen_expand_image') || 'Expand image',
                    hint: t('imggen_expand_image_hint') || 'Открыть картинку в полноэкранном режиме и посмотреть промпт',
                    icon: '<svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zm0 12.5c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>',
                    onClick: () => { closeBottomSheet(); openImage(src, instr); }
                },
                {
                    label: t('action_save_image') || 'Save image',
                    hint: t('imggen_save_hint') || 'Сохранить картинку на устройство',
                    icon: '<svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>',
                    onClick: async () => {
                        closeBottomSheet();
                        try {
                            const response = await fetch(src);
                            const blob = await response.blob();
                            await saveFile(`Image_${Date.now()}.png`, blob, 'image/png');
                        } catch (err) {
                            console.error('Failed to save image:', err);
                        }
                    }
                },
                {
                    label: t('action_regenerate') || 'Regenerate',
                    hint: t('imggen_regenerate_hint') || 'Повторно сгенерировать картинку',
                    icon: '<svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>',
                    onClick: () => { closeBottomSheet(); if (instr && id) emit('regenerate-image', { instruction: instr, id }); }
                },
            ]
        });
        return;
    }

    // Error retry button
    const retryBtn = path.find(el => el?.classList?.contains('imggen-error-retry'));
    if (retryBtn) {
        e.stopPropagation();
        const errorBlock = path.find(el => el?.classList?.contains('imggen-error'));
        if (errorBlock) {
            const instr = parseIIGInstruction(errorBlock);
            const id = errorBlock.dataset?.iigId;
            if (instr && id) emit('regenerate-image', { instruction: instr, id });
        }
        return;
    }

    // Enable and generate button
    const enableBtn = path.find(el => el?.classList?.contains('imggen-enable-retry'));
    if (enableBtn) {
        e.stopPropagation();
        const disabledBlock = path.find(el => el?.classList?.contains('imggen-disabled'));
        if (disabledBlock) {
            import('@/core/services/imageGenService.js').then(module => {
                const settings = module.getImageGenSettings();
                settings.enabled = true;
                module.saveImageGenSettings(settings);
                
                const instr = parseIIGInstruction(disabledBlock);
                const id = disabledBlock.dataset?.iigId;
                if (instr && id) emit('regenerate-image', { instruction: instr, id });
            });
        }
        return;
    }

    handleBubbleClick(e);
};
const layoutMode = computed(() => themeState.chatLayout);
const showFooter = computed(() => {
    // In bubble layout, meta and actions are hidden, so we only show footer if there are actual controls
    if (layoutMode.value === 'bubble') {
        const hasSwipes = props.message.role === 'char' && props.message.swipes?.length > 1;
        const hasGreetings = props.index === 0 && props.message.role === 'char' && getAllGreetings(props.activeChatChar).length > 1;
        const hasRegenerate = ((props.message.role === 'user' && props.isLast) || props.message.isError) && !props.isGenerating && !props.message.isEditing;
        const hasTriggeredItems = props.message.triggeredLorebooks?.length || combinedMessageData.value.regexes?.length;
        return hasSwipes || hasGreetings || hasRegenerate || props.message.isEditing || hasTriggeredItems;
    }
    return true; // Always show in other layouts for meta/actions
});

const blacklistedErrorProvider = computed(() => {
    if (!props.message.isError) return null;
    const endpoint = localStorage.getItem('gz_api_endpoint_normalized')
        || localStorage.getItem('api-endpoint') || '';
    return getBlacklistedProvider(endpoint);
});

const tokenCount = computed(() => {
    return props.message.tokens || 0;
});

const uiHideMsgId = ref(hideMessageId.value);
const uiHideGenTime = ref(hideGenerationTime.value);
const uiHideTokenCnt = ref(hideTokenCount.value);

const onSettingsChanged = () => {
    uiHideMsgId.value = hideMessageId.value;
    uiHideGenTime.value = hideGenerationTime.value;
    uiHideTokenCnt.value = hideTokenCount.value;
};

onMounted(() => {
    window.addEventListener('settings-changed', onSettingsChanged);
});

onUnmounted(() => {
    window.removeEventListener('settings-changed', onSettingsChanged);
});
</script>

<template>
    <div 
        class="message-section"
        v-bind="$attrs"
        :class="[message.role, `layout-${layoutMode}`, { error: message.isError, selected: isSelected, 'selection-mode': isSelectionMode, 'msg-hidden': message.isHidden }]"
        @touchstart.passive="handleTouchStart"
        @touchmove="handleTouchMove"
        @touchend="handleTouchEnd"
        @click="handleMessageClick"
    >
        <div class="msg-header">
            <img v-if="getAvatar()" class="msg-avatar" :src="getAvatar()" @click.stop="emit('open-avatar')" />
            <div v-else class="msg-avatar" :style="{ backgroundColor: getAvatarColor() }">
                {{ getAvatarLetter() }}
            </div>
            
            <span class="msg-name">
                <span class="msg-name-label">{{ getDisplayName() }}</span>
                <span class="msg-index gen-stat header-idx" v-if="!uiHideMsgId">#{{ index + 1 }}</span>
                <sup v-if="message.role === 'char' && activeChatChar?.version" class="item-version">#{{ activeChatChar.version }}</sup>
                <div v-if="message.triggeredLorebooks?.length || combinedMessageData.regexes?.length" class="msg-lb-trigger-menu" @click.stop="openTriggeredSheet">
                    <svg viewBox="0 0 24 24"><path d="M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z"/></svg>
                </div>
            </span>
            <span class="msg-time">
                <svg v-if="message.isHidden" class="msg-hidden-badge" viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>
                {{ message.time }}
            </span>
        </div>

        <!-- Guidance Block (Header) -->
        <div v-if="currentGuidance" class="msg-guidance-block" style="margin-bottom: 4px; border-radius: 8px;">
            <div class="guidance-label" style="display: flex; justify-content: space-between; align-items: center;">
                <span>GUIDED {{ currentGuidance.type }}</span>
                <div style="display: flex; gap: 2px; align-items: center;">
                    <div class="edit-btn inline-pencil" v-if="!isGuidanceEditing && !message.isEditing && !isGenerating" title="Edit instruction" @click.stop="startGuidanceEdit" style="width: 20px; height: 20px; background: transparent; border: none; box-shadow: none;">
                        <svg viewBox="0 0 24 24" style="width: 13px; height: 13px; fill: currentColor; opacity: 0.6;"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                    </div>
                    <div class="edit-btn inline-refresh" v-if="!isGenerating && message.role === 'char'" title="Regenerate swipe with this instruction" @click.stop="emit('regenerate', 'guided', currentGuidance.text)" style="width: 20px; height: 20px; background: transparent; border: none; box-shadow: none;">
                        <svg viewBox="0 0 24 24" style="width: 14px; height: 14px; fill: currentColor; opacity: 0.6;"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                    </div>
                </div>
            </div>
            <div v-if="isGuidanceEditing" class="guidance-edit-container-inline">
                <textarea 
                    v-model="guidanceEditText" 
                    class="edit-textarea guidance-edit-textarea" 
                    style="font-style: italic; font-size: 13px; background: rgba(0,0,0,0.03); margin-bottom: 6px;"
                    rows="1" 
                    @vue:mounted="({ el }) => focusAndResize(el)"
                ></textarea>
                <div class="edit-buttons" style="display: flex; gap: 8px; justify-content: flex-end;">
                    <div class="edit-btn cancel" title="Cancel" @click.stop="cancelGuidanceEdit" style="width: 24px; height: 24px;">
                        <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                    </div>
                    <div class="edit-btn save" title="Save" @click.stop="saveGuidanceEdit" style="width: 24px; height: 24px;">
                        <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                    </div>
                </div>
            </div>
            <div v-else class="guidance-content">{{ currentGuidance.text }}</div>
        </div>

        <!-- Reasoning Block -->
        <div v-if="message.reasoning" class="msg-reasoning collapsed">
            <div class="msg-reasoning-header" @click="$event.target.closest('.msg-reasoning').classList.toggle('collapsed')">
                <span>Reasoning</span>
                <svg class="reasoning-arrow" viewBox="0 0 24 24" style="width:16px;height:16px;fill:currentColor"><path d="M7 10l5 5 5-5z"/></svg>
            </div>
            <div class="msg-reasoning-content">
                <div class="msg-transition-wrapper" style="min-height: 0;">
                    <Transition :name="message.swipeDirection || 'slide-next'">
                        <ShadowContent 
                            class="msg-reasoning-inner" 
                            :key="(message.swipeId || 0) + '-' + (message.greetingIndex || 0)" 
                            :html="formatText(message.reasoning)" 
                            :is-selected="isSelected"
                        />
                    </Transition>
                </div>
            </div>
        </div>

        <div class="msg-transition-wrapper">
            <Transition :name="message.swipeDirection || 'slide-next'">
                <!-- Edit Mode -->
                <div class="msg-body" v-if="message.isEditing" key="edit">
                    <textarea 
                        v-model="message.editText" 
                        class="edit-textarea" 
                        rows="1" 
                        @vue:mounted="({ el }) => focusAndResize(el)"
                    ></textarea>
                </div>

                <!-- Normal Text -->
                <div 
                    class="msg-body" 
                    v-else-if="message.text || (!message.isTyping && !message.text)" 
                    :key="(message.swipeId || 0) + '-' + (message.greetingIndex || 0)"
                    @click="handleContentClick"
                >
                    <div v-if="message.isError" class="error-window">
                        <div class="error-header">
                            <span>ERROR</span>
                            <span v-if="blacklistedErrorProvider" class="error-provider-chip">{{ blacklistedErrorProvider.name }} API</span>
                            <div class="error-copy-btn" @click.stop="copyErrorText(message.text)">
                                <svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
                            </div>
                        </div>
                        <ShadowContent class="error-content" :html="formatMessageText(message.text)" :is-selected="isSelected" />
                    </div>
                    <template v-else>
                        <ShadowContent :html="combinedMessageData.html" :is-selected="isSelected" />
                    </template>
                    
                    <div v-if="message.image" class="msg-image-attachment" :class="{ 'image-hidden': message.imageHidden }">
                        <img :src="message.image" alt="Attached image" @click.stop="openImage(message.image)" />
                        <div class="image-ctx-toggle" @click.stop="emit('toggle-image-hidden')" :title="message.imageHidden ? 'Include image in context' : 'Exclude image from context'">
                            <svg v-if="message.imageHidden" viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>
                            <svg v-else viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>
                        </div>
                    </div>

                    <div v-if="layoutMode === 'bubble'" class="bubble-meta">
                        <span class="msg-index gen-stat" v-if="!uiHideMsgId">#{{ index + 1 }}</span>
                        
                        <div class="gen-stat" v-if="((!uiHideGenTime && message.genTime && message.genTime !== '0s') || (!uiHideTokenCnt && tokenCount > 0)) && index > 0" style="margin-right: auto;">
                            <template v-if="!uiHideGenTime && message.genTime && message.genTime !== '0s'">
                                <svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:2px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>
                                <div class="gen-time-wrapper">
                                    <RollingNumber class="gen-time" :value="message.genTime" />
                                </div>
                            </template>
                            <Transition name="fade">
                                <div class="token-count-inline" v-if="!uiHideTokenCnt && tokenCount > 0 && !isGenerating" style="display: flex; align-items: center;" :style="(!uiHideGenTime && message.genTime && message.genTime !== '0s') ? 'margin-left: 6px;' : ''" :title="t('label_tokens') || 'Tokens'">
                                    <svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:2px;"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                    <span>{{ tokenCount }}t</span>
                                </div>
                            </Transition>
                        </div>

                        <span class="bubble-time" :style="!(((!uiHideGenTime && message.genTime && message.genTime !== '0s') || (!uiHideTokenCnt && tokenCount > 0))) ? 'margin-left: auto;' : ''">
                            <svg v-if="message.isHidden" class="msg-hidden-badge" viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>
                            {{ message.time }}
                        </span>
                    </div>
                </div>
                
                <!-- Typing Indicator -->
                <div class="msg-body" v-else key="typing">
                    <div class="typing-container">
                        <svg class="typing-icon" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                        <span class="typing-text">{{ t('model_typing') }}</span>
                    </div>
                    
                    <div v-if="layoutMode === 'bubble'" class="bubble-meta">
                        <span class="msg-index gen-stat" v-if="!uiHideMsgId">#{{ index + 1 }}</span>
                        
                        <div class="gen-stat" v-if="(!uiHideGenTime && message.genTime && message.genTime !== '0s') || (!uiHideTokenCnt && tokenCount > 0)" style="margin-right: auto;">
                            <template v-if="!uiHideGenTime && message.genTime && message.genTime !== '0s'">
                                <svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:2px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>
                                <div class="gen-time-wrapper">
                                    <RollingNumber class="gen-time" :value="message.genTime" />
                                </div>
                            </template>
                            <Transition name="fade">
                                <div class="token-count-inline" v-if="!uiHideTokenCnt && tokenCount > 0 && !isGenerating" style="display: flex; align-items: center;" :style="(!uiHideGenTime && message.genTime && message.genTime !== '0s') ? 'margin-left: 6px;' : ''" :title="t('label_tokens') || 'Tokens'">
                                    <svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:2px;"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                                    <span>{{ tokenCount }}t</span>
                                </div>
                            </Transition>
                        </div>

                        <span class="bubble-time" :style="!((!uiHideGenTime && message.genTime && message.genTime !== '0s') || (!uiHideTokenCnt && tokenCount > 0)) ? 'margin-left: auto;' : ''">
                            {{ message.time }}
                        </span>
                    </div>
                </div>
            </Transition>
        </div>

        <div class="msg-footer" v-if="showFooter">
            <div class="msg-meta">
                <div class="gen-stat" v-if="((!uiHideGenTime && message.genTime && message.genTime !== '0s') || (!uiHideTokenCnt && tokenCount > 0))">
                    <template v-if="!uiHideGenTime && message.genTime && message.genTime !== '0s'">
                        <svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:4px;"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>
                        <div class="gen-time-wrapper">
                            <RollingNumber class="gen-time" :value="message.genTime" />
                        </div>
                    </template>
                    <Transition name="fade">
                        <div class="token-count-inline" v-if="!uiHideTokenCnt && tokenCount > 0 && !isGenerating" style="display: flex; align-items: center;" :style="(!uiHideGenTime && message.genTime && message.genTime !== '0s') ? 'margin-left: 6px;' : ''" :title="t('label_tokens') || 'Tokens'">
                            <svg viewBox="0 0 24 24" style="width:12px;height:12px;fill:currentColor;margin-right:2px;"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>
                            <span>{{ tokenCount }}t</span>
                        </div>
                    </Transition>
                </div>
            </div>

            <div class="msg-center-controls">
                <!-- Swipe Switcher -->
                <div class="msg-switcher" v-if="message.role === 'char' && message.swipes && message.swipes.length > 1">
                    <div class="msg-switcher-btn prev" @click.stop="emit('swipe', -1)">
                        <svg viewBox="0 0 24 24"><path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg>
                    </div>
                    <div class="msg-switcher-count">
                        <Transition :name="message.swipeDirection || 'slide-next'" mode="out-in">
                            <span :key="message.swipeId || 0" style="display: inline-block; min-width: 24px; text-align: center;">{{ (message.swipeId || 0) + 1 }}/{{ message.swipes.length }}</span>
                        </Transition>
                    </div>
                    <div class="msg-switcher-btn next" @click.stop="emit('swipe', 1)">
                        <svg viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>
                    </div>
                </div>
                
                <!-- Greeting Switcher -->
                <div class="msg-switcher" v-else-if="index === 0 && message.role === 'char' && getAllGreetings(activeChatChar).length > 1">
                    <div class="msg-switcher-btn prev" @click.stop="emit('change-greeting', -1)">
                        <svg viewBox="0 0 24 24"><path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg>
                    </div>
                    <div class="msg-switcher-count">
                        <Transition :name="message.swipeDirection || 'slide-next'" mode="out-in">
                            <span :key="message.greetingIndex || 0" style="display: inline-block; min-width: 24px; text-align: center;">{{ (message.greetingIndex || 0) + 1 }}/{{ getAllGreetings(activeChatChar).length }}</span>
                        </Transition>
                    </div>
                    <div class="msg-switcher-btn next" @click.stop="emit('change-greeting', 1)">
                        <svg viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>
                    </div>
                </div>

                <div v-if="layoutMode === 'bubble' && (message.triggeredLorebooks?.length || combinedMessageData.regexes?.length)" class="msg-lb-trigger-menu" @click.stop="openTriggeredSheet">
                    <svg viewBox="0 0 24 24"><path d="M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z"/></svg>
                </div>

                <div class="msg-guided-swipe-btn" v-if="message.role === 'char' && !isGenerating && !message.isEditing && isLast" :class="{ 'active': isGuidedSwipeOpen }" @click.stop="toggleGuidedSwipe" :title="t('guided_swipe') || 'Guided Swipe'">
                    <svg viewBox="0 0 24 24"><path d="M9 5v2h6.59L4 18.59 5.41 20 17 8.41V15h2V5H9z"/></svg>
                </div>

                <!-- Regenerate Button (User or Error) -->
                <div class="msg-regenerate" v-if="((message.role === 'user' && isLast) || message.isError) && !isGenerating && !message.isEditing" @click.stop="emit('regenerate', 'magic')" :class="{'icon-only': (message.role === 'char' && ((message.swipes && message.swipes.length > 1) || (index === 0 && getAllGreetings(activeChatChar).length > 1)))}">
                    <svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
                    <span v-if="!(message.role === 'char' && ((message.swipes && message.swipes.length > 1) || (index === 0 && getAllGreetings(activeChatChar).length > 1)))">{{ t('magic_regenerate') }}</span>
                </div>
            </div>

            <!-- Edit Buttons -->
            <div class="edit-buttons" v-if="message.isEditing">
                <div class="edit-btn cancel" :title="t('btn_cancel')" @click.stop="emit('cancel-edit')">
                    <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                </div>
                <div class="edit-btn save" :title="t('btn_save')" @click.stop="emit('save-edit')">
                    <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                </div>
            </div>

            <!-- Action Button -->
            <div class="msg-actions-btn" v-else-if="!isSelectionMode" @click.stop="emit('open-actions')">
                <svg viewBox="0 0 24 24"><path d="M3 18h18v-2H3v2zm0-5h18v-2H3v2zm0-7v2h18V6H3z"/></svg>
            </div>

        </div>

        <div class="guided-swipe-container" v-if="isGuidedSwipeOpen">
            <div class="guidance-main">
                <div class="guidance-header">{{ t('guided_swipe') || 'GUIDED SWIPE' }}</div>
                <textarea 
                    class="guided-swipe-textarea"
                    v-model="guidedSwipeText"
                    :placeholder="t('guided_swipe_placeholder') || 'Enter OOC instruction for swipe...'"
                    rows="1"
                    ref="guidedSwipeInput"
                ></textarea>
            </div>
            <div class="guided-swipe-actions">
                <div class="guided-btn cancel" @click.stop="toggleGuidedSwipe">
                    <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                </div>
                <div class="guided-btn confirm" @click.stop="submitGuidedSwipe">
                    <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                </div>
            </div>
        </div>
    </div>

    <!-- Triggered Items Sheet -->
    <SheetView ref="triggeredItemsSheet" fit-content :title="t('sheet_triggered_items') || 'Triggered Items'">
        <div class="triggered-items-list">
            <div v-if="message.triggeredLorebooks?.length" class="triggered-group">
                <div class="triggered-group-title">{{ t('menu_lorebooks') || 'World Info' }}</div>
                <div v-for="lb in message.triggeredLorebooks" :key="lb.id" class="triggered-item-card" @click="openLorebookEntry(lb)">
                    <div class="item-icon">
                        <svg viewBox="0 0 24 24"><path d="M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z"/></svg>
                    </div>
                    <div class="item-info">
                        <div class="item-label">{{ lb.name }}</div>
                        <div class="item-sublabel">{{ lb.lorebookName }}</div>
                    </div>
                </div>
            </div>
            
            <div v-if="combinedMessageData.regexes?.length" class="triggered-group">
                <div class="triggered-group-title">{{ t('menu_regex') || 'Regex Extensions' }}</div>
                <div v-for="(r, idx) in combinedMessageData.regexes" :key="idx" class="triggered-item-card static">
                    <div class="item-icon">
                        <svg viewBox="0 0 24 24"><path d="M14.6 16.6l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4m-5.2 0L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4z"/></svg>
                    </div>
                    <div class="item-info">
                        <div class="item-label">{{ r.name || 'Unnamed Script' }}</div>
                        <div class="item-sublabel">{{ r.regex ? `/${r.regex}/` : 'Trim Out' }}</div>
                    </div>
                </div>
            </div>
        </div>
    </SheetView>
</template>

<style scoped>
.msg-image-attachment {
    margin-top: 8px;
    border-radius: 12px;
    overflow: hidden;
    max-width: 100%;
    position: relative;
    display: inline-block;
}
.msg-image-attachment img {
    max-width: 100%;
    max-height: 300px;
    border-radius: 12px;
    display: block;
    object-fit: cover;
    transition: opacity 0.25s;
    cursor: pointer;
}
.msg-image-attachment.image-hidden img {
    opacity: 0.35;
}
.image-ctx-toggle {
    position: absolute;
    top: 6px;
    right: 6px;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    background: rgba(0,0,0,0.55);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    transition: background 0.2s;
    z-index: 2;
}
.image-ctx-toggle:active {
    background: rgba(0,0,0,0.75);
}
.image-ctx-toggle svg {
    width: 16px;
    height: 16px;
    fill: #fff;
}

.message-section {
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    transition: background-color 0.3s ease;
    position: relative;
    user-select: none;
    -webkit-user-select: none;
    --current-quote-color: var(--char-quote-color, var(--vk-blue));
    --current-text-color: var(--char-text-color, inherit);
    --current-italic-color: var(--char-italic-color, #888);
}

.message-section.user {
    --current-quote-color: var(--user-quote-color, var(--vk-blue));
    --current-text-color: var(--user-text-color, inherit);
    --current-italic-color: var(--user-italic-color, #888);
}

.message-section.selected {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15) !important;
    user-select: text;
    -webkit-user-select: text;
}

.message-section.selection-mode {
    cursor: pointer;
}

.message-section.msg-hidden .msg-body {
    opacity: 0.45;
}

.msg-hidden-badge {
    width: 12px;
    height: 12px;
    fill: currentColor;
    opacity: 0.6;
    vertical-align: middle;
    margin-right: 2px;
}

.msg-header {
    display: flex;
    align-items: center;
    margin-bottom: 6px;
}

.msg-avatar {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    margin-right: 10px;
    object-fit: cover;
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 12px;
}

.msg-name {
    font-weight: 500;
    font-size: 14px;
    color: var(--text-dark-gray);
    display: inline-flex;
    align-items: center;
    gap: 8px;
}

.msg-index.header-idx {
    font-weight: normal;
    opacity: 0.6;
}

.msg-lb-trigger-menu {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    cursor: pointer;
    color: var(--text-gray);
    background-color: rgba(var(--ui-bg-rgb), 0.5);
    border: 1px solid #555555;
    border-radius: 6px;
    transition: all 0.2s;
    flex-shrink: 0;
}

.msg-lb-trigger-menu:hover {
    background-color: rgba(var(--ui-bg-rgb), 0.8);
    color: var(--text-black);
}

.msg-lb-trigger-menu svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.triggered-sheet-header {
    padding: 0 20px 10px;
}

.triggered-sheet-header h3 {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    color: var(--text-black);
}

.triggered-items-list {
    padding: 16px 16px 20px;
    display: flex;
    flex-direction: column;
    gap: 16px;
}

.triggered-group {
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.triggered-group-title {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-gray);
    text-transform: uppercase;
    letter-spacing: 0.5px;
    padding-left: 4px;
}

.triggered-item-card {
    display: flex;
    align-items: center;
    padding: 10px 12px;
    background: var(--menu-group-bg, rgba(0, 0, 0, 0.02));
    border: 1px solid #555555;
    border-radius: 12px;
    gap: 12px;
    cursor: pointer;
    transition: background 0.2s;
}

.triggered-item-card:not(.static):active {
    background: rgba(var(--vk-blue-rgb), 0.1);
}

.triggered-item-card.static {
    cursor: default;
}

.item-icon {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(var(--vk-blue-rgb), 0.1);
    color: var(--vk-blue);
    border-radius: 8px;
    flex-shrink: 0;
}

.item-icon svg {
    width: 18px;
    height: 18px;
    fill: currentColor;
}

.item-info {
    display: flex;
    flex-direction: column;
    min-width: 0;
}

.item-label {
    font-size: 14px;
    font-weight: 500;
    color: var(--text-black);
}

.item-sublabel {
    font-size: 12px;
    color: var(--text-gray);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.msg-time {
    margin-left: auto;
    font-size: 12px;
    color: var(--text-gray);
}

.msg-body {
    position: relative;
    font-size: var(--chat-font-size, 15px);
    letter-spacing: var(--chat-letter-spacing, 0px);
    line-height: 1.5;
    color: var(--current-text-color, var(--text-black));
    width: 100%;
    max-width: 100%;
    min-width: 0;
}

.msg-footer {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    min-height: 28px;
    margin-top: 4px;
}

.msg-meta {
    display: flex;
    align-items: center;
    gap: 6px;
}

.msg-index, .gen-stat {
    font-size: 11px;
    color: var(--text-gray);
    display: flex;
    align-items: center;
}

.msg-switcher {
    display: flex;
    align-items: center;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 12px;
    padding: 2px 6px;
    font-size: 11px;
    color: var(--text-gray);
    gap: 4px;
    height: 22px;
}

.msg-switcher-btn {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    opacity: 0.7;
}
.msg-switcher-btn svg { width: 16px; height: 16px; fill: currentColor; }

.msg-center-controls {
    display: flex;
    align-items: center;
    gap: 8px;
    justify-content: center;
}

.msg-regenerate {
    display: flex;
    align-items: center;
    justify-content: center;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 12px;
    padding: 2px 8px;
    font-size: 11px;
    color: var(--text-gray);
    gap: 4px;
    height: 22px;
    cursor: pointer;
}
.msg-regenerate svg { width: 14px; height: 14px; fill: currentColor; }

.msg-guided-swipe-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 12px;
    padding: 2px 6px;
    color: var(--text-gray);
    height: 22px;
    cursor: pointer;
    transition: all 0.2s;
}
.msg-guided-swipe-btn.active {
    background-color: var(--vk-blue);
    color: white;
    border-color: var(--vk-blue);
}
.msg-guided-swipe-btn svg { width: 14px; height: 14px; fill: currentColor; }

.msg-actions-btn {
    justify-self: end;
    padding: 4px;
    cursor: pointer;
    color: var(--text-gray);
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    grid-column: 3;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 50%;
}
.msg-actions-btn svg { width: 20px; height: 20px; fill: currentColor; }

/* Reasoning */
.msg-reasoning {
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 12px;
    margin-bottom: 8px;
    overflow: hidden;
}

.msg-reasoning-content {
    display: grid;
    grid-template-rows: 1fr;
    transition: grid-template-rows 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}

.msg-reasoning-content .msg-transition-wrapper { overflow: hidden; }
.msg-reasoning.collapsed .msg-reasoning-content { grid-template-rows: 0fr; }

.msg-reasoning-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 12px;
    cursor: pointer;
    font-size: 0.85em;
    color: var(--text-gray);
    font-weight: 600;
    background-color: rgba(0, 0, 0, 0.02);
    transition: background-color 0.2s;
    border-bottom: 1px solid rgba(0, 0, 0, 0.05);
}
.msg-reasoning-inner {
    padding: 8px 10px;
    font-size: 0.9em;
    color: var(--text-gray);
    font-style: italic;
    overflow: hidden;
}

.msg-reasoning.collapsed .msg-reasoning-header {
    border-bottom-color: transparent;
}

.reasoning-arrow {
    transition: transform 0.3s ease;
}
.msg-reasoning.collapsed .reasoning-arrow {
    transform: rotate(-90deg);
}

/* Edit */
.edit-textarea {
    display: block;
    color: var(--text-black);
    width: 100%;
    max-width: 100%;
    background: rgba(0, 0, 0, 0.05);
    border: 1px solid var(--border-color);
    padding: 8px;
    font-family: inherit;
    font-size: inherit;
    resize: none;
    outline: none;
    field-sizing: content;
}
.edit-buttons { 
    display: flex; 
    justify-self: end; 
    gap: 8px; 
    grid-column: 3; 
}
.edit-btn { 
    width: 28px; 
    height: 28px; 
    display: flex; 
    align-items: center; 
    justify-content: center; 
    border-radius: 50%; 
    cursor: pointer;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    transition: all 0.2s ease;
}
.edit-btn:active {
    transform: scale(0.9);
    background-color: rgba(var(--ui-bg-rgb), 1);
}
.edit-btn svg { width: 16px; height: 16px; }
.edit-btn.save svg { fill: #4CAF50; }
.edit-btn.cancel svg { fill: #ff4444; }

/* Guided Swipe Inline Block */
.guided-swipe-container {
    margin-top: 8px;
    margin-bottom: 4px;
    background: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.9));
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    border: 1px solid var(--border-color, rgba(0,0,0,0.05));
    border-radius: 28px !important;
    padding: 8px 12px;
    display: flex;
    gap: 8px;
    align-items: center;
    animation: slideDownFade 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.guidance-main {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
}

.guidance-header {
    font-size: 10px;
    font-weight: 700;
    color: var(--vk-blue);
    letter-spacing: 0.5px;
    margin-bottom: 2px;
    text-transform: uppercase;
}

.guided-swipe-textarea {
    width: 100%;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-black);
    font-size: 14px;
    font-family: inherit;
    resize: none;
    field-sizing: content;
    padding: 4px 0;
    max-height: 120px;
    min-height: 20px;
}
.guided-swipe-textarea::-webkit-scrollbar { display: none; }
.guided-swipe-textarea { -ms-overflow-style: none; scrollbar-width: none; }
.guided-swipe-textarea::placeholder { color: var(--text-gray); }

.guided-swipe-actions {
    display: flex;
    gap: 8px;
}
.guided-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    cursor: pointer;
    background-color: rgba(255, 255, 255, 0.03);
    transition: all 0.2s ease;
}
.guided-btn:active { transform: scale(0.9); background-color: rgba(255, 255, 255, 0.1); }
.guided-btn.confirm { color: #4CAF50; }
.guided-btn.cancel { color: #ff4444; }
.guided-btn svg { width: 16px; height: 16px; fill: currentColor; }
.guided-swipe-textarea { color: var(--text-black); }

/* Message Styles */
.msg-body { color: var(--current-text-color, #e1e3e6); }
.message-section.selected .msg-body { user-select: text; -webkit-user-select: text; }
.msg-switcher { border-color: rgba(255, 255, 255, 0.1); }
.msg-regenerate { border-color: rgba(255, 255, 255, 0.1); color: var(--text-gray); }
.edit-textarea { background: rgba(255, 255, 255, 0.05); color: var(--text-black); }
.msg-actions-btn { border-color: rgba(255, 255, 255, 0.1); }
.msg-reasoning { border-color: rgba(255, 255, 255, 0.1); }
.msg-reasoning-header { border-bottom-color: rgba(255, 255, 255, 0.1); }

/* Swipe Animations */
.slide-next-enter-active, .slide-next-leave-active,
.slide-prev-enter-active, .slide-prev-leave-active {
  transition: all 0.2s ease;
}
.slide-next-enter-from { transform: translateX(10px); opacity: 0; }
.slide-next-leave-to { transform: translateX(-10px); opacity: 0; }
.slide-prev-enter-from { transform: translateX(-10px); opacity: 0; }
.slide-prev-leave-to { transform: translateX(10px); opacity: 0; }

.fade-enter-active, .fade-leave-active {
  transition: opacity 0.3s ease;
}
.fade-enter-from, .fade-leave-to {
  opacity: 0;
}

/* Error State (Glassmorphism) */
.message-section.error {
    background-color: transparent;
    border-left: none;
}

.message-section.error .msg-body {
    padding: 0;
    background: transparent;
}

.error-window {
    display: block;
    margin-top: 6px;
    background-color: rgba(43, 14, 14, 0.85);
    backdrop-filter: blur(10px);
    -webkit-backdrop-filter: blur(10px);
    border: 1px solid #ff3b30;
    border-radius: 8px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
    overflow: hidden;
}

.error-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background-color: rgba(255, 59, 48, 0.2);
    padding: 6px 12px;
    border-bottom: 1px solid rgba(255, 59, 48, 0.3);
}

.error-header span {
    color: #ff3b30;
    font-size: 10px;
    font-weight: bold;
    letter-spacing: 1px;
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
}

.error-copy-btn {
    cursor: pointer;
    color: #ff3b30;
    opacity: 0.7;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2px;
    border-radius: 4px;
    transition: all 0.2s;
}

.error-copy-btn:hover {
    opacity: 1;
    background-color: rgba(255, 59, 48, 0.1);
}

.error-copy-btn svg {
    width: 14px;
    height: 14px;
    fill: currentColor;
}

.error-content {
    padding: 10px 12px;
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    font-size: 12px;
    color: #ffb3b3;
    white-space: pre-wrap;
    word-break: break-word;
}

.message-section.error .msg-name {
    color: #ff3b30;
}

.message-section.error {
    background-color: transparent;
    border-left: none;
}



.error-provider-chip {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: 10px;
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 0.5px;
    text-transform: uppercase;
    white-space: nowrap;
    flex-shrink: 0;
    margin-left: auto;
    margin-right: 8px;
    background-color: rgba(255, 59, 48, 0.2);
    color: #ff453a;
    border: 1px solid rgba(255, 59, 48, 0.35);
}



.message-section.error .msg-name {
    color: #ff453a;
}

/* Typing Dots for Chat Message & Impersonation */
.msg-body :deep(.typing-dots-bounce) {
    display: inline-block;
    margin-left: 4px;
}

.msg-body :deep(.typing-dots-bounce span) {
    display: inline-block;
    animation: dotBounce 1.4s infinite ease-in-out both;
    color: var(--text-gray);
    font-size: 1.4em;
    line-height: 10px;
    vertical-align: middle;
}

.msg-body :deep(.typing-dots-bounce span:nth-child(1)) { animation-delay: -0.32s; }
.msg-body :deep(.typing-dots-bounce span:nth-child(2)) { animation-delay: -0.16s; }

@keyframes dotBounce {
    0%, 80%, 100% { transform: translateY(0); opacity: 0.5; }
    40% { transform: translateY(-5px); opacity: 1; }
}

:deep(.search-highlight-text) {
    background-color: rgba(255, 215, 0, 0.4);
    border-radius: 4px;
    padding: 0 2px;
}

:deep(.search-highlight-text.active-search-match) {
    background-color: rgba(244, 67, 54, 0.8);
    color: #fff;
    border-radius: 4px;
    padding: 0 2px;
}



:global(.search-highlight) {
    background-color: rgba(var(--vk-blue-rgb), 0.1) !important;
    transition: background-color 0.3s ease;
}

.msg-transition-wrapper {
    display: grid;
    align-items: start;
    width: 100%;
    min-width: 0;
}
.msg-transition-wrapper > * {
    grid-area: 1 / 1;
    width: 100%;
}

/* --- Bubble Layout Styles --- */
.message-section.layout-bubble {
    background-color: transparent;
    padding: 8px 16px;
}
.message-section.layout-bubble.selected {
    background-color: rgba(var(--vk-blue-rgb, 82, 139, 204), 0.15) !important;
}
.message-section.layout-bubble.selected .msg-body {
    box-shadow: 0 0 0 2px var(--vk-blue);
}
.message-section.layout-bubble .msg-name,
.message-section.layout-bubble .msg-avatar,
.message-section.layout-bubble .msg-header .msg-time,
.message-section.layout-bubble .msg-footer .msg-index,
.message-section.layout-bubble .msg-footer .gen-stat,
.message-section.layout-bubble .msg-actions-btn {
    display: none !important;
}
.message-section.layout-bubble .msg-header {
    margin-bottom: 4px;
}
.message-section.layout-bubble.user .msg-header {
    flex-direction: row-reverse;
}
.message-section.layout-bubble .msg-body {
    background-color: rgba(var(--char-bubble-color-rgb, var(--vk-blue-rgb)), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 18px;
    border-top-left-radius: 4px;
    padding: 10px 14px 6px 14px;
    width: fit-content;
    max-width: 88%;
    margin-left: 0;
    cursor: pointer;
    min-width: 0;
    display: flex;
    flex-direction: column;
}
.message-section.layout-bubble.user .msg-body {
    background-color: rgba(var(--user-bubble-color-rgb, var(--ui-bg-rgb)), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 18px;
    border-top-right-radius: 4px;
    margin-left: auto;
    margin-right: 0;
}
.message-section.layout-bubble .bubble-meta {
    display: flex;
    justify-content: flex-start;
    align-items: center;
    gap: 8px;
    margin-top: 4px;
    font-size: 11px;
    color: var(--text-gray);
    opacity: 0.8;
}
.message-section.layout-bubble .bubble-time {
    display: flex;
    align-items: center;
    gap: 4px;
}
.message-section.layout-bubble .msg-footer {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-start;
    margin-left: 0;
    gap: 8px;
}
.message-section.layout-bubble.user .msg-footer {
    justify-content: flex-end;
    margin-left: 0;
    margin-right: 0;
}
.message-section.layout-bubble .msg-reasoning {
    margin-left: 0;
    max-width: 88%;
    border-radius: 18px;
    border-top-left-radius: 4px;
}
.message-section.layout-bubble.user .msg-reasoning {
    margin-left: auto;
    margin-right: 0;
    border-radius: 18px;
    border-top-right-radius: 4px;
}
.message-section.layout-bubble.msg-hidden .msg-body {
    opacity: 0.45;
}

/* Guidance Block Styling */
.msg-guidance-block {
    margin-bottom: 8px;
    padding: 6px 10px;
    border-left: 2px solid var(--vk-blue);
    background: rgba(var(--vk-blue-rgb), 0.1);
    border-radius: 4px;
    font-size: 13px;
    width: fit-content;
    max-width: 100%;
}
.guidance-label {
    font-size: 10px;
    font-weight: 700;
    color: var(--vk-blue);
    margin-bottom: 2px;
    letter-spacing: 0.5px;
    text-transform: uppercase;
}
.guidance-content {
    color: #ccc;
    line-height: 1.4;
    font-size: 12px;
    font-style: italic;
}

.imggen-rolling-overlay {
    position: absolute;
    top: 8px;
    right: 8px;
    font-size: 11px;
    font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
    color: rgba(128,128,128,0.8);
    background: rgba(0,0,0,0.45);
    border-radius: 8px;
    padding: 2px 6px;
    z-index: 2;
    pointer-events: none;
}
</style>