<script setup>
import { ref, watch, nextTick, onMounted, onBeforeUnmount, computed } from 'vue';
import { formatInputPreview } from '@/utils/textFormatter.js';
import RequestPreviewSheet from '@/components/sheets/RequestPreviewSheet.vue';
import MagicDrawer from '@/components/chat/MagicDrawer.vue';
import { translations } from '@/utils/i18n.js';
import { currentLang, enterToSubmit } from '@/core/config/APPSettings.js';
import { hideKeyboard, onKeyboardShow, onKeyboardHide, isNativeKeyboard } from '@/core/services/keyboardHandler.js';
import { Capacitor } from '@capacitor/core';
import { attachRipple } from '@/core/services/ui.js';

const props = defineProps({
    modelValue: { type: String, default: '' },
    isGenerating: { type: Boolean, default: false },
    isImpersonating: { type: Boolean, default: false },
    showScrollButton: { type: Boolean, default: false },
    canRegenerate: { type: Boolean, default: false },
    isSearchMode: { type: Boolean, default: false },
    searchMatchCurrent: { type: Number, default: 0 },
    searchMatchTotal: { type: Number, default: 0 },
    isSelectionMode: { type: Boolean, default: false },
    selectedCount: { type: Number, default: 0 },
    activeChar: { type: Object, default: null }
});

const emit = defineEmits([
    'update:modelValue', 'send', 'scroll-to-bottom', 
    'magic-regenerate', 'magic-impersonate', 'magic-notes', 'magic-context', 'magic-stats', 'magic-sessions', 'magic-summary', 'magic-api', 'magic-presets', 'magic-char-card', 'magic-lorebooks', 'magic-memory-books', 'magic-regex', 'magic-image-gen', 'magic-glossary',
    'search-next', 'search-prev', 'delete-selected', 'hide-selected', 'cancel-selection', 'create-memory-selected', 'remove-memory-selected', 'configure-memory-selected', 'generate-memory-draft-selected'
]);

const t = (key) => translations[currentLang.value]?.[key] || key;

const chatInput = ref(null);
const isComposing = ref(false);
const isMagicMenuVisible = ref(false);
const magicDrawerRef = ref(null);
const isKeyboardOpen = ref(document.body.classList.contains('keyboard-open'));
const isSwitchingToDrawer = ref(false);
const inputWrapper = ref(null);
const kbListeners = [];
const isMainFocused = ref(false);
const isGuidanceFocused = ref(false);

const isGuidanceMode = ref(false);
const guidanceType = ref('send');
const guidanceText = ref('');
const guidanceInput = ref(null);

const closeGuidance = () => {
    if (guidanceText.value.trim() !== '') {
        const confirmMsg = t('confirm_discard_changes') || 'Discard changes?';
        if (!confirm(confirmMsg)) return;
    }
    isGuidanceMode.value = false;
    guidanceText.value = '';
};

const toggleGuidanceMode = () => {
    if (isGuidanceMode.value && guidanceType.value === 'send') {
        closeGuidance();
    } else {
        isGuidanceMode.value = true;
        guidanceType.value = 'send';
        nextTick(() => { if (guidanceInput.value) guidanceInput.value.focus(); });
    }
};

const currentAction = computed(() => {
    if (props.isGenerating) return 'stop';
    if ((props.modelValue && props.modelValue.trim()) || attachedImage.value) return 'send';
    return 'impersonate';
});

const attachedImage = ref(null);
const imageInput = ref(null);

const triggerImageUpload = () => {
    if (imageInput.value) imageInput.value.click();
};

const onImageSelected = (event) => {
    const file = event.target.files[0];
    if (file) {
        const reader = new FileReader();
        reader.onload = (e) => {
            attachedImage.value = e.target.result;
        };
        reader.readAsDataURL(file);
    }
    if (imageInput.value) imageInput.value.value = '';
};

const clearImage = () => {
    attachedImage.value = null;
};

const handleSend = () => {
    if (props.isGenerating) {
        emit('send');
    } else if ((props.modelValue && props.modelValue.trim()) || attachedImage.value) {
        emit('send', attachedImage.value, guidanceText.value);
        attachedImage.value = null;
        closeGuidance();
    } else {
        if (!isGuidanceMode.value || guidanceType.value !== 'impersonate') {
            isGuidanceMode.value = true;
            guidanceType.value = 'impersonate';
            nextTick(() => { if (guidanceInput.value) guidanceInput.value.focus(); });
        } else {
            emit('magic-impersonate', guidanceText.value);
            closeGuidance();
        }
    }
};


