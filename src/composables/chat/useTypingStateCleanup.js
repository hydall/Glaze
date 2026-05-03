export function useTypingStateCleanup({ currentMessages, db }) {
    return {
        async clearTypingStateForMessage({ charId, sessionId, msgId, errorLabel = '[generation]' }) {
            const idx = currentMessages.value.findIndex(m => m.id === msgId);
            if (idx !== -1) {
                currentMessages.value[idx].isTyping = false;
            }

            try {
                await db.patchChatData(charId, (data) => {
                    if (data.sessions[sessionId]) {
                        const dbIdx = data.sessions[sessionId].findIndex(m => m.id === msgId);
                        if (dbIdx !== -1) {
                            data.sessions[sessionId][dbIdx].isTyping = false;
                        }
                    }
                });
            } catch (dbErr) {
                console.error(`${errorLabel} Failed to clear isTyping in DB:`, dbErr);
            }
        }
    };
}
