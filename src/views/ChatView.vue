<script>
// --- Module Level State (Persists across component mounts) ---
let activeChatChar = null;
let _cleanupScroll = null;
let _msgIdCounter = 0;
let unsubCharacterUpdated = null;
let unsubGenerationEnded = null;
let unsubFsEditorClosed = null;
let unsubChatSearchToggle = null;
let unsubRegexChanged = null;
let unsubChatSearch = null;
let unsubApiContextChanged = null;
let unsubSettingsChanged = null;
let unsubSyncDataRefreshed = null;
let _appStateListener = null;

import * as memoryBooksService from '@/core/services/memoryBooksService.js';

// Import Memory Books functions from service
const {
    createEmptyMemoryCoverage,
    createBaseMessageMeta,
    reconcileSessionMemoryState,
    runMemoryMaintenancePass,
    formatElapsedSeconds,
    genMemoryEntryId,
    genMemoryPromptId,
    normalizeMemoryEntryShape,
    parseMemoryKeyInput,
    buildMemoryKeysFromText,
    indexMemoryEntryIfNeeded,
    deleteMemoryEntryIndexIfPresent,
    reindexMemoryEntry,
    shouldEnableMemoryVectorSearch,
    getMemoryVectorSearchEnabled
} = memoryBooksService;
</script>

<script setup>
import { ref, nextTick, onMounted, onUnmounted, watch, computed } from 'vue';
import { Capacitor } from '@capacitor/core';
import { App } from '@capacitor/app';
import { keyboardOverlap } from '@/core/services/keyboardHandler.js';
import { estimateTokens } from '@/utils/tokenizer.js';
import { cleanText, invalidateFormatCache } from '@/utils/textFormatter.js';
import { invalidateRegexCache } from '@/core/services/regexService.js';
import { getEffectivePersona, activePersona, allPersonas } from '@/core/states/personaState.js';
import { formatDate, formatDateSeparator } from '@/utils/dateFormatter.js';
import { currentLang, chatMaxWidth, setChatMaxWidth, shouldUseBatterySaverUI } from '@/core/config/APPSettings.js';
import { translations } from '@/utils/i18n.js';
import { createChatGenerationServices } from '@/core/llm/usecases/generateChat.js';
import { useGenerationAbort } from '@/composables/chat/useGenerationAbort.js';
import { getActiveLLMProfile } from '@/core/config/ProviderProfiles.js';
import { getEmbeddingConfig, isEmbeddingConfigured } from '@/core/config/embeddingSettings.js';
import { animateTextChange, updateAppColors, initHeaderScroll } from '@/core/services/ui.js';
import { initRipple } from '@/core/services/interactionEffects.js';
import { showBottomSheet, closeBottomSheet, bottomSheetState } from '@/core/states/bottomSheetState.js';
import { db } from '@/utils/db.js';
import { createNewSession as dbCreateSession, deleteSession as dbDeleteSession, switchSession as dbSwitchSession, getAllGreetings, getChatData } from '@/utils/sessions.js';
import { lorebookState, getActiveLorebooksForContext } from '@/core/states/lorebookState.js';
import { presetState, getEffectivePreset, getEffectivePresetId } from '@/core/states/presetState.js';
import { useVirtualScroll } from '@/composables/chat/useVirtualScroll.js';
import { useSelectionAutoScroll } from '@/composables/chat/useSelectionAutoScroll.js';
import { useGenerationRegistry } from '@/composables/chat/useGenerationRegistry.js';
import { useTypingStateCleanup } from '@/composables/chat/useTypingStateCleanup.js';
import { useSidebarResizer } from '@/composables/ui/useSidebarResizer.js';
import { sendMessageNotification, clearMessageNotifications } from '@/core/services/notificationService.js';
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
import TokenizerSheet from '@/components/sheets/TokenizerSheet.vue';
import ImageGenSheet from '@/components/sheets/ImageGenSheet.vue';
import GlossarySheet from '@/components/sheets/GlossarySheet.vue';
import MemoryBooksSheet from '@/components/sheets/MemoryBooksSheet.vue';
import { addDeletedStats, migrateStatsIfNeeded } from '@/core/services/statsService.js';
import { showToast } from '@/core/states/toastState.js';
import { ensureSessionMemoryBook } from '@/core/services/memorySchema.js';
import { triggerAutoSyncCheck } from '@/composables/chat/useAutoSync.js';
import { useMemoryBooks } from '@/composables/chat/useMemoryBooks.js';
import { useMemoryAutomation } from '@/composables/chat/useMemoryAutomation.js';
import { useChatMessageDisplay, restoreVisibleSwipeState } from '@/composables/chat/useChatMessageDisplay.js';
import { useMessageSelection } from '@/composables/chat/useMessageSelection.js';
import { useChatSearch } from '@/composables/chat/useChatSearch.js';
import { useMemorySheetUI } from '@/composables/chat/useMemorySheetUI.js';
import { useSwipeNavigation } from '@/composables/chat/useSwipeNavigation.js';
import { useSessionManagement } from '@/composables/chat/useSessionManagement.js';
import { useMessageActions } from '@/composables/chat/useMessageActions.js';
import { useChatGeneration } from '@/composables/chat/useChatGeneration.js';
import { useContextCutoff } from '@/composables/chat/useContextCutoff.js';
import { publishAppEvent, subscribeAppEvent } from '@/core/events/eventHub.js';
import { APP_EVENTS } from '@/core/events/eventNames.js';
import { useSessionPersistence } from '@/composables/chat/useSessionPersistence.js';

function genMsgId() {
    return `msg_${Date.now()}_${++_msgIdCounter}`;
}
import { getMemoryPromptOptions, getMemoryPromptLabel, getMemoryPromptLabelByKey, getNormalizedMemoryGenerationState } from '@/core/services/memoryPromptPresets.js';

