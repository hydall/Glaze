# Glaze Architecture

Mobile-first LLM frontend for AI roleplay. SillyTavern alternative as a native mobile app.
**Stack:** Vue 3.5 + Vite 7 + Capacitor 8 (iOS/Android). **Language:** JavaScript only.

---

## High-Level Overview

```
User Input (ChatView)
    |
    v
generationService.generateChatResponse()
    |
    v
[Web Worker] generationWorker.buildPromptMessagesWorker()
    |-- Load preset blocks (system, persona, char_card, scenario, etc.)
    |-- Scan lorebooks (keyword matching in history)
    |-- Expand macros ({{char}}, {{user}}, {{random}}, etc.)
    |-- Apply regex scripts
    |-- Count tokens, calculate history cutoff
    |
    v
[Return messages array]
    |
    v
llmApi.executeRequest()
    |-- fetch() with SSE streaming (or CapacitorHttp for non-streaming native)
    |-- Parse SSE chunks, extract reasoning (inner/outer CoT)
    |-- onUpdate() callbacks -> ChatView renders in real-time
    |
    v
onComplete() -> Save to IndexedDB
```

---

## File Structure

```
src/
+-- App.vue                          # Root: view routing, global events, initialization
+-- main.js                          # Vite entry point
+-- core/
|   +-- config/
|   |   +-- APISettings.js          # API endpoint/key/model config (localStorage)
|   |   +-- APPSettings.js          # App preferences (lang, theme mode, toggles)
|   +-- services/
|   |   +-- generationService.js    # Prompt building orchestration
|   |   +-- llmApi.js               # HTTP requests + SSE streaming
|   |   +-- imageGenService.js      # Image generation (OpenAI/Gemini/Naistera endpoints)
|   |   +-- notificationService.js  # Push notifications (Capacitor)
|   |   +-- regexService.js         # Regex transformation engine
|   |   +-- statsService.js         # Message/generation analytics
|   |   +-- ui.js                   # UI init helpers (ripple, theme toggle, etc.)
|   |   +-- timeTracker.js          # Session time tracking
|   |   +-- keyboardHandler.js      # Capacitor keyboard management (reactive state)
|   |   +-- chatImporter.js         # Chat file import
|   |   +-- fileSaver.js            # File export
|   |   +-- presetImportService.js  # Preset import
|   |   +-- backupService.js        # Full backup export/import (ZIP via JSZip)
|   |   +-- stBackupImporter.js     # SillyTavern backup ZIP import
|   +-- states/
|       +-- bottomSheetState.js     # Global bottom sheet (notifications, menus, errors)
|       +-- lorebookState.js        # Lorebook scanning and activation
|       +-- notificationsState.js   # In-app notification center (localStorage)
|       +-- personaState.js         # User personas (CRUD, connections, effective persona)
|       +-- presetState.js          # Prompt presets (blocks, connections, effective preset)
|       +-- themeState.js           # Visual themes (colors, fonts, backgrounds, ~1100 LOC)
|       +-- toastState.js           # Custom in-app toast system
|       +-- defaultPresets.js       # Built-in preset definitions
+-- utils/
|   +-- db.js                       # IndexedDB wrapper (SillyCradleDB)
|   +-- macroEngine.js              # Macro substitution (main thread version)
|   +-- tokenizer.js                # Token counting (GPTTokenizer / heuristic fallback)
|   +-- textFormatter.js            # Message rendering (markdown, quotes, code blocks)
|   +-- i18n.js                     # Internationalization (en, ru)
|   +-- sessions.js                 # Chat session management
|   +-- characterIO.js              # Character import/export (SillyTavern V2 format)
|   +-- dateFormatter.js            # Date/time display
|   +-- errorHandler.js             # Error display
|   +-- errors.js                   # Error formatting (JSON extraction from API responses)
|   +-- logger.js                   # Dev-only logger (debug/info suppressed in prod)
|   +-- tavoBackupReader.js         # Pure-JS LMDB reader for Isar-based Tavo backups
+-- views/
|   +-- ChatView.vue                # Main chat interface
|   +-- CharacterList.vue           # Character browser
|   +-- DialogList.vue              # Active chat sessions
|   +-- PresetView.vue              # Preset editor/selector
|   +-- ApiView.vue                 # API configuration UI
|   +-- OnboardingView.vue          # First-run tutorial
|   +-- PersonasView.vue            # Persona management
|   +-- Menu/
|       +-- MenuView.vue            # Main menu
|       +-- AboutView.vue           # About page
|       +-- Settings/
|           +-- SettingsView.vue    # App settings (lang, toggles, display options)
|           +-- ThemeSettingsView.vue # Theme customization (full theme engine UI)
+-- components/
|   +-- chat/
|   |   +-- ChatMessage.vue         # Message bubble (edit, delete, regenerate, copy)
|   |   +-- ChatInput.vue           # Text input + persona selector
|   |   +-- MagicDrawer.vue         # Side panel for quick actions
|   +-- layout/
|   |   +-- AppHeader.vue           # Top bar (title, controls, search)
|   |   +-- BottomNavigation.vue    # Tab bar (dialogs, characters, menu)
|   |   +-- AppLoader.vue           # Loading spinner
|   +-- ui/
|   |   +-- BottomSheet.vue         # Global modal/notification system
|   |   +-- FabButton.vue           # Floating action button
|   |   +-- SheetView.vue           # Sheet base component
|   |   +-- RollingNumber.vue       # Animated counter
|   |   +-- AppToast.vue            # Custom in-app toast
|   |   +-- HelpTip.vue             # Clickable help tip -> opens glossary
|   |   +-- ShadowContent.vue       # Shadow DOM content renderer (style isolation)
|   +-- sheets/
|   |   +-- CharacterCardSheet.vue  # Character detail viewer
|   |   +-- LorebookSheet.vue       # Lorebook editor
|   |   +-- RegexSheet.vue          # Regex script editor
|   |   +-- StatsSheet.vue          # Chat statistics
|   |   +-- ConnectionsSheet.vue    # Preset/persona/lorebook mappings
|   |   +-- RequestPreviewSheet.vue # Final prompt preview
|   |   +-- BackupSheet.vue         # Backup export/import (Glaze, ST, Tavo)
|   |   +-- ImageGenSheet.vue       # Image generation settings
|   |   +-- GlossarySheet.vue       # In-app glossary of terms
|   |   +-- NotificationsSheet.vue  # Notification center
|   |   +-- ColorPickerSheet.vue    # Color picker for themes
|   +-- editors/
|   |   +-- GenericEditor.vue       # Dynamic form editor
|   |   +-- FullScreenEditor.vue    # Large text editor
|   +-- media/
|       +-- ImageViewer.vue         # Image popup
|       +-- HoloCardViewer.vue      # Card renderer
+-- composables/
|   +-- chat/useVirtualScroll.js    # Efficient list rendering for chat messages
|   +-- media/useViewer.js          # Image/card viewer composable
+-- workers/
|   +-- generationWorker.js         # Off-thread prompt building
+-- tokenizers/
|   +-- gp-tokenizer-*.js           # GPT tokenizer (cl100k_base, minified)
+-- locales/
|   +-- en/
|   |   +-- index.json              # English UI strings
|   |   +-- glossary.json           # English glossary entries
|   +-- ru/
|       +-- index.json              # Russian UI strings
|       +-- glossary.json           # Russian glossary entries
+-- assets/
    +-- css/                        # Global styles
```

