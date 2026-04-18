import { ref } from 'vue';
import { Keyboard, KeyboardResize } from '@capacitor/keyboard';
import { Capacitor } from '@capacitor/core';

export const isKeyboardOpen = ref(false);
export const isNativeKeyboard = ref(false);
export const keyboardOverlap = ref(0);

let _scrollResetRaf = null;

export function initKeyboard() {
    isNativeKeyboard.value = Capacitor.isNativePlatform();
    isKeyboardOpen.value = document.body.classList.contains('keyboard-open');

    if (!Capacitor.isNativePlatform()) {
        // On web/desktop, keyboard overlap should always be 0
        // Keep --keyboard-height intact (used for MagicDrawer sizing), only zero out --keyboard-overlap
        document.documentElement.style.setProperty('--keyboard-overlap', '0px');
        return; // Exit early, no need to set up native keyboard listeners
    }

    const savedKbHeight = localStorage.getItem('gz_keyboard_height');
    const kbH = savedKbHeight ? `${savedKbHeight}px` : '300px';
    document.documentElement.style.setProperty('--keyboard-height', kbH);
    document.documentElement.style.setProperty('--keyboard-overlap', '0px');

    Keyboard.setResizeMode({ mode: KeyboardResize.None }).catch(() => { });

    Keyboard.setScroll({ isDisabled: true }).catch(e => console.warn('Keyboard setScroll error', e));

    if (Capacitor.getPlatform() === 'android') {
        // The viewport is always stable, so --keyboard-overlap always equals --keyboard-height.
        Keyboard.addListener('keyboardWillShow', (info) => {
            isKeyboardOpen.value = true;
            document.body.classList.add('keyboard-open');
            if (info && info.keyboardHeight) {
                document.documentElement.style.setProperty('--keyboard-height', `${info.keyboardHeight}px`);
                document.documentElement.style.setProperty('--keyboard-overlap', `${info.keyboardHeight}px`);
                keyboardOverlap.value = info.keyboardHeight;
                localStorage.setItem('gz_keyboard_height', info.keyboardHeight);
            } else {
                applyKeyboardOverlap();
            }
        });

        Keyboard.addListener('keyboardDidShow', (info) => {
            if (info && info.keyboardHeight) {
                document.documentElement.style.setProperty('--keyboard-height', `${info.keyboardHeight}px`);
                document.documentElement.style.setProperty('--keyboard-overlap', `${info.keyboardHeight}px`);
                keyboardOverlap.value = info.keyboardHeight;
                localStorage.setItem('gz_keyboard_height', info.keyboardHeight);
            }
        });

        Keyboard.addListener('keyboardWillHide', () => {
            isKeyboardOpen.value = false;
            document.body.classList.remove('keyboard-open');
            document.documentElement.style.setProperty('--keyboard-overlap', '0px');
            keyboardOverlap.value = 0;
        });
    } else if (Capacitor.getPlatform() === 'ios') {
        let preKeyboardHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight;

        function resetBodyScroll() {
            if (document.body.scrollTop !== 0) {
                document.body.scrollTop = 0;
            }
            window.scrollTo(0, 0);
        }

        function startScrollResetLoop() {
            if (_scrollResetRaf) return;
            function tick() {
                resetBodyScroll();
                if (isKeyboardOpen.value) {
                    // Dynamically adjust overlap to prevent double padding if OS natively shrinks viewport
                    const currentHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight;
                    const viewportShrunk = Math.max(0, preKeyboardHeight - currentHeight);
                    const currentKbHeight = parseInt(document.documentElement.style.getPropertyValue('--keyboard-height')) || 0;
                    if (currentKbHeight > 0) {
                        const effectiveOverlap = Math.max(0, currentKbHeight - viewportShrunk);
                        document.documentElement.style.setProperty('--keyboard-overlap', `${effectiveOverlap}px`);
                        keyboardOverlap.value = effectiveOverlap;
                    }

                    _scrollResetRaf = requestAnimationFrame(tick);
                } else {
                    _scrollResetRaf = null;
                }
            }
            _scrollResetRaf = requestAnimationFrame(tick);
        }

        function stopScrollResetLoop() {
            if (_scrollResetRaf) {
                cancelAnimationFrame(_scrollResetRaf);
                _scrollResetRaf = null;
            }
            // Final reset after keyboard closes
            resetBodyScroll();
            setTimeout(resetBodyScroll, 100);
        }

        Keyboard.addListener('keyboardWillShow', (info) => {
            if (!isKeyboardOpen.value) {
                preKeyboardHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight;
            }
            isKeyboardOpen.value = true;
            document.body.classList.add('keyboard-open');
            resetBodyScroll();

            if (info && info.keyboardHeight) {
                document.documentElement.style.setProperty('--keyboard-height', `${info.keyboardHeight}px`);
                localStorage.setItem('gz_keyboard_height', info.keyboardHeight);

                const currentHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight;
                const viewportShrunk = Math.max(0, preKeyboardHeight - currentHeight);
                const effectiveOverlap = Math.max(0, info.keyboardHeight - viewportShrunk);
                document.documentElement.style.setProperty('--keyboard-overlap', `${effectiveOverlap}px`);
                keyboardOverlap.value = effectiveOverlap;
            }
            startScrollResetLoop();
        });

        Keyboard.addListener('keyboardDidShow', (info) => {
            if (info && info.keyboardHeight) {
                document.documentElement.style.setProperty('--keyboard-height', `${info.keyboardHeight}px`);
                localStorage.setItem('gz_keyboard_height', info.keyboardHeight);
            }
            resetBodyScroll();
        });

        Keyboard.addListener('keyboardWillHide', () => {
            isKeyboardOpen.value = false;
            document.body.classList.remove('keyboard-open');
            document.documentElement.style.setProperty('--keyboard-overlap', '0px');
            keyboardOverlap.value = 0;
            stopScrollResetLoop();
        });
    }
}

