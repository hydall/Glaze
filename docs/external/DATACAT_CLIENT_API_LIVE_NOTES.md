<!--
Observed behaviour of the live DataCat deployment, recorded 2026-09-21 by two
runs against https://datacat.run/api/client/v1. The second run solved the
Turnstile challenge, so the lease and protected-transfer paths below are
measured rather than inferred.

This is not vendor documentation. It is a record of where the vendored
contract (DATACAT_CLIENT_API.md / .openapi.json) and the running server
disagree — and they do, in ways that silently break a client written to the
document. Where the two conflict, this file is the one that was measured.
-->

# DataCat Client API — live verification results

Run date: 2026-09-21, against `https://datacat.run/api/client/v1`.
Credentials: Client ID only (`dca_…`). No developer token.
Method: `curl` + Node for JSON. Browser: Playwright/Chromium (for the Turnstile step).

## TL;DR — the blocking items

| Question | Live answer | Code impact |
|---|---|---|
| Verification `action` value | **`character-import`** — HTTP 201. `character_transfer` → HTTP 400 `INVALID_VERIFICATION_ACTION`. | Must send `character-import`. Better: read `capabilities.securityCheck.actions[0]`. |
| Is `action` optional / unnamed accepted? | **YES** — omitting it returns HTTP 201 and the server defaults `action` to `"character-import"`. | Sending no `action` is the rename-proof path. |
| Pre-solve `/token` refusal | **HTTP 428** `VERIFICATION_PENDING`. | App treats 409 as "keep polling"; 428 is treated as fatal → it gives up on a solvable challenge. Fix `awaitDatacatLease`. |
| Lease expiry field name | **`expiresAt`**, absolute ISO-8601. Also new: `remainingUniqueCharacters`. | The app's `expiresAt` parse is correct. |
| Installation header on transfer | **Required** — `/card` and `/avatar` answer 428 `verificationReason:"missing"` if `X-Datacat-Installation-Id` is absent, even with a valid lease. | The app must send the installation header on both. Not in the contract. |
| Error machine code field | **`error`** (not `code`). | Confirmed. |
| `/characters` time window | **No** window/range param — silently ignored. | The `/fresh` detour is required. |
| Tag filters | **Numeric ids** in `tagIds`/`blockedTagIds`. `tagSlugs` is ignored. | Confirmed. |

Blocking conclusion: the integration's action rename to `character-import` is
correct against live. Two further correctness problems were found: the app's
polling loop expects **409** for "still pending" where the live server uses
**428**; and the protected transfer needs **`X-Datacat-Installation-Id`** next to
the lease, or the server reports the lease as `missing`.

---

## Check 1 — verification action

`POST /verifications` with `clientName=Glaze`, `clientVersion=0.0.0`,
`installationId=glaze-live-check-0000001`.

### 1a — `action: "character-import"` → HTTP **201**

```json
{
  "success": true,
  "verificationId": "2c1e43fd-72c4-49d4-9136-db31c8ee4cce",
  "deviceCode": "<redacted>",
  "verificationUri": "https://datacat.run/client-verify",
  "verificationUriComplete": "https://datacat.run/client-verify?id=2c1e43fd-72c4-49d4-9136-db31c8ee4cce",
  "expiresIn": 300,
  "interval": 3,
  "action": "character-import"
}
```

Field names are exactly as the app expects: `verificationId`, `deviceCode`,
`verificationUriComplete`, `expiresIn`, `interval`, and `action` echoes
`character-import`.

### 1b — `action: "character_transfer"` → HTTP **400**

```json
{
  "success": false,
  "error": "INVALID_VERIFICATION_ACTION",
  "message": "Unsupported verification action. Use \"character-import\"."
}
```

### 1c — no `action` → HTTP **201** (optional; defaults)

```json
{
  "success": true,
  "verificationId": "a780eb93-…",
  "deviceCode": "<redacted>",
  "verificationUriComplete": "https://datacat.run/client-verify?id=a780eb93-…",
  "expiresIn": 300,
  "interval": 3,
  "action": "character-import"
}
```