---

## 1. Navigation

No Vue Router. Navigation is CustomEvent-based with a `currentView` ref in App.vue.

```js
// Navigate:
window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-chat' }));

// App.vue listens:
window.addEventListener('navigate-to', (e) => { currentView.value = e.detail; });

// Template switches via v-if on currentView
```

**Navigation events:**

| Event | Purpose |
|---|---|
| `navigate-to` | Generic view switch (detail = view id) |
| `open-chat` | Open chat with character (detail = { char, sessionId?, msgId? }) |
| `open-character-editor` | Open character editor |
| `open-persona-editor` | Open persona editor |
| `open-item-editor` | Open preset/lorebook/persona editor |
| `open-connections` | Show connection mappings sheet |
| `open-fs-request` | Open full-screen text editor |
| `open-lorebook-entry` | Jump to lorebook entry in ChatView |
| `open-glossary` | Open glossary sheet (detail = { term? }) |
| `open-backup-sheet` | Open backup export/import sheet |
| `open-notifications-sheet` | Open notification center |
| `open-holocards` | Open holocard viewer |
| `open-image-viewer` | Open image viewer |
| `open-onboarding` | Open onboarding tutorial |

**Header events:**

| Event | Purpose |
|---|---|
| `header-setup-editor` | Signal editor mode to AppHeader |
| `header-setup-chat` | Signal chat mode to AppHeader |
| `header-setup-submenu` | Signal submenu mode to AppHeader |
| `header-view-changed` | Notify header of view change |
| `header-force-update` | Force header re-render |
| `header-reset` | Reset header to default state |
| `header-scroll-hidden` | Toggle header visibility on scroll |
| `header-update-avatar` | Update avatar in header |
| `header-chat-search` / `header-chat-search-toggle` | Chat search controls |
| `header-show-lb-banner` | Show lorebook activation banner |

