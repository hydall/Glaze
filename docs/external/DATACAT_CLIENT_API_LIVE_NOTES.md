<!--
Observed behaviour of the live DataCat deployment, recorded 2026-09-21 by a
run against https://datacat.run/api/client/v1.

This is not vendor documentation. It is a record of where the vendored
contract (DATACAT_CLIENT_API.md / .openapi.json) and the running server
disagree — and they do, in ways that silently break a client written to the
document. Where the two conflict, this file is the one that was measured.

The items still marked unverified were blocked by Turnstile and the per-IP
verification rate limit, not by choice.
-->

# DataCat Client API — live verification results

Run date: 2026-09-21, against `https://datacat.run/api/client/v1`.
Credentials: Client ID only (`dca_…`). No developer token.
Method: `curl` + Node for JSON. Browser: Playwright/Chromium (for the Turnstile step).

## TL;DR — the blocking items

| Question | Live answer | Code impact |
|---|---|---|
| Verification `action` value | **`character-import`** — HTTP 201. `character_transfer` → HTTP 400 `INVALID_VERIFICATION_ACTION`. | Must send `character-import`. Better: read `capabilities.securityCheck.actions[0]`. |
| Is `action` optional / unnamed accepted? | **Not proven** — rate-limited. | Use the capabilities list. |
| Pre-solve `/token` refusal | **HTTP 428** `VERIFICATION_PENDING`. | App treats 409 as "keep polling"; 428 is treated as fatal → it gives up on a solvable challenge. Fix `awaitDatacatLease`. |
| Lease expiry field name | **Not verified** (could not solve Turnstile / rate-limited). | Open. Contract says `expiresAt`. |
| Error machine code field | **`error`** (not `code`). | Confirmed. |
| `/characters` time window | **No** window/range param — silently ignored. | The `/fresh` detour is required. |
| Tag filters | **Numeric ids** in `tagIds`/`blockedTagIds`. `tagSlugs` is ignored. | Confirmed. |

Blocking conclusion: the integration's action rename to `character-import` is
correct against live. The other blocker is that the app's polling loop expects
**409** for "still pending"; the live server uses **428**. That must be fixed or
the first solve is thrown away as fatal.

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

### 1c — no `action` → HTTP **429** (inconclusive)

```json
{
  "success": false,
  "error": "CLIENT_API_RATE_LIMITED",
  "message": "Your anonymous DataCat Client API limit was reached. Link DataCat or wait before trying again.",
  "accountState": "anonymous"
}
```

Rate limit headers: `x-ratelimit-limit: 10`, `x-ratelimit-remaining: 0`,
`x-ratelimit-scope: ip`, `x-ratelimit-tier: anonymous`,
`retry-after: 2537`.

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

### Success body — NOT OBTAINED

Turnstile did not solve in this environment (headless and `xvfb-run` headed
Chromium both sat at "Complete the Cloudflare check below" until the 300 s
challenge TTL expired), and creating a replacement challenge was blocked by the
per-IP creation limit (reset 2026-09-21T13:58:35Z). So the lease token response
shape (`leaseToken`, and whether expiry is `expiresAt` vs `expiresIn`) is
**unverified**. From `/capabilities`:

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

### With a lease — NOT TESTED (no lease obtained)

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

## Still unverified (blocked)

- The lease token success body: `leaseToken` field name, and whether expiry is
  `expiresAt` (absolute) or `expiresIn` (seconds).
- `/characters/{id}/card` success body shape (bare `{spec,data}` vs wrapped under
  `card` / `chara_card_v2_json`).
- `/characters/{id}/avatar` success and `avatar-preview` public behaviour.
- Whether an absent `action` is accepted on `POST /verifications`.
- Community gift/comment item field names (no populated sample).

Reason: Turnstile does not solve in this sandbox, and `POST /verifications` is
rate-limited per IP (10 per window; reset 2026-09-21T13:58:35Z). Re-run the
lease-dependent checks after the reset or from a real browser.