export async function showKeyboard() {
    if (Capacitor.isNativePlatform()) {
        await Keyboard.show().catch(() => { });
    }
}

export async function hideKeyboard() {
    if (Capacitor.isNativePlatform()) {
        await Keyboard.hide().catch(() => { });
    }
}

export function applyKeyboardOverlap(height) {
    // Only apply keyboard overlap on native platforms
    if (!Capacitor.isNativePlatform()) {
        return;
    }
    
    if (height !== undefined) {
        document.documentElement.style.setProperty('--keyboard-height', `${height}px`);
        document.documentElement.style.setProperty('--keyboard-overlap', `${height}px`);
    } else {
        const savedKbHeight = localStorage.getItem('gz_keyboard_height') || 300;
        document.documentElement.style.setProperty('--keyboard-overlap', `${savedKbHeight}px`);
    }
}

export async function onKeyboardShow(callback) {
    if (Capacitor.isNativePlatform()) {
        return await Keyboard.addListener('keyboardWillShow', callback);
    }
    return { remove: () => { } };
}

export async function onKeyboardHide(callback) {
    if (Capacitor.isNativePlatform()) {
        return await Keyboard.addListener('keyboardWillHide', callback);
    }
    return { remove: () => { } };
}

export function attachKeyboardFocusHandler(contentRef, callbacks = {}) {
    const isTextFieldFocused = ref(false);
    const isLocalKeyboardOpen = ref(false);

    function updateFocusState() {
        const active = document.activeElement;
        if (!active) {
            isTextFieldFocused.value = false;
            return;
        }

        const isInside = contentRef.value?.contains(active) || active?.closest('.sheet-view-content');

        if (isInside) {
            const tagName = active.tagName;
            let isTextEntry = false;

            if (tagName === 'TEXTAREA') {
                isTextEntry = true;
            } else if (tagName === 'INPUT') {
                const textTypes = ['text', 'password', 'email', 'number', 'tel', 'url', 'search', 'date', 'datetime-local', 'month', 'time', 'week'];
                isTextEntry = textTypes.includes(active.type.toLowerCase());
            } else if (active.isContentEditable) {
                isTextEntry = true;
            }

            isTextFieldFocused.value = isTextEntry;

            if (isTextEntry && Capacitor.isNativePlatform()) {
                showKeyboard();
            }
        } else {
            isTextFieldFocused.value = false;
        }

        if (!Capacitor.isNativePlatform()) {
            isLocalKeyboardOpen.value = isTextFieldFocused.value;
        }
    }

    let kbListeners = [];

    function onFocusIn() {
        updateFocusState();
        if (isLocalKeyboardOpen.value && callbacks.onKeyboardOpen) {
            callbacks.onKeyboardOpen();
        }
    }

    function onFocusOut() {
        setTimeout(updateFocusState, 50);
    }

    async function mount() {
        document.addEventListener('focusin', onFocusIn);
        document.addEventListener('focusout', onFocusOut);

        if (Capacitor.isNativePlatform()) {
            kbListeners.push(await onKeyboardShow((info) => {
                updateFocusState();
                if (isTextFieldFocused.value) {
                    if (callbacks.onKeyboardOpen) callbacks.onKeyboardOpen();
                    if (info && info.keyboardHeight) {
                        applyKeyboardOverlap(info.keyboardHeight);
                    }
                    isLocalKeyboardOpen.value = true;
                    if (callbacks.onKeyboardExpanded) callbacks.onKeyboardExpanded(info);
                }
            }));
            kbListeners.push(await onKeyboardHide(() => {
                isLocalKeyboardOpen.value = false;
                isTextFieldFocused.value = false;
                if (callbacks.onKeyboardRestored) callbacks.onKeyboardRestored();
            }));
        }
    }

    function unmount() {
        document.removeEventListener('focusin', onFocusIn);
        document.removeEventListener('focusout', onFocusOut);
        kbListeners.forEach(l => l.remove());
    }

    function hideLocalKeyboard() {
        if (isLocalKeyboardOpen.value) {
            isLocalKeyboardOpen.value = false;
            const active = document.activeElement;
            if (active && contentRef.value?.contains(active)) {
                active.blur();
            }
            if (Capacitor.isNativePlatform()) {
                hideKeyboard();
            }
        }
    }

    return {
        isLocalKeyboardOpen,
        isTextFieldFocused,
        mount,
        unmount,
        hideLocalKeyboard
    };
}