**Data events:**

| Event | Purpose |
|---|---|
| `character-updated` | Character data changed |
| `chat-updated` | Chat data changed |
| `chat-generation-started` / `chat-generation-ended` | Generation lifecycle |
| `regex-scripts-changed` | Regex scripts modified |
| `settings-changed` | App settings changed |
| `language-changed` | Language switched |
| `fs-editor-closed` | Full-screen editor closed |

**Imperative component access** via template refs:
```js
const chatViewRef = ref(null);
// Used for: chatViewRef.value.openChat(char)
```

---

## 2. State Management

No Pinia/Vuex. Custom reactive modules in `src/core/states/`. Each exports `ref()`/`reactive()`/`computed()` values and mutation functions, imported directly where needed.

### bottomSheetState.js

Global bottom sheet for notifications, menus, error dialogs, and form inputs.

```js
// Exports:
bottomSheetState   // ref: { visible, title, content, items, bigInfo, input, sessionItems, ... }
showBottomSheet()  // Show with config object
closeBottomSheet() // Hide (also hides keyboard on iOS)
```

### lorebookState.js

Lorebook (world info) scanning and management.

```js
// Exports:
lorebookState       // reactive: { lorebooks, globalSettings, activations, initialized }
initLorebookState() // Load from IndexedDB
saveLorebooks()     // Persist to IndexedDB
scanLorebooks()     // Recursive keyword matching against chat history

// Lorebook entry structure:
{ id, keys, content, enabled, position, secondaryKeys, probability, cooldown, ... }

// Activation scopes: global, per-character, per-chat
// Positions: 0=before char_card, 1=after char_card, 2=before examples, 3=after examples, 4=very beginning
```

### personaState.js

User personas with connection system.

```js
// Exports:
personas            // ref: array of { id, name, prompt, avatar }
activePersona       // computed: current global persona
personaConnections  // reactive: { character: {charId: personaId}, chat: {chatId: personaId} }
getEffectivePersona(charId, chatId) // Priority: chat > character > global
loadPersonas(), addPersona(), updatePersona(), deletePersona()
```

### presetState.js

Block-based prompt presets with connection system.

```js
// Exports:
presetState          // reactive: { presets, connections, globalPresetId, initialized }
getEffectivePreset() // Priority: chat > character > global
initPresetState(), savePresets()

// Preset block types (ordered in template):
// sys1 (system prompt), user_persona, char_card, scenario,
// example_dialogue, summary, authors_note, chat_history
// Each block: { id, name, role, content, enabled, insertion_mode, depth }
```

### themeState.js

Visual theme management with 60+ properties (~1100 LOC).

```js
// Exports:
themeState           // reactive: colors, opacities, fonts, blur, noise, borders, layout
initTheme()          // Load from IndexedDB
setAccentColor()     // Change accent
applyPreset(preset)  // Apply full theme preset
setBackgroundImage() // Store as data URI in IndexedDB
setCustomFont()      // Store as data URI in IndexedDB
updateThemeStyles()  // Inject CSS variables into DOM

// Extended styling (per-bubble colors, fonts, layout):
setUserBubbleColor(), setCharBubbleColor()
setUserQuoteColor(), setCharQuoteColor()
setUserTextColor(), setCharTextColor()
setUserItalicColor(), setCharItalicColor()
setUiFontSize(), setUiLetterSpacing()
setChatFontSize(), setChatLetterSpacing(), setChatFont()
setChatLayout()      // Chat layout mode
setBorderWidth(), setBorderColor(), setBorderOpacity()
setNoiseOpacity(), setNoiseIntensity()
setBgNoiseOpacity(), setBgNoiseIntensity()

// Theme presets CRUD:
createPreset(), getPresets(), deletePreset(), switchPreset(), updatePresetMeta()
exportThemePreset(), importThemePreset()
```