const requestPreviewSheet = ref(null);

const openRequestPreview = () => {
    if (requestPreviewSheet.value) requestPreviewSheet.value.open();
};

// Keyboard listeners are set up in onMounted and cleaned up in onBeforeUnmount

// --- Input Logic ---
function getCaretIndex(element) {
    let position = 0;
    try {
        const selection = window.getSelection?.();
        if (!selection || selection.rangeCount === 0) return position;
        const range = selection.getRangeAt(0);
        if (!range) return position;
        const preCaretRange = range.cloneRange();
        preCaretRange.selectNodeContents(element);
        preCaretRange.setEnd(range.endContainer, range.endOffset);
        const tempDiv = document.createElement('div');
        tempDiv.appendChild(preCaretRange.cloneContents());
        const visualBrs = tempDiv.querySelectorAll('.visual-br');
        visualBrs.forEach(br => br.remove());
        const brs = tempDiv.querySelectorAll('br');
        brs.forEach(br => {
            const textNode = document.createTextNode('\n');
            br.parentNode.replaceChild(textNode, br);
        });
        let text = tempDiv.textContent || '';
        text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
        position = text.length;
    } catch (e) {
        // Selection API can throw on iOS/WKWebView during keyboard transitions
    }
    return position;
}

function setCaretPosition(element, pos) {
    try {
        const sel = window.getSelection?.();
        if (!sel) return;
        const range = document.createRange();
        let currentPos = 0;
        function traverse(node) {
            if (node.nodeType === 3) {
                const len = node.nodeValue.length;
                if (currentPos + len >= pos) {
                    range.setStart(node, pos - currentPos);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    return true;
                }
                currentPos += len;
            } else if (node.nodeName === 'BR') {
                if (node.classList.contains('visual-br')) return false;
                if (currentPos === pos) {
                    const index = Array.from(node.parentNode.childNodes).indexOf(node);
                    range.setStart(node.parentNode, index);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    return true;
                }
                currentPos += 1;
                if (currentPos === pos) {
                    const index = Array.from(node.parentNode.childNodes).indexOf(node);
                    range.setStart(node.parentNode, index + 1);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    return true;
                }
            } else {
                for (let i = 0; i < node.childNodes.length; i++) {
                    if (traverse(node.childNodes[i])) return true;
                }
            }
            return false;
        }
        if (!traverse(element)) {
            range.selectNodeContents(element);
            range.collapse(false);
            sel.removeAllRanges();
            sel.addRange(range);
        }
    } catch (e) {
        // Selection API can throw on iOS/WKWebView during keyboard transitions
    }
}

function getTextFromContentEditable(el) {
    const clone = el.cloneNode(true);
    const hasVisualBr = !!clone.querySelector('.visual-br');
    const visualBrs = clone.querySelectorAll('.visual-br');
    visualBrs.forEach(br => br.remove());
    
    const originalText = clone.textContent || '';
    const brs = clone.querySelectorAll('br');
    brs.forEach(br => {
        const textNode = document.createTextNode('\n');
        br.parentNode.replaceChild(textNode, br);
    });
    
    let text = clone.textContent || '';
    text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    
    // If we have a single newline that came from a single <br>, 
    // and we didn't have a visual-br, it's likely a browser ghost.
    if (originalText === '' && text === '\n' && !hasVisualBr) {
        return '';
    }
    return text;
}

function onInput(e) {
    if (isComposing.value) return;
    try {
        const text = getTextFromContentEditable(e.target);
        if (text === '' && e.target.innerHTML !== '') {
            e.target.innerHTML = '';
        }
        emit('update:modelValue', text);
    } catch (err) {
        // Guard against DOM exceptions on iOS during keyboard transitions
    }
}

function onPaste(e) {
    e.preventDefault();
    const text = (e.clipboardData || window.clipboardData).getData('text/plain');
    document.execCommand('insertText', false, text);
}

function onKeyDown(e) {
    if (e.key === 'Enter') {
        const isMobile = Capacitor.isNativePlatform() || /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
        const shouldSend = (!isMobile && enterToSubmit.value) ? !e.shiftKey && !e.ctrlKey : (e.shiftKey || e.ctrlKey);
        
        if (shouldSend) {
            e.preventDefault();
            handleSend();
        } else {
            if (e.target.tagName && e.target.tagName.toLowerCase() === 'textarea') {
                return;
            }
            if (!props.isImpersonating) {
                e.preventDefault();
                const el = chatInput.value;
                if (!el) return;
                const caret = getCaretIndex(el);
                const text = props.modelValue || '';
                const before = text.slice(0, caret);
                const after = text.slice(caret);
                emit('update:modelValue', before + '\n' + after);
                nextTick(() => updateInputPreview(caret + 1));
            }
        }
    }
}