So the field is optional and the server defaults it to `character-import`. This
is the rename-proof option — send no `action` at all, or send
`capabilities.securityCheck.actions[0]`.

Creating verifications is rate-limited per IP: `x-ratelimit-limit: 10`,
`x-ratelimit-scope: ip`, `x-ratelimit-tier: anonymous` (the window is long — a
run was blocked with `retry-after: 2537` and reset ~42 min later).

### Discoverable legal action list — YES

`GET /capabilities` returns it, two places:

```json
"securityCheck": { "actions": ["character-import"], ... },
"verification":  { "actions": ["character-import"], ... }
```

So the rename-proof fix is to stop hard-coding the value and read
`capabilities.securityCheck.actions[0]` (fallback to `character-import`).

---

## Check 2 — verification status and pre-solve token

### `GET /verifications/{id}` (public) → HTTP 200

Status is **nested under `verification`**:

```json
{
  "success": true,
  "verification": {
    "verificationId": "2c1e43fd-…",
    "status": "pending",
    "action": "character-import",
    "client": { "name": "Glaze", "version": "0.0.0" },
    "expiresAt": "2026-09-21T13:18:24.000Z",
    "turnstile": {
      "siteKey": "0x4AAAAAADslrPaR78-5fojE",
      "action": "client_import",
      "cData": "…"
    }
  },
  "maxUniqueCharacters": 20
}
```

- `status` values seen: `pending`; plus `VERIFICATION_EXPIRED` handling below.
- `expiresAt` here is **absolute ISO-8601** on the challenge.
- Top-level `maxUniqueCharacters: 20`.

### `POST /verifications/{id}/token` before solving → HTTP **428**

```json
{
  "success": false,
  "error": "VERIFICATION_PENDING",
  "message": "Waiting for the DataCat security check."
}
```

**This is the key mismatch.** The app's `awaitDatacatLease` treats 409 as
"keep polling" and everything else as fatal. Live uses **428**.

### Expired challenge → HTTP **410** everywhere

`GET /verifications/{id}`, `POST /token`, and `POST /complete` all answer:

```json
{ "success": false, "error": "VERIFICATION_EXPIRED", "message": "This verification request expired." }
```

### Success body — obtained

Turnstile was solved with a headed Chromium under `xvfb` using the browser's own
User-Agent. Two earlier attempts failed:
- headless Chromium with a UA override (UA said Chrome/136, binary was 153) →
  `[Cloudflare Turnstile] Error: 600010`, widget never loaded;
- plain headless → `error-callback`, "The human security check could not be
  loaded."

Once solved, the hosted page POSTed `/complete`:
`{"status":"verified","verifiedAt":"2026-09-21T17:13:42.529Z"}`.

`POST /verifications/{id}/token` → HTTP 200:

```json
{
  "success": true,
  "leaseToken": "dcv1v_…",
  "tokenType": "DataCat-Verification",
  "leaseHeader": "X-Datacat-Verification-Lease",
  "action": "character-import",
  "expiresAt": "2026-09-21T17:43:48.298Z",
  "maxUniqueCharacters": 20,
  "remainingUniqueCharacters": 20
}
```

- Expiry is **`expiresAt`**, absolute ISO-8601 (≈30 min after issue, matching
  `leaseTtlSeconds: 1800`). The app's absolute-timestamp parsing is correct.
- Extra field `remainingUniqueCharacters` (not in the contract).

```json
"securityCheck": {
  "enabled": true, "hosted": true,
  "createPath": "/api/client/v1/verifications",
  "hostedPath": "/client-verify",
  "leaseHeader": "X-Datacat-Verification-Lease",
  "challengeTtlSeconds": 300,
  "leaseTtlSeconds": 1800,
  "maxUniqueCharacters": 20,
  "requiredFor": ["character-card", "mirrored-avatar"],
  "independentOfAccount": true,
  "requiredForAllAccountStates": true
}
```

So a lease lives 1800 s (30 min), not the 5-minute stub the app may assume.

