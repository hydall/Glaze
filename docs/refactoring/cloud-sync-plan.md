# Cloud Sync Refactor Plan

Branch: `refactor/cloud-sync` (from `refactor/async-integrity-and-composables`)

## Bugs to Fix

### BUG-1: Gallery Duplication on Pull (CRITICAL)

**Root cause**: Gallery image IDs are generated with `Math.random()` (`img_` + random). Same physical image gets different IDs on different devices. Pull only checks ID match (`char.images.findIndex(im => im.id === cloudEntry.imgId)`), not content. So `img_abc123` on device A and `img_xyz789` on device B for the same image → both coexist after sync.

**Fix**: On gallery pull, after checking ID match, also check hash match:
1. Download binary from cloud, compute its hash
2. Scan local `char.images` for any image with matching hash (different ID)
3. If found: update existing entry (replace ID + src), don't push new
4. If not found: push new image entry

Also: during push manifest build, if a local image has no corresponding manifest entry but its hash matches an existing cloud gallery entry, skip re-upload and just update the manifest to reference the existing cloud entry.

**Files**: `syncEngine.js` lines 710-750 (pull), 293-331 (manifest build)

### BUG-2: Gallery Counts as "Characters" in Breakdown

**Root cause**: `getBreakdownBucket()` maps `GALLERY` → `'characters'`. SyncSheet shows "8 characters" when 3 characters + 5 gallery images synced.

**Fix**: Add `'gallery'` bucket. Add gallery line to `formatSyncBreakdown()`.

**Files**: `syncEngine.js` line 503, `SyncSheet.vue` lines 64-72

### BUG-3: Conflict Details Not Visible

**Root cause**: `ConflictSheet.vue` shows type icon + name + truncated fields. No field-level diff, no image preview, no way to see what actually changed.

**Fix**: 
1. For characters: show avatar preview (local vs cloud), field diff (name, description, personality, scenario)
2. For chats: show message count diff, last message preview
3. For personas: show prompt diff
4. Add a "View Details" expandable with full field-by-field comparison
5. For gallery: since gallery has no conflict detection yet, nothing to show

**Files**: `ConflictSheet.vue`, `syncEngine.js` (include more data in conflict objects)

### BUG-4: Gallery Race Condition on Parallel Pull

**Root cause**: `runParallel` (concurrency=3) processes gallery entries for the same character simultaneously. Each reads character from DB → modifies `images` → writes back. Last write wins, losing other image additions.

**Fix**: Serialize gallery writes per character. Group gallery entries by `charId`, process all entries for one character before moving to the next. Within a character, apply all image adds/removes to a single character read, then write once.

**Files**: `syncEngine.js` `pullManifestV2` lines 710-750

### BUG-5: Gallery No Conflict Detection

**Root cause**: The gallery branch in `pullManifestV2` skips `needsConflict()` entirely. Cloud always wins silently.

**Fix**: Add `needsConflict()` check for gallery entries. If local gallery entry is newer (different hash, local updatedAt > cloud updatedAt), create a conflict entry. User can then choose which version to keep.

**Files**: `syncEngine.js` lines 710-750

### BUG-6: getLocalCharacterWithImages Loads ALL Characters

**Root cause**: `getLocalCharacterWithImages` does `db.getAll('characters')` then `find()`. Called once per gallery entry during sync. O(n*m).

**Fix**: Use `db.get('characters', id)` directly. The IDB primary key lookup is O(1).

**Files**: `syncEngine.js` lines 864-875

### BUG-7: Missing else for Gallery Push When Image Not Found

**Root cause**: If image is deleted between manifest build and push, upload is skipped but manifest entry still marks it as non-deleted. Cloud gets stale entry.

**Fix**: If image not found locally during push, mark manifest entry as `deleted: true` before uploading manifest.

**Files**: `syncEngine.js` lines 593-618

---

## GDrive Cross-Device File Issue

**Observed**: On different devices, GDrive refuses to modify files inside the same folder.

**TavernRev approach**: They use file IDs directly — find existing file by name in folder, get its ID, then PATCH update by ID. Same as our current approach.

**Root cause hypothesis**: Our adapter resolves path → file ID on every operation. The `_folderIdCache` could be stale if another device created/modified folders. When cache is stale, `findFileByName` may find the wrong file ID or none.

**Potential fixes**:
1. Cache GDrive file IDs in the manifest (not just paths). On pull/push, use the cached file ID directly instead of re-resolving by name.
2. Add retry with cache invalidation on 404/403 (already partially done for download — extend to upload).
3. Store file IDs per manifest entry in a local mapping (`gz_sync_gdrive_file_ids`) so cross-device operations don't rely on name resolution.

