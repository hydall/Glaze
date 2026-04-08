import { ref } from 'vue';
import { Capacitor } from '@capacitor/core';
import { hideKeyboard } from '@/core/services/keyboardHandler.js';

export const bottomSheetState = ref({
    visible: false,
    locked: false,
    title: '',
    helpTip: null,
    content: null,
    items: [],
    headerAction: null,
    bigInfo: null,
    input: null,
    sessionItems: [],
    cardItems: [],
    onClose: null
});

export function showBottomSheet(config) {
    bottomSheetState.value = {
        visible: true,
        locked: config.locked || false,
        title: config.title || '',
        helpTip: config.helpTip || null,
        content: config.content || null,
        items: config.items || [],
        headerAction: config.headerAction || null,
        bigInfo: config.bigInfo || null,
        input: config.input || null,
        sessionItems: config.sessionItems || [],
        cardItems: config.cardItems || [],
        onClose: config.onClose || null
    };
}

export function closeBottomSheet() {
    if (bottomSheetState.value.onClose) {
        bottomSheetState.value.onClose();
    }
    // Only hide keyboard if focus is actually inside the bottom sheet.
    // Unconditionally calling Keyboard.hide() causes a rapid show/hide/show cycle
    // on iOS when the user taps an input right after closing the sheet, which crashes WKWebView.
    const active = document.activeElement;
    if (active && active.closest('.bottom-sheet-content')) {
        active.blur();
        if (Capacitor.isNativePlatform()) {
            hideKeyboard();
        }
    }
    bottomSheetState.value.visible = false;
}