### notificationsState.js

In-app notification center.

```js
// Exports:
notificationsState   // reactive: { items, unreadCount }
// Storage: gz_notifications in localStorage, max 20 items
```

### toastState.js

Custom in-app toast (replaces native Capacitor Toast for consistent styling).

```js
// Exports:
showToast(text, duration?)  // Show toast with auto-dismiss (default 2500ms)
toastState                  // reactive: { visible, text, duration }
```

---

## 3. Services

Functional modules (exported async functions, no classes) in `src/core/services/`.

### generationService.js — Orchestration

Entry point for all LLM generation.

```js
generateChatResponse({
    char, history, summary, sessionId, authorsNote,
    apiConfig, lorebooks, globalRegexes,
    onUpdate, onComplete, onError, abortSignal
})
```

**Flow:**
1. Load effective preset and persona for character/session
2. Build payload (deep clone to avoid proxy issues)
3. Send to Web Worker via `processPromptAsync()`
4. Receive back: `{ messages, loreEntries, cutoffIndex, staticTokens }`
5. Construct OpenAI-compatible request body
6. Call `llmApi.executeRequest()`
7. Handle streaming callbacks and completion

**Reasoning support:**
- OpenRouter: `include_reasoning: true` in body
- Google Gemini: `extra_body.google.thinking_config`
- Generic: reasoning tags from preset (e.g., `<think>`/`</think>`)

### llmApi.js — HTTP + Streaming

```js
executeRequest({
    requestBody, apiConfig,
    onUpdate, onComplete, onError, abortSignal
})
```

**Dual HTTP paths:**
- **Web / streaming**: `fetch()` with `ReadableStream` for SSE
- **Native non-streaming**: `CapacitorHttp.post()`

**SSE streaming loop:**
- Parses `data: {json}` lines from event stream
- Extracts `delta.content` (text) and `delta.reasoning_content` (outer CoT)
- Detects inner CoT via configurable tags (e.g., `<think>...</think>`)
- Fires `onUpdate()` with: `{ content, reasoning, effectiveText, effectiveReasoning, textDelta }`
- On complete: `onComplete(finalText, reasoningText)`
- On interruption: saves partial text with error footer

**Platform features:**
- Wake lock (`navigator.wakeLock`) to keep screen on
- iOS: `BackgroundTask.beforeExit()` for background generation
- Android: notification-based background task

### regexService.js — Text Transformations

```js
applyRegexes(text, placement, scripts, options)
// placement: 1=user input, 2=AI output, 4=system blocks
// ephemerality: 2=display-only (doesn't alter prompt)
```

### notificationService.js — Push Notifications

Capacitor-based notifications for message events and background generation.

### imageGenService.js — Image Generation

Parses `[IMG:GEN:{...}]` and `<img data-iig-instruction>` tags in AI messages and generates images via configured API.

```js
// Settings stored in localStorage (gz_imggen_* keys):
// enabled, apiType, endpoint, apiKey, model, size, quality

// Supported backends:
// - OpenAI-compatible (/images/generations)
// - Gemini-compatible
// - Naistera
```

### keyboardHandler.js — Keyboard Management

Extracted keyboard handling with reactive state. Manages Capacitor `Keyboard` plugin, resize mode, scroll resets.

```js
// Exports:
isKeyboardOpen       // ref: boolean
isNativeKeyboard     // ref: boolean
keyboardOverlap      // ref: number (px)
initKeyboard()       // Setup listeners and resize mode
```

### backupService.js / stBackupImporter.js — Backup System

Full backup export/import via JSZip. Exports all IndexedDB stores + localStorage into a ZIP. Imports merge data back.

```js
exportFullBackupAsync()                    // -> ZIP blob (characters, chats, lorebooks, presets, personas, settings)
importFullBackupAsync(zipFile, onProgress) // Merge Glaze backup into current DB
importSTBackupFromZip(zipFile, onProgress) // Import SillyTavern backup ZIP
importTavoBackupFromZip(zipFile, onProgress) // Import Tavo backup (LMDB/Isar)
```

---

## 4. Config System

### APISettings.js

```js
initSettings()           // Set localStorage defaults
normalizeEndpoint(url)   // Ensure https://, strip /chat/completions
getApiConfig()           // Merge defaults + localStorage overrides
fetchRemoteModels()      // GET /models from endpoint (CapacitorHttp on native)
```

