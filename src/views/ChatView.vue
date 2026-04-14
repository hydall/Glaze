<script>
// --- Module Level State (Persists across component mounts) ---
let activeChatChar = null;
const generatingStates = {}; // { charId: state }
let genIdCounter = 0;
let _cleanupScroll = null;
let _msgIdCounter = 0;
function genMsgId() {
    return `msg_${Date.now()}_${++_msgIdCounter}`;
}
</script>

<script setup>
import { ref, nextTick, onMounted, onUnmounted, watch, computed, onBeforeUnmount } from 'vue';
import { Capacitor } from '@capacitor/core';
import { keyboardOverlap } from '@/core/services/keyboardHandler.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { formatText, cleanText } from '@/utils/textFormatter.js';
import { replaceMacros } from '@/utils/macroEngine.js';
import { getEffectivePersona, activePersona, allPersonas } from '@/core/states/personaState.js';
import { formatDate, formatDateSeparator } from '@/utils/dateFormatter.js';
import { currentLang } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import { generateChatResponse, calculateContext } from '@/core/services/generationService.js';
import { executeRequest } from '@/core/services/llmApi.js';
import { getApiConfig } from '@/core/config/APISettings.js';
import { animateTextChange, updateAppColors, initHeaderScroll, initRipple } from '@/core/services/ui.js';
import { showBottomSheet, closeBottomSheet, bottomSheetState } from '@/core/states/bottomSheetState.js';
import { db } from '@/utils/db.js';
import { createNewSession as dbCreateSession, deleteSession as dbDeleteSession, switchSession as dbSwitchSession, getAllGreetings, getChatData } from '@/utils/sessions.js';
import { lorebookState, getActiveLorebooksForContext } from '@/core/states/lorebookState.js';
import { presetState, getEffectivePreset, getEffectivePresetId } from '@/core/states/presetState.js';
import { useVirtualScroll } from '@/composables/chat/useVirtualScroll.js';
import { sendMessageNotification, clearMessageNotifications, startGenerationNotification, stopGenerationNotification } from '@/core/services/notificationService.js';
import { addNotification } from '@/core/states/notificationsState.js';
import { formatError } from '@/utils/errors.js';
import { themeState } from '@/core/states/themeState.js';
import { triggerChatImport } from '@/core/services/chatImporter.js';
import { setTrackedContext } from '@/core/services/timeTracker.js';
import ChatMessage from '@/components/chat/ChatMessage.vue';
import ChatInput from '@/components/chat/ChatInput.vue';
import PresetView from '@/views/PresetView.vue';
import CharacterCardSheet from '@/components/sheets/CharacterCardSheet.vue';
import LorebookSheet from '@/components/sheets/LorebookSheet.vue';
import RegexSheet from '@/components/sheets/RegexSheet.vue';
import StatsSheet from '@/components/sheets/StatsSheet.vue';
import ImageGenSheet from '@/components/sheets/ImageGenSheet.vue';
import GlossarySheet from '@/components/sheets/GlossarySheet.vue';
import { addMessageStats, addDeletedStats, addRegenerationStats, migrateStatsIfNeeded } from '@/core/services/statsService.js';
import { processMessageImages, generateImage, makeLoadingHtml, makeErrorHtml, makeResultHtml } from '@/core/services/imageGenService.js';
import { showToast } from '@/core/states/toastState.js';

const isAndroid = Capacitor.getPlatform() === 'android';

// --- Component State ---
const chatViewRoot = ref(null);
const messagesContainer = ref(null);
const chatInputContainer = ref(null);
const chatInputRef = ref(null);
const inputValue = ref('');
const isImpersonating = ref(false);
const currentMessages = ref([]);
const isGenerating = ref(false);
const showScrollButton = ref(false);
const isLoading = ref(false);
let currentOnBack = null;
let inputResizeObserver = null;
const cutoffIndex = ref(-1);
const apiView = ref(null);
const statsSheet = ref(null);
const imageGenSheet = ref(null);
const openImageGenSheet = () => imageGenSheet.value?.open();
const glossarySheet = ref(null);
const openGlossarySheet = () => glossarySheet.value?.open();
const presetView = ref(null);
const charCardSheet = ref(null);
const lorebookSheet = ref(null);
const regexSheet = ref(null);
const activeChar = ref(null);
const regexRevision = ref(0);
const onRegexChanged = () => { regexRevision.value++; };
const contextBreakdown = ref(null);
const HISTORY_FILL_THRESHOLD_KEY = 'gz_history_fill_threshold';
const HISTORY_HIDE_PERCENT_KEY = 'gz_history_hide_percent';
const historyFillThreshold = ref(parseInt(localStorage.getItem(HISTORY_FILL_THRESHOLD_KEY) || '85', 10));
const historyHidePercent = ref(parseInt(localStorage.getItem(HISTORY_HIDE_PERCENT_KEY) || '30', 10));
let isCalculatingCutoff = false;
let pendingCutoffRecalc = false;
let isOpeningChat = false;
let cutoffRerunTimer = null;
const pendingGuidance = ref(null); // { text, type }

let ignoreScrollAdjustment = false;
let ignoreScrollAdjustmentTimer = null;

// --- Search State ---
const isSearchMode = ref(false);
const searchQuery = ref('');
const searchResults = ref([]); // array of original indices
const currentSearchIndex = ref(-1);

// --- Selection State ---
const selectedMessages = ref(new Set());
const isSelectionMode = computed(() => selectedMessages.value.size > 0);

watch([isSearchMode, isSelectionMode], () => {
    ignoreScrollAdjustment = true;
    if (ignoreScrollAdjustmentTimer) clearTimeout(ignoreScrollAdjustmentTimer);
    ignoreScrollAdjustmentTimer = setTimeout(() => {
        ignoreScrollAdjustment = false;
    }, 400); // Wait for transition animations
});

function toggleSelection(msgId) {
    if (selectedMessages.value.has(msgId)) {
        selectedMessages.value.delete(msgId);
    } else {
        selectedMessages.value.add(msgId);
    }
}

function clearSelection() {
    selectedMessages.value.clear();
}

async function deleteSelectedMessages() {
    if (selectedMessages.value.size === 0) return;
    
    // Filter messages
    const newMsgs = currentMessages.value.filter(msg => msg && !selectedMessages.value.has(msg.timestamp));
    const count = currentMessages.value.length - newMsgs.length;
    currentMessages.value = newMsgs;
    
    // Save to active chat data
    if (activeChatChar) {
        if (count > 0) {
            const sid = activeChatChar.sessionId || (await getChatData(activeChatChar.id)).currentId;
            addDeletedStats(activeChatChar.id, sid, count);
        }

        let chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        chatData.sessions[sessionId] = currentMessages.value;
        await db.saveChat(activeChatChar.id, chatData);
        updateContextCutoff();
    }
    
    clearSelection();
}

async function toggleHideSelectedMessages() {
    if (selectedMessages.value.size === 0) return;
    
    for (const msg of currentMessages.value) {
        if (msg && selectedMessages.value.has(msg.timestamp)) {
            msg.isHidden = !msg.isHidden;
        }
    }
    
    if (activeChatChar) {
        let chatData = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || chatData.currentId;
        chatData.sessions[sessionId] = currentMessages.value;
        await db.saveChat(activeChatChar.id, chatData);
        updateContextCutoff();
    }
    
    clearSelection();
}

// --- Display Logic (Separators) ---
const displayMessages = computed(() => {
    const msgs = currentMessages.value;
    if (!msgs || msgs.length === 0) return [];
    
    const res = [];
    let lastDateKey = null;
    
    for (let i = 0; i < msgs.length; i++) {
        const msg = msgs[i];
        if (!msg) continue;
        const d = new Date(msg.timestamp);
        const dateKey = d.toDateString();
        
        if (dateKey !== lastDateKey) {
            res.push({ type: 'separator', timestamp: msg.timestamp, id: `sep_${dateKey}` });
            lastDateKey = dateKey;
        }
        
        if (i === cutoffIndex.value && i > 0) {
            res.push({ type: 'cutoff', id: 'context-cutoff' });
        }
        
        res.push({ type: 'message', data: msg, originalIndex: i, id: `msg_${msg.timestamp}_${i}` });
    }
    
    if (cutoffIndex.value >= msgs.length && msgs.length > 0) {
        res.push({ type: 'cutoff', id: 'context-cutoff-end' });
    }
    
    return res;
});

// --- Virtual Scroll Setup ---
const { visibleItems, paddingTop, paddingBottom, refresh: refreshVirtualScroll, scrollToBottom: vsScrollToBottom, isScrolling, isProgrammaticScrolling, getScrollAnchor, scrollToAnchor, scrollToIndex, isItemVisible } = useVirtualScroll(displayMessages, messagesContainer, {
    buffer: 75, // Significantly increased buffer for smoother fast scrolling
    estimateHeight: 100
});

const onScroll = (e) => {
    const el = e.target;
    if (isSearchMode.value) {
        showScrollButton.value = false;
        return;
    }
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight;
    showScrollButton.value = distance > 100;
};

// Expose vsScrollToBottom
window.forceScrollToBottom = () => { vsScrollToBottom('auto') };

// Helper to access translations
const t = (key) => translations[currentLang.value]?.[key] || key;

const contextSegments = computed(() => {
    const breakdown = contextBreakdown.value;
    if (!breakdown || !breakdown.safeContext) return { used: [], reserve: null };

    const total = breakdown.safeContext;
    const toPercent = (value) => Math.max(0, Math.min(100, (value / total) * 100));
    const used = [];

    if (breakdown.character > 0) {
        used.push({ key: 'character', value: breakdown.character, percent: toPercent(breakdown.character), className: 'segment-character' });
    }
    if (breakdown.preset > 0) {
        used.push({ key: 'preset', value: breakdown.preset, percent: toPercent(breakdown.preset), className: 'segment-fixed' });
    }
    if (breakdown.authorsNote > 0) {
        used.push({ key: 'authorsNote', value: breakdown.authorsNote, percent: toPercent(breakdown.authorsNote), className: 'segment-authors-note' });
    }
    if (breakdown.summary > 0) {
        used.push({ key: 'summary', value: breakdown.summary, percent: toPercent(breakdown.summary), className: 'segment-summary' });
    }
    if (breakdown.lorebook > 0) {
        used.push({ key: 'lorebook', value: breakdown.lorebook, percent: toPercent(breakdown.lorebook), className: 'segment-lorebook' });
    }
    if (breakdown.history > 0) {
        used.push({ key: 'history', value: breakdown.history, percent: toPercent(breakdown.history), className: 'segment-history' });
    }

    return {
        used,
        reserve: breakdown.lorebookReserve > 0
            ? { key: 'lorebookReserve', value: breakdown.lorebookReserve, percent: toPercent(breakdown.lorebookReserve), className: 'segment-lorebook-reserve' }
            : null
    };
});

const contextBreakdownItems = computed(() => {
    const breakdown = contextBreakdown.value;
    if (!breakdown) return [];

    return [
        { key: 'character', label: 'Character', value: breakdown.character || 0 },
        { key: 'preset', label: 'Preset', value: breakdown.preset || 0 },
        { key: 'authorsNote', label: 'Author\'s Note', value: breakdown.authorsNote || 0 },
        { key: 'summary', label: 'Summary', value: breakdown.summary || 0 },
        { key: 'lorebook', label: 'Lorebook Used', value: breakdown.lorebook || 0 },
        { key: 'lorebookReserve', label: 'Lorebook Reserve', value: breakdown.lorebookReserve || 0 },
        { key: 'history', label: 'History', value: breakdown.history || 0 }
    ];
});

const contextLegendItems = computed(() => [
    { key: 'character', label: 'Character', className: 'segment-character' },
    { key: 'preset', label: 'Preset', className: 'segment-fixed' },
    { key: 'authorsNote', label: 'Author\'s Note', className: 'segment-authors-note' },
    { key: 'summary', label: 'Summary', className: 'segment-summary' },
    { key: 'lorebook', label: 'Lorebook Used', className: 'segment-lorebook' },
    { key: 'history', label: 'History', className: 'segment-history' },
    { key: 'lorebookReserve', label: 'Lorebook Reserve', className: 'segment-lorebook-reserve' }
]);

const visibleHistoryMessages = computed(() => {
    return currentMessages.value.filter(m => m && !m.isTyping && !m.isHidden);
});

const historyUsagePercent = computed(() => {
    const breakdown = contextBreakdown.value;
    if (!breakdown) return 0;
    const available = breakdown.availableForHistory || 0;
    if (available <= 0) return breakdown.history > 0 ? 100 : 0;
    return Math.max(0, Math.min(100, Math.round(((breakdown.history || 0) / available) * 100)));
});

const historyHidePreview = computed(() => {
    const messages = visibleHistoryMessages.value;
    const percent = Math.max(1, Math.min(95, historyHidePercent.value || 30));
    if (!messages.length) return { count: 0, tokens: 0 };

    const count = Math.max(1, Math.min(messages.length, Math.ceil(messages.length * percent / 100)));
    const tokens = messages
        .slice(0, count)
        .reduce((sum, msg) => sum + estimateTokens(msg.text || ''), 0);

    return { count, tokens };
});

const shouldRecommendHide = computed(() => {
    const breakdown = contextBreakdown.value;
    if (!breakdown || !breakdown.history) return false;
    const threshold = Math.max(1, Math.min(100, historyFillThreshold.value || 85));
    return historyUsagePercent.value >= threshold;
});


// --- Search Logic ---
watch(searchQuery, (newVal) => {
    if (!newVal || !isSearchMode.value) {
        searchResults.value = [];
        currentSearchIndex.value = -1;
        return;
    }
    const query = newVal.toLowerCase();
    const results = [];
    currentMessages.value.forEach((msg, idx) => {
        if (msg && msg.text) {
            const text = msg.text.toLowerCase();
            let lastIdx = -1;
            while ((lastIdx = text.indexOf(query, lastIdx + 1)) !== -1) {
                results.push({ msgIdx: idx, matchIdx: lastIdx });
            }
        }
    });
    searchResults.value = results;
    if (results.length > 0) {
        currentSearchIndex.value = results.length - 1; // Start from most recent (bottom)
        scrollToSearchResult();
    } else {
        currentSearchIndex.value = -1;
    }
});

function scrollToSearchResult() {
    if (currentSearchIndex.value >= 0 && currentSearchIndex.value < searchResults.value.length) {
        const { msgIdx } = searchResults.value[currentSearchIndex.value];
        const displayIndex = displayMessages.value.findIndex(m => m.type === 'message' && m.originalIndex === msgIdx);
        if (displayIndex !== -1) {
            scrollToIndex(displayIndex, 'smooth').then(() => {
                const el = document.getElementById(`msg-${msgIdx}`);
                if (el) {
                    el.classList.add('search-highlight');
                    setTimeout(() => el.classList.remove('search-highlight'), 1500);
                }
            });
        }
    }
}

function nextSearchResult() {
    if (searchResults.value.length === 0) return;
    currentSearchIndex.value = (currentSearchIndex.value + 1) % searchResults.value.length;
    scrollToSearchResult();
}

function prevSearchResult() {
    if (searchResults.value.length === 0) return;
    currentSearchIndex.value = (currentSearchIndex.value - 1 + searchResults.value.length) % searchResults.value.length;
    scrollToSearchResult();
}

const searchMatchState = computed(() => {
    if (!isSearchMode.value || searchResults.value.length === 0 || currentSearchIndex.value < 0) return { msgIdx: -1, occurrenceIdx: -1 };
    const activeMatch = searchResults.value[currentSearchIndex.value];
    let occurrenceIdx = 0;
    for (let i = 0; i < currentSearchIndex.value; i++) {
        if (searchResults.value[i].msgIdx === activeMatch.msgIdx) {
            occurrenceIdx++;
        }
    }
    return {
        msgIdx: activeMatch.msgIdx,
        occurrenceIdx: occurrenceIdx
    };
});

const onChatSearchToggle = (e) => {
    isSearchMode.value = e.detail;
    if (!isSearchMode.value) {
        searchQuery.value = '';
    }
};

const onChatSearch = (e) => {
    searchQuery.value = e.detail;
};

// --- Data Management ---