function updateInputPreview(forcedCaretPos = null) {
    if (!chatInput.value || isComposing.value) return;
    const el = chatInput.value;
    // Skip if element is detached from DOM (prevents iOS crash)
    if (!el.isConnected) return;
    const isActive = document.activeElement === el;
    const currentCaret = (isActive || forcedCaretPos !== null) ? (forcedCaretPos !== null ? forcedCaretPos : getCaretIndex(el)) : 0;
    
    let formatted = props.modelValue ? formatInputPreview(props.modelValue) : '';
    if (props.modelValue && props.modelValue.endsWith('\n')) {
        formatted += '<br class="visual-br">';
    }
    
    if (el.innerHTML !== formatted) {
        el.innerHTML = formatted;
        if (isActive || forcedCaretPos !== null) {
            nextTick(() => { if (el.isConnected && document.activeElement === el) setCaretPosition(el, currentCaret); });
        }
    } else if (forcedCaretPos !== null && isActive) {
        nextTick(() => { if (el.isConnected && document.activeElement === el) setCaretPosition(el, currentCaret); });
    }
}

watch(() => props.modelValue, (newVal) => {
    if (chatInput.value) {
        const currentText = getTextFromContentEditable(chatInput.value);
        if (currentText !== newVal || (newVal === '' && chatInput.value.innerHTML !== '')) {
            updateInputPreview();
        }
    }
});

const toggleMagicMenu = async () => {
    if (isMagicMenuVisible.value) {
        isMagicMenuVisible.value = false;
    } else {
        if (isKeyboardOpen.value || document.body.classList.contains('keyboard-open')) {
            isSwitchingToDrawer.value = true;
            await hideKeyboard();
        } else {
            isMagicMenuVisible.value = true;
        }
    }
};

const onFocus = () => {
    isMainFocused.value = true;
    // Close drawer when user focuses input to type
    // isMagicMenuVisible.value = false; // Don't close, let keyboard cover it
};

const onBlur = () => {
    isMainFocused.value = false;
};

const onGuidanceFocus = () => {
    isGuidanceFocused.value = true;
};

const onGuidanceBlur = () => {
    isGuidanceFocused.value = false;
};

const closeMagicMenu = (e) => {
    // Do not close if clicking on a bottom sheet (overlay or content)
    if (e && e.target && e.target.closest && e.target.closest('.modal-overlay')) {
        return;
    }
    isMagicMenuVisible.value = false; 
};

const openFullScreenEditor = async () => {
    if (isKeyboardOpen.value || document.body.classList.contains('keyboard-open')) {
        await hideKeyboard();
    }
    window.dispatchEvent(new CustomEvent('open-fs-request', {
        detail: {
            value: props.modelValue,
            onSave: (newVal) => {
                emit('update:modelValue', newVal);
            }
        }
    }));
};
onMounted(async () => {
    window.addEventListener('click', closeMagicMenu);
    
    if (inputWrapper.value) {
        attachRipple(inputWrapper.value);
    }
    
    // On mount: if the visual viewport is significantly smaller than the screen, the keyboard is open
    if (window.visualViewport && window.visualViewport.height < window.innerHeight * 0.75) {
        isKeyboardOpen.value = true;
        isMagicMenuVisible.value = false;
    }

    // Register keyboard listeners with proper lifecycle management
    if (Capacitor.isNativePlatform()) {
        kbListeners.push(await onKeyboardShow(() => {
            isKeyboardOpen.value = true;
            isMagicMenuVisible.value = false;
            isSwitchingToDrawer.value = false;
        }));
        kbListeners.push(await onKeyboardHide(() => { 
            isKeyboardOpen.value = false;
            if (isSwitchingToDrawer.value) {
                isMagicMenuVisible.value = true;
                isSwitchingToDrawer.value = false;
            } else {
                isMagicMenuVisible.value = false;
            }
        }));
    }
});
onBeforeUnmount(() => {
    window.removeEventListener('click', closeMagicMenu);
    kbListeners.forEach(l => l.remove());
    kbListeners.length = 0;
});