**Storage keys:** `api-endpoint`, `api-key`, `api-model`, `api-temperature`, `api-top-p`,
`api-max-tokens`, `api-context-size`, `api-stream`, `gz_api_presets` (IndexedDB)

### APPSettings.js

Module-level ref exports with setter functions:

```js
currentLang, themeMode, imageViewerMode, disableSwipeRegeneration,
hideMessageId, hideGenerationTime, hideTokenCount,
enterToSubmit, hideHelpTips, dialogGrouping, ...

setLanguage(), setThemeMode(), setImageViewerMode(),
setDisableSwipeRegeneration(), setHideMessageId(),
setHideGenerationTime(), setHideTokenCount(),
setEnterToSubmit(), setHideHelpTips(), setDialogGrouping(), ...
```

**Storage:** `gz_lang`, `gz_theme`, `gz_image_viewer`, `gz_disable_swipe_regeneration`,
`gz_hide_msg_id`, `gz_hide_gen_time`, `gz_hide_token_count`,
`gz_enter_to_submit`, `gz_hide_help_tips`, `gz_dialog_grouping` in localStorage.

---

## 5. Storage

### IndexedDB — `SillyCradleDB` (version 5)

| Store | KeyPath | Contents |
|---|---|---|
| `keyvalue` | key | Settings, chats, lorebooks, themes |
| `characters` | id | Character cards (SillyTavern V2) |
| `personas` | id | User personas |

**Key patterns in keyvalue store:**

| Key | Data |
|---|---|
| `gz_chat_{charId}` | `{ sessions: {id: [msgs]}, currentId, authorsNotes }` |
| `gz_lorebooks` | Full lorebook collection with activations |
| `gz_theme_presets` | Theme preset array |
| `gz_theme_bg` | Background image (data URI) |
| `gz_theme_font` | Custom font (data URI) |

**DB queue pattern** (prevents race conditions):
```js
let dbQueue = Promise.resolve();
function queueDbOp(op) {
    dbQueue = dbQueue.then(op);
    return dbQueue;
}
```

### localStorage

| Key Pattern | Data |
|---|---|
| `api-*` | API config (endpoint, key, model, etc.) |
| `gz_*` | App settings (lang, theme mode, toggles, etc.) |
| `gz_vars_{charId}_{sessionId}` | Session macro variables |
| `gz_notifications` | In-app notification items (max 20) |
| `gz_imggen_*` | Image generation config (enabled, apiType, endpoint, apiKey, model, size, quality) |
| `gz_keyboard_height` | Saved keyboard height for drawer |
| `silly_cradle_presets` | Prompt presets |
| `regex_scripts` | Regex transformation scripts |
| `gz_persona_connections` | Persona-to-char/chat mappings |
| `gz_preset_connections` | Preset-to-char/chat mappings |

---

## 6. Prompt Building Pipeline (Web Worker)

`src/workers/generationWorker.js` runs in a separate thread.

**Communication:**
```js
// Main thread -> Worker:
worker.postMessage({ id, type: 'generateChatResponse', payload });

// Worker -> Main thread:
postMessage({ id, success: true, data: { messages, loreEntries, cutoffIndex, staticTokens } });
```

**Pipeline steps:**