async function loadChats() {
    // Preserve in-memory data for ANY character currently generating
    for (const charId of Object.keys(generatingStates)) {
        const memData = await getChatData(charId);
        if (!memData) continue;

        const state = generatingStates[charId];

        let foundMsg = null;
        let foundSessionId = memData.currentId;

        if (memData.sessions[foundSessionId]) {
            foundMsg = memData.sessions[foundSessionId].find(m => m.id === state.msgId);
        }
        if (!foundMsg) {
            for (const [sid, sess] of Object.entries(memData.sessions)) {
                const m = sess.find(msg => msg.id === state.msgId);
                if (m) {
                    foundMsg = m;
                    foundSessionId = sid;
                    break;
                }
            }
        }

        if (foundMsg) {
            if (!memData.sessions[foundSessionId]) memData.sessions[foundSessionId] = [];
            const dbSession = memData.sessions[foundSessionId];
            const dbIdx = dbSession.findIndex(m => m.id === state.msgId);
            if (dbIdx !== -1) {
                dbSession[dbIdx] = foundMsg;
            } else {
                dbSession.push(foundMsg);
            }
            await db.saveChat(charId, memData);
        }
    }

    if (activeChatChar) {
        const data = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || data.currentId;
        if (data && data.sessions && data.sessions[sessionId]) {
            currentMessages.value = data.sessions[sessionId];
        } else {
            currentMessages.value = [];
        }
    }
}

async function updateContextCutoff() {
    if (!activeChatChar || !currentMessages.value) return;

    if (isOpeningChat) {
        pendingCutoffRecalc = true;
        return;
    }

    if (isCalculatingCutoff) {
        pendingCutoffRecalc = true;
        return;
    }

    isCalculatingCutoff = true;
    
    const currentCharId = activeChatChar.id;
    const history = currentMessages.value
        .filter(m => m && !m.isTyping && !m.isHidden)
        .map((m, i) => ({ role: m.role === 'user' ? 'user' : 'assistant', content: m.text || "", originalIndex: i }));
        
    const chatData = await getChatData(activeChatChar.id);
    const sessionId = chatData.currentId;
    const summary = chatData.summaries?.[sessionId];
    
    let authorsNote = null;
    if (chatData.authorsNotes && chatData.authorsNotes[sessionId]) {
        const storedAn = chatData.authorsNotes[sessionId];
        let anContent = typeof storedAn === 'string' ? storedAn : storedAn.content;
        
        const effectivePreset = getEffectivePreset(activeChatChar.id, sessionId ? `${activeChatChar.id}_${sessionId}` : null);
        const anBlock = effectivePreset?.blocks?.find(b => b.id === 'authors_note');
        if (anBlock && anBlock.enabled && anContent) {
            authorsNote = {
                content: anContent,
                role: anBlock.role || 'system',
                enabled: true,
                depth: anBlock.depth !== undefined ? anBlock.depth : 0,
                insertion_mode: anBlock.insertion_mode || 'relative'
            };
        }
    }

    try {
        const result = await calculateContext({
            char: activeChatChar,
            history,
            authorsNote,
            summary
        });
        
        if (activeChatChar && activeChatChar.id === currentCharId) {
            cutoffIndex.value = result?.cutoffIndex ?? 0;
            contextBreakdown.value = result?.contextBreakdown || null;
        }
    } finally {
        isCalculatingCutoff = false;
        if (pendingCutoffRecalc) {
            pendingCutoffRecalc = false;
            if (cutoffRerunTimer) clearTimeout(cutoffRerunTimer);
            cutoffRerunTimer = setTimeout(() => {
                updateContextCutoff();
            }, 0);
        }
    }
}

async function updateSessionMessage(char, msgIndex, newMsgData) {
    let data = await getChatData(char.id);
    if (data && data.sessions[data.currentId]) {
        data.sessions[data.currentId][msgIndex] = newMsgData;
        await db.saveChat(char.id, data);
    }
}

function clampHistoryFillThreshold(value) {
    const parsed = parseInt(value, 10);
    if (Number.isNaN(parsed)) return 85;
    return Math.max(1, Math.min(100, parsed));
}

function clampHistoryHidePercent(value) {
    const parsed = parseInt(value, 10);
    if (Number.isNaN(parsed)) return 30;
    return Math.max(1, Math.min(95, parsed));
}

function persistHistoryContextSettings(fillThreshold, hidePercent) {
    historyFillThreshold.value = clampHistoryFillThreshold(fillThreshold);
    historyHidePercent.value = clampHistoryHidePercent(hidePercent);
    localStorage.setItem(HISTORY_FILL_THRESHOLD_KEY, String(historyFillThreshold.value));
    localStorage.setItem(HISTORY_HIDE_PERCENT_KEY, String(historyHidePercent.value));
}

async function saveCurrentMessages() {
    if (!activeChatChar) return;
    const data = await getChatData(activeChatChar.id);
    if (!data) return;
    const sessionId = activeChatChar.sessionId || data.currentId;
    data.sessions[sessionId] = currentMessages.value;
    await db.saveChat(activeChatChar.id, data);
}

function openHistoryContextSettings() {
    const content = document.createElement('div');
    content.className = 'context-sheet';
    content.innerHTML = `
        <div class="settings-item">
            <label>History fill threshold (%)</label>
            <input id="history-fill-threshold" type="number" min="1" max="100" value="${historyFillThreshold.value}">
        </div>
        <div class="settings-item">
            <label>Hide top messages (%)</label>
            <input id="history-hide-percent" type="number" min="1" max="95" value="${historyHidePercent.value}">
        </div>
        <div class="context-sheet-note">Hide top messages recommendation appears when visible history reaches the configured threshold.</div>
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-secondary" id="history-context-back">Back</button>
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" id="history-context-save">Save</button>
        </div>
    `;

    const fillInput = content.querySelector('#history-fill-threshold');
    const hideInput = content.querySelector('#history-hide-percent');
    const saveBtn = content.querySelector('#history-context-save');
    const backBtn = content.querySelector('#history-context-back');

    backBtn.addEventListener('click', () => {
        closeBottomSheet();
        setTimeout(() => openContextSheet(), 250);
    });
    saveBtn.addEventListener('click', () => {
        persistHistoryContextSettings(fillInput?.value, hideInput?.value);
        closeBottomSheet();
        setTimeout(() => openContextSheet(), 250);
    });

    showBottomSheet({
        title: 'History Context Settings',
        content,
        isSolid: true
    });
}

async function hideTopMessagesNow() {
    const count = historyHidePreview.value.count;
    if (!count || !activeChatChar) return;

    let hidden = 0;
    for (const msg of currentMessages.value) {
        if (!msg || msg.isTyping || msg.isHidden) continue;
        msg.isHidden = true;
        hidden += 1;
        if (hidden >= count) break;
    }

    if (!hidden) return;

    await saveCurrentMessages();
    await updateContextCutoff();
    closeBottomSheet();
    showToast(`Hidden ${hidden} top message${hidden === 1 ? '' : 's'}`);
}

function confirmHideTopMessages() {
    const preview = historyHidePreview.value;
    if (!preview.count) return;

    showBottomSheet({
        title: 'Hide Top Messages',
        items: [
            {
                label: 'Open Summary',
                hint: 'Review or generate a summary first',
                icon: '<svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-2 14H7v-2h10v2zm0-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    setTimeout(() => presetView.value?.openSummarySheet(), 250);
                }
            },
            {
                label: `Hide ${preview.count} message${preview.count === 1 ? '' : 's'} now`,
                hint: `Free about ${preview.tokens} tokens`,
                icon: '<svg viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27z"/></svg>',
                onClick: () => {
                    hideTopMessagesNow();
                }
            },
            {
                label: 'Cancel',
                onClick: () => closeBottomSheet()
            }
        ]
    });
}

async function openContextSheet() {
    if (!contextBreakdown.value && activeChatChar) {
        await updateContextCutoff();
    }

    const breakdown = contextBreakdown.value;
    if (!breakdown) {
        showBottomSheet({
            title: 'Context',
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M11 17h2v-6h-2v6zm0-8h2V7h-2v2zm1-7C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/></svg>',
                description: 'Context breakdown is not ready yet. Try again in a moment.',
                buttonText: 'Close',
                onButtonClick: () => closeBottomSheet()
            }
        });
        return;
    }

    const used = breakdown.totalUsed || 0;
    const safeContext = breakdown.safeContext || 0;
    const remaining = Math.max(0, breakdown.remaining || 0);
    const preview = historyHidePreview.value;
    const content = document.createElement('div');
    content.className = 'context-sheet';

    const usedWidth = Math.max(0, 100 - (contextSegments.value.reserve?.percent || 0));
    const segmentHtml = contextSegments.value.used.map(segment => `
        <div class="chat-context-segment ${segment.className}" style="width:${segment.percent}%"></div>
    `).join('');

    const reserveHtml = contextSegments.value.reserve
        ? `<div class="chat-context-reserve ${contextSegments.value.reserve.className}" style="width:${contextSegments.value.reserve.percent}%"></div>`
        : '';

    const legendHtml = contextLegendItems.value.map(segment => `
        <div class="context-legend-item">
            <span class="context-legend-swatch ${segment.className}"></span>
            <span>${segment.label}</span>
        </div>
    `).join('');

    const breakdownHtml = contextBreakdownItems.value.map(item => `
        <div class="context-breakdown-row">
            <span>${item.label}</span>
            <strong>${item.value}</strong>
        </div>
    `).join('');

    const recommendationHtml = shouldRecommendHide.value ? `
        <div class="context-recommendation">
            <div class="context-recommendation-title">History is near its limit</div>
            <div class="context-recommendation-text">Hide about ${preview.count} top message${preview.count === 1 ? '' : 's'} to free about ${preview.tokens} tokens.</div>
        </div>
    ` : '';

    const hideButtonLabel = preview.count
        ? `Hide top ${preview.count}`
        : 'Hide top messages';

    content.innerHTML = `
        <div class="context-sheet-summary">
            <div class="context-sheet-kpi">
                <strong>${used}</strong>
                <span>used / ${breakdown.contextSize || safeContext}</span>
            </div>
            <div class="context-sheet-kpi">
                <strong>${remaining}</strong>
                <span>remaining</span>
            </div>
            <div class="context-sheet-kpi">
                <strong>${historyUsagePercent.value}%</strong>
                <span>history fill</span>
            </div>
        </div>
        <div class="chat-context-bar context-sheet-bar">
            <div class="chat-context-used" style="width:${usedWidth}%">${segmentHtml}</div>
            ${reserveHtml}
        </div>
        <div class="context-legend">${legendHtml}</div>
        <div class="context-breakdown">${breakdownHtml}</div>
        ${recommendationHtml}
        <div class="context-sheet-actions">
            <button type="button" class="context-sheet-btn context-sheet-btn-primary" id="context-hide-btn">${hideButtonLabel}</button>
            <button type="button" class="context-sheet-btn context-sheet-btn-secondary" id="context-settings-btn">Settings</button>
        </div>
    `;

    content.querySelector('#context-settings-btn')?.addEventListener('click', () => {
        openHistoryContextSettings();
    });

    content.querySelector('#context-hide-btn')?.addEventListener('click', () => {
        confirmHideTopMessages();
    });

    showBottomSheet({
        title: 'Context',
        content,
        isSolid: true
    });
}

async function setupHeader(char = activeChatChar) {
    if (!char) return;
    const data = await getChatData(char.id);
    const initialSessionId = char.sessionId || (data ? data.currentId : '...');
    const sessionName = data?.sessionNames?.[initialSessionId];

    window.dispatchEvent(new CustomEvent('header-setup-chat', { 
        detail: { 
            char, 
            currentSessionId: initialSessionId, 
            sessionName,
            callbacks: {
                onActionsClick: () => openSessionsSheet(char),
                onBackClick: () => {
                    closeChat();
                    if (currentOnBack) currentOnBack();
                }
            } 
        } 
    }));
}

const onFsEditorClosed = async () => {
    if (activeChatChar) {
        // Restore chat header when FS editor is closed
        await setupHeader(activeChatChar);
    }
};