// Import additional memory service functions needed locally
const {
    getMemoryKeyMatchMode,
    setMemoryVectorSearchOnEntries,
    reindexAllMemoryEntries
} = memoryBooksService;

let chatGenerationServices = null;

const t = (key) => translations[currentLang.value]?.[key] || key;

const isAndroid = Capacitor.getPlatform() === 'android';
const isBatterySaverUI = computed(() => shouldUseBatterySaverUI());
const formatGenerationElapsed = (startTime) => {
    const elapsedSeconds = (Date.now() - startTime) / 1000;
    return isBatterySaverUI.value
        ? elapsedSeconds.toFixed(0) + 's'
        : elapsedSeconds.toFixed(1) + 's';
};
const getGenerationTimerInterval = () => isBatterySaverUI.value ? 1000 : 100;
const currentMessages = ref([]);
const {
    nextGenerationId,
    listGeneratingCharIds,
    getGenerationState,
    hasGenerationState,
    setGenerationState,
    isGenerationStateCurrent,
    clearGenerationState,
    markGenerationPersisted,
    clearPersistedGeneration,
    buildGenerationOwnerKey,
    createGenerationRequestToken
} = useGenerationRegistry();
const restartVisibleGenerationTimers = () => {
    if (!activeChatChar) return;

    const state = getGenerationState(activeChatChar.id);
    if (!state) return;

    if (typeof state.restartGenerationTimer === 'function') {
        state.restartGenerationTimer();
        return;
    }

    if (state.timerId) clearTimeout(state.timerId);
    state.timerId = setTimeout(() => {
        state.timerId = null;
        const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
        if (idx !== -1) {
            currentMessages.value[idx].genTime = formatGenerationElapsed(state.startTime);
        }
    }, getGenerationTimerInterval());
};

let abortActiveChatGeneration = async () => false;
let abortAnyActiveGeneration = async () => false;
const { clearTypingStateForMessage } = useTypingStateCleanup({ currentMessages, getChatData, db });

// --- Component State ---
const chatViewRoot = ref(null);
const messagesContainer = ref(null);
const chatInputContainer = ref(null);

const chatRootStyle = computed(() => {
    return {
        '--chat-max-width': chatMaxWidth.value > 0 ? `${chatMaxWidth.value}px` : '100%'
    };
});

const { width: leftWidthRef, startResize: startLeftWidthResize } = useSidebarResizer('gz_chat_max_width', chatMaxWidth.value || 800, 'right', 400, 1600);
const { width: rightWidthRef, startResize: startRightWidthResize } = useSidebarResizer('gz_chat_max_width', chatMaxWidth.value || 800, 'left', 400, 1600);

watch(leftWidthRef, (val) => {
    setChatMaxWidth(val);
    if (rightWidthRef.value !== val) rightWidthRef.value = val;
});
watch(rightWidthRef, (val) => {
    setChatMaxWidth(val);
    if (leftWidthRef.value !== val) leftWidthRef.value = val;
});

const chatInputRef = ref(null);
const inputValue = ref('');
const isImpersonating = ref(false);
const isGenerating = ref(false);
const showScrollButton = ref(false);
const isLoading = ref(false);
let currentOnBack = null;
let inputResizeObserver = null;
const apiView = ref(null);
const statsSheet = ref(null);
const tokenizerSheet = ref(null);
const imageGenSheet = ref(null);
const openImageGenSheet = () => imageGenSheet.value?.open();
const glossarySheet = ref(null);
const openGlossarySheet = () => glossarySheet.value?.open();
const memoryBooksSheet = ref(null);
const presetView = ref(null);
const charCardSheet = ref(null);
const lorebookSheet = ref(null);
const regexSheet = ref(null);
const activeChar = ref(null);
({ abortActiveChatGeneration, abortAnyActiveGeneration } = useGenerationAbort({
    getGenerationState,
    clearGenerationState,
    isGenerating,
    isImpersonating,
    activeChatChar: activeChar
}));
const regexRevision = ref(0);
// Initialize Memory Books composable
const {
    currentMemoryBookData,
    pendingMemoryMessageIds,
    draftMemoryMessageIds,
    memoryDraftState,
    loadCurrentMemoryBook,
    updatePendingMemoryMessageIds,
    startMemoryDraftProgress,
    stopMemoryDraftProgress,
    cancelMemoryDraft,
    setMemoryDraftAbortController,
    getMemoryDraftAbortController,
    handleMemorySearchTypeUpdate: handleMemorySearchTypeUpdate_composable,
    handleMemoryReindexAll: handleMemoryReindexAll_composable,
    handleMemoryScanChat: handleMemoryScanChat_composable,
    handleMemoryApproveDraft: handleMemoryApproveDraft_composable,
    handleMemoryDeleteDraft: handleMemoryDeleteDraft_composable,
    handleMemoryDeleteAllDrafts: handleMemoryDeleteAllDrafts_composable,
    handleMemoryDeleteEntry: handleMemoryDeleteEntry_composable,
    handleMemoryCancelDraft: handleMemoryCancelDraft_composable,
    handleMemoryOpenMaintenance: handleMemoryOpenMaintenance_composable
} = useMemoryBooks({
    getChatData,
    showToast,
    showBottomSheet,
    closeBottomSheet,
    formatError,
    db
});

let openMemoryBooksSheet = () => {};

const {
    createPendingMemoryDraft,
    generateMemoryDraftForMessages,
    runMemoryAutomationAfterStableTurn,
    bootstrapImportedMemoryDrafts,
    buildMemoryContinuityContext,
    buildMemoryDraftLoreContext,
    buildMemoryDraftSummaryExcerpt,
    parseMemoryDraftResponse,
    runBatchDraftGeneration,
    runBatchDraftGenerationFromIds,
    generateSingleDraft,
    handleMemoryBatchGenerate: handleMemoryBatchGenerate_impl,
    handleMemoryQuickModelChange: handleMemoryQuickModelChange_impl
} = useMemoryAutomation({
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    activePersona,
    getGenerationState,
    memoryDraftState,
    currentMemoryBookData,
    loadCurrentMemoryBook,
    updatePendingMemoryMessageIds,
    startMemoryDraftProgress,
    stopMemoryDraftProgress,
    setMemoryDraftAbortController,
    openMemoryBooksSheet
});