1. **Lorebook scan** — `scanLorebooksPure()`: match keywords in history, handle recursion/probability/cooldowns
2. **Block resolution** — for each preset block: fill content from char/persona fields, expand macros, apply regexes
3. **Block merging** — if `mergePrompts` enabled, combine consecutive same-role blocks
4. **History processing** — for each message: expand macros, apply regexes
5. **Depth insertion** — insert depth-based blocks (summary, author's note) at configured message depth
6. **Lorebook injection** — insert activated entries at their configured position (0-4)
7. **Token counting** — count static prompt tokens, calculate available budget for history
8. **History cutoff** — keep messages from end backwards until budget exhausted

**Macro engine** (runs in worker and main thread):

| Macro | Description |
|---|---|
| `{{char}}` | Character name |
| `{{user}}` | User/persona name |
| `{{description}}` | Character description |
| `{{personality}}` | Character personality |
| `{{scenario}}` | Scenario text |
| `{{persona}}` | User persona prompt |
| `{{mesExamples}}` | Example dialogue |
| `{{random::a::b::c}}` | Random choice |
| `{{roll::1d20}}` | Dice roll |
| `{{setvar::name::val}}` | Set session variable |
| `{{getvar::name}}` | Get session variable |
| `{{pick::a::b::c}}` | Sequential pick |

---

## 7. API Integration

**Format:** OpenAI-compatible `/chat/completions`

**Request structure:**
```json
{
    "model": "claude-sonnet-4-20250514",
    "messages": [
        { "role": "system", "content": "..." },
        { "role": "user", "content": "..." },
        { "role": "assistant", "content": "..." }
    ],
    "temperature": 0.7,
    "top_p": 0.9,
    "max_tokens": 8000,
    "stream": true
}
```

**Compatible backends:** OpenAI, OpenRouter, Ollama, LM Studio, any OpenAI-compatible endpoint.

**Streaming:** SSE (Server-Sent Events) over fetch ReadableStream. No WebSocket.

**Message sanitization:** Only `role`, `content`, `name` fields sent to API (strips internal metadata).

---

## 8. UI Architecture

### View hierarchy (lazy-loaded with defineAsyncComponent)

```
App.vue (currentView routing)
+-- DialogList.vue        — active chat sessions list
+-- CharacterList.vue     — character browser/search
+-- ChatView.vue          — main chat (messages, input, sheets)
|   +-- ChatMessage.vue   — message bubble
|   +-- ChatInput.vue     — text input
|   +-- MagicDrawer.vue   — side panel
|   +-- [Sheet components] — context-specific modals
+-- PresetView.vue        — preset editor
+-- ApiView.vue           — API configuration
+-- PersonasView.vue      — persona management
+-- OnboardingView.vue    — first-run tutorial
+-- Menu/
    +-- MenuView.vue      — main menu
    +-- AboutView.vue     — about page
    +-- Settings/
        +-- SettingsView.vue      — app settings (lang, toggles, display)
        +-- ThemeSettingsView.vue  — theme customization (full engine UI)
```

### Sheet components

Dedicated full-screen sheets opened via CustomEvents or template refs:

| Sheet | Trigger Event | Purpose |
|---|---|---|
| CharacterCardSheet | via ref | Character detail viewer |
| LorebookSheet | via ref | Lorebook editor |
| RegexSheet | via ref | Regex script editor |
| StatsSheet | via ref | Chat statistics |
| ConnectionsSheet | `open-connections` | Preset/persona/lorebook mappings |
| RequestPreviewSheet | via ref | Final prompt preview |
| BackupSheet | `open-backup-sheet` | Backup export/import |
| ImageGenSheet | via ref | Image generation settings |
| GlossarySheet | `open-glossary` | In-app glossary |
| NotificationsSheet | `open-notifications-sheet` | Notification center |
| ColorPickerSheet | via prop | Color picker (used in ThemeSettingsView) |

### Bottom Sheet system

Global modal used for confirmations, menus, errors, forms:
```js
showBottomSheet({
    title: 'Error',
    bigInfo: 'Connection failed',
    items: [{ text: 'Retry', action: () => {} }],
    input: { label: 'Enter name', onSubmit: (val) => {} }
});
```

### Toast system

Custom in-app toast via `AppToast.vue` + `toastState.js`:
```js
import { showToast } from '@/core/states/toastState.js';
showToast('Saved!', 2000);
```

### CSS theming

- Scoped `<style>` blocks, no CSS modules or preprocessor
- CSS custom properties for theming (`--header-height`, `--vk-blue`, `--element-opacity`)
- Glass effect: `backdrop-filter: blur()` + `rgba()` backgrounds
- Light/dark via `body.dark-theme` class

---

## 9. Capacitor Plugins & Platform Behavior

**App ID:** `com.hydall.glaze`

### Installed Capacitor plugins

| Plugin | Package | Usage |
|---|---|---|
| App | `@capacitor/app` | Back button handling, app lifecycle |
| Browser | `@capacitor/browser` | Open external links (AboutView, PresetView) |
| Filesystem | `@capacitor/filesystem` | File read/write for exports |
| Haptics | `@capacitor/haptics` | Vibration feedback |
| Keyboard | `@capacitor/keyboard` | Keyboard show/hide events, resize handling |
| Local Notifications | `@capacitor/local-notifications` | Message notifications |
| Share | `@capacitor/share` | Share character/chat data |
| Toast | `@capacitor/toast` | Toast messages |
| CapacitorHttp | `@capacitor/core` (built-in) | Non-streaming HTTP on native (avoids CORS) |
| Background Task | `@capawesome/capacitor-background-task` | iOS background generation |
| Foreground Service | `@capawesome-team/capacitor-android-foreground-service` | Android background generation |
| Background Mode | `@anuradev/capacitor-background-mode` | Keep app alive in background |
| Safe Area | `@capacitor-community/safe-area` | Safe area insets |

### `@capacitor/browser` details

Opens system browser (SFSafariViewController on iOS, Chrome Custom Tabs on Android).
Used via `Browser.open({ url })` in AboutView and PresetView for external links.

**Limitations:** No URL change monitoring, no navigation interception. Cannot be used to intercept OAuth callback URLs. Events: `browserPageLoaded` (no URL info), `browserFinished` (browser closed).

**No InAppBrowser plugin installed.** No community WebView plugin with URL interception capability is present.

### Platform-specific behavior

| Feature | Dev (browser) | iOS (Capacitor) | Android (Capacitor) |
|---|---|---|---|
| HTTP requests | fetch | CapacitorHttp (non-streaming) + fetch (streaming) | Same as iOS |
| Background gen | N/A | BackgroundTask.beforeExit() | Notification-based |
| Wake lock | navigator.wakeLock | Same | Same |
| Keyboard | Standard | WKWebView keyboard workarounds | Standard |
| Tokenizer | GPTTokenizer | Heuristic fallback (avoids stack overflow) | GPTTokenizer |
| History limit | contextSize / 5 | contextSize / 15 (memory safety) | contextSize / 5 |
| Back button | N/A | Capacitor App.addListener('backButton') | Same |

---

## 10. Key Design Patterns

**Reactive state export** — modules export raw refs, imported directly:
```js
// state module
export const items = ref([]);
export function addItem(item) { items.value.push(item); }

// consumer
import { items, addItem } from '@/core/states/myState';
```

**Auto-save with watch:**
```js
watch(() => lorebookState, () => saveLorebooks(), { deep: true });
```

**Worker communication:**
```js
const _workerQueue = new Map(); // id -> { resolve, reject }
function processPromptAsync(payload) {
    return new Promise((resolve, reject) => {
        const id = ++_msgIdCounter;
        _workerQueue.set(id, { resolve, reject });
        worker.postMessage({ id, type: 'generateChatResponse', payload });
    });
}
```

**CustomEvent navigation** (see section 1).

**DB queue** — serializes IndexedDB writes (see section 5).

**Connection priority** — chat > character > global (for presets, personas, lorebooks).

---

## 11. Initialization Sequence (App.vue onMounted)

```
1.  migrateScToGz()              — localStorage key migration (sc_ -> gz_)
2.  initSettings()               — API config defaults
3.  initTheme()                  — Load theme from IndexedDB
4.  Promise.all([
      initLorebookState(),       — Load lorebooks from IndexedDB
      initPresetState(),         — Load presets from localStorage
      loadPersonas()             — Load personas from IndexedDB
    ])
5.  startTracking()              — Time tracking
6.  UI inits (ripple, theme toggle, header dropdown, back button, viewport fix)
7.  Register all CustomEvent listeners
8.  consumePendingNotificationData() — Handle notification-initiated launch
9.  ResizeObserver on header/footer
10. updateLanguage()
11. generateMissingThumbnails()
12. checkAndRequestNotifications()
13. Capacitor keyboard listeners
```

---

## 12. Adding New Features

**New view:**
1. Create `src/views/MyView.vue` (Composition API, `<script setup>`)
2. Add to App.vue as `defineAsyncComponent()` with `v-if="currentView === 'view-my'"`
3. Navigate: `window.dispatchEvent(new CustomEvent('navigate-to', { detail: 'view-my' }))`

**New state module:**
1. Create `src/core/states/myState.js`
2. Export `ref()`/`reactive()` + mutation functions
3. Add init function, call from App.vue `onMounted`

**New service:**
1. Create `src/core/services/myService.js`
2. Export async functions (no classes)
3. Import where needed

**New preset block:**
1. Add to `DEFAULT_PRESETS` in `defaultPresets.js`
2. Handle in `generationWorker.js` block resolution
3. Add UI in `PresetView.vue`

**New API provider:**
1. Adapt request format in `generationService.js` (model-specific fields)
2. Handle auth in `llmApi.js` if non-standard
3. Add UI in `ApiView.vue` for provider-specific config