async function openChat(char, onBack, force = false) {
    let targetSessionId = char.sessionId;
    if (targetSessionId === undefined) {
        const memData = await getChatData(char.id);
        targetSessionId = memData ? memData.currentId : undefined;
    }

    // Prevent reloading if the requested chat is already open and active
    if (!force && activeChatChar && String(activeChatChar.id) === String(char.id) && String(activeChatChar.sessionId) === String(targetSessionId) && !isOpeningChat) {
        if (char.msgId) {
            const msgIdx = currentMessages.value.findIndex(m => m.id === char.msgId);
            if (msgIdx !== -1) {
                const displayIndex = displayMessages.value.findIndex(
                    m => m.type === 'message' && m.originalIndex === msgIdx
                );
                if (displayIndex !== -1) {
                    scrollToAnchor({ index: displayIndex, offset: 0 });
                    nextTick(() => {
                        const el = document.getElementById(`msg-${msgIdx}`);
                        if (el) {
                            el.classList.add('search-highlight');
                            setTimeout(() => el.classList.remove('search-highlight'), 2000);
                        }
                    });
                }
            }
            delete char.msgId;
        }
        
        if (onBack && currentOnBack !== onBack) {
            currentOnBack = onBack;
        }

        clearMessageNotifications(char.id);
        return;
    }

    isOpeningChat = true;
    isLoading.value = true;

    try {
    // Attempt to migrate legacy stats locally
    await migrateStatsIfNeeded();

    // Hide tabbar immediately to prevent flickering
    const tabbar = document.querySelector('.tabbar');
    if (tabbar) tabbar.style.display = 'none';

    if (onBack) currentOnBack = onBack;
    // Cleanup previous scroll listener if exists to prevent leaks/conflicts
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }

    // Setup header immediately to start transition before loader covers screen
    setupHeader(char);

    clearMessageNotifications(char.id);

    await loadChats();

    if (char.sessionId) {
        const data = await getChatData(char.id);
        if (data && data.sessions && data.sessions[char.sessionId]) {
            if (data.currentId !== char.sessionId) {
                data.currentId = char.sessionId;
                await db.saveChat(char.id, data);
            }
        }
    }

    const chatData = await getChatData(char.id);
    const currentSessionId = chatData.currentId;

    activeChatChar = { ...char, sessionId: char.sessionId || currentSessionId };
    setTrackedContext(activeChatChar.id, activeChatChar.sessionId);
    
    // Explicitly strip legacy properties from the base character reference 
    // to prevent leakage from DB payloads saved before the fixes.
    delete activeChatChar.authors_note;
    delete activeChatChar.summary;

    activeChar.value = activeChatChar;
    isGenerating.value = !!generatingStates[char.id];

    // Clear unread
    let unread = (await db.get('gz_unread')) || {};
    if (unread[char.id]) {
        delete unread[char.id];
        await db.set('gz_unread', unread);
    }


    const effectivePreset = getEffectivePreset(char.id, currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const presetSummary = effectivePreset.blocks?.find(b => b.id === 'summary');
    const presetAN = effectivePreset.blocks?.find(b => b.id === 'authors_note');

    // Remove legacy properties when creating new sessions to avoid picking them up
    // However, if they exist from before the fix, we should wipe them during load.
    if (!chatData.authorsNotes?.[currentSessionId]) { 
        delete activeChatChar.authors_note; 
    } 
    if (!chatData.summaries?.[currentSessionId]) { 
        delete activeChatChar.summary; 
    }

    // Inject Session Data for GenerationView binding
    let summaryData = chatData.summaries?.[currentSessionId];
    if (typeof summaryData === 'string') {
        summaryData = { 
            content: summaryData, 
            depth: presetSummary?.depth !== undefined ? presetSummary.depth : 4, 
            role: presetSummary?.role || 'system', 
            insertion_mode: presetSummary?.insertion_mode || 'relative' 
        };
    } else if (!summaryData) {
        summaryData = null;
    }
    
    let anData = chatData.authorsNotes?.[currentSessionId];
    if (typeof anData === 'object' && anData !== null) {
        anData = anData.content || null;
    } else if (typeof anData !== 'string') {
        anData = null;
    }
    
    // Author's Note and Summary settings are now directly in the preset, not in char/chat data.
    // Content is still in char data.
    if (anData !== null) activeChatChar.authors_note = anData;
    else delete activeChatChar.authors_note;
    
    if (summaryData !== null) activeChatChar.summary = summaryData.content;
    else delete activeChatChar.summary;
    
    if (activeChar.value) {
        if (anData !== null) activeChar.value.authors_note = anData;
        else delete activeChar.value.authors_note;
        
        if (summaryData !== null) activeChar.value.summary = summaryData.content;
        else delete activeChar.value.summary;
    }

    // Update header session if it was placeholder
    if (!activeChatChar.sessionId) {
        setupHeader(activeChatChar);
    }

    // Load messages
    let msgs = chatData.sessions[currentSessionId];
    if (!msgs) {
        msgs = [];
        chatData.sessions[currentSessionId] = msgs;
    }

    // Filter out corrupted/null messages
    msgs = msgs.filter(m => m !== null && m !== undefined);
    // Backfill unique IDs for legacy messages
    msgs.forEach(m => { if (!m.id) m.id = `legacy_${m.timestamp || Date.now()}_${Math.random().toString(36).slice(2, 6)}`; });
    chatData.sessions[currentSessionId] = msgs;

    // Cleanup phantom generations or errors
    let dirty = false;
    while (msgs.length > 0) {
        const lastMsg = msgs[msgs.length - 1];
        const isPhantomTyping = lastMsg.isTyping && !generatingStates[char.id];

        if (isPhantomTyping) {
            if (lastMsg.swipes && lastMsg.swipes.length > 1) {
                // Revert to previous swipe if interrupted
                const failedSwipeId = lastMsg.swipeId || (lastMsg.swipes.length - 1);
                lastMsg.swipes.splice(failedSwipeId, 1);
                if (lastMsg.swipesMeta) lastMsg.swipesMeta.splice(failedSwipeId, 1);
                
                let newSwipeId = failedSwipeId - 1;
                if (newSwipeId < 0) newSwipeId = 0;
                
                lastMsg.swipeId = newSwipeId;
                lastMsg.text = lastMsg.swipes[newSwipeId] || "";
                lastMsg.isTyping = false;
                
                if (lastMsg.swipesMeta && lastMsg.swipesMeta[newSwipeId]) {
                    lastMsg.reasoning = lastMsg.swipesMeta[newSwipeId].reasoning;
                    lastMsg.genTime = lastMsg.swipesMeta[newSwipeId].genTime;
                    lastMsg.guidanceText = lastMsg.swipesMeta[newSwipeId].guidanceText || null;
                    lastMsg.guidanceType = lastMsg.swipesMeta[newSwipeId].guidanceType || 'GENERATION';
                } else {
                    lastMsg.reasoning = null;
                    lastMsg.genTime = null;
                    lastMsg.guidanceText = null;
                    lastMsg.guidanceType = 'GENERATION';
                }
                dirty = true;
                break;
            } else {
                msgs.pop();
                dirty = true;
            }
        } else {
            break;
        }
    }
    if (dirty) {
        await db.saveChat(char.id, chatData);
    }

    // Cleanup stuck imggen-loading states (saved during interrupted generation).
    // Convert them back to canonical <img data-iig-instruction='...' src="[IMG:GEN]"> so
    // processMessageImages can pick them up and regenerate on this load.
    {
        const loadingSpanRe = /<span\b[^>]*\bclass="[^"]*\bimggen-loading\b[^"]*"[^>]*data-iig-instruction='([^']*)'[^>]*>(?:<span[^>]*>[^<]*<\/span>)*<\/span>/g;
        let dirtyImggen = false;
        const fixText = (t) => t ? t.replace(loadingSpanRe, (_, enc) => `<img data-iig-instruction='${enc}' src="[IMG:GEN]">`) : t;
        for (const msg of msgs) {
            if (!msg?.text?.includes('imggen-loading')) continue;
            const newText = fixText(msg.text);
            if (newText !== msg.text) {
                msg.text = newText;
                if (msg.swipes) msg.swipes = msg.swipes.map(fixText);
                dirtyImggen = true;
            }
        }
        if (dirtyImggen) {
            chatData.sessions[currentSessionId] = msgs;
            await db.saveChat(char.id, chatData);
        }
    }

    currentMessages.value = msgs;
    
    // First Message Logic
    const persona = activePersona.value;
    const greetings = getAllGreetings(char, persona);
    if (currentMessages.value.length === 0 && greetings.length > 0) {
        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        const firstMsg = {
            id: genMsgId(),
            role: 'char',
            text: greetings[0],
            time: time,
            genTime: '0s',
            tokens: estimateTokens(greetings[0]),
            greetingIndex: 0,
            swipes: greetings,
            swipeId: 0,
            timestamp: Date.now()
        };
        currentMessages.value.push(firstMsg);
        if (activeChatChar) {
            const data = await getChatData(activeChatChar.id);
            if (data) {
                data.sessions[data.currentId] = currentMessages.value;
                await db.saveChat(activeChatChar.id, data);
            }
        }
        scrollToBottom(false);
    }

    // Restore draft
    inputValue.value = chatData.draft || '';
    pendingCutoffRecalc = true;

    // Reset virtual scroll (defaults to bottom)
    refreshVirtualScroll();

    nextTick(async () => {
        updateAppColors();
        
        if (char.msgId) {
            const msgIdx = currentMessages.value.findIndex(m => m.id === char.msgId);
            if (msgIdx !== -1) {
                const displayIndex = displayMessages.value.findIndex(
                    m => m.type === 'message' && m.originalIndex === msgIdx
                );
                if (displayIndex !== -1) {
                    // Use scrollToAnchor for instant positioning without jitter
                    await scrollToAnchor({ index: displayIndex, offset: 0 });
                    nextTick(() => {
                        const el = document.getElementById(`msg-${msgIdx}`);
                        if (el) {
                            el.classList.add('search-highlight');
                            setTimeout(() => el.classList.remove('search-highlight'), 2000);
                        }
                    });
                }
            }
            delete char.msgId;
        } else if (chatData.lastScrollAnchor) {
            await scrollToAnchor(chatData.lastScrollAnchor);
        } else {
             if (messagesContainer.value) messagesContainer.value.scrollTop = messagesContainer.value.scrollHeight;
        }
        
        // Init scroll listener for header
        if (messagesContainer.value) {
            // Delay slightly to allow scrollToAnchor to apply
            setTimeout(() => {
                const currentScroll = messagesContainer.value ? messagesContainer.value.scrollTop : 0;
                _cleanupScroll = initHeaderScroll(messagesContainer.value, currentScroll);
            }, 50);
            messagesContainer.value.addEventListener('scroll', onScroll);
            onScroll({ target: messagesContainer.value });
            applyImageAutoHide();
        }
        // updateInputPreview(); // Handled by ChatInput component

        // Restore generation state if active
        if (generatingStates[char.id]) {
            const state = generatingStates[char.id];
            
            // Clear previous timer if exists (from previous mount)
            if (state.timerId) clearInterval(state.timerId);

            // Define updater for this component instance
            state.onUIUpdate = (text, reasoning, isTyping, textDelta) => {
                const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
                if (idx !== -1) {
                    const m = currentMessages.value[idx];
                    if (textDelta) {
                        // Remove stream animation from previously rendered characters
                        m.text = m.text.replace(/class="stream-char"/g, 'class="stream-char-done"');
                        m.text += `<span class="stream-char">${textDelta}</span>`;
                    } else {
                        m.text = text;
                    }
                    m.reasoning = reasoning;
                    m.isTyping = isTyping;
                    smartScroll();
                }
            };

            // Restart timer for this component instance
            state.timerId = setInterval(() => {
                const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
                if (idx !== -1) {
                    const elapsed = ((Date.now() - state.startTime) / 1000).toFixed(1) + 's';
                    currentMessages.value[idx].genTime = elapsed;
                }
            }, 100);
        }
    });

    // Lorebook Banner Trigger
    const activeLbs = getActiveLorebooksForContext(char.id, char.id && currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const presetName = effectivePreset ? effectivePreset.name : '';
    const effPersona = getEffectivePersona(char.id, currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const personaName = effPersona ? effPersona.name : '';

    if (activeLbs.length > 0 || presetName || personaName) {
        window.dispatchEvent(new CustomEvent('header-show-lb-banner', { 
            detail: {
                names: activeLbs,
                preset: presetName,
                persona: personaName
            }
        }));
    }

    } finally {
        isLoading.value = false;
        isOpeningChat = false;
        if (pendingCutoffRecalc) {
            pendingCutoffRecalc = false;
            updateContextCutoff();
        }
    }
}

function asyncSaveCurrentSessionState() {
    if (activeChatChar && messagesContainer.value) {
        // Capture activeChar synchronously since closing chat will nullify it
        const charContext = activeChatChar;
        const inputValueDraft = inputValue.value;
        const currentAnchor = getScrollAnchor();
        
        getChatData(charContext.id).then(data => {
            if (!data) return;
            // Save anchor instead of pixel position for reliable restoration
            data.lastScrollAnchor = currentAnchor;
            
            // Save draft of new message
            data.draft = inputValueDraft;

            // Remove edit state from messages (do not save draft of edited message)
            if (data.sessions && data.sessions[data.currentId]) {
                const msgs = data.sessions[data.currentId];
                for (let i = msgs.length - 1; i >= 0; i--) {
                    const msg = msgs[i];
                    if (msg.isEditing) {
                        msg.isEditing = false;
                        delete msg.editText;
                    }

                    if (msg.isError) {
                        if (msg.swipes && msg.swipes.length > 1) {
                            const errorSwipeId = msg.swipeId || 0;
                            msg.swipes.splice(errorSwipeId, 1);
                            if (msg.swipesMeta) msg.swipesMeta.splice(errorSwipeId, 1);
                            
                            let newSwipeId = errorSwipeId - 1;
                            if (newSwipeId < 0) newSwipeId = 0;
                            
                            msg.swipeId = newSwipeId;
                            msg.text = msg.swipes[newSwipeId] || "";
                            msg.isError = false;
                            
                            if (msg.swipesMeta && msg.swipesMeta[newSwipeId]) {
                                msg.reasoning = msg.swipesMeta[newSwipeId].reasoning;
                                msg.genTime = msg.swipesMeta[newSwipeId].genTime;
                            } else {
                                msg.reasoning = null;
                                msg.genTime = null;
                            }
                        } else {
                            msgs.splice(i, 1);
                        }
                    }
                }
                data.sessions[data.currentId] = msgs;
            }

            // Persist Author's Note and Summary content back to chat data
            const sessionId = data.currentId;
            if (charContext.authors_note !== undefined) {
                if (!data.authorsNotes) data.authorsNotes = {};
                data.authorsNotes[sessionId] = charContext.authors_note;
            }
            if (charContext.summary !== undefined) {
                if (!data.summaries) data.summaries = {};
                data.summaries[sessionId] = charContext.summary;
            }

            db.saveChat(charContext.id, data);
        });
    }
}

function closeChat() {
    updateAppColors(true); // Revert colors
    if (activeChatChar && messagesContainer.value) {
        asyncSaveCurrentSessionState();
        messagesContainer.value.removeEventListener('scroll', onScroll);
    }
    
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }

    window.dispatchEvent(new CustomEvent('header-reset'));
    activeChatChar = null;
    activeChar.value = null;
    setTrackedContext(null, null);
    currentMessages.value = [];
    inputValue.value = '';
}

function scrollToBottom(smooth = true) {
    vsScrollToBottom(smooth ? 'smooth' : 'auto');
}

function smartScroll() {
    if (isSearchMode.value) return;
    if (!showScrollButton.value) {
        scrollToBottom(false);
    }
}

async function sendMessage(attachedImage = null, guidanceText = null) {
    if (isGenerating.value && activeChatChar) {
        // Stop Generation
        const state = generatingStates[activeChatChar.id];
        if (state) {
            if (state.controller) state.controller.abort();
            if (state.restoreState) state.restoreState();

            if (state.type === 'impersonation') {
                isImpersonating.value = false;
            }

            delete generatingStates[activeChatChar.id];
            isGenerating.value = false;
        } else {
            // Stale isGenerating flag — no active generation found, just reset
            isGenerating.value = false;
        }
        return;
    }

    let effectiveGuidance = guidanceText;
    let effectiveGuidanceType = 'GENERATION';

    if (!effectiveGuidance && pendingGuidance.value) {
        effectiveGuidance = pendingGuidance.value.text;
        effectiveGuidanceType = pendingGuidance.value.type;
        pendingGuidance.value = null;
    }

    const text = inputValue.value.trim();
    const hasImage = typeof attachedImage === 'string';
    if (text || hasImage || effectiveGuidance) {

        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        
        const persona = activePersona.value;
        
        const processedText = replaceMacros(text, activeChatChar, persona);
        
        inputValue.value = '';

        const msgData = { 
            id: genMsgId(),
            role: 'user', 
            text: processedText, 
            time: time, 
            timestamp: now.getTime(),
            image: attachedImage, 
            tokens: estimateTokens(processedText),
            persona: { ...activePersona.value },
            guidanceText: effectiveGuidance,
            guidanceType: effectiveGuidanceType
        };
        currentMessages.value.push(msgData);
        if (activeChatChar) {
            const currentSessionId = activeChatChar.sessionId || (await getChatData(activeChatChar.id))?.currentId;
            addMessageStats(activeChatChar.id, currentSessionId, msgData.tokens, processedText.length, msgData.timestamp);
            const data = await getChatData(activeChatChar.id);
            if (data) {
                data.sessions[data.currentId] = currentMessages.value;
                await db.saveChat(activeChatChar.id, data);
            }
        }
        
        // Wait for vue to render the new item then force scroll to bottom
        nextTick(() => {
            scrollToBottom(false);
            if (window.forceScrollToBottom) {
                setTimeout(window.forceScrollToBottom, 100);
            }
        });
        
        if (activeChatChar) {
            startGeneration(activeChatChar, null, -1, null, effectiveGuidance, effectiveGuidanceType);
        }
    }
}

// --- Generation Logic ---