**Files**: `gdriveAdapter.js`, `syncEngine.js` manifest structure

---

## Refactor Plan: syncEngine.js Decomposition

Current: 955 lines mixing orchestration, serialization, manifest logic, conflict detection, and entity-specific handling.

### Target Structure

```
src/core/services/sync/
  syncEngine.js          — Push/pull orchestration, parallel runner (~200 lines)
  syncManifest.js        — Manifest CRUD, build, diff, V1→V2 migration (~200 lines)
  syncSerialization.js   — Entity serialization/deserialization for cloud (~150 lines)
  syncConflict.js        — Conflict detection, resolution, needsConflict (~100 lines)
  syncGallery.js         — Gallery image push/pull/dedup, hash matching (~150 lines)
  syncMergeStrategies.js — Declarative merge strategies per entity type (~100 lines)
```

### Merge Strategy Registry

```js
const MERGE_STRATEGIES = {
  character: mergeCharacterObjects,     // preserve local images, merge tags
  persona: lastWriteWins,               // simple overwrite
  chat: mergeChatMessages,              // preserve local messages, merge new
  lorebooks: mergeArrayById,            // ID-based merge for entries
  api_presets: mergePresetObjects,      // merge settings, preserve overrides
  regex_scripts: mergeArrayById,        // ID-based merge for scripts
  gallery: hashBasedDedup,              // content-hash dedup, not ID
  local_storage: lastWriteWins,         // simple overwrite
};
```

### Tasks

| Task | Description | Priority | Depends |
|------|-------------|----------|---------|
| CS-1 | BUG-6: Replace `db.getAll` with `db.get` for character lookups | high | none |
| CS-2 | BUG-2: Add gallery breakdown bucket, separate from characters | high | none |
| CS-3 | BUG-1: Gallery hash-based dedup on pull | high | CS-1 |
| CS-4 | BUG-4: Serialize gallery writes per character | high | CS-1 |
| CS-5 | BUG-7: Mark gallery as deleted in manifest when image not found | medium | none |
| CS-6 | BUG-5: Add conflict detection for gallery entries | medium | CS-3 |
| CS-7 | BUG-3: ConflictSheet field-level diff + avatar preview | medium | none |
| CS-8 | GDrive: Cache file IDs in manifest, reduce name resolution | medium | none |
| CS-9 | Extract syncManifest.js from syncEngine.js | low | CS-1..CS-5 |
| CS-10 | Extract syncGallery.js from syncEngine.js | low | CS-3, CS-4 |
| CS-11 | Extract syncConflict.js from syncEngine.js | low | CS-6 |
| CS-12 | Extract syncSerialization.js from syncEngine.js | low | CS-9 |
| CS-13 | Extract syncMergeStrategies.js | low | CS-12 |
| CS-14 | GDrive: persistent file ID mapping for cross-device reliability | low | CS-8 |

### Recommended Order

1. CS-1, CS-2 — quick fixes, no dependencies
2. CS-3 — gallery dedup (biggest user-facing bug)
3. CS-4 — gallery race condition fix
4. CS-5 — gallery manifest consistency
5. CS-7 — conflict detail visibility
6. CS-6 — gallery conflict detection
7. CS-8 — GDrive file ID caching
8. CS-9..CS-14 — decomposition (can be done incrementally)

### TavernRev Lessons

| Pattern | TavernRev | Glaze | Takeaway |
|---------|-----------|-------|----------|
| File identity | UUID filenames + name→ID resolution at sync time | Path-based with name→ID resolution in adapter | Same effective approach |
| File update | PATCH existing file by ID | PATCH existing file by ID | Same |
| Conflict | Last-write-wins by timestamp, no merge | Last-write-wins with conflict flag for newer local | Glaze is slightly better |
| Gallery sync | Not separate (images inline in character JSON) | Separate binary files with manifest entries | Glaze's approach is better for large galleries, but needs dedup |
| Folder creation | `get_or_create_folder` idempotent | Same pattern | Same |
| Delete handling | None (files never deleted) | Marked deleted in manifest, cloud files deleted | Glaze is better |
| Sync state | Stateless (compare DB timestamps vs cloud modifiedTime) | Stateful (manifest with entries, hashes, paths) | Glaze is better for delta sync |
| Auto-sync | Debounced 5s push after message save | Periodic + event-driven | TavernRev is more responsive |
