# Roadmap

Active work and upcoming tasks. Historical items are removed once merged.

## Active Branch

`refactor/async-integrity-and-composables` (from `fix/migrate-getchatdata-savechat-to-patchchatdata`)

## Async Integrity & Composable Decomposition (2026-05-04)

Status: `implementation done`, 9/10 tasks complete

### Completed Tasks

| Task | Description | Testing |
|------|-------------|---------|
| T1 | `AsyncOperationScope` primitive | not tested |
| T2 | generationState backed by AsyncOperationScope | not tested |
| T3 | `patchChatDataBatch` — multi-mutation in one read-mutate-write | not tested |
| T4 | Lifecycle save durability (crash buffer + batch) | not tested |
| T5 | ESLint rule `glaze/no-read-mutate-write` | not tested |
| T7 | useMemorySheetUI → 7 Vue SFCs | not tested |
| T8 | useMemoryBooks split → 3 sub-composables | not tested |
| T9 | useMemoryAutomation split → 2 sub-modules | not tested |
| T10 | useVirtualScroll audit + decomposition → 3 modules | not tested |

### Remaining

| Task | Description | Priority |
|------|-------------|----------|
| T6 | Cloud sync refactor (syncEngine.js 955→5 modules) | lowest |

### Key New Files

- `src/core/utils/asyncOperationScope.js` — AsyncOperationScope primitive
- `src/composables/chat/virtualScrollHeightCache.js` — pure height cache with prefix-sum
- `src/composables/chat/useVirtualScrollNavigation.js` — scroll navigation composable
- `src/composables/chat/useMemoryDraftProgress.js` — draft progress composable
- `src/composables/chat/useMemoryIndexing.js` — vector toggle/reindex composable
- `src/composables/chat/useMemoryCRUD.js` — entry CRUD composable
- `src/composables/chat/useMemoryDraftContext.js` — draft context builder
- `src/composables/chat/useMemoryBatchGeneration.js` — batch generation logic
- `eslint-rules/glaze/no-read-mutate-write.js` — custom ESLint rule

## Bug Investigations (2026-05-03)

Status: `research complete`, implementation `done`

### 1. Inline Image Edit During Generation — DONE

**Implemented**:
- Created `src/core/states/imageGenState.js` — centralized registry for in-flight image generations with `setImageGenState`, `hasImageGenState`, `clearImageGenState`, `abortImageGenForMessage`
- `processMessageImages()` now accepts `context.msgId` and `context.abortSignal`; registers itself in registry; uses guarded `onUpdate` that checks `controller.signal.aborted` and `hasImageGenState(msgId)` before each callback
- `enterEditMode()` calls `abortImageGenForMessage(msg.id)` — cancels any in-flight image gen before editing
- `saveEdit()` calls `abortImageGenForMessage(msg.id)` before starting new `processMessageImages`
- All call sites pass `context.msgId`

**Testing**: not tested

### 2. Background Inline Image Generation — DONE

**Implemented**:
- Fix #4 (ChatView `onUnmounted` no longer aborts generations) allows `processMessageImages` to continue after unmount
- `updateSessionMessage` saves directly to DB (`db.saveChat`), independent of component mount state
- `imageGenState` registry survives unmount — `clearImageGenState` runs in `processMessageImages` finally block, not on unmount
- Background path in `useGenerationCompleteHandler` (line 303) already uses `db.saveChat` directly

**Testing**: not tested

### 3. Database Crash After RegexSheet Operations — DONE

**Implemented**:
- `regexService.js:trimOut` — changed from `new RegExp(token, 'g')` to `replaceAll(token, '')` (string replacement, no regex crash)
- `syncEngine.js` — added ID-based merge for `regex_scripts` key (preserves local-only scripts on cloud sync)
- `RegexSheet.vue` — subscribes to `regexScriptsChanged` event, reloads `scripts.value` on external changes; uses collision-resistant IDs (`Date.now().toString(36) + Math.random().toString(36).slice(2)`)
- `DragDropOverlay.vue` — fixed `trimStrings.join('\\n')` → `trimStrings.join('\n')` (double-escape bug)
- `tavoBackupReader.js` — fixed `substituteRegex` → `macroRules` field name

**Testing**: not tested

### 4. Streaming Lost When Leaving ChatView — DONE

**Implemented**:
- `ChatView.onUnmounted` — no longer calls `state.controller.abort()` or `clearGenerationState()` for active generations; instead sets `state.onUIUpdate = null` to route stream updates through background DB path
- Generations continue in background after navigating away; completion handler finds state in registry
- Explicit user abort (stop button) still works via `useGenerationAbort` with proper `userAborted` flag
- Timer/stream cleanup still runs (timerId, streamFlush, clearGenerationTimer) to prevent leaks

**Testing**: not tested

## Ghost Generation Bug (2026-05-03)

Status: `research complete`, implementation `done`

**Scenario**: User sends message → app goes to background ~7 min → returns to 500+ second counter → stops/exits → chat disappears

### Root Cause