function startGeneration(char, text, existingMsgIndex = -1, onAbort = null, guidanceText = null, guidanceType = 'GENERATION') {
    // Check API Configuration
    const model = localStorage.getItem('api-model');
    const endpoint = localStorage.getItem('gz_api_endpoint_normalized') || localStorage.getItem('api-endpoint');
    
    if (!model || !endpoint) {
        showBottomSheet({
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                description: t('api_not_configured') || "API Not Configured",
                buttonText: t('btn_configure') || "Configure",
                onButtonClick: () => {
                    closeBottomSheet();
                    openApiView();
                }
            }
        });
        return;
    }

    const genId = ++genIdCounter;
    const controller = new AbortController();
    const startTime = Date.now();
    // Capture session ID at start
    let rawStreamText = text || "";
    let chatData = null;
    let sessionId = null;
    let summary = char.summary !== undefined ? char.summary : null;
    let anContent = char.authors_note !== undefined ? char.authors_note : null;

    if (!char.sessionId) {
        // Fallback for missing sessionId (e.g. from background task without activeChatChar)
        db.getChat(char.id).then(d => {
            chatData = d;
            sessionId = chatData?.currentId;
            if (summary === null) summary = chatData?.summaries?.[sessionId];
            if (typeof summary === 'object' && summary !== null) summary = summary.content;
            if (anContent === null) anContent = chatData?.authorsNotes?.[sessionId];
            if (typeof anContent === 'object' && anContent !== null) anContent = anContent.content;
            continueGeneration();
        }).catch(e => {
            console.error('Failed to load chat for generation:', e);
            isGenerating.value = false;
        });
        return; // wait for async db to finish
    } else {
        sessionId = char.sessionId;
        continueGeneration();
    }

    async function continueGeneration() {

    // Notify application about generation start
    window.dispatchEvent(new CustomEvent('chat-generation-started', { detail: { charId: char.id, sessionId: sessionId } }));

    isGenerating.value = true;
    let msgIndex = existingMsgIndex;

    // Get Authors Note combined object for current session and preset
    const effectivePreset = getEffectivePreset(char.id, sessionId ? `${char.id}_${sessionId}` : null);
    const anBlock = effectivePreset?.blocks?.find(b => b.id === 'authors_note');
    let authorsNote = null;
    
    if (typeof anContent === 'object' && anContent !== null) anContent = anContent.content;

    if (anBlock && anBlock.enabled && anContent) {
        authorsNote = {
            content: anContent,
            role: anBlock.role || 'system',
            enabled: true,
            depth: anBlock.depth !== undefined ? anBlock.depth : 0,
            insertion_mode: anBlock.insertion_mode || 'relative'
        };
    }

    if (msgIndex === -1 && !text) {
        const now = new Date();
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');

        const msg = { 
            id: genMsgId(),
            role: 'char', 
            text: "", 
            time: time, 
            timestamp: Date.now(),
            swipes: [""],
            swipeId: 0,
            isTyping: true, // Custom flag for UI
            guidanceText,
            guidanceType
        };
        currentMessages.value.push(msg);
        msgIndex = currentMessages.value.length - 1;
        const data = await getChatData(char.id);
        if (data) {
            data.sessions[sessionId] = currentMessages.value;
            await db.saveChat(char.id, data);
        }
        scrollToBottom();
    }

    // Get unique ID to identify message across re-mounts
    if (msgIndex !== -1 && currentMessages.value[msgIndex]) {
        const msg = currentMessages.value[msgIndex];
        msg.guidanceText = guidanceText;
        msg.guidanceType = guidanceType;
        // Force fallback to message-level guidance by clearing current swipe's metadata if it exists
        if (msg.swipesMeta && msg.swipesMeta[msg.swipeId || 0]) {
            msg.swipesMeta[msg.swipeId || 0].guidanceText = null;
            msg.swipesMeta[msg.swipeId || 0].guidanceType = null;
        }
    }
    const msgId = currentMessages.value[msgIndex]?.id || genMsgId();

    // Save generation status for DialogList
    localStorage.setItem(`gz_generating_${char.id}_${sessionId}`, 'true');

    // Initialize state
    // Setup initial UI updater inline to avoid null gap between state creation and assignment (#8)
    const initialUIUpdate = (text, reasoning, isTyping, textDelta) => {
        const idx = currentMessages.value.findIndex(m => m.id === msgId);
        if (idx !== -1) {
            const m = currentMessages.value[idx];
            if (textDelta) {
                m.text = m.text.replace(/class="stream-char"/g, 'class="stream-char-done"');
                m.text += `<span class="stream-char">${textDelta}</span>`;
            } else {
                m.text = text;
            }
            m.reasoning = reasoning;
            m.isTyping = isTyping;
            smartScroll();
        }
    };

    generatingStates[char.id] = { 
        genId, 
        controller, 
        startTime, 
        msgId,
        timerId: null,
        onUIUpdate: initialUIUpdate
    };

    generatingStates[char.id].timerId = setInterval(() => {
        if (activeChatChar && activeChatChar.id === char.id) {
            const idx = currentMessages.value.findIndex(m => m.id === msgId);
            if (idx !== -1) {
                const elapsed = ((Date.now() - startTime) / 1000).toFixed(1) + 's';
                currentMessages.value[idx].genTime = elapsed;
            }
        }
    }, 100);

    const restoreState = async (isError = false) => {
        if (_bgUpdateTimer) { clearTimeout(_bgUpdateTimer); _bgUpdateTimer = null; }
        if (generatingStates[char.id]?.timerId) clearInterval(generatingStates[char.id].timerId);
        localStorage.removeItem(`gz_generating_${char.id}_${sessionId}`);
        
        const idx = currentMessages.value.findIndex(m => m.id === msgId);
        if (idx !== -1) {
            // User is still viewing this chat — update reactive state
            currentMessages.value[idx].isTyping = false;

            if (!isError) {
                const msg = currentMessages.value[idx];
                if (msg.swipes && msg.swipes.length > 1) {
                    const currentSwipeId = msg.swipeId || 0;
                    msg.swipes.splice(currentSwipeId, 1);
                    if (msg.swipesMeta) msg.swipesMeta.splice(currentSwipeId, 1);
                    
                    let newSwipeId = currentSwipeId - 1;
                    if (newSwipeId < 0) newSwipeId = 0;
                    
                    msg.swipeId = newSwipeId;
                    msg.text = msg.swipes[newSwipeId] || "";
                    
                    // Restore guidance from the reverted swipe's meta
                    if (msg.swipesMeta && msg.swipesMeta[newSwipeId]) {
                        msg.guidanceText = msg.swipesMeta[newSwipeId].guidanceText || null;
                        msg.guidanceType = msg.swipesMeta[newSwipeId].guidanceType || 'GENERATION';
                    } else {
                        msg.guidanceText = null;
                        msg.guidanceType = 'GENERATION';
                    }
                    
                    if (msg.swipesMeta && msg.swipesMeta[newSwipeId]) {
                        msg.reasoning = msg.swipesMeta[newSwipeId].reasoning;
                        msg.genTime = msg.swipesMeta[newSwipeId].genTime;
                    }
                    updateSessionMessage(char, idx, msg);
                } else {
                    currentMessages.value.splice(idx, 1);
                    const data = await getChatData(char.id);
                    if (data && data.sessions[data.currentId]) {
                        data.sessions[data.currentId] = currentMessages.value;
                        await db.saveChat(char.id, data);
                    }
                }
            }
        } else {
            // User navigated away — clean up directly in DB
            const data = await getChatData(char.id);
            if (data && data.sessions[sessionId]) {
                const dbIdx = data.sessions[sessionId].findIndex(m => m.id === msgId);
                if (dbIdx !== -1) {
                    data.sessions[sessionId][dbIdx].isTyping = false;
                    if (!isError) {
                        const msg = data.sessions[sessionId][dbIdx];
                        if (msg.swipes && msg.swipes.length > 1) {
                            const currentSwipeId = msg.swipeId || 0;
                            msg.swipes.splice(currentSwipeId, 1);
                            if (msg.swipesMeta) msg.swipesMeta.splice(currentSwipeId, 1);
                            let newSwipeId = currentSwipeId - 1;
                            if (newSwipeId < 0) newSwipeId = 0;
                            msg.swipeId = newSwipeId;
                            msg.text = msg.swipes[newSwipeId] || "";
                        } else {
                            data.sessions[sessionId].splice(dbIdx, 1);
                        }
                    }
                    await db.saveChat(char.id, data);
                }
            }
        }
        if (onAbort) onAbort(isError);
    };

    generatingStates[char.id].restoreState = restoreState;

    const onError = async (e) => {
        const state = generatingStates[char.id];
        if (!state || state.genId !== genId) return;
        if (_bgUpdateTimer) { clearTimeout(_bgUpdateTimer); _bgUpdateTimer = null; }

        // Handle Context Limit gracefully (Bottom Sheet already shown by llmApi)
        if (e.message === "Context limit exceeded") {
            restoreState(false); // Treat as abort/cancel (removes typing indicator)
            delete generatingStates[char.id];
            if (activeChatChar && activeChatChar.id === char.id) isGenerating.value = false;
            window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId: sessionId } }));
            return;
        }

        restoreState(true);
        delete generatingStates[char.id];
        if (activeChatChar && activeChatChar.id === char.id) isGenerating.value = false;

        sendMessageNotification(
            `Error — ${char.name}`,
            e.message || 'Generation failed',
            char.avatar, char.id, sessionId, msgId
        );

        const idx = currentMessages.value.findIndex(m => m.id === msgId);
        if (idx !== -1) {
            // User is still viewing this chat
            const msg = currentMessages.value[idx];
            msg.text = formatError(e, rawStreamText);
            msg.isError = true;
            if (msg.swipes && msg.swipes.length > 0) {
                msg.swipes[msg.swipeId || 0] = msg.text;
            }
            updateSessionMessage(char, idx, msg);
        } else {
            // User navigated away — write error directly to DB
            const data = await getChatData(char.id);
            if (data && data.sessions[sessionId]) {
                const dbIdx = data.sessions[sessionId].findIndex(m => m.id === msgId);
                if (dbIdx !== -1) {
                    const msg = data.sessions[sessionId][dbIdx];
                    msg.text = formatError(e, rawStreamText);
                    msg.isError = true;
                    msg.isTyping = false;
                    if (msg.swipes && msg.swipes.length > 0) {
                        msg.swipes[msg.swipeId || 0] = msg.text;
                    }
                    await db.saveChat(char.id, data);
                }
            }
        }
        window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId: sessionId } }));
    };

    // Prepare history for LLM
    const history = currentMessages.value
        .map((m, i) => ({ ...m, originalIndex: i }))
        .filter(m => !m.isTyping && !m.isHidden)
        .map(m => ({ 
            role: m.role === 'user' ? 'user' : 'assistant', 
            content: m.text || "", 
            text: m.text || "", 
            image: (m.image && !m.imageHidden) ? m.image : null,
            chatId: m.originalIndex 
        }));

    let _bgUpdateTimer = null;
    let _bgPendingText = null;
    let _bgPendingReasoning = null;

    const onUpdate = async (chunk, reasoningChunk, effectiveText, effectiveReasoning, textDelta) => {
        rawStreamText = effectiveText || (rawStreamText + (chunk || ""));
        
        // Update via dynamic updater (handles re-mounts)
        const state = generatingStates[char.id];
        if (state && state.onUIUpdate) {
            state.onUIUpdate(effectiveText, effectiveReasoning, true, textDelta);
        } else {
            // Background update — throttle DB writes to once per 2s (#7)
            _bgPendingText = effectiveText;
            _bgPendingReasoning = effectiveReasoning;
            if (!_bgUpdateTimer) {
                _bgUpdateTimer = setTimeout(async () => {
                    _bgUpdateTimer = null;
                    if (_bgPendingText === null) return;
                    const data = await getChatData(char.id);
                    if (data && data.sessions[sessionId]) {
                        const dbMsg = data.sessions[sessionId].find(m => m.id === msgId);
                        if (dbMsg) {
                            dbMsg.text = _bgPendingText;
                            dbMsg.reasoning = _bgPendingReasoning;
                            await db.saveChat(char.id, data);
                        }
                    }
                }, 2000);
            }
        }
    };

    generateChatResponse({
        text,
        char,
        history,
        authorsNote,
        summary,
        guidanceText,
        type: 'normal',
        controller,
        callbacks: {
            onPromptReady: async ({ loreEntries }) => {
                let targetIndex = msgIndex;
                // Place lorebooks on the user message that triggered this generation, if it exists
                if (msgIndex > 0 && currentMessages.value[msgIndex - 1]?.role === 'user') {
                    targetIndex = msgIndex - 1;
                }
                if (targetIndex !== -1 && currentMessages.value[targetIndex]) {
                    const m = currentMessages.value[targetIndex];
                    m.triggeredLorebooks = loreEntries.map(e => ({
                        id: e.id,
                        // Lorebook entry display name: ST-compatible field is `comment`
                        name: e.comment || e.name || e.keys?.[0] || 'Entry',
                        content: e.content,
                        lorebookName: e.lorebookName,
                        lorebookId: e.lorebookId
                    }));
                    const data = await getChatData(char.id);
                    if (data) {
                        data.sessions[sessionId] = currentMessages.value;
                        await db.saveChat(char.id, data);
                    }
                }
            },
            onUpdate,
            onComplete: async (response, finalReasoning, meta) => {
        const currentState = generatingStates[char.id];
        if (currentState && currentState.timerId) clearInterval(currentState.timerId);
        if (_bgUpdateTimer) { clearTimeout(_bgUpdateTimer); _bgUpdateTimer = null; }
        localStorage.removeItem(`gz_generating_${char.id}_${sessionId}`);

        if (!currentState || currentState.genId !== genId) return;
        
        // Guard against race with abort
        if (controller.signal.aborted) {
            delete generatingStates[char.id];
            if (activeChatChar && activeChatChar.id === char.id) isGenerating.value = false;
            return;
        }

        let wasVisible = false;
        let displayIndex = -1;
        const foundIndex = currentMessages.value.findIndex(m => m.id === currentState.msgId);
        
        if (foundIndex !== -1) {
            displayIndex = displayMessages.value.findIndex(m => m.type === 'message' && m.originalIndex === foundIndex);
            if (displayIndex !== -1) {
                wasVisible = isItemVisible(displayIndex);
            }
        }

        delete generatingStates[char.id];
        if (activeChatChar && activeChatChar.id === char.id) isGenerating.value = false;

        const now = new Date();
        response = cleanText(response);
        const time = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
        const duration = ((Date.now() - startTime) / 1000).toFixed(2) + 's';

        // Try to find message in current view by timestamp, fallback to index if same instance
        if (activeChatChar && activeChatChar.id === char.id && foundIndex !== -1) {
            const msg = currentMessages.value[foundIndex];
            msg.text = response;
            msg.reasoning = finalReasoning;
            msg.time = time;
            msg.genTime = duration;
            msg.tokens = estimateTokens(response);
            msg.isTyping = false;
            if (meta?.partialError) {
                msg.isPartial = true;
                msg.partialErrorMsg = meta.partialError;
            }

            // Update swipes
            if (!msg.swipes) msg.swipes = [];
            if (!msg.swipesMeta) msg.swipesMeta = [];
            
            // If this was a new generation (not a swipe add), it's the first swipe
            if (msg.swipes.length === 1 && msg.swipes[0] === "") {
                msg.swipes[0] = response;
                msg.swipesMeta[0] = { 
                    genTime: duration, 
                    reasoning: finalReasoning, 
                    tokens: msg.tokens,
                    guidanceText: msg.guidanceText,
                    guidanceType: msg.guidanceType
                };
                addMessageStats(char.id, sessionId, msg.tokens, response.length, msg.timestamp);
            } else {
                msg.swipes[msg.swipeId || 0] = response;
                if (!msg.swipesMeta[msg.swipeId || 0]) msg.swipesMeta[msg.swipeId || 0] = {};
                msg.swipesMeta[msg.swipeId || 0].genTime = duration;
                msg.swipesMeta[msg.swipeId || 0].reasoning = finalReasoning;
                msg.swipesMeta[msg.swipeId || 0].tokens = msg.tokens;
                msg.swipesMeta[msg.swipeId || 0].guidanceText = guidanceText;
                msg.swipesMeta[msg.swipeId || 0].guidanceType = guidanceType;
                addRegenerationStats(char.id, sessionId, msg.tokens, response.length);
            }
            
            updateSessionMessage(char, foundIndex, msg);

            // Process image generation tags async (non-blocking)
            processMessageImages(msg.text, (updatedText) => {
                msg.text = updatedText;
                msg.swipes[msg.swipeId || 0] = updatedText;
                // Only persist to DB once all images are resolved (no loading states remain)
                if (!updatedText.includes('imggen-loading')) {
                    updateSessionMessage(char, foundIndex, msg);
                }
            }, { charAvatar: char.avatar || null, userAvatar: activePersona.value?.avatar || null, messages: currentMessages.value, currentMsgIndex: foundIndex }).then(finalText => {
                if (finalText !== msg.text) {
                    msg.text = finalText;
                    msg.swipes[msg.swipeId || 0] = finalText;
                    updateSessionMessage(char, foundIndex, msg);
                }
            }).catch(e => console.error('[ImageGen] processMessageImages failed:', e));

            if (wasVisible) {
                scrollToIndex(displayIndex, 'smooth', 'top');
            } else {
                smartScroll();
            }

            sendMessageNotification(char.name, response, char.avatar, char.id, sessionId, msgId);

            // Notify application about generation end (after update)
            window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId: sessionId } }));
        } else {
            // Background completion — write directly to DB, NOT currentMessages.value
            const bgData = await getChatData(char.id);
            if (bgData && bgData.sessions[sessionId]) {
                const bIdx = bgData.sessions[sessionId].findIndex(m => m.id === msgId);
                if (bIdx !== -1) {
                    const msg = bgData.sessions[sessionId][bIdx];
                    msg.text = response;
                    msg.reasoning = finalReasoning;
                    msg.time = time;
                    msg.genTime = duration;
                    msg.tokens = estimateTokens(response);
                    msg.isTyping = false;
                    if (meta?.partialError) {
                        msg.isPartial = true;
                        msg.partialErrorMsg = meta.partialError;
                    }

                    if (!msg.swipes) msg.swipes = [];
                    if (!msg.swipesMeta) msg.swipesMeta = [];
                    
                    if (msg.swipes.length === 1 && msg.swipes[0] === "") {
                        msg.swipes[0] = response;
                        msg.swipesMeta[0] = { genTime: duration, reasoning: finalReasoning, tokens: msg.tokens };
                        addMessageStats(char.id, sessionId, msg.tokens, response.length, msg.timestamp);
                    } else {
                        msg.swipes[msg.swipeId || 0] = response;
                        if (!msg.swipesMeta[msg.swipeId || 0]) msg.swipesMeta[msg.swipeId || 0] = {};
                        msg.swipesMeta[msg.swipeId || 0].genTime = duration;
                        msg.swipesMeta[msg.swipeId || 0].reasoning = finalReasoning;
                        msg.swipesMeta[msg.swipeId || 0].tokens = msg.tokens;
                        addRegenerationStats(char.id, sessionId, msg.tokens, response.length);
                    }
                    
                    processMessageImages(response, (updatedText) => {
                        msg.text = updatedText;
                        msg.swipes[msg.swipeId || 0] = updatedText;
                        // Only persist to DB once all images are resolved (no loading states remain)
                        if (!updatedText.includes('imggen-loading')) {
                            db.saveChat(char.id, bgData);
                        }
                    }, { charAvatar: char.avatar || null, userAvatar: activePersona.value?.avatar || null, messages: bgData.sessions[sessionId], currentMsgIndex: bIdx }).then(finalText => {
                        if (finalText !== msg.text) {
                            msg.text = finalText;
                            msg.swipes[msg.swipeId || 0] = finalText;
                            db.saveChat(char.id, bgData);
                        }
                    }).catch(e => console.error('[ImageGen] background processMessageImages failed:', e));
                    
                    await db.saveChat(char.id, bgData);
                    sendMessageNotification(char.name, response, char.avatar, char.id, sessionId, msgId);
                    
                    // Mark unread
                    db.get('gz_unread').then(unread => {
                        const newUnread = unread || {};
                        newUnread[char.id] = true;
                        db.set('gz_unread', newUnread);
                        window.dispatchEvent(new CustomEvent('chat-updated'));
                    });

                    window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: char.id, sessionId: sessionId } }));
                }
            }
        }
            },
            onError
        }
    });
    }
}

