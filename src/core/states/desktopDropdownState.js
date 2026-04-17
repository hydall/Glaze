import { ref } from 'vue';

// ── Dropdown state ─────────────────────────────────────────────────────────
export const desktopDropdownState = ref({
    visible: false,
    title: '',
    items: [],
    bigInfo: null,
    headerAction: null,
    x: 0,
    y: 0,
    isTriggered: false,
});

export function showDesktopDropdown({ title, items, bigInfo, headerAction, x, y, isTriggered = false }) {
    desktopDropdownState.value = {
        visible: true,
        title: title || '',
        items: items || [],
        bigInfo: bigInfo || null,
        headerAction: headerAction || null,
        isTriggered,
        x,
        y,
    };
}

export function closeDesktopDropdown() {
    desktopDropdownState.value = {
        ...desktopDropdownState.value,
        visible: false,
    };
}

// ── Last mousedown position tracker ───────────────────────────────────────
// Automatically tracks the latest mouse/touch position so callers of
// showBottomSheet() don't need to pass an anchor element manually.
let _lastX = typeof window !== 'undefined' ? window.innerWidth / 2 : 400;
let _lastY = typeof window !== 'undefined' ? window.innerHeight / 2 : 300;

export function getLastClickPosition() {
    return { x: _lastX, y: _lastY };
}

if (typeof window !== 'undefined') {
    // mousedown covers regular clicks
    window.addEventListener('mousedown', (e) => {
        _lastX = e.clientX;
        _lastY = e.clientY;
    }, { passive: true, capture: true });

    // touchstart covers mobile / stylus
    window.addEventListener('touchstart', (e) => {
        if (e.touches.length > 0) {
            _lastX = e.touches[0].clientX;
            _lastY = e.touches[0].clientY;
        }
    }, { passive: true, capture: true });
}