defineExpose({
    openPersonas: () => {
        isMagicMenuVisible.value = true;
        nextTick(() => {
            magicDrawerRef.value?.openPersonas();
        });
    }
});
</script>

<template>
    <div class="chat-input-container" :class="{ 'drawer-open': isMagicMenuVisible || isSwitchingToDrawer, 'keyboard-open': isKeyboardOpen }">
        <div class="chat-status-gradient-bottom"></div>
        <div v-if="!isSearchMode" id="scroll-to-bottom" class="scroll-bottom-btn" :class="{ visible: showScrollButton }" @click="emit('scroll-to-bottom')">
            <svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:currentColor"><path d="M12 16.17L5.59 9.76L7 8.35L12 13.35L17 8.35L18.41 9.76L12 16.17Z"/></svg>
        </div>
        <div class="chat-input-content">
            <div class="chat-input-bar" :class="{ 'mode-normal': !isSelectionMode && !isSearchMode, 'mode-special': isSelectionMode || isSearchMode }" @click.stop>
                <div class="input-row-container">
                    <div v-if="attachedImage && !isSelectionMode && !isSearchMode" class="attached-image-preview">
                        <img :src="attachedImage" alt="Attached preview" />
                        <div class="remove-image-btn" @click.stop="clearImage">
                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                        </div>
                    </div>
                    <div class="input-wrapper" ref="inputWrapper" v-show="!isSelectionMode" :class="{ 'with-guidance': isGuidanceMode && guidanceType === 'send' }">
                        <div v-if="isGuidanceMode && guidanceType === 'send'" class="guidance-input-container" :class="{ 'dimmed': isMainFocused }">
                            <div class="guidance-main">
                                <div class="guidance-header">{{ t('guided_generation') || 'GUIDED GENERATION' }}</div>
                                <textarea
                                    class="guidance-editable"
                                    v-model="guidanceText"
                                    :placeholder="t('guidance_placeholder') || 'System Instruction...'"
                                    rows="1"
                                    ref="guidanceInput"
                                    @focus="onGuidanceFocus"
                                    @blur="onGuidanceBlur"
                                ></textarea>
                            </div>
                            <div class="close-guidance-btn" @click.stop="closeGuidance">
                                <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                            </div>
                        </div>
                        <template v-if="isSearchMode">
                            <div class="search-counts-wrapper">
                                <div style="color: var(--text-gray); font-size: 16px; font-weight: 500;">
                                    {{ searchMatchTotal > 0 ? `${searchMatchCurrent} ${t('search_match_of') || 'of'} ${searchMatchTotal}` : (t('search_no_results') || t('no_results') || 'No results') }}
                                </div>
                                <div class="inline-actions">
                                    <div class="chat-btn inline-action-btn" @click="emit('search-prev')">
                                        <svg viewBox="0 0 24 24"><path d="M12 7.83L5.59 14.24L7 15.65L12 10.65L17 15.65L18.41 14.24L12 7.83Z"/></svg>
                                    </div>
                                    <div class="chat-btn inline-action-btn" @click="emit('search-next')">
                                        <svg viewBox="0 0 24 24"><path d="M12 16.17L5.59 9.76L7 8.35L12 13.35L17 8.35L18.41 9.76L12 16.17Z"/></svg>
                                    </div>
                                </div>
                            </div>
                        </template>
                        <div v-else-if="isGuidanceMode && guidanceType === 'impersonate'" class="impersonate-inline-container" :class="{ 'dimmed': isMainFocused }">
                            <div class="guidance-main" style="width: 100%;">
                                <div class="guidance-header">{{ t('guided_impersonation') || 'GUIDED IMPERSONATION' }}</div>
                                <textarea
                                    class="guidance-editable"
                                    v-model="guidanceText"
                                    :placeholder="t('impersonate_guidance_placeholder') || 'Instruction (optional)...'"
                                    rows="1"
                                    ref="guidanceInput"
                                    @input="resizeTextarea"
                                    @keydown="onKeyDown"
                                    @focus="onGuidanceFocus"
                                    @blur="onGuidanceBlur"
                                    style="font-size: 16px; padding: 0; min-height: 24px;"
                                ></textarea>
                            </div>
                            <div class="close-guidance-btn" @click.stop="closeGuidance" style="margin-left: 12px; margin-top: auto; margin-bottom: auto; background: transparent;">
                                <svg viewBox="0 0 24 24" style="fill:currentColor"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                            </div>
                        </div>
                        <template v-else>
                            <div id="chat-input" ref="chatInput" class="chat-input-editable" :class="{'dimmed': isGuidanceMode && !isMainFocused}" :contenteditable="!isImpersonating" role="textbox" aria-multiline="true" enterkeyhint="enter" :data-placeholder="isImpersonating ? '' : t('chat_placeholder')" @input="onInput" @keydown="onKeyDown" @focus="onFocus" @blur="onBlur" @paste="onPaste" @compositionstart="isComposing = true" @compositionend="(e) => { isComposing = false; onInput(e); }"></div>
                            <div v-if="isImpersonating && !modelValue" class="impersonation-overlay" style="padding-left: 18px;"><svg class="typing-icon" viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg><span>{{ t('impersonating') }}</span></div>
                        </template>
                    </div>
                </div>

                <Transition name="buttons-slide">
                    <div v-if="isSelectionMode" class="chat-input-buttons-row selection-buttons-row">
                        <div class="selection-circle-btn btn-cancel-selection" @click="emit('cancel-selection')">
                            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
                        </div>
                        <div class="selection-count-pill">
                            {{ selectedCount }} {{ t('selected_count') || 'Selected' }}
                        </div>
                        <div class="selection-actions-group">
                            <div class="selection-circle-btn btn-memory-config-selection" @click="emit('configure-memory-selected')" :title="t('Memory settings') || 'Memory settings'">
                                <svg viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>
                            </div>
                            <div class="selection-circle-btn btn-memory-draft-selection" :class="{ disabled: selectedCount === 0 }" @click="emit('generate-memory-draft-selected')" :title="t('Generate memory draft') || 'Generate memory draft'">
                                <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-2 .9-2 2v16l4-4h10c1.1 0 2-.9 2-2V8l-6-6zm1 7V3.5L19.5 9H15zm-5 8H8v-2h2v2zm0-4H8V7h2v6z"/></svg>
                            </div>
                            <div class="selection-circle-btn btn-memory-selection" :class="{ disabled: selectedCount === 0 }" @click="emit('create-memory-selected')" :title="t('Create memory') || 'Create memory'">
                                <svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-1 10h-5v5h-2v-5H6v-2h5V6h2v5h5v2z"/></svg>
                            </div>
                            <div class="selection-circle-btn btn-memory-remove-selection" :class="{ disabled: selectedCount === 0 }" @click="emit('remove-memory-selected')" :title="t('Remove memory') || 'Remove memory'">
                                <svg viewBox="0 0 24 24"><path d="M19 13H5v-2h14v2z"/></svg>
                            </div>
                            <div class="selection-circle-btn btn-hide-selection" :class="{ disabled: selectedCount === 0 }" @click="emit('hide-selected')">
                                <svg viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>
                            </div>
                            <div class="selection-circle-btn btn-delete-selection" :class="{ disabled: selectedCount === 0 }" @click="emit('delete-selected')">
                                <svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                            </div>
                        </div>
                    </div>
                    <div v-else-if="!isSearchMode" class="chat-input-buttons-row">
                        <div style="display: flex; gap: 8px;">
                            <div class="chat-btn circle-btn" id="btn-magic" @click.stop="toggleMagicMenu">
                                <svg viewBox="0 0 24 24"><path d="M19 9l1.25-2.75L23 5l-2.75-1.25L19 1l-1.25 2.75L15 5l2.75 1.25L19 9zm-7.5.5L9 4 6.5 9.5 1 12l5.5 2.5L9 20l2.5-5.5L17 12l-5.5-2.5zM19 15l-1.25 2.75L15 19l2.75 1.25L19 23l1.25-2.75L23 19l-2.75-1.25L19 15z"/></svg>
                            </div>
                            <div class="chat-btn circle-btn" @click.stop="triggerImageUpload">
                                <svg viewBox="0 0 24 24"><path d="M16.5 6v11.5c0 2.21-1.79 4-4 4s-4-1.79-4-4V5a2.5 2.5 0 0 1 5 0v10.5c0 .55-.45 1-1 1s-1-.45-1-1V6H10v9.5a2.5 2.5 0 0 0 5 0V5c0-2.21-1.79-4-4-4S7 2.79 7 5v12.5c0 3.04 2.46 5.5 5.5 5.5s5.5-2.46 5.5-5.5V6h-1.5z"/></svg>
                            </div>
                            <div class="chat-btn circle-btn" @click.stop="openFullScreenEditor">
                                <svg viewBox="0 0 24 24"><path d="M15 3l2.3 2.3-2.89 2.87 1.42 1.42L18.7 6.7 21 9V3zM3 9l2.3-2.3 2.87 2.89 1.42-1.42L6.7 5.3 9 3H3zm6 12l-2.3-2.3 2.89-2.87-1.42-1.42L5.3 17.3 3 15v6zm12-6l-2.3 2.3-2.87-2.89-1.42 1.42 2.89 2.87L15 21h6z"/></svg>
                            </div>
                            <div class="chat-btn circle-btn" :class="{ 'active': isGuidanceMode && guidanceType === 'send' }" @click.stop="toggleGuidanceMode">
                                <svg viewBox="0 0 24 24"><path d="M9 5v2h6.59L4 18.59 5.41 20 17 8.41V15h2V5H9z"/></svg>
                            </div>
                        </div>

                        <div class="send-btn-wrapper">
                            <div class="chat-action-btn" @click="handleSend">
                                <div class="btn-icon-wrapper">
                                    <Transition name="btn-icon-fade">
                                        <svg v-if="currentAction === 'stop'" key="stop" viewBox="0 0 24 24"><path d="M6 6h12v12H6z"/></svg>
                                        <svg v-else-if="isGuidanceMode" key="confirm" viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
                                        <svg v-else-if="currentAction === 'send'" key="send" viewBox="0 0 24 24" style="margin-left: 2px;"><path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/></svg>
                                        <svg v-else key="impersonate" viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm0 14.2c-2.5 0-4.71-1.28-6-3.22.03-1.99 4-3.08 6-3.08 1.99 0 5.97 1.09 6 3.08-1.29 1.94-3.5 3.22-6 3.22z"/></svg>
                                    </Transition>
                                </div>
                            </div>
                        </div>
                    </div>
                </Transition>
            </div>
            <MagicDrawer 
                ref="magicDrawerRef"
                :visible="isMagicMenuVisible"
                :active-char="activeChar"
                @close="isMagicMenuVisible = false"
                @magic-notes="emit('magic-notes')"
                @magic-context="emit('magic-context')"
                @magic-summary="emit('magic-summary')"
                @magic-sessions="emit('magic-sessions')"
                @magic-stats="emit('magic-stats')"
                @magic-impersonate="emit('magic-impersonate')"
                @magic-char-card="emit('magic-char-card')"
                @magic-api="emit('magic-api')"
                @magic-presets="emit('magic-presets')"
                @magic-lorebooks="emit('magic-lorebooks')"
                @magic-memory-books="emit('magic-memory-books')"
                @magic-regex="emit('magic-regex')"
                @magic-image-gen="emit('magic-image-gen')"
                @magic-glossary="emit('magic-glossary')"
                @request-preview="openRequestPreview"
                @add-block="() => {}"
            />
            <input type="file" ref="imageInput" accept="image/png, image/jpeg, image/webp" style="display: none" @change="onImageSelected" />
        </div>
    </div>
    <RequestPreviewSheet ref="requestPreviewSheet" />
