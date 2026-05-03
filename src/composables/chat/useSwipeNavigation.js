import { getAllGreetings } from '@/utils/sessions.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { activePersona } from '@/core/states/personaState.js';
import { db } from '@/utils/db.js';

async function updateSessionMessage(char, msgIndex, newMsgData) {
    await db.patchChatData(char.id, (data) => {
        if (data.sessions[data.currentId]) {
            data.sessions[data.currentId][msgIndex] = newMsgData;
        }
    });
}

export function useSwipeNavigation({ currentMessages, isGenerating, getActiveChatChar, regenerateMessage }) {
    function changeSwipe(msgIndex, dir, fromSwipe = false) {
        const activeChatChar = getActiveChatChar();
        if (isGenerating.value) return;
        const msg = currentMessages.value[msgIndex];

        if (msg.isError && msg.swipes && msg.swipes.length > 1) {
            const errorSwipeId = msg.swipeId || 0;

            msg.swipes.splice(errorSwipeId, 1);
            if (msg.swipesMeta) msg.swipesMeta.splice(errorSwipeId, 1);

            let newIndex = errorSwipeId;
            if (dir < 0) newIndex = errorSwipeId - 1;

            if (newIndex >= msg.swipes.length) newIndex = msg.swipes.length - 1;
            if (newIndex < 0) newIndex = 0;

            msg.swipeId = newIndex;
            msg.text = msg.swipes[newIndex];
            msg.isError = false;
            msg.swipeDirection = fromSwipe ? (dir > 0 ? 'slide-next' : 'slide-prev') : 'fade';

            let newReasoning = null;
            let newGenTime = null;
            let newTokens = null;
            if (msg.swipesMeta && msg.swipesMeta[newIndex]) {
                newReasoning = msg.swipesMeta[newIndex].reasoning;
                newGenTime = msg.swipesMeta[newIndex].genTime;
                newTokens = msg.swipesMeta[newIndex].tokens;
            }
            msg.reasoning = newReasoning;
            msg.genTime = newGenTime;
            msg.tokens = newTokens;

            updateSessionMessage(activeChatChar, msgIndex, msg);
            return;
        }

        if (!msg.swipes || msg.swipes.length <= 1) return;

        const newIndex = (msg.swipeId || 0) + dir;

        const isLastMsg = msgIndex === currentMessages.value.length - 1;
        if (dir > 0 && newIndex >= msg.swipes.length && isLastMsg) {
            regenerateMessage(msgIndex, 'new_variant');
            return;
        }

        if (newIndex < 0 || newIndex >= msg.swipes.length) return;

        msg.swipeDirection = fromSwipe ? (dir > 0 ? 'slide-next' : 'slide-prev') : 'fade';
        msg.swipeId = newIndex;
        msg.text = msg.swipes[newIndex];
        msg.isError = false;

        let newReasoning = null;
        let newGenTime = null;
        let newTokens = null;
        if (msg.swipesMeta && msg.swipesMeta[newIndex]) {
            newReasoning = msg.swipesMeta[newIndex].reasoning;
            newGenTime = msg.swipesMeta[newIndex].genTime;
            newTokens = msg.swipesMeta[newIndex].tokens;
        }
        msg.reasoning = newReasoning;
        msg.genTime = newGenTime;
        msg.tokens = newTokens;

        updateSessionMessage(activeChatChar, msgIndex, msg);
    }

    function changeGreeting(msgIndex, dir, fromSwipe = false) {
        const activeChatChar = getActiveChatChar();
        if (isGenerating.value) return;
        const msg = currentMessages.value[msgIndex];
        const persona = activePersona.value;
        const greetings = getAllGreetings(activeChatChar, persona);
        if (greetings.length <= 1) return;

        let newIndex = (msg.greetingIndex || 0) + dir;
        if (newIndex >= greetings.length) newIndex = 0;
        if (newIndex < 0) newIndex = greetings.length - 1;

        msg.swipeDirection = fromSwipe ? (dir > 0 ? 'slide-next' : 'slide-prev') : 'fade';
        msg.greetingIndex = newIndex;
        msg.text = greetings[newIndex];
        msg.tokens = estimateTokens(greetings[newIndex]);
        msg.swipes = [msg.text];
        msg.swipeId = 0;
        msg.reasoning = null;
        msg.isError = false;
        updateSessionMessage(activeChatChar, msgIndex, msg);
    }

    return {
        changeSwipe,
        changeGreeting
    };
}