`restoreGenerationState` used `getChatData` + `saveChat` (not `patchChatData`). Between the async `getChatData` yield and the `saveChat`, `closeChat()` could run and set `currentMessages.value = []`. The stale reference `data.sessions[sessionId] = currentMessages.value` then wrote an empty array to DB, erasing all messages.

### Bugs Fixed

**BUG 1 (CRITICAL) — `restoreGenerationState` race with `closeChat`** (`useGenerationStateRestore.js:78-83`):
- Replaced `getChatData` + `saveChat` with `patchChatData` + snapshot before await
- Both branches (message found in `currentMessages`, message not found) now use `patchChatData`
- Removed `getChatData` dependency entirely

**BUG 2 (MODERATE) — `abortActiveChatGeneration` doesn't clear generation state** (`useGenerationAbort.js`):
- Added `clearGenerationState(charId, state.genId)` and `publishAppEvent(generation.ended)` to abort path
- Prevents ghost generation state from blocking future generations when SSE `onError` never fires (dead HTTP connection)

**BUG 3 (MODERATE) — `updateSessionMessage` lost-update** (`ChatView.vue:588-595`):
- Replaced `getChatData` + `saveChat` with `patchChatData` + message snapshot
- Prevents concurrent writes from overwriting each other

**BUG 4 (MINOR) — `appStateChange` missing crash buffer** (`ChatView.vue:1414`):
- Added `onNativeBackground()` call that writes crash buffer before `patchChatData`
- Mirrors `visibilitychange` handler behavior for native platform

**Testing**: not tested

## Streaming + Chat Switch Bugs (2026-05-03)

Status: `research complete`, implementation `done`

**Bug A**: During streaming, half the message "disappears" visually, reappears when generation finishes.

**Bug B**: After switching chats during generation and returning, UI shows generation done but half the message is missing. Tapping message shows "Stop generation" instead of "Edit".

### Root Cause

When switching chats within ChatView (not unmounting), `state.onUIUpdate` was NOT set to `null`. The streaming `onUpdate` path checked `state?.onUIUpdate` → truthy → took the "visible path" → called `onUIUpdate` → but message wasn't in `currentMessages` (different chat) → updates silently dropped. The background DB-save path was never entered, so DB retained stale partial text.

On return, `openChat` reconnected `onUIUpdate` with delta mode (`m.text += textDelta`) on a stale base text → garbled display. Generation completion overwrites with full correct text → "reappears".

For Bug B: race between `handleGenerationComplete` clearing `generationState` (sync) and `openChat` loading from DB (async). `isTyping = true` persists without generation state → "Stop generation" button → **clicking it deleted the message entirely**.

### Fixes

**1. Disconnect `onUIUpdate` on chat switch** (`ChatView.vue` `openChat`):
- Before `asyncSaveCurrentSessionState`, iterate all generating chars, set `state.onUIUpdate = null`, flush timers
- Forces streaming `onUpdate` into the background path → DB saves work correctly

**2. Reconnected `onUIUpdate` uses full text always** (`ChatView.vue` line 999):
- Changed `if (textDelta) m.text += textDelta` to always `m.text = text`
- Prevents delta-on-stale-base garbling

**3. `onGenerationEnded` cleans phantom `isTyping`** (`ChatView.vue` line 1284):
- Added `findLastIndex(m => m.isTyping)` + `m.isTyping = false` when no generation state exists
- Prevents "Stop generation" button on completed-but-stale messages

**4. `openMessageActions` safe phantom typing handling** (`useMessageActions.js` line 205):
- Changed `currentMessages.value.splice(index, 1)` (DELETE) to `msg.isTyping = false` (PRESERVE)
- Prevents catastrophic data loss when user clicks "Stop generation" on a phantom typing message

**Testing**: not tested

## Sync Setup Guide — For Developers

### Maintainer Goal

- **Status:** done
- **Testing:** not tested
- After merge, the maintainer should only need to add OAuth app keys to `.env`.
- End users still authenticate into their **own** Dropbox or Google Drive accounts. Glaze does not sync everyone into one shared maintainer-owned cloud.
- Provider buttons are only shown when the corresponding OAuth env key is present in the build.

### Shortest Setup Path

1. Copy `.env.example` to `.env` if needed.
2. Add `VITE_DROPBOX_APP_KEY=...`.
3. Register the Dropbox redirect URIs listed below.
4. Build and ship.

That is the shortest maintainer path. Google Drive remains available, but it needs its own OAuth client configuration and is not required for cloud sync to work.

### Platform Status

- **Windows (Electron):** done / not tested
- **Linux (Electron):** done / not tested
- **Android (Capacitor):** done / not tested
- **iPhone (Capacitor iOS):** done / not tested

Meaning: the repo now contains callback plumbing for desktop loopback OAuth and mobile deep-link OAuth, but provider sign-in still needs manual verification against real Dropbox / Google OAuth apps.

### How Cloud Sync Works

Glaze syncs data to cloud storage (Dropbox or Google Drive) using an incremental manifest-based approach:
1. **Manifest** (`manifest.json`) tracks every entity with `{type, id, path, updatedAt, hash, deleted}`
2. **Push**: Compare local manifest vs cloud manifest → upload only changed entities
3. **Pull**: Compare cloud manifest vs local manifest → download only newer entities
4. **Conflicts**: If local is newer AND cloud is newer → surface conflict for manual resolution