async function handleImageRegenerate(msgIndex, { instruction, id }) {
    const char = activeChatChar;
    if (!char || !currentMessages.value[msgIndex]) return;
    const msg = currentMessages.value[msgIndex];

    const idEsc = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const loadingHtml = makeLoadingHtml(instruction, id);
    const toLoading = (text) => text
        .replace(new RegExp(`<span[^>]+class="[^"]*imggen-error[^"]*"[^>]+data-iig-id="${idEsc}"[^>]*>[\\s\\S]*?<\\/button><\\/span>`, 'g'), loadingHtml)
        .replace(new RegExp(`<span[^>]+class="[^"]*imggen-result-wrapper[^"]*"[^>]*>[\\s\\S]*?data-iig-id="${idEsc}"[\\s\\S]*?<\\/span>`, 'g'), loadingHtml);

    msg.text = toLoading(msg.text);
    msg.swipes[msg.swipeId || 0] = msg.text;
    updateSessionMessage(char, msgIndex, msg);

    const loadingRe = new RegExp(`<span[^>]+class="[^"]*imggen-loading[^"]*"[^>]+data-iig-id="${idEsc}"[^>]*>(?:<span[^>]*>[\\s\\S]*?<\\/span>)*<\\/span>`, 'g');
    const context = { charAvatar: char.avatar || null, userAvatar: activePersona.value?.avatar || null };

    startGenerationNotification(t('imggen_notification_title') || 'Glaze', t('imggen_notification_body') || 'Generating image...');
    addNotification(t('imggen_notification_body') || 'Generating image...', 'info');

    try {
        const dataUrl = await generateImage(instruction, context);
        const latest = currentMessages.value[msgIndex]?.text || msg.text;
        msg.text = latest.replace(loadingRe, makeResultHtml(instruction, id, dataUrl));
        msg.swipes[msg.swipeId || 0] = msg.text;
        updateSessionMessage(char, msgIndex, msg);
    } catch (err) {
        const latest = currentMessages.value[msgIndex]?.text || msg.text;
        msg.text = latest.replace(loadingRe, makeErrorHtml(instruction, id, err.message));
        msg.swipes[msg.swipeId || 0] = msg.text;
        updateSessionMessage(char, msgIndex, msg);
    } finally {
        stopGenerationNotification();
    }
}

function regenerateMessage(msgIndex, mode = 'normal', guidanceText = null) {
    if (msgIndex === -1) return;
    const msg = currentMessages.value[msgIndex];
    const isUser = msg.role === 'user';
    const isLast = msgIndex === currentMessages.value.length - 1;

    if (msg.isError) {
        msg.isError = false;
        msg.text = "";
        msg.reasoning = null;
        msg.isTyping = true;
        if (msg.swipes && msg.swipes.length > 0) {
            msg.swipes[msg.swipeId || 0] = "";
        }
        updateSessionMessage(activeChatChar, msgIndex, msg);
        startGeneration(activeChatChar, null, msgIndex, null, guidanceText, 'SWIPE');
        return;
    }

    if (mode === 'magic' && isUser) {
        // Inherit guidance from the user message if it exists
        startGeneration(activeChatChar, null, -1, null, msg.guidanceText, 'GENERATION');
        return;
    }

    if (!isUser && isLast && mode === 'normal') {
        mode = 'new_variant';
    }

    if ((mode === 'new_variant' || mode === 'guided') && !isUser) {
        // Add new swipe
        const newSwipeIndex = (msg.swipes?.length || 0);
        if (!msg.swipes) msg.swipes = [msg.text];
        msg.swipes.push(""); // Placeholder
        msg.swipeId = newSwipeIndex;
        msg.text = "";
        msg.reasoning = null;
        msg.isTyping = true;
        
        let effectiveGuidance = null;
        let effectiveType = 'GENERATION';
        
        if (mode === 'guided') {
            effectiveGuidance = guidanceText;
            effectiveType = 'SWIPE';
        }
        
        startGeneration(activeChatChar, null, msgIndex, null, effectiveGuidance, effectiveType);
    } else {
        // Delete and regen (simplified for Vue: remove subsequent, then regen)
        // In Vue we just slice the array
        const deleted = currentMessages.value.splice(msgIndex);
        // Update DB
        getChatData(activeChatChar.id).then(data => {
            if (data) {
                data.sessions[data.currentId] = currentMessages.value; // Save truncated
                db.saveChat(activeChatChar.id, data);
            }
        });
        
        startGeneration(activeChatChar, null, -1, null, guidanceText, 'GENERATION');
    }
}

async function branchSession(msgIndex) {
    if (!activeChatChar) return;

    if (isGenerating.value && generatingStates[activeChatChar.id]) {
        const state = generatingStates[activeChatChar.id];
        if (state.controller) state.controller.abort();
        if (state.restoreState) state.restoreState();
        delete generatingStates[activeChatChar.id];
        isGenerating.value = false;
    }

    const data = await getChatData(activeChatChar.id);
    const currentMsgs = data.sessions[data.currentId] || [];
    // Deep copy to avoid reference issues between sessions
    const newHistory = JSON.parse(JSON.stringify(currentMsgs.slice(0, msgIndex + 1)));
    
    // Capture old session ID and notes
    const oldSessionId = data.currentId;
    const oldAuthorsNote = data.authorsNotes?.[oldSessionId] ? JSON.parse(JSON.stringify(data.authorsNotes[oldSessionId])) : null;
    
    // Create new session directly (updates DB)
    await dbCreateSession(activeChatChar.id);
    await loadChats(); // Reload to get new ID
    
    const newData = await getChatData(activeChatChar.id);
    newData.sessions[newData.currentId] = newHistory;
    
    // Copy authors note
    if (oldAuthorsNote) {
        if (!newData.authorsNotes) newData.authorsNotes = {};
        newData.authorsNotes[newData.currentId] = oldAuthorsNote;
    }
    // Copy session variables for macros
    const oldVarsKey = `gz_vars_${activeChatChar.id}_${oldSessionId}`;
    const oldVars = localStorage.getItem(oldVarsKey);
    if (oldVars) {
        const newVarsKey = `gz_vars_${activeChatChar.id}_${newData.currentId}`;
        localStorage.setItem(newVarsKey, oldVars);
    }

    await db.saveChat(activeChatChar.id, newData);
    
    // Reload UI
    const charObj = { ...activeChatChar };
    delete charObj.sessionId;
    await openChat(charObj, null, true);
}

// --- Message Actions ---

function changeSwipe(msgIndex, dir, fromSwipe = false) {
    if (isGenerating.value) return;
    const msg = currentMessages.value[msgIndex];
    
    // If the current message is an error and other swipes exist, remove the error entry on swipe
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
    
    let newIndex = (msg.swipeId || 0) + dir;

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
    msg.swipes = [msg.text]; // Reset swipes for greeting
    msg.swipeId = 0;
    msg.reasoning = null;
    msg.isError = false;
    updateSessionMessage(activeChatChar, msgIndex, msg);
}

function getReasoningTags() {
    let start = localStorage.getItem('gz_api_reasoning_start') || '<think>';
    let end = localStorage.getItem('gz_api_reasoning_end') || '</think>';

    try {
        const charId = activeChatChar?.id;
        const chatId = charId && activeChatChar?.sessionId ? `${charId}_${activeChatChar.sessionId}` : null;
        const activePreset = getEffectivePreset(charId, chatId);
        if (activePreset) {
            if (activePreset.reasoningStart) start = activePreset.reasoningStart;
            if (activePreset.reasoningEnd) end = activePreset.reasoningEnd;
        }
    } catch (e) {}
    
    return { start, end };
}

function openMessageActions(msg, index) {
    if (msg.isTyping) {
        showBottomSheet({
            title: t('sheet_title_msg_actions'),
            items: [{
                label: "Stop generation",
                icon: '<svg viewBox="0 0 24 24"><path d="M6 6h12v12H6z"/></svg>',
                iconColor: '#ff4444',
                onClick: () => {
                    if (activeChatChar && generatingStates[activeChatChar.id]) {
                        const state = generatingStates[activeChatChar.id];
                        if (state.controller) state.controller.abort();
                        if (state.restoreState) state.restoreState();
                        delete generatingStates[activeChatChar.id];
                        isGenerating.value = false;
                    } else {
                        currentMessages.value.splice(index, 1);
                        if (activeChatChar) {
                            getChatData(activeChatChar.id).then(data => {
                                if (data) {
                                    data.sessions[data.currentId] = currentMessages.value;
                                    db.saveChat(activeChatChar.id, data);
                                }
                            });
                        }
                    }
                    closeBottomSheet();
                }
            }]
        });
        return;
    }

    const items = [];

    // 1. Regenerate (for char messages or errors)
    if ((msg.role === 'char' && index > 0) || msg.isError) {
        items.push({
            label: t('action_regenerate'),
            icon: '<svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                regenerateMessage(index);
            }
        });
    }

    // 2. Edit
    if (!msg.isError) {
        items.push({
            label: t('action_edit'),
            icon: '<svg viewBox="0 0 24 24"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                enterEditMode(msg);
            }
        });
    }

    // 3. Copy
    items.push({
        label: t('action_copy'),
        icon: '<svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>',
        onClick: () => {
            let text = msg.text;
            if (msg.isError) {
                const div = document.createElement('div');
                div.innerHTML = text.replace(/<br\s*\/?>/gi, '\n');
                text = div.textContent || div.innerText || text;
                text = text.trim();
            }
            navigator.clipboard.writeText(text);
            closeBottomSheet();
        }
    });

    // 4. Branch
    if (!msg.isError) {
        items.push({
            label: t('action_branch'),
            icon: '<svg viewBox="0 0 24 24"><path d="M17.5 4C15.57 4 14 5.57 14 7.5C14 8.55 14.46 9.49 15.2 10.15L11.2 14.15C10.46 13.46 9.55 13 8.5 13C7.57 13 6.72 13.36 6.08 13.96L6 6.5C6.55 6.23 7 5.69 7 5C7 3.9 6.1 3 5 3C3.9 3 3 3.9 3 5C3 5.69 3.45 6.23 4 6.5L4.08 16.04C3.44 16.64 3 17.43 3 18.5C3 20.43 4.57 22 6.5 22C8.43 22 10 20.43 10 18.5C10 17.55 9.54 16.71 8.8 16.05L12.8 12.05C13.54 12.74 14.45 13.2 15.5 13.2C17.43 13.2 19 11.63 19 9.7C19 7.77 17.43 6.2 15.5 6.2C15.5 6.2 15.5 6.2 15.5 6.2L17.5 4Z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                branchSession(index);
            }
        });
    }

    // 5. Hide/Unhide
    items.push({
        label: msg.isHidden ? (t('action_unhide_msg') || 'Unhide') : (t('action_hide_msg') || 'Hide'),
        icon: msg.isHidden
            ? '<svg viewBox="0 0 24 24"><path d="M12 4.5C7 4.5 2.73 7.61 1 12c1.73 4.39 6 7.5 11 7.5s9.27-3.11 11-7.5c-1.73-4.39-6-7.5-11-7.5zM12 17c-2.76 0-5-2.24-5-5s2.24-5 5-5 5 2.24 5 5-2.24 5-5 5zm0-8c-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/></svg>'
            : '<svg viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>',
        onClick: () => {
            msg.isHidden = !msg.isHidden;
            updateSessionMessage(activeChatChar, index, msg);
            updateContextCutoff();
            closeBottomSheet();
        }
    });

    // 6. Delete
    items.push({
        label: t('action_delete_msg'),
        icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
        iconColor: '#ff4444',
        isDestructive: true,
        onClick: () => {
            const msg = currentMessages.value[index];
            if (msg.isError && msg.swipes && msg.swipes.length > 1) {
                const currentSwipeId = msg.swipeId || 0;
                msg.swipes.splice(currentSwipeId, 1);
                if (msg.swipesMeta) msg.swipesMeta.splice(currentSwipeId, 1);
                
                let newSwipeId = currentSwipeId - 1;
                if (newSwipeId < 0) newSwipeId = 0;
                
                msg.swipeId = newSwipeId;
                msg.text = msg.swipes[newSwipeId] || "";
                msg.isError = false;
                
                if (msg.swipesMeta && msg.swipesMeta[newSwipeId]) {
                    msg.reasoning = msg.swipesMeta[newSwipeId].reasoning;
                    msg.genTime = msg.swipesMeta[newSwipeId].genTime;
                } else {
                    msg.reasoning = null;
                    msg.genTime = null;
                }
                updateSessionMessage(activeChatChar, index, msg);
            } else {
                currentMessages.value.splice(index, 1);
                if (activeChatChar) {
                    const sid = activeChatChar.sessionId || '1';
                    let cDel = parseInt(localStorage.getItem(`gz_deleted_char_${activeChatChar.id}`) || '0', 10);
                    localStorage.setItem(`gz_deleted_char_${activeChatChar.id}`, cDel + 1);
                    let sDel = parseInt(localStorage.getItem(`gz_deleted_chat_${activeChatChar.id}_${sid}`) || '0', 10);
                    localStorage.setItem(`gz_deleted_chat_${activeChatChar.id}_${sid}`, sDel + 1);
                }
                getChatData(activeChatChar.id).then(data => {
                    if (data) {
                        data.sessions[data.currentId] = currentMessages.value;
                        db.saveChat(activeChatChar.id, data);
                    }
                });
            }
            closeBottomSheet();
        }
    });

    showBottomSheet({ title: t('sheet_title_msg_actions'), items });
}

function enterEditMode(msg) {
    msg._iigMap = msg._iigMap || {};
    const { text, map } = prepareEditText(msg?.text || '', msg._iigMap);
    msg.editText = text;
    msg._base64Map = map;
    msg.isEditing = true;
}