const {
    getAvatar,
    getAvatarLetter,
    getAvatarColor,
    getDisplayName,
    openAvatar
} = useChatMessageDisplay(() => activeChatChar, allPersonas);

const onRegexChanged = () => {
    regexRevision.value++;
    invalidateRegexCache();
    invalidateFormatCache();
};

let isOpeningChat = false;

const {
    cutoffIndex,
    contextBreakdown,
    contextSegments,
    contextBreakdownItems,
    contextLegendItems,
    visibleHistoryMessages,
    historyUsagePercent,
    historyHidePreview,
    shouldRecommendHide,
    historyFillThreshold,
    historyHidePercent,
    saveCurrentMessages,
    updateContextCutoff,
    debouncedUpdateContextCutoff,
    invalidateContextCache,
    handleSaveContextSettings,
    hideTopMessagesNow,
    confirmHideTopMessages,
    unhideAllMessages,
    openContextSheet,
    resetCutoffState,
    clearCutoffTimers,
    consumePendingCutoffRecalc,
    getIsCalculatingCutoff,
    setPendingCutoffRecalc
} = useContextCutoff({
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    isOpeningChat: () => isOpeningChat,
    isBatterySaverUI,
    getChatData,
    db,
    getEffectivePreset,
    showBottomSheet,
    closeBottomSheet,
    showToast,
    tokenizerSheet,
    presetView
});

const pendingGuidance = ref(null); // { text, type }

let ignoreScrollAdjustment = false;
let ignoreScrollAdjustmentTimer = null;



// --- Selection State ---
const {
    selectedMessages,
    isSelectionMode,
    selectionIncludesLast,
    toggleSelection,
    clearSelection,
    deleteSelectedMessages,
    toggleHideSelectedMessages
} = useMessageSelection(currentMessages, {
    getChatData,
    db,
    addDeletedStats,
    reconcileSessionMemoryState,
    debouncedUpdateContextCutoff: () => debouncedUpdateContextCutoff(),
    getActiveChatChar: () => activeChatChar
});


const {
    openMemoryEntryEditor,
    openMemoryPromptPreview,
    createMemoryFromSelection,
    generateMemoryDraftFromSelection,
    openMemoryTextPreview,
    openMessageMemoryCoverage,
    removeMemoryFromSelection,
    openMemoryGenerationSettings,
    openMemoryPromptManager,
    openMemoryPromptEditor,
    openMemoryBooksSheet: openMemoryBooksSheetImpl,
    handleMemorySearchTypeUpdate,
    handleMemoryReindexAll,
    handleMemoryScanChat,
    handleMemoryBatchGenerate,
    handleMemoryGenerateSingleDraft,
    handleMemoryApproveDraft,
    handleMemoryDeleteDraft,
    handleMemoryDeleteAllDrafts,
    handleMemoryDeleteEntry,
    handleMemoryOpenMaintenance,
    handleMemoryCancelDraft,
    handleMemoryPreview,
    handleMemoryOpenSettings,
    handleMemoryQuickModelChange
} = useMemorySheetUI({
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    selectedMessages,
    clearSelection,
    memoryBooksSheet,
    loadCurrentMemoryBook,
    generateMemoryDraftForMessages,
    generateSingleDraft,
    cancelMemoryDraft,
    handleMemorySearchTypeUpdate_composable,
    handleMemoryReindexAll_composable,
    handleMemoryScanChat_composable,
    handleMemoryApproveDraft_composable,
    handleMemoryDeleteDraft_composable,
    handleMemoryDeleteAllDrafts_composable,
    handleMemoryDeleteEntry_composable,
    handleMemoryOpenMaintenance_composable,
    handleMemoryBatchGenerate_impl,
    handleMemoryQuickModelChange_impl,
    debouncedUpdateContextCutoff: () => debouncedUpdateContextCutoff()
});

openMemoryBooksSheet = openMemoryBooksSheetImpl;

// --- Display Logic (Separators) ---
const displayMessages = computed(() => {
    const msgs = currentMessages.value;
    if (!msgs || msgs.length === 0) return [];
    
    const res = [];
    let lastDateKey = null;
    let visibleIndex = 0;
    
    for (let i = 0; i < msgs.length; i++) {
        const msg = msgs[i];
        if (!msg) continue;
        const d = new Date(msg.timestamp);
        const dateKey = d.toDateString();
        
        if (dateKey !== lastDateKey) {
            res.push({ type: 'separator', timestamp: msg.timestamp, id: `sep_${dateKey}` });
            lastDateKey = dateKey;
        }
        
        if (!msg.isHidden) {
            if (visibleIndex === cutoffIndex.value && visibleIndex > 0) {
                res.push({ type: 'cutoff', id: 'context-cutoff' });
            }
            visibleIndex++;
        }
        
        res.push({ type: 'message', data: msg, originalIndex: i, id: `msg_${msg.timestamp}_${i}` });
    }
    
    if (cutoffIndex.value >= visibleIndex && visibleIndex > 0) {
        res.push({ type: 'cutoff', id: 'context-cutoff-end' });
    }
    
    return res;
});

// --- Virtual Scroll Setup ---
const { visibleItems, paddingTop, paddingBottom, refresh: refreshVirtualScroll, scrollToBottom: vsScrollToBottom, isScrolling, isProgrammaticScrolling, getScrollAnchor, scrollToAnchor, scrollToIndex, isItemVisible } = useVirtualScroll(displayMessages, messagesContainer, {
    buffer: isBatterySaverUI.value ? 28 : 75,
    estimateHeight: 100
});

