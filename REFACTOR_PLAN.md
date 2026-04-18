# Backend/Service Logic Refactoring Plan

## Current Situation

ChatView.vue содержит ~6787 строк, из которых:
- ~68 функций для Memory Books logic
- ~11 функций для Context/Tokenizer logic  
- Множество helper функций смешаны с UI логикой

## Proposed Extraction

### 1. Memory Books Service (HIGH PRIORITY)

**File:** `src/core/services/memoryBooksService.js`

**Functions to extract (~50-60 functions, ~800-1000 lines):**

#### Core Memory Book Management
- `ensureSessionMemoryBook(chatData, sessionId)` — создание/получение memory book
- `createEmptyMemoryCoverage()` — инициализация coverage
- `createMemoryAutomationState()` — инициализация automation
- `ensureMemoryAutomationState(memoryBook)` — ensure automation state
- `reconcileMemoryBookForMessages(memoryBook, messages)` — синхронизация entries с messages
- `reconcileSessionMemoryState(chatData, sessionId, messages)` — reconcile session state
- `runMemoryMaintenancePass(chatData, sessionId, options)` — cleanup и maintenance

#### Memory Entry Operations
- `genMemoryEntryId()` — ID generation
- `normalizeMemoryEntryShape(entry)` — normalize entry structure
- `parseMemoryKeyInput(value)` — parse key input
- `buildMemoryKeysFromText(text, fallback)` — extract keys from text
- `findConflictingMemoryEntry(memoryBook, selectedIds, options)` — conflict detection
- `normalizeEntryMessageIds(entry)` — normalize messageIds array

#### Vector/Embedding Operations
- `indexMemoryEntryIfNeeded(entry, charId, sessionId)` — index if vector search enabled
- `deleteMemoryEntryIndexIfPresent(entryId)` — delete embedding
- `reindexMemoryEntry(entry, charId, sessionId)` — reindex single entry
- `reindexAllMemoryEntries(memoryBook, charId, sessionId)` — reindex all entries
- `shouldEnableMemoryVectorSearch()` — check if vector search available
- `getMemoryVectorSearchEnabled(memoryBook)` — get vector search state
- `setMemoryVectorSearchOnEntries(memoryBook, enabled)` — toggle vector search

#### Memory Draft Generation
- `generateMemoryDraftForMessages(selectedMessages, options)` — generate draft
- `runBatchDraftGeneration(chatData, sessionId, memoryBook, segments, count)` — batch generation
- `runMemoryAutomationAfterStableTurn(chatData, sessionId, messages, options)` — auto-generation
- `bootstrapImportedMemoryDrafts(charId, sessionId)` — bootstrap after import
- `parseMemoryDraftResponse(rawText, fallbackKeys)` — parse LLM response
- `buildMemoryContinuityContext(memoryBook, selected)` — build context for continuity
- `buildMemoryDraftLoreContext(selected)` — build lorebook context
- `buildMemoryDraftSummaryExcerpt(summary)` — build summary excerpt

#### Memory Prompt Management
- `getMemoryPromptOptions(settings)` — get available prompts
- `resolveMemoryPrompt(settings)` — resolve prompt text
- `getMemoryPromptLabel(settings)` — get prompt label
- `builtInMemoryPrompts` — константы built-in промптов

#### Automation & Triggers
- `normalizeAutoCreateInterval(memoryBook)` — normalize interval
- `memoryBooksHasAutomationState(memoryBook)` — check automation state
- `resolvePendingTriggerMessages(stableMessages, pendingTrigger)` — resolve pending triggers
- `buildBootstrapSegments(messages, interval)` — build segments for bootstrap
- `countStableConversationMessages(messages)` — count stable messages
- `getLastStableConversationRole(messages)` — get last role
- `computeDelayedWaitExchanges(triggerRole)` — compute wait exchanges

#### Utilities
- `arraysEqual(a, b)` — array equality
- `calculateMessageOverlapRatio(leftIds, rightIds)` — overlap calculation
- `formatElapsedSeconds(ms)` — format time
- `getMemoryKeyMatchMode(memoryBook)` — get key match mode