function normalizeImgGenHtmlForEditing(text, iigMap) {
    if (!text) return text;

    const makeTag = (instruction) => `<img data-iig-instruction='${instruction}' src="[IMG:GEN]">`;

    const extractInstruction = (chunk) => {
        if (!chunk) return null;
        const m1 = chunk.match(/\bdata-iig-instruction='([^']*)'/i);
        if (m1?.[1] != null) return m1[1];
        const m2 = chunk.match(/\bdata-iig-instruction="([^"]*)"/i);
        if (m2?.[1] != null) return m2[1];
        return null;
    };

    // Result wrapper (contains base64 src + options button) → canonical [IMG:GEN] tag.
    text = text.replace(
        /<span\b[^>]*\bclass="[^"]*\bimggen-result-wrapper\b[^"]*"[^>]*>[\s\S]*?<\/span>/gi,
        (wrapperHtml) => {
            const instruction = extractInstruction(wrapperHtml);
            if (!instruction) return wrapperHtml;
            
            if (iigMap) {
                const mSrc = wrapperHtml.match(/src="([^"]+)"/i);
                const mId = wrapperHtml.match(/data-iig-id="([^"]+)"/i);
                if (mSrc && mSrc[1]) {
                    iigMap[instruction] = { dataUrl: mSrc[1], id: mId ? mId[1] : `iig_${Date.now()}` };
                }
            }
            return makeTag(instruction);
        }
    );

    // Standalone imggen-result <img> (in case wrapper was stripped elsewhere) → canonical [IMG:GEN] tag.
    text = text.replace(
        /<img\b[^>]*\bclass="[^"]*\bimggen-result\b[^"]*"[^>]*>/gi,
        (imgHtml) => {
            const instruction = extractInstruction(imgHtml);
            if (!instruction) return imgHtml;
            
            if (iigMap) {
                const mSrc = imgHtml.match(/src="([^"]+)"/i);
                const mId = imgHtml.match(/data-iig-id="([^"]+)"/i);
                if (mSrc && mSrc[1]) {
                    iigMap[instruction] = { dataUrl: mSrc[1], id: mId ? mId[1] : `iig_${Date.now()}` };
                }
            }
            return makeTag(instruction);
        }
    );

    // Loading / Error / Disabled blocks → canonical [IMG:GEN] tag.
    text = text.replace(
        /<span\b[^>]*\bclass="[^"]*\bimggen-loading\b[^"]*"[^>]*>[\s\S]*?<\/span>/gi,
        (spanHtml) => {
            const instruction = extractInstruction(spanHtml);
            if (!instruction) return spanHtml;
            return makeTag(instruction);
        }
    );
    text = text.replace(
        /<span\b[^>]*\bclass="[^"]*\bimggen-error\b[^"]*"[^>]*>[\s\S]*?<\/span>/gi,
        (spanHtml) => {
            const instruction = extractInstruction(spanHtml);
            if (!instruction) return spanHtml;
            return makeTag(instruction);
        }
    );

    return text;
}

function prepareEditText(text, iigMap) {
    text = normalizeImgGenHtmlForEditing(text, iigMap);

    // Only shorten src for imggen canonical tags (data-iig-instruction + src="[IMG:GEN]").
    // Regular <img> tags with normal links or base64 are left completely untouched.
    const map = {};
    let idx = 0;
    const cleaned = text.replace(
        /(<img\b[^>]*\bdata-iig-instruction=[^>]*\bsrc=")([^"]{256,})("[^>]*>)/gi,
        (match, before, src, after) => {
            const key = `[IMG:SRC:${idx}]`;
            map[key] = src;
            idx++;
            return before + key + after;
        }
    );
    return { text: cleaned, map };
}

function restoreEditText(text, map) {
    if (!map) return text;
    for (const [key, src] of Object.entries(map)) {
        text = text.replace(key, src);
    }
    return text;
}

function saveEdit(msg, index) {
    let newText = restoreEditText(msg.editText || "", msg._base64Map);
    delete msg._base64Map;
    
    const iigMap = msg._iigMap || {};
    newText = newText.replace(
        /<img\b[^>]*?(?:data-iig-instruction='([^']*)'[^>]*?src="\[IMG:GEN\]"|src="\[IMG:GEN\]"[^>]*?data-iig-instruction='([^']*?)')[^>]*?>/g,
        (match, inst1, inst2) => {
            const raw = inst1 ?? inst2 ?? '{}';
            if (iigMap[raw]) {
                const { dataUrl, id } = iigMap[raw];
                let instrObj = {};
                try {
                     instrObj = JSON.parse(raw.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&'));
                } catch(e) { }
                return makeResultHtml(instrObj, id, dataUrl);
            }
            return match;
        }
    );
    delete msg._iigMap;

    let newReasoning = msg.reasoning;

    const { start: tagStart, end: tagEnd } = getReasoningTags();

    if (tagStart && tagEnd) {
        const startIndex = newText.indexOf(tagStart);
        if (startIndex !== -1) {
            const endIndex = newText.indexOf(tagEnd, startIndex);
            if (endIndex !== -1) {
                newReasoning = newText.substring(startIndex + tagStart.length, endIndex).trim();
                newText = newText.substring(0, startIndex) + newText.substring(endIndex + tagEnd.length);
            }
        }
    }

    newText = cleanText(newText);
    msg.text = newText;
    msg.reasoning = newReasoning;
    msg.tokens = estimateTokens(newText);
    if (msg.swipes) msg.swipes[msg.swipeId || 0] = newText;
    if (msg.swipesMeta && msg.swipesMeta[msg.swipeId || 0]) {
        msg.swipesMeta[msg.swipeId || 0].reasoning = newReasoning;
        msg.swipesMeta[msg.swipeId || 0].tokens = msg.tokens;
    }
    msg.isEditing = false;
    updateSessionMessage(activeChatChar, index, msg);
    delete msg.editText;

    if (newText.includes('[IMG:GEN]')) {
        processMessageImages(msg.text, (updatedText) => {
            const mIdx = currentMessages.value.findIndex(m => m.id === msg.id);
            if (mIdx !== -1) {
                const currentMsg = currentMessages.value[mIdx];
                currentMsg.text = updatedText;
                if (currentMsg.swipes) currentMsg.swipes[currentMsg.swipeId || 0] = updatedText;
                updateSessionMessage(activeChatChar, mIdx, currentMsg);
            }
        }, {
            messages: currentMessages.value,
            currentMsgIndex: index
        }).catch(e => console.error('[ImageGen] processMessageImages failed:', e));
    }
}

function cancelEdit(msg) {
    msg.isEditing = false;
    delete msg.editText;
    delete msg._base64Map;
    delete msg._iigMap;
}

function saveGuidance(msg, index, newGuidance) {
    if (msg.role === 'char') {
        if (msg.swipesMeta && msg.swipesMeta[msg.swipeId || 0] && msg.swipesMeta[msg.swipeId || 0].guidanceType === 'SWIPE') {
            msg.swipesMeta[msg.swipeId || 0].guidanceText = newGuidance;
        }
        if (msg.guidanceType === 'SWIPE') {
            msg.guidanceText = newGuidance;
        }
    } else if (msg.role === 'user') {
        msg.guidanceText = newGuidance;
    }
    updateSessionMessage(activeChatChar, index, msg);
}

function toggleImageHidden(msg, index) {
    msg.imageHidden = !msg.imageHidden;
    updateSessionMessage(activeChatChar, index, msg);
    showToast(msg.imageHidden ? 'Изображение скрыто из контекста' : 'Изображение добавлено в контекст');
}

// --- Magic Menu ---

async function startImpersonation(guidanceText = null) {
    if (guidanceText) {
        pendingGuidance.value = { text: guidanceText, type: 'IMPERSONATION' };
    } else {
        pendingGuidance.value = null;
    }
    if (!activeChatChar) return;
    const charId = activeChatChar.id;
    
    let preset = null;
    try {
        const charId = activeChatChar?.id;
        const chatId = charId && activeChatChar?.sessionId ? `${charId}_${activeChatChar.sessionId}` : null;
        preset = getEffectivePreset(charId, chatId);
    } catch(e) {}

    const promptText = preset ? (preset.impersonationPrompt || "") : "";

    if (!promptText) {
        showBottomSheet({
            bigInfo: {
                icon: '<svg viewBox="0 0 24 24" style="fill:currentColor;width:100%;height:100%;"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.04.24.24.41.48.41h3.84c.24 0 .43-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>',
                description: t('impersonation_prompt_missing') || "Impersonation prompt is empty",
                buttonText: t('btn_configure') || "Configure",
                onButtonClick: () => {
                    closeBottomSheet();
                    openApiView();
                }
            }
        });
        return;
    }

    inputValue.value = '';

    isImpersonating.value = true;
    isGenerating.value = true;
    const controller = new AbortController();
    generatingStates[charId] = { genId: ++genIdCounter, controller, type: 'impersonation' };

    // Prepare history
    const history = currentMessages.value
        .map((m, i) => ({ ...m, originalIndex: i }))
        .filter(m => !m.isTyping && !m.isHidden)
        .map(m => ({ role: m.role === 'user' ? 'user' : 'assistant', content: m.text, chatId: m.originalIndex }));

    window.dispatchEvent(new CustomEvent('chat-generation-started', { detail: { charId, sessionId: activeChatChar.sessionId } }));

    generateChatResponse({
        text: promptText,
        char: activeChatChar,
        history,
        guidanceText,
        type: 'impersonation',
        controller,
        callbacks: {
            onUpdate: (chunk) => { inputValue.value += chunk || ""; },
            onComplete: (response) => {
        inputValue.value = cleanText(response);
        isImpersonating.value = false;
        isGenerating.value = false;
        delete generatingStates[charId];
        window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: charId } }));
            },
            onError: (err) => {
        console.error(err);
        isImpersonating.value = false;
        isGenerating.value = false;
        delete generatingStates[charId];
        window.dispatchEvent(new CustomEvent('chat-generation-ended', { detail: { charId: charId } }));
            }
        }
    });
}

// --- Utils ---

function getAvatar(msg) {
    if (msg.role === 'user') {
        // Try to resolve avatar from allPersonas by ID (IndexedDB-backed)
        if (msg.persona?.id) {
            const p = allPersonas.value.find(p => p.id === msg.persona.id);
            if (p?.avatar) return p.avatar;
        }
        // Fallback to embedded avatar for old messages
        return msg.persona?.avatar || null;
    }
    return activeChatChar?.avatar || null;
}

function getAvatarLetter(msg) {
    if (msg.role === 'user') return (msg.persona?.name?.[0] || "U").toUpperCase();
    return (activeChatChar?.name?.[0] || "?").toUpperCase();
}

function getAvatarColor(msg) {
    if (msg.role === 'user') return 'var(--vk-blue)';
    return activeChatChar?.color || '#ccc';
}

function getDisplayName(msg) {
    if (msg.role === 'user') return msg.persona?.name || "User";
    return activeChatChar?.name || "Character";
}

function openAvatar(msg) {
    const src = getAvatar(msg);
    if (src) {
        const name = getDisplayName(msg);
        const description = "";
        window.dispatchEvent(new CustomEvent('trigger-open-image', { 
            detail: { src, name, description, onCloseCallback: null } 
        }));
    }
}

async function deleteSession(sessionId, targetChar) {
    const char = targetChar || activeChatChar;

    if (char && generatingStates[char.id]) {
        const state = generatingStates[char.id];
        if (state.controller) state.controller.abort();
        if (state.restoreState) state.restoreState();
        delete generatingStates[char.id];
        if (activeChatChar && activeChatChar.id === char.id) {
            isGenerating.value = false;
        }
    }

    if (char) {
        // Check if last session to prevent auto-creation
        const data = await getChatData(char.id);
        let isLast = false;
        if (data) {
             if (data.sessions) {
                 if (Object.keys(data.sessions).length <= 1 && data.sessions[sessionId]) isLast = true;
             } else if (Array.isArray(data)) {
                 isLast = true;
             }
        }

        if (isLast) {
            let deletedCount = 0;
            if (Array.isArray(data)) {
                deletedCount = data.length;
                await db.saveChat(char.id, { currentId: 1, sessions: {} });
            }
            else if (data.sessions) {
                if (data.sessions[sessionId]) deletedCount = data.sessions[sessionId].length;
                delete data.sessions[sessionId];
                await db.saveChat(char.id, data);
            }
            if (deletedCount > 0) addDeletedStats(char.id, sessionId, deletedCount);
        } else {
            let deletedCount = 0;
            if (data.sessions && data.sessions[sessionId]) deletedCount = data.sessions[sessionId].length;
            await dbDeleteSession(char.id, sessionId);
            if (deletedCount > 0) addDeletedStats(char.id, sessionId, deletedCount);
        }

        await loadChats(); // Reload local state
        
        if (activeChatChar && activeChatChar.id === char.id) {
            // Fetch raw DB state to bypass getChat's auto-creation
            const currentData = await db.get(`gz_chat_${char.id}`);
            // Check if there are any sessions left
            if (!currentData || !currentData.sessions || Object.keys(currentData.sessions).length === 0) {
                // No sessions left, close chat manually to avoid creating a new empty one
                const onBack = currentOnBack;
                
                updateAppColors(true);
                if (_cleanupScroll) {
                    _cleanupScroll();
                    _cleanupScroll = null;
                }
                window.dispatchEvent(new CustomEvent('header-reset'));
                activeChatChar = null;
                currentMessages.value = [];
                inputValue.value = '';
                
                if (onBack) onBack();
            } else {
                // Reload chat
                const charObj = { ...activeChatChar };
                delete charObj.sessionId; // Ensure we load the new currentId
                openChat(charObj, null, true);
            }
        }
        
        // Notify other components
        window.dispatchEvent(new CustomEvent('chat-updated'));
    }
}

async function openSessionsSheet(char) {
    const data = await getChatData(char.id);
    if (!data) return;
    const sessions = data.sessions || {};
    
    // Sort by timestamp desc
    const ids = Object.keys(sessions).map(Number).sort((a,b) => {
        const lastA = sessions[a][sessions[a].length-1]?.timestamp || 0;
        const lastB = sessions[b][sessions[b].length-1]?.timestamp || 0;
        return lastB - lastA;
    });

    const currentSessionId = data.currentId;

    const cardItems = ids.map(sid => {
        const msgs = sessions[sid] || [];
        const lastMsg = msgs[msgs.length - 1];
        const preview = lastMsg ? (lastMsg.text.length > 40 ? lastMsg.text.substring(0, 40) + '...' : lastMsg.text) : 'Empty session';
        const dateFormatted = lastMsg ? formatDate(lastMsg.timestamp, 'short') : '';
        const isCurrent = sid === currentSessionId;
        
        return {
            label: `Session #${sid}`,
            sublabel: preview,
            badge: `${msgs.length} msgs${dateFormatted ? ' · ' + dateFormatted : ''}`,
            isActive: isCurrent,
            onClick: async () => {
                if (sid !== currentSessionId) {
                    asyncSaveCurrentSessionState();
                    await dbSwitchSession(char.id, sid);
                    await loadChats();
                    // Pass char without sessionId so openChat uses the currentId from DB
                    openChat({ ...char, sessionId: sid }, null, true);
                }
                closeBottomSheet();
            },
            actions: [
                {
                    icon: '<svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>',
                    color: '#ff4444',
                    onClick: () => {
                        openDeleteSessionConfirm(char, sid, true);
                    }
                }
            ]
        };
    });

    showBottomSheet({
        title: t('history_title') + ' ',
        helpTip: 'sessions',
        cardItems: cardItems,
        isSolid: true,
        headerAction: {
            icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            onClick: () => {
                closeBottomSheet();
                setTimeout(() => {
                    showBottomSheet({
                        title: t('history_title') + ' ',
                        helpTip: 'sessions',
                        items: [
                            {
                                label: t('action_create_new') || 'Create New',
                                icon: '<svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
                                onClick: () => {
                                    closeBottomSheet();
                                    createNewSession(char);
                                }
                            },
                            {
                                label: t('action_import') || 'Import from file',
                                icon: '<svg viewBox="0 0 24 24"><path d="M4 15h2v3h12v-3h2v3c0 1.1-.9 2-2 2H6c-1.1 0-2-.9-2-2v-3zm4.41-6.59L11 5.83V17h2V5.83l2.59 2.58L17 7l-5-5-5 5 1.41 1.41z"/></svg>',
                                onClick: () => {
                                    closeBottomSheet();
                                    triggerChatImport(char.id, null, async () => {
                                        await loadChats();
                                        const charObj = { ...char };
                                        delete charObj.sessionId;
                                        openChat(charObj, null, true);
                                    });
                                }
                            }
                        ]
                    });
                }, 300);
            }
        }
    });
}