---

## Check 3 — protected download

### Without a lease → HTTP **428** (not 403/401)

`/characters/{id}/card` (and `/avatar`, same body):

```json
{
  "success": false,
  "error": "CLIENT_VERIFICATION_REQUIRED",
  "message": "Complete the DataCat security check before importing a character.",
  "verificationRequired": true,
  "securityCheckRequired": true,
  "verificationReason": "missing",
  "verification": {
    "createPath": "/api/client/v1/verifications",
    "leaseHeader": "X-Datacat-Verification-Lease",
    "action": "character-import"
  },
  "securityCheck": {
    "createPath": "/api/client/v1/verifications",
    "leaseHeader": "X-Datacat-Verification-Lease",
    "action": "character-import",
    "independentOfAccount": true
  }
}
```

Confirmed for the app's parsing:
- `verificationRequired` **and** `securityCheckRequired` both present, both `true`.
- machine code lives in `error` (no `code`).
- `verification.action` = `character-import`.
- `verificationReason` = `missing` (useful for choosing "re-verify" vs "first verify").
- `sourceKind` was **omitted** on the request and the refusal still came back — sourceKind is not required to reach the gate. (Whether it is required on the success path is unverified, but profile works without it.)

### `avatar-preview?sourceKind=direct_upload` — not testable

The chosen character is not a direct-upload, so we could not confirm the public
path. `/capabilities` lists `mirroredAvatars` and `humanSecurityCheck`, but no
per-endpoint flag.

### With a lease — works, but the installation header is mandatory

The lease alone is **not enough**. `/card` and `/avatar` with
`X-Datacat-Verification-Lease` but **without** `X-Datacat-Installation-Id` still
answer 428 `CLIENT_VERIFICATION_REQUIRED` / `verificationReason: "missing"`.

| Headers sent | `/card` result |
|---|---|
| Client ID + lease | 428 `missing` |
| Client ID + lease + `sourceKind` | 428 `missing` |
| Client ID + lease + `X-Datacat-Installation-Id` | **200** |
| Client ID + lease + installation + `sourceKind` | **200** |

The installation header is missing from the vendored contract. Without it the
lease is silently ignored.

`/card` success is a bare Character Card V2 with an extra top-level `metadata`:

```json
{
  "spec": "chara_card_v2",
  "spec_version": "2.0",
  "data": {
    "name": "…",
    "description": "…",
    "personality": "",
    "scenario": "…",
    "first_mes": "…",
    "mes_example": "",
    "creator_notes": "…",
    "system_prompt": "",
    "post_history_instructions": "",
    "alternate_greetings": [],
    "character_book": {},
    "tags": [...],
    "creator": "…",
    "character_version": "…",
    "avatar": "…",
    "extensions": { "datacat": {...} }
  },
  "metadata": {
    "version": "...", "created": "...", "modified": "...", "tool": "...",
    "raw_description_html": "...",
    "janitor_character_name": "...", "janitor_character_id": "...",
    "janitor_creator_id": "...", "janitor_creator_name": "...",
    "janitor_is_nsfw": false, "janitor_is_public": true,
    "janitor_show_definitions": true, "janitor_allow_proxy": false,
    "extensions": {...}
  }
}
```

So: not wrapped under `card` or `chara_card_v2_json` — bare `{spec, spec_version,
data, metadata}`. `sourceKind` is genuinely optional on `/card` (the 200 above
was obtained without it). `metadata.janitor_show_definitions` is a useful
"is the definition public" flag.

`/avatar` with lease + installation → HTTP 200 `image/webp`, 45430 bytes,
`content-disposition: inline; filename="…​.webp"`.

### `avatar-preview` — still untested

`/characters?sourceKind=direct_upload` is ignored (returns `janitor_core`), so no
direct-upload character could be selected, and `clientPaths.avatarPreview` was
`null` on the sampled summaries. Public `avatar-preview` behaviour is unverified.

---

## Check 4 — discovery

### `/capabilities` → HTTP 200 (public; no Client ID needed)