### Auth Model

1. Maintainer configures the app-level OAuth client IDs/keys in `.env`.
2. User taps a provider in the Sync sheet.
3. The provider OAuth flow returns tokens for **that specific user account**.
4. Tokens are stored locally on the device.
5. Sync uploads into that user's own cloud storage under `/Glaze`.

This means maintainer credentials only identify the Glaze OAuth app. They do not decide where user data is stored.

### Platform Setup

#### 1. Dropbox

**Create a Dropbox App:**
1. Go to https://www.dropbox.com/developers/apps
2. Click "Create app" → choose "Scoped access" → "Full Dropbox" (or "App folder" if preferred)
3. Note your **App key**

**Configure OAuth redirect URIs:**
- In the Dropbox App Console → Settings → OAuth 2 → Redirect URIs
- Add ALL redirect URIs you will use:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/dropbox`
  - **Web (production)**: `https://yourdomain.com/oauth/dropbox/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/dropbox/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_DROPBOX_APP_KEY=your_app_key_here
# Optional overrides (defaults shown):
# VITE_DROPBOX_REDIRECT_NATIVE=com.hydall.glaze://oauth/dropbox
# VITE_DROPBOX_REDIRECT_WEB=https://yourdomain.com/oauth/dropbox/redirect.html
```

**Android/iOS config:**
- Ensure `capacitor.config.json` has `"appId": "com.hydall.glaze"` (must match redirect URI scheme)
- For Android: `android/app/src/main/AndroidManifest.xml` now contains a `VIEW` / `BROWSABLE` intent-filter for `com.hydall.glaze://`
- For iOS: `ios/App/App/Info.plist` now registers `CFBundleURLTypes` for `com.hydall.glaze`, and `ios/App/App/AppDelegate.swift` forwards the callback to Capacitor

#### 2. Google Drive

**Create a Google Cloud project:**
1. Go to https://console.cloud.google.com
2. Create a project → Enable Google Drive API
3. Go to "Credentials" → "Create OAuth client ID" → "Web application"
4. Note your **Client ID**

**Configure redirect URIs:**
- In Google Cloud Console → Credentials → your OAuth client → "Authorized redirect URIs"
- Add ALL redirect URIs:
  - **Native (Android/iOS)**: `com.hydall.glaze://oauth/gdrive`
  - **Web (production)**: `https://yourdomain.com/oauth/gdrive/redirect.html`
  - **Web (dev)**: `http://localhost:5173/oauth/gdrive/redirect.html`
  - **Electron (desktop)**: `http://127.0.0.1:PORT/oauth/callback` (loopback)

**Environment variables (`.env`):**
```
VITE_GDRIVE_CLIENT_ID=your_client_id_here
# Optional overrides:
# VITE_GDRIVE_REDIRECT_NATIVE=com.hydall.glaze://oauth/gdrive
# VITE_GDRIVE_REDIRECT_WEB=https://yourdomain.com/oauth/gdrive/redirect.html
```

Glaze uses OAuth PKCE in the client, so `VITE_GDRIVE_CLIENT_SECRET` is intentionally not used.

### Error 400 Troubleshooting

**Error 400 on OAuth token exchange** = `redirect_uri` mismatch.

The `redirect_uri` sent in the OAuth authorize request must **exactly match** the `redirect_uri` sent in the token exchange request AND must be registered in the provider's OAuth console.

Common causes:
1. **Hardcoded localhost in production**: Old code used `http://localhost:5173/...` — this only works in dev. Fixed: now uses `window.location.origin` as default.
2. **Missing redirect URI in OAuth console**: The URI you deploy with must be added to the app's redirect URI list in Dropbox/Google console.
3. **Platform mismatch**: Native builds use `com.hydall.glaze://...` scheme. Web builds use `https://...`. Each platform needs its own redirect URI registered.
4. **Port mismatch for Electron**: Electron uses loopback `http://127.0.0.1:PORT/oauth/callback` with a random port. The OAuth provider must allow loopback redirects (Google does by default for "Desktop app" client type; Dropbox requires adding it explicitly).

### Error 401/403 Troubleshooting

- **401**: Access token expired → auto-refresh via `refresh_token`. If refresh also fails → user must reconnect.
- **403**: App permissions revoked or API quota exceeded. User must reconnect.

### Encryption (Optional)

Encryption uses AES-256-GCM via Web Crypto API, key derived from a 12-word BIP39 mnemonic.
- **Without encryption**: Data stored as plain JSON in cloud. Simple, portable, debuggable.
- **With encryption**: Each entity encrypted before upload. Recovery phrase required to decrypt on other devices.
- **Migration**: If cloud has `.enc` files and encryption is disabled, the system attempts to read both `.enc` and `.json` variants.
- **Key files**: `src/core/services/crypto/syncCrypto.js` (AES-GCM), `src/core/services/crypto/keyManager.js` (BIP39, storage)