function openDeleteSessionConfirm(char, sessionId, returnToSessions = false) {
    showBottomSheet({
        title: t('confirm_delete_session'),
        items: [
            {
                label: t('btn_yes'),
                icon: '<svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>',
                iconColor: '#ff4444',
                isDestructive: true,
                onClick: async () => {
                    await deleteSession(sessionId, char);
                    closeBottomSheet();
                    if (returnToSessions) {
                        const currentData = await db.get(`gz_chat_${char.id}`);
                        if (currentData && currentData.sessions && Object.keys(currentData.sessions).length > 0) {
                            setTimeout(() => openSessionsSheet(char), 300);
                        }
                    }
                }
            },
            {
                label: t('btn_no'),
                icon: '<svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>',
                onClick: () => {
                    closeBottomSheet();
                    if (returnToSessions) setTimeout(() => openSessionsSheet(char), 300);
                }
            }
        ]
    });
}

async function createNewSession(char) {
    asyncSaveCurrentSessionState();
    await dbCreateSession(char.id);
    await loadChats(); // Reload local state to get new session
    
    // Open chat with the new currentId (by removing sessionId from char object)
    const charObj = { ...char };
    delete charObj.sessionId;
    openChat(charObj, null, true);
}

async function openCharCard() {
    if (!activeChatChar) return;
    charCardSheet.value?.open(activeChatChar);
}

async function openChatStatsSheet(char = activeChatChar) {
    if (!char) return;
    statsSheet.value?.open(char, currentMessages.value);
}

function openApiView() {
    window.dispatchEvent(new CustomEvent('open-api-sheet'));
}

function openPresetView() {
    if (presetView.value) {
        presetView.value.open();
    }
}

async function openLorebookSheet() {
    const chatData = await getChatData(activeChar.value?.id);
    const charId = activeChar.value?.id;
    const sessionId = chatData?.currentId;
    lorebookSheet.value?.open({
        charId: charId,
        chatId: charId && sessionId ? `${charId}_${sessionId}` : null
    });
}

function openLorebookEntry(lbId, entryId) {
    lorebookSheet.value?.openEntry(lbId, entryId);
}

function openRegexSheet() {
    regexSheet.value?.open();
}

const applyImageAutoHide = () => {
    const autoHide = localStorage.getItem('gz_api_auto_hide_images') === 'true';
    const threshold = parseInt(localStorage.getItem('gz_api_auto_hide_images_n') || '1', 10);
    
    if (!autoHide || threshold <= 0 || !activeChatChar) return;

    let changed = false;
    let assistantCount = 0;
    
    // Iterate backwards to count assistant responses after user images
    for (let i = currentMessages.value.length - 1; i >= 0; i--) {
        const msg = currentMessages.value[i];
        if (msg.role === 'char' || msg.role === 'assistant') {
            assistantCount++;
        } else if (msg.role === 'user' && msg.image) {
            if (assistantCount >= threshold && !msg.imageHidden) {
                msg.imageHidden = true;
                changed = true;
            }
        }
    }

    if (changed) {
        getChatData(activeChatChar.id).then(data => {
            if (data) {
                data.sessions[data.currentId] = currentMessages.value;
                db.saveChat(activeChatChar.id, data);
            }
        });
    }
};

const restoreHeader = () => {
    if (activeChatChar) setupHeader(activeChatChar);
};

// Expose methods for App.vue
defineExpose({
    loadChats,
    openChat,
    restoreHeader,
    openLorebookEntry,
    openPersonas: () => { chatInputRef.value?.openPersonas(); },
    initChat: () => {} // No-op, initialization is in onMounted
});

const onGenerationEnded = (e) => {
    if (activeChatChar && activeChatChar.id === e.detail.charId) {
        isGenerating.value = false;
        isImpersonating.value = false;
        applyImageAutoHide();
        updateContextCutoff();
    }
};

const onCharacterUpdated = (e) => {
    if (activeChatChar && activeChatChar.id === e.detail.character.id) {
        activeChatChar = e.detail.character;
        activeChar.value = e.detail.character;
        window.dispatchEvent(new CustomEvent('header-update-avatar', { detail: activeChatChar }));
    }
};

const onVisibilityChange = () => {
    if (document.visibilityState === 'visible' && activeChatChar) {
        clearMessageNotifications(activeChatChar.id);
    }
};

let _paddingRafContext = null;
const updateContentPadding = () => {
    if (_paddingRafContext) cancelAnimationFrame(_paddingRafContext);
    _paddingRafContext = requestAnimationFrame(() => {
        _paddingRafContext = null;
        if (messagesContainer.value && chatInputContainer.value) {
        const el = messagesContainer.value;
        const currentFullHeight = chatInputContainer.value.getBoundingClientRect().height;
        const currentContainerHeight = el.getBoundingClientRect().height;
        
        const prevContainerHeight = el._lastContainerHeight !== undefined ? el._lastContainerHeight : currentContainerHeight;
        el._lastContainerHeight = currentContainerHeight;
        const containerHeightDiff = currentContainerHeight - prevContainerHeight;
        
        const prevFullHeight = el._lastFullHeight !== undefined ? el._lastFullHeight : currentFullHeight;
        el._lastFullHeight = currentFullHeight;
        const diffScroll = currentFullHeight - prevFullHeight;

        let targetPadding = currentFullHeight;

        const currentPadding = parseFloat(el.style.paddingBottom) || 0;
        const paddingDiff = targetPadding - currentPadding;

        if (Math.abs(diffScroll) < 0.1 && Math.abs(paddingDiff) < 0.1 && Math.abs(containerHeightDiff) < 0.1) return;

        const isAtBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 5;

        el.style.paddingBottom = `${targetPadding}px`;

        if (!isProgrammaticScrolling.value) {
            isProgrammaticScrolling.value = true;
        }
        if (el._scrollUnlockTimer) clearTimeout(el._scrollUnlockTimer);
        el._scrollUnlockTimer = setTimeout(() => {
            isProgrammaticScrolling.value = false;
        }, 100);
        
        const totalScrollAdjustment = diffScroll - containerHeightDiff;

        if (isAtBottom) {
            // If already at the bottom, stay at the bottom
            el.scrollTop = el.scrollHeight - el.clientHeight;
        } else if (!ignoreScrollAdjustment && Math.abs(totalScrollAdjustment) > 0.1) {
            el.scrollTop += totalScrollAdjustment;
        }
        }
    });
};

function setScrollLock(enabled) {
    if (enabled) {
        document.body.classList.add('no-scroll');
    } else {
        document.body.classList.remove('no-scroll');
    }
}

// Throttle visualViewport handler via RAF to prevent layout thrashing on iOS
// during rapid keyboard show/hide cycles (which can crash WKWebView).
let _vpRafId = null;
function handleVisualViewport() {
    if (Capacitor.getPlatform() !== 'ios') return;
    if (_vpRafId) return;
    _vpRafId = requestAnimationFrame(() => {
        _vpRafId = null;
        if (!window.visualViewport || !chatViewRoot.value) return;
        chatViewRoot.value.style.height = `${window.visualViewport.height}px`;
        window.scrollTo(0, 0);
    });
}

onMounted(() => {
    setScrollLock(true);
    loadChats();
    initRipple();
    if (activeChatChar) {
        setupHeader(activeChatChar);
    }
    window.addEventListener('character-updated', onCharacterUpdated);
    window.addEventListener('chat-generation-ended', onGenerationEnded);
    window.addEventListener('fs-editor-closed', onFsEditorClosed);
    if (window.visualViewport) {
        window.visualViewport.addEventListener('resize', handleVisualViewport);
        window.visualViewport.addEventListener('scroll', handleVisualViewport);
        handleVisualViewport();
    }

    // Clear notifications when app comes to foreground and chat is active
    document.addEventListener('visibilitychange', onVisibilityChange);

    if (chatInputContainer.value) {
        inputResizeObserver = new ResizeObserver(updateContentPadding);
        inputResizeObserver.observe(chatInputContainer.value);
        if (messagesContainer.value) inputResizeObserver.observe(messagesContainer.value);
        updateContentPadding();
    }
    updateContextCutoff();
    window.addEventListener('header-chat-search-toggle', onChatSearchToggle);
    window.addEventListener('regex-scripts-changed', onRegexChanged);
    window.addEventListener('header-chat-search', onChatSearch);
});

watch(() => currentMessages.value.length, () => {
    updateContextCutoff();
});

watch(activeChar, async (newVal) => {
    if (!newVal) return;
    
    const chatData = await getChatData(newVal.id);
    if (!chatData) return;
    const sessionId = chatData.currentId;
    let changed = false;

    // Sync Summary Content
    if (newVal.summary !== undefined) {
        if (!chatData.summaries) chatData.summaries = {};
        let currentSum = chatData.summaries[sessionId];
        if (typeof currentSum === 'string') {
            currentSum = { content: currentSum, depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
        } else if (!currentSum) {
            currentSum = { content: '', depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
        }
        if (currentSum.content !== newVal.summary) {
            chatData.summaries[sessionId] = { ...currentSum, content: newVal.summary };
            changed = true;
        }
    }

    // Sync Author's Note Content
    if (newVal.authors_note !== undefined) {
        if (!chatData.authorsNotes) chatData.authorsNotes = {};
        const storedAn = chatData.authorsNotes[sessionId];
        let currentAN = typeof storedAn === 'string' ? storedAn : storedAn?.content || '';
        if (currentAN !== newVal.authors_note) {
            chatData.authorsNotes[sessionId] = newVal.authors_note;
            changed = true;
        }
    }

    if (changed) await db.saveChat(newVal.id, chatData);
}, { deep: true });

onBeforeUnmount(() => {
    if (activeChatChar && messagesContainer.value) {
        const charId = activeChatChar.id;
        const currentAnchor = getScrollAnchor();
        const draft = inputValue.value;
        getChatData(charId).then(data => {
            if (!data) return;
            data.lastScrollAnchor = currentAnchor;
            data.draft = draft;
            db.saveChat(charId, data);
        });
    }
});

onUnmounted(() => {
    setScrollLock(false);
    // Cleanup UI timers for ALL generating states, not just activeChatChar
    // This prevents leaked intervals and closures referencing unmounted reactive state
    for (const charId of Object.keys(generatingStates)) {
        const state = generatingStates[charId];
        if (state.timerId) {
            clearInterval(state.timerId);
            state.timerId = null;
        }
        // Disconnect UI updater to prevent updates to unmounted component
        state.onUIUpdate = null;
    }
    window.removeEventListener('character-updated', onCharacterUpdated);
    document.removeEventListener('visibilitychange', onVisibilityChange);
    window.removeEventListener('chat-generation-ended', onGenerationEnded);
    window.removeEventListener('fs-editor-closed', onFsEditorClosed);
    
    if (window.visualViewport) {
        window.visualViewport.removeEventListener('resize', handleVisualViewport);
        window.visualViewport.removeEventListener('scroll', handleVisualViewport);
    }
    if (_vpRafId) {
        cancelAnimationFrame(_vpRafId);
        _vpRafId = null;
    }

    // Cleanup scroll listener (may not have been cleaned up by closeChat)
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }

    // Remove scroll listener that was added in openChat()
    if (messagesContainer.value) {
        messagesContainer.value.removeEventListener('scroll', onScroll);
    }

    if (inputResizeObserver) {
        inputResizeObserver.disconnect();
        inputResizeObserver = null;
    }
    window.removeEventListener('header-chat-search-toggle', onChatSearchToggle);
    window.removeEventListener('regex-scripts-changed', onRegexChanged);
    window.removeEventListener('header-chat-search', onChatSearch);
    if (cutoffRerunTimer) {
        clearTimeout(cutoffRerunTimer);
        cutoffRerunTimer = null;
    }

    // Reset chatViewRoot height to prevent stale inline style leaking to next mount
    if (chatViewRoot.value) {
        chatViewRoot.value.style.height = '';
    }
});

</script>

<template>
    <div id="view-chat" ref="chatViewRoot" :class="{ 'android-resize-fix': isAndroid }">
        <div v-if="isLoading" class="chat-loading-overlay">
            <div class="app-loader-spinner"></div>
        </div>

        <div class="chat-container" id="chat-messages" ref="messagesContainer" :class="{ 'is-scrolling': isScrolling, 'visually-hidden': isLoading }" :style="isAndroid ? { marginBottom: keyboardOverlap + 'px' } : {}">
            <!-- paddingTop - spacer for virtual list scroll offset -->
            <div :style="{ height: paddingTop + 'px' }"></div>
            
            <template v-for="vItem in visibleItems" :key="vItem.key">
                <div v-if="vItem.item.type === 'separator'" class="chat-date-separator" :data-index="vItem.index">
                    {{ formatDateSeparator(vItem.item.timestamp) }}
                </div>
                <div v-else-if="vItem.item.type === 'cutoff'" class="chat-context-limit">
                    <span>Context Limit</span>
                </div>
                <ChatMessage 
                    v-else
                    :id="`msg-${vItem.item.originalIndex}`"
                    :data-index="vItem.index"
                    :message="vItem.item.data"
                    :index="vItem.item.originalIndex"
                    :active-chat-char="activeChatChar"
                    :is-generating="isGenerating"
                    :is-last="vItem.item.originalIndex === currentMessages.length - 1"
                    :search-query="isSearchMode ? searchQuery : ''"
                    :regex-revision="regexRevision"
                    :active-search-match-index="searchMatchState.msgIdx === vItem.item.originalIndex ? searchMatchState.occurrenceIdx : -1"
                    :is-selection-mode="isSelectionMode"
                    :is-selected="selectedMessages.has(vItem.item.data.timestamp)"
                    @swipe="(dir) => changeSwipe(vItem.item.originalIndex, dir, true)"
                    @change-greeting="(dir) => changeGreeting(vItem.item.originalIndex, dir, true)"
                    @regenerate="(mode, guidanceText) => regenerateMessage(vItem.item.originalIndex, mode, guidanceText)"
                    @edit="() => enterEditMode(vItem.item.data)"
                    @save-edit="saveEdit(vItem.item.data, vItem.item.originalIndex)"
                    @cancel-edit="cancelEdit(vItem.item.data)"
                    @save-guidance="(text) => saveGuidance(vItem.item.data, vItem.item.originalIndex, text)"
                    @open-actions="openMessageActions(vItem.item.data, vItem.item.originalIndex)"
                    @open-avatar="openAvatar(vItem.item.data)"
                    @toggle-selection="toggleSelection(vItem.item.data.timestamp)"
                    @toggle-image-hidden="toggleImageHidden(vItem.item.data, vItem.item.originalIndex)"
                    @regenerate-image="(payload) => handleImageRegenerate(vItem.item.originalIndex, payload)"
                />
            </template>
            <!-- paddingBottom - spacer for virtual list scroll offset -->
            <div :style="{ height: paddingBottom + 'px' }"></div>
        </div>

        <div class="chat-status-gradient"></div>

        <div class="chat-input-wrapper" ref="chatInputContainer" :style="isAndroid ? { bottom: keyboardOverlap + 'px' } : {}">
            <ChatInput 
                ref="chatInputRef"
                v-model="inputValue"
                :is-generating="isGenerating"
                :is-impersonating="isImpersonating"
                :show-scroll-button="showScrollButton"
                :is-search-mode="isSearchMode"
                :is-selection-mode="isSelectionMode"
                :selected-count="selectedMessages.size"
                :search-match-current="currentSearchIndex + 1"
                :search-match-total="searchResults.length"
                :active-char="activeChar"
                @send="sendMessage"
                @scroll-to-bottom="scrollToBottom"
                @search-next="nextSearchResult"
                @search-prev="prevSearchResult"
                @magic-impersonate="startImpersonation"
                @magic-notes="presetView.openAuthorsNoteSheet()"
                @magic-context="openContextSheet()"
                @magic-stats="openChatStatsSheet()"
                @magic-summary="presetView.openSummarySheet()"
                @magic-sessions="openSessionsSheet(activeChatChar)"
                @magic-char-card="openCharCard"
                @magic-api="openApiView"
                @magic-presets="openPresetView"
                @magic-lorebooks="openLorebookSheet"
                @magic-regex="openRegexSheet"
                @magic-image-gen="openImageGenSheet"
                @magic-glossary="openGlossarySheet"
                @delete-selected="deleteSelectedMessages"
                @hide-selected="toggleHideSelectedMessages"
                @cancel-selection="clearSelection"
            />
            

        </div>

        <div style="display: none;"></div>
        <PresetView ref="presetView" :active-chat-char="activeChar" :chat-history="currentMessages" :is-generating="isGenerating" />
        <CharacterCardSheet ref="charCardSheet" />
        <LorebookSheet ref="lorebookSheet" />
        <RegexSheet ref="regexSheet" :active-chat-char="activeChar" />
        <StatsSheet ref="statsSheet" />
        <ImageGenSheet ref="imageGenSheet" />
        <GlossarySheet ref="glossarySheet" />
    </div>
</template>

<style>
@import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700&family=Rajdhani:wght@300;500;700&display=swap');
/* Chat View */
#view-chat {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    display: flex;
    flex-direction: column;
    flex: none;
    height: 100%;
    min-height: 0;
    width: 100%;
    overflow: hidden; /* Disable view scroll, delegate to chat-container */
    padding: 0 !important;
    background-color: var(--ui-bg);
    z-index: 1000;
}