</template>

<style scoped>
.attached-image-preview {
    position: relative;
    align-self: flex-start;
    margin-bottom: 8px;
    margin-left: 18px;
    border-radius: 12px;
    overflow: hidden;
    max-width: 150px;
    max-height: 150px;
    box-shadow: 0 4px 10px rgba(0,0,0,0.1);
    border: 1px solid var(--border-color, rgba(0,0,0,0.05));
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
}
.attached-image-preview img {
    width: 100%;
    height: auto;
    object-fit: contain;
    display: block;
}
.remove-image-btn {
    position: absolute;
    top: 4px;
    right: 4px;
    width: 24px;
    height: 24px;
    background: rgba(0,0,0,0.6);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    color: white;
}
.remove-image-btn svg {
    width: 16px;
    height: 16px;
    fill: currentColor;
}

.chat-input-container {
    position: relative;
    display: flex;
    flex-direction: column;
    width: 100%;
    -webkit-user-select: text;
    user-select: text;
}

.chat-input-content {
    display: flex;
    flex-direction: column;
    width: 100%;
    overflow: hidden;
    transition: padding-bottom 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
    -webkit-user-select: text;
    user-select: text;
}

.chat-input-container.drawer-open .chat-input-content {
    padding-bottom: var(--keyboard-height, 300px);
}