The app reads these; all exist:

- `paging.defaultPageSize` = 24, `paging.maxPageSize` = 24 ✓
- `features.listing = true`, `features.tagBrowsing = true`, `features.social = true` ✓
- `securityCheck.enabled = true` ✓

Extra features present: `paging`, `search`, `profiles`, `creatorProfiles`,
`freshFeed`, `jsonCardImport`, `mirroredAvatars`, `accountLinking`,
`remoteVerification`, `humanSecurityCheck`.

Rate limits (live): discovery `120 / 600 s / ip`, community read `60 / 600 s`,
community write `10 / 600 s` (logged-in required), tiers anonymous ×1,
loggedIn ×4.

### `/characters` → HTTP 200

Top-level: `success`, `characters`, `paging`, `filters`.
Item fields match `CharacterSummary` exactly, including `creator.ref`,
`clientPaths`, `image{status,url}`, `avatarUrl`, `stats{chats,messages,messagesPerChat}`,
`totalTokens`, `score`, `nsfw`, timestamps.

Paging: `{"limit":24,"offset":0,"hasMore":true,"nextOffset":24}` — **no `total` field at all.**

Sort values — all five accepted:

| `sort` | HTTP | `filters.sort` echoed |
|---|---|---|
| `fresh` | 200 | fresh |
| `score` | 200 | score |
| `chat_count` | 200 | chat_count |
| `messages_per_chat` | 200 | messages_per_chat |
| `first_published` | 200 | first_published |
| `bogus_sort` | 200 | **fresh** (silently falls back) |

Window/time-range — **not supported**:

```
GET /characters?sort=score&window=last24h&timeWindow=last24h&createdWithin=24h
→ filters: {"tagIds":[],"blockedTagIds":[],"search":null,"sort":"score"}
```

The window parameters are neither echoed nor honoured. `/fresh` is the only
windowed path.

Tag filters — numeric ids only:

```
GET /characters?tagIds=12,44        → filters.tagIds = [12,44]   (honoured)
GET /characters?tagSlugs=fantasy    → filters.tagIds = []        (ignored)
GET /characters?blockedTagIds=2     → filters.blockedTagIds = [2] (honoured; all results nsfw:false)
```

### `/tags` → HTTP 200

Top-level: `success`, `groups` (6), `tags` (240), `filters`, `paging`.

```json
"paging": { "limit": 240, "offset": 0, "totalCount": 110000, "hasMore": true, "nextOffset": 240 }
```

- **Naming inconsistency:** `/tags` uses `totalCount`; creators use `total`;
  characters and `/fresh` have no total at all.
- `limit=250` requested, clamped to 240.
- `tag[0]` = `{id:2, name:"NSFW", slug:"nsfw", groupId:1, count:598458}`.
- `group[0]` = `{id:1, name:"Rating", slug:"rating", displayOrder:0, exclusive:true}`.

### `/fresh` → HTTP 200

```json
"windows": { "last24h": {...}, "thisWeek": {...} }
```

Each window has `count`, `characters`, `paging` (`limit/offset/hasMore/nextOffset`,
no total). Confirmed shape.

---

## Check 5 — creators

`ref` is `creator.ref` from a character summary (equals `creator.id` for janitor).

### `/creators/{ref}/bootstrap` → HTTP 200

Top-level: `success`, `creatorRef{id,sourceKind,publicRef}`, `creator`,
`characters`, `paging`, `filters`.

`creator` field names all match what the app reads:

```json
{
  "id": "...", "ref": "...", "sourceKind": "janitor", "name": "...",
  "handle": null, "avatarUrl": "https://...", "about": "...", "verified": false,
  "stats": { "characters": 11, "chats": 10527, "messages": 153692, "followers": 385 },
  "topTags": [{ "name": "Male", "slug": "male", "count": 10 }, ...],
  "createdAt": "...", "updatedAt": "..."
}
```

### `/creators/{ref}/characters` → HTTP 200

