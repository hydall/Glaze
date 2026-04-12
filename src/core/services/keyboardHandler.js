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

    const savedKbHeight = localStorage.getItem('gz_keyboard_height');
    const kbH = savedKbHeight ? `${savedKbHeight}px` : '300px';
    document.documentElement.style.setProperty('--keyboard-height', kbH);
    document.documentElement.style.setProperty('--keyboard-overlap', '0px');

    Keyboard.setResizeMode({ mode: KeyboardResize.None }).catch(() => { });

    Keyboard.setScroll({ isDisabled: true }).catch(e => console.warn('Keyboard setScroll error', e));

    if (Capacitor.getPlatform() === 'android') {


        // adjustNothing in AndroidManifest means the OS never pans or resizes the WebView.
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
    if (height !== undefined) {
        document.documentElement.style.setProperty('--keyboard-height', `${height}px`);
        document.documentElement.style.setProperty('--keyboard-overlap', `${height}px`);
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
