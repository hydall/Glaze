# Database Rules

Rules for all code that reads from or writes to IndexedDB.

## patchChatData for read-mutate-write

NEVER:
```javascript
const data = await db.getChat(charId);
data.messages.push(newMsg);
await db.saveChat(charId, data);
```

ALWAYS:
```javascript
await patchChatData(charId, draft => {
  draft.messages.push(newMsg);
});
```

`patchChatData` serializes read-mutate-write via `queueDbWrite`. Two concurrent saves WILL corrupt data without it.

Enforced by ESLint rule `glaze/no-read-mutate-write` — flags `getChatData`/`getChat` + `saveChat` in the same scope.

## patchChatDataBatch for multiple mutations

When you need to apply 2+ mutations to the same charId with no async work between them, use `patchChatDataBatch` to do a single IDB read + write:

INSTEAD OF:
```javascript
await db.patchChatData(charId, d => { d.sessions[sid] = msgs; });
await db.patchChatData(charId, d => { d.memoryBooks[sid].updatedAt = Date.now(); });
await db.patchChatData(charId, d => { d.sessionDates[sid] = Date.now(); });
```

PREFER:
```javascript
await db.patchChatDataBatch(charId, [
  d => { d.sessions[sid] = msgs; },
  d => { d.memoryBooks[sid].updatedAt = Date.now(); },
  d => { d.sessionDates[sid] = Date.now(); },
]);
```

One `getChat` → all mutations → one `normalizeChatData` → one `set`. No redundant reads, no gap between patches.

**When NOT to batch:** If you need async work (API call, embedding, image processing) between mutations, keep them as separate `patchChatData` calls. `patchChatDataBatch` callbacks must be synchronous.

## Save before state cleanup

When finalizing a generation, persist data to DB BEFORE clearing reactive state. If you clear state first and the save fails, data is lost.

## Crash recovery buffer

`useSessionPersistence.js` writes a crash buffer to `localStorage` on `visibilitychange`, `pagehide`, and `beforeunload`. On `openChat()`, if crash buffer has more messages than stored session, buffer is restored to IndexedDB.

Key format: `gz_chat_recovery_{charId}_{sessionId}`

## Background persistence throttling

During active generation, stream text is persisted to DB at reduced frequency:
- Web: moderate throttle
- Native / battery-saver: aggressive throttle

This reduces IndexedDB churn while ensuring no data loss on crash.

## Embedding storage

Store: `embeddings`
Schema v8: `{ id, sourceType, sourceId, vectors[], textHash, retrievalHints, updatedAt }`

Legacy support: single `vector` field for pre-v8 entries.