.chat-input-container.keyboard-open .chat-input-content {
    padding-bottom: var(--keyboard-overlap, 0px);
}

.chat-input-container.drawer-open .chat-input-bar {
    margin-bottom: 10px;
}

.chat-input-bar {
    position: relative;
    width: auto;
    margin: 0 16px;
    margin-bottom: calc(10px + var(--sab));
    z-index: 10;
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-height: 108px;
    justify-content: flex-start;
    -webkit-user-select: text;
    user-select: text;
}

.chat-input-container.keyboard-open .chat-input-bar {
    margin-bottom: 10px;
}

.chat-input-buttons-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    width: 100%;
    -webkit-user-select: none;
    user-select: none;
}


.selection-buttons-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    width: 100%;
    gap: 8px;
    -webkit-user-select: none;
    user-select: none;
}

.selection-count-pill {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: flex-start;
    padding: 0 16px;
    height: 40px;
    border-radius: 20px;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    color: var(--vk-blue);
    font-size: 14px;
    font-weight: 600;
    white-space: nowrap;
}

.selection-actions-group {
    display: flex;
    gap: 8px;
}

.selection-circle-btn {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 50%;
    cursor: pointer;
    flex-shrink: 0;
}

.selection-circle-btn svg {
    width: 22px;
    height: 22px;
    fill: currentColor;
}

