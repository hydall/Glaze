import { ref } from 'vue';
import { Capacitor } from '@capacitor/core';
import { hideKeyboard } from '@/core/services/keyboardHandler.js';
import { showDesktopDropdown, getLastClickPosition } from '@/core/states/desktopDropdownState.js';

export const bottomSheetState = ref({
    visible: false,
    locked: false,
    isSolid: false,
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

// ── Helper: is this a "simple select" sheet? ──────────────────────────────
// Criteria: only has items[], no bigInfo / input / content / cardItems /
// sessionItems / headerAction. Items may have icons, but no sub-actions.
function isSimpleSelect(config) {
    const hasItems = config.items && config.items.length > 0;
    const hasCardItems = config.cardItems && config.cardItems.length > 0;
    const hasBigInfo = !!config.bigInfo;

    if (!hasItems && !hasCardItems && !hasBigInfo) return false;
    if (config.input || config.content) return false;
    if (config.sessionItems?.length) return false;
    return true;
}

function isDesktopEnv() {
    return typeof window !== 'undefined' && window.innerWidth >= 768;
}

// ── Public API ─────────────────────────────────────────────────────────────
export function showBottomSheet(config) {
    // On desktop, intercept "simple select" sheets and show a dropdown instead
    if (isDesktopEnv() && isSimpleSelect(config)) {
        const { x, y } = getLastClickPosition();
        showDesktopDropdown({
            title: config.title || '',
            items: config.items || config.cardItems,
            bigInfo: config.bigInfo,
            headerAction: config.headerAction,
            isTriggered: !!config.cardItems?.length || !!config.bigInfo,
            x,
            y,
        });
        return;
    }

    bottomSheetState.value = {
        visible: true,
        locked: config.locked || false,
        isSolid: config.isSolid || false,
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