useSelectionAutoScroll(messagesContainer, isProgrammaticScrolling);

const {
    asyncSaveCurrentSessionState,
    applyImageAutoHide,
    onVisibilityChange,
    onNativeBackground,
    buildCrashBufferKey,
    clearCrashBuffer
} = useSessionPersistence({
    getActiveChatChar: () => activeChatChar,
    activeChar,
    currentMessages,
    inputValue,
    messagesContainer,
    db,
    getChatData,
    getScrollAnchor,
    clearMessageNotifications
});

const {
    deleteSession,
    openSessionsSheet,
    openDeleteSessionConfirm,
    createNewSession
} = useSessionManagement({
    activeChar,
    getActiveChatChar: () => activeChatChar,
    setActiveChatChar: (v) => { activeChatChar = v; },
    currentMessages,
    inputValue,
    isGenerating,
    hasGenerationState,
    getGenerationState,
    clearGenerationState,
    abortActiveChatGeneration,
    getChatGenerationServices: () => chatGenerationServices,
    loadChats,
    openChat,
    asyncSaveCurrentSessionState: () => asyncSaveCurrentSessionState(),
    getCleanupScroll: () => _cleanupScroll,
    setCleanupScroll: (v) => { _cleanupScroll = v; },
    t
});

// --- Search Logic ---
const {
    isSearchMode,
    searchQuery,
    searchResults,
    currentSearchIndex,
    searchMatchState,
    scrollToSearchResult,
    nextSearchResult,
    prevSearchResult,
    onChatSearchToggle,
    onChatSearch
} = useChatSearch({ currentMessages, scrollToIndex, displayMessages });

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

watch([isSearchMode, isSelectionMode], () => {
    ignoreScrollAdjustment = true;
    if (ignoreScrollAdjustmentTimer) clearTimeout(ignoreScrollAdjustmentTimer);
    ignoreScrollAdjustmentTimer = setTimeout(() => {
        ignoreScrollAdjustment = false;
    }, 400);
});

// --- Data Management ---

async function loadChats() {
    for (const charId of listGeneratingCharIds()) {
        const state = getGenerationState(charId);
        await db.patchChatData(charId, (memData) => {
            if (!memData) return;
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
            }
        });
    }

    if (activeChatChar) {
        const data = await getChatData(activeChatChar.id);
        const sessionId = activeChatChar.sessionId || data.currentId;
        if (data && data.sessions && data.sessions[sessionId]) {
            currentMessages.value = restoreVisibleSwipeState(data.sessions[sessionId]);
        } else {
            currentMessages.value = [];
        }
    }
}

async function updateSessionMessage(char, msgIndex, newMsgData) {
    const msgCopy = JSON.parse(JSON.stringify(newMsgData));
    await db.patchChatData(char.id, (data) => {
        const sessionId = char.sessionId || data?.currentId;
        if (data && sessionId && data.sessions[sessionId]) {
            data.sessions[sessionId][msgIndex] = msgCopy;
        }
    });
}

function handleSheetBack() {
    tokenizerSheet.value?.close();
    memoryBooksSheet.value?.close();
    chatInputRef.value?.openMagicDrawer();
}

