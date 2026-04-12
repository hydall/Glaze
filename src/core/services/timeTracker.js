import { ref } from 'vue';

let interval = null;
let activeCharId = null;
let activeSessionId = null;

export const startTracking = () => {
    if (interval) return;

    // Check local storage for initial values or default to 0
    if (!localStorage.getItem('gz_time_app')) {
        localStorage.setItem('gz_time_app', '0');
    }

    interval = setInterval(() => {
        // Only track time if the document has focus (app is active)
        if (!document.hasFocus()) return;

        // App time
        let appTime = parseInt(localStorage.getItem('gz_time_app') || '0', 10);
        localStorage.setItem('gz_time_app', appTime + 1);

        // Context time
        if (activeCharId) {
            let charTime = parseInt(localStorage.getItem(`gz_time_char_${activeCharId}`) || '0', 10);
            localStorage.setItem(`gz_time_char_${activeCharId}`, charTime + 1);

            if (activeSessionId) {
                let sessionTime = parseInt(localStorage.getItem(`gz_time_chat_${activeCharId}_${activeSessionId}`) || '0', 10);
                localStorage.setItem(`gz_time_chat_${activeCharId}_${activeSessionId}`, sessionTime + 1);
            }
        }
    }, 1000);
};

export const setTrackedContext = (charId, sessionId) => {
    activeCharId = charId || null;
    activeSessionId = sessionId || null;
};

export const getTrackedTime = (scope, charId = null, sessionId = null) => {
    if (scope === 'app') {
        return parseInt(localStorage.getItem('gz_time_app') || '0', 10);
    }
    if (scope === 'char' && charId) {
        return parseInt(localStorage.getItem(`gz_time_char_${charId}`) || '0', 10);
    }
    if (scope === 'chat' && charId && sessionId) {
        return parseInt(localStorage.getItem(`gz_time_chat_${charId}_${sessionId}`) || '0', 10);
    }
    return 0;
};

export const getActiveContext = () => ({ charId: activeCharId, sessionId: activeSessionId });