**Benefits:**
- Уменьшит ChatView на ~800-1000 строк
- Изолирует Memory Books бизнес-логику
- Позволит тестировать логику отдельно от UI
- Упростит переиспользование (например, в worker'ах)

---

### 2. Composable: useMemoryBooks (MEDIUM PRIORITY)

**File:** `src/composables/chat/useMemoryBooks.js`

**Reactive state + UI interaction logic (~200-300 lines):**

#### State
- `currentMemoryBookData` — ref для текущего memory book
- `memoryDraftState` — ref для draft generation state
- `pendingMemoryMessageIds` — ref для pending message IDs
- `draftMemoryMessageIds` — ref для draft message IDs

#### UI Handlers (already extracted to ChatView, но можно в composable)
- `loadCurrentMemoryBook()` — load reactive memory book
- `updatePendingMemoryMessageIds()` — update pending IDs
- `handleMemoryKeyModeUpdate()` — key mode change
- `handleMemoryVectorToggle(enabled)` — vector search toggle
- `handleMemoryReindexAll()` — reindex all
- `handleMemoryScanChat()` — scan chat
- `handleMemoryBatchGenerate()` — batch generate
- `handleMemoryApproveDraft(draftId)` — approve draft
- `handleMemoryDeleteDraft(draftId)` — delete draft
- `handleMemoryDeleteEntry(entryId)` — delete entry
- `handleMemoryCancelDraft()` — cancel draft generation

#### Progress Tracking
- `startMemoryDraftProgress(label)` — start progress timer
- `stopMemoryDraftProgress()` — stop progress timer
- `cancelMemoryDraft()` — cancel + cleanup

**Benefits:**
- Убирает reactive state из ChatView
- Группирует UI interaction logic
- Легко переиспользовать в других view

---

### 3. Context/Tokenizer Service (LOW PRIORITY)

**File:** `src/core/services/contextService.js`

**Functions to extract (~5-8 functions, ~200-300 lines):**

#### Context Calculation
- `updateContextCutoff()` — calculate context cutoff
- `debouncedUpdateContextCutoff(delay)` — debounced version
- `invalidateContextCache()` — invalidate cache

#### History Management
- `persistHistoryContextSettings(fillThreshold, hidePercent)` — save settings
- `clampHistoryFillThreshold(value)` — clamp value
- `clampHistoryHidePercent(value)` — clamp value
- `hideTopMessagesNow()` — hide messages
- `confirmHideTopMessages()` — confirm dialog

**Computed properties (остаются в ChatView или composable):**
- `contextSegments` — segment breakdown
- `contextBreakdownItems` — breakdown items
- `contextLegendItems` — legend items
- `historyUsagePercent` — usage percentage
- `historyHidePreview` — preview info
- `shouldRecommendHide` — recommendation flag

**Benefits:**
- Изолирует context calculation logic
- Проще тестировать
- Но меньший приоритет, т.к. уже относительно небольшой и чистый код

---

## Execution Order

### Phase 7: Memory Books Service Extraction

**Priority:** HIGH  
**Impact:** ~800-1000 lines from ChatView  
**Complexity:** MEDIUM-HIGH (много взаимосвязей)

**Steps:**
1. Create `src/core/services/memoryBooksService.js`
2. Extract pure functions (no refs, no reactive state)
3. Update imports in ChatView
4. Update imports in MemoryBooksSheet (if needed)
5. Test: npm run build
6. Manual testing: Memory Books functionality

### Phase 8: useMemoryBooks Composable (OPTIONAL)

**Priority:** MEDIUM  
**Impact:** ~200-300 lines from ChatView  
**Complexity:** MEDIUM (reactive state management)

**Steps:**
1. Create `src/composables/chat/useMemoryBooks.js`
2. Move reactive state (refs, computed)
3. Move UI handlers
4. Return from composable: `{ state, handlers }`
5. Import and use in ChatView
6. Test: npm run build

### Phase 9: Context Service (OPTIONAL, LOW PRIORITY)

**Priority:** LOW  
**Impact:** ~200-300 lines  
**Complexity:** LOW

---

## Estimated Final State

**After all extractions:**

```
src/views/ChatView.vue                    ~5200 строк (-1587 от текущих 6787)
src/core/services/memoryBooksService.js   ~900 строк (новый)
src/composables/chat/useMemoryBooks.js    ~250 строк (новый, опционально)
src/core/services/contextService.js       ~250 строк (новый, опционально)
```

**Total code organization improvement:**
- ChatView.vue focus: UI orchestration, message rendering, chat flow
- Services: Business logic, data transformation, calculations
- Composables: Reactive state + UI interaction patterns
- Sheets: Presentation components

---

## Questions for Discussion

1. **Should we extract Memory Books Service first?** (рекомендую да — самый большой impact)
2. **Do we need composables or keep handlers in ChatView?** (зависит от того, планируем ли переиспользовать)
3. **Should context logic stay in ChatView?** (да, пока небольшой и специфичный для ChatView)
4. **Testing strategy?** (unit tests для services, integration tests для composables)

---

## Decision

Твоё мнение: начинать ли Phase 7 (Memory Books Service extraction) сейчас, или сначала протестировать текущие UI компоненты?