async function setupHeader(char = activeChatChar) {
    if (!char) return;
    const data = await getChatData(char.id);
    const initialSessionId = char.sessionId || (data ? data.currentId : '...');
    const sessionName = data?.sessionNames?.[initialSessionId];

    publishAppEvent(APP_EVENTS.ui.header.setupChat, {
            char,
            currentSessionId: initialSessionId,
            sessionName,
            callbacks: {
                onActionsClick: () => openSessionsSheet(char),
                onBackClick: () => {
                    closeChat();
                    if (typeof window !== 'undefined' && window.innerWidth >= 768) {
                        publishAppEvent(APP_EVENTS.nav.navigateTo, 'view-characters');
                    } else if (currentOnBack) {
                        currentOnBack();
                    }
                }
            }
        }
    );
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
    resetCutoffState();

    if (activeChatChar) {
        for (const charId of listGeneratingCharIds()) {
            const state = getGenerationState(charId);
            if (!state) continue;
            state.onUIUpdate = null;
            if (state.timerId) { clearTimeout(state.timerId); state.timerId = null; }
            if (typeof state.clearStreamFlushTimer === 'function') state.clearStreamFlushTimer();
            if (typeof state.streamFlush === 'function') state.streamFlush();
            if (typeof state.clearGenerationTimer === 'function') state.clearGenerationTimer();
        }
        await asyncSaveCurrentSessionState();
    }

    try {
    // Attempt to migrate legacy stats locally
    await migrateStatsIfNeeded();

    // Hide tabbar immediately to prevent flickering
    const tabbar = document.querySelector('.bottom-nav');
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
        await db.patchChatData(char.id, (data) => {
            if (data && data.sessions && data.sessions[char.sessionId]) {
                if (data.currentId !== char.sessionId) {
                    data.currentId = char.sessionId;
                }
            }
        });
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
    isGenerating.value = hasGenerationState(char.id);

    // Clear unread
    const unread = (await db.get('gz_unread')) || {};
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

    try {
        const skipCrashBuffer = localStorage.getItem('gz_backup_restored');
        if (skipCrashBuffer) {
            localStorage.removeItem('gz_backup_restored');
            clearCrashBuffer(char.id, currentSessionId);
        }
        const crashBufferRaw = localStorage.getItem(buildCrashBufferKey(char.id, currentSessionId));
        if (crashBufferRaw) {
            const crashBuffer = JSON.parse(crashBufferRaw);
            if (Array.isArray(crashBuffer?.messages) && crashBuffer.messages.length > msgs.length) {
                const restoredMsgs = crashBuffer.messages;
                const restoredDraft = typeof crashBuffer.draft === 'string' ? crashBuffer.draft : undefined;
                const restoredAN = crashBuffer.authorsNote;
                const restoredSummary = crashBuffer.summary;
                await db.patchChatData(char.id, (data) => {
                    data.sessions[currentSessionId] = restoredMsgs;
                    if (restoredDraft !== undefined) data.draft = restoredDraft;
                    if (restoredAN !== undefined) {
                        if (!data.authorsNotes) data.authorsNotes = {};
                        data.authorsNotes[currentSessionId] = restoredAN;
                    }
                    if (restoredSummary !== undefined) {
                        if (!data.summaries) data.summaries = {};
                        data.summaries[currentSessionId] = restoredSummary;
                    }
                });
                msgs = restoredMsgs;
            }
            clearCrashBuffer(char.id, currentSessionId);
        }
    } catch (e) {
        console.warn('[chat] Failed to restore crash buffer:', e);
    }

    // Filter out corrupted/null messages
    msgs = msgs.filter(m => m !== null && m !== undefined);
    // Backfill unique IDs for legacy messages
    msgs.forEach(m => {
        if (!m.id) m.id = `legacy_${m.timestamp || Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
        if (!Array.isArray(m.contextRefs)) m.contextRefs = [];
        if (!m.memoryCoverage || typeof m.memoryCoverage !== 'object') m.memoryCoverage = createEmptyMemoryCoverage();
        if (!Array.isArray(m.memoryCoverage.entryIds)) m.memoryCoverage.entryIds = [];
        if (typeof m.memoryCoverage.needsRebuild !== 'boolean') m.memoryCoverage.needsRebuild = false;
        if (typeof m.memoryCoverage.stale !== 'boolean') m.memoryCoverage.stale = false;
    });
    chatData.sessions[currentSessionId] = msgs;

    let dirty = false;
    while (msgs.length > 0) {
        const lastMsg = msgs[msgs.length - 1];
        const isPhantomTyping = lastMsg.isTyping && !hasGenerationState(char.id);

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
                lastMsg.isTyping = false;
                dirty = true;
                break;
            }
        } else {
            break;
        }
    }
    if (dirty) {
        const dirtyMsgs = JSON.parse(JSON.stringify(msgs));
        await db.patchChatData(char.id, (data) => {
            data.sessions[currentSessionId] = dirtyMsgs;
        });
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
            const fixedMsgs = JSON.parse(JSON.stringify(msgs));
            await db.patchChatData(char.id, (data) => {
                data.sessions[currentSessionId] = fixedMsgs;
            });
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
            timestamp: Date.now(),
            ...createBaseMessageMeta()
        };
        currentMessages.value.push(firstMsg);
        if (activeChatChar) {
            const sessionId = activeChatChar.sessionId;
            const snapshot = JSON.parse(JSON.stringify(currentMessages.value));
            await db.patchChatData(activeChatChar.id, (data) => {
                if (sessionId && data.sessions?.[sessionId]) {
                    data.sessions[sessionId] = snapshot;
                }
            });
        }
        scrollToBottom(false);
    }

    // Restore draft
    inputValue.value = chatData.draft || '';
    setPendingCutoffRecalc(true);

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
        if (hasGenerationState(char.id)) {
            const state = getGenerationState(char.id);
            let lastReopenScrollAt = 0;
            
            // Clear previous timer if exists (from previous mount)
            if (state.timerId) clearTimeout(state.timerId);

            // Define updater for this component instance
            state.onUIUpdate = (text, reasoning, isTyping, textDelta) => {
                const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
                if (idx !== -1) {
                    const m = currentMessages.value[idx];
                    m.text = text;
                    m.reasoning = reasoning;
                    m.isTyping = isTyping;

                    if (isBatterySaverUI.value) {
                        const now = Date.now();
                        if (now - lastReopenScrollAt >= 180) {
                            lastReopenScrollAt = now;
                            smartScroll();
                        }
                    } else {
                        smartScroll();
                    }
                }
            };

            // Restart timer for this component instance
            state.restartGenerationTimer = () => {
                if (state.timerId) clearTimeout(state.timerId);

                state.timerId = setTimeout(() => {
                    state.timerId = null;

                    const activeState = getGenerationState(char.id);
                    if (!activeState || activeState.genId !== state.genId) return;

                    const idx = currentMessages.value.findIndex(m => m.id === state.msgId);
                    if (idx !== -1) {
                        currentMessages.value[idx].genTime = formatGenerationElapsed(state.startTime);
                    }

                    if (typeof activeState.restartGenerationTimer === 'function') {
                        activeState.restartGenerationTimer();
                    }
                }, getGenerationTimerInterval());
            };
            state.restartGenerationTimer();
        }
    });

    // Lorebook Banner Trigger
    const activeLbs = getActiveLorebooksForContext(char.id, char.id && currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const presetName = effectivePreset ? effectivePreset.name : '';
    const effPersona = getEffectivePersona(char.id, currentSessionId ? `${char.id}_${currentSessionId}` : null);
    const personaName = effPersona ? effPersona.name : '';

    if (activeLbs.length > 0 || presetName || personaName) {
        publishAppEvent(APP_EVENTS.ui.header.showLbBanner, {
                names: activeLbs,
                preset: presetName,
                persona: personaName
            });
    }

    } finally {
        isLoading.value = false;
        isOpeningChat = false;
        if (consumePendingCutoffRecalc()) {
            updateContextCutoff();
        }
        updatePendingMemoryMessageIds(activeChatChar);
    }
}

async function handleMemoryFlushSave() {
    if (!activeChatChar || !currentMemoryBookData.value) return;
    try {
        await db.patchChatData(activeChatChar.id, (chatData) => {
            const sessionId = activeChatChar.sessionId || chatData.currentId;
            const memoryBook = ensureSessionMemoryBook(chatData, sessionId);
            memoryBook.updatedAt = Date.now();
        });
        await loadCurrentMemoryBook(activeChatChar);
        await updatePendingMemoryMessageIds(activeChatChar);
    } catch (e) {
        console.error('[MemoryBooks] flush-save error:', e);
    }
}

async function closeChat() {
    updateAppColors(true);
    let savePromise = null;
    if (activeChatChar && messagesContainer.value) {
        savePromise = asyncSaveCurrentSessionState();
        messagesContainer.value.removeEventListener('scroll', onScroll);
    }
    
    if (_cleanupScroll) {
        _cleanupScroll();
        _cleanupScroll = null;
    }

    publishAppEvent(APP_EVENTS.ui.header.reset);

    if (savePromise) {
        try { await savePromise; } catch (_e) {}
    }

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

chatGenerationServices = createChatGenerationServices({
    activeChatChar: activeChar,
    isGenerating,
    currentMessages,
    displayMessages,
    smartScroll,
    scrollToBottom,
    isItemVisible,
    scrollToIndex,
    genMsgId,
    updateSessionMessage,
    runMemoryAutomationAfterStableTurn
});

const {
    sendMessage,
    startGeneration,
    handleImageRegenerate,
    startImpersonation
} = useChatGeneration({
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    inputValue,
    isGenerating,
    pendingGuidance,
    hasGenerationState,
    getGenerationState,
    abortAnyActiveGeneration,
    getChatGenerationServices: () => chatGenerationServices,
    genMsgId,
    createBaseMessageMeta,
    nextGenerationId,
    createGenerationRequestToken,
    buildGenerationOwnerKey,
    updateSessionMessage,
    scrollToBottom,
    openApiView,
    memoryDraftState,
    isImpersonating,
    setGenerationState,
    clearGenerationState,
    cleanText,
    activeChar,
    t
});




// --- Message Actions ---

const {
    openMessageActions,
    regenerateMessage,
    branchSession,
    enterEditMode,
    saveEdit,
    cancelEdit,
    saveGuidance,
    toggleImageHidden
} = useMessageActions({
    activeChar,
    getActiveChatChar: () => activeChatChar,
    currentMessages,
    isGenerating,
    hasGenerationState,
    getGenerationState,
    clearGenerationState,
    abortActiveChatGeneration,
    startGeneration,
    updateSessionMessage,
    updateContextCutoff,
    unhideAllMessages,
    toggleSelection,
    loadChats,
    openChat,
    t
});

const {
    changeSwipe,
    changeGreeting
} = useSwipeNavigation({
    currentMessages,
    isGenerating,
    getActiveChatChar: () => activeChatChar,
    regenerateMessage: (msgIndex, mode, guidanceText) => regenerateMessage(msgIndex, mode, guidanceText)
});

// --- Utils ---

async function openCharCard() {
    if (!activeChatChar) return;
    charCardSheet.value?.open(activeChatChar, { importEnabled: false });
}

async function openChatStatsSheet(char = activeChatChar) {
    if (!char) return;
    statsSheet.value?.open(char, currentMessages.value);
}

function openApiView() {
    publishAppEvent(APP_EVENTS.nav.openApiSheet);
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

const restoreHeader = () => {
    if (activeChatChar) setupHeader(activeChatChar);
};

// Expose methods for App.vue
defineExpose({
    loadChats,
    openChat,
    restoreHeader,
    openLorebookEntry,
    startImpersonation,
    openPersonas: () => { chatInputRef.value?.openPersonas(); },
    initChat: () => {},
    contextBreakdown,
    openPresetView,
    openApiView,
    openLorebookSheet,
    openMemoryBooksSheet,
    openRegexSheet,
    openChatStatsSheet: () => openChatStatsSheet(),
    openCharCard,
    openSessionsSheet: () => openSessionsSheet(activeChatChar),
    openImageGenSheet,
    openGlossarySheet,
    openAuthorsNoteSheet: () => presetView.value?.openAuthorsNoteSheet(),
    openSummarySheet: () => presetView.value?.openSummarySheet(),
    openContextSheet: () => openContextSheet(),
    openRequestPreviewSheet: () => chatInputRef.value?.openRequestPreview(),
});

const onGenerationEnded = (e) => {
    if (activeChatChar && activeChatChar.id === e.detail.charId) {
        const activeState = getGenerationState(activeChatChar.id);
        if (activeState?.type === 'chat') {
            const endedSessionId = e.detail.sessionId ?? null;
            const endedGenId = e.detail.genId ?? null;
            if (endedGenId !== null && activeState.genId !== endedGenId) {
                return;
            }
            if (endedSessionId === null || String(activeState.sessionId) === String(endedSessionId)) {
                return;
            }
        }
        isGenerating.value = false;
        isImpersonating.value = false;

        const lastTypingIdx = currentMessages.value.findLastIndex(m => m.isTyping);
        if (lastTypingIdx !== -1 && !hasGenerationState(activeChatChar.id)) {
            currentMessages.value[lastTypingIdx].isTyping = false;
        }

        applyImageAutoHide();
        updateContextCutoff();
    }
};

const onCharacterUpdated = async (e) => {
    if (!activeChatChar) return;
    const updatedChar = e?.detail?.character;
    if (updatedChar && updatedChar.id === activeChatChar.id) {
        activeChatChar = updatedChar;
        activeChar.value = updatedChar;
        publishAppEvent(APP_EVENTS.ui.header.updateAvatar, activeChatChar);
    } else {
        const charId = activeChatChar.id;
        const allChars = await db.getAll('characters');
        const freshChar = allChars.find(c => String(c.id) === String(charId));
        if (freshChar) {
            freshChar.sessionId = activeChatChar.sessionId;
            activeChatChar = freshChar;
            activeChar.value = freshChar;
            publishAppEvent(APP_EVENTS.ui.header.updateAvatar, activeChatChar);
        }
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

        const targetPadding = currentFullHeight;

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
    unsubCharacterUpdated = subscribeAppEvent(APP_EVENTS.domain.character.updated, ({ detail }) => onCharacterUpdated({ detail }));
    unsubGenerationEnded = subscribeAppEvent(APP_EVENTS.domain.generation.ended, ({ detail }) => onGenerationEnded({ detail }));
    unsubFsEditorClosed = subscribeAppEvent(APP_EVENTS.ui.fsEditorClosed, onFsEditorClosed);
    if (window.visualViewport) {
        window.visualViewport.addEventListener('resize', handleVisualViewport);
        window.visualViewport.addEventListener('scroll', handleVisualViewport);
        handleVisualViewport();
    }

    // Clear notifications when app comes to foreground and chat is active
    document.addEventListener('visibilitychange', onVisibilityChange);

    if (Capacitor.isNativePlatform()) {
        App.addListener('appStateChange', ({ isActive }) => {
            if (!isActive && activeChatChar) {
                onNativeBackground(activeChatChar);
                const charId = activeChatChar.id;
                const sessionId = activeChatChar.sessionId;
                const messagesSnapshot = currentMessages.value;
                const draft = inputValue.value;
                const authorsNote = activeChatChar.authors_note;
                const summary = activeChatChar.summary;
                db.patchChatData(charId, (data) => {
                    if (sessionId) {
                        data.sessions[sessionId] = JSON.parse(JSON.stringify(messagesSnapshot));
                    }
                    data.draft = draft;
                    if (authorsNote !== undefined) {
                        if (!data.authorsNotes) data.authorsNotes = {};
                        data.authorsNotes[sessionId] = authorsNote;
                    }
                    if (summary !== undefined) {
                        if (!data.summaries) data.summaries = {};
                        let currentSum = data.summaries[sessionId];
                        if (typeof currentSum === 'string') {
                            currentSum = { content: currentSum, depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
                        } else if (!currentSum) {
                            currentSum = { content: '', depth: 4, role: 'system', insertion_mode: 'relative', prefix: 'Summary: ' };
                        }
                        if (currentSum.content !== summary) {
                            data.summaries[sessionId] = { ...currentSum, content: summary };
                        }
                    }
                });
            }
        }).then(handle => { _appStateListener = handle; });
    }

    if (chatInputContainer.value) {
        inputResizeObserver = new ResizeObserver(updateContentPadding);
        inputResizeObserver.observe(chatInputContainer.value);
        if (messagesContainer.value) inputResizeObserver.observe(messagesContainer.value);
        updateContentPadding();
    }
    updateContextCutoff();
    unsubChatSearchToggle = subscribeAppEvent(APP_EVENTS.ui.chatSearchToggle, ({ detail }) => onChatSearchToggle({ detail }));
    unsubRegexChanged = subscribeAppEvent(APP_EVENTS.domain.lorebook.regexScriptsChanged, onRegexChanged);
    unsubChatSearch = subscribeAppEvent(APP_EVENTS.ui.chatSearch, ({ detail }) => onChatSearch({ detail }));
    unsubApiContextChanged = subscribeAppEvent(APP_EVENTS.domain.settings.apiContextChanged, () => { invalidateContextCache(); updateContextCutoff(); });
    unsubSettingsChanged = subscribeAppEvent(APP_EVENTS.domain.settings.changed, restartVisibleGenerationTimers);
    unsubSyncDataRefreshed = subscribeAppEvent(APP_EVENTS.domain.sync.dataRefreshed, () => loadChats());
});

watch(() => currentMessages.value.length, () => {
    updateContextCutoff();
});

onUnmounted(() => {
    setScrollLock(false);
    stopMemoryDraftProgress();
    for (const charId of listGeneratingCharIds()) {
        const state = getGenerationState(charId);
        if (!state) continue;
        state.onUIUpdate = null;
        if (state.timerId) {
            clearTimeout(state.timerId);
            state.timerId = null;
        }
        if (typeof state.clearStreamFlushTimer === 'function') {
            state.clearStreamFlushTimer();
        }
        if (typeof state.streamFlush === 'function') {
            state.streamFlush();
        }
        if (typeof state.clearGenerationTimer === 'function') {
            state.clearGenerationTimer();
        }
    }
    if (unsubCharacterUpdated) { unsubCharacterUpdated(); unsubCharacterUpdated = null; }
    document.removeEventListener('visibilitychange', onVisibilityChange);
    if (unsubGenerationEnded) { unsubGenerationEnded(); unsubGenerationEnded = null; }
    if (unsubFsEditorClosed) { unsubFsEditorClosed(); unsubFsEditorClosed = null; }
    
    if (window.visualViewport) {
        window.visualViewport.removeEventListener('resize', handleVisualViewport);
        window.visualViewport.removeEventListener('scroll', handleVisualViewport);
    }
    if (_vpRafId) {
        cancelAnimationFrame(_vpRafId);
        _vpRafId = null;
    }

    if (_appStateListener) {
        _appStateListener.remove();
        _appStateListener = null;
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
    if (unsubChatSearchToggle) { unsubChatSearchToggle(); unsubChatSearchToggle = null; }
    if (unsubRegexChanged) { unsubRegexChanged(); unsubRegexChanged = null; }
    if (unsubChatSearch) { unsubChatSearch(); unsubChatSearch = null; }
    if (unsubApiContextChanged) { unsubApiContextChanged(); unsubApiContextChanged = null; }
    if (unsubSettingsChanged) { unsubSettingsChanged(); unsubSettingsChanged = null; }
    if (unsubSyncDataRefreshed) { unsubSyncDataRefreshed(); unsubSyncDataRefreshed = null; }
    clearCutoffTimers();

    // Reset chatViewRoot height to prevent stale inline style leaking to next mount
    if (chatViewRoot.value) {
        chatViewRoot.value.style.height = '';
    }
});

</script>

<template>
    <div id="view-chat" ref="chatViewRoot" :class="{ 'android-resize-fix': isAndroid }" :style="chatRootStyle">
        <div v-if="isLoading" class="chat-loading-overlay">
            <div class="app-loader-spinner"></div>
        </div>

        <div class="sidebar-drag-handle" v-if="!isAndroid && chatMaxWidth > 0" :style="{ left: 'calc((100% - ' + chatMaxWidth + 'px) / 2 - 4px)' }" @mousedown="startLeftWidthResize" style="position: absolute; z-index: 10;"></div>
        <div class="sidebar-drag-handle" v-if="!isAndroid && chatMaxWidth > 0" :style="{ right: 'calc((100% - ' + chatMaxWidth + 'px) / 2 - 4px)' }" @mousedown="startRightWidthResize" style="position: absolute; z-index: 10;"></div>

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
                    :is-selected="selectedMessages.has(vItem.item.data.id)"
                    :is-pending-memory="pendingMemoryMessageIds.has(vItem.item.data.id)"
                    :is-draft-memory="draftMemoryMessageIds.has(vItem.item.data.id)"
                    :total-messages="currentMessages.length"
                    @swipe="(dir) => changeSwipe(vItem.item.originalIndex, dir, true)"
                    @change-greeting="(dir) => changeGreeting(vItem.item.originalIndex, dir, true)"
                    @regenerate="(mode, guidanceText) => regenerateMessage(vItem.item.originalIndex, mode, guidanceText)"
                    @edit="() => enterEditMode(vItem.item.data)"
                    @save-edit="saveEdit(vItem.item.data, vItem.item.originalIndex)"
                    @cancel-edit="cancelEdit(vItem.item.data)"
                    @update:edit-text="(val) => { vItem.item.data.editText = val }"
                    @save-guidance="(text) => saveGuidance(vItem.item.data, vItem.item.originalIndex, text)"
                    @open-actions="openMessageActions(vItem.item.data, vItem.item.originalIndex)"
                    @open-avatar="openAvatar(vItem.item.data)"
                    @open-memory-coverage="openMessageMemoryCoverage"
                    @toggle-selection="toggleSelection(vItem.item.data.id)"
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
                :can-delete-selected="selectionIncludesLast"
                :search-match-current="currentSearchIndex + 1"
                :search-match-total="searchResults.length"
                :active-char="activeChar"
                :context-breakdown="contextBreakdown"
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
                @magic-memory-books="openMemoryBooksSheet"
                @magic-regex="openRegexSheet"
                @magic-image-gen="openImageGenSheet"
                @magic-glossary="openGlossarySheet"
                @delete-selected="deleteSelectedMessages"
                @hide-selected="toggleHideSelectedMessages"
                @generate-memory-draft-selected="generateMemoryDraftFromSelection"
                @create-memory-selected="createMemoryFromSelection"
                @remove-memory-selected="removeMemoryFromSelection"
                @cancel-selection="clearSelection"
            />
            

        </div>

        <div style="display: none;"></div>
        <PresetView ref="presetView" :active-chat-char="activeChar" :chat-history="currentMessages" :is-generating="isGenerating" :context-breakdown="contextBreakdown" @update:active-chat-char="val => { if (activeChar) Object.assign(activeChar, val) }" />
        <CharacterCardSheet ref="charCardSheet" />
        <LorebookSheet ref="lorebookSheet" />
        <RegexSheet ref="regexSheet" :active-chat-char="activeChar" />
        <StatsSheet ref="statsSheet" />
        <TokenizerSheet
            ref="tokenizerSheet"
            :breakdown="contextBreakdown"
            :context-segments="contextSegments"
            :context-breakdown-items="contextBreakdownItems"
            :context-legend-items="contextLegendItems"
            :history-usage-percent="historyUsagePercent"
            :history-hide-preview="historyHidePreview"
            :should-recommend-hide="shouldRecommendHide"
            :history-fill-threshold="historyFillThreshold"
            :history-hide-percent="historyHidePercent"
            :is-calculating="getIsCalculatingCutoff()"
            @hide-messages="confirmHideTopMessages"
            @save-settings="handleSaveContextSettings"
            @back="handleSheetBack"
        />
        <ImageGenSheet ref="imageGenSheet" />
        <GlossarySheet ref="glossarySheet" />
        <MemoryBooksSheet
            v-if="currentMemoryBookData"
            ref="memoryBooksSheet"
            :memory-book="currentMemoryBookData"
            :current-messages="currentMessages"
            :character-name="activeChatChar?.name || 'Character'"
            :session-id="String(activeChatChar?.sessionId || '')"
            :memory-draft-state="memoryDraftState"
            :pending-memory-message-ids="pendingMemoryMessageIds"
            @close="() => {}"
            @flush-save="handleMemoryFlushSave"
            @open-settings="handleMemoryOpenSettings"
            @open-maintenance="handleMemoryOpenMaintenance"
            @open-preview="handleMemoryPreview"
            @update-search-type="handleMemorySearchTypeUpdate"
            @reindex-all="handleMemoryReindexAll"
            @scan-chat="handleMemoryScanChat"
            @batch-generate="handleMemoryBatchGenerate"
            @generate-draft="handleMemoryGenerateSingleDraft"
            @delete-all-drafts="handleMemoryDeleteAllDrafts"
            @approve-draft="handleMemoryApproveDraft"
            @delete-draft="handleMemoryDeleteDraft"
            @delete-entry="handleMemoryDeleteEntry"
            @cancel-draft="handleMemoryCancelDraft"
            @change-model="handleMemoryQuickModelChange"
            @back="handleSheetBack"
        />
    </div>
</template>

<style src="@/assets/css/chat.css"></style>


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