.selection-circle-btn.btn-cancel-selection {
    color: var(--vk-blue);
}

.selection-circle-btn.btn-hide-selection {
    color: var(--text-gray);
}

.selection-circle-btn.btn-memory-selection {
    color: #1ec8ff;
}

.selection-circle-btn.btn-memory-draft-selection {
    color: #9b8cff;
}

.selection-circle-btn.btn-memory-config-selection {
    color: #7a6cff;
}

.selection-circle-btn.btn-memory-remove-selection {
    color: #ffb347;
}

.selection-circle-btn.btn-hide-selection.disabled {
    opacity: 0.3;
    pointer-events: none;
}

.selection-circle-btn.btn-memory-selection.disabled,
.selection-circle-btn.btn-memory-remove-selection.disabled,
.selection-circle-btn.btn-memory-draft-selection.disabled {
    opacity: 0.3;
    pointer-events: none;
}

.selection-circle-btn.btn-delete-selection {
    color: #ff4444;
}

.selection-circle-btn.btn-delete-selection.disabled {
    opacity: 0.3;
    pointer-events: none;
}

.search-counts-wrapper {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 8px 0 18px;
    min-height: 56px;
    background: transparent;
    border: none;
    border-radius: 0;
    backdrop-filter: none;
    -webkit-backdrop-filter: none;
    -webkit-user-select: none;
    user-select: none;
}

.inline-actions {
    display: flex;
    gap: 4px;
}

.inline-action-btn {
    width: 40px;
    height: 40px;
    color: var(--text-gray);
    border-radius: 50%;
    transition: background-color 0.2s;
}

.inline-action-btn:active {
    background-color: rgba(var(--text-gray-rgb, 150, 150, 150), 0.1);
}

.inline-action-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

/* Buttons slide animation */
.chat-input-buttons-row {
    transform-origin: top;
}
.buttons-slide-enter-active,
.buttons-slide-leave-active {
    transition: all 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
    max-height: 40px;
}
.buttons-slide-enter-from,
.buttons-slide-leave-to {
    opacity: 0;
    max-height: 0;
    transform: translateY(10px) scaleY(0.8);
    margin-top: -10px;
    overflow: hidden;
}

.input-wrapper {
    position: relative;
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 28px;
    min-height: 56px;
    box-sizing: border-box;
    -webkit-user-select: text;
    user-select: text;
}

.chat-input-editable {
    width: 100%;
    max-height: 150px;
    overflow-y: auto;
    padding: 16px 18px;
    font-size: 16px;
    font-family: inherit;
    line-height: 1.5;
    color: var(--text-black);
    background: transparent;
    outline: none;
    white-space: pre-wrap;
    word-wrap: break-word;
    /* Hide scrollbar */
    -ms-overflow-style: none;
    scrollbar-width: none;
    -webkit-user-select: text;
    user-select: text;
    -webkit-touch-callout: default;
}

.chat-input-editable::-webkit-scrollbar {
    display: none;
}

.chat-input-editable:empty::before {
    content: attr(data-placeholder);
    color: var(--text-gray);
    pointer-events: none;
    display: inline-block;
    cursor: text;
}

.impersonation-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    padding-left: 16px;
    pointer-events: none;
    color: var(--text-gray);
    background: transparent;
    z-index: 10;
}