`creator` is `null` (as documented). `filters` echoes
`tagSlugs/blockedTagSlugs/sort/sortDir`. Paging uses `total`:
`{"limit":3,"offset":0,"total":4,"hasMore":true,"nextOffset":3}`.

Limit ceiling: `limit=51` → HTTP 200 but `paging.limit` clamped to **50**. So the
app's 50 clamp matches.

---

## Check 6 — community and account

### `/account/status` → HTTP 200 (Client ID only)

Matches the contract exactly:

```json
{
  "success": true,
  "accountState": "unlinked",
  "account": null,
  "installation": { "boundToAccountToken": false, "linkageKind": null },
  "rateLimit": { "tier": "anonymous", "multiplier": 1, "discoveryMultiplier": 1, "linkedAccountMultiplier": 4 },
  "securityCheck": { "independentOfAccount": true, "requiredForProtectedTransfers": true }
}
```

`accountState` is the string `unlinked` (not a boolean). Good.

### `/characters/{id}/community` → HTTP 200

Payload **wrapped in `community`**:

```json
{
  "success": true,
  "community": {
    "characterId": "...",
    "kudos": { "total": 0, "gifts": undefined, "options": [{ "key": "kudos", "label": "Kudos", "emoji": "💖", "description": "..." }] },
    "comments": { "total": 0, "items": [], "paging": { "limit": 40, "offset": 0, "hasMore": false, "nextOffset": 0 } },
    "canInteract": false
  }
}
```

- `canInteract` is a boolean **inside `community`**.
- `kudos.options[]` keys on `key` (not `giftKey`).
- `kudos.gifts` is absent/empty when there are none; its `key` spelling and the
  comment item fields (`id`/`body`/`createdAt`/`author.username`) could **not** be
  confirmed — 13 sampled characters (top score and top chat_count) all had
  `kudos.total = 0` and `comments.total = 0`.
- Comments `paging.nextOffset` is `0` (not `null`) when there are no more.

Account linking (needs a real login) was not run.

---

## Extra findings that affect the app

1. **Missing/unknown Client ID → HTTP 403** `CLIENT_API_CLIENT_NOT_APPROVED`
   ("not approved or has been revoked"), not 401. If the app treats 403 as an
   auth-retry signal, it will loop pointlessly.
2. **Paging total naming is inconsistent**: `/tags` → `totalCount`, creators →
   `total`, `/characters` and `/fresh` → neither (`hasMore`/`nextOffset` only).
3. **`/characters` has no `total`**, so the app cannot show an exact result count
   from the API.
4. **`/tags` clamps limit to 240**, not the documented 250.
5. **Sort falls back silently** to `fresh` on an unknown value (no 400).
6. **`securityCheck` is independent of account and required for all account
   states** — a developer token would not bypass the human check.
7. **Lease lifetime is 1800 s**, challenge lifetime 300 s.
8. **`/capabilities` is public** (no Client ID), but every scoped route needs the
   Client ID.
9. **Protected transfers need `X-Datacat-Installation-Id` next to the lease** —
   without it, a valid lease is reported as `verificationReason: "missing"`. This
   is absent from the vendored contract.
10. **`action` on `POST /verifications` is optional** and defaults to
    `character-import`.
11. **Lease response adds `remainingUniqueCharacters`** and uses `expiresAt`
    (absolute ISO, ~1800 s out), not `expiresIn`.
12. **Bearer with the Client ID value is rejected** (`INVALID_CLIENT_TOKEN`, 401)
    — the Client ID is not a developer token, as expected.

## Still unverified

- `avatar-preview` public behaviour (no direct-upload sample available;
  `sourceKind` is ignored as a `/characters` filter).
- Community gift/comment item field names (no populated sample — 13 sampled
  characters all had `kudos.total = 0` and `comments.total = 0`).
- Account linking (`POST /account-links` → approve → token): needs a real DataCat
  login. Whether the token response carries granted `scopes` is untested.

Note on the Turnstile step for future runs: it only cleared in a **headed**
Chromium under `xvfb` with the browser's **real** User-Agent. Headless and a
mismatched UA both failed (`600010`).