@keyframes msgFadeIn {
    from { opacity: 0; transform: translateY(10px); }
    to { opacity: 1; transform: translateY(0); }
}

.message-section {
    animation: msgFadeIn 0.3s ease-out;
}

.chat-container {
    padding: calc(60px + var(--sat)) 0 0 0; /* Space for fixed header */
    margin-top: 0;
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    min-height: 0;
    /* Enable scroll anchoring to prevent jumps when top padding changes */
    overflow-anchor: auto; 
    
    /* Hide scrollbar */
    scrollbar-width: none; /* Firefox */
    -ms-overflow-style: none;  /* IE 10+ */
}

.chat-container::-webkit-scrollbar {
    display: none; /* Chrome, Safari and Opera */
}

/* Performance optimization: disable pointer events on items while scrolling */
.chat-container.is-scrolling .message-section {
    pointer-events: none;
}

.message-section {
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    transition: background-color 0.5s ease, color 0.5s ease;
    touch-action: pan-y;
    overflow: hidden;
}


.msg-name {
    font-weight: 500;
    font-size: 14px;
    color: var(--text-dark-gray);
}

.msg-time {
    margin-left: auto;
    font-size: 12px;
    color: var(--text-gray);
}

/* Typing Indicator (VK Style Pencil) */
@keyframes pencil-write {
    0% { transform: translateX(0); }
    15% { transform: translateX(1px); }
    30% { transform: translateX(2px); }
    45% { transform: translateX(3px); }
    60% { transform: translateX(4px); }
    75% { transform: translateX(5px); }
    100% { transform: translateX(0); }
}

.typing-container {
    display: flex;
    align-items: center;
    padding: 2px 0;
    color: var(--text-gray, #818c99);
    font-size: 0.9em;
}

.typing-icon {
    width: 16px;
    height: 16px;
    fill: var(--text-gray);
    margin-right: 10px;
    animation: pencil-write 1.5s infinite ease-in-out;
}


/* Chat Input Bar */
.chat-input-wrapper {
    position: absolute !important;
    bottom: 0;
    left: 0;
    width: 100%;
    z-index: 1000;
    display: flex;
    flex-direction: column;
    overflow: visible !important;
    flex-shrink: 0;
}

.chat-context-bar {
    position: relative;
    display: flex;
    width: 100%;
    height: 10px;
    overflow: hidden;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.06);
}

.chat-context-used {
    display: flex;
    height: 100%;
    min-width: 0;
    flex: 0 0 auto;
}

.chat-context-reserve {
    position: absolute;
    top: 0;
    right: 0;
    height: 100%;
    box-shadow: inset 2px 0 0 rgba(0, 0, 0, 0.35);
}

.chat-context-segment {
    height: 100%;
}

.segment-fixed {
    background: #8f8f95;
}

.segment-character {
    background: #4f8cff;
}

.segment-history {
    background: #d8b84a;
}

.segment-summary {
    background: #1ec8ff;
}

.segment-authors-note {
    background: #7a6cff;
}

.segment-lorebook {
    background: #ff8c42;
}

.segment-lorebook-reserve {
    background: #43b56f;
}

.context-sheet {
    padding: 0 16px 16px;
}

.context-sheet-summary {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 10px;
    margin-bottom: 14px;
}

.context-sheet-kpi {
    padding: 12px;
    border-radius: 14px;
    background: rgba(255, 255, 255, 0.08);
    backdrop-filter: blur(var(--element-blur, 20px));
    text-align: center;
    color: var(--text-black);
    border: 1px solid rgba(255, 255, 255, 0.08);
}

.context-sheet-kpi strong {
    display: block;
    font-size: 18px;
    line-height: 1.2;
    color: var(--text-black);
}

.context-sheet-kpi span {
    display: block;
    margin-top: 4px;
    font-size: 12px;
    color: var(--text-gray);
}

.context-sheet-bar {
    margin-bottom: 14px;
}

.context-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 8px 12px;
    margin-bottom: 14px;
}

.context-legend-item {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    color: var(--text-gray);
}

.context-legend-swatch {
    width: 10px;
    height: 10px;
    border-radius: 999px;
    flex-shrink: 0;
}

.context-breakdown {
    display: grid;
    gap: 8px;
}

.context-breakdown-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border-radius: 12px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.06);
}

.context-breakdown-row span {
    color: var(--text-gray);
}

.context-breakdown-row strong {
    font-weight: 600;
    color: var(--text-black);
}

.context-recommendation {
    margin-top: 14px;
    padding: 12px;
    border-radius: 14px;
    background: rgba(216, 184, 74, 0.14);
    border: 1px solid rgba(216, 184, 74, 0.35);
}

.context-recommendation-title {
    font-weight: 600;
    margin-bottom: 4px;
}

.context-recommendation-text,
.context-sheet-note {
    font-size: 13px;
    color: var(--text-gray);
    line-height: 1.45;
}

.context-sheet-actions {
    display: flex;
    gap: 10px;
    margin-top: 16px;
}

.context-sheet-btn {
    flex: 1;
    min-height: 42px;
    border: none;
    border-radius: 12px;
    padding: 0 14px;
    font-size: 14px;
    font-weight: 600;
}

.context-sheet-btn-primary {
    color: #fff;
    background: var(--vk-blue);
}

.context-sheet-btn-secondary {
    color: var(--text-black);
    background: rgba(255, 255, 255, 0.08);
}

@media (max-width: 480px) {
    .context-sheet-summary {
        grid-template-columns: 1fr;
    }

    .context-sheet-actions {
        flex-direction: column;
    }
}


/* History List */
.history-item {
    padding: 12px;
    border-bottom: 1px solid var(--border-color);
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.chat-date-separator {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px 0;
    color: var(--text-gray);
    font-size: 11px;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 1px;
    width: 100%;
}

.chat-date-separator::before, .chat-date-separator::after {
    content: '';
    flex: 1;
    height: 1px;
    background: var(--border-color);
    margin: 0 12px;
    opacity: 0.5;
}

.chat-context-limit {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 16px 0;
    color: var(--text-gray);
    font-size: 11px;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 1px;
    opacity: 1;
}
.chat-context-limit::before, .chat-context-limit::after {
    content: '';
    flex: 1;
    height: 1px;
    background: var(--border-color);
    margin: 0 12px;
    opacity: 1;
}

.impersonate-status {
    display: flex;
    align-items: center;
    margin-left: auto;
    margin-right: 8px;
    pointer-events: none;
    background-color: transparent;
}

/* Typing Dots for Dialog List */
.typing-dots {
    display: inline-flex;
    align-items: center;
    height: 12px;
}
.typing-dot {
    width: 4px;
    height: 4px;
    background-color: var(--vk-blue);
    border-radius: 50%;
    margin: 0 1px;
    animation: typingDot 1.4s infinite ease-in-out both;
}
.typing-dot:nth-child(1) { animation-delay: -0.32s; }
.typing-dot:nth-child(2) { animation-delay: -0.16s; }
@keyframes typingDot {
    0%, 80%, 100% { transform: scale(0); }
    40% { transform: scale(1); }
}

/* Typing Dots for Chat Message & Impersonation */
.typing-dots-bounce {
    display: inline-block;
    margin-left: 4px;
}

.typing-dots-bounce span {
    display: inline-block;
    animation: dotBounce 1.4s infinite ease-in-out both;
    color: var(--text-gray);
    font-size: 1.4em;
    line-height: 10px;
    vertical-align: middle;
}

.typing-dots-bounce span:nth-child(1) { animation-delay: -0.32s; }
.typing-dots-bounce span:nth-child(2) { animation-delay: -0.16s; }

@keyframes dotBounce {
    0%, 80%, 100% { transform: translateY(0); opacity: 0.5; }
    40% { transform: translateY(-5px); opacity: 1; }
}

/* Unread Message State */
.list-item.unread .item-subtitle,
.list-item.unread .item-meta {
    color: var(--vk-blue);
    font-weight: 500;
}


/* Deletion Animation */
@keyframes msgDelete {
    0% {
        opacity: 1;
        transform: translateY(0);
        max-height: 500px; /* Large enough to cover most messages */
        margin-bottom: 0;
        padding-top: 12px;
        padding-bottom: 12px;
    }
    100% {
        opacity: 0;
        transform: translateY(20px);
        max-height: 0;
        margin-bottom: 0;
        padding-top: 0;
        padding-bottom: 0;
        border-bottom-width: 0;
    }
}

.message-section.deleting {
    animation: msgDelete 0.3s ease-out forwards;
    overflow: hidden;
    border-bottom: none;
    pointer-events: none;
}


.msg-switcher {
    background-color: rgba(30, 30, 30, var(--element-opacity, 0.6));
    color: var(--text-gray);
}

/* Code Blocks */
.code-block {
    background-color: rgba(255, 255, 255, 0.1);
    border-radius: 6px;
    padding: 10px;
    margin: 8px 0;
    overflow-x: auto;
    font-family: Consolas, Monaco, 'Courier New', monospace;
    font-size: 13px;
    white-space: pre;
    color: var(--text-black);
}

.edit-btn.save svg {
    fill: #4CAF50;
}

.edit-btn.cancel svg {
    fill: #ff4444;
}

.edit-btn:hover {
    background-color: rgba(255,255,255,0.1);
}

/* --- Custom Interface Styles (FC) --- */
.fc-interface {
  width: 100%;
  max-width: 340px;
  margin: 20px auto;
  background: #050a05;
  border: 1px solid #33ff33;
  font-family: 'Rajdhani', sans-serif;
  color: #ccffcc;
  overflow: hidden;
  position: relative;
  box-shadow: 0 0 15px rgba(51, 255, 51, 0.2);
  border-radius: 8px;
}

.fc-header {
  background: linear-gradient(90deg, #0a1f0a, #003300);
  padding: 10px;
  border-bottom: 1px solid #33ff33;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.fc-logo {
  font-family: 'Orbitron', sans-serif;
  font-weight: 700;
  color: #33ff33;
  text-shadow: 0 0 5px #33ff33;
  font-size: 14px;
}

.fc-status {
  font-size: 10px;
  color: #33ff33;
  animation: blink 2s infinite;
}

.fc-content {
  padding: 15px;
  position: relative;
  min-height: 280px;
}

/* Character Scan Layer */
.scan-container {
  position: relative;
  height: 180px;
  background: url('https://image.pollinations.ai/prompt/silhouette%20of%20a%20man%20standing%20in%20a%20casino%20green%20hologram%20style%20wireframe?nologo=true') center/cover no-repeat;
  border: 1px solid #1a4d1a;
  margin-bottom: 15px;
  overflow: hidden;
}

.scan-line {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 2px;
  background: #33ff33;
  box-shadow: 0 0 10px #33ff33;
  animation: scan 3s linear infinite;
}

.scan-overlay {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  background: rgba(0, 20, 0, 0.8);
  padding: 5px;
  font-size: 12px;
  transform: translateY(100%);
  transition: transform 0.3s ease;
}

.scan-container:hover .scan-overlay {
  transform: translateY(0);
}

/* Interactive Tabs */
.fc-tabs {
  display: flex;
  gap: 5px;
  margin-bottom: 10px;
}

.fc-tab {
  flex: 1;
  background: #0f2b0f;
  border: 1px solid #1a4d1a;
  color: #88cc88;
  padding: 8px;
  text-align: center;
  cursor: pointer;
  font-size: 12px;
  transition: all 0.3s ease;
  text-transform: uppercase;
}

.fc-tab:hover, .fc-tab.active {
  background: #33ff33;
  color: #000;
  box-shadow: 0 0 10px rgba(51, 255, 51, 0.4);
}

/* Data Display Area */
.data-panel {
  display: none;
  animation: fadeInUp 0.4s ease;
}

.data-panel.active {
  display: block;
}

.stat-row {
  display: flex;
  justify-content: space-between;
  margin-bottom: 8px;
  font-size: 13px;
  border-bottom: 1px dashed #1a4d1a;
  padding-bottom: 4px;
}

.stat-val {
  color: #33ff33;
  font-weight: 700;
}

/* Animations */
@keyframes scan {
  0% { top: 0; opacity: 0; }
  10% { opacity: 1; }
  90% { opacity: 1; }
  100% { top: 100%; opacity: 0; }
}

@keyframes blink {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}

@keyframes fadeInUp {
  from { opacity: 0; transform: translateY(5px); }
  to { opacity: 1; transform: translateY(0); }
}

/* Header Hiding Fix */
.app-header, header.app-header {
    transform: translateY(0) translateZ(0);
}
.app-header.fixed-header {
    position: fixed;
    left: 0;
    right: 0;
    margin-top: calc(var(--sat) + 10px) !important;
    width: auto;
    z-index: 1000;
}
.app-header.scroll-hidden {
    transform: none;
    transform: translateY(-250%);
}

/* Text Change Animations */
@keyframes slideOutLeft {
    to { opacity: 0; transform: translateX(-20px); }
}
@keyframes slideOutRight {
    to { opacity: 0; transform: translateX(20px); }
}
@keyframes slideInLeft {
    from { opacity: 0; transform: translateX(-20px); }
    to { opacity: 1; transform: translateX(0); }
}
@keyframes slideInRight {
    from { opacity: 0; transform: translateX(20px); }
    to { opacity: 1; transform: translateX(0); }
}

.msg-body.slide-out-left { animation: slideOutLeft 0.15s ease forwards; }
.msg-body.slide-out-right { animation: slideOutRight 0.15s ease forwards; }
.msg-body.slide-in-left { animation: slideInLeft 0.15s ease forwards; }
.msg-body.slide-in-right { animation: slideInRight 0.15s ease forwards; }

/* Streaming Text Animation */
@keyframes streamAnim {
    from { opacity: 0; transform: translateY(5px); }
    to { opacity: 1; transform: translateY(0); }
}

.stream-char {
    animation: streamAnim 0.2s ease-out forwards;
    display: inline-block;
}



.chat-loading-placeholder {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding-top: 60px;
}

.chat-loading-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-color: var(--white);
    z-index: 100;
    display: flex;
    align-items: center;
    justify-content: center;
    padding-top: 60px;
}

.visually-hidden {
    opacity: 0;
}

.chat-status-gradient {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: calc(var(--sat) + 20px);
    background: linear-gradient(to bottom, rgba(0,0,0,0.4), transparent);
    z-index: 900;
    pointer-events: none;
}



.clock-flip-enter-active,
.clock-flip-leave-active {
    transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1), opacity 0.25s ease;
}
.clock-flip-enter-from {
    transform: translateY(-15px);
    opacity: 0;
}
.clock-flip-leave-to {
    transform: translateY(15px);
    opacity: 0;
}

/* Android text selection fix */
#view-chat.android-resize-fix .chat-container {
    transition: margin-bottom 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
}
#view-chat.android-resize-fix .chat-input-wrapper {
    transition: bottom 0.25s cubic-bezier(0.2, 0.8, 0.2, 1);
}
#view-chat.android-resize-fix .chat-input-container.keyboard-open .chat-input-content {
    padding-bottom: 0 !important;
}
</style>

<style scoped>
/* Scoped overrides if necessary, but mostly relying on chat.css */
.msg-avatar {
    display: flex;
    align-items: center;
    justify-content: center;
    color: white;
    font-weight: bold;
    font-size: 1.2em;
}

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
  transition: opacity 0.2s ease;
}
.fade-enter-from, .fade-leave-to {
  opacity: 0;
}


</style>