.send-btn-wrapper {
    display: flex;
    align-items: center;
}

.chat-btn.circle-btn {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 12px));
    -webkit-backdrop-filter: blur(var(--element-blur, 12px));
    border: 1px solid var(--border-color, rgba(0, 0, 0, 0.05));
    border-radius: 50%;
    cursor: pointer;
    color: var(--vk-blue);
    flex-shrink: 0;
}

.chat-btn.circle-btn svg {
    width: 24px;
    height: 24px;
    fill: currentColor;
}

.chat-btn {
    width: 40px;
    height: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    fill: var(--vk-blue);
}

.chat-btn svg {
    width: 28px;
    height: 28px;
}

.chat-action-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    background-color: var(--vk-blue);
    border: none;
    border-radius: 50%;
    width: 40px;
    height: 40px;
    color: #fff;
    cursor: pointer;
    flex-shrink: 0;
    overflow: hidden;
}

/* Guidance CSS */
.guidance-input-container {
    display: flex;
    align-items: center;
    background: transparent;
    border-bottom: 1px dashed var(--border-color, rgba(0,0,0,0.1));
    padding: 8px 8px 8px 18px;
    animation: slideDownFade 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
    flex-shrink: 0;
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

.guidance-editable {
    width: 100%;
    background: transparent;
    border: none;
    outline: none;
    color: var(--text-black);
    font-size: 14px;
    font-family: inherit;
    resize: none;
    field-sizing: content;
    padding: 0;
    margin: 0;
    line-height: inherit;
    min-height: 20px;
    max-height: 80px;
    border-radius: 0 !important;
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
}
.guidance-editable::-webkit-scrollbar { display: none; }
.guidance-editable { -ms-overflow-style: none; scrollbar-width: none; }

.guidance-editable::placeholder { color: var(--text-gray); }

.close-guidance-btn {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0,0,0,0.05);
    color: var(--text-gray);
    cursor: pointer;
    transition: background-color 0.2s;
}
.close-guidance-btn:active { background: rgba(0,0,0,0.1); }
.close-guidance-btn svg { width: 14px; height: 14px; fill: currentColor; }

.impersonate-inline-container {
    display: flex;
    align-items: center;
    padding: 12px 18px;
    width: 100%;
}

.circle-btn.active {
    background-color: var(--vk-blue) !important;
    color: white !important;
    border-color: var(--vk-blue) !important;
}
.circle-btn.active svg { fill: white !important; }

.chat-input-editable.dimmed,
.impersonate-inline-container.dimmed,
.guidance-input-container.dimmed {
    opacity: 0.5;
}

@keyframes slideDownFade {
    0% { opacity: 0; max-height: 0; padding-top: 0; padding-bottom: 0; }
    100% { opacity: 1; max-height: 100px; }
}

.guidance-editable { color: var(--text-black); }

.chat-action-btn:active {
    transform: scale(0.95);
    opacity: 0.8;
}

.btn-icon-wrapper {
    position: relative;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
}

.btn-icon-wrapper svg {
    position: absolute;
    width: 24px;
    height: 24px;
    fill: currentColor;
}

/* Icon transition */
.btn-icon-fade-enter-active,
.btn-icon-fade-leave-active {
    transition: opacity 0.2s ease, transform 0.2s ease;
}
.btn-icon-fade-enter-from { opacity: 0; transform: scale(0.8); }
.btn-icon-fade-leave-to { opacity: 0; transform: scale(0.8); }



/* Scroll Button */
.scroll-bottom-btn {
    position: absolute;
    right: 16px;
    top: -50px;
    width: 42px;
    height: 42px;
    border-radius: 50%;
    background-color: rgba(var(--ui-bg-rgb), var(--element-opacity, 0.8));
    backdrop-filter: blur(var(--element-blur, 20px));
    -webkit-backdrop-filter: blur(var(--element-blur, 20px));
    border: 1px solid rgba(255, 255, 255, 0.1);
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.3);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.3s ease, transform 0.2s, background-color 0.3s;
    z-index: 95;
    color: var(--text-black);
    -webkit-user-select: none;
    user-select: none;
}
.scroll-bottom-btn.visible {
    opacity: 1;
    pointer-events: auto;
}


.chat-input-editable { color: var(--text-black); }

.chat-status-gradient-bottom {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    height: calc(var(--sab) + 80px);
    background: linear-gradient(to top, rgba(0,0,0,0.4), transparent);
    z-index: 1;
    pointer-events: none;
}
</style